`default_nettype none
// full-size lsq random test (lq8/sq8/rob32) against an independent rob-order byte scoreboard:
// dual allocate/retire, wrap, squash, flush, stale updates, committed-owner forwarding, load-take backpressure.
module load_store_queue_tb;
  localparam int ROB = 32, LQ = 8, SQ = 8, CYCLES = 200000;
  localparam logic [1:0] NONE = 0, LOAD = 1, STORE = 2;
  logic clk = 0, rst = 1, flush = 0, recover = 0;
  always #5 clk = ~clk;
  logic [1:0] allocate_load = 0, allocate_store = 0, allocate = 0, retire = 0;
  logic [4:0] recover_pick = 0;
  logic address = 0, data = 0, address_unsigned = 0, address_early = 0, committed_valid = 0, load_take = 0;
  logic [12:0] address_id = 0, data_id = 0;
  logic [31:0] address_value = 0, data_value = 0, committed_address = 0, committed_data = 0, memory_word = 0;
  logic [3:0] address_mask = 0, committed_mask = 0;
  logic [1:0] address_size = 0;

  // reference rob window: 32 slots, eight generation bits above the slot index.
  logic [4:0] head_q = 0;
  logic [5:0] count_q = 0;
  logic [1:0] kind_q [ROB], size_q [ROB];
  logic [7:0] generation_q [ROB];
  logic [12:0] id_q [ROB];
  logic [3:0] mask_q [ROB];
  logic [31:0] address_q [ROB], data_q [ROB];
  logic [ROB-1:0] address_ready_q, data_ready_q, unsigned_q, early_q, issued_q;

  wire [1:0] allocate_ready, load_size;
  wire load_valid, load_unsigned;
  wire [12:0] load_id;
  wire [3:0] forward_mask, memory_mask;
  wire [31:0] load_address, forward_data, result;
  wire [4:0] tail = head_q + 5'(count_q);
  wire [1:0][12:0] allocate_id, retire_id;
  assign allocate_id[0] = {generation_q[tail], tail};
  assign allocate_id[1] = {generation_q[5'(tail + 1)], 5'(tail + 1)};
  assign retire_id[0] = id_q[head_q];
  assign retire_id[1] = id_q[5'(head_q + 1)];

  load_store_queue dut (
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

  function automatic logic live(input logic [4:0] slot);
    return 6'(5'(slot - head_q)) < count_q;
  endfunction

  // independent oldest-first search in rob order; dut ranks and pointers are never consulted.
  int loads, stores, width;
  logic found, unknown, missing, from_store, from_committed, any_store_killed, live_address_match;
  logic [4:0] pick;
  logic [3:0] requested, expected_forward;
  logic [31:0] word, expected_data, expected_result;
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
    for (int age = 0; age < ROB; age++) begin
      automatic logic [4:0] slot = head_q + 5'(age);
      if (live(slot) && kind_q[slot] == LOAD) loads++;
      if (live(slot) && kind_q[slot] == STORE) stores++;
      if (live(slot) && kind_q[slot] == STORE && age > int'(recover_pick)) any_store_killed = 1;
      if (live(slot) && kind_q[slot] != NONE && id_q[slot] == address_id) live_address_match = 1;
      if (!found && live(slot) && kind_q[slot] == LOAD && address_ready_q[slot] && early_q[slot] && !issued_q[slot]) begin
        found = 1;
        pick = slot;
      end
    end
    width = size_q[pick] == 0 ? 1 : size_q[pick] == 1 ? 2 : 4;
    word = memory_word;
    for (int b = 0; b < 4; b++)
      requested[b] = b >= int'(address_q[pick][1:0]) && b < int'(address_q[pick][1:0]) + width;
    for (int age = 0; age < ROB; age++) begin
      automatic logic [4:0] slot = head_q + 5'(age);
      if (found && age < int'(5'(pick - head_q)) && kind_q[slot] == STORE && !address_ready_q[slot]) unknown = 1;
    end
    for (int b = 0; b < 4; b++) begin
      automatic logic hit = 0;
      // walk older stores from youngest to oldest; the first cover wins.
      for (int age = ROB-1; age >= 0; age--) begin
        automatic logic [4:0] slot = head_q + 5'(age);
        if (!hit && found && requested[b] && age < int'(5'(pick - head_q)) && kind_q[slot] == STORE
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
  wire blocked = rst || flush || recover;
  wire expected_valid = !blocked && found && !unknown && !missing;

  // scoreboard and coverage
  int covered [8];
  int wraps = 0;
  always @(posedge clk) if (!rst) begin
    if (allocate_ready[0] != (!blocked && loads + int'(allocate_load[0]) <= LQ && stores + int'(allocate_store[0]) <= SQ)
        || allocate_ready[1] != (allocate_ready[0] && loads + $countones(allocate_load) <= LQ
        && stores + $countones(allocate_store) <= SQ))
      $fatal(1, "READY loads=%0d stores=%0d ready=%b", loads, stores, allocate_ready);
    if (load_valid != expected_valid) $fatal(1, "OFFER dut=%b ref=%b", load_valid, expected_valid);
    if (expected_valid && (load_id != id_q[pick] || load_address != address_q[pick] || load_size != size_q[pick]
        || load_unsigned != unsigned_q[pick])) $fatal(1, "IDENTITY dut=%h ref=%h", load_id, id_q[pick]);
    if (expected_valid && (forward_mask != expected_forward || memory_mask != (requested & ~expected_forward)
        || forward_data != expected_data || result != expected_result))
      $fatal(1, "BYTES fwd=%b/%b data=%h/%h result=%h/%h", forward_mask, expected_forward,
             forward_data, expected_data, result, expected_result);
    if (load_valid && from_store && memory_mask != 0) covered[0]++;
    if (load_valid && from_committed) covered[1]++;
    if (!blocked && found && unknown) covered[2]++;
    if (!blocked && found && !unknown && missing) covered[3]++;
    if (!blocked && allocate_load[0] && !allocate_ready[0]) covered[4]++;
    if (recover && any_store_killed) covered[5]++;
    if (address && !live_address_match) covered[6]++;
    if (retire == 2'b11 && allocate == 2'b11) covered[7]++;
  end

  // reference update from the same input events
  always @(posedge clk) begin
    if (rst || flush) begin
      head_q <= 0;
      count_q <= 0;
      if (rst) for (int slot = 0; slot < ROB; slot++) generation_q[slot] <= 0;
    end else begin
      if (recover) count_q <= 6'(recover_pick) + 6'd1;
      else begin
        if (int'(head_q) + $countones(retire) >= ROB) wraps++;
        head_q <= head_q + 5'($countones(retire));
        count_q <= count_q + 6'($countones(allocate)) - 6'($countones(retire));
      end
      for (int lane = 0; lane < 2; lane++)
        if (allocate[lane]) begin
          automatic logic [4:0] slot = tail + 5'(lane);
          kind_q[slot] <= allocate_load[lane] ? LOAD : allocate_store[lane] ? STORE : NONE;
          id_q[slot] <= allocate_id[lane];
          generation_q[slot] <= generation_q[slot] + 8'd1;
          address_ready_q[slot] <= 0;
          data_ready_q[slot] <= 0;
          issued_q[slot] <= 0;
        end
      for (int slot = 0; slot < ROB; slot++) begin
        if (live(5'(slot)) && address && kind_q[slot] != NONE && id_q[slot] == address_id) begin
          address_ready_q[slot] <= 1;
          address_q[slot] <= address_value;
          mask_q[slot] <= address_mask;
          size_q[slot] <= address_size;
          unsigned_q[slot] <= address_unsigned;
          early_q[slot] <= address_early;
        end
        if (live(5'(slot)) && data && kind_q[slot] == STORE && id_q[slot] == data_id) begin
          data_ready_q[slot] <= 1;
          data_q[slot] <= data_value;
        end
      end
      if (load_valid && load_take) issued_q[pick] <= 1;
    end
  end

  // random identity: usually a live slot, sometimes stale or arbitrary.
  function automatic logic [12:0] some_id();
    if (count_q == 0 || $urandom_range(9) == 0) return 13'($urandom);
    // half the time resolve the oldest unaddressed slot so older stores stop blocking forwarding.
    if ($urandom_range(1) == 0)
      for (int age = 0; age < int'(count_q); age++)
        if (!address_ready_q[head_q + 5'(age)] && kind_q[head_q + 5'(age)] != NONE) return id_q[head_q + 5'(age)];
    return id_q[head_q + 5'($urandom_range(int'(count_q) - 1))];
  endfunction

  // one cycle of caller-contract stimulus, mirroring the reduced proof's assumptions at full size.
  task automatic drive();
    automatic int r = $urandom_range(999);
    automatic int lq = loads, sq = stores;
    flush = 0; recover = 0; allocate = 0; retire = 0; address = 0; data = 0; load_take = 0;
    for (int lane = 0; lane < 2; lane++) begin
      automatic int kind = $urandom_range(2);
      allocate_load[lane] = kind == 1;
      allocate_store[lane] = kind == 2;
    end
    if (r < 3) flush = 1;
    else if (r < 40 && count_q != 0) begin
      recover = 1;
      recover_pick = 5'($urandom_range(int'(count_q) - 1));
    end else begin
      for (int lane = 0; lane < 2; lane++) begin
        automatic logic [4:0] slot = head_q + 5'(lane);
        if ((lane == 0 || retire[0]) && int'(count_q) > lane && $urandom_range(2) != 0
            && (kind_q[slot] != STORE || (address_ready_q[slot] && data_ready_q[slot])))
          retire[lane] = 1;
      end
      for (int lane = 0; lane < 2; lane++) begin
        lq += int'(allocate_load[lane]);
        sq += int'(allocate_store[lane]);
        if ((lane == 0 || allocate[0]) && lq <= LQ && sq <= SQ && int'(count_q) + lane < ROB && $urandom_range(3) != 0)
          allocate[lane] = 1;
      end
    end
    if ($urandom_range(99) < 60) begin
      address = 1;
      address_id = some_id();
      address_size = 2'($urandom_range(2));
      address_value = 32'h100 + 32'($urandom_range(3)) * 4 + ($urandom_range(15) == 0 ? 32'h1000 : 0)
        + (address_size == 0 ? 32'($urandom_range(3)) : address_size == 1 ? 32'($urandom_range(1)) * 2 : 0);
      address_mask = (address_size == 0 ? 4'b0001 : address_size == 1 ? 4'b0011 : 4'b1111) << address_value[1:0];
      address_early = $urandom_range(9) != 0;
      address_unsigned = 1'($urandom);
    end
    if ($urandom_range(1) == 0) begin
      data = 1;
      data_id = address && $urandom_range(3) == 0 ? address_id : some_id();
      data_value = $urandom;
    end
    committed_valid = $urandom_range(9) < 3;
    committed_address = 32'h100 + 32'($urandom_range(3)) * 4;
    committed_mask = 4'($urandom_range(15));
    committed_data = $urandom;
    memory_word = $urandom;
    #1 load_take = load_valid && $urandom_range(9) < 7;
  endtask

  initial begin
    for (int i = 0; i < 8; i++) covered[i] = 0;
    repeat (2) @(posedge clk);
    #1 rst = 0;
    repeat (CYCLES) begin
      drive();
      @(posedge clk);
      #1;
    end
    $display("forward=%0d committed=%0d unknown=%0d data_stall=%0d full=%0d recover_store=%0d stale=%0d dual=%0d wraps=%0d",
             covered[0], covered[1], covered[2], covered[3], covered[4], covered[5], covered[6], covered[7], wraps);
    for (int i = 0; i < 8; i++) if (covered[i] == 0) $fatal(1, "UNCOVERED %0d", i);
    if (wraps < 10) $fatal(1, "UNCOVERED wraps");
    $display("PASS");
    $finish;
  end
endmodule
`default_nettype wire
