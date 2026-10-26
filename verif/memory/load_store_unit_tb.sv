`default_nettype none
// early-load completion, access faults, store-to-load forwarding and arbitration with the rob-head memory path.
module load_store_unit_tb;
  import memory_protocol_pkg::*;
  import commit_event_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [1:0] allocate_valid = 0, allocate_memory = 0, allocate_store = 0, allocate = 0;
  logic [12:0] allocate_id = 0, issue_id = 0;
  logic [31:0] allocate_instruction = 0, store_data = 0;
  logic issue = 0, issue_allowed = 1, request_ready = 0, response_valid = 0;
  logic [31:0] issue_instruction = 0, base = 0;
  mem_response_t response = '0;
  mem_request_t request, unused_request;
  wire allocate_ready, head_memory, complete_valid, busy, fatal, head_request_ready, head_response_valid;
  wire request_valid, response_ready;
  wire [12:0] complete_id;
  wire [31:0] head_instruction;
  wire [11:0] head_sources;
  commit_event_t event_out;
  localparam logic [31:0] LB = 32'h00310283;  // lb x5, 3(x2)
  localparam logic [31:0] SB = 32'h003101a3;  // sb x3, 3(x2)
  localparam logic [31:0] PC = 32'h40, ADDRESS = 32'h8003;
  assign unused_request = '0;
  load_store_unit dut (
    .clk_i(clk), .rst_i(rst), .flush_i(1'b0), .recover_i(1'b0), .recover_slot_i(5'd0),
    .head_valid_i(1'b1), .head_id_i(13'd0),
    .allocate_valid_i(allocate_valid), .allocate_memory_i(allocate_memory), .allocate_store_i(allocate_store),
    .allocate_ready_o(allocate_ready), .allocate_i(allocate), .allocate_id_i({13'd0, allocate_id}),
    .allocate_instruction_i(allocate_instruction), .allocate_pc_i(PC), .allocate_sources_i(12'd2),
    .issue_i(issue), .issue_id_i(issue_id), .issue_instruction_i(issue_instruction), .issue_pc_i(PC),
    .source1_i(base), .source2_i(store_data), .retire_i(1'b0), .clean_i(1'b0),
    .head_memory_o(head_memory), .head_instruction_o(head_instruction),
    .head_sources_o(head_sources), .issue_allowed_i(issue_allowed),
    .committed_valid_i(1'b0), .committed_address_i(32'd0), .committed_data_i(32'd0), .committed_mask_i(4'd0),
    .complete_valid_o(complete_valid), .complete_id_o(complete_id), .complete_event_o(event_out),
    .complete_take_i(complete_valid), .busy_o(busy), .fatal_o(fatal), .write_done_o(), .store_buffer_full_o(), .store_buffer_pending_o(),
    .write_address_o(), .write_data_o(), .write_mask_o(), .clean_done_o(),
    .head_request_valid_i(1'b0), .head_request_ready_o(head_request_ready), .head_request_i(unused_request),
    .head_response_valid_o(head_response_valid), .head_response_ready_i(1'b0),
    .request_valid_o(request_valid), .request_ready_i(request_ready), .request_o(request),
    .response_valid_i(response_valid), .response_ready_o(response_ready), .response_i(response)
  );

  // allocate and issue the load at rob slot 0 (also the head), then wait for its line request.
  task automatic start(input bit hold_for_head);
    rst = 1;
    repeat (2) @(posedge clk);
    #1 rst = 0;
    issue_allowed = !hold_for_head;
    allocate_valid = 2'b01; allocate_memory = 2'b01; allocate = 2'b01; allocate_instruction = LB;
    @(posedge clk); #1 allocate = 0; allocate_valid = 0; allocate_memory = 0;
    issue = 1; issue_instruction = LB; base = 32'h8000;
    @(posedge clk); #1 issue = 0;
    if (hold_for_head) begin
      // launched before issue permission: no request until permission arrives.
      repeat (4) begin
        @(posedge clk); #1 if (request_valid) $fatal(1, "EARLY_REQUEST_BEFORE_PERMISSION");
      end
      issue_allowed = 1;
    end
    for (int n = 0; n < 10 && !request_valid; n++) @(posedge clk);
    #1 if (!request_valid || request.write || request.uncached || request.address != 32'h8000)
      $fatal(1, "REQUEST valid=%b address=%h", request_valid, request.address);
    if (head_memory) $fatal(1, "SETUP head path chosen for a cacheable load");
    request_ready = 1;
    @(posedge clk); #1 request_ready = 0;
  endtask

  task automatic respond(input mem_response_status_e status);
    response = '0;
    response.transaction_id = 4'd0;
    response.status = status;
    if (status == MEM_STATUS_OK) response.line_read_data[3*8 +: 8] = 8'h80;
    response_valid = 1;
    @(posedge clk); #1 response_valid = 0;
    for (int n = 0; n < 4 && !complete_valid; n++) @(posedge clk);
    #1 if (!complete_valid || complete_id != 13'd0) $fatal(1, "COMPLETE valid=%b", complete_valid);
  endtask

  // an older store at slot 0 fully covers the load at slot 1: no memory request, store bytes returned.
  task automatic forward();
    rst = 1;
    repeat (2) @(posedge clk);
    #1 rst = 0;
    allocate_valid = 2'b01; allocate_memory = 2'b01; allocate = 2'b01;
    allocate_store = 2'b01; allocate_instruction = SB; allocate_id = 0;
    @(posedge clk); #1 allocate_store = 0; allocate_instruction = LB; allocate_id = 1;
    @(posedge clk); #1 allocate = 0; allocate_valid = 0; allocate_memory = 0;
    issue = 1; issue_instruction = SB; issue_id = 0; base = 32'h8000; store_data = 32'h80;
    @(posedge clk); #1 issue_instruction = LB; issue_id = 1;
    @(posedge clk); #1 issue = 0;
    for (int n = 0; n < 10 && !complete_valid; n++) begin
      if (request_valid) $fatal(1, "FORWARD_REQUEST");
      @(posedge clk); #1;
    end
    if (!complete_valid || complete_id != 13'd1 || request_valid) $fatal(1, "FORWARD_COMPLETE valid=%b", complete_valid);
    if (!event_out.retired || event_out.rd_value != 32'hffffff80 || event_out.mem_read_data != 32'h80000000
        || event_out.mem_read_mask != 4'b1000 || event_out.instruction != LB)
      $fatal(1, "FORWARD_EVENT rd=%h mem=%h", event_out.rd_value, event_out.mem_read_data);
    @(posedge clk); #1 issue_id = 0; store_data = 0; allocate_id = 0;
  endtask

  initial begin
    forward();
    start(0);
    respond(MEM_STATUS_OK);
    if (!event_out.retired || event_out.trap || event_out.rd_addr != 5 || event_out.rd_value != 32'hffffff80
        || event_out.rd_write_mask != '1 || event_out.mem_address != ADDRESS || event_out.mem_read_mask != 4'b1000
        || event_out.mem_read_data != 32'h80000000 || event_out.pc_before != PC || event_out.pc_after != PC + 4
        || event_out.rs1_addr != 2 || event_out.rs1_value != 32'h8000 || event_out.instruction != LB)
      $fatal(1, "LOAD_EVENT rd=%h mem=%h", event_out.rd_value, event_out.mem_read_data);

    start(0);
    respond(MEM_STATUS_ACCESS_FAULT);
    if (!event_out.trap || event_out.retired || event_out.trap_cause != 5 || event_out.trap_value != ADDRESS
        || event_out.pc_after != PC || event_out.rd_write_mask != 0 || event_out.mem_valid)
      $fatal(1, "FAULT_EVENT cause=%0d value=%h", event_out.trap_cause, event_out.trap_value);

    start(1);
    respond(MEM_STATUS_OK);
    if (fatal) $fatal(1, "FATAL");
    $display("PASS");
    $finish;
  end
endmodule
`default_nettype wire
