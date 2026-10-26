`default_nettype none
// L1 data cache: 2 ways of 32-byte lines over l1_cache_array, write-back and write-allocate.
// An access (a load, or the store buffer's held write) reads its set when it enters and decides HIT_STAGES = 1
// cycle later from the registered read. One miss is outstanding: dirty victim writeback, refill into line_q,
// install from line_q. An access that cannot finish parks in one replay slot and reads again once the miss
// handler is free; after an install the miss target reads again first, then the slot.
// Every ready, memory request and array write comes from registers; only the load hit response is combinational.
module l1_dcache #(parameter int HIT_STAGES = 1, SETS = 16) (
  // inputs
  input  wire clk_i, rst_i,
  input  wire kill_i,                      // drops the loads in the stage, the slot and the miss target, and a load
                                           // accepted in this cycle; never a write, writeback or refill
  input  wire load_valid_i,
  input  wire [12:0] load_id_i,
  input  wire [31:0] load_address_i,
  input  wire [1:0] load_size_i,
  input  wire load_unsigned_i,
  input  wire write_valid_i,               // store-buffer head, held with its fields until write_done_o
  input  wire [31:0] write_address_i,
  input  wire [31:0] write_data_i,         // byte lanes of the addressed word
  input  wire [3:0] write_mask_i,
  input  wire clean_i,                     // only with no write held or in flight, and not while cleaning
  input  wire mem_request_ready_i,
  input  wire mem_response_valid_i,
  input  memory_protocol_pkg::mem_response_t mem_response_i,
  // outputs
  output wire load_ready_o,
  output wire response_valid_o,
  output wire [12:0] response_id_o,
  output logic [31:0] response_data_o,
  output wire write_done_o,                // the held write lands at this edge; the store buffer pops it
  output wire clean_done_o,
  output wire busy_o,
  output wire fatal_o,                     // refill or writeback access fault, or protocol error; sticky. Then
                                           // every handshake output stays low and busy_o high
  output wire mem_request_valid_o,
  output memory_protocol_pkg::mem_request_t mem_request_o,
  output wire mem_response_ready_o
);
  import memory_protocol_pkg::*;
  localparam int WAYS = 2, INDEX_BITS = $clog2(SETS), TAG_BITS = 27 - INDEX_BITS;

  // shortcut: compare and select are built for HIT_STAGES = 1; a second stage would need its own race guards
  if (HIT_STAGES != 1) begin : g_hit_stages
    $error("l1_dcache implements HIT_STAGES = 1 only");
  end

  typedef struct packed {
    logic write;
    logic [12:0] id;
    logic [31:0] address;
    logic [1:0] size;
    logic unsigned_load;
  } access_t;
  typedef enum logic [2:0] {IDLE, CLEAN_SCAN, CLEAN_READ, WB_REQUEST, WB_RESPONSE, FILL_REQUEST, FILL_RESPONSE,
                            INSTALL} state_e;

  state_e state_q;
  logic [SETS-1:0][WAYS-1:0] valid_q, dirty_q;
  logic [SETS-1:0] lru_q;                          // the least recently used way of each set
  access_t stage_q, slot_q, target_q;
  logic stage_valid_q, slot_full_q, target_live_q, replay_pending_q, install_last_q, miss_way_q;
  logic write_busy_q, land_valid_q, land_way_q, write_last_q, write_last_way_q;
  logic [INDEX_BITS-1:0] write_last_set_q;
  logic [26:0] writeback_line_q;                   // {tag, set}
  logic [255:0] line_q;                            // victim data, then refill data
  logic cleaning_q, walk_q, clean_done_q, fatal_q;
  logic [INDEX_BITS:0] clean_index_q;              // {set, way}
  logic [3:0] transaction_q;
  wire [WAYS-1:0][TAG_BITS-1:0] read_tag;
  wire [WAYS-1:0][255:0] read_data;

  // entry: at most one access per cycle, the held write ahead of a load (it is older), all from registers
  wire miss_busy = state_q != IDLE;
  wire base = !slot_full_q && !(miss_busy && stage_valid_q) && !replay_pending_q && !cleaning_q && !fatal_q;
  wire write_enter = write_valid_i && !write_busy_q && base;
  wire slot_go = slot_full_q && !replay_pending_q && !miss_busy;
  assign load_ready_o = base && !write_enter;
  access_t next_access;
  always_comb begin
    if (replay_pending_q) next_access = target_q;
    else if (slot_full_q) next_access = slot_q;
    else if (write_valid_i && !write_busy_q)
      next_access = '{write: 1'b1, id: 13'd0, address: write_address_i, size: 2'd2, unsigned_load: 1'b0};
    else next_access = '{write: 1'b0, id: load_id_i, address: load_address_i, size: load_size_i,
                         unsigned_load: load_unsigned_i};
  end
  wire enter = !(kill_i && !next_access.write)
    && (replay_pending_q || slot_go || write_enter || (load_valid_i && load_ready_o));
  wire [INDEX_BITS-1:0] clean_set = clean_index_q[INDEX_BITS:1];
  wire clean_way = clean_index_q[0];
  wire [INDEX_BITS-1:0] read_set = walk_q ? clean_set : next_access.address[5 +: INDEX_BITS];

  // decision, one cycle after entry, from the registered read and the current valid bits
  wire [INDEX_BITS-1:0] stage_set = stage_q.address[5 +: INDEX_BITS];
  wire [INDEX_BITS-1:0] target_set = target_q.address[5 +: INDEX_BITS];
  wire [INDEX_BITS-1:0] write_set = write_address_i[5 +: INDEX_BITS];
  wire [WAYS-1:0] way_valid = valid_q[stage_set];
  wire [WAYS-1:0] hit_way;
  for (genvar w = 0; w < WAYS; w++) begin : g_hit
    assign hit_way[w] = way_valid[w] && read_tag[w] == stage_q.address[31 -: TAG_BITS];
  end
  wire hit = |hit_way;
  wire victim_way = !way_valid[0] ? 1'b0 : !way_valid[1] ? 1'b1 : lru_q[stage_set];
  wire stage_live = stage_valid_q && !(kill_i && !stage_q.write);
  // read at an install edge into this set: the tags predate the install (T4-A2)
  wire install_race = install_last_q && target_set == stage_set;
  // the victim's read lacks a write landing now or at its read edge (T4-A1)
  wire landing_race = (land_valid_q && write_set == stage_set && land_way_q == victim_way)
    || (write_last_q && write_last_set_q == stage_set && write_last_way_q == victim_way);
  wire decide_hit = stage_live && hit && !install_race;
  wire park = stage_live && (install_race || (!hit && (miss_busy || landing_race)));
  wire start_miss = stage_live && !hit && !install_race && !miss_busy && !landing_race;

  // load response
  wire [31:0] hit_word = ({32{hit_way[0]}} & read_data[0][32*stage_q.address[4:2] +: 32])
    | ({32{hit_way[1]}} & read_data[1][32*stage_q.address[4:2] +: 32]);
  wire [31:0] shifted = hit_word >> {stage_q.address[1:0], 3'b000};
  assign response_valid_o = decide_hit && !stage_q.write && !fatal_q;
  assign response_id_o = stage_q.id;
  always_comb
    case (stage_q.size)
      2'd0: response_data_o = {{24{!stage_q.unsigned_load && shifted[7]}}, shifted[7:0]};
      2'd1: response_data_o = {{16{!stage_q.unsigned_load && shifted[15]}}, shifted[15:0]};
      default: response_data_o = shifted;
    endcase

  // array write port: the landing write always lands; an install waits behind it, at most one cycle
  wire land_go = land_valid_q && !fatal_q;
  wire install_go = state_q == INSTALL && !land_valid_q && !fatal_q;
  assign write_done_o = land_go;
  l1_cache_array #(.SETS(SETS), .WAYS(WAYS), .TAG_BITS(TAG_BITS)) u_array (
    .clk_i, .rst_i, .read_set_i(read_set), .write_i(land_go || install_go), .write_tag_i(install_go),
    .write_set_i(land_valid_q ? write_set : target_set), .write_way_i(land_valid_q ? land_way_q : miss_way_q),
    .write_tag_value_i(target_q.address[31 -: TAG_BITS]),
    .write_byte_mask_i(land_valid_q ? 32'(write_mask_i) << {write_address_i[4:2], 2'b00} : '1),
    .write_data_i(land_valid_q ? {8{write_data_i}} : line_q),
    .read_tag_o(read_tag), .read_data_o(read_data));

  // memory port: one transaction at a time, requested from state and never withdrawn
  wire waiting = state_q == WB_RESPONSE || state_q == FILL_RESPONSE;
  assign mem_request_valid_o = (state_q == WB_REQUEST || state_q == FILL_REQUEST) && !fatal_q;
  assign mem_response_ready_o = waiting && !fatal_q;
  wire malformed = mem_response_valid_i && (!waiting || mem_response_i.transaction_id != transaction_q
    || !(mem_response_i.status inside {MEM_STATUS_OK, MEM_STATUS_ACCESS_FAULT})
    || mem_response_i.uncached_read_data != 0
    || ((state_q == WB_RESPONSE || mem_response_i.status != MEM_STATUS_OK) && mem_response_i.line_read_data != 0));
  wire responded = mem_response_valid_i && waiting && !malformed;
  wire access_fault = responded && mem_response_i.status == MEM_STATUS_ACCESS_FAULT;
  wire response_ok = responded && !access_fault;
  always_comb begin
    mem_request_o = '0;
    if (mem_request_valid_o) begin
      mem_request_o.transaction_id = transaction_q;
      mem_request_o.write = state_q == WB_REQUEST;
      mem_request_o.address = {state_q == WB_REQUEST ? writeback_line_q : target_q.address[31:5], 5'd0};
      if (state_q == WB_REQUEST) begin
        mem_request_o.line_write_data = line_q;
        mem_request_o.line_write_mask = '1;
      end
    end
  end

  // clean: once nothing is in flight, walk every (set, way) and write back the dirty lines
  wire clean_start = cleaning_q && !walk_q && !stage_valid_q && !slot_full_q && !replay_pending_q && !write_busy_q;
  wire walk_step = (state_q == CLEAN_SCAN && !dirty_q[clean_set][clean_way])
    || (state_q == WB_RESPONSE && walk_q && response_ok);
  assign clean_done_o = clean_done_q && !fatal_q;
  assign busy_o = fatal_q || stage_valid_q || slot_full_q || miss_busy || replay_pending_q || write_busy_q
    || cleaning_q;
  assign fatal_o = fatal_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= IDLE;
      {valid_q, dirty_q, lru_q} <= '0;
      {stage_valid_q, slot_full_q, target_live_q, replay_pending_q, install_last_q} <= '0;
      {write_busy_q, land_valid_q, write_last_q, cleaning_q, walk_q, clean_done_q, fatal_q} <= '0;
      transaction_q <= '0;
    end else begin
      // stage, replay slot and miss target
      stage_valid_q <= enter;
      stage_q <= next_access;
      if (!slot_full_q || slot_go) slot_q <= stage_q;
      slot_full_q <= park || (slot_full_q && !slot_go && !(kill_i && !slot_q.write));
      replay_pending_q <= install_go && target_live_q && !(kill_i && !target_q.write);
      install_last_q <= install_go;
      if (state_q == IDLE) begin
        target_q <= stage_q;
        target_live_q <= start_miss;
        miss_way_q <= victim_way;
        writeback_line_q <= {read_tag[victim_way], stage_set};
        line_q <= read_data[victim_way];
      end else if (kill_i && !target_q.write) target_live_q <= 0;

      // the held write: one in flight from entry to landing
      if (write_enter) write_busy_q <= 1;
      else if (land_go) write_busy_q <= 0;
      land_valid_q <= decide_hit && stage_q.write;
      land_way_q <= hit_way[1];
      write_last_q <= land_go;
      write_last_set_q <= write_set;
      write_last_way_q <= land_way_q;

      // line state
      if (decide_hit) lru_q[stage_set] <= !hit_way[1];
      if (start_miss) {valid_q[stage_set][victim_way], dirty_q[stage_set][victim_way]} <= 2'b00;
      if (land_go) dirty_q[write_set][land_way_q] <= 1;
      if (install_go) begin
        {valid_q[target_set][miss_way_q], dirty_q[target_set][miss_way_q]} <= 2'b10;
        lru_q[target_set] <= !miss_way_q;
      end

      // miss handler and clean walk
      if (responded) transaction_q <= transaction_q + 1'b1;
      if (malformed || access_fault) fatal_q <= 1;
      clean_done_q <= 0;
      case (state_q)
        IDLE:
          if (start_miss) state_q <= dirty_q[stage_set][victim_way] ? WB_REQUEST : FILL_REQUEST;
          else if (clean_start) begin
            walk_q <= 1;
            clean_index_q <= '0;
            state_q <= CLEAN_SCAN;
          end
        CLEAN_SCAN: if (dirty_q[clean_set][clean_way]) state_q <= CLEAN_READ;
        CLEAN_READ: begin
          line_q <= read_data[clean_way];
          writeback_line_q <= {read_tag[clean_way], clean_set};
          dirty_q[clean_set][clean_way] <= 0;
          state_q <= WB_REQUEST;
        end
        WB_REQUEST: if (mem_request_ready_i) state_q <= WB_RESPONSE;
        WB_RESPONSE: if (response_ok && !walk_q) state_q <= FILL_REQUEST;
        FILL_REQUEST: if (mem_request_ready_i) state_q <= FILL_RESPONSE;
        FILL_RESPONSE: if (response_ok) begin
          line_q <= mem_response_i.line_read_data;
          state_q <= INSTALL;
        end
        INSTALL: if (install_go) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
      if (walk_step) begin
        if (&clean_index_q) begin
          {walk_q, cleaning_q, clean_done_q} <= 3'b001;
          state_q <= IDLE;
        end else begin
          clean_index_q <= clean_index_q + 1'b1;
          state_q <= CLEAN_SCAN;
        end
      end
      if (clean_i) cleaning_q <= 1;
    end
  end

  // checks: design invariants are fatal; a bus error is an environment event and is only named
`ifndef SYNTHESIS
  logic held_q, replayed_q;
  logic [67:0] held_fields_q;
  always_ff @(posedge clk_i) begin
    held_q <= !rst_i && write_valid_i && !write_done_o;
    held_fields_q <= {write_address_i, write_data_i, write_mask_i};
    replayed_q <= replay_pending_q && enter;
    // after fatal the state is dead and only the gated outputs matter
    if (!rst_i && !fatal_q) begin
      assert (!held_q || (write_valid_i && {write_address_i, write_data_i, write_mask_i} == held_fields_q))
        else $fatal(1, "DC_WRITE_HELD");
      assert (!clean_i || !(write_valid_i || write_busy_q)) else $fatal(1, "DC_CLEAN_WITH_WRITE");
      assert (!clean_i || !cleaning_q) else $fatal(1, "DC_CLEAN_TWICE");
      assert (!park || !slot_full_q || slot_go) else $fatal(1, "DC_SLOT_OVERFLOW");
      assert (!land_go || valid_q[write_set][land_way_q]) else $fatal(1, "DC_LAND_INVALID");
      assert ((dirty_q & ~valid_q) == '0) else $fatal(1, "DC_DIRTY_INVALID");
      assert (!(replayed_q && stage_live) || decide_hit) else $fatal(1, "DC_REPLAY_MISS");
      if (load_valid_i && load_ready_o)
        assert (load_size_i <= 2 && !(load_size_i == 2 && load_unsigned_i) && (load_size_i != 1 || !load_address_i[0])
          && (load_size_i != 2 || load_address_i[1:0] == 0)) else $fatal(1, "DC_LOAD_ACCESS");
      if (write_enter) assert (write_mask_i != 0) else $fatal(1, "DC_WRITE_MASK");
    end
    if (!rst_i) begin
      if (!fatal_q && malformed) $display("DC_PROTOCOL status=%0d id=%0d", mem_response_i.status,
                                          mem_response_i.transaction_id);
      else if (!fatal_q && access_fault && state_q == FILL_RESPONSE) $display("DC_REFILL_FAULT");
      else if (!fatal_q && access_fault) $display("DC_WRITEBACK_FAULT");
    end
  end
`endif
endmodule
`default_nettype wire
