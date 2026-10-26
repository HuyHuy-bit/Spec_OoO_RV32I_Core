`default_nettype none
// store_buffer against a queue model: directed fill, hold and push-in-pop-cycle steps, then random traffic.
// Every output is compared with the model before each edge. +negative=push_full|pop_empty breaks the contract.
module store_buffer_tb;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic push = 0, done = 0;
  logic [31:0] push_address = 0, push_data = 0;
  logic [3:0] push_mask = 0;
  wire push_ready, drain_valid, empty;
  wire [31:0] drain_address, drain_data;
  wire [3:0] drain_mask, entry_valid;
  wire [3:0][31:0] entry_address, entry_data;
  wire [3:0][3:0] entry_mask;
  typedef struct packed {
    logic [31:0] address, data;
    logic [3:0] mask;
  } entry_t;
  entry_t model [$];
  int pushes = 0, pops = 0, both = 0, full = 0, held = 0;
  string negative;

  store_buffer dut (
    .clk_i(clk), .rst_i(rst), .push_i(push), .push_address_i(push_address), .push_data_i(push_data),
    .push_mask_i(push_mask), .drain_done_i(done),
    .push_ready_o(push_ready), .drain_valid_o(drain_valid), .drain_address_o(drain_address),
    .drain_data_o(drain_data), .drain_mask_o(drain_mask), .empty_o(empty),
    .entry_valid_o(entry_valid), .entry_address_o(entry_address), .entry_data_o(entry_data),
    .entry_mask_o(entry_mask)
  );

  task automatic check();
    if (empty != (model.size() == 0) || drain_valid != (model.size() != 0) || push_ready != (model.size() < 4))
      $fatal(1, "FAIL occupancy %0d: empty=%0d drain_valid=%0d push_ready=%0d", model.size(), empty, drain_valid,
             push_ready);
    for (int k = 0; k < 4; k++) begin
      if (entry_valid[k] != (k < model.size())) $fatal(1, "FAIL entry %0d valid=%0d with %0d stored", k,
                                                         entry_valid[k], model.size());
      if (k < model.size() && entry_t'({entry_address[k], entry_data[k], entry_mask[k]}) != model[k])
        $fatal(1, "FAIL entry %0d is not the %0d-th oldest store", k, k);
    end
    if (model.size() != 0 && entry_t'({drain_address, drain_data, drain_mask}) != model[0])
      $fatal(1, "FAIL drain is not the oldest store");
  endtask

  // one cycle: drive, compare, clock, then update the model as the buffer should have
  task automatic step(input logic p, input logic d);
    push = p;
    done = d;
    push_address = $urandom;
    push_data = $urandom;
    push_mask = 4'($urandom_range(1, 15));
    #1 check();
    if (p && d) both++;
    if (model.size() == 4) full++;
    if (model.size() != 0 && !d) held++;
    @(posedge clk);
    if (d) begin model.pop_front(); pops++; end
    if (p) begin model.push_back(entry_t'({push_address, push_data, push_mask})); pushes++; end
    #1;
  endtask

  initial begin
    if (!$value$plusargs("negative=%s", negative)) negative = "";
    repeat (2) @(posedge clk);
    #1 rst = 0;
    check();
    if (negative == "pop_empty") step(0, 1);
    // fill: FIFO order, full, and the head held while no write lands
    for (int n = 0; n < 4; n++) step(1, 0);
    if (negative == "push_full") step(1, 0);
    repeat (3) step(0, 0);
    // push in a pop cycle at every occupancy below full, then drain
    step(0, 1);
    step(1, 1);
    step(0, 1);
    step(1, 1);
    step(0, 1);
    step(1, 1);
    step(0, 1);
    step(1, 0);
    step(1, 1);
    step(0, 1);
    // random traffic within the contract: pushes only when ready, pops only with a head
    for (int n = 0; n < 20000; n++)
      step(model.size() < 4 && $urandom_range(0, 1) == 1, model.size() != 0 && $urandom_range(0, 2) == 0);
    while (model.size() != 0) step(0, 1);
    check();
    $display("PASS pushes=%0d pops=%0d both=%0d full=%0d held=%0d", pushes, pops, both, full, held);
    $finish;
  end
endmodule
`default_nettype wire
