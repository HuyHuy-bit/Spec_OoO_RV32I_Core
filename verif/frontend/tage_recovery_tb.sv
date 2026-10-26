`default_nettype none
module tage_recovery_tb;
  logic clk;
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end
  logic rst = 1, redirect = 0, repair = 0;
  logic [1:0] take = 0, retire = 0;
  logic [63:0] pc = {32'h104,32'h100}, instruction = {32'h13,32'h13};
  logic [63:0] retire_pc = 0, retire_instruction = 0, retire_next = 0;
  logic [35:0] saved = 0;
  wire [71:0] checkpoint;
  wire [1:0] taken;
  wire [63:0] target;
  branch_predictor #(.TAGE(1)) dut (
    .clk_i(clk), .rst_i(rst), .pc_i(pc), .instruction_i(instruction), .take_i(take),
    .redirect_i(redirect), .repair_i(repair), .repair_checkpoint_i(saved), .retire_i(retire),
    .retire_pc_i(retire_pc), .retire_instruction_i(retire_instruction), .retire_next_i(retire_next),
    .taken_o(taken), .target_o(target), .checkpoint_o(checkpoint)
  );
  task automatic tick();
    @(posedge clk); #1;
  endtask
  task automatic history(input logic [31:0] expected);
    if (dut.ghr_q !== expected) $fatal(1, "HISTORY got=%h expected=%h", dut.ghr_q, expected);
    if (dut.commit_ghr_q !== dut.tage_direction.direction.history_q) $fatal(1, "COMMIT_HISTORY");
  endtask
  initial begin
    automatic logic [31:0] h, committed;
    automatic logic [35:0] branch_checkpoint, call_checkpoint;
    repeat (2) tick();
    rst = 0;
    // establish nonzero upper history without depending on a trained prediction.
    saved = {1'b0,3'd0,32'hdeadbeef}; repair = 1; redirect = 1;
    tick(); history(32'hdeadbeef);
    repair = 0; redirect = 0;
    instruction = {32'h00000463,32'h00000463}; // beq x0,x0,+8, both lookup lanes
    #1;
    h = {30'h1eadbeef,taken[0],taken[1]};
    if (checkpoint[31:0] !== {31'h5eadbeef,taken[0]} || checkpoint[67:36] !== h)
      $fatal(1, "LOOKUP_HISTORY_CHAIN");
    repeat (3) tick(); history(32'hdeadbeef); // offered but not dispatched
    take = 1; #1; branch_checkpoint = checkpoint[35:0];
    tick(); history(branch_checkpoint[31:0]);
    // wrong-path dispatch and a younger checkpoint cannot change the older recovery state.
    instruction = {32'h13,32'h000000ef}; // jal x1,0
    #1; call_checkpoint = checkpoint[35:0]; tick();
    instruction = {32'h13,32'h00000463}; tick();
    take = 0; saved = branch_checkpoint; repair = 1; redirect = 1;
    tick(); history(branch_checkpoint[31:0] ^ 32'd1);
    if (dut.ras_ptr_q != branch_checkpoint[34:32]) $fatal(1, "RAS_REPAIR");
    // a target-only call repair restores its post-call history without flipping a bit.
    saved = call_checkpoint; tick(); history(call_checkpoint[31:0]);
    if (dut.ras_ptr_q != call_checkpoint[34:32]) $fatal(1, "CALL_REPAIR");
    repair = 0; redirect = 0;
    instruction = {32'h13,32'h00000263}; // beq x0,x0,+4, actual condition true
    take = 1; #1; saved = checkpoint[35:0];
    if (saved[35] || saved[0]) $fatal(1, "PLUS4_CHECKPOINT");
    tick(); take = 0; repair = 1; redirect = 1;
    tick(); history(saved[31:0]);
    // retire two branches during full redirect; include both in the restored history.
    repair = 0; retire = 3;
    retire_instruction = {32'h00000463,32'h00000463};
    retire_pc = {32'h204,32'h200}; retire_next = {32'h208,32'h208};
    tick(); history(32'd2);
    retire = 0; redirect = 0;
    // lane-one branch after an ordinary lane-zero instruction.
    instruction = {32'h00000463,32'h13}; take = 3; #1;
    h = checkpoint[67:36]; tick(); history(h);
    take = 0;
    // training while dispatch is blocked must not move speculative history.
    retire = 2; retire_pc[63:32] = 32'h300; retire_next[63:32] = 32'h308;
    tick(); history(h);
    retire = 0; committed = dut.commit_ghr_q;
    // both speculative state and table history clear on reset.
    rst = 1; tick(); history(0);
    if (committed != 5 || dut.commit_ptr_q != 0 || dut.ras_ptr_q != 0) $fatal(1, "RESET");
    $display("PASS recovery"); $finish;
  end
  wire unused = ^{target, checkpoint[71:68]};
endmodule
`default_nettype wire
