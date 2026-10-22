`default_nettype none
// gshare direction, an eight-entry return stack and tagless jalr targets.
// checkpoints hold post-instruction history and stack pointer; tables train at retirement.
// recovery restores the stack pointer, not overwritten stack entries.
module branch_predictor #(parameter int ENTRIES = 256) (
  // inputs
  input  wire clk_i, rst_i,
  input  wire [63:0] pc_i, instruction_i,
  input  wire [1:0] take_i,
  input  wire redirect_i, repair_i,
  input  wire [11:0] repair_checkpoint_i,
  input  wire [1:0] retire_i,
  input  wire [63:0] retire_instruction_i, retire_pc_i, retire_next_i,

  // outputs
  output logic [1:0] taken_o,
  output logic [63:0] target_o,
  output logic [23:0] checkpoint_o
);
  localparam int IW = $clog2(ENTRIES);
  logic [ENTRIES-1:0][1:0] counter_q;
  logic [7:0] ghr_q, commit_ghr_q;
  logic [2:0] ras_ptr_q, commit_ptr_q;
  logic [7:0][31:0] ras_q;
  logic [63:0][31:0] jalr_target_q;
  logic [63:0] jalr_valid_q;

  // call and return classification
  function automatic logic link(input logic [4:0] r);
    return r == 5'd1 || r == 5'd5;
  endfunction
  function automatic logic is_call(input logic [6:0] op, input logic [4:0] rd);
    return (op == 7'h6f || op == 7'h67) && link(rd);
  endfunction
  function automatic logic is_return(input logic [6:0] op, input logic [4:0] rd, rs1);
    return op == 7'h67 && link(rs1) && !link(rd);
  endfunction

  // fetch prediction and speculative history
  // lane 1 sees lane 0's speculative effect; at most one stack operation per cycle (lane 0 first).
  logic [7:0] ghr_next;
  logic [2:0] ptr_next;
  logic push;
  logic [2:0] push_slot;
  logic [31:0] push_value;
  always_comb begin
    automatic logic [7:0] g = ghr_q;
    automatic logic [2:0] p = ras_ptr_q;
    automatic logic stack_used = 0;
    push = 0;
    push_slot = 0;
    push_value = 0;
    ghr_next = ghr_q;
    ptr_next = ras_ptr_q;
    for (int lane = 0; lane < 2; lane++) begin
      automatic logic [31:0] pc = pc_i[lane*32 +: 32], ins = instruction_i[lane*32 +: 32];
      automatic logic [31:0] jal = {{12{ins[31]}}, ins[19:12], ins[20], ins[30:21], 1'b0};
      automatic logic [31:0] branch = {{20{ins[31]}}, ins[7], ins[30:25], ins[11:8], 1'b0};
      automatic logic is_branch = ins[6:0] == 7'h63;
      automatic logic is_jalr = ins[6:0] == 7'h67;
      target_o[lane*32 +: 32] = is_jalr ? (is_return(ins[6:0], ins[11:7], ins[19:15]) ? ras_q[p - 3'd1] : jalr_target_q[pc[7:2]])
                                        : pc + (ins[6:0] == 7'h6f ? jal : branch);
      taken_o[lane] = (ins[6:0] == 7'h6f || (is_branch && counter_q[pc[IW+1:2] ^ IW'(g)][1])
          || (is_jalr && (is_return(ins[6:0], ins[11:7], ins[19:15]) || jalr_valid_q[pc[7:2]])))
        && target_o[lane*32 +: 2] == 2'b00;
      // history records whether control left the fall-through path, matching retirement: a branch
      // to pc+4 counts as not taken whatever its condition.
      if (is_branch) g = {g[6:0], taken_o[lane] && target_o[lane*32 +: 32] != pc + 32'd4};
      if (!stack_used && is_return(ins[6:0], ins[11:7], ins[19:15])) begin
        p = p - 3'd1;
        stack_used = 1;
      end else if (!stack_used && is_call(ins[6:0], ins[11:7])) begin
        if (take_i[lane]) begin
          push = 1;
          push_slot = p;
          push_value = pc + 32'd4;
        end
        p = p + 3'd1;
        stack_used = 1;
      end
      checkpoint_o[lane*12 +: 12] = {is_branch, p, g};
      if (take_i[lane]) begin
        ghr_next = g;
        ptr_next = p;
      end
    end
  end

  // retirement training
  logic [7:0] commit_ghr;
  logic [2:0] commit_ptr;
  logic [1:0] retire_branch, retire_jalr, retire_call, retire_return, train_write;
  logic [1:0][IW-1:0] train_index;
  logic [1:0][1:0] train_count;
  always_comb begin
    automatic logic [1:0] count;
    commit_ghr = commit_ghr_q;
    commit_ptr = commit_ptr_q;
    for (int lane = 0; lane < 2; lane++) begin
      automatic logic [6:0] op = retire_instruction_i[lane*32 +: 7];
      automatic logic [4:0] rd = retire_instruction_i[lane*32+7 +: 5], rs1 = retire_instruction_i[lane*32+15 +: 5];
      retire_branch[lane] = op == 7'h63;
      retire_jalr[lane] = op == 7'h67;
      retire_call[lane] = is_call(op, rd);
      retire_return[lane] = is_return(op, rd, rs1);
      train_index[lane] = retire_pc_i[lane*32+2 +: IW] ^ IW'(commit_ghr);
      train_write[lane] = retire_i[lane] && retire_branch[lane];
      if (!(lane == 1 && train_write[0] && train_index[0] == train_index[1])) count = counter_q[train_index[lane]];
      if (train_write[lane]) begin
        if (retire_next_i[lane*32 +: 32] != retire_pc_i[lane*32 +: 32] + 32'd4)
          count = count == 2'b11 ? 2'b11 : count + 2'd1;
        else count = count == 2'b00 ? 2'b00 : count - 2'd1;
      end
      train_count[lane] = count;
      if (retire_i[lane]) begin
        if (retire_branch[lane])
          commit_ghr = {commit_ghr[6:0], retire_next_i[lane*32 +: 32] != retire_pc_i[lane*32 +: 32] + 32'd4};
        if (retire_return[lane]) commit_ptr = commit_ptr - 3'd1;
        else if (retire_call[lane]) commit_ptr = commit_ptr + 3'd1;
      end
    end
  end

  wire unused = ^{retire_instruction_i[63:52], retire_instruction_i[46:44],
                  retire_instruction_i[31:20], retire_instruction_i[14:12]};

  // predictor storage and recovery
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      for (int n = 0; n < ENTRIES; n++) counter_q[n] <= 2'b01;
      jalr_valid_q <= 0;
      ghr_q <= 0;
      commit_ghr_q <= 0;
      ras_ptr_q <= 0;
      commit_ptr_q <= 0;
      ras_q <= '0;
    end else begin
      commit_ghr_q <= commit_ghr;
      commit_ptr_q <= commit_ptr;
      if (repair_i) begin
        ghr_q <= repair_checkpoint_i[7:0] ^ {7'd0, repair_checkpoint_i[11]};
        ras_ptr_q <= repair_checkpoint_i[10:8];
      end else if (redirect_i) begin
        ghr_q <= commit_ghr;
        ras_ptr_q <= commit_ptr;
      end else begin
        ghr_q <= ghr_next;
        ras_ptr_q <= ptr_next;
        if (push) ras_q[push_slot] <= push_value;
      end
      for (int lane = 0; lane < 2; lane++) if (retire_i[lane]) begin
        automatic logic [5:0] slot = retire_pc_i[lane*32+2 +: 6];
        // lane 1's count already includes lane 0's update when both train one entry.
        if (train_write[lane]) counter_q[train_index[lane]] <= train_count[lane];
        if (retire_jalr[lane] && !retire_return[lane]) begin
          jalr_target_q[slot] <= retire_next_i[lane*32 +: 32];
          jalr_valid_q[slot] <= 1;
        end
      end
    end
  end

  // checks
`ifndef SYNTHESIS
  initial assert (ENTRIES >= 256 && ENTRIES == 2**IW) else $fatal(1, "PREDICTOR_GEOMETRY");
`endif
endmodule
`default_nettype wire
