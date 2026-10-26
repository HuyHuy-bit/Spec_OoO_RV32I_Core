`default_nettype none
// replays +stimulus lines "lookup_valid lookup_pc update_valid update_pc taken expected region" (hex);
// expected is the lookup from the state before that line's update, and is checked on every line.
// random idle cycles with junk inputs check that invalid ports neither predict nor train.
module tage_predictor_tb #(parameter int AGE_BITS = 18);
  logic clk;
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end
  logic rst = 1, lookup_valid = 0, update_valid = 0, taken = 0;
  logic [31:0] lookup_pc = 0, update_pc = 0;
  wire prediction;
  tage_predictor #(.AGE_BITS(AGE_BITS)) dut (
    .clk_i(clk), .rst_i(rst), .lookup_valid_i(lookup_valid), .lookup_pc_i(lookup_pc),
    .update_valid_i(update_valid), .update_taken_i(taken), .update_pc_i(update_pc),
    .lookup_history_i(32'd0), .lookup_branch_i(1'b0), .lookup_path_i(1'b0),
    .lookup_taken_o(prediction)
  );

  initial begin
    automatic string path, line;
    automatic int fd, fields, count = 0, region_misses = 0;
    automatic logic lv, uv, t, expected, region;
    automatic logic [31:0] lpc, upc;
    if (!$value$plusargs("stimulus=%s", path)) $fatal(1, "NO_STIMULUS");
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "NO_FILE %s", path);
    repeat (2) @(posedge clk);
    #1 rst = 0;
    // whole lines, so a short or garbled line cannot be read as end of file
    while ($fgets(line, fd) != 0) begin
      fields = $sscanf(line, "%h %h %h %h %h %h %h", lv, lpc, uv, upc, t, expected, region);
      if (fields != 7) $fatal(1, "FAIL malformed line %0d: %s", count, line);
      if ($urandom_range(7) == 0) begin
        {lookup_valid, update_valid} = 0;
        {lookup_pc, update_pc} = {$urandom, $urandom};
        taken = 1'($urandom);
        #1 if (prediction !== 1'b0) $fatal(1, "FAIL idle prediction");
        @(posedge clk); #1;
      end
      {lookup_valid, lookup_pc, update_valid, update_pc, taken} = {lv, lpc, uv, upc, t};
      #1 if (prediction !== (lv && expected))
        $fatal(1, "FAIL index=%0d lookup=%b/%h update=%b/%h taken=%0d expected=%0d got=%b",
               count, lv, lpc, uv, upc, t, lv && expected, prediction);
      region_misses += int'(region && prediction != t);
      @(posedge clk); #1;
      count++;
    end
    if (count == 0) $fatal(1, "FAIL empty stimulus");
    $display("PASS lines=%0d region_misses=%0d", count, region_misses);
    $finish;
  end
endmodule
`default_nettype wire
