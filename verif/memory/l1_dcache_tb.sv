`default_nettype none
// Replays +stimulus lines "op a b c d e f" (seven hex fields) against l1_dcache; a memory model answers its
// line requests.
//   0 load: id address size unsigned expected timed     timed: respond exactly HIT_STAGES cycles after acceptance
//   1 write: address data mask timed                    held until write_done_o; timed: done 2 cycles after present
//   2 clean    3 kill (a=1: keep issuing in the kill cycle)    4 barrier: wait until nothing is outstanding
//   5 expect request: kind (0 fill, 1 writeback) base way     6 fault: 0 next fill, 1 next writeback, 2 protocol
//     status, 3 wrong id, 4 uncached data (next response), 5 line data on the next writeback, 6 next fill faults
//     with line data    7 idle a cycles    8 continue in the next write_done_o cycle
//   9 expect fatal (last line); then present a clean and a load every cycle and require silence
//   a timing: latency (0: random 1..50) ready_delay (ff: random) no_gaps
//   b continue a cycles before (b=0) or after (b=1) the response of the current or next request
//   c present an unsolicited response this cycle, once nothing is outstanding at the memory
// Always checked: load data against the line and a byte shadow, writeback and fill data against the shadow, one
// outstanding transaction, requests never withdrawn, no duplicate valid tag, fatal only after an injected fault,
// a watchdog on the oldest access and a bound on every line's wait. +exact also checks each request and install
// way against the expect lines.
// Like the LSU, the bench presents no write or clean while cleaning and no load overlapping the held write, except
// right after op 8. +trace prints events.
module l1_dcache_tb;
  import memory_protocol_pkg::*;
  localparam int SETS = 16, MAX_LATENCY = 50, WATCHDOG = 4 * MAX_LATENCY + 64, QUIET = 300;
  localparam int CLEAN_WATCHDOG = WATCHDOG + 2 * SETS * (MAX_LATENCY + 8);

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1, kill = 0, load_valid = 0, load_unsigned = 0, write_valid = 0, clean = 0;
  logic request_ready = 0, response_valid = 0;
  logic [12:0] load_id = 0;
  logic [31:0] load_address = 0, write_address = 0, write_data = 0;
  logic [1:0] load_size = 0;
  logic [3:0] write_mask = 0;
  mem_response_t response = '0;
  wire load_ready, hit_valid, write_done, clean_done, busy, fatal, request_valid, response_ready;
  wire [12:0] hit_id;
  wire [31:0] hit_data;
  mem_request_t request;

  l1_dcache dut (
    .clk_i(clk), .rst_i(rst), .kill_i(kill), .load_valid_i(load_valid), .load_id_i(load_id),
    .load_address_i(load_address), .load_size_i(load_size), .load_unsigned_i(load_unsigned),
    .write_valid_i(write_valid), .write_address_i(write_address), .write_data_i(write_data),
    .write_mask_i(write_mask), .clean_i(clean), .mem_request_ready_i(request_ready),
    .mem_response_valid_i(response_valid), .mem_response_i(response), .load_ready_o(load_ready),
    .response_valid_o(hit_valid), .response_id_o(hit_id), .response_data_o(hit_data), .write_done_o(write_done),
    .clean_done_o(clean_done), .busy_o(busy), .fatal_o(fatal), .mem_request_valid_o(request_valid),
    .mem_request_o(request), .mem_response_ready_o(response_ready));

  // backing memory and the architectural shadow (updated at write_done_o); absent lines hold initial_line()
  logic [255:0] backing[int unsigned], shadow[int unsigned];

  function automatic logic [255:0] initial_line(int unsigned base);
    logic [255:0] line;
    for (int w = 0; w < 8; w++) line[32*w +: 32] = (base + 4 * w) * 32'h9e3779b1 ^ 32'h5bd1e995;
    return line;
  endfunction

  function automatic logic [255:0] backing_line(int unsigned base);
    return backing.exists(base) ? backing[base] : initial_line(base);
  endfunction

  function automatic logic [255:0] shadow_line(int unsigned base);
    return shadow.exists(base) ? shadow[base] : initial_line(base);
  endfunction

  function automatic logic [31:0] shadow_load(int unsigned address, logic [1:0] size, logic is_unsigned);
    logic [255:0] line = shadow_line(address & ~32'd31) >> (8 * (address & 31));
    case (size)
      2'd0: return {{24{!is_unsigned && line[7]}}, line[7:0]};
      2'd1: return {{16{!is_unsigned && line[15]}}, line[15:0]};
      default: return line[31:0];
    endcase
  endfunction

  function automatic bit overlaps_write(int unsigned address, logic [1:0] size);
    for (int b = 0; b < (1 << size); b++)
      if (((address + b) & ~32'd3) == (write_address & ~32'd3) && write_mask[(address + b) & 3]) return 1;
    return 0;
  endfunction

  // live accesses, oldest first, keyed by serial number; the watchdog times the oldest
  typedef struct {logic [31:0] expected, shadow; int accepted, key; bit timed;} load_t;
  load_t loads[int];
  int order[$];
  int serial = 0, front = -1, oldest_since = 0, load_key = -1, write_key = -1;

  function automatic void retire(int key);
    int found[$] = order.find_first_index(k) with (k == key);
    if (found.size() != 0) order.delete(found[0]);
  endfunction

  // stimulus
  string path, text;
  int fd, lines = 0, op, cycle = 0, gap = 0, idle_left = 0, sync_due = -1, quiet_left = -1;
  logic [31:0] a, b, c, d, e, f;
  bit have = 0, started = 0, eof = 0, exact, trace, sync_allow = 0;
  // the held write and cleaning
  bit write_held = 0, write_timed = 0, cleaning = 0;
  int write_presented = 0, clean_cycle = 0, line_since = 0;
  // memory: one transaction, its response valid from mem_due until the handshake
  bit mem_busy = 0, last_pending = 0, fault_sent = 0, fatal_traced = 0, reply_bad = 0;
  int mem_due = 0, fixed_latency = 0, ready_delay = -1, ready_count = 0, fault_kind = -1;
  bit no_gaps = 0;
  mem_response_t reply;
  mem_request_t last_request;
  // +exact expectations
  int expect_kind[$], expect_way[$], install_way = -1, install_set = -1;
  int unsigned expect_base[$];
  // counts reported on PASS
  int responses = 0, writes = 0, fills = 0, writebacks = 0, kills = 0, parks = 0, cleans = 0;
  // handshakes of the current cycle
  bit load_accept;
  logic [31:0] accept_shadow;

  // inputs for this cycle; lines that need no cycle are consumed until one does
  task automatic drive();
    {kill, clean, load_valid} = 0;
    write_valid = write_held;
    response_valid = mem_busy && cycle >= mem_due;
    response = response_valid ? reply : '0;
    request_ready = request_valid && !mem_busy
      && (ready_delay < 0 ? $urandom_range(3) != 0 : ready_count >= ready_delay);
    if (quiet_left >= 0) begin
      load_valid = 1;
      load_id = 13'h1fff;
      load_address = 0;
      load_size = 2;
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
        started = 0;
        gap = (op <= 1 && !no_gaps && $urandom_range(3) == 0) ? $urandom_range(1, 3) : 0;
      end
      case (op)
        0: begin
          if (gap > 0 || (write_held && overlaps_write(b, c[1:0]) && !(sync_allow && write_done))) break;
          if (!started) begin
            load_key = serial++;
            order.push_back(load_key);
            started = 1;
          end
          {load_valid, load_id, load_address, load_size, load_unsigned} = {1'b1, a[12:0], b, c[1:0], d[0]};
          break;
        end
        1: begin
          if (gap > 0 || write_held || cleaning) break;
          {write_valid, write_address, write_data, write_mask, write_timed} = {1'b1, a, b, c[3:0], d[0]};
          write_held = 1;
          write_presented = cycle;
          write_key = serial++;
          order.push_back(write_key);
          writes++;
          if (trace) $display("T %0d WPRES %h", cycle, a);
          have = 0;
        end
        2: begin
          if (write_held || cleaning) break;
          clean = 1;
          cleaning = 1;
          clean_cycle = cycle;
          cleans++;
          if (trace) $display("T %0d CLEAN", cycle);
          have = 0;
          break;
        end
        3: begin
          kill = 1;
          kills++;
          if (trace) $display("T %0d KILL", cycle);
          have = 0;
          if (a == 0) break;
        end
        4: begin
          if (loads.num() != 0 || write_held || cleaning || busy) break;
          if (exact && expect_kind.size() != 0)
            $fatal(1, "FAIL line %0d: %0d expected requests missing, first base %h", lines,
                   expect_kind.size(), expect_base[0]);
          have = 0;
        end
        5: begin
          expect_kind.push_back(a);
          expect_base.push_back(b);
          expect_way.push_back(c);
          have = 0;
        end
        6: begin
          fault_kind = a;
          have = 0;
        end
        7: begin
          if (!started) begin
            idle_left = a;
            started = 1;
          end
          if (idle_left > 0) break;
          have = 0;
        end
        8: begin
          if (!write_done) break;
          sync_allow = 1;
          have = 0;
        end
        9: begin
          if (!fatal) break;
          clean = 1;
          quiet_left = QUIET;
          have = 0;
          break;
        end
        'ha: begin
          fixed_latency = a;
          ready_delay = b == 'hff ? -1 : b;
          no_gaps = c[0];
          have = 0;
        end
        'hb: begin
          if (!started) begin
            sync_due = mem_busy ? mem_due : -1;
            started = 1;
          end
          if (sync_due < 0 || cycle < (b[0] ? sync_due + a : sync_due - a)) break;
          if (cycle > (b[0] ? sync_due + a : sync_due - a)) $fatal(1, "FAIL line %0d: sync point passed", lines);
          have = 0;
        end
        'hc: begin
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
    load_accept = load_valid && load_ready;
    accept_shadow = shadow_load(load_address, load_size, load_unsigned);
    if (quiet_left >= 0) begin
      if (!fatal || !busy || hit_valid || write_done || load_ready || request_valid || response_ready
          || dut.u_array.write_i || clean_done)
        $fatal(1, "FAIL cycle %0d: activity after fatal", cycle);
      return;
    end
    if (fatal && !fault_sent) $fatal(1, "FAIL cycle %0d: fatal without an injected fault", cycle);
    if (hit_valid) begin
      if (kill) $fatal(1, "FAIL cycle %0d: response in a kill cycle", cycle);
      if (!loads.exists(int'(hit_id))) $fatal(1, "FAIL cycle %0d: response for id %h not outstanding", cycle, hit_id);
      if (hit_data !== loads[int'(hit_id)].expected || hit_data !== loads[int'(hit_id)].shadow)
        $fatal(1, "FAIL cycle %0d: id %h data %h expected %h shadow %h", cycle, hit_id, hit_data,
               loads[int'(hit_id)].expected, loads[int'(hit_id)].shadow);
      if (loads[int'(hit_id)].timed && cycle - loads[int'(hit_id)].accepted != 1)
        $fatal(1, "FAIL cycle %0d: id %h hit latency %0d", cycle, hit_id, cycle - loads[int'(hit_id)].accepted);
    end
    if (write_done && !write_held) $fatal(1, "FAIL cycle %0d: write_done without a held write", cycle);
    if (write_done && write_timed && cycle - write_presented != 2)
      $fatal(1, "FAIL cycle %0d: write hit done after %0d cycles", cycle, cycle - write_presented);
    if (clean_done && !cleaning) $fatal(1, "FAIL cycle %0d: clean_done without a clean", cycle);
    if (load_accept && cleaning && cycle > clean_cycle && !clean_done)
      $fatal(1, "FAIL cycle %0d: load entered while cleaning", cycle);
    if (request_valid && mem_busy) $fatal(1, "FAIL cycle %0d: DC_ONE_OUTSTANDING", cycle);
    if (last_pending && (!request_valid || request !== last_request))
      $fatal(1, "FAIL cycle %0d: pending request withdrawn or changed", cycle);
    for (int s = 0; s < SETS; s++)
      if (dut.valid_q[s] == 2'b11 && dut.u_array.tag_q[s][0] == dut.u_array.tag_q[s][1])
        $fatal(1, "FAIL cycle %0d: DC_DUPLICATE_TAG set %0d", cycle, s);
    if (dut.u_array.write_i && dut.u_array.write_tag_i) begin
      if (trace) $display("T %0d INSTALL %0d %0d", cycle, dut.u_array.write_set_i, dut.u_array.write_way_i);
      if (exact && (int'(dut.u_array.write_set_i) != install_set || int'(dut.u_array.write_way_i) != install_way))
        $fatal(1, "FAIL cycle %0d: install set %0d way %0d expected %0d %0d", cycle, dut.u_array.write_set_i,
               dut.u_array.write_way_i, install_set, install_way);
    end
    if (dut.u_array.write_i && !dut.u_array.write_tag_i && trace)
      $display("T %0d LAND %0d %0d", cycle, dut.u_array.write_set_i, dut.u_array.write_way_i);
    parks += int'(dut.park);
    // accesses behind a clean wait for it; the clean watchdog covers that time
    if ((order.size() != 0 ? order[0] : -1) != front || cleaning) begin
      front = order.size() != 0 ? order[0] : -1;
      oldest_since = cycle;
    end
    if (order.size() != 0 && cycle - oldest_since > WATCHDOG)
      $fatal(1, "FAIL cycle %0d: watchdog, oldest access waiting since %0d", cycle, oldest_since);
    if (cleaning && cycle - clean_cycle > CLEAN_WATCHDOG) $fatal(1, "FAIL cycle %0d: clean watchdog", cycle);
    if (have && cycle - line_since > 2 * CLEAN_WATCHDOG) $fatal(1, "FAIL cycle %0d: line %0d stalled", cycle, lines);
  endtask

  task automatic accept_request();
    int unsigned base = request.address;
    mem_response_status_e status = MEM_STATUS_OK;
    if (request.uncached || base[4:0] != 0) $fatal(1, "FAIL cycle %0d: request %h not a line", cycle, base);
    if (trace) $display("T %0d REQ %0d %h", cycle, request.write, base);
    if (request.write) begin
      writebacks++;
      if (request.line_write_mask != '1) $fatal(1, "FAIL cycle %0d: partial writeback", cycle);
      if (request.line_write_data !== shadow_line(base))
        $fatal(1, "FAIL cycle %0d: writeback %h data %h shadow %h", cycle, base, request.line_write_data,
               shadow_line(base));
      backing[base] = request.line_write_data;
    end else begin
      fills++;
      if (backing_line(base) !== shadow_line(base)) $fatal(1, "FAIL cycle %0d: fill %h of a dirty line", cycle, base);
    end
    if (exact) begin
      if (expect_kind.size() == 0) $fatal(1, "FAIL cycle %0d: unexpected request %h", cycle, base);
      if (expect_kind[0] != int'(request.write) || expect_base[0] != base)
        $fatal(1, "FAIL cycle %0d: request %0d %h expected %0d %h", cycle, request.write, base, expect_kind[0],
               expect_base[0]);
      if (!request.write) {install_set, install_way} = {32'((base >> 5) % SETS), expect_way[0]};
      void'(expect_kind.pop_front());
      void'(expect_base.pop_front());
      void'(expect_way.pop_front());
    end
    reply_bad = fault_kind inside {3, 4} || (fault_kind == 5 && request.write) || (fault_kind == 6 && !request.write);
    if (fault_kind == 2) status = MEM_STATUS_PROTOCOL_ERROR;
    else if (fault_kind == int'(request.write) || (fault_kind == 6 && !request.write)) status = MEM_STATUS_ACCESS_FAULT;
    reply = '{transaction_id: request.transaction_id, status: status,
              line_read_data: (!request.write && status == MEM_STATUS_OK) ? backing_line(base) : '0,
              uncached_read_data: '0};
    case (reply_bad ? fault_kind : -1)
      3: reply.transaction_id = request.transaction_id + 1'b1;
      4: reply.uncached_read_data = 32'h1;
      5, 6: reply.line_read_data = initial_line(base);
      default: ;
    endcase
    if (status != MEM_STATUS_OK || reply_bad) fault_kind = -1;
    mem_busy = 1;
    mem_due = cycle + (fixed_latency != 0 ? fixed_latency : $urandom_range(1, MAX_LATENCY));
    if (have && op == 'hb && started && sync_due < 0) sync_due = mem_due;
  endtask

  task automatic pass();
    $display("PASS lines=%0d responses=%0d writes=%0d fills=%0d writebacks=%0d kills=%0d parks=%0d cleans=%0d",
             lines, responses, writes, fills, writebacks, kills, parks, cleans);
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
    if (hit_valid) begin
      retire(loads[int'(hit_id)].key);
      loads.delete(int'(hit_id));
      responses++;
      if (trace) $display("T %0d RSP %h %h", cycle, hit_id, hit_data);
    end
    if (kill) begin
      foreach (loads[id]) retire(loads[id].key);
      loads.delete();
    end
    if (load_accept) begin
      if (trace) $display("T %0d ACC %h", cycle, load_id);
      if (kill) retire(load_key);
      else begin
        if (loads.exists(int'(load_id))) $fatal(1, "FAIL line %0d: id %h reused while outstanding", lines, load_id);
        loads[int'(load_id)] = '{expected: e, shadow: accept_shadow, accepted: cycle, key: load_key, timed: f[0]};
      end
      have = 0;
      sync_allow = 0;
    end else if (load_valid && trace) $display("T %0d LWAIT %h", cycle, load_id);
    if (write_done) begin
      logic [255:0] line = shadow_line(write_address & ~32'd31);
      for (int k = 0; k < 4; k++)
        if (write_mask[k]) line[8 * ((write_address & 28) + k) +: 8] = write_data[8*k +: 8];
      shadow[write_address & ~32'd31] = line;
      write_held = 0;
      retire(write_key);
      if (trace) $display("T %0d WDONE %h", cycle, write_address);
    end
    if (clean_done) begin
      cleaning = 0;
      if (trace) $display("T %0d CDONE", cycle);
    end
    if (response_valid && response_ready) begin
      mem_busy = 0;
      if (reply.status != MEM_STATUS_OK || reply_bad) fault_sent = 1;
      if (trace) $display("T %0d MRSP %0d %0d", cycle, last_request.write, reply.status);
    end
    if (request_valid && request_ready) accept_request();
    ready_count = request_valid && !request_ready ? ready_count + 1 : 0;
    last_pending = request_valid && !request_ready;
    if (request_valid) last_request = request;
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
      if (eof && loads.num() == 0 && !write_held && !cleaning && !busy && !mem_busy) begin
        if (lines == 0) $fatal(1, "FAIL empty stimulus");
        if (expect_kind.size() != 0) $fatal(1, "FAIL %0d expected requests missing", expect_kind.size());
        pass();
      end
    end
  end
endmodule
`default_nettype wire
