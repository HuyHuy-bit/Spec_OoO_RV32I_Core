`default_nettype none
// Area experiment: l1_cache_array with plain flops behind per-byte (data) and per-entry (tag) clock gates
// instead of enable flops. Ports and behaviour match l1_cache_array; only the write clocking differs.
// The SYNTHESIS branch instantiates the sky130 cell; simulation uses a latch-and-AND model of it.

`ifdef SYNTHESIS
(* blackbox *) module sky130_fd_sc_hd__dlclkp_1 (input wire CLK, input wire GATE, output wire GCLK);
endmodule
`endif

/* verilator lint_off DECLFILENAME */
module l1_cache_array_cg_gate (
  // inputs
  input  wire clk_i,
  input  wire enable_i,
  // outputs
  output wire gclk_o
);
`ifdef SYNTHESIS
  sky130_fd_sc_hd__dlclkp_1 u_gate (.CLK(clk_i), .GATE(enable_i), .GCLK(gclk_o));
`else
  // the latch is transparent while the clock is low, so a late enable cannot glitch the gated clock
  logic enable_q;
  always_latch if (!clk_i) enable_q = enable_i;
  assign gclk_o = clk_i & enable_q;
`endif
endmodule
/* verilator lint_on DECLFILENAME */

// Valid, dirty, LRU and pin bits live in each cache, so nothing here resets.
// Read data is registered and a same-cycle write is not forwarded: the cache must not rely on bypass.
// REGISTER_READ=0 exposes the combinational read for the 20 ns hit-path probe only.
module l1_cache_array_cg #(
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
  wire [SETS-1:0][WAYS-1:0][TAG_BITS-1:0] tag_q;
  wire [SETS-1:0][WAYS-1:0][255:0] data_q;

  for (genvar s = 0; s < SETS; s++) begin : g_set
    for (genvar w = 0; w < WAYS; w++) begin : g_way
      wire entry_write = write_i && write_set_i == $clog2(SETS)'(s) && write_way_i == $clog2(WAYS)'(w);
      wire tag_gclk;
      logic [TAG_BITS-1:0] entry_tag_q;

      l1_cache_array_cg_gate u_tag_gate (.clk_i(clk_i), .enable_i(entry_write && write_tag_i), .gclk_o(tag_gclk));
      always_ff @(posedge tag_gclk) entry_tag_q <= write_tag_value_i;
      assign tag_q[s][w] = entry_tag_q;

      for (genvar b = 0; b < 32; b++) begin : g_byte
        wire byte_gclk;
        logic [7:0] byte_q;

        l1_cache_array_cg_gate u_gate (.clk_i(clk_i), .enable_i(entry_write && write_byte_mask_i[b]),
                                       .gclk_o(byte_gclk));
        always_ff @(posedge byte_gclk) byte_q <= write_data_i[8*b +: 8];
        assign data_q[s][w][8*b +: 8] = byte_q;
      end
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
