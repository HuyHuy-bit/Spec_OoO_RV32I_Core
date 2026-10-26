`default_nettype none
// load and store queues: program-order entries, address/data updates, disambiguation and the oldest early load.
// committed_*[k]: the k-th oldest retired store whose bytes are not yet in memory (SB_N of them).
module load_store_queue #(parameter int LQ_N = 8, parameter int SQ_N = 8, parameter int ROB_W = 5, parameter int ID_W = 13,
                          parameter int SB_N = 1) (
  // inputs
  input  wire clk_i, rst_i, flush_i,
  input  wire [ROB_W-1:0] head_slot_i,
  input  wire [1:0] allocate_load_i, allocate_store_i, allocate_i,
  input  wire [1:0][ID_W-1:0] allocate_id_i,
  input  wire [1:0] retire_i,
  input  wire [1:0][ID_W-1:0] retire_id_i,
  input  wire recover_i,
  input  wire [ROB_W-1:0] recover_slot_i,
  input  wire address_i,
  input  wire [ID_W-1:0] address_id_i,
  input  wire [31:0] address_value_i,
  input  wire [3:0] address_mask_i,
  input  wire [1:0] address_size_i,
  input  wire address_unsigned_i, address_early_i,
  input  wire data_i,
  input  wire [ID_W-1:0] data_id_i,
  input  wire [31:0] data_value_i,
  input  wire [SB_N-1:0] committed_valid_i,
  input  wire [SB_N-1:0][31:0] committed_address_i, committed_data_i,
  input  wire [SB_N-1:0][3:0] committed_mask_i,
  input  wire [31:0] memory_word_i,
  input  wire load_take_i,

  // outputs
  output logic [1:0] allocate_ready_o,
  output wire load_valid_o,
  output wire [ID_W-1:0] load_id_o,
  output wire [31:0] load_address_o,
  output wire [1:0] load_size_o,
  output wire load_unsigned_o,
  output wire [3:0] forward_mask_o, memory_mask_o,
  output wire [31:0] forward_data_o, result_o
);
  localparam int LW = $clog2(LQ_N), SW = $clog2(SQ_N);
  logic [LW-1:0] lq_head_q, lq_tail_q;
  logic [SW-1:0] sq_head_q, sq_tail_q;
  logic [LW:0] lq_count_q;
  logic [SW:0] sq_count_q;
  logic [LQ_N-1:0][ID_W-1:0] lq_id_q;
  logic [SQ_N-1:0][ID_W-1:0] sq_id_q;
  logic [LQ_N-1:0][31:0] lq_address_q;
  logic [SQ_N-1:0][31:0] sq_address_q, sq_data_q;
  logic [LQ_N-1:0][1:0] lq_size_q;
  logic [SQ_N-1:0][3:0] sq_mask_q;
  logic [LQ_N-1:0] lq_ready_q, lq_early_q, lq_unsigned_q, lq_issued_q, lq_live, lq_killed;
  logic [SQ_N-1:0] sq_ready_q, sq_data_ready_q, sq_live, sq_killed;
  logic [LW-1:0] pick;
  logic pick_found;
  wire blocked = rst_i || flush_i || recover_i;
  wire [ROB_W-1:0] recover_age = recover_slot_i - head_slot_i;

  // rob-relative age and recovery membership
  // committed store k has age k; live ranks are rob-head distance plus SB_N, so every live rank is younger.
  function automatic logic [5:0] rank(input logic [ROB_W-1:0] slot);
    return 6'(ROB_W'(slot - head_slot_i)) + 6'(SB_N);
  endfunction

  for (genvar i = 0; i < LQ_N; i++) begin : loads
    assign lq_live[i] = (LW+1)'(LW'(LW'(i) - lq_head_q)) < lq_count_q;
    assign lq_killed[i] = ROB_W'(lq_id_q[i][ROB_W-1:0] - head_slot_i) > recover_age;
  end
  for (genvar s = 0; s < SQ_N; s++) begin : stores
    assign sq_live[s] = (SW+1)'(SW'(SW'(s) - sq_head_q)) < sq_count_q;
    assign sq_killed[s] = ROB_W'(sq_id_q[s][ROB_W-1:0] - head_slot_i) > recover_age;
  end

  // allocation capacity
  always_comb begin
    allocate_ready_o = 0;
    if (!blocked) begin
      allocate_ready_o[0] = int'(lq_count_q) + int'(allocate_load_i[0]) <= LQ_N
        && int'(sq_count_q) + int'(allocate_store_i[0]) <= SQ_N;
      allocate_ready_o[1] = allocate_ready_o[0]
        && int'(lq_count_q) + int'(allocate_load_i[0]) + int'(allocate_load_i[1]) <= LQ_N
        && int'(sq_count_q) + int'(allocate_store_i[0]) + int'(allocate_store_i[1]) <= SQ_N;
    end
  end

  // retirement matching
  // retirement pops the oldest entry whose identity matches, in lane order.
  wire lq_pop0 = retire_i[0] && lq_count_q != 0 && lq_id_q[lq_head_q] == retire_id_i[0];
  wire sq_pop0 = retire_i[0] && sq_count_q != 0 && sq_id_q[sq_head_q] == retire_id_i[0];
  wire [LW-1:0] lq_next = lq_head_q + LW'(lq_pop0);
  wire [SW-1:0] sq_next = sq_head_q + SW'(sq_pop0);
  wire lq_pop1 = retire_i[1] && lq_count_q > (LW+1)'(lq_pop0) && lq_id_q[lq_next] == retire_id_i[1];
  wire sq_pop1 = retire_i[1] && sq_count_q > (SW+1)'(sq_pop0) && sq_id_q[sq_next] == retire_id_i[1];
  wire [1:0] lq_push = allocate_i & allocate_load_i, sq_push = allocate_i & allocate_store_i;

  // oldest eligible load selection
  always_comb begin
    pick_found = 0;
    pick = 0;
    for (int k = LQ_N-1; k >= 0; k--) begin
      automatic logic [LW-1:0] i = lq_head_q + LW'(k);
      if (lq_live[i] && lq_ready_q[i] && lq_early_q[i] && !lq_issued_q[i]) begin
        pick_found = 1;
        pick = i;
      end
    end
  end

  logic [SB_N+SQ_N-1:0] candidate_valid, candidate_ready;
  logic [SB_N+SQ_N-1:0][5:0] candidate_age;
  logic [SB_N+SQ_N-1:0][31:0] candidate_address, candidate_data;
  logic [SB_N+SQ_N-1:0][3:0] candidate_mask, candidate_data_ready;

  // store forwarding candidates
  // committed stores come first: their ages are constants below every queue rank, so the selector's
  // youngest-wins chain over them needs no age compare.
  always_comb begin
    for (int k = 0; k < SB_N; k++) begin
      candidate_valid[k] = committed_valid_i[k];
      candidate_ready[k] = 1;
      candidate_age[k] = 6'(k);
      candidate_address[k] = committed_address_i[k];
      candidate_data[k] = committed_data_i[k];
      candidate_mask[k] = committed_mask_i[k];
      candidate_data_ready[k] = 4'hf;
    end
    for (int s = 0; s < SQ_N; s++) begin
      candidate_valid[SB_N+s] = sq_live[s];
      candidate_ready[SB_N+s] = sq_ready_q[s];
      candidate_age[SB_N+s] = rank(sq_id_q[s][ROB_W-1:0]);
      candidate_address[SB_N+s] = sq_address_q[s];
      candidate_data[SB_N+s] = sq_data_q[s];
      candidate_mask[SB_N+s] = sq_mask_q[s];
      candidate_data_ready[SB_N+s] = {4{sq_data_ready_q[s]}};
    end
  end
  wire stall;

  // byte selection and load result
  store_forward #(.CANDIDATES(SB_N+SQ_N)) selector (
    .load_valid_i(pick_found), .load_address_i(lq_address_q[pick]), .load_size_i(lq_size_q[pick]),
    .load_unsigned_i(lq_unsigned_q[pick]), .load_age_i(rank(lq_id_q[pick][ROB_W-1:0])),
    .store_valid_i(candidate_valid), .store_killed_i('0), .store_address_ready_i(candidate_ready),
    .store_age_i(candidate_age), .store_address_i(candidate_address), .store_data_i(candidate_data),
    .store_mask_i(candidate_mask), .store_data_ready_i(candidate_data_ready), .memory_word_i,
    .stall_o(stall), .forward_mask_o, .memory_mask_o, .forward_data_o, .result_o
  );
  assign load_valid_o = !blocked && pick_found && !stall;
  assign load_id_o = lq_id_q[pick];
  assign load_address_o = lq_address_q[pick];
  assign load_size_o = lq_size_q[pick];
  assign load_unsigned_o = lq_unsigned_q[pick];

  // queue storage and recovery
  always_ff @(posedge clk_i) begin
    if (rst_i || flush_i) begin
      lq_head_q <= 0;
      lq_tail_q <= 0;
      lq_count_q <= 0;
      sq_head_q <= 0;
      sq_tail_q <= 0;
      sq_count_q <= 0;
    end else if (recover_i) begin
      // killed entries form the youngest suffix, so survivors stay a prefix.
      lq_count_q <= (LW+1)'($countones(lq_live & ~lq_killed));
      lq_tail_q <= lq_head_q + LW'($countones(lq_live & ~lq_killed));
      sq_count_q <= (SW+1)'($countones(sq_live & ~sq_killed));
      sq_tail_q <= sq_head_q + SW'($countones(sq_live & ~sq_killed));
    end else begin
      lq_head_q <= lq_head_q + LW'(lq_pop0) + LW'(lq_pop1);
      sq_head_q <= sq_head_q + SW'(sq_pop0) + SW'(sq_pop1);
      lq_tail_q <= lq_tail_q + LW'($countones(lq_push));
      sq_tail_q <= sq_tail_q + SW'($countones(sq_push));
      lq_count_q <= lq_count_q + (LW+1)'($countones(lq_push)) - (LW+1)'(lq_pop0) - (LW+1)'(lq_pop1);
      sq_count_q <= sq_count_q + (SW+1)'($countones(sq_push)) - (SW+1)'(sq_pop0) - (SW+1)'(sq_pop1);
      for (int lane = 0; lane < 2; lane++) begin
        automatic logic [LW-1:0] l = lq_tail_q + LW'(lane == 1 && lq_push[0]);
        automatic logic [SW-1:0] s = sq_tail_q + SW'(lane == 1 && sq_push[0]);
        if (lq_push[lane]) begin
          lq_id_q[l] <= allocate_id_i[lane];
          lq_ready_q[l] <= 0;
          lq_issued_q[l] <= 0;
        end
        if (sq_push[lane]) begin
          sq_id_q[s] <= allocate_id_i[lane];
          sq_ready_q[s] <= 0;
          sq_data_ready_q[s] <= 0;
        end
      end
    end
    // updates find their entry by full identity; stale identities match nothing.
    if (!rst_i && !flush_i) begin
      for (int i = 0; i < LQ_N; i++)
        if (address_i && lq_live[i] && lq_id_q[i] == address_id_i) begin
          lq_ready_q[i] <= 1;
          lq_address_q[i] <= address_value_i;
          lq_size_q[i] <= address_size_i;
          lq_unsigned_q[i] <= address_unsigned_i;
          lq_early_q[i] <= address_early_i;
        end
      for (int s = 0; s < SQ_N; s++) begin
        if (address_i && sq_live[s] && sq_id_q[s] == address_id_i) begin
          sq_ready_q[s] <= 1;
          sq_address_q[s] <= address_value_i;
          sq_mask_q[s] <= address_mask_i;
        end
        if (data_i && sq_live[s] && sq_id_q[s] == data_id_i) begin
          sq_data_ready_q[s] <= 1;
          sq_data_q[s] <= data_value_i;
        end
      end
      if (load_take_i && load_valid_o) lq_issued_q[pick] <= 1;
    end
  end

  // checks
`ifndef SYNTHESIS
  initial assert (LQ_N >= 2 && SQ_N >= 2 && LQ_N == 2**LW && SQ_N == 2**SW && ROB_W <= 5 && ID_W >= ROB_W
                  && SB_N >= 1 && 2**ROB_W + SB_N <= 64)
    else $fatal(1, "LSQ_GEOMETRY");
  always_ff @(posedge clk_i) if (!rst_i) begin
    assert ((allocate_i & ~allocate_ready_o) == 0 && allocate_i != 2'b10) else $fatal(1, "LSQ_ALLOCATE");
    assert ((allocate_load_i & allocate_store_i) == 0) else $fatal(1, "LSQ_KIND");
    assert (!(flush_i || recover_i) || (allocate_i == 0 && retire_i == 0)) else $fatal(1, "LSQ_RECOVERY");
    assert (retire_i != 2'b10) else $fatal(1, "LSQ_RETIRE");
    assert (!sq_pop0 || (sq_ready_q[sq_head_q] && sq_data_ready_q[sq_head_q])) else $fatal(1, "LSQ_STORE_READY");
    assert (!sq_pop1 || (sq_ready_q[sq_next] && sq_data_ready_q[sq_next])) else $fatal(1, "LSQ_STORE_READY");
    assert (!load_take_i || load_valid_o) else $fatal(1, "LSQ_TAKE");
    // full-size queue shape and rob-order age: live entries form a run from head with strictly rising ranks.
    assert (int'(lq_count_q) <= LQ_N && LW'(lq_head_q + LW'(lq_count_q)) == lq_tail_q) else $fatal(1, "LSQ_LOAD_SHAPE");
    assert (int'(sq_count_q) <= SQ_N && SW'(sq_head_q + SW'(sq_count_q)) == sq_tail_q) else $fatal(1, "LSQ_STORE_SHAPE");
    for (int k = 1; k < LQ_N; k++)
      if (k < int'(lq_count_q)) assert (rank(lq_id_q[LW'(lq_head_q + LW'(k))][ROB_W-1:0])
        > rank(lq_id_q[LW'(lq_head_q + LW'(k - 1))][ROB_W-1:0])) else $fatal(1, "LSQ_LOAD_ORDER");
    for (int k = 1; k < SQ_N; k++)
      if (k < int'(sq_count_q)) assert (rank(sq_id_q[SW'(sq_head_q + SW'(k))][ROB_W-1:0])
        > rank(sq_id_q[SW'(sq_head_q + SW'(k - 1))][ROB_W-1:0])) else $fatal(1, "LSQ_STORE_ORDER");
    assert ((lq_live & lq_issued_q & ~lq_ready_q) == 0) else $fatal(1, "LSQ_ISSUED_READY");
  end
`endif
endmodule
`default_nettype wire
