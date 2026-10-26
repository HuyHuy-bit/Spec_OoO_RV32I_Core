`default_nettype none
// L1 instruction cache: 2 ways of 32-byte lines over l1_cache_array, read-only.
// A lookup reads its set when presented and answers HIT_STAGES = 1 cycle later with a hit, a miss, or neither: a
// miss decided around an install into its set is not trusted, and fetch looks up again (T7-A2). A miss makes its
// line the demand, replacing any older one. The single transaction then answers the demand with fill_valid_o or
// fill_fault_o, whether the demand or an earlier prefetch of that line started it. A prefetch only checks its
// line, in a cycle without a lookup, and requests it on a miss when nothing else waits (T7-A3); a check that hits
// shows its line on hit_data_o with prefetch_hit_o, so fetch fills its ahead buffer without a demand.
// prefetch_cancel_i, fetch's redirect a cycle late, drops a check accepted or read before the redirect: it is
// neither read nor requested, so the redirected path's own checks start at once.
// The fill lands in line_q and installs from it the next cycle. invalidate_i clears every valid bit; the
// transaction in flight at that edge installs and answers nothing, and a demand left waiting is requested again.
// Every ready, request and array write comes from registers; only the lookup answer is combinational.
module l1_icache #(parameter int HIT_STAGES = 1, SETS = 16) (
  // inputs
  input  wire clk_i, rst_i,
  input  wire invalidate_i,
  input  wire lookup_valid_i,                  // demand; accepted every cycle
  input  wire [31:5] lookup_line_i,
  input  wire prefetch_valid_i,                // only fills, never returns data
  input  wire [31:5] prefetch_line_i,
  input  wire prefetch_cancel_i,               // registered: the pending or staged prefetch check is stale
  input  wire mem_request_ready_i,
  input  wire mem_response_valid_i,
  input  memory_protocol_pkg::mem_response_t mem_response_i,
  // outputs
  output wire hit_valid_o,                     // HIT_STAGES after the lookup
  output wire [255:0] hit_data_o,
  output wire miss_o,
  output wire fill_valid_o,                    // the demand line fill_line_o arrived in fill_data_o
  output wire [255:0] fill_data_o,
  output wire fill_fault_o,                    // the demand line's fill was an access fault; nothing installed
  output wire [31:5] fill_line_o,
  output wire prefetch_ready_o,
  output wire prefetch_hit_o,                  // the accepted prefetch's check hit; its line is on hit_data_o
  output wire busy_o,
  output wire fatal_o,                         // protocol error; sticky. Then every handshake output stays low and
                                               // busy_o high
  output wire mem_request_valid_o,
  output memory_protocol_pkg::mem_request_t mem_request_o,
  output wire mem_response_ready_o
);
  import memory_protocol_pkg::*;
  localparam int WAYS = 2, INDEX_BITS = $clog2(SETS), TAG_BITS = 27 - INDEX_BITS;

  // shortcut: the install-race window is built for HIT_STAGES = 1; a second stage would widen it
  if (HIT_STAGES != 1) begin : g_hit_stages
    $error("l1_icache implements HIT_STAGES = 1 only");
  end

  typedef enum logic [1:0] {IDLE, REQUEST, RESPONSE, DELIVER} state_e;

  state_e state_q;
  logic [SETS-1:0][WAYS-1:0] valid_q;
  logic [SETS-1:0] lru_q;                          // the least recently used way of each set
  logic [WAYS-1:0] valid_snap_q;
  logic stage_valid_q, stage_prefetch_q, prefetch_pending_q, demand_valid_q, invalidated_q, fault_q;
  logic deliver_last_q, fatal_q;
  logic [26:0] stage_line_q, prefetch_line_q, demand_line_q, mshr_line_q;
  logic [255:0] line_q;
  logic [3:0] transaction_q;
  wire [WAYS-1:0][TAG_BITS-1:0] read_tag;
  wire [WAYS-1:0][255:0] read_data;

  // read port: a lookup every cycle it is presented, the pending prefetch check otherwise
  wire prefetch_read = prefetch_pending_q && !lookup_valid_i && !prefetch_cancel_i;
  wire [26:0] read_line = lookup_valid_i ? lookup_line_i : prefetch_line_q;

  // decision, one cycle after the read, from the tags and the valid bits read at the same edge (T7-A1)
  wire [INDEX_BITS-1:0] stage_set = stage_line_q[INDEX_BITS-1:0];
  wire [INDEX_BITS-1:0] mshr_set = mshr_line_q[INDEX_BITS-1:0];
  wire [WAYS-1:0] hit_way;
  for (genvar w = 0; w < WAYS; w++) begin : g_hit
    assign hit_way[w] = valid_snap_q[w] && read_tag[w] == stage_line_q[26 -: TAG_BITS];
  end
  wire hit = |hit_way;
  // a set read at an install edge, or decided in an install cycle, may lack the line being installed (T7-A2)
  wire install_race = (state_q == DELIVER || deliver_last_q) && stage_set == mshr_set;
  wire stage_miss = stage_valid_q && !hit && !install_race && !(stage_prefetch_q && prefetch_cancel_i);
  wire demand_miss = stage_miss && !stage_prefetch_q;
  assign hit_valid_o = stage_valid_q && !stage_prefetch_q && hit && !fatal_q;
  assign hit_data_o = hit_way[0] ? read_data[0] : read_data[1];
  assign miss_o = demand_miss && !fatal_q;
  assign prefetch_hit_o = stage_valid_q && stage_prefetch_q && hit && !fatal_q;

  // the newest demand miss starts first, then a demand left waiting, then a prefetch that missed
  wire idle = state_q == IDLE;
  wire start = idle && (stage_miss || demand_valid_q);
  wire [26:0] start_line = demand_valid_q && !demand_miss ? demand_line_q : stage_line_q;
  assign prefetch_ready_o = idle && !prefetch_pending_q && !(stage_valid_q && stage_prefetch_q) && !fatal_q;

  // delivery and install, one cycle after the response, from line_q
  wire deliver = state_q == DELIVER && demand_valid_q && demand_line_q == mshr_line_q && !invalidated_q;
  assign fill_valid_o = deliver && !fault_q && !fatal_q;
  assign fill_fault_o = deliver && fault_q && !fatal_q;
  assign fill_data_o = line_q;
  assign fill_line_o = mshr_line_q;
  wire install_go = state_q == DELIVER && !fault_q && !invalidated_q && !fatal_q;
  wire install_way = !valid_q[mshr_set][0] ? 1'b0 : !valid_q[mshr_set][1] ? 1'b1 : lru_q[mshr_set];
  l1_cache_array #(.SETS(SETS), .WAYS(WAYS), .TAG_BITS(TAG_BITS)) u_array (
    .clk_i, .rst_i, .read_set_i(read_line[INDEX_BITS-1:0]), .write_i(install_go), .write_tag_i(1'b1),
    .write_set_i(mshr_set), .write_way_i(install_way), .write_tag_value_i(mshr_line_q[26 -: TAG_BITS]),
    .write_byte_mask_i('1), .write_data_i(line_q), .read_tag_o(read_tag), .read_data_o(read_data));

  // memory port: one transaction at a time, requested from state and never withdrawn
  assign mem_request_valid_o = state_q == REQUEST && !fatal_q;
  assign mem_response_ready_o = state_q == RESPONSE && !fatal_q;
  wire malformed = mem_response_valid_i && (state_q != RESPONSE || mem_response_i.transaction_id != transaction_q
    || !(mem_response_i.status inside {MEM_STATUS_OK, MEM_STATUS_ACCESS_FAULT})
    || mem_response_i.uncached_read_data != 0
    || (mem_response_i.status != MEM_STATUS_OK && mem_response_i.line_read_data != 0));
  wire responded = mem_response_valid_i && state_q == RESPONSE && !malformed;
  always_comb begin
    mem_request_o = '0;
    if (mem_request_valid_o) begin
      mem_request_o.transaction_id = transaction_q;
      mem_request_o.address = {mshr_line_q, 5'd0};
    end
  end
  assign busy_o = fatal_q || !idle || demand_valid_q || prefetch_pending_q || stage_valid_q;
  assign fatal_o = fatal_q;

  // no reset: each is read only under a reset valid bit or state. line_q takes the response bus every cycle; only
  // the value taken at the response edge is used, in DELIVER
  always_ff @(posedge clk_i) begin
    stage_prefetch_q <= !lookup_valid_i;
    stage_line_q <= read_line;
    valid_snap_q <= valid_q[read_line[INDEX_BITS-1:0]] & {WAYS{!invalidate_i}};
    line_q <= mem_response_i.line_read_data;
    fault_q <= mem_response_i.status == MEM_STATUS_ACCESS_FAULT;
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= IDLE;
      {valid_q, lru_q} <= '0;
      {stage_valid_q, prefetch_pending_q, demand_valid_q, invalidated_q, deliver_last_q, fatal_q} <= '0;
      transaction_q <= '0;
    end else begin
      // stage and prefetch check; a prefetch that missed in an install window is dropped
      stage_valid_q <= lookup_valid_i || prefetch_read;
      if (prefetch_valid_i && prefetch_ready_o) prefetch_line_q <= prefetch_line_i;
      prefetch_pending_q <= (prefetch_valid_i && prefetch_ready_o)
        || (prefetch_pending_q && lookup_valid_i && !prefetch_cancel_i);

      // demand: set by a miss, cleared when its fill or fault is delivered
      if (deliver) demand_valid_q <= 0;
      if (demand_miss) {demand_valid_q, demand_line_q} <= {1'b1, stage_line_q};

      // line state; an invalidate in an install cycle wins over the install
      if (stage_valid_q && hit) lru_q[stage_set] <= !hit_way[1];
      if (install_go) begin
        valid_q[mshr_set][install_way] <= 1;
        lru_q[mshr_set] <= !install_way;
      end
      if (invalidate_i) valid_q <= '0;

      // transaction; the invalidated mark belongs to the transaction in flight at the invalidate (T7-A4)
      invalidated_q <= !idle && (invalidated_q || invalidate_i);
      deliver_last_q <= state_q == DELIVER;
      if (responded) transaction_q <= transaction_q + 1'b1;
      if (malformed) fatal_q <= 1;
      case (state_q)
        IDLE: if (start) begin
          mshr_line_q <= start_line;
          state_q <= REQUEST;
        end
        REQUEST: if (mem_request_ready_i) state_q <= RESPONSE;
        RESPONSE: if (responded) state_q <= DELIVER;
        default: state_q <= IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // a bus error on a fill is precise (fill_fault_o); only a protocol error is fatal, and it is named once
  always_ff @(posedge clk_i)
    if (!rst_i && !fatal_q && malformed)
      $display("IC_PROTOCOL status=%0d id=%0d", mem_response_i.status, mem_response_i.transaction_id);
`endif
endmodule
`default_nettype wire
