`default_nettype none
// return-stack reset, fall-through history and concurrent counter-training checks.
module branch_predictor_tb;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [63:0] pc = 0, instruction = {32'h13, 32'h13}, retire_instruction = 0, retire_pc = 0, retire_next = 0;
  logic [1:0] take = 0, retire = 0;
  logic redirect = 0, repair = 0;
  wire [1:0] taken;
  wire [63:0] target;
  wire [23:0] checkpoint;
  branch_predictor dut (
    .clk_i(clk), .rst_i(rst), .pc_i(pc), .instruction_i(instruction), .taken_o(taken), .target_o(target),
    .take_i(take), .checkpoint_o(checkpoint), .redirect_i(redirect), .repair_i(repair),
    .repair_checkpoint_i(12'd0), .retire_i(retire), .retire_instruction_i(retire_instruction),
    .retire_pc_i(retire_pc), .retire_next_i(retire_next)
  );
  localparam logic [31:0] BRANCH = 32'h00000263;  // beq x0, x0, +4
  localparam logic [31:0] RETURN = 32'h00008067;  // jalr x0, 0(x1)

  // pc of a branch that indexes counter `index` under history `ghr`.
  function automatic logic [31:0] at(input logic [7:0] index, ghr);
    return {22'd0, index ^ ghr, 2'b00};
  endfunction
  // retire one taken branch training counter `index` under the current committed history.
  task automatic train_taken(input logic [7:0] index);
    retire = 2'b01;
    retire_instruction = {32'h13, BRANCH};
    retire_pc = {32'd0, at(index, dut.commit_ghr_q)};
    retire_next = {32'd0, at(index, dut.commit_ghr_q) + 32'd64};
    @(posedge clk); #1 retire = 0;
  endtask

  initial begin
    repeat (2) @(posedge clk);
    #1 rst = 0;

    // a return before any call predicts from a reset stack entry.
    pc = {32'd0, 32'h100};
    instruction = {32'h13, RETURN};
    #1 if (target[31:0] !== 32'd0) $fatal(1, "RAS_RESET target=%h", target[31:0]);
    instruction = {32'h13, 32'h13};

    // a predicted-taken branch to pc+4 records not taken, as its retirement will.
    train_taken(8'h21);
    train_taken(8'h21);
    if (dut.counter_q[8'h21] != 2'b11) $fatal(1, "SETUP counter=%b", dut.counter_q[8'h21]);
    pc = {32'd0, at(8'h21, dut.ghr_q)};
    instruction = {32'h13, BRANCH};
    take = 2'b01;
    #1 if (!taken[0]) $fatal(1, "SETUP prediction");
    @(posedge clk); #1 take = 0;
    if (dut.ghr_q[0] !== 1'b0) $fatal(1, "PLUS4_HISTORY ghr=%b", dut.ghr_q);
    retire = 2'b01;
    retire_instruction = {32'h13, BRANCH};
    retire_pc = {32'd0, pc[31:0]};
    retire_next = {32'd0, pc[31:0] + 32'd4};
    @(posedge clk); #1 retire = 0;
    if (dut.commit_ghr_q[0] !== 1'b0) $fatal(1, "PLUS4_COMMIT ghr=%b", dut.commit_ghr_q);

    // lane 0 not taken then lane 1 taken on one saturated counter ends at 3, not 2.
    train_taken(8'h5a);
    train_taken(8'h5a);
    if (dut.counter_q[8'h5a] != 2'b11) $fatal(1, "SETUP counter=%b", dut.counter_q[8'h5a]);
    retire = 2'b11;
    retire_instruction = {BRANCH, BRANCH};
    retire_pc = {at(8'h5a, {dut.commit_ghr_q[6:0], 1'b0}), at(8'h5a, dut.commit_ghr_q)};
    retire_next = {retire_pc[63:32] + 32'd64, retire_pc[31:0] + 32'd4};
    @(posedge clk); #1 retire = 0;
    if (dut.counter_q[8'h5a] != 2'b11) $fatal(1, "COUNTER_CHAIN counter=%b", dut.counter_q[8'h5a]);
    // both lanes not taken on one counter step it twice: 3 -> 1.
    retire = 2'b11;
    retire_pc = {at(8'h5a, {dut.commit_ghr_q[6:0], 1'b0}), at(8'h5a, dut.commit_ghr_q)};
    retire_next = {retire_pc[63:32] + 32'd4, retire_pc[31:0] + 32'd4};
    @(posedge clk); #1 retire = 0;
    if (dut.counter_q[8'h5a] != 2'b01) $fatal(1, "COUNTER_CHAIN_TWICE counter=%b", dut.counter_q[8'h5a]);

    $display("PASS");
    $finish;
  end
endmodule
`default_nettype wire
