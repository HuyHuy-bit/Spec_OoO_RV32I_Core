`default_nettype none
// Replays +stimulus lines "op a b c d e f" (seven hex fields) against l1_icache, acting as fetch; a memory model
// answers its line requests. Lines are numbered by address[31:5].
//   0 lookup: line wait expect     wait: look up again after a retry, then wait for the miss's fill or fault
//                                  expect, checked on the first answer: 0 any, 1 hit, 2 miss
//   1 prefetch: line wait          offered until accepted; wait 1: then until the cache is idle; 2: one cycle only
//   2 invalidate: modify line next modify: the line's memory changes at this edge; next: the next line issues too
//   3 barrier: wait until nothing is outstanding
//   4 expect request: line way fault (+exact)   5 fault line: line arm (requests for it get an access fault)
//   6 malformed next response: 2 protocol status, 3 wrong id, 4 uncached data, 6 an access fault with line data
//   7 idle a cycles    8 expect fatal (last line): then look up the demand line and offer a prefetch every cycle,
//     and require silence
//   9 timing: latency (0: random 1..50) ready_delay (ff: random) no_gaps
//   a continue a cycles before (b=0) or after (b=1) the response of the current or next request
//   b present an unsolicited response this cycle, once nothing is outstanding at the memory
// Always checked: hit and fill data against memory as of the answer cycle, only the demand (the latest miss) is
// delivered or faulted, one outstanding transaction, requests never withdrawn and never for a resident line,
// prefetches accepted only with nothing in flight, retries only around an install cycle into the set, no duplicate
// valid tag, fatal only after an injected fault, and watchdogs on the demand and on every line. +exact also checks
// each request and install way against the expect lines. +trace prints events.
module l1_icache_tb;
  import memory_protocol_pkg::*;
  localparam int SETS = 16, MAX_LATENCY = 50, WATCHDOG = 4 * MAX_LATENCY + 64, QUIET = 300;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1, invalidate = 0, lookup_valid = 0, prefetch_valid = 0, request_ready = 0, response_valid = 0;
  logic [26:0] lookup_line = 0, prefetch_line = 0;
  mem_response_t response = '0;
  wire hit_valid, miss, fill_valid, fill_fault, prefetch_ready, prefetch_hit, busy, fatal, request_valid, response_ready;
  wire [255:0] hit_data, fill_data;
  wire [26:0] fill_line;
  mem_request_t request;

  l1_icache dut (
    .clk_i(clk), .rst_i(rst), .invalidate_i(invalidate), .lookup_valid_i(lookup_valid), .lookup_line_i(lookup_line),
    .prefetch_valid_i(prefetch_valid), .prefetch_line_i(prefetch_line), .prefetch_cancel_i(1'b0), .mem_request_ready_i(request_ready),
    .mem_response_valid_i(response_valid), .mem_response_i(response), .hit_valid_o(hit_valid),
    .hit_data_o(hit_data), .miss_o(miss), .fill_valid_o(fill_valid), .fill_data_o(fill_data),
    .fill_fault_o(fill_fault), .fill_line_o(fill_line), .prefetch_ready_o(prefetch_ready), .prefetch_hit_o(prefetch_hit), .busy_o(busy),
    .fatal_o(fatal), .mem_request_valid_o(request_valid), .mem_request_o(request),
    .mem_response_ready_o(response_ready));

  // memory: absent lines hold initial_line(); faulting lines answer every request with an access fault
  logic [255:0] backing[int unsigned];
  bit faulty[int unsigned];

  function automatic logic [255:0] initial_line(int unsigned line);
    logic [255:0] data;
    for (int w = 0; w < 8; w++) data[32*w +: 32] = (line * 32 + 4 * w) * 32'h9e3779b1 ^ 32'h5bd1e995;
    return data;
  endfunction

  function automatic logic [255:0] backing_line(int unsigned line);
    return backing.exists(line) ? backing[line] : initial_line(line);
  endfunction

  function automatic bit resident(int unsigned line);
    for (int w = 0; w < 2; w++)
      if (dut.valid_q[line % SETS][w] && dut.u_array.tag_q[line % SETS][w] == line / SETS) return 1;
    return 0;
  endfunction

  // stimulus
  string path, text;
  int fd, lines = 0, op, cycle = 0, gap = 0, idle_left = 0, sync_due = -1, quiet_left = -1, phase = 0;
  logic [31:0] a, b, c, d, e, f;
  bit have = 0, eof = 0, exact, trace, no_gaps = 0;
  int line_since = 0;
  // the lookup presented last cycle, answered this cycle
  bit last_lookup = 0;
  int unsigned last_line = 0;
  int last_expect = 0, lookup_expect = 0;
  // the demand: the line of the latest miss, until its fill or fault
  bit want_valid = 0;
  int unsigned want_line = 0;
  int want_since = 0;
  // memory: one transaction, its response valid from mem_due until the handshake
  bit mem_busy = 0, last_pending = 0, fault_sent = 0, fatal_traced = 0, reply_bad = 0, modify_now = 0;
  int mem_due = 0, fixed_latency = 0, ready_delay = -1, ready_count = 0, fault_kind = -1, response_cycle = -10;
  int unsigned response_line = 0, modify_line = 0, mem_line = 0;
  mem_response_t reply;
  mem_request_t last_request;
  // +exact expectations
  int expect_way[$], install_way = -1;
  int unsigned expect_line[$];
  bit expect_fault[$];
  // counts reported on PASS
  int lookups = 0, hits = 0, misses = 0, retries = 0, fills = 0, faults = 0, prefetches = 0, requests = 0;
  int installs = 0, invalidates = 0, dropped = 0, prefetch_hits = 0;

  // inputs for this cycle; lines that need no cycle are consumed until one does. Every answer output comes from
  // registers, so this cycle's answers to last cycle's lookup are already settled here.
  task automatic drive();
    {invalidate, lookup_valid, prefetch_valid} = 0;
    {modify_now, lookup_expect} = 0;
    response_valid = mem_busy && cycle >= mem_due;
    response = response_valid ? reply : '0;
    request_ready = request_valid && !mem_busy
      && (ready_delay < 0 ? $urandom_range(3) != 0 : ready_count >= ready_delay);
    if (quiet_left >= 0) begin
      // the demand line, so the lookups keep the demand a late fill would answer
      {lookup_valid, lookup_line, prefetch_valid, prefetch_line} = {1'b1, want_line[26:0], 1'b1, 27'd1};
      return;
    end
    while (!eof) begin
      if (!have) begin
        if ($fgets(text, fd) == 0) begin
          eof = 1;
          break;
        end
        {a, b, c, d, e, f} = '0;
        if ($sscanf(text, "%h %h %h %h %h %h %h", op, a, b, c, d, e, f) != 7)
          $fatal(1, "FAIL malformed line %0d: %s", lines, text);
        lines++;
        line_since = cycle;
        have = 1;
        phase = 0;
        gap = (op <= 1 && !no_gaps && $urandom_range(3) == 0) ? $urandom_range(1, 3) : 0;
      end
      case (op)
        0: begin
          if (gap > 0) break;
          if (phase == 1) begin
            if (hit_valid) begin
              have = 0;
              continue;
            end
            if (miss) begin
              phase = 2;
              break;
            end
          end
          if (phase == 2) begin
            if (want_valid && want_line == a) break;
            have = 0;
            continue;
          end
          {lookup_valid, lookup_line} = {1'b1, a[26:0]};
          lookup_expect = phase == 0 ? int'(c) : 0;
          if (b[0]) phase = 1;
          else have = 0;
          break;
        end
        1: begin
          if (gap > 0) break;
          if (phase == 1) begin
            if (busy || mem_busy) break;
            have = 0;
            continue;
          end
          {prefetch_valid, prefetch_line} = {1'b1, a[26:0]};
          if (prefetch_ready && b == 1) phase = 1;
          else if (prefetch_ready || b == 2) have = 0;
          break;
        end
        2: begin
          invalidate = 1;
          {modify_now, modify_line} = {a[0], b};
          have = 0;
          if (c == 0) break;
        end
        3: begin
          if (busy || mem_busy || want_valid || request_valid) break;
          if (exact && expect_line.size() != 0)
            $fatal(1, "FAIL line %0d: %0d expected requests missing, first %h", lines, expect_line.size(),
                   expect_line[0]);
          have = 0;
        end
        4: begin
          expect_line.push_back(a);
          expect_way.push_back(b);
          expect_fault.push_back(c[0]);
          have = 0;
        end
        5: begin
          if (b[0]) faulty[a] = 1;
          else faulty.delete(a);
          have = 0;
        end
        6: begin
          fault_kind = a;
          have = 0;
        end
        7: begin
          if (phase == 0) begin
            idle_left = a;
            phase = 1;
          end
          if (idle_left > 0) break;
          have = 0;
        end
        8: begin
          if (!fatal) break;
          quiet_left = QUIET;
          have = 0;
          break;
        end
        9: begin
          fixed_latency = a;
          ready_delay = b == 'hff ? -1 : b;
          no_gaps = c[0];
          have = 0;
        end
        'ha: begin
          if (phase == 0) begin
            sync_due = mem_busy ? mem_due : -1;
            phase = 1;
          end
          if (sync_due < 0 || cycle < (b[0] ? sync_due + a : sync_due - a)) break;
          if (cycle > (b[0] ? sync_due + a : sync_due - a)) $fatal(1, "FAIL line %0d: sync point passed", lines);
          have = 0;
        end
        'hb: begin
          if (mem_busy) break;
          response_valid = 1;
          response = '{transaction_id: 4'd0, status: MEM_STATUS_OK, line_read_data: '0, uncached_read_data: '0};
          fault_sent = 1;
          if (trace) $display("T %0d UNSOL", cycle);
          have = 0;
          break;
        end
        default: $fatal(1, "FAIL line %0d: unknown op %0d", lines, op);
      endcase
    end
  endtask

  // settled outputs of this cycle
  task automatic check();
    if (quiet_left >= 0) begin
      if (!fatal || !busy || hit_valid || miss || fill_valid || fill_fault || prefetch_ready || request_valid
          || response_ready || dut.u_array.write_i)
        $fatal(1, "FAIL cycle %0d: activity after fatal", cycle);
      return;
    end
    if (fatal && !fault_sent) $fatal(1, "FAIL cycle %0d: fatal without an injected fault", cycle);
    if (fatal) return;  // the quiet window checks the gated outputs
    if (hit_valid && miss) $fatal(1, "FAIL cycle %0d: hit and miss", cycle);
    if ((hit_valid || miss) && !last_lookup) $fatal(1, "FAIL cycle %0d: answer without a lookup", cycle);
    if (last_lookup) begin
      if (hit_valid && (faulty.exists(last_line) || hit_data !== backing_line(last_line)))
        $fatal(1, "FAIL cycle %0d: hit %h data %h memory %h", cycle, last_line, hit_data, backing_line(last_line));
      // a retry is a miss decided in an install cycle, or read at one, of the same set
      if (!hit_valid && !miss && !(cycle - response_cycle inside {1, 2} && response_line % SETS == last_line % SETS))
        $fatal(1, "FAIL cycle %0d: retry of %h outside an install window", cycle, last_line);
      if ((last_expect == 1 && !hit_valid) || (last_expect == 2 && !miss))
        $fatal(1, "FAIL cycle %0d: lookup %h answered hit=%0d miss=%0d, expected %0d", cycle, last_line, hit_valid,
               miss, last_expect);
    end
    // a prefetch check that hits shows its line, and only a prefetch check does
    if (prefetch_hit && (last_lookup || !dut.stage_prefetch_q || faulty.exists(dut.stage_line_q)
                         || hit_data !== backing_line(dut.stage_line_q)))
      $fatal(1, "FAIL cycle %0d: prefetch hit %h data %h memory %h", cycle, dut.stage_line_q, hit_data,
             backing_line(dut.stage_line_q));
    if (fill_valid && fill_fault) $fatal(1, "FAIL cycle %0d: fill and fault", cycle);
    if (fill_valid || fill_fault) begin
      if (!want_valid || fill_line != want_line)
        $fatal(1, "FAIL cycle %0d: delivery of %h, demand %0d %h", cycle, fill_line, want_valid, want_line);
      if (fill_valid && (faulty.exists(fill_line) || fill_data !== backing_line(fill_line)))
        $fatal(1, "FAIL cycle %0d: fill %h data %h memory %h", cycle, fill_line, fill_data, backing_line(fill_line));
      if (fill_fault && !faulty.exists(fill_line)) $fatal(1, "FAIL cycle %0d: fault on %h", cycle, fill_line);
    end
    if (prefetch_valid && prefetch_ready && (mem_busy || request_valid))
      $fatal(1, "FAIL cycle %0d: prefetch accepted with a request in flight", cycle);
    if (request_valid && mem_busy) $fatal(1, "FAIL cycle %0d: IC_ONE_OUTSTANDING", cycle);
    if (last_pending && (!request_valid || request !== last_request))
      $fatal(1, "FAIL cycle %0d: pending request withdrawn or changed", cycle);
    if (request_valid && !last_pending && resident(request.address >> 5))
      $fatal(1, "FAIL cycle %0d: IC_REQUEST_RESIDENT %h", cycle, request.address >> 5);
    for (int s = 0; s < SETS; s++)
      if (dut.valid_q[s] == 2'b11 && dut.u_array.tag_q[s][0] == dut.u_array.tag_q[s][1])
        $fatal(1, "FAIL cycle %0d: IC_DUPLICATE_TAG set %0d", cycle, s);
    if (dut.u_array.write_i) begin
      if (!dut.u_array.write_tag_i || dut.u_array.write_byte_mask_i != '1)
        $fatal(1, "FAIL cycle %0d: partial install", cycle);
      if (cycle != response_cycle + 1 || dut.u_array.write_set_i != response_line % SETS
          || dut.u_array.write_tag_value_i != response_line / SETS || dut.u_array.write_data_i !== reply.line_read_data
          || reply.status != MEM_STATUS_OK)
        $fatal(1, "FAIL cycle %0d: install is not the last response's line", cycle);
      if (exact && int'(dut.u_array.write_way_i) != install_way)
        $fatal(1, "FAIL cycle %0d: install way %0d expected %0d", cycle, dut.u_array.write_way_i, install_way);
    end
    if (want_valid && cycle - want_since > WATCHDOG)
      $fatal(1, "FAIL cycle %0d: watchdog, demand %h waiting since %0d", cycle, want_line, want_since);
    if (have && cycle - line_since > 4 * WATCHDOG) $fatal(1, "FAIL cycle %0d: line %0d stalled", cycle, lines);
  endtask

  task automatic accept_request();
    int unsigned line = request.address >> 5;
    mem_response_status_e status = faulty.exists(line) ? MEM_STATUS_ACCESS_FAULT : MEM_STATUS_OK;
    if (request.uncached || request.write || request.address[4:0] != 0 || request.line_write_mask != 0
        || request.line_write_data != 0 || request.uncached_write_strobe != 0)
      $fatal(1, "FAIL cycle %0d: request %h not a line read", cycle, request.address);
    requests++;
    if (trace) $display("T %0d REQ %h", cycle, line);
    if (exact) begin
      if (expect_line.size() == 0) $fatal(1, "FAIL cycle %0d: unexpected request %h", cycle, line);
      if (expect_line[0] != line || expect_fault[0] != (status != MEM_STATUS_OK))
        $fatal(1, "FAIL cycle %0d: request %h expected %h fault %0d", cycle, line, expect_line[0], expect_fault[0]);
      install_way = expect_way[0];
      void'(expect_line.pop_front());
      void'(expect_way.pop_front());
      void'(expect_fault.pop_front());
    end
    reply_bad = fault_kind inside {2, 3, 4, 6};
    if (fault_kind == 2) status = MEM_STATUS_PROTOCOL_ERROR;
    if (fault_kind == 6) status = MEM_STATUS_ACCESS_FAULT;
    reply = '{transaction_id: request.transaction_id, status: status,
              line_read_data: status == MEM_STATUS_OK ? backing_line(line) : '0, uncached_read_data: '0};
    case (fault_kind)
      3: reply.transaction_id = request.transaction_id + 1'b1;
      4: reply.uncached_read_data = 32'h1;
      6: reply.line_read_data = initial_line(line);
      default: ;
    endcase
    fault_kind = -1;
    mem_busy = 1;
    mem_line = line;
    mem_due = cycle + (fixed_latency != 0 ? fixed_latency : $urandom_range(1, MAX_LATENCY));
    if (have && op == 'ha && phase == 1 && sync_due < 0) sync_due = mem_due;
  endtask

  task automatic pass();
    $display("PASS lines=%0d lookups=%0d hits=%0d misses=%0d retries=%0d fills=%0d faults=%0d prefetches=%0d requests=%0d installs=%0d invalidates=%0d dropped=%0d prefetch_hits=%0d",
             lines, lookups, hits, misses, retries, fills, faults, prefetches, requests, installs, invalidates, dropped,
             prefetch_hits);
    $finish;
  endtask

  // effects of this cycle's handshakes, applied at its closing edge
  task automatic update();
    if (fatal && !fatal_traced) begin
      fatal_traced = 1;
      if (trace) $display("T %0d FATAL", cycle);
    end
    if (quiet_left >= 0) begin
      if (quiet_left-- == 0) pass();
      return;
    end
    if (fill_valid || fill_fault) begin
      want_valid = 0;
      fills += int'(fill_valid);
      faults += int'(fill_fault);
      if (trace) $display("T %0d %s %h", cycle, fill_valid ? "FILL" : "FAULT", fill_line);
    end
    if (last_lookup) begin
      if (hit_valid) hits++;
      else if (miss) begin
        misses++;
        {want_valid, want_line, want_since} = {1'b1, last_line, cycle};
      end else retries++;
      if (trace) $display("T %0d %s %h", cycle, hit_valid ? "HIT" : miss ? "MISS" : "RETRY", last_line);
    end
    if (cycle == response_cycle + 1 && reply.status == MEM_STATUS_OK && !dut.u_array.write_i) dropped++;
    prefetch_hits += int'(prefetch_hit);
    if (dut.u_array.write_i) begin
      installs++;
      if (trace) $display("T %0d INSTALL %h %h", cycle, dut.u_array.write_set_i, dut.u_array.write_way_i);
    end
    if (lookup_valid) begin
      lookups++;
      if (trace) $display("T %0d LOOK %h", cycle, lookup_line);
    end
    if (prefetch_valid && prefetch_ready) begin
      prefetches++;
      if (trace) $display("T %0d PFACC %h", cycle, prefetch_line);
    end
    if (invalidate) begin
      invalidates++;
      want_since = cycle;  // an invalidate may drop the demand's transaction and restart it
      if (trace) $display("T %0d INV", cycle);
    end
    if (response_valid && response_ready) begin
      mem_busy = 0;
      {response_cycle, response_line} = {cycle, mem_line};
      if (reply_bad) fault_sent = 1;
      if (trace) $display("T %0d MRSP %0d", cycle, reply.status);
    end
    if (request_valid && request_ready) accept_request();
    // after the request handshake: a request taken in the invalidate cycle reads the old line
    if (modify_now) backing[modify_line] = backing_line(modify_line) ^ {8{$urandom | 32'h1}};
    ready_count = request_valid && !request_ready ? ready_count + 1 : 0;
    last_pending = request_valid && !request_ready;
    if (request_valid) last_request = request;
    last_lookup = lookup_valid;
    last_line = lookup_line;
    last_expect = lookup_valid ? lookup_expect : 0;
    if (gap > 0) gap--;
    if (idle_left > 0) idle_left--;
  endtask

  initial begin
    if (!$value$plusargs("stimulus=%s", path)) $fatal(1, "NO_STIMULUS");
    exact = $test$plusargs("exact");
    trace = $test$plusargs("trace");
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "NO_FILE %s", path);
    repeat (2) @(posedge clk);
    #1 rst = 0;
    forever begin
      drive();
      #1;
      check();
      @(posedge clk);
      update();
      cycle++;
      #1;
      if (eof && !want_valid && !busy && !mem_busy && !request_valid) begin
        if (lines == 0) $fatal(1, "FAIL empty stimulus");
        if (expect_line.size() != 0) $fatal(1, "FAIL %0d expected requests missing", expect_line.size());
        pass();
      end
    end
  end
endmodule
`default_nettype wire
