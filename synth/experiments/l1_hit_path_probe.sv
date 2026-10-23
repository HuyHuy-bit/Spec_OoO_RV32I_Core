`default_nettype none
// Timing probe only: array read, 2-way tag compare and 256-to-32 way/word select between registers.
// Instance a registers the read inside the array (read path alone, then compare+select in the next stage);
// instance b reads combinationally so compare+select share the read cycle (HIT_STAGES=1).
module l1_hit_path_probe (
  // inputs
  input  wire clk_i,
  input  wire rst_i,
  input  wire [3:0] read_set_i,
  input  wire [22:0] query_tag_i,
  input  wire [2:0] word_i,
  input  wire write_i,
  input  wire write_tag_i,
  input  wire [3:0] write_set_i,
  input  wire write_way_i,
  input  wire [22:0] write_tag_value_i,
  input  wire [31:0] write_byte_mask_i,
  input  wire [255:0] write_data_i,
  // outputs
  output logic [32:0] hit_data_a_o,
  output logic [32:0] hit_data_b_o
);
  logic [3:0] read_set_q;
  logic [22:0] query_tag_q;
  logic [2:0] word_q;
  logic [1:0][22:0] tag_a, tag_b;
  logic [1:0][255:0] data_a, data_b;
  logic [2:0] word_a_q;
  logic [22:0] query_a_q;

  l1_cache_array #(.REGISTER_READ(1'b1)) array_a (
    .clk_i, .rst_i, .read_set_i(read_set_q), .write_i, .write_tag_i, .write_set_i, .write_way_i,
    .write_tag_value_i, .write_byte_mask_i, .write_data_i, .read_tag_o(tag_a), .read_data_o(data_a));
  l1_cache_array #(.REGISTER_READ(1'b0)) array_b (
    .clk_i, .rst_i, .read_set_i(read_set_q), .write_i, .write_tag_i, .write_set_i, .write_way_i,
    .write_tag_value_i, .write_byte_mask_i, .write_data_i, .read_tag_o(tag_b), .read_data_o(data_b));

  function automatic logic [32:0] hit_select(input logic [1:0][22:0] tags, input logic [1:0][255:0] data,
                                              input logic [22:0] query, input logic [2:0] word);
    logic [1:0] hit;
    logic [31:0] picked;
    hit = {tags[1] == query, tags[0] == query};
    picked = ({32{hit[0]}} & data[0][32*word +: 32]) | ({32{hit[1]}} & data[1][32*word +: 32]);
    return {|hit, picked};
  endfunction

  always_ff @(posedge clk_i) begin
    read_set_q <= read_set_i;
    query_tag_q <= query_tag_i;
    word_q <= word_i;
    query_a_q <= query_tag_q;
    word_a_q <= word_q;
    hit_data_a_o <= hit_select(tag_a, data_a, query_a_q, word_a_q);
    hit_data_b_o <= hit_select(tag_b, data_b, query_tag_q, word_q);
  end
endmodule
`default_nettype wire
