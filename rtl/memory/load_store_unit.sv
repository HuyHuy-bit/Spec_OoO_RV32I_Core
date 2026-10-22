`default_nettype none
// issue-port-one address generation and early cacheable, idempotent loads.
// loads take fully covering older store bytes (queued or committed) and wait for unknown or partial overlaps.
// stores, uncached loads and faults use the shared rob-head memory path.
module load_store_unit #(parameter bit TRACE = 1) (
  // inputs
  input  wire clk_i, rst_i, flush_i,
  input  wire recover_i,
  input  wire [4:0] recover_slot_i,
  input  wire head_valid_i,
  input  wire [12:0] head_id_i,
  input  wire [1:0] allocate_valid_i, allocate_memory_i, allocate_store_i,
  input  wire [1:0] allocate_i,
  input  wire [25:0] allocate_id_i,
  input  wire [31:0] allocate_instruction_i, allocate_pc_i,
  input  wire [11:0] allocate_sources_i,
  input  wire issue_i,
  input  wire [12:0] issue_id_i,
  input  wire [31:0] issue_instruction_i, issue_pc_i, source1_i, source2_i,
  input  wire retire_i,
  input  wire issue_allowed_i,
  input  wire committed_valid_i,
  input  wire [31:0] committed_address_i, committed_data_i,
  input  wire [3:0] committed_mask_i,
  input  wire complete_take_i,
  input  wire head_request_valid_i,
  input  memory_protocol_pkg::mem_request_t head_request_i,
  input  wire head_response_ready_i,
  input  wire request_ready_i,
  input  wire response_valid_i,
  input  memory_protocol_pkg::mem_response_t response_i,

  // outputs
  output wire allocate_ready_o,
  output wire head_memory_o,
  output wire [31:0] head_instruction_o,
  output wire [11:0] head_sources_o,
  output wire complete_valid_o,
  output wire [12:0] complete_id_o,
  output commit_event_pkg::commit_event_t complete_event_o,
  output wire busy_o, fatal_o,
  output wire head_request_ready_o,
  output wire head_response_valid_o,
  output wire request_valid_o,
  output memory_protocol_pkg::mem_request_t request_o,
  output wire response_ready_o
);
  import core_pkg::*;
  import commit_event_pkg::*;
  import memory_protocol_pkg::*;

  // rob-slot descriptors
  logic [31:0] memory_q, done_q, head_path_q;
  logic [31:0] instruction_q [32], pc_q [32], base_q [32], address_q [32];
  logic [11:0] sources_q [32];
  logic [3:0] mask_q [32];
  wire [4:0] head = head_id_i[4:0];
  assign head_memory_o = head_valid_i && memory_q[head] && done_q[head] && head_path_q[head];
  assign head_instruction_o = instruction_q[head];
  assign head_sources_o = sources_q[head];

  // address generation
  // one registered descriptor per issue, consumed the next cycle.
  wire generated, generated_store, generated_unsigned, generated_head_only, generated_fault, generated_uncached;
  wire [12:0] generated_id;
  wire [31:0] generated_address, generated_data, generated_base;
  wire [3:0] generated_mask;
  wire [1:0] generated_size;
  wire [159:0] unused_descriptor;
  wire unused_ready;
  load_store_prepare agu (
    .clk_i, .rst_i, .flush_i, .launch_i(issue_i), .ready_o(unused_ready),
    .id_i(issue_id_i), .instruction_i(issue_instruction_i), .pc_i(issue_pc_i), .source1_i, .source2_i,
    .valid_o(generated), .take_i(generated), .id_o(generated_id),
    .instruction_o(unused_descriptor[31:0]), .pc_o(unused_descriptor[63:32]),
    .source1_o(generated_base), .source2_o(unused_descriptor[95:64]),
    .address_o(generated_address), .write_data_o(generated_data),
    .cause_o(unused_descriptor[127:96]), .trap_value_o(unused_descriptor[159:128]),
    .byte_mask_o(generated_mask), .size_o(generated_size), .store_o(generated_store),
    .load_unsigned_o(generated_unsigned), .uncached_o(generated_uncached),
    .head_only_o(generated_head_only), .fault_o(generated_fault)
  );

  // dispatch and address-result capture
  // allocation refreshes slot ownership; lane zero also captures instruction metadata.
  always_ff @(posedge clk_i) begin
    for (int lane = 0; lane < 2; lane++)
      if (allocate_i[lane]) begin
        memory_q[allocate_id_i[lane*13 +: 5]] <= allocate_memory_i[lane];
        done_q[allocate_id_i[lane*13 +: 5]] <= 0;
      end
    if (allocate_i[0]) begin
      instruction_q[allocate_id_i[4:0]] <= allocate_instruction_i;
      if (TRACE) pc_q[allocate_id_i[4:0]] <= allocate_pc_i;
      sources_q[allocate_id_i[4:0]] <= allocate_sources_i;
    end
    // a killed slot cannot be reallocated on the descriptor-write cycle.
    if (generated) begin
      done_q[generated_id[4:0]] <= 1;
      head_path_q[generated_id[4:0]] <= generated_store || generated_head_only;
      base_q[generated_id[4:0]] <= generated_base;
      address_q[generated_id[4:0]] <= generated_address;
      mask_q[generated_id[4:0]] <= generated_mask;
    end
  end

  // shared data-port arbitration
  // the early engine and the head path share the data port; an offered request stays selected.
  typedef enum logic [1:0] {IDLE, HEAD, EARLY} owner_e;
  owner_e owner_q;
  logic head_offered_q, early_offered_q;
  wire early_request_valid, early_response_ready;
  mem_request_t early_request;
  wire select_head = owner_q == IDLE && head_request_valid_i && (head_offered_q || !early_offered_q);
  wire select_early = owner_q == IDLE && early_request_valid && !select_head;
  assign request_valid_o = select_head || select_early;
  assign request_o = select_head ? head_request_i : select_early ? early_request : '0;
  assign head_request_ready_o = select_head && request_ready_i;
  wire early_request_ready = select_early && request_ready_i;
  // a stray response goes to the head path, whose engines flag it fatal.
  assign head_response_valid_o = response_valid_i && owner_q != EARLY;
  wire early_response_valid = response_valid_i && owner_q == EARLY;
  assign response_ready_o = owner_q == EARLY ? early_response_ready : head_response_ready_i;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      owner_q <= IDLE;
      head_offered_q <= 0;
      early_offered_q <= 0;
    end else begin
      head_offered_q <= select_head && !request_ready_i;
      early_offered_q <= select_early && !request_ready_i;
      if (head_request_ready_o) owner_q <= HEAD;
      if (early_request_ready) owner_q <= EARLY;
      if (response_valid_i && response_ready_o && owner_q != IDLE) owner_q <= IDLE;
    end
  end

  // load selection and admission
  wire lsq_valid;
  wire [12:0] lsq_id;
  wire [31:0] lsq_address;
  wire [1:0] lsq_size, lsq_ready;
  wire lsq_unsigned;
  wire [3:0] forward_mask, memory_mask;
  wire [31:0] forward_result, unused_forward;
  wire engine_ready, engine_valid, engine_fault, engine_busy;
  wire [12:0] engine_id, engine_owner;
  wire [31:0] engine_data, unused_address, unused_cause, unused_trap_value;
  wire unused_irrevocable;
  // a load reads memory only when no older store owns a requested byte, and completes from the
  // selector when older stores own all of them.
  // shortcut: partial overlaps wait for the store to drain; merge memory and forwarded bytes if they matter for cpi.
  logic forward_valid_q;
  logic [12:0] forward_id_q;
  logic [31:0] forward_data_q;
  wire start_ready = lsq_valid && engine_ready && !forward_valid_q;
  wire launch_memory = start_ready && forward_mask == 0;
  wire launch_forward = start_ready && memory_mask == 0;
  wire launch = launch_memory || launch_forward;
  assign allocate_ready_o = lsq_ready[0];

  // load and store queues
  load_store_queue queues (
    .clk_i, .rst_i, .flush_i, .head_slot_i(head),
    .allocate_load_i(allocate_valid_i & allocate_memory_i & ~allocate_store_i),
    .allocate_store_i(allocate_valid_i & allocate_memory_i & allocate_store_i),
    .allocate_i(allocate_i & allocate_memory_i), .allocate_id_i, .allocate_ready_o(lsq_ready),
    .retire_i({1'b0, retire_i}), .retire_id_i({13'd0, head_id_i}),
    .recover_i, .recover_slot_i,
    .address_i(generated), .address_id_i(generated_id), .address_value_i(generated_address),
    .address_mask_i(generated_mask), .address_size_i(generated_size), .address_unsigned_i(generated_unsigned),
    .address_early_i(!generated_head_only),
    .data_i(generated && generated_store), .data_id_i(generated_id), .data_value_i(generated_data),
    .committed_valid_i, .committed_address_i, .committed_data_i, .committed_mask_i,
    .load_valid_o(lsq_valid), .load_id_o(lsq_id), .load_address_o(lsq_address), .load_size_o(lsq_size),
    .load_unsigned_o(lsq_unsigned), .forward_mask_o(forward_mask), .memory_mask_o(memory_mask),
    .forward_data_o(unused_forward), .result_o(forward_result),
    .memory_word_i(32'd0), .load_take_i(launch)
  );

  // early-load recovery and transaction
  // recovery keeps an older in-flight load; flush or a younger position kills it.
  function automatic logic killed(input logic [4:0] slot);
    return flush_i || (recover_i && 5'(slot - head) > 5'(recover_slot_i - head));
  endfunction
  wire kill = killed(engine_owner[4:0]) && (flush_i || engine_busy);
  load_transaction engine (
    .clk_i, .rst_i, .kill_i(kill), .launch_i(launch_memory), .ready_o(engine_ready),
    .id_i(lsq_id), .address_i(lsq_address), .size_i(lsq_size), .unsigned_i(lsq_unsigned),
    .uncached_i(1'b0), .head_only_i(1'b0), .fault_i(1'b0), .cause_i(32'd0), .trap_value_i(32'd0),
    .issue_allowed_i, .head_valid_i, .head_id_i,
    .request_valid_o(early_request_valid), .request_ready_i(early_request_ready), .request_o(early_request),
    .response_valid_i(early_response_valid), .response_ready_o(early_response_ready), .response_i,
    .valid_o(engine_valid), .take_i(complete_take_i && engine_valid), .id_o(engine_id), .owner_id_o(engine_owner),
    .address_o(unused_address), .data_o(engine_data), .cause_o(unused_cause), .trap_value_o(unused_trap_value),
    .fault_o(engine_fault), .busy_o(engine_busy), .irrevocable_o(unused_irrevocable), .fatal_o
  );

  // forwarded-load result
  always_ff @(posedge clk_i) begin
    if (rst_i || (forward_valid_q && (killed(forward_id_q[4:0]) || complete_take_i))) forward_valid_q <= 0;
    else if (launch_forward) begin
      forward_valid_q <= 1;
      forward_id_q <= lsq_id;
      forward_data_q <= forward_result;
    end
  end
  assign busy_o = !rst_i && (engine_busy || forward_valid_q || owner_q != IDLE || generated);
  assign complete_valid_o = engine_valid || forward_valid_q;
  assign complete_id_o = forward_valid_q ? forward_id_q : engine_id;
  wire [31:0] complete_data = forward_valid_q ? forward_data_q : engine_data;

  // load completion event
  // the event matches what the head path would have retired for the same load.
  always_comb begin
    automatic logic [4:0] slot = complete_id_o[4:0];
    automatic logic [31:0] instruction = instruction_q[slot];
    complete_event_o = '0;
    if (complete_valid_o) begin
      complete_event_o.valid = 1;
      complete_event_o.privilege = 3;
      complete_event_o.instruction = instruction;
      complete_event_o.pc_before = TRACE ? pc_q[slot] : 32'd0;
      complete_event_o.pc_after = TRACE ? pc_q[slot] : 32'd0;
      complete_event_o.rs1_addr = instruction[19:15];
      complete_event_o.rs1_value = base_q[slot];
      if (engine_valid && engine_fault) begin
        complete_event_o.trap = 1;
        complete_event_o.trap_cause = 32'd5;
        complete_event_o.trap_value = address_q[slot];
      end else begin
        complete_event_o.retired = 1;
        complete_event_o.pc_after = TRACE ? pc_q[slot] + 32'd4 : 32'd0;
        complete_event_o.mem_valid = 1;
        complete_event_o.mem_address = address_q[slot];
        complete_event_o.mem_read_mask = mask_q[slot];
        complete_event_o.mem_read_data = (complete_data << {address_q[slot][1:0], 3'b000}) & byte_mask(mask_q[slot]);
        complete_event_o.rd_addr = instruction[11:7];
        complete_event_o.rd_value = instruction[11:7] == 0 ? 32'd0 : complete_data;
        complete_event_o.rd_write_mask = instruction[11:7] == 0 ? 32'd0 : 32'hffffffff;
      end
    end
  end
  wire unused = ^{unused_descriptor, unused_ready, generated_fault, generated_uncached,
                  unused_forward, unused_address, unused_cause, unused_trap_value, unused_irrevocable, lsq_ready[1], engine_owner[12:5]};

  // checks
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) if (!rst_i) begin
    assert (!(select_head && select_early)) else $fatal(1, "LSU_PORT_SELECT");
    assert (!(engine_valid && forward_valid_q)) else $fatal(1, "LSU_COMPLETE_SOURCE");
    assert (!(owner_q != IDLE && request_valid_o)) else $fatal(1, "LSU_PORT_OUTSTANDING");
    assert (!complete_take_i || complete_valid_o) else $fatal(1, "LSU_TAKE");
    assert (!issue_i || issue_instruction_i[6:0] inside {7'h03, 7'h23}) else $fatal(1, "LSU_ISSUE");
    if (generated) assert (memory_q[generated_id[4:0]]) else $fatal(1, "LSU_GENERATED_SLOT");
    // an early load must be a live load whose address generation chose the early path.
    if (launch) assert (memory_q[lsq_id[4:0]] && done_q[lsq_id[4:0]] && !head_path_q[lsq_id[4:0]])
      else $fatal(1, "LSU_EARLY_KIND");
  end
`endif
endmodule
`default_nettype wire
