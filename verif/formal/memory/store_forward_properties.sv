`default_nettype none
module store_forward_properties #(parameter int CHECK = 4) (
  input wire load_valid,
  input wire [31:0] load_address,
  input wire [1:0] load_size,
  input wire load_unsigned,
  input wire [5:0] load_age,
  input wire [8:0] store_valid, store_killed, store_address_ready,
  input wire [8:0][5:0] store_age,
  input wire [8:0][31:0] store_address, store_data,
  input wire [8:0][3:0] store_mask, store_data_ready,
  input wire [31:0] memory_word,
  input wire [3:0] watched_store,
  input wire [1:0] watched_byte
);
  wire stall;
  wire [3:0] forward_mask, memory_mask;
  wire [31:0] forward_data, result;
  store_forward dut (
    .load_valid_i(load_valid), .load_address_i(load_address), .load_size_i(load_size),
    .load_unsigned_i(load_unsigned), .load_age_i(load_age),
    .store_valid_i(store_valid), .store_killed_i(store_killed), .store_address_ready_i(store_address_ready),
    .store_age_i(store_age), .store_address_i(store_address), .store_data_i(store_data),
    .store_mask_i(store_mask), .store_data_ready_i(store_data_ready), .memory_word_i(memory_word),
    .stall_o(stall), .forward_mask_o(forward_mask), .memory_mask_o(memory_mask),
    .forward_data_o(forward_data), .result_o(result)
  );
  logic legal, unknown_store, missing_data, expected_stall;
  logic [3:0] requested, expected_forward, expected_memory;
  logic [31:0] expected_result, word_value;
  logic [8:0] eligible;
  logic [3:0][8:0] covers_byte, winner;
  integer width_bits;

  always_comb begin
    legal = load_size == 0 || (load_size == 1 && load_address[0] == 0)
      || (load_size == 2 && load_address[1:0] == 0);
    width_bits = load_size == 0 ? 8 : load_size == 1 ? 16 : 32;
    requested = 0;
    unknown_store = 0;
    missing_data = 0;
    expected_forward = 0;
    expected_memory = 0;
    expected_result = 0;
    word_value = memory_word;
    covers_byte = 0;
    winner = 0;
    for (int s = 0; s < 9; s++) begin
      eligible[s] = store_valid[s] && !store_killed[s] && store_age[s] < load_age;
      if (eligible[s] && !store_address_ready[s]) unknown_store = 1;
    end
    for (int b = 0; b < 4; b++) begin
      requested[b] = b >= int'(load_address[1:0]) && b < int'(load_address[1:0]) + width_bits/8;
      for (int s = 0; s < 9; s++)
        covers_byte[b][s] = eligible[s] && store_address_ready[s] && requested[b] && store_mask[s][b]
          && (store_address[s] >> 2) == (load_address >> 2);
      // a winner has no dominating candidate, independent of the dut's running maximum.
      for (int s = 0; s < 9; s++) begin
        winner[b][s] = covers_byte[b][s];
        for (int t = 0; t < 9; t++)
          if (covers_byte[b][t] && (store_age[t] > store_age[s] || (store_age[t] == store_age[s] && t > s)))
            winner[b][s] = 0;
        if (winner[b][s] && !store_data_ready[s][b]) missing_data = 1;
      end
      expected_forward[b] = |winner[b];
      if (expected_forward[b]) word_value[b*8 +: 8] = forward_data[b*8 +: 8];
    end
    expected_stall = load_valid && (!legal || unknown_store || missing_data);
    if (load_valid && legal && !expected_stall) begin
      expected_memory = requested ^ expected_forward;
      for (int bit_index = 0; bit_index < 32; bit_index++) begin
        if (bit_index < width_bits)
          expected_result[bit_index] = word_value[int'(load_address[1:0])*8 + bit_index];
        else
          expected_result[bit_index] = !load_unsigned && word_value[int'(load_address[1:0])*8 + width_bits-1];
      end
    end else begin
      expected_forward = 0;
    end
    if (CHECK == 4 || CHECK == 0) begin
      stall_exact: assert (stall == expected_stall);
    end
    if (CHECK == 4 || CHECK == 1) begin
      mask_exact: assert (forward_mask == expected_forward && memory_mask == expected_memory);
    end
    // arbitrary watched indices prove every source byte without another data mux tree.
    if (CHECK == 4 || CHECK == 2) begin
      data_exact: assert (!(load_valid && legal && !expected_stall) ? forward_data == 0 :
        !expected_forward[watched_byte] ? forward_data[watched_byte*8 +: 8] == 0 :
        watched_store >= 9 || !winner[watched_byte][watched_store]
          || forward_data[watched_byte*8 +: 8] == store_data[watched_store][watched_byte*8 +: 8]);
    end
    if (CHECK == 4 || CHECK == 3) begin
      result_exact: assert (result == expected_result);
    end
    inactive: cover (!load_valid && !stall && result == 0);
    invalid_load: cover (load_valid && !legal && stall);
    memory_only: cover (load_valid && legal && !stall && memory_mask == 15);
    full_forward: cover (load_valid && !stall && forward_mask == 15);
    mixed_memory: cover (load_valid && !stall && forward_mask == 5 && memory_mask == 10);
    split_stores: cover (load_valid && !stall && winner[0][0] && winner[1][1]);
    last_candidate: cover (load_valid && !stall && winner[0][8]);
    unknown_address: cover (load_valid && legal && unknown_store && stall);
    unavailable_byte: cover (load_valid && legal && !unknown_store && missing_data && stall);
    signed_byte: cover (load_valid && !stall && load_size == 0 && !load_unsigned && result[31]);
    unsigned_half: cover (load_valid && !stall && load_size == 1 && load_unsigned && result[15]);
  end
endmodule
`default_nettype wire
