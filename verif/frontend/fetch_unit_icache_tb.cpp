// Fetch with the instruction cache (ICACHE=1, PREDICT=1, AHEAD=1, TAGE=1), driven as a memory target: every
// delivered lane is scored against the memory image, the instruction port is checked against the protocol and
// fence.i's hold, and an invalidate changes the image, as a cleaned store does. Directed runs time a redirect hit,
// a resident straight-line run and redirects racing a prefetch.
#include "../common/packed_bits.hpp"
using packed_bits::put;
using packed_bits::get32;
#include "Vfetch_unit.h"
#include "Vfetch_unit___024root.h"
#include "verilated.h"
#include "fetch_memory_layout.hpp"
#include <cstdint>
#include <iostream>
#include <map>
#include <random>
#include <stdexcept>
#include <string>

#define CACHE(name) d.rootp->fetch_unit__DOT__icache__DOT__cache__DOT__##name

// Words carry no control flow, so fetch runs sequentially and the predictor stays silent; each epoch changes them all.
static uint32_t word(uint32_t address, unsigned epoch) {
    const uint32_t h=(address*0x9e3779b9U) ^ (epoch*0x85ebca6bU) ^ 0x2545f491U;
    return (h & ~0x7fU) | 0x13U;
}
static bool faulty(uint32_t line) { return line%23==7; }   // lines the target answers with an access fault
static bool executable(uint32_t pc) { return pc<65536; }

struct Input {
    bool reset=false, enable=true, redirect=false, request_ready=true, hold=false, invalidate=false, corrupt=false;
    uint32_t target=0;
    unsigned take=0;                  // a lane mask: the bench takes this prefix of what fetch offers
};
struct Bench {
    Vfetch_unit d;
    unsigned cycles=0, epoch=0, min_epoch=0, latency=1, id=0, idle=0;
    uint32_t pc=0, line=0, request_line=0;
    unsigned request_epoch=0, response_cycle=0, fatal_wait=0;
    bool offered=false, pending=false, stopped=false, fatal=false, held=false, refresh=false;
    // sampled in the last cycle
    bool prefetch_accepted=false, lookup=false, read=false, busy=false;
    unsigned valid=0, requests=0;
    std::map<uint32_t, unsigned> line_requests;
    std::map<std::string, unsigned> coverage;
    void require(bool good, const std::string& message) const {
        if (!good) throw std::runtime_error("fetch icache mismatch cycle="+std::to_string(cycles)+": "+message);
    }
    void tick(Input i={}) {
        const bool respond=!i.reset && pending && cycles>=response_cycle;
        d.clk_i=0; d.rst_i=i.reset; d.enable_i=i.enable; d.redirect_i=i.redirect; d.redirect_pc_i=i.target;
        d.invalidate_i=i.invalidate; d.hold_i=i.hold; d.request_ready_i=i.request_ready;
        d.response_valid_i=respond || i.corrupt; d.take_i=i.take;
        d.repair_i=0; d.repair_checkpoint_i=0; d.retire_i=0;
        d.retire_instruction_i=0; d.retire_pc_i=0; d.retire_next_i=0;
        for (unsigned n=0; n<(RESPONSE_BITS+31)/32; ++n) d.response_i[n]=0;
        if (respond || i.corrupt) {
            put(d.response_i, RESPONSE_TRANSACTION_ID_OFFSET, 4, id ^ (i.corrupt ? 1U : 0U));
            if (faulty(request_line)) put(d.response_i, RESPONSE_STATUS_OFFSET, 2, 1);
            else for (unsigned n=0; n<8; ++n)
                put(d.response_i, RESPONSE_LINE_READ_DATA_OFFSET+32*n, 32, word(request_line*32+4*n, request_epoch));
        }
        d.eval();
        const unsigned take=d.valid_o & i.take;
        d.take_i=take; d.eval();
        prefetch_accepted=CACHE(prefetch_valid_i) && CACHE(prefetch_ready_o);
        lookup=CACHE(lookup_valid_i);
        read=lookup || CACHE(prefetch_read);
        valid=d.valid_o; busy=d.busy_o;
        coverage["cache_hit"]+=CACHE(hit_valid_o);
        coverage["cache_miss"]+=CACHE(miss_o);
        coverage["prefetch_hit"]+=CACHE(prefetch_hit_o);
        coverage["cache_retry"]+=CACHE(stage_valid_q) && !CACHE(stage_prefetch_q) && !CACHE(hit_valid_o) && !CACHE(miss_o);
        if (i.reset) {
            require(!d.request_valid_o && !d.response_ready_o && !d.valid_o && !d.busy_o, "reset suppresses interfaces");
            coverage[pending ? "reset_pending" : offered ? "reset_offered" : "reset_idle"]++;
            pc=0; id=0; idle=0; min_epoch=epoch;
            offered=pending=stopped=fatal=held=refresh=false; fatal_wait=0;
        } else if (fatal) {
            require(d.fatal_o && !d.request_valid_o && !d.response_ready_o && !d.valid_o && !d.busy_o,
                    "sticky fatal blocks traffic");
            coverage["fatal_hold"]++;
        } else {
            require(!d.fatal_o || fatal_wait, "unexpected fatal");
            if (d.fatal_o) { fatal=true; coverage["fatal"]++; }
            if (fatal_wait && !--fatal_wait) require(fatal, "malformed response not fatal");
            score(i, take);
            port(i, respond);
        }
        if (i.invalidate) { ++epoch; refresh=true; coverage["invalidate"]++; }
        if (i.redirect && refresh) { min_epoch=epoch; refresh=false; }
        if (i.corrupt) fatal_wait=3;
        held=!i.reset && i.hold;
        d.clk_i=1; d.eval(); ++cycles;
    }
    // every lane follows the demanded pc and carries the image of an epoch the last fence.i redirect allows
    void score(const Input& i, unsigned take) {
        require(d.predict_taken_o==0, "prediction without control flow");
        if (i.redirect) require(d.valid_o==0, "redirect hides output");
        else if (d.valid_o) {
            idle=0;
            require(uint32_t(d.pc_o)==pc, "instruction PC");
            if (d.fault_o) {
                require(d.valid_o==1 && (pc%4 || !executable(pc) || faulty(pc/32)), "unexpected fault");
                require(d.fault_cause_o==(pc%4 ? 0U : 1U), "fault cause");
                coverage[pc%4 ? "alignment_fault" : executable(pc) ? "bus_fault" : "pma_fault"]++;
            } else {
                require(pc%4==0 && executable(pc) && !faulty(pc/32), "missing fault");
                require(d.valid_o==(pc%32==28 ? 1U : 3U), "lane availability");
                unsigned e=min_epoch;
                auto match=[&](unsigned v) {
                    for (unsigned lane=0; lane<(d.valid_o==3 ? 2U : 1U); ++lane)
                        if (uint32_t(d.instruction_o>>(32*lane))!=word(pc+4*lane, v)) return false;
                    return true;
                };
                while (e<=epoch && !match(e)) ++e;
                require(e<=epoch, "instruction data/order");
                if (e<epoch) coverage["older_epoch"]++;
                if (d.valid_o==3) require(uint32_t(d.pc_o>>32)==pc+4, "second lane PC");
            }
        } else if (!stopped && i.enable) require(++idle<300, "fetch progress");
        if (i.redirect) { pc=i.target; stopped=false; idle=0; coverage["redirect"]++; }
        else if (take) {
            if (d.fault_o) { stopped=true; coverage["fault_take"]++; }
            else coverage[take==3 ? "dual_take" : d.valid_o==3 ? "partial_pair" : "line_tail"]++;
            pc+=take==3 ? 8 : 4;
        }
    }
    // instruction port: one line read at a time, stable until accepted, none started under fence.i's hold
    void port(const Input& i, bool respond) {
        if (offered) require(d.request_valid_o, "request withdrawn");
        require(bool(d.response_ready_o)==pending, "response ownership");
        if (d.request_valid_o) {
            const uint32_t address=get32(d.request_o, REQUEST_ADDRESS_OFFSET, 32);
            if (!offered) {
                require(!pending && !held, held ? "request under fence.i hold" : "multiple requests");
                require(address%32==0 && executable(address), "request address");
                line=address/32; offered=true;
                coverage["request"]++;
            }
            for (unsigned b=0; b<REQUEST_BITS; ++b) {
                unsigned bit=0;
                if (b>=REQUEST_ADDRESS_OFFSET && b<REQUEST_ADDRESS_OFFSET+32) bit=(line*32 >> (b-REQUEST_ADDRESS_OFFSET)) & 1U;
                if (b>=REQUEST_TRANSACTION_ID_OFFSET && b<REQUEST_TRANSACTION_ID_OFFSET+4)
                    bit=(id >> (b-REQUEST_TRANSACTION_ID_OFFSET)) & 1U;
                require(get32(d.request_o, b, 1)==bit, "request payload/stability");
            }
            if (!i.request_ready) coverage["request_stall"]++;
        }
        if (held && CACHE(mem_request_valid_o) && !d.request_valid_o) coverage["hold_blocked"]++;
        require(!(offered || pending) || d.busy_o, "busy covers the instruction port");
        if (respond) {
            pending=false; id=(id+1)%16;
            coverage[faulty(request_line) ? "fill_fault" : "fill"]++;
            if (!id) coverage["id_wrap"]++;
        }
        if (offered && i.request_ready) {
            // the target reads the image at acceptance; an invalidate in this cycle comes after the read
            offered=false; pending=true; request_line=line; request_epoch=epoch;
            response_cycle=cycles+latency; ++requests; ++line_requests[line];
            if (i.invalidate) coverage["invalidate_accept"]++;
        }
        if (i.invalidate && pending) coverage["invalidate_in_flight"]++;
    }
    void reset() { Input i; i.reset=true; tick(i); line_requests.clear(); }
    void redirect(uint32_t target) { Input i; i.redirect=true; i.target=target; tick(i); }
    // run with every offered lane taken until the demanded pc reaches end
    void fetch_until(uint32_t end) {
        for (unsigned n=0; pc!=end; ++n) {
            require(n<400, "fetch_until progress");
            Input i; i.take=3; tick(i);
        }
    }
    // disabled, fetch keeps its line and the cache finishes every transaction
    void quiesce() {
        unsigned n=0;
        do { require(n++<100, "drain"); Input i; i.enable=false; tick(i); } while (busy || pending || offered);
    }
    // make a line resident without its next line: fetch is enabled only for the redirect's lookup
    void warm(uint32_t address) {
        quiesce();
        redirect(address);
        { Input i; tick(i); }
        for (unsigned n=0; !valid; ++n) { require(n<100, "warm progress"); Input i; i.enable=false; tick(i); }
        quiesce();
    }
};

// cycles without output between a redirect to a resident line and its first lanes
static unsigned hit_bubbles(Bench& b, uint32_t target) {
    b.quiesce();
    b.redirect(target);
    unsigned bubbles=0;
    for (b.tick(); !b.valid; b.tick()) b.require(++bubbles<20, "redirect hit progress");
    return bubbles;
}
static unsigned directed(Bench& b) {
    b.reset();
    b.latency=3;
    // resident lines 0x100..0x1ff, warmed sequentially; 0x2000 alone, without its next line
    b.redirect(0x100); b.fetch_until(0x200);
    b.warm(0x300); b.warm(0x2000); b.warm(0x2400);
    // redirect_hit_no_bubble: every offset of a resident line delivers after the same bubbles
    const unsigned bubbles=hit_bubbles(b, 0x100);
    for (unsigned k=0; k<8; ++k)
        b.require(hit_bubbles(b, 0x100+0x20*k+4*k)==bubbles, "redirect hit bubbles differ");
    b.require(bubbles<=2, "redirect hit is slower than its cache read");
    b.coverage["redirect_hit_no_bubble"]++;
    // sequential_crossing_no_bubble: eight resident lines, one cache read each, no gap
    b.quiesce();
    b.redirect(0x100);
    unsigned reads=b.read, lookups=b.lookup, gaps=0;
    bool started=false;
    for (unsigned n=0; b.pc!=0x200; ++n) {
        b.require(n<100, "crossing progress");
        Input i; i.take=3; b.tick(i);
        started|=b.valid!=0;
        if (started && !b.valid) ++gaps;
        reads+=b.read; lookups+=b.lookup;
    }
    b.require(gaps==0, "sequential crossing gap: "+std::to_string(gaps));
    b.require(lookups==1 && reads<=9, "cache reads per line: "+std::to_string(reads));
    b.coverage["sequential_crossing_no_bubble"]++;
    // redirect_during_prefetch: in the offer cycle, its read, its check and with the ahead line filled; the
    // redirect target's next line is missing
    const char* phases[]={"offer", "read", "check", "filled"};
    for (unsigned phase=0; phase<4; ++phase) {
        b.quiesce();
        b.redirect(0x100);
        for (unsigned n=0; n<bubbles; ++n) b.tick();
        if (phase) {
            for (unsigned n=0; !b.prefetch_accepted; ++n) { b.require(n<4, "prefetch offer"); b.tick(); }
            for (unsigned n=1; n<phase; ++n) b.tick();
        }
        b.redirect(0x300);
        b.require(phase || b.prefetch_accepted, "offer cycle missed");
        b.fetch_until(0x340);
        b.coverage[std::string("redirect_during_prefetch_")+phases[phase]]++;
    }
    // a prefetch miss in flight: a redirect elsewhere waits behind it; one onto its line takes its fill
    for (uint32_t target : {0x2e00U, 0x2020U}) {
        b.quiesce();
        { Input i; i.enable=false; i.invalidate=true; i.redirect=true; i.target=0x2000; b.tick(i); }
        b.warm(0x2000);
        b.latency=8;
        const unsigned before=b.line_requests[0x2020/32];
        b.redirect(0x2000);
        for (unsigned n=0; !b.pending || b.request_line!=0x2020/32; ++n) { b.require(n<20, "prefetch miss"); b.tick(); }
        b.redirect(target);
        b.fetch_until(target+32);
        b.require(target!=0x2020 || b.line_requests[0x2020/32]==before+1, "filling line requested twice");
        b.coverage[target==0x2020 ? "redirect_to_filling_line" : "redirect_during_prefetch_miss"]++;
        b.latency=3;
    }
    // a check cancelled by the redirect in its offer or read cycle is neither read nor requested; fetch is
    // disabled after the redirect, so no lookup takes the read port in its place
    for (unsigned phase=0; phase<2; ++phase) {
        b.quiesce();
        { Input i; i.enable=false; i.invalidate=true; i.redirect=true; i.target=0x2000; b.tick(i); }
        b.warm(0x2000);
        const unsigned before=b.line_requests[0x2020/32];
        b.redirect(0x2000);
        for (unsigned n=0; n<bubbles; ++n) b.tick();
        if (phase) for (unsigned n=0; !b.prefetch_accepted; ++n) { b.require(n<4, "prefetch offer"); b.tick(); }
        b.redirect(0x100);
        b.require(phase || b.prefetch_accepted, "offer cycle missed");
        { Input i; i.enable=false; b.tick(i); }
        b.fetch_until(0x140);
        b.quiesce();
        b.require(b.line_requests[0x2020/32]==before, "cancelled prefetch requested");
        b.coverage[phase ? "cancelled_prefetch_read" : "cancelled_prefetch_offer"]++;
    }
    // a miss decided around an install into its set retries, and fetch looks the line up again
    const unsigned retries=b.coverage["cache_retry"];
    for (int offset=-1; offset<=1; ++offset) {
        b.quiesce();
        { Input i; i.enable=false; i.invalidate=true; i.redirect=true; i.target=0x2000; b.tick(i); }
        b.warm(0x2000);
        b.latency=4;
        b.redirect(0x2000);
        for (unsigned n=0; !b.pending || b.request_line!=0x2020/32; ++n) { b.require(n<20, "prefetch miss"); b.tick(); }
        while (int(b.cycles)<int(b.response_cycle)+offset) b.tick();
        b.redirect(0x2220);
        b.fetch_until(0x2240);
        b.latency=3;
    }
    b.require(b.coverage["cache_retry"]>retries, "no install-race retry");
    b.coverage["install_race_retry"]++;
    // fence.i: a missing line waits under the hold; the invalidate makes a resident line read again
    b.quiesce();
    const unsigned before=b.line_requests[0x100/32];
    { Input i; i.hold=true; i.redirect=true; i.target=0x3000; b.tick(i); }
    for (unsigned n=0; n<6; ++n) { Input i; i.hold=true; b.tick(i); }
    { Input i; i.invalidate=true; i.redirect=true; i.target=0x100; b.tick(i); }
    b.fetch_until(0x120);
    b.require(b.line_requests[0x100/32]==before+1, "invalidated line not read again");
    b.coverage["fence_refetch"]++;
    // an invalidate while the line's read is in flight discards that fill
    b.quiesce();
    b.latency=6;
    b.redirect(0x140);
    for (unsigned n=0; !b.pending || b.request_line!=0x140/32; ++n) { b.require(n<20, "line read"); b.tick(); }
    { Input i; i.invalidate=true; i.redirect=true; i.target=0x140; b.tick(i); }
    b.fetch_until(0x160);
    b.require(b.line_requests[0x140/32]>=2, "invalidated fill delivered");
    b.latency=3;
    // fetch drains when disabled
    b.quiesce();
    b.coverage["drain"]++;
    // reset drops an offered request
    { Input i; i.enable=false; i.invalidate=true; i.redirect=true; i.target=0x100; b.tick(i); }
    for (unsigned n=0; !b.offered; ++n) { b.require(n<10, "offer before reset"); Input i; i.request_ready=false; b.tick(i); }
    b.reset();
    return bubbles;
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Bench b;
        // a malformed response is fatal through the cache, which names it on stdout
        if (argc>1 && std::string(argv[1])=="fatal") {
            b.reset(); b.redirect(0x100); b.fetch_until(0x110); b.quiesce();
            { Input i; i.corrupt=true; b.tick(i); }
            for (unsigned n=0; n<6; ++n) b.tick();
            b.require(b.coverage["fatal"] && b.coverage["fatal_hold"], "malformed response not fatal");
            b.reset(); b.redirect(0x100); b.fetch_until(0x120);
            std::cout << "FETCH ICACHE FATAL PASS\n";
            return 0;
        }
        const unsigned seed=argc>1 ? std::stoul(argv[1]) : 1;
        const unsigned random_cycles=argc>2 ? std::stoul(argv[2]) : 20000;
        const unsigned bubbles=directed(b);
        const unsigned directed_cycles=b.cycles;
        std::mt19937 rng(seed);
        unsigned hold=0, due=0;
        bool invalidate=false;
        for (unsigned n=0; n<random_cycles; ++n) {
            Input i;
            i.reset=rng()%2003==0;
            i.enable=rng()%4!=0;
            i.request_ready=rng()%3!=0;
            if (n%64==0) b.latency=1+rng()%4;
            // fence.i: hold cycles, then the invalidate, then its redirect in that cycle or up to two later
            bool fence_redirect=false;
            if (!hold && !invalidate && !due && rng()%97==0) hold=1+rng()%6;
            if (hold) { i.hold=true; invalidate=!--hold; }
            else if (invalidate) { i.invalidate=true; invalidate=false; due=rng()%3; fence_redirect=!due; }
            else if (due) fence_redirect=!--due;
            i.redirect=rng()%29==0 || b.stopped || fence_redirect;
            if (i.redirect) due=0;
            // half the targets fall in 512 bytes the cache can hold
            i.target=rng()%2 ? 0x400+(rng()%128)*4 : (rng()%2048)*4;
            if (rng()%37==0) i.target|=2;
            if (rng()%41==0) i.target=0x10000000;
            i.take=i.redirect || i.reset || rng()%3==0 ? 0 : rng()%2 ? 3 : 1;
            b.tick(i);
        }
        b.reset(); b.redirect(0x100); b.fetch_until(0x120);
        std::cout << "FETCH ICACHE PASS seed=" << seed << " directed=" << directed_cycles
                  << " random=" << random_cycles << " cycles=" << b.cycles << " hit_bubbles=" << bubbles;
        for (const auto& [name, count] : b.coverage) std::cout << ' ' << name << '=' << count;
        std::cout << '\n';
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
