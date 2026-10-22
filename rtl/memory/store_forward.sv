`default_nettype none
// store-to-load forwarding selector: per byte, the youngest older store wins; unknown addresses stall.
module store_forward #(parameter int CANDIDATES = 9) (
  // inputs
  input  wire load_valid_i,
  input  wire [31:0] load_address_i,
  input  wire [1:0] load_size_i,
  input  wire load_unsigned_i,
  input  wire [5:0] load_age_i,
  input  wire [CANDIDATES-1:0] store_valid_i, store_killed_i, store_address_ready_i,
  input  wire [CANDIDATES-1:0][5:0] store_age_i,
  input  wire [CANDIDATES-1:0][31:0] store_address_i, store_data_i,
  input  wire [CANDIDATES-1:0][3:0] store_mask_i, store_data_ready_i,
  input  wire [31:0] memory_word_i,

  // outputs
  output logic stall_o,
  output logic [3:0] forward_mask_o, memory_mask_o,
  output logic [31:0] forward_data_o, result_o
);

  // load legality and requested bytes
  wire legal_load = load_size_i <= 2
    && (load_size_i != 1 || !load_address_i[0])
    && (load_size_i != 2 || load_address_i[1:0] == 0);
  wire [3:0] requested = (load_size_i == 0 ? 4'b0001 : load_size_i == 1 ? 4'b0011 : 4'b1111)
    << load_address_i[1:0];
  wire [CANDIDATES-1:0] older;

  // older-store eligibility
  for (genvar s = 0; s < CANDIDATES; s++) begin : candidates
    assign older[s] = store_valid_i[s] && !store_killed_i[s] && store_age_i[s] < load_age_i;
  end
  logic [31:0] merged, shifted;

  // youngest-store selection and byte merge
  always_comb begin
    stall_o = load_valid_i && !legal_load;
    forward_mask_o = 0;
    memory_mask_o = 0;
    forward_data_o = 0;
    result_o = 0;
    merged = memory_word_i;
    shifted = 0;
    if (load_valid_i && legal_load) begin
      for (int s = 0; s < CANDIDATES; s++)
        if (older[s] && !store_address_ready_i[s]) stall_o = 1;
      for (int b = 0; b < 4; b++) begin
        logic found, ready_byte;
        logic [5:0] youngest;
        found = 0;
        ready_byte = 0;
        youngest = 0;
        for (int s = 0; s < CANDIDATES; s++) begin
          if (requested[b] && older[s] && store_address_ready_i[s]
              && store_address_i[s][31:2] == load_address_i[31:2] && store_mask_i[s][b]
              && (!found || store_age_i[s] >= youngest)) begin
            found = 1;
            youngest = store_age_i[s];
            ready_byte = store_data_ready_i[s][b];
            forward_data_o[b*8 +: 8] = store_data_i[s][b*8 +: 8];
          end
        end
        forward_mask_o[b] = found;
        // select by age before checking readiness; an older value cannot substitute.
        if (found && !ready_byte) stall_o = 1;
        if (found) merged[b*8 +: 8] = forward_data_o[b*8 +: 8];
      end
      memory_mask_o = requested & ~forward_mask_o;
      shifted = merged >> {load_address_i[1:0], 3'b000};
      case (load_size_i)
        0: result_o = {{24{!load_unsigned_i && shifted[7]}}, shifted[7:0]};
        1: result_o = {{16{!load_unsigned_i && shifted[15]}}, shifted[15:0]};
        default: result_o = shifted;
      endcase
    end
    if (stall_o) begin
      forward_mask_o = 0;
      memory_mask_o = 0;
      forward_data_o = 0;
      result_o = 0;
    end
  end
endmodule
`default_nettype wire
