`default_nettype none
// tage512 direction predictor, bit-exact with verif/frontend/predictor_model.py (spec: README.md).
// 256x2b base, four 64-entry tagged banks over 4/8/16/32 history bits, immediate update.
// both ports read the state before this cycle's update, so a branch's lookup and update
// must share a cycle to see the model's predict-then-train order.
module tage_predictor #(parameter int AGE_BITS = 18) (  // AGE_BITS < 18 only to test aging
  // inputs
  input  wire clk_i, rst_i,
  input  wire lookup_valid_i,
  input  wire [31:0] lookup_pc_i,
  input  wire update_valid_i, update_taken_i,
  input  wire [31:0] update_pc_i,

  // outputs
  output logic lookup_taken_o
);
  typedef struct packed {
    logic valid;
    logic [7:0] tag;
    logic [2:0] counter;  // signed, >= 0 predicts taken
    logic [1:0] useful;
  } entry_t;
  typedef struct packed {
    logic [7:0] base_index;
    logic [3:0][5:0] index;
    logic [3:0][7:0] tag;
    logic provider_hit, alternate_hit;
    logic [1:0] provider, alternate;
    logic provider_prediction, alternate_prediction, weak_new, prediction;
    logic [1:0] useful;
  } lookup_t;

  logic [255:0][1:0] base_q, base_n;
  entry_t [3:0][63:0] table_q, table_n;
  logic [31:0] history_q;
  logic [3:0] chooser_q, chooser_n;  // signed, >= 0 selects the alternate for weak/new providers
  logic [AGE_BITS-1:0] age_q, age_n;

  // xor of consecutive width-bit chunks
  function automatic logic [7:0] fold(input logic [31:0] h, input int width);
    logic [7:0] r = 0;
    logic [39:0] x = {8'd0, h};  // the last chunk may run past bit 31
    for (int i = 0; i < 32; i += width) r ^= x[i +: 8] & 8'((1 << width) - 1);
    return r;
  endfunction
  function automatic int saturate(input int value, input logic up, input int low, high);
    return up ? (value < high ? value + 1 : high) : (value > low ? value - 1 : low);
  endfunction

  // provider is the longest tag hit, alternate the next longest, else the base
  function automatic lookup_t lookup(input logic [17:2] pc);  // the hashes use no other pc bits
    lookup_t r = '0;
    r.base_index = pc[9:2];
    for (int b = 0; b < 4; b++) begin
      automatic logic [31:0] h = history_q & (32'hffffffff >> (32 - (4 << b)));
      r.index[b] = pc[7:2] ^ pc[13:8] ^ fold(h, 6)[5:0];
      r.tag[b] = pc[9:2] ^ pc[17:10] ^ fold(h, 8) ^ {fold(h, 7)[6:0], 1'b0};
      if (table_q[b][r.index[b]].valid && table_q[b][r.index[b]].tag == r.tag[b]) begin
        r.alternate_hit = r.provider_hit;
        r.alternate = r.provider;
        r.provider_hit = 1;
        r.provider = 2'(b);
      end
    end
    r.alternate_prediction = r.alternate_hit ? !table_q[r.alternate][r.index[r.alternate]].counter[2]
                                             : base_q[r.base_index][1];
    r.provider_prediction = r.alternate_prediction;
    r.prediction = r.alternate_prediction;
    if (r.provider_hit) begin
      automatic logic [2:0] counter = table_q[r.provider][r.index[r.provider]].counter;
      r.provider_prediction = !counter[2];
      r.useful = table_q[r.provider][r.index[r.provider]].useful;
      r.weak_new = r.useful == 0 && (counter == 3'b111 || counter == 3'b000);
      r.prediction = r.weak_new && !chooser_q[3] ? r.alternate_prediction : r.provider_prediction;
    end
    return r;
  endfunction

  assign lookup_taken_o = lookup_valid_i && lookup(lookup_pc_i[17:2]).prediction;
  wire unused = ^{lookup_pc_i[31:18], lookup_pc_i[1:0], update_pc_i[31:18], update_pc_i[1:0]};

  // training, allocation and aging, in model order
  always_comb begin
    automatic lookup_t r = lookup(update_pc_i[17:2]);
    automatic logic taken = update_taken_i;
    base_n = base_q;
    table_n = table_q;
    chooser_n = chooser_q;
    age_n = age_q + 1'b1;
    if (!r.provider_hit) begin
      base_n[r.base_index] = 2'(saturate(int'(base_q[r.base_index]), taken, 0, 3));
    end else begin
      automatic entry_t e = table_q[r.provider][r.index[r.provider]];
      if (r.weak_new && r.provider_prediction != r.alternate_prediction)
        chooser_n = 4'(saturate(int'($signed(chooser_q)), r.alternate_prediction == taken, -8, 7));
      e.counter = 3'(saturate(int'($signed(e.counter)), taken, -4, 3));
      if (r.provider_prediction != r.alternate_prediction)
        e.useful = 2'(saturate(int'(e.useful), r.provider_prediction == taken, 0, 3));
      table_n[r.provider][r.index[r.provider]] = e;
      // usefulness is the pre-update value
      if (r.useful == 0) begin
        if (!r.alternate_hit) begin
          base_n[r.base_index] = 2'(saturate(int'(base_q[r.base_index]), taken, 0, 3));
        end else begin
          e = table_q[r.alternate][r.index[r.alternate]];
          e.counter = 3'(saturate(int'($signed(e.counter)), taken, -4, 3));
          table_n[r.alternate][r.index[r.alternate]] = e;
        end
      end
    end
    // a correct new provider should mature instead of causing another allocation.
    if (r.prediction != taken && !(r.weak_new && r.provider_prediction == taken)) begin
      automatic logic found = 0;
      for (int b = 0; b < 4; b++) begin
        if ((!r.provider_hit || b > int'(r.provider)) && !found
            && (!table_n[b][r.index[b]].valid || table_n[b][r.index[b]].useful == 0)) begin
          table_n[b][r.index[b]] = '{valid: 1, tag: r.tag[b], counter: taken ? 3'b000 : 3'b111, useful: 0};
          found = 1;
        end
      end
      // every longer candidate is useful: wear them down and defer allocation
      if (!found) for (int b = 0; b < 4; b++) if (!r.provider_hit || b > int'(r.provider))
        table_n[b][r.index[b]].useful = table_n[b][r.index[b]].useful - 2'(table_n[b][r.index[b]].useful != 0);
    end
    if (age_n == 0) for (int b = 0; b < 4; b++) for (int i = 0; i < 64; i++)
      table_n[b][i].useful = table_n[b][i].useful >> 1;
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      base_q <= {256{2'b01}};
      table_q <= {256{entry_t'{valid: 0, tag: 0, counter: 3'b111, useful: 0}}};
      history_q <= 0;
      chooser_q <= 0;
      age_q <= 0;
    end else if (update_valid_i) begin
      base_q <= base_n;
      table_q <= table_n;
      chooser_q <= chooser_n;
      age_q <= age_n;
      history_q <= {history_q[30:0], update_taken_i};
    end
  end
endmodule
`default_nettype wire
