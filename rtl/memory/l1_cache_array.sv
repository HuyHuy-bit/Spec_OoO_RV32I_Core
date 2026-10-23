`default_nettype none
// Flop storage shared by the L1 caches. Valid, dirty, LRU and pin bits live in each cache, so nothing here resets.
// Read data is registered and a same-cycle write is not forwarded: the cache must not rely on bypass.
// REGISTER_READ=0 exposes the combinational read for the 20 ns hit-path probe only.
module l1_cache_array #(
  parameter int SETS = 16,
  parameter int WAYS = 2,
  parameter int TAG_BITS = 23,
  parameter bit REGISTER_READ = 1'b1
) (
  // inputs
  input  wire clk_i,
  /* verilator lint_off UNUSEDSIGNAL */
  input  wire rst_i,
  /* verilator lint_on UNUSEDSIGNAL */
  input  wire [$clog2(SETS)-1:0] read_set_i,
  input  wire write_i,
  input  wire write_tag_i,
  input  wire [$clog2(SETS)-1:0] write_set_i,
  input  wire [$clog2(WAYS)-1:0] write_way_i,
  input  wire [TAG_BITS-1:0] write_tag_value_i,
  input  wire [31:0] write_byte_mask_i,
  input  wire [255:0] write_data_i,
  // outputs
  output logic [WAYS-1:0][TAG_BITS-1:0] read_tag_o,
  output logic [WAYS-1:0][255:0] read_data_o
);
  logic [SETS-1:0][WAYS-1:0][TAG_BITS-1:0] tag_q;
  logic [SETS-1:0][WAYS-1:0][255:0] data_q;

  always_ff @(posedge clk_i) begin
    if (write_i) begin
      if (write_tag_i) tag_q[write_set_i][write_way_i] <= write_tag_value_i;
      for (int b = 0; b < 32; b++)
        if (write_byte_mask_i[b]) data_q[write_set_i][write_way_i][8*b +: 8] <= write_data_i[8*b +: 8];
    end
  end

  if (REGISTER_READ) begin : g_registered
    always_ff @(posedge clk_i) begin
      read_tag_o <= tag_q[read_set_i];
      read_data_o <= data_q[read_set_i];
    end
  end else begin : g_combinational
    always_comb begin
      read_tag_o = tag_q[read_set_i];
      read_data_o = data_q[read_set_i];
    end
  end
endmodule
`default_nettype wire
