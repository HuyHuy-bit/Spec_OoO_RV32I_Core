`default_nettype none
// simulation only: the trace build and the physical build (TRACE=0) run in lockstep on the same inputs.
// outputs come from the trace build; every cycle the physical build must drive the same valids and
// handshakes, the same payload under each valid, and the same event fields the hardware reads. generated from cpu_top's port
// list; `.*` makes a port change fail the build.
module trace_lockstep #(parameter bit FRONTEND_FAULTS = 1, parameter bit TRAP_SERVICE = 1, parameter bit MEMORY_SERVICE = 0,
                        parameter bit EARLY_LOADS = 0, parameter bit TAGE = 1, parameter bit DCACHE = 0,
                        parameter bit ICACHE = 0) (
  // inputs
  input  wire clk_i, rst_i, enable_i, flush_i, drained_i,
  input  wire [31:0] flush_pc_i,
  input  wire request_ready_i,
  input  wire response_valid_i,
  input  memory_protocol_pkg::mem_response_t response_i,
  input  wire data_request_ready_i,
  input  wire data_response_valid_i,
  input  memory_protocol_pkg::mem_response_t data_response_i,
  input  wire memory_issue_allowed_i, admit_valid_i,
  input  wire [12:0] admit_id_i,
  input  wire [1:0] execution_ready_i, completion_enable_i, retire_ready_i,
  input  wire resolve_grant_i,
  input  wire trap_ready_i,

  // outputs
  output wire request_valid_o,
  output memory_protocol_pkg::mem_request_t request_o,
  output wire response_ready_o,
  output wire data_request_valid_o,
  output memory_protocol_pkg::mem_request_t data_request_o,
  output wire data_response_ready_o,
  output wire admission_valid_o,
  output wire [12:0] admission_id_o,
  output wire [31:0] admission_address_o, admission_data_o,
  output wire [3:0] admission_mask_o,
  output wire [1:0] admission_size_o,
  output wire memory_prepare_o, memory_busy_o, memory_committed_o, memory_irrevocable_o, memory_fatal_o,
  output wire committed_valid_o,
  output wire [31:0] committed_address_o, committed_data_o,
  output wire [3:0] committed_mask_o,
  output wire flush_ready_o,
  output wire [1:0] fetch_valid_o, dispatch_o, unsupported_o, producer_busy_o,
  output wire [63:0] fetch_pc_o, fetch_instruction_o,
  output wire fetch_busy_o, fetch_fault_o,
  output wire [31:0] fetch_fault_cause_o,
  output wire [1:0] retire_valid_o, retire_accept_o,
  output commit_event_pkg::commit_event_t [1:0] retire_event_o,
  output wire redirect_o,
  output wire [31:0] redirect_pc_o,
  output wire trap_valid_o, trap_accept_o,
  output commit_event_pkg::commit_event_t trap_event_o,
  output wire backend_fault_o,
  output commit_event_pkg::commit_event_t backend_fault_event_o,
  output wire [5:0] occupancy_o,
  output wire system_prepare_o, system_busy_o,
  output wire identity_drain_o, fatal_o
);
  import commit_event_pkg::*;
  // the comparison deliberately reads only the hardware-visible bits of each event
  /* verilator lint_off UNUSEDSIGNAL */
  cpu_top #(.FRONTEND_FAULTS(FRONTEND_FAULTS), .TRAP_SERVICE(TRAP_SERVICE), .MEMORY_SERVICE(MEMORY_SERVICE), .EARLY_LOADS(EARLY_LOADS), .TAGE(TAGE), .DCACHE(DCACHE), .ICACHE(ICACHE), .TRACE(1)) full (.*);

  wire lean_request_valid_o;
  memory_protocol_pkg::mem_request_t lean_request_o;
  wire lean_response_ready_o;
  wire lean_data_request_valid_o;
  memory_protocol_pkg::mem_request_t lean_data_request_o;
  wire lean_data_response_ready_o;
  wire lean_admission_valid_o;
  wire [12:0] lean_admission_id_o;
  wire [31:0] lean_admission_address_o, lean_admission_data_o;
  wire [3:0] lean_admission_mask_o;
  wire [1:0] lean_admission_size_o;
  wire lean_memory_prepare_o, lean_memory_busy_o, lean_memory_committed_o, lean_memory_irrevocable_o, lean_memory_fatal_o;
  wire lean_committed_valid_o;
  wire [31:0] lean_committed_address_o, lean_committed_data_o;
  wire [3:0] lean_committed_mask_o;
  wire lean_flush_ready_o;
  wire [1:0] lean_fetch_valid_o, lean_dispatch_o, lean_unsupported_o, lean_producer_busy_o;
  wire [63:0] lean_fetch_pc_o, lean_fetch_instruction_o;
  wire lean_fetch_busy_o, lean_fetch_fault_o;
  wire [31:0] lean_fetch_fault_cause_o;
  wire [1:0] lean_retire_valid_o, lean_retire_accept_o;
  commit_event_pkg::commit_event_t [1:0] lean_retire_event_o;
  wire lean_redirect_o;
  wire [31:0] lean_redirect_pc_o;
  wire lean_trap_valid_o, lean_trap_accept_o;
  commit_event_pkg::commit_event_t lean_trap_event_o;
  wire lean_backend_fault_o;
  commit_event_pkg::commit_event_t lean_backend_fault_event_o;
  wire [5:0] lean_occupancy_o;
  wire lean_system_prepare_o, lean_system_busy_o;
  wire lean_identity_drain_o, lean_fatal_o;
  cpu_top #(.FRONTEND_FAULTS(FRONTEND_FAULTS), .TRAP_SERVICE(TRAP_SERVICE), .MEMORY_SERVICE(MEMORY_SERVICE), .EARLY_LOADS(EARLY_LOADS), .TAGE(TAGE), .DCACHE(DCACHE), .ICACHE(ICACHE), .TRACE(0)) lean (.clk_i, .rst_i, .enable_i, .flush_i, .drained_i, .flush_pc_i, .request_ready_i, .response_valid_i, .response_i, .data_request_ready_i, .data_response_valid_i, .data_response_i, .memory_issue_allowed_i, .admit_valid_i, .admit_id_i, .execution_ready_i, .completion_enable_i, .retire_ready_i, .resolve_grant_i, .trap_ready_i,
    .request_valid_o(lean_request_valid_o),
    .request_o(lean_request_o),
    .response_ready_o(lean_response_ready_o),
    .data_request_valid_o(lean_data_request_valid_o),
    .data_request_o(lean_data_request_o),
    .data_response_ready_o(lean_data_response_ready_o),
    .admission_valid_o(lean_admission_valid_o),
    .admission_id_o(lean_admission_id_o),
    .admission_address_o(lean_admission_address_o),
    .admission_data_o(lean_admission_data_o),
    .admission_mask_o(lean_admission_mask_o),
    .admission_size_o(lean_admission_size_o),
    .memory_prepare_o(lean_memory_prepare_o),
    .memory_busy_o(lean_memory_busy_o),
    .memory_committed_o(lean_memory_committed_o),
    .memory_irrevocable_o(lean_memory_irrevocable_o),
    .memory_fatal_o(lean_memory_fatal_o),
    .committed_valid_o(lean_committed_valid_o),
    .committed_address_o(lean_committed_address_o),
    .committed_data_o(lean_committed_data_o),
    .committed_mask_o(lean_committed_mask_o),
    .flush_ready_o(lean_flush_ready_o),
    .fetch_valid_o(lean_fetch_valid_o),
    .dispatch_o(lean_dispatch_o),
    .unsupported_o(lean_unsupported_o),
    .producer_busy_o(lean_producer_busy_o),
    .fetch_pc_o(lean_fetch_pc_o),
    .fetch_instruction_o(lean_fetch_instruction_o),
    .fetch_busy_o(lean_fetch_busy_o),
    .fetch_fault_o(lean_fetch_fault_o),
    .fetch_fault_cause_o(lean_fetch_fault_cause_o),
    .retire_valid_o(lean_retire_valid_o),
    .retire_accept_o(lean_retire_accept_o),
    .retire_event_o(lean_retire_event_o),
    .redirect_o(lean_redirect_o),
    .redirect_pc_o(lean_redirect_pc_o),
    .trap_valid_o(lean_trap_valid_o),
    .trap_accept_o(lean_trap_accept_o),
    .trap_event_o(lean_trap_event_o),
    .backend_fault_o(lean_backend_fault_o),
    .backend_fault_event_o(lean_backend_fault_event_o),
    .occupancy_o(lean_occupancy_o),
    .system_prepare_o(lean_system_prepare_o),
    .system_busy_o(lean_system_busy_o),
    .identity_drain_o(lean_identity_drain_o),
    .fatal_o(lean_fatal_o)
  );

  // retire events: the predictor and committed pc read pc_before, pc_after and opcode/rd/rs1.
  function automatic logic retire_same(commit_event_t a, commit_event_t b);
    return a.valid == b.valid && a.retired == b.retired && a.trap == b.trap && a.pc_before == b.pc_before
      && a.pc_after == b.pc_after && a.instruction[19:15] == b.instruction[19:15] && a.instruction[11:0] == b.instruction[11:0];
  endfunction
  // trap events: mepc, mcause, mtval, the redirect and the csr writes.
  function automatic logic trap_same(commit_event_t a, commit_event_t b);
    return a.valid == b.valid && a.trap == b.trap && a.pc_before == b.pc_before && a.pc_after == b.pc_after
      && a.trap_cause == b.trap_cause && a.trap_value == b.trap_value && a.csr_effects == b.csr_effects;
  endfunction

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      assert (lean_request_valid_o == request_valid_o) else $fatal(1, "LOCKSTEP request_valid_o");
      assert (!request_valid_o || lean_request_o == request_o) else $fatal(1, "LOCKSTEP request_o");
      assert (lean_response_ready_o == response_ready_o) else $fatal(1, "LOCKSTEP response_ready_o");
      assert (lean_data_request_valid_o == data_request_valid_o) else $fatal(1, "LOCKSTEP data_request_valid_o");
      assert (!data_request_valid_o || lean_data_request_o == data_request_o) else $fatal(1, "LOCKSTEP data_request_o");
      assert (lean_data_response_ready_o == data_response_ready_o) else $fatal(1, "LOCKSTEP data_response_ready_o");
      assert (lean_admission_valid_o == admission_valid_o) else $fatal(1, "LOCKSTEP admission_valid_o");
      assert (!admission_valid_o || lean_admission_id_o == admission_id_o) else $fatal(1, "LOCKSTEP admission_id_o");
      assert (!admission_valid_o || lean_admission_address_o == admission_address_o) else $fatal(1, "LOCKSTEP admission_address_o");
      assert (!admission_valid_o || lean_admission_data_o == admission_data_o) else $fatal(1, "LOCKSTEP admission_data_o");
      assert (!admission_valid_o || lean_admission_mask_o == admission_mask_o) else $fatal(1, "LOCKSTEP admission_mask_o");
      assert (!admission_valid_o || lean_admission_size_o == admission_size_o) else $fatal(1, "LOCKSTEP admission_size_o");
      assert (lean_memory_prepare_o == memory_prepare_o) else $fatal(1, "LOCKSTEP memory_prepare_o");
      assert (lean_memory_busy_o == memory_busy_o) else $fatal(1, "LOCKSTEP memory_busy_o");
      assert (lean_memory_committed_o == memory_committed_o) else $fatal(1, "LOCKSTEP memory_committed_o");
      assert (lean_memory_irrevocable_o == memory_irrevocable_o) else $fatal(1, "LOCKSTEP memory_irrevocable_o");
      assert (lean_memory_fatal_o == memory_fatal_o) else $fatal(1, "LOCKSTEP memory_fatal_o");
      assert (lean_committed_valid_o == committed_valid_o) else $fatal(1, "LOCKSTEP committed_valid_o");
      assert (!committed_valid_o || lean_committed_address_o == committed_address_o) else $fatal(1, "LOCKSTEP committed_address_o");
      assert (!committed_valid_o || lean_committed_data_o == committed_data_o) else $fatal(1, "LOCKSTEP committed_data_o");
      assert (!committed_valid_o || lean_committed_mask_o == committed_mask_o) else $fatal(1, "LOCKSTEP committed_mask_o");
      assert (lean_flush_ready_o == flush_ready_o) else $fatal(1, "LOCKSTEP flush_ready_o");
      assert (lean_fetch_valid_o == fetch_valid_o) else $fatal(1, "LOCKSTEP fetch_valid_o");
      assert (lean_dispatch_o == dispatch_o) else $fatal(1, "LOCKSTEP dispatch_o");
      assert (((lean_unsupported_o ^ unsupported_o) & fetch_valid_o) == 0) else $fatal(1, "LOCKSTEP unsupported_o");
      assert (lean_producer_busy_o == producer_busy_o) else $fatal(1, "LOCKSTEP producer_busy_o");
      for (int lane = 0; lane < 2; lane++)
        assert (!fetch_valid_o[lane] || lean_fetch_pc_o[lane*32 +: 32] == fetch_pc_o[lane*32 +: 32]) else $fatal(1, "LOCKSTEP fetch_pc_o");
      for (int lane = 0; lane < 2; lane++)
        assert (!fetch_valid_o[lane] || lean_fetch_instruction_o[lane*32 +: 32] == fetch_instruction_o[lane*32 +: 32]) else $fatal(1, "LOCKSTEP fetch_instruction_o");
      assert (lean_fetch_busy_o == fetch_busy_o) else $fatal(1, "LOCKSTEP fetch_busy_o");
      assert (lean_fetch_fault_o == fetch_fault_o) else $fatal(1, "LOCKSTEP fetch_fault_o");
      assert (!fetch_fault_o || lean_fetch_fault_cause_o == fetch_fault_cause_o) else $fatal(1, "LOCKSTEP fetch_fault_cause_o");
      assert (lean_retire_valid_o == retire_valid_o) else $fatal(1, "LOCKSTEP retire_valid_o");
      assert (lean_retire_accept_o == retire_accept_o) else $fatal(1, "LOCKSTEP retire_accept_o");
      assert (lean_redirect_o == redirect_o) else $fatal(1, "LOCKSTEP redirect_o");
      assert (!redirect_o || lean_redirect_pc_o == redirect_pc_o) else $fatal(1, "LOCKSTEP redirect_pc_o");
      assert (lean_trap_valid_o == trap_valid_o) else $fatal(1, "LOCKSTEP trap_valid_o");
      assert (lean_trap_accept_o == trap_accept_o) else $fatal(1, "LOCKSTEP trap_accept_o");
      assert (lean_backend_fault_o == backend_fault_o) else $fatal(1, "LOCKSTEP backend_fault_o");
      assert (lean_occupancy_o == occupancy_o) else $fatal(1, "LOCKSTEP occupancy_o");
      assert (lean_system_prepare_o == system_prepare_o) else $fatal(1, "LOCKSTEP system_prepare_o");
      assert (lean_system_busy_o == system_busy_o) else $fatal(1, "LOCKSTEP system_busy_o");
      assert (lean_identity_drain_o == identity_drain_o) else $fatal(1, "LOCKSTEP identity_drain_o");
      assert (lean_fatal_o == fatal_o) else $fatal(1, "LOCKSTEP fatal_o");
      for (int lane = 0; lane < 2; lane++)
        assert (!retire_valid_o[lane] || retire_same(lean_retire_event_o[lane], retire_event_o[lane]))
          else $fatal(1, "LOCKSTEP retire_event_o");
      assert (!trap_valid_o || trap_same(lean_trap_event_o, trap_event_o)) else $fatal(1, "LOCKSTEP trap_event_o");
      assert (!backend_fault_o || (lean_backend_fault_event_o.trap == backend_fault_event_o.trap
          && lean_backend_fault_event_o.pc_before == backend_fault_event_o.pc_before
          && lean_backend_fault_event_o.trap_cause == backend_fault_event_o.trap_cause
          && lean_backend_fault_event_o.trap_value == backend_fault_event_o.trap_value))
        else $fatal(1, "LOCKSTEP backend_fault_event_o");
    end
  end
`endif
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
