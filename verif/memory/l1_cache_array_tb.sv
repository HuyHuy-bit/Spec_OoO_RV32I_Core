`default_nettype none
// random reads and masked writes against an associative-array shadow; reads are checked one cycle later.
module l1_cache_array_tb #(parameter int CYCLES = 20000);
  localparam int SETS = 16, WAYS = 2, TAG_BITS = 23;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1, write = 0, write_tag = 0;
  logic [3:0] read_set = 0, write_set = 0;
  logic write_way = 0;
  logic [TAG_BITS-1:0] write_tag_value = 0;
  logic [31:0] write_mask = 0;
  logic [255:0] write_data = 0;
  wire [WAYS-1:0][TAG_BITS-1:0] read_tag;
  wire [WAYS-1:0][255:0] read_data;
  l1_cache_array #(.SETS(SETS), .WAYS(WAYS), .TAG_BITS(TAG_BITS)) dut (
    .clk_i(clk), .rst_i(rst), .read_set_i(read_set), .write_i(write), .write_tag_i(write_tag),
    .write_set_i(write_set), .write_way_i(write_way), .write_tag_value_i(write_tag_value),
    .write_byte_mask_i(write_mask), .write_data_i(write_data), .read_tag_o(read_tag), .read_data_o(read_data));

  // shadow only holds what was written; unwritten bits are never compared (storage is not reset).
  logic [TAG_BITS-1:0] tag_shadow[int];
  logic [255:0] data_shadow[int];
  logic [255:0] data_known[int];
  int reads = 0, writes = 0, same_set = 0;

  function automatic int key(int set, int way);
    return set * WAYS + way;
  endfunction

  // expected values captured at the read edge, compared after the next edge
  logic [WAYS-1:0][TAG_BITS-1:0] exp_tag, tag_known;
  logic [WAYS-1:0][255:0] exp_data, data_mask;
  logic check_pending = 0;

  task automatic cycle(input bit do_read, input bit do_write, input int rset, input int wset);
    int k;
    logic [255:0] cur, known;
    read_set = 4'(rset);
    write = do_write;
    write_set = 4'(wset);
    write_way = 1'($urandom);
    write_tag = 1'($urandom);
    write_tag_value = TAG_BITS'($urandom);
    write_mask = ($urandom_range(3) == 0) ? 32'hffffffff : 32'($urandom);
    write_data = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
    check_pending = 0;
    if (do_read) begin
      for (int w = 0; w < WAYS; w++) begin
        k = key(rset, w);
        {exp_tag[w], tag_known[w], exp_data[w], data_mask[w]} = '0;
        if (tag_shadow.exists(k)) begin exp_tag[w] = tag_shadow[k]; tag_known[w] = '1; end
        if (data_known.exists(k)) begin exp_data[w] = data_shadow[k]; data_mask[w] = data_known[k]; end
      end
      check_pending = 1;
      reads++;
    end
    @(posedge clk);  // write and read sample here; the read sees the pre-write contents
    if (do_write) begin
      k = key(wset, int'(write_way));
      cur = '0;
      known = '0;
      if (data_known.exists(k)) begin cur = data_shadow[k]; known = data_known[k]; end
      for (int b = 0; b < 32; b++)
        if (write_mask[b]) begin
          cur[8*b +: 8] = write_data[8*b +: 8];
          known[8*b +: 8] = 8'hff;
        end
      data_shadow[k] = cur;
      data_known[k] = known;
      if (write_tag) tag_shadow[k] = write_tag_value;
      writes++;
    end
    if (do_read && do_write && rset == wset) same_set++;
    #1;
    if (check_pending) begin
      for (int w = 0; w < WAYS; w++) begin
        if ((read_tag[w] & tag_known[w]) !== (exp_tag[w] & tag_known[w]))
          $fatal(1, "FAIL tag set=%0d way=%0d got=%h exp=%h", rset, w, read_tag[w], exp_tag[w]);
        if ((read_data[w] & data_mask[w]) !== (exp_data[w] & data_mask[w]))
          $fatal(1, "FAIL data set=%0d way=%0d got=%h exp=%h mask=%h n=%0d", rset, w, read_data[w], exp_data[w], data_mask[w], reads);
      end
    end
  endtask

  // a read in the cycle of a write to the same set must return the pre-write data, then the new data on the next read
  task automatic same_set_read_write_returns_old();
    for (int s = 0; s < SETS; s++) begin
      cycle(0, 1, 0, s);
      cycle(1, 1, s, s);
      cycle(1, 0, s, s);
    end
  endtask

  initial begin
    repeat (2) @(posedge clk);
    #1 rst = 0;
    same_set_read_write_returns_old();
    for (int n = 0; n < CYCLES; n++)
      cycle($urandom_range(3) != 0, $urandom_range(2) != 0, $urandom_range(SETS - 1),
            ($urandom_range(3) == 0) ? 0 : $urandom_range(SETS - 1));
    if (same_set < SETS) $fatal(1, "FAIL same-set read/write not exercised");
    $display("PASS reads=%0d writes=%0d", reads, writes);
    $finish;
  end
endmodule
`default_nettype wire
