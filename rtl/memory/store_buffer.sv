`default_nettype none
// store buffer: retired cacheable stores in retirement order. The oldest is held on l1_dcache's write port until it
// lands; every entry stays visible to load forwarding until then, entry k being the k-th oldest (age k).
module store_buffer #(parameter int DEPTH = 4) (
  // inputs
  input  wire clk_i, rst_i,
  input  wire push_i,
  input  wire [31:0] push_address_i, push_data_i,
  input  wire [3:0] push_mask_i,
  input  wire drain_done_i,                // l1_dcache write_done_o: the head landed, pop it

  // outputs
  output wire push_ready_o, drain_valid_o,
  output wire [31:0] drain_address_o, drain_data_o,
  output wire [3:0] drain_mask_o,
  output wire empty_o,
  output wire [DEPTH-1:0] entry_valid_o,
  output wire [DEPTH-1:0][31:0] entry_address_o, entry_data_o,
  output wire [DEPTH-1:0][3:0] entry_mask_o
);
  // a pop shifts every entry one place toward the head, so each output is a register with no pointer mux
  logic [DEPTH-1:0] valid_q;
  logic [DEPTH-1:0][31:0] address_q, data_q;
  logic [DEPTH-1:0][3:0] mask_q;
  wire [DEPTH-1:0] shifted = drain_done_i ? valid_q >> 1 : valid_q;
  wire [DEPTH:0] occupied = {shifted, 1'b1};       // [k]: entry k-1 is held after the pop, or k is 0
  wire [DEPTH-1:0][31:0] address_up = {32'd0, address_q[DEPTH-1:1]};
  wire [DEPTH-1:0][31:0] data_up = {32'd0, data_q[DEPTH-1:1]};
  wire [DEPTH-1:0][3:0] mask_up = {4'd0, mask_q[DEPTH-1:1]};

  assign push_ready_o = !valid_q[DEPTH-1];
  assign drain_valid_o = valid_q[0];
  assign drain_address_o = address_q[0];
  assign drain_data_o = data_q[0];
  assign drain_mask_o = mask_q[0];
  assign empty_o = !valid_q[0];
  assign entry_valid_o = valid_q;
  assign entry_address_o = address_q;
  assign entry_data_o = data_q;
  assign entry_mask_o = mask_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) valid_q <= '0;
    else valid_q <= shifted | (push_i ? occupied[DEPTH-1:0] & ~shifted : '0);
    for (int k = 0; k < DEPTH; k++)
      // a push lands in the first entry free after this cycle's pop
      if (push_i && !shifted[k] && occupied[k]) begin
        address_q[k] <= push_address_i;
        data_q[k] <= push_data_i;
        mask_q[k] <= push_mask_i;
      end else if (drain_done_i) begin
        address_q[k] <= address_up[k];
        data_q[k] <= data_up[k];
        mask_q[k] <= mask_up[k];
      end
  end

  // checks
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) if (!rst_i) begin
    assert (!push_i || push_ready_o) else $fatal(1, "SB_PUSH_FULL");
    assert (!drain_done_i || drain_valid_o) else $fatal(1, "SB_POP_EMPTY");
    // held entries form a prefix from the head
    assert ((valid_q & (valid_q + 1'b1)) == '0) else $fatal(1, "SB_SHAPE");
  end
`endif
endmodule
`default_nettype wire
