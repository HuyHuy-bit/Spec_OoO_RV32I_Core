`default_nettype none
// two-wide fetch: one 32-byte line buffer, next-line prefetch, the last line left and the branch predictor.
// ICACHE=1: lines come from l1_icache, read once per line into line_q; an idle line checks line+1 with a prefetch,
// whose hit fills the ahead buffer. REDIRECT_CYCLE=1 looks a redirect target up from pc_q the next cycle (ruling Q7).
module fetch_unit #(parameter bit PREDICT = 0, parameter bit AHEAD = 0,
                    parameter bit TAGE = 0, parameter int CHECKPOINT_BITS = TAGE ? 36 : 12,
                    parameter bit ICACHE = 0, parameter bit REDIRECT_CYCLE = 1) (
  // inputs
  input  wire clk_i, rst_i, enable_i,
  input  wire redirect_i,
  input  wire [31:0] redirect_pc_i,
  input  wire invalidate_i,                // ICACHE: fence.i, once the data cache is clean
  input  wire hold_i,                      // ICACHE: fence.i before its invalidate; no new instruction-port request
  input  wire request_ready_i,
  input  wire response_valid_i,
  input  memory_protocol_pkg::mem_response_t response_i,
  input  wire [1:0] take_i,
  input  wire repair_i,
  input  wire [CHECKPOINT_BITS-1:0] repair_checkpoint_i,
  input  wire [1:0] retire_i,
  input  wire [63:0] retire_instruction_i, retire_pc_i, retire_next_i,

  // outputs
  output wire request_valid_o,
  output memory_protocol_pkg::mem_request_t request_o,
  output wire response_ready_o,
  output logic [1:0] valid_o,
  output logic [63:0] instruction_o, pc_o,
  output wire fault_o,
  output wire [31:0] fault_cause_o,
  output wire busy_o,
  output logic fatal_o,
  output wire [1:0] predict_taken_o,
  output wire [63:0] predict_pc_o,
  output wire [2*CHECKPOINT_BITS-1:0] predict_checkpoint_o
);
  import memory_protocol_pkg::*;
  import platform_pkg::*;
  import core_pkg::executable;
  typedef enum logic [2:0] {EMPTY, REQUEST, RESPONSE, BUFFER, FAULT, STOP, WAIT} state_e;
  typedef enum logic [1:0] {A_IDLE, A_REQ, A_RESP, A_HAVE} ahead_e;
  ahead_e ahead_q;
  logic [26:0] ahead_line_q;
  logic [255:0] ahead_data_q;
  logic ahead_drop_q;
  logic previous_valid_q;
  logic [26:0] previous_line_q;
  logic [255:0] previous_data_q;
  state_e state_q;
  logic [31:0] pc_q;
  logic [26:0] request_line_q;
  logic [255:0] line_q;
  logic [3:0] id_q;
  logic discard_q, misaligned_q;
  wire active = !rst_i && !fatal_o;
  wire [31:0] advance = take_i[1] ? 32'd8 : 32'd4;
  wire [1:0] taken;
  wire [63:0] target;
  wire [2:0] next_word = pc_q[4:2] + 3'd1;
  wire [63:0] words = {line_q[32*next_word +: 32], line_q[32*pc_q[4:2] +: 32]};
  wire ic_hit, ic_miss, ic_fill, ic_fill_fault, ic_prefetch_ready, ic_prefetch_hit, ic_busy, ic_fatal;
  wire ic_request_valid, ic_response_ready;
  wire [255:0] ic_hit_data, ic_fill_data;
  wire [26:0] ic_fill_line;
  mem_request_t ic_request;

  // branch prediction
  if (PREDICT) begin : prediction
    branch_predictor #(.TAGE(TAGE)) predictor (
      .clk_i, .rst_i, .pc_i(pc_o), .instruction_i(words), .taken_o(taken), .target_o(target),
      .take_i(take_i & {2{state_q == BUFFER}}), .checkpoint_o(predict_checkpoint_o), .redirect_i, .repair_i,
      .repair_checkpoint_i, .retire_i, .retire_instruction_i, .retire_pc_i, .retire_next_i
    );
  end else begin : sequential
    assign taken = 0;
    assign target = 0;
    assign predict_checkpoint_o = 0;
    wire unused = ^{repair_i, repair_checkpoint_i, retire_i, retire_instruction_i, retire_pc_i, retire_next_i, words};
  end

  // fetch advance and line selection
  // a predicted-taken lane ends the offered group.
  assign predict_taken_o = taken & valid_o & {2{state_q == BUFFER}};
  assign predict_pc_o = {predict_taken_o[1] ? target[63:32] : pc_o[63:32] + 32'd4,
                         predict_taken_o[0] ? target[31:0] : pc_o[31:0] + 32'd4};
  wire last = take_i[1];
  wire jump = predict_taken_o[last];
  wire [31:0] jump_pc = last ? target[63:32] : target[31:0];
  wire crossing = {1'b0, pc_q[4:2]} + (take_i[1] ? 4'd2 : 4'd1) >= 4'd8;
  wire leave = state_q == BUFFER && take_i[0] && !redirect_i && (jump ? jump_pc[31:5] != pc_q[31:5] : crossing);
  wire [26:0] next_line = jump ? jump_pc[31:5] : pc_q[31:5] + 27'd1;
  wire ahead_flight = ahead_q == A_REQ || ahead_q == A_RESP;
  wire ahead_match = ahead_q != A_IDLE && ahead_line_q == next_line;
  wire ahead_cancel = redirect_i || (leave && !ahead_match) || (state_q == EMPTY && ahead_q == A_HAVE);
  // the line last left: a predicted jump back to it swaps it in without an instruction-memory request.
  wire previous_match = PREDICT && previous_valid_q && previous_line_q == next_line;
  wire previous_next = PREDICT && previous_valid_q && previous_line_q == pc_q[31:5] + 27'd1;
  // a mispredict repair (never a trap, flush or fence.i) into a held line restarts without a request.
  wire repair_reuse = PREDICT && repair_i && enable_i && redirect_pc_i[1:0] == 0
    && !(!ICACHE && state_q inside {REQUEST, RESPONSE});
  wire repair_current = repair_reuse && state_q == BUFFER && redirect_pc_i[31:5] == pc_q[31:5];
  wire repair_previous = repair_reuse && previous_valid_q && redirect_pc_i[31:5] == previous_line_q;

  // next-line prefetch admission
  // suppress next-line prefetch when a remaining backward branch or jump may reuse this line.
  logic loop_back;
  always_comb begin
    loop_back = 0;
    for (int w = 0; w < 8; w++)
      if (3'(w) >= pc_q[4:2] && line_q[32*w+31] && line_q[32*w +: 7] inside {7'h63, 7'h6f}) loop_back = 1;
  end
  // ICACHE: the offer is a prefetch check of line+1 and takes no late term; one made in a redirect cycle is
  // cancelled the next.
  wire ahead_offer = AHEAD && state_q == BUFFER && ahead_q == A_IDLE && enable_i && !loop_back && !previous_next
    && executable({pc_q[31:5] + 27'd1, 5'd0}) && (!ICACHE || ic_prefetch_ready);
  wire ahead_start = ahead_offer && !redirect_i && !leave;
  wire malformed = !ICACHE && response_valid_i && (!(state_q == RESPONSE || ahead_q == A_RESP)
    || response_i.transaction_id != id_q
    || !(response_i.status inside {MEM_STATUS_OK, MEM_STATUS_ACCESS_FAULT})
    || response_i.uncached_read_data != 0
    || (response_i.status != MEM_STATUS_OK && response_i.line_read_data != 0));

  // instruction cache. A lookup reads pc_q's line in EMPTY, or a redirect target in its redirect cycle without
  // REDIRECT_CYCLE; REQUEST takes the answer and RESPONSE waits for a miss's fill. Every lookup is executable.
  wire empty_lookup = state_q == EMPTY && enable_i && pc_q[1:0] == 0 && executable(pc_q);
  wire redirect_lookup = ICACHE && !REDIRECT_CYCLE && redirect_i && enable_i && redirect_pc_i[1:0] == 0
    && executable(redirect_pc_i) && !repair_current && !repair_previous;
  wire fill_take = state_q == RESPONSE && (ic_fill || ic_fill_fault) && ic_fill_line == request_line_q;
  if (ICACHE) begin : icache
    logic hold_q, offered_q, redirect_q;
    wire cache_request_valid;
    // fence.i holds back a new request; one already offered stays offered
    wire hold = hold_q && !offered_q;
    l1_icache cache (
      .clk_i, .rst_i, .invalidate_i,
      .lookup_valid_i(!REDIRECT_CYCLE && redirect_i ? redirect_lookup : empty_lookup),
      .lookup_line_i(!REDIRECT_CYCLE && redirect_i ? redirect_pc_i[31:5] : pc_q[31:5]),
      .prefetch_valid_i(ahead_offer), .prefetch_line_i(pc_q[31:5] + 27'd1), .prefetch_cancel_i(redirect_q),
      .mem_request_ready_i(request_ready_i && !hold), .mem_response_valid_i(response_valid_i),
      .mem_response_i(response_i), .hit_valid_o(ic_hit), .hit_data_o(ic_hit_data), .miss_o(ic_miss),
      .fill_valid_o(ic_fill), .fill_data_o(ic_fill_data), .fill_fault_o(ic_fill_fault), .fill_line_o(ic_fill_line),
      .prefetch_ready_o(ic_prefetch_ready), .prefetch_hit_o(ic_prefetch_hit), .busy_o(ic_busy), .fatal_o(ic_fatal),
      .mem_request_valid_o(cache_request_valid), .mem_request_o(ic_request),
      .mem_response_ready_o(ic_response_ready)
    );
    assign ic_request_valid = cache_request_valid && !hold;
    always_ff @(posedge clk_i) begin
      if (rst_i) {hold_q, offered_q, redirect_q} <= '0;
      else begin
        hold_q <= hold_i;
        redirect_q <= redirect_i;
        offered_q <= request_valid_o && !request_ready_i;
      end
    end
  end else begin : no_icache
    assign {ic_hit, ic_miss, ic_fill, ic_fill_fault, ic_prefetch_ready, ic_prefetch_hit, ic_busy, ic_fatal} = '0;
    assign {ic_request_valid, ic_response_ready, ic_hit_data, ic_fill_data, ic_fill_line} = '0;
    assign ic_request = '0;
    wire unused_icache = ^{invalidate_i, hold_i, empty_lookup, redirect_lookup, fill_take};
  end

  // a redirect cannot withdraw an offered request or release an owned id.
  wire ahead_request = active && ahead_q == A_REQ;
  assign request_valid_o = ICACHE ? active && ic_request_valid : ahead_request || active && state_q == REQUEST;
  assign response_ready_o = active && (ICACHE ? ic_response_ready : state_q == RESPONSE || ahead_q == A_RESP);
  assign busy_o = active && (ICACHE ? ic_busy : state_q == REQUEST || state_q == RESPONSE || ahead_flight);
  assign fault_o = valid_o[0] && state_q == FAULT;
  assign fault_cause_o = misaligned_q ? CAUSE_INSTRUCTION_ADDRESS_MISALIGNED
                                    : CAUSE_INSTRUCTION_ACCESS_FAULT;

  // request formatting and lane delivery
  always_comb begin
    request_o = '0;
    request_o.transaction_id = id_q;
    request_o.address = {request_line_q, 5'd0};
    if (ahead_q == A_REQ) request_o.address = {ahead_line_q, 5'd0};
    if (ICACHE) request_o = ic_request;
    valid_o = '0;
    pc_o = {pc_q + 32'd4, pc_q};
    instruction_o = '0;
    if (active && !redirect_i) begin
      if (state_q == BUFFER) begin
        valid_o = pc_q[4:2] == 3'd7 ? 2'b01 : 2'b11;
        if (taken[0]) valid_o = 2'b01;
        instruction_o[31:0] = line_q[pc_q[4:2]*32 +: 32];
        if (valid_o[1]) instruction_o[63:32] = line_q[(int'(pc_q[4:2])+1)*32 +: 32];
      end else if (state_q == FAULT) valid_o = 2'b01;
    end
  end

  // fetch, prefetch and redirect state
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= EMPTY;
      pc_q <= RESET_PC;
      id_q <= 0;
      discard_q <= 0;
      ahead_q <= A_IDLE;
      ahead_drop_q <= 0;
      previous_valid_q <= 0;
      misaligned_q <= 0;
      fatal_o <= 0;
    end else if (!fatal_o) begin
      if (malformed) fatal_o <= 1;
      if (ic_fatal) fatal_o <= 1;
      case (state_q)
        EMPTY: if (enable_i && !redirect_i && (ICACHE || !ahead_flight)) begin
          misaligned_q <= pc_q[1:0] != 0;
          if (pc_q[1:0] != 0 || !executable(pc_q)) state_q <= FAULT;
          else begin
            request_line_q <= pc_q[31:5];
            discard_q <= 0;
            state_q <= REQUEST;
          end
        end
        // ICACHE: the lookup's answer; a retry looks up again
        REQUEST: if (ICACHE) begin
          if (ic_hit) begin
            line_q <= ic_hit_data;
            state_q <= BUFFER;
          end else state_q <= ic_miss ? RESPONSE : EMPTY;
        end else if (request_ready_i) state_q <= RESPONSE;
        RESPONSE: if (ICACHE ? fill_take : response_valid_i && !malformed) begin
          discard_q <= 0;
          if (discard_q || redirect_i) state_q <= EMPTY;
          else if (ICACHE ? ic_fill_fault : response_i.status == MEM_STATUS_ACCESS_FAULT) begin
            misaligned_q <= 0;
            state_q <= FAULT;
          end else begin
            line_q <= ICACHE ? ic_fill_data : response_i.line_read_data;
            state_q <= BUFFER;
          end
        end
        BUFFER: if (take_i[0] && !redirect_i) begin
          pc_q <= jump ? jump_pc : pc_q + advance;
          if (leave) begin
            if (PREDICT) begin
              previous_valid_q <= 1;
              previous_line_q <= pc_q[31:5];
              previous_data_q <= line_q;
            end
            if (ahead_match && ahead_q == A_HAVE) begin
              line_q <= ahead_data_q;
              ahead_q <= A_IDLE;
            end else if (previous_match) line_q <= previous_data_q;
            else state_q <= ahead_match ? WAIT : EMPTY;
          end
        end
        WAIT: if (ahead_q == A_HAVE) begin
          line_q <= ahead_data_q;
          ahead_q <= A_IDLE;
          state_q <= BUFFER;
        end else if (ahead_q == A_IDLE) state_q <= EMPTY;
        FAULT: if (take_i[0] && !redirect_i) state_q <= STOP;
        default: ;
      endcase
      if (response_valid_i && response_ready_o && !malformed) id_q <= id_q + 1'b1;
      // discard stale or faulting prefetches; demand fetch reports faults precisely.
      case (ahead_q)
        A_IDLE: if (ahead_start) begin
          ahead_line_q <= pc_q[31:5] + 27'd1;
          ahead_drop_q <= 0;
          ahead_q <= A_REQ;
        end
        A_REQ: if (ICACHE) begin
          if (ic_prefetch_hit) begin
            ahead_data_q <= ic_hit_data;
            ahead_q <= A_HAVE;
          end else if (ic_prefetch_ready) ahead_q <= A_IDLE;
        end else if (request_ready_i) ahead_q <= A_RESP;
        // ICACHE: unreachable; the guard keeps the uncached capture's late cancel off ahead_data_q's enable
        A_RESP: if (!ICACHE && response_valid_i && !malformed) begin
          if (ahead_drop_q || ahead_cancel || response_i.status != MEM_STATUS_OK) ahead_q <= A_IDLE;
          else begin
            ahead_data_q <= response_i.line_read_data;
            ahead_q <= A_HAVE;
          end
        end
        A_HAVE: if (ahead_cancel) ahead_q <= A_IDLE;
        default: ;
      endcase
      if (ahead_cancel && ahead_flight) ahead_drop_q <= 1;
      // the cache owns a prefetch check, so a cancelled one is just forgotten
      if (ICACHE && ahead_cancel && ahead_q == A_REQ) ahead_q <= A_IDLE;
      // every redirect but a mispredict repair, including FENCE.I's, drops the retained line.
      if (redirect_i) begin
        if (!(PREDICT && repair_i)) previous_valid_q <= 0;
        pc_q <= redirect_pc_i;
        if (!ICACHE && (state_q == REQUEST || state_q == RESPONSE)) begin
          if (!(state_q == RESPONSE && response_valid_i && !malformed)) discard_q <= 1;
        end else if (repair_current) state_q <= BUFFER;
        else if (repair_previous) begin
          line_q <= previous_data_q;
          if (state_q == BUFFER) begin
            previous_line_q <= pc_q[31:5];
            previous_data_q <= line_q;
          end
          state_q <= BUFFER;
        end else if (redirect_lookup) begin
          request_line_q <= redirect_pc_i[31:5];
          state_q <= REQUEST;
        end else state_q <= EMPTY;
      end
    end
  end

  // checks
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      assert (!(take_i[1] && !take_i[0]) && (take_i & ~valid_o) == 0)
        else $fatal(1, "FETCH_PREFIX");
    end
  end
`endif
endmodule
`default_nettype wire
