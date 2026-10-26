`default_nettype none
// load_store_unit with DCACHE=1: squashed loads whose cache responses or misses outlive them.
module load_store_unit_dcache_tb;
  import memory_protocol_pkg::*;
  import commit_event_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic flush = 0, recover = 0, hold = 0, issue = 0, allocate = 0;
  logic [4:0] recover_slot = 0;
  logic [12:0] id = 0;
  logic [31:0] instruction = 0, base = 0;
  mem_request_t request, unused_request;
  mem_response_t response;
  wire request_valid, response_ready, complete_valid, busy, fatal, unused_wire;
  wire [12:0] complete_id;
  commit_event_t event_out;
  localparam logic [31:0] LW0 = 32'h00012283, LW4 = 32'h00412283;  // lw x5, 0(x2) / lw x5, 4(x2)
  assign unused_request = '0;

  // memory: one transaction at a time; line word w of line L reads as L + 4w; hold delays the response
  logic pending = 0;
  logic [3:0] pending_id;
  logic [31:0] pending_address;
  wire request_ready = !pending;
  always_comb begin
    response = '0;
    response.transaction_id = pending_id;
    response.status = MEM_STATUS_OK;
    for (int w = 0; w < 8; w++) response.line_read_data[32*w +: 32] = pending_address + 32'(4*w);
    if (request.write) response.line_read_data = '0;
  end
  wire response_valid = pending && !hold;
  always_ff @(posedge clk) begin
    if (response_valid && response_ready) pending <= 0;
    if (request_valid && request_ready) begin
      if (request.uncached) $fatal(1, "TB_UNCACHED_REQUEST");
      pending <= 1;
      pending_id <= request.transaction_id;
      pending_address <= request.address;
    end
  end

  // completions are taken at once and recorded
  int completions = 0;
  logic [12:0] last_id;
  logic [31:0] last_value;
  always_ff @(posedge clk) if (rst) completions <= 0;
  else if (complete_valid) begin
    completions <= completions + 1;
    last_id <= complete_id;
    last_value <= event_out.rd_value;
  end

  load_store_unit #(.DCACHE(1)) dut (
    .clk_i(clk), .rst_i(rst), .flush_i(flush), .recover_i(recover), .recover_slot_i(recover_slot),
    .head_valid_i(1'b1), .head_id_i(13'd0),
    .allocate_valid_i({1'b0, allocate}), .allocate_memory_i({1'b0, allocate}), .allocate_store_i(2'b00),
    .allocate_ready_o(unused_wire), .allocate_i({1'b0, allocate}), .allocate_id_i({13'd0, id}),
    .allocate_instruction_i(instruction), .allocate_pc_i(32'h40), .allocate_sources_i(12'd2),
    .issue_i(issue), .issue_id_i(id), .issue_instruction_i(instruction), .issue_pc_i(32'h40),
    .source1_i(base), .source2_i(32'd0), .retire_i(1'b0), .clean_i(1'b0),
    .head_memory_o(), .head_instruction_o(), .head_sources_o(), .issue_allowed_i(1'b1),
    .committed_valid_i(1'b0), .committed_address_i(32'd0), .committed_data_i(32'd0), .committed_mask_i(4'd0),
    .complete_valid_o(complete_valid), .complete_id_o(complete_id), .complete_event_o(event_out),
    .complete_take_i(complete_valid), .busy_o(busy), .fatal_o(fatal), .write_done_o(), .store_buffer_full_o(), .store_buffer_pending_o(),
    .write_address_o(), .write_data_o(), .write_mask_o(), .clean_done_o(),
    .head_request_valid_i(1'b0), .head_request_ready_o(), .head_request_i(unused_request),
    .head_response_valid_o(), .head_response_ready_i(1'b0),
    .request_valid_o(request_valid), .request_ready_i(request_ready), .request_o(request),
    .response_valid_i(response_valid), .response_ready_o(response_ready), .response_i(response)
  );

  task automatic step();
    @(posedge clk); #1;
  endtask

  task automatic restart();
    rst = 1;
    repeat (2) @(posedge clk);
    #1 rst = 0;
  endtask

  // allocate and issue one load {generation, slot}; head is slot 0
  task automatic load(input logic [12:0] load_id, input logic [31:0] word, input logic [31:0] address);
    id = load_id; instruction = word; base = address;
    allocate = 1;
    @(posedge clk); #1 allocate = 0; issue = 1;
    @(posedge clk); #1 issue = 0;
  endtask

  // squash every slot younger than slot 0 for one cycle
  task automatic squash();
    recover = 1; recover_slot = 0;
    @(posedge clk); #1 recover = 0;
  endtask

  // only once the load has reached the cache: a load waiting in the queue does not count as busy
  task automatic wait_idle(input string name);
    for (int n = 0; n < 60 && busy; n++) step();
    // the unit stays busy while the cache is, so identity recycling waits for a squashed load's miss
    if (busy || fatal || dut.cached.dcache.busy_o) $fatal(1, "%s busy=%b fatal=%b", name, busy, fatal);
  endtask

  task automatic wait_refill();
    for (int n = 0; n < 10 && !pending; n++) step();
    if (!pending) $fatal(1, "no refill request");
  endtask

  task automatic expect_completion(input string name, input int count, input logic [12:0] expected_id,
                                   input logic [31:0] value);
    for (int n = 0; n < 100 && completions < count; n++) step();
    wait_idle(name);
    if (completions != count || last_id != expected_id || last_value != value)
      $fatal(1, "%s completions=%0d id=%h value=%h", name, completions, last_id, last_value);
  endtask

  initial begin
    // response_same_cycle_as_recovery: a hit answers in the cycle its load is squashed
    restart();
    load({8'd0, 5'd1}, LW0, 32'h8000);
    expect_completion("WARM", 1, {8'd0, 5'd1}, 32'h8000);
    load({8'd0, 5'd2}, LW4, 32'h8000);
    for (int n = 0; n < 10 && !dut.cached.dcache.response_valid_o; n++) step();
    if (!dut.cached.dcache.response_valid_o || dut.cached.dcache.response_id_o != {8'd0, 5'd2})
      $fatal(1, "RECOVERY_RACE_SETUP");
    squash();
    wait_idle("RECOVERY_RACE");
    if (completions != 1) $fatal(1, "RECOVERY_RACE completed a squashed load");

    // zombie_response_after_slot_reuse: the squashed miss answers after its slot holds a new load
    restart();
    hold = 1;
    load({8'd0, 5'd1}, LW0, 32'h9000);
    wait_refill();
    squash();
    load({8'd1, 5'd1}, LW4, 32'h9000);
    repeat (3) step();
    hold = 0;
    expect_completion("ZOMBIE", 1, {8'd1, 5'd1}, 32'h9004);

    // identity_recycle_with_dcache_miss_outstanding: busy covers a squashed load's miss until it drains
    restart();
    hold = 1;
    load({8'd0, 5'd1}, LW0, 32'ha000);
    wait_refill();
    squash();
    repeat (8) begin
      step();
      if (!busy) $fatal(1, "RECYCLE busy dropped under an outstanding miss");
    end
    hold = 0;
    wait_idle("RECYCLE");
    if (completions != 0) $fatal(1, "RECYCLE completed a squashed load");

    // a flush under a miss: the cache drops the load one cycle later and the next load still completes
    hold = 1;
    load({8'd0, 5'd3}, LW0, 32'hb000);
    wait_refill();
    flush = 1;
    step();
    flush = 0;
    hold = 0;
    wait_idle("FLUSH");
    load({8'd1, 5'd3}, LW4, 32'hb000);
    expect_completion("FLUSH", 1, {8'd1, 5'd3}, 32'hb004);
    $display("PASS");
    $finish;
  end
endmodule
`default_nettype wire
