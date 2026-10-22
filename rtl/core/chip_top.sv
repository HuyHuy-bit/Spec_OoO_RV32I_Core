`default_nettype none
// physical top: cpu_top without trace state, the bench controls tied to always-ready, and only the
// instruction and data memory ports plus fatal as pins. stores are admitted as soon as they are offered.
module chip_top (
  input  wire clk_i, rst_i,
  // instruction port
  output wire request_valid_o,
  output memory_protocol_pkg::mem_request_t request_o,
  input  wire request_ready_i,
  input  wire response_valid_i,
  input  memory_protocol_pkg::mem_response_t response_i,
  output wire response_ready_o,
  // data port
  output wire data_request_valid_o,
  output memory_protocol_pkg::mem_request_t data_request_o,
  input  wire data_request_ready_i,
  input  wire data_response_valid_i,
  input  memory_protocol_pkg::mem_response_t data_response_i,
  output wire data_response_ready_o,
  output wire fatal_o
);
  wire admission_valid;
  wire [12:0] admission_id;

  cpu_top #(.FRONTEND_FAULTS(1), .TRAP_SERVICE(1), .MEMORY_SERVICE(1), .EARLY_LOADS(1), .TRACE(0)) core (
    .clk_i, .rst_i, .enable_i(1'b1), .flush_i(1'b0), .drained_i(1'b0), .flush_pc_i(32'd0),
    .request_ready_i, .response_valid_i, .response_i,
    .data_request_ready_i, .data_response_valid_i, .data_response_i,
    .memory_issue_allowed_i(1'b1), .admit_valid_i(admission_valid), .admit_id_i(admission_id),
    .execution_ready_i(2'b11), .completion_enable_i(2'b11), .retire_ready_i(2'b11),
    .resolve_grant_i(1'b1), .trap_ready_i(1'b1),
    .request_valid_o, .request_o, .response_ready_o,
    .data_request_valid_o, .data_request_o, .data_response_ready_o,
    .admission_valid_o(admission_valid), .admission_id_o(admission_id),
    .admission_address_o(), .admission_data_o(), .admission_mask_o(), .admission_size_o(),
    .memory_prepare_o(), .memory_busy_o(), .memory_committed_o(), .memory_irrevocable_o(), .memory_fatal_o(),
    .flush_ready_o(), .fetch_valid_o(), .dispatch_o(), .unsupported_o(), .producer_busy_o(),
    .fetch_pc_o(), .fetch_instruction_o(), .fetch_busy_o(), .fetch_fault_o(), .fetch_fault_cause_o(),
    .retire_valid_o(), .retire_accept_o(), .retire_event_o(), .redirect_o(), .redirect_pc_o(),
    .trap_valid_o(), .trap_accept_o(), .trap_event_o(), .backend_fault_o(), .backend_fault_event_o(),
    .occupancy_o(), .system_prepare_o(), .system_busy_o(), .identity_drain_o(), .fatal_o
  );
endmodule
`default_nettype wire
