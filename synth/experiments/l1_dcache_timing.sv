`default_nettype none
// Timing top only: l1_dcache with its writeback mask outputs tied off. Every mask bit equals the request's write
// bit, and those aliased top-level ports leave an assign in the netlist that the pinned OpenSTA cannot read.
module l1_dcache_timing (
  // inputs
  input  wire clk_i, rst_i, kill_i,
  input  wire load_valid_i,
  input  wire [12:0] load_id_i,
  input  wire [31:0] load_address_i,
  input  wire [1:0] load_size_i,
  input  wire load_unsigned_i,
  input  wire write_valid_i,
  input  wire [31:0] write_address_i, write_data_i,
  input  wire [3:0] write_mask_i,
  input  wire clean_i,
  input  wire mem_request_ready_i, mem_response_valid_i,
  input  memory_protocol_pkg::mem_response_t mem_response_i,
  // outputs
  output wire load_ready_o,
  output wire response_valid_o,
  output wire [12:0] response_id_o,
  output wire [31:0] response_data_o,
  output wire write_done_o, clean_done_o, busy_o, fatal_o,
  output wire mem_request_valid_o,
  output memory_protocol_pkg::mem_request_t mem_request_o,
  output wire mem_response_ready_o
);
  memory_protocol_pkg::mem_request_t request;
  l1_dcache u_dcache (.*, .mem_request_o(request));
  always_comb begin
    mem_request_o = request;
    mem_request_o.line_write_mask = '0;
  end
endmodule
`default_nettype wire
