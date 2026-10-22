`default_nettype none
// execution backend: decode, issue queue, alu/branch producers, head system/memory service and early loads.
module execution_backend #(parameter bit SYSTEM_SERVICE = 0, parameter bit MEMORY_SERVICE = 0,
  parameter bit EARLY_LOADS = 0) (
  // inputs
  input  wire clk_i, rst_i, flush_i, drained_i,
  input  wire [1:0] valid_i,
  input  wire [63:0] instruction_i, pc_i, predicted_pc_i,
  input  wire [1:0] predicted_taken_i,
  input  wire [23:0] predicted_checkpoint_i,
  input  wire [1:0] frontend_fault_i,
  input  wire [63:0] frontend_cause_i, frontend_value_i,
  input  wire [1:0] execution_ready_i, completion_enable_i, retire_ready_i,
  input  wire resolve_grant_i,
  input  wire trap_ready_i,
  input  wire cancel_system_i,
  input  wire memory_issue_allowed_i, admit_valid_i,
  input  wire [12:0] admit_id_i,
  input  wire data_request_ready_i,
  input  wire data_response_valid_i,
  input  memory_protocol_pkg::mem_response_t data_response_i,

  // outputs
  output wire [1:0] supported_o, allocate_accept_o,
  output wire [25:0] allocate_id_o,
  output wire [11:0] redirect_checkpoint_o,
  output wire resolve_valid_o, resolve_accept_o, resolve_taken_o, resolve_mispredict_o,
  output wire [12:0] resolve_id_o,
  output wire [31:0] resolve_pc_o,
  output wire redirect_o,
  output wire [1:0] issue_o, producer_busy_o,
  output wire [25:0] issue_id_o,
  output wire [1:0] completion_valid_o, completion_accept_o, wb_accept_o,
  output wire [25:0] completion_id_o,
  output commit_event_pkg::commit_event_t [1:0] completion_event_o,
  output wire [1:0] retire_valid_o, retire_accept_o,
  output commit_event_pkg::commit_event_t [1:0] retire_event_o,
  output wire trap_accept_o,
  output wire fault_pending_o,
  output commit_event_pkg::commit_event_t fault_event_o,
  output wire system_prepare_o, system_busy_o, system_redirect_o,
  output wire [31:0] system_redirect_pc_o,
  output wire system_trap_valid_o,
  output commit_event_pkg::commit_event_t system_trap_event_o,
  output wire admission_valid_o,
  output wire [12:0] admission_id_o,
  output wire [31:0] admission_address_o, admission_data_o,
  output wire [3:0] admission_mask_o,
  output wire [1:0] admission_size_o,
  output wire memory_prepare_o, memory_busy_o, memory_committed_o, memory_irrevocable_o, memory_fatal_o,
  output wire data_request_valid_o,
  output memory_protocol_pkg::mem_request_t data_request_o,
  output wire data_response_ready_o,
  output wire [12:0] head_id_o,
  output wire [5:0] occupancy_o,
  output wire [4:0] issue_occupancy_o,
  output wire [7:0] checkpoint_valid_o,
  output wire identity_drain_o
);
  import core_pkg::*;
  decoded_t [1:0] decoded;
  wire [9:0] rs1, rs2, rd;
  wire [1:0] cfi, selected, producer_ready, system_op, memory_op, serial_op, admitted, dispatch_solo;
  wire [5:0] rename_source, rename_source2, unused_rename_source, unused_rename_source2;
  wire [1:0] read_ready, unused_read_ready;
  wire head_valid, head_read, serial_offer, serial_accept, illegal_offer, illegal_accept, backend_trap_ready;
  wire [12:0] serial_id, illegal_id;
  wire [31:0] head_pc;
  commit_event_pkg::commit_event_t serial_event, illegal_event;
  wire [1:0] backend_complete_accept;
  wire memory_serial_offer, memory_fault_offer, memory_trap_ready, memory_read;
  wire [12:0] memory_serial_id, memory_fault_id;
  commit_event_pkg::commit_event_t memory_serial_event, memory_fault_event;
  wire raw_offer = illegal_offer || memory_fault_offer;
  wire [12:0] raw_id = memory_fault_offer ? memory_fault_id : illegal_id;
  commit_event_pkg::commit_event_t raw_event;
  assign raw_event = memory_fault_offer ? memory_fault_event : illegal_event;
  assign serial_op = system_op | memory_op;
  wire [1:0] backend_complete_offer = raw_offer ? {1'b0, completion_enable_i[0]} : completion_valid_o & completion_enable_i;
  wire [25:0] backend_complete_id = raw_offer ? {13'd0, raw_id} : completion_id_o;
  wire [1:0] backend_complete_solo = raw_offer ? 2'b01 : 2'b00;
  wire [11:0] system_sources;
  commit_event_pkg::commit_event_t [1:0] backend_complete_event;
  assign backend_complete_event = raw_offer ? {commit_event_pkg::commit_event_t'('0), raw_event} : completion_event_o;
  assign completion_accept_o = raw_offer ? 2'b00 : backend_complete_accept;
  assign illegal_accept = illegal_offer && backend_complete_accept[0];
  wire [3:0] eligible;
  wire [127:0] issue_payload, read_data;
  logic [31:0] prediction_pc_q [32];
  logic [31:0] prediction_taken_q;
  logic [11:0] prediction_checkpoint_q [32];
  assign redirect_checkpoint_o = prediction_checkpoint_q[resolve_id_o[4:0]];
  wire [127:0] payload;
  wire [63:0] executable_instruction;
  commit_event_pkg::commit_event_t [1:0] producer_event;
  wire alu1_valid, lsu_issue, lsu_complete, lsu_allocate_ready, lsu_head_memory;
  wire [12:0] alu1_id, lsu_complete_id;
  commit_event_pkg::commit_event_t alu1_event, lsu_event;
  // issue port 1 carries both alu work and load/store address generation.
  assign lsu_issue = EARLY_LOADS && issue_o[1] && issue_payload[70:64] inside {7'h03, 7'h23};
  assign completion_valid_o[1] = alu1_valid || lsu_complete;
  assign completion_id_o[25:13] = lsu_complete ? lsu_complete_id : alu1_id;
  assign producer_event[1] = lsu_complete ? lsu_event : alu1_event;
  logic [31:0] fault_q;
  logic [31:0] fault_instruction_q [32], fault_pc_q [32], fault_cause_q [32], fault_value_q [32];
  wire producer_flush = flush_i || trap_accept_o;
  wire cancel_alu1 = redirect_o && 5'(alu1_id[4:0] - head_id_o[4:0])
      > 5'(resolve_id_o[4:0] - head_id_o[4:0]);

  assign selected = {valid_i[1] && !cfi[0] && !frontend_fault_i[0], valid_i[0]};
  assign resolve_id_o = completion_id_o[12:0];
  assign producer_busy_o[1] = completion_valid_o[1];

  // instruction decode and dispatch
  for (genvar lane = 0; lane < 2; lane++) begin : lanes
    assign executable_instruction[lane*32 +: 32] = frontend_fault_i[lane] ? 32'h00000013 : instruction_i[lane*32 +: 32];
    assign payload[lane*64 +: 64] = {frontend_fault_i[lane] ? 32'd0 : pc_i[lane*32 +: 32], executable_instruction[lane*32 +: 32]};
    decoder decode (.instruction_i(executable_instruction[lane*32 +: 32]), .decoded_o(decoded[lane]));
    assign system_op[lane] = SYSTEM_SERVICE && !frontend_fault_i[lane] && (decoded[lane].op inside {OP_CSR, OP_MRET, OP_WFI}
      || (MEMORY_SERVICE && decoded[lane].op inside {OP_FENCE, OP_FENCE_I}));
    assign memory_op[lane] = MEMORY_SERVICE && !frontend_fault_i[lane] && decoded[lane].op inside {OP_LOAD, OP_STORE};
    assign cfi[lane] = decoded[lane].op inside {OP_BRANCH, OP_JAL, OP_JALR};
    assign supported_o[lane] = frontend_fault_i[lane] || ((cfi[lane] || serial_op[lane] || decoded[lane].op inside {OP_ALU, OP_LUI, OP_AUIPC})
      && pc_i[lane*32 +: 2] == 0);
    assign rs1[lane*5 +: 5] = decoded[lane].rs1;
    assign rs2[lane*5 +: 5] = decoded[lane].rs2;
    assign rd[lane*5 +: 5] = decoded[lane].rd;
    assign eligible[lane*2 +: 2] = cfi[lane] ? 2'b01 : EARLY_LOADS && memory_op[lane] ? 2'b10 : 2'b11;
  end

  // prediction and fault metadata
  // per-slot side tables: frontend-fault metadata and the prediction each branch was fetched with.
  always_ff @(posedge clk_i) begin
    for (int lane = 0; lane < 2; lane++) begin
      automatic logic [4:0] slot = allocate_id_o[lane*13 +: 5];
      if (allocate_accept_o[lane]) begin
        fault_q[slot] <= frontend_fault_i[lane];
        if (frontend_fault_i[lane]) begin
          fault_instruction_q[slot] <= instruction_i[lane*32 +: 32];
          fault_pc_q[slot] <= pc_i[lane*32 +: 32];
          fault_cause_q[slot] <= frontend_cause_i[lane*32 +: 32];
          fault_value_q[slot] <= frontend_value_i[lane*32 +: 32];
        end
      end
      if (allocate_accept_o[lane] && cfi[lane]) begin
        prediction_pc_q[slot] <= predicted_pc_i[lane*32 +: 32];
        prediction_taken_q[slot] <= predicted_taken_i[lane];
        prediction_checkpoint_q[slot] <= predicted_checkpoint_i[lane*12 +: 12];
      end
    end
  end

  // frontend fault completion
  // fault tokens carry saved metadata to the rob without a result.
  always_comb begin
    completion_event_o = producer_event;
    for (int lane = 0; lane < 2; lane++) begin
      automatic logic [4:0] slot = completion_id_o[lane*13 +: 5];
      if (fault_q[slot]) begin
        completion_event_o[lane] = '0;
        completion_event_o[lane].valid = 1;
        completion_event_o[lane].privilege = 3;
        completion_event_o[lane].instruction = fault_instruction_q[slot];
        completion_event_o[lane].pc_before = fault_pc_q[slot];
        completion_event_o[lane].pc_after = fault_pc_q[slot];
        completion_event_o[lane].trap = 1;
        completion_event_o[lane].trap_cause = fault_cause_q[slot];
        completion_event_o[lane].trap_value = fault_value_q[slot];
      end
    end
  end

  // port zero execution and branch resolution
  // port 0: branches, jumps and alu ops; the only port that resolves predictions.
  control_flow_pipeline producer0 (
    .clk_i, .rst_i, .flush_i(producer_flush), .launch_i(issue_o[0]), .ready_o(producer_ready[0]), .busy_o(producer_busy_o[0]),
    .id_i(issue_id_o[12:0]), .instruction_i(issue_payload[31:0]), .pc_i(issue_payload[63:32]),
    .source1_i(read_data[31:0]), .source2_i(read_data[63:32]),
    .predicted_taken_i(prediction_taken_q[issue_id_o[4:0]]), .predicted_pc_i(prediction_pc_q[issue_id_o[4:0]]),
    .valid_o(completion_valid_o[0]), .id_o(completion_id_o[12:0]), .event_o(producer_event[0]),
    .take_i(completion_accept_o[0]), .resolve_valid_o, .taken_o(resolve_taken_o),
    .mispredict_o(resolve_mispredict_o), .next_pc_o(resolve_pc_o), .resolve_take_i(resolve_accept_o)
  );

  // port one alu execution
  // only port zero resolves; cancel a younger held port-one result.
  alu_pipeline producer1 (
    .clk_i, .rst_i, .flush_i(producer_flush || cancel_alu1), .launch_i(issue_o[1] && !lsu_issue), .ready_o(producer_ready[1]),
    .id_i(issue_id_o[25:13]), .instruction_i(issue_payload[95:64]), .pc_i(issue_payload[127:96]),
    .source1_i(read_data[95:64]), .source2_i(read_data[127:96]),
    .valid_o(alu1_valid), .id_o(alu1_id), .event_o(alu1_event),
    .take_i(completion_accept_o[1] && !lsu_complete)
  );

  if (SYSTEM_SERVICE) begin : systems
    wire descriptor_busy, killed, owner_valid, owner_memory, system_offer, system_trap_valid;
    wire [12:0] system_serial_id;
    commit_event_pkg::commit_event_t system_serial_event, system_trap_event;
    wire [12:0] system_id;
    wire [31:0] system_instruction, owner_pc;
    wire [11:0] dispatch_sources, lsu_head_sources;
    wire [31:0] lsu_head_instruction, lsu_head_pc;
    wire memory_head = EARLY_LOADS ? lsu_head_memory : owner_memory && system_id == head_id_o;
    assign system_sources = EARLY_LOADS && memory_read ? lsu_head_sources : dispatch_sources;
    assign head_read = (owner_valid && !owner_memory) || memory_read;
    assign serial_offer = system_offer || memory_serial_offer;
    assign serial_id = memory_serial_offer ? memory_serial_id : system_serial_id;
    assign serial_event = memory_serial_offer ? memory_serial_event : system_serial_event;
    assign system_trap_valid_o = system_trap_valid && (!memory_head || memory_trap_ready);
    assign system_trap_event_o = system_trap_valid_o ? system_trap_event : '0;

    // serialized dispatch ownership
    head_dispatch #(.HOLD_MEMORY(!EARLY_LOADS)) dispatch (
      .clk_i, .rst_i, .flush_i(flush_i || trap_accept_o || cancel_system_i), .drained_i,
      .valid_i(selected), .serial_i(serial_op), .cfi0_i(cfi[0]), .memory_i(memory_op[0]),
      .instruction_i(instruction_i[31:0]), .pc_i(pc_i[31:0]),
      .dispatch_valid_o(admitted), .dispatch_solo_o(dispatch_solo),
      .allocate_accept_i(allocate_accept_o), .allocate_id_i(allocate_id_o[12:0]), .source1_i(rename_source[5:0]), .source2_i(rename_source2),
      .queue_dispatch_o(), .head_valid_i(head_valid), .head_id_i(head_id_o), .head_pc_i(head_pc),
      .recover_i(redirect_o), .recover_slot_i(resolve_id_o[4:0]),
      .retire_accept_i(serial_accept && !(EARLY_LOADS && memory_serial_offer)), .retire_id_i(serial_id),
      .busy_o(descriptor_busy), .owner_valid_o(owner_valid), .killed_o(killed),
      .owner_id_o(system_id), .owner_instruction_o(system_instruction), .owner_pc_o(owner_pc), .owner_sources_o(dispatch_sources), .owner_memory_o(owner_memory)
    );

    // system instructions and trap service
    head_system_controller head (
      .clk_i, .rst_i, .cancel_i(flush_i || cancel_system_i), .retire_accept_i(retire_accept_o),
      .head_valid_i(head_valid), .head_id_i(head_id_o), .head_pc_i(head_pc),
      .system_valid_i(owner_valid && !owner_memory), .system_id_i(system_id), .instruction_i(system_instruction),
      .source_ready_i(read_ready[0]), .source_i(read_data[31:0]), .order_ready_i(!memory_busy_o),
      .prepare_o(system_prepare_o), .busy_o(system_busy_o),
      .fault_valid_i(fault_pending_o), .fault_event_i(fault_event_o),
      .serial_offer_o(system_offer), .serial_id_o(system_serial_id), .serial_event_o(system_serial_event), .serial_accept_i(serial_accept && system_offer),
      .illegal_offer_o(illegal_offer), .illegal_id_o(illegal_id), .illegal_event_o(illegal_event), .illegal_accept_i(illegal_accept),
      .trap_valid_o(system_trap_valid), .trap_event_o(system_trap_event), .trap_accept_i(trap_accept_o),
      .redirect_o(system_redirect_o), .redirect_pc_o(system_redirect_pc_o)
    );
    if (MEMORY_SERVICE) begin : memory_service
      wire [11:0] unused_fatal;
      wire head_busy, head_fatal, head_request_valid, head_request_ready, head_response_valid, head_response_ready;
      memory_protocol_pkg::mem_request_t head_request;
      wire lsu_busy, lsu_fatal;
      wire [31:0] committed_address, committed_data;
      wire [3:0] committed_mask;

      // rob-head memory service
      head_memory_controller memory_head_controller (
        .clk_i, .rst_i, .recovery_i(flush_i || redirect_o || trap_accept_o), .cancel_i(flush_i),
        .memory_valid_i((EARLY_LOADS ? lsu_head_memory : owner_valid && owner_memory) && !cancel_system_i),
        .memory_id_i(EARLY_LOADS ? head_id_o : system_id),
        .instruction_i(EARLY_LOADS ? lsu_head_instruction : system_instruction),
        .pc_i(EARLY_LOADS ? lsu_head_pc : owner_pc),
        .head_valid_i(head_valid), .head_id_i(head_id_o), .head_pc_i(head_pc),
        .source_ready_i(read_ready), .source1_i(read_data[31:0]), .source2_i(read_data[63:32]),
        .issue_allowed_i(memory_issue_allowed_i), .read_request_o(memory_read),
        .prepare_o(memory_prepare_o), .busy_o(head_busy),
        .admission_valid_o, .admission_id_o, .admission_address_o, .admission_data_o,
        .admission_mask_o, .admission_size_o, .admit_valid_i, .admit_id_i,
        .serial_offer_o(memory_serial_offer), .serial_id_o(memory_serial_id), .serial_event_o(memory_serial_event),
        .serial_accept_i(serial_accept && memory_serial_offer),
        .fault_offer_o(memory_fault_offer), .fault_id_o(memory_fault_id), .fault_event_o(memory_fault_event),
        .fault_accept_i(memory_fault_offer && backend_complete_accept[0]),
        .trap_ready_o(memory_trap_ready), .trap_accept_i(trap_accept_o && memory_head),
        .committed_o(memory_committed_o), .committed_address_o(committed_address), .committed_data_o(committed_data),
        .committed_mask_o(committed_mask), .irrevocable_o(memory_irrevocable_o), .fatal_o(head_fatal),
        .fatal_sources_o(unused_fatal[11:8]), .fatal_reason_o(unused_fatal[7:0]),
        .request_valid_o(head_request_valid), .request_ready_i(head_request_ready), .request_o(head_request),
        .response_valid_i(head_response_valid), .response_ready_o(head_response_ready), .response_i(data_response_i)
      );
      assign memory_busy_o = head_busy || lsu_busy;
      assign memory_fatal_o = head_fatal || lsu_fatal;
      if (EARLY_LOADS) begin : early_loads

        // early-load scheduling and execution
        load_store_unit lsu (
          .clk_i, .rst_i, .flush_i(producer_flush), .recover_i(redirect_o), .recover_slot_i(resolve_id_o[4:0]),
          .head_valid_i(head_valid), .head_id_i(head_id_o),
          .allocate_valid_i(admitted), .allocate_memory_i(memory_op),
          .allocate_store_i({decoded[1].op == OP_STORE, decoded[0].op == OP_STORE}),
          .allocate_ready_o(lsu_allocate_ready), .allocate_i(allocate_accept_o), .allocate_id_i(allocate_id_o),
          .allocate_instruction_i(instruction_i[31:0]), .allocate_pc_i(pc_i[31:0]),
          .allocate_sources_i({rename_source2, rename_source[5:0]}),
          .issue_i(lsu_issue), .issue_id_i(issue_id_o[25:13]), .issue_instruction_i(issue_payload[95:64]),
          .issue_pc_i(issue_payload[127:96]), .source1_i(read_data[95:64]), .source2_i(read_data[127:96]),
          .retire_i(retire_accept_o[0]),
          .head_memory_o(lsu_head_memory), .head_instruction_o(lsu_head_instruction), .head_pc_o(lsu_head_pc),
          .head_sources_o(lsu_head_sources), .issue_allowed_i(memory_issue_allowed_i),
          .committed_valid_i(memory_committed_o), .committed_address_i(committed_address),
          .committed_data_i(committed_data), .committed_mask_i(committed_mask),
          .complete_valid_o(lsu_complete), .complete_id_o(lsu_complete_id), .complete_event_o(lsu_event),
          .complete_take_i(completion_accept_o[1] && lsu_complete), .busy_o(lsu_busy), .fatal_o(lsu_fatal),
          .head_request_valid_i(head_request_valid), .head_request_ready_o(head_request_ready),
          .head_request_i(head_request), .head_response_valid_o(head_response_valid),
          .head_response_ready_i(head_response_ready),
          .request_valid_o(data_request_valid_o), .request_ready_i(data_request_ready_i), .request_o(data_request_o),
          .response_valid_i(data_response_valid_i), .response_ready_o(data_response_ready_o), .response_i(data_response_i)
        );
      end else begin : head_only_memory
        assign {lsu_busy, lsu_fatal} = 0;
        wire unused_committed = ^{committed_address, committed_data, committed_mask};
        assign {data_request_valid_o, head_request_ready, head_response_valid, data_response_ready_o}
          = {head_request_valid, data_request_ready_i, data_response_valid_i, head_response_ready};
        assign data_request_o = head_request;
      end
    end
    if (!MEMORY_SERVICE) begin : unused_memory_owner
      wire unused_owner = ^owner_pc ^ read_ready[1] ^ ^lsu_head_instruction ^ ^lsu_head_pc;
    end
    if (!(MEMORY_SERVICE && EARLY_LOADS)) begin : no_lsu_head
      assign {lsu_head_instruction, lsu_head_pc, lsu_head_sources} = 0;
    end
    assign backend_trap_ready = system_trap_valid_o && trap_ready_i;

    // checks
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) if (!rst_i) begin
      assert (!(system_busy_o && redirect_o)) else $fatal(1, "CF_SYSTEM_RECOVERY");
      assert (!(system_offer && memory_serial_offer) && !(illegal_offer && memory_fault_offer))
        else $fatal(1, "CF_HEAD_EXCLUSIVE");
      assert (!memory_irrevocable_o || !redirect_o) else $fatal(1, "CF_MEMORY_RECOVERY");
      assert (!head_read || issue_o == 0) else $fatal(1, "CF_SYSTEM_READ");
      assert (!drained_i || (!descriptor_busy && !system_busy_o && !memory_busy_o)) else $fatal(1, "CF_SYSTEM_DRAIN");
      assert (!killed || !system_prepare_o) else $fatal(1, "CF_SYSTEM_CANCEL");
    end
`endif
  end else begin : no_systems
    wire unused_lsu = lsu_head_memory;
    assign admitted = selected;
    assign dispatch_solo = 0;
    assign head_read = 0;
    assign system_sources = 0;
    assign serial_offer = 0;
    assign serial_id = 0;
    assign serial_event = '0;
    assign illegal_offer = 0;
    assign illegal_id = 0;
    assign illegal_event = '0;
    assign backend_trap_ready = trap_ready_i;
    assign system_prepare_o = 0;
    assign system_busy_o = 0;
    assign system_redirect_o = 0;
    assign system_redirect_pc_o = 0;
    assign system_trap_valid_o = 0;
    assign system_trap_event_o = '0;
    wire unused_system = cancel_system_i ^ head_valid ^ ^head_pc ^ ^rename_source ^ ^rename_source2 ^ ^read_ready
      ^ serial_accept ^ illegal_accept ^ memory_serial_offer ^ memory_trap_ready ^ memory_read ^ ^memory_serial_id
      ^ ^memory_serial_event;
  end

  // disabled-service defaults
  // without early loads, port one completes only alu results.
  if (!(SYSTEM_SERVICE && MEMORY_SERVICE && EARLY_LOADS)) begin : no_early_loads
    assign {lsu_complete, lsu_complete_id, lsu_head_memory} = 0;
    assign lsu_event = '0;
    assign lsu_allocate_ready = 1;
  end

  if (!MEMORY_SERVICE) begin : no_memory
    assign {memory_prepare_o, memory_busy_o, memory_committed_o, memory_irrevocable_o, memory_fatal_o} = 0;
    assign {memory_read, memory_serial_offer, memory_fault_offer, memory_trap_ready} = 0;
    assign {memory_serial_id, memory_fault_id, admission_id_o} = 0;
    assign {memory_serial_event, memory_fault_event, data_request_o} = '0;
    assign {admission_valid_o, admission_address_o, admission_data_o, admission_mask_o, admission_size_o} = 0;
    assign {data_request_valid_o, data_response_ready_o} = 0;
    wire unused_memory = memory_issue_allowed_i ^ admit_valid_i ^ ^admit_id_i ^ data_request_ready_i
      ^ data_response_valid_i ^ ^data_response_i;
  end

  // configuration checks
  if (MEMORY_SERVICE && !SYSTEM_SERVICE) begin : invalid_memory_configuration
    initial $error("MEMORY_SERVICE_REQUIRES_SYSTEM_SERVICE");
  end
  if (EARLY_LOADS && !MEMORY_SERVICE) begin : invalid_early_load_configuration
    initial $error("EARLY_LOADS_REQUIRES_MEMORY_SERVICE");
  end

  // rename, issue and retirement
  issue_backend backend (
    .queue_skip_i(EARLY_LOADS ? system_op : serial_op), .head_read_i(head_read), .head_source_i(system_sources),
    .serial_offer_i(serial_offer), .serial_id_i(serial_id), .serial_event_i(serial_event), .serial_accept_o(serial_accept),
    .clk_i, .rst_i, .flush_i, .drained_i,
    .resources_ready_i((admitted & ~supported_o) == 0 && lsu_allocate_ready),
    .valid_i(admitted), .cfi_i(cfi), .solo_i(dispatch_solo), .rs1_i(rs1), .rs2_i(rs2), .rd_i(rd), .pc_i,
    .eligible_i(eligible), .payload_i(payload), .allocate_accept_o, .allocate_id_o,
    .source1_o({unused_rename_source, rename_source}), .source2_o({unused_rename_source2, rename_source2}), .destination_o(), .stale_o(), .source_ready_o(),
    .complete_offer_i(backend_complete_offer), .complete_solo_i(backend_complete_solo),
    .complete_id_i(backend_complete_id), .complete_event_i(backend_complete_event),
    .complete_accept_o(backend_complete_accept), .wb_accept_o, .wb_destination_o(), .wb_data_o(),
    .resolve_offer_i(resolve_valid_o),
    // a branch may not recover while a head system/memory op or a pending fault owns the head.
    .resolve_grant_i(resolve_grant_i && !(SYSTEM_SERVICE && (system_busy_o || fault_pending_o || memory_irrevocable_o))),
    .mispredict_i(resolve_mispredict_o), .resolve_id_i(resolve_id_o),
    .resolve_accept_o, .branch_recover_o(redirect_o),
    .retire_ready_i, .retire_valid_o, .retire_accept_o,
    .retire_rd_o(), .retire_destination_o(), .retire_stale_o(), .retire_event_o,
    .trap_ready_i(backend_trap_ready), .trap_valid_o(fault_pending_o), .trap_accept_o, .trap_event_o(fault_event_o),
    .port_ready_i(producer_ready & execution_ready_i), .issue_o, .issue_id_o, .issue_destination_o(),
    .issue_source_o(), .issue_payload_o(issue_payload), .read_data_o(read_data), .read_ready_o({unused_read_ready, read_ready}),
    .head_valid_o(head_valid), .head_id_o, .head_pc_o(head_pc), .occupancy_o, .issue_occupancy_o, .identity_drain_o,
    .rat_o(), .committed_o(), .free_o(), .ready_o(),
    .checkpoint_accept_o(), .checkpoint_id_o(), .checkpoint_valid_o, .checkpoint_released_o()
  );

  // checks
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      assert (valid_i != 2'b10) else $fatal(1, "CF_BACKEND_PREFIX");
      assert (!drained_i || producer_busy_o == 0) else $fatal(1, "CF_BACKEND_DRAIN");
      assert (!resolve_accept_o || (resolve_valid_o && resolve_grant_i)) else $fatal(1, "CF_BACKEND_RESOLVE");
      assert (!redirect_o || (allocate_accept_o == 0 && issue_o == 0 && retire_accept_o == 0))
        else $fatal(1, "CF_BACKEND_RECOVERY");
    end
  end
`endif
endmodule
`default_nettype wire
