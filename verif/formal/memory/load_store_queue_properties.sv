`default_nettype none
module load_store_queue_properties (
  input wire clk, rst, flush,
  input wire [1:0] allocate_load, allocate_store, allocate, retire,
  input wire recover,
  input wire [1:0] recover_pick,
  input wire address,
  input wire [3:0] address_id,
  input wire [31:0] address_value,
  input wire [3:0] address_mask,
  input wire [1:0] address_size,
  input wire address_unsigned, address_early,
  input wire data,
  input wire [3:0] data_id,
  input wire [31:0] data_value,
  input wire committed_valid,
  input wire [31:0] committed_address, committed_data,
  input wire [3:0] committed_mask,
  input wire [31:0] memory_word,
  input wire load_take
);
  localparam logic [1:0] NONE = 0, LOAD = 1, STORE = 2;
  // reference rob window: four slots, two generation bits, lq = sq = 2.
  logic past_valid = 0;
  logic [1:0] head_q;
  logic [2:0] count_q;
  logic [3:0][1:0] kind_q, generation_q, size_q;
  logic [3:0][3:0] id_q, mask_q;
  logic [3:0][31:0] address_q, data_q;
  logic [3:0] address_ready_q, data_ready_q, unsigned_q, early_q, issued_q;
  logic [2:0] load_allocations_q, rob_allocations_q;
  logic stalled_q;
  logic [3:0] stalled_id_q;

  wire [1:0] allocate_ready, load_size;
  wire load_valid, load_unsigned;
  wire [3:0] load_id, forward_mask, memory_mask;
  wire [31:0] load_address, forward_data, result;
  wire [1:0][3:0] allocate_id, retire_id;
  wire [1:0] tail = head_q + 2'(count_q);
  wire [1:0] tail1 = tail + 2'd1, head1 = head_q + 2'd1;
  assign allocate_id[0] = {generation_q[tail], tail};
  assign allocate_id[1] = {generation_q[tail1], tail1};
  assign retire_id[0] = id_q[head_q];
  assign retire_id[1] = id_q[head1];

  load_store_queue #(.LQ_N(2), .SQ_N(2), .ROB_W(2), .ID_W(4)) dut (
    .clk_i(clk), .rst_i(rst), .flush_i(flush), .head_slot_i(head_q),
    .allocate_load_i(allocate_load), .allocate_store_i(allocate_store), .allocate_i(allocate),
    .allocate_id_i(allocate_id), .allocate_ready_o(allocate_ready),
    .retire_i(retire), .retire_id_i(retire_id),
    .recover_i(recover), .recover_slot_i(head_q + recover_pick),
    .address_i(address), .address_id_i(address_id), .address_value_i(address_value),
    .address_mask_i(address_mask), .address_size_i(address_size),
    .address_unsigned_i(address_unsigned), .address_early_i(address_early),
    .data_i(data), .data_id_i(data_id), .data_value_i(data_value),
    .committed_valid_i(committed_valid), .committed_address_i(committed_address),
    .committed_data_i(committed_data), .committed_mask_i(committed_mask),
    .load_valid_o(load_valid), .load_id_o(load_id), .load_address_o(load_address),
    .load_size_o(load_size), .load_unsigned_o(load_unsigned),
    .forward_mask_o(forward_mask), .memory_mask_o(memory_mask),
    .forward_data_o(forward_data), .result_o(result),
    .memory_word_i(memory_word), .load_take_i(load_take)
  );

  logic [3:0] live;
  for (genvar slot = 0; slot < 4; slot++) begin : window
    assign live[slot] = 3'(2'(2'(slot) - head_q)) < count_q;
  end
  logic [2:0] loads, stores;
  logic found, unknown, missing, from_store, from_committed, any_store_killed, live_address_match;
  logic [1:0] pick;
  logic [3:0] requested, expected_forward;
  logic [31:0] word, expected_data, expected_result;
  integer width;
  wire blocked = rst || flush || recover;

  // independent oldest-first search in rob order; ranks are never consulted.
  always_comb begin
    loads = 0;
    stores = 0;
    found = 0;
    pick = 0;
    unknown = 0;
    missing = 0;
    from_store = 0;
    from_committed = 0;
    any_store_killed = 0;
    live_address_match = 0;
    expected_forward = 0;
    expected_data = 0;
    for (int age = 0; age < 4; age++) begin
      automatic logic [1:0] slot = head_q + 2'(age);
      if (live[slot] && kind_q[slot] == LOAD) loads++;
      if (live[slot] && kind_q[slot] == STORE) stores++;
      if (live[slot] && kind_q[slot] == STORE && age > int'(recover_pick)) any_store_killed = 1;
      if (live[slot] && kind_q[slot] != NONE && id_q[slot] == address_id) live_address_match = 1;
      if (!found && live[slot] && kind_q[slot] == LOAD && address_ready_q[slot] && early_q[slot] && !issued_q[slot]) begin
        found = 1;
        pick = slot;
      end
    end
    width = size_q[pick] == 0 ? 1 : size_q[pick] == 1 ? 2 : 4;
    word = memory_word;
    for (int b = 0; b < 4; b++)
      requested[b] = b >= int'(address_q[pick][1:0]) && b < int'(address_q[pick][1:0]) + width;
    for (int age = 0; age < 4; age++) begin
      automatic logic [1:0] slot = head_q + 2'(age);
      if (found && 2'(age) < 2'(pick - head_q) && kind_q[slot] == STORE && !address_ready_q[slot])
        unknown = 1;
    end
    for (int b = 0; b < 4; b++) begin
      automatic logic hit = 0;
      // walk older stores from youngest to oldest; the first cover wins.
      for (int age = 3; age >= 0; age--) begin
        automatic logic [1:0] slot = head_q + 2'(age);
        if (!hit && found && requested[b] && 2'(age) < 2'(pick - head_q) && kind_q[slot] == STORE
            && address_ready_q[slot] && address_q[slot][31:2] == address_q[pick][31:2] && mask_q[slot][b]) begin
          hit = 1;
          from_store = 1;
          if (!data_ready_q[slot]) missing = 1;
          expected_data[b*8 +: 8] = data_q[slot][b*8 +: 8];
        end
      end
      if (!hit && found && requested[b] && committed_valid && committed_mask[b]
          && committed_address[31:2] == address_q[pick][31:2]) begin
        hit = 1;
        from_committed = 1;
        expected_data[b*8 +: 8] = committed_data[b*8 +: 8];
      end
      expected_forward[b] = hit;
      if (hit) word[b*8 +: 8] = expected_data[b*8 +: 8];
    end
    for (int i = 0; i < 32; i++)
      expected_result[i] = i < width*8 ? word[int'(address_q[pick][1:0])*8 + i]
        : !unsigned_q[pick] && word[int'(address_q[pick][1:0])*8 + width*8 - 1];
  end
  wire expected_valid = !blocked && found && !unknown && !missing;

  always @(posedge clk) begin
    past_valid <= 1;
    if (!past_valid) assume (rst);
    assume ((allocate_load & allocate_store) == 0);
    assume (retire != 2'b10 && allocate != 2'b10);
    assume ((allocate & ~allocate_ready) == 0);
    assume (int'(count_q) + $countones(allocate) <= 4);
    assume (!load_take || load_valid);
    assume (!(flush && recover));
    assume (!(flush || recover) || (allocate == 0 && retire == 0));
    assume (!recover || int'(recover_pick) < int'(count_q));
    assume (!address || (address_size <= 2 && (address_size != 1 || !address_value[0])
      && (address_size != 2 || address_value[1:0] == 0)));
    // retirement follows rob order; a store retires only with address and data.
    for (int lane = 0; lane < 2; lane++) begin
      automatic logic [1:0] slot = head_q + 2'(lane);
      if (retire[lane]) assume (int'(count_q) > lane
        && (kind_q[slot] != STORE || (address_ready_q[slot] && data_ready_q[slot])));
    end
    if (!rst) begin
      ready_exact: assert (allocate_ready[0] == (!blocked && int'(loads) + int'(allocate_load[0]) <= 2
        && int'(stores) + int'(allocate_store[0]) <= 2)
        && allocate_ready[1] == (allocate_ready[0] && int'(loads) + $countones(allocate_load) <= 2
        && int'(stores) + $countones(allocate_store) <= 2));
      offer_exact: assert (load_valid == expected_valid);
      if (expected_valid) begin
        identity_exact: assert (load_id == id_q[pick] && load_address == address_q[pick]
          && load_size == size_q[pick] && load_unsigned == unsigned_q[pick]);
        forward_exact: assert (forward_mask == expected_forward && memory_mask == (requested & ~expected_forward)
          && forward_data == expected_data);
        result_exact: assert (result == expected_result);
      end
    end
  end

  always @(posedge clk) begin
    if (rst || flush) begin
      head_q <= 0;
      count_q <= 0;
      address_ready_q <= 0;
      data_ready_q <= 0;
      issued_q <= 0;
      if (rst) begin
        load_allocations_q <= 0;
        rob_allocations_q <= 0;
        for (int slot = 0; slot < 4; slot++) generation_q[slot] <= 0;
      end
    end else begin
      if (recover) count_q <= 3'(recover_pick) + 3'd1;
      else begin
        head_q <= head_q + 2'($countones(retire));
        count_q <= count_q + 3'($countones(allocate)) - 3'($countones(retire));
      end
      for (int lane = 0; lane < 2; lane++)
        if (allocate[lane]) begin
          automatic logic [1:0] slot = tail + 2'(lane);
          kind_q[slot] <= allocate_load[lane] ? LOAD : allocate_store[lane] ? STORE : NONE;
          id_q[slot] <= allocate_id[lane];
          generation_q[slot] <= generation_q[slot] + 2'd1;
          address_ready_q[slot] <= 0;
          data_ready_q[slot] <= 0;
          issued_q[slot] <= 0;
          if (allocate_load[lane] && load_allocations_q != 7) load_allocations_q <= load_allocations_q + 3'd1;
          if (rob_allocations_q != 7) rob_allocations_q <= rob_allocations_q + 3'd1;
        end
      for (int slot = 0; slot < 4; slot++) begin
        if (live[slot] && address && kind_q[slot] != NONE && id_q[slot] == address_id) begin
          address_ready_q[slot] <= 1;
          address_q[slot] <= address_value;
          mask_q[slot] <= address_mask;
          size_q[slot] <= address_size;
          unsigned_q[slot] <= address_unsigned;
          early_q[slot] <= address_early;
        end
        if (live[slot] && data && kind_q[slot] == STORE && id_q[slot] == data_id) begin
          data_ready_q[slot] <= 1;
          data_q[slot] <= data_value;
        end
      end
      if (load_valid && load_take) issued_q[pick] <= 1;
    end
    stalled_q <= !blocked && found && !expected_valid;
    stalled_id_q <= id_q[pick];
  end

  always @(posedge clk) if (past_valid && !rst) begin
    dual_allocate: cover (allocate == 2'b11 && allocate_store[0] && allocate_load[1]);
    dual_retire: cover (retire == 2'b11);
    queue_full: cover (!blocked && allocate_load[0] && !allocate_ready[0]);
    store_forward: cover (load_valid && from_store && memory_mask != 0);
    committed_forward: cover (load_valid && from_committed);
    unknown_stall: cover (!blocked && found && unknown);
    data_stall: cover (!blocked && found && !unknown && missing);
    woken_load: cover (load_valid && stalled_q && load_id == stalled_id_q);
    joint_resolution: cover (address && data && address_id == data_id && live_address_match);
    recover_store: cover (recover && any_store_killed);
    stale_update: cover (address && !live_address_match);
    wrapped_issue: cover (load_valid && from_store && load_allocations_q >= 3 && rob_allocations_q >= 5);
  end
endmodule
`default_nettype wire
