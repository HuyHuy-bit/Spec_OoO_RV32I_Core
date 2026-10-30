`default_nettype none
// checks speculative reads and both retirement ports against independently generated model state.
module tage_ports_tb;
  logic clk;
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end
  logic rst = 1;
  logic [1:0] valid = 0, branch = 0, path = 0, update = 0, outcome = 0;
  logic [63:0] pc = 0, update_pc = 0;
  logic [31:0] history = 0;
  wire [1:0] prediction;
  tage_predictor #(.AGE_BITS(10), .LOOKUPS(2), .UPDATES(2), .EXTERNAL_HISTORY(1)) dut (
    .clk_i(clk), .rst_i(rst), .lookup_valid_i(valid), .lookup_pc_i(pc), .lookup_history_i(history),
    .lookup_branch_i(branch), .lookup_path_i(path), .lookup_taken_o(prediction),
    .update_valid_i(update), .update_taken_i(outcome), .update_pc_i(update_pc),
    .update_history_i(64'd0), .update_dropped_o(dropped)
  );
  wire [1:0] dropped;
  wire unused = ^dropped;
  initial begin
    automatic string filename, line;
    automatic int fd, count = 0;
    automatic logic [1:0] expected;
    automatic logic [511:0] base;
    automatic logic [3583:0] banks;
    automatic logic [31:0] committed;
    automatic logic [3:0] chooser;
    automatic logic [9:0] age;
    if (!$value$plusargs("stimulus=%s", filename)) $fatal(1, "NO_STIMULUS");
    fd = $fopen(filename, "r");
    if (fd == 0) $fatal(1, "NO_FILE");
    repeat (2) @(posedge clk);
    #1 rst = 0;
    while ($fgets(line, fd) != 0) begin
      if ($sscanf(line, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h", valid, pc, history,
          branch, path, update, outcome, update_pc, expected, base, banks, committed, chooser, age) != 14)
        $fatal(1, "MALFORMED %0d", count);
      #1;
      if (prediction !== expected) $fatal(1, "LOOKUP %0d got=%h expected=%h", count, prediction, expected);
      @(posedge clk); #1;
      if (dut.base_q !== base || dut.table_q !== banks || dut.history_q !== committed
          || dut.chooser_q !== chooser || dut.age_q !== age) $fatal(1, "TRAINING %0d", count);
      count++;
    end
    if (count == 0) $fatal(1, "EMPTY");
    $display("PASS cycles=%0d", count);
    $finish;
  end
endmodule
`default_nettype wire
