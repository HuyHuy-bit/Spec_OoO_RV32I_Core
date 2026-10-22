// Runs a raw program image on the fetched memory core and prints accepted architectural events.
// With a tohost address (ACT4), the run ends at tohost == 1 after every write drains; the count is a limit.
// Mode perf holds every external readiness high, answers after fixed latencies and ends at a terminal PC;
// +read_latency=N +write_latency=N +terminal=PC [+warm=PC:n:PC:n]. The count is a limit.
// Perf mode also prints COUNTER <all|region> <name> <value> lines (docs: perf-counters).
#include "Vcpu_top.h"
#include "Vcpu_top___024root.h"
#include "verilated.h"
#include "fields.hpp"
#include "../common/packed_bits.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

using packed_bits::get32;
using packed_bits::put;

static void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}
struct Transaction {
    bool pending=false, write=false, uncached=false;
    unsigned delay=0, id=0, address=0, mask=0, size=0;
    std::array<uint32_t,8> words{};
};
struct Write { unsigned address, mask; uint32_t data; };
constexpr unsigned SLOT_WORDS=(EVENT_BITS+31)/32;

// Verification-only activity counters (docs: perf-counters), sampled before each perf edge.
// They read Verilator internals; TB_<parameter> defines from the build select the profile's hierarchy.
#define CORE(name) dut.rootp->cpu_top__DOT__##name
#define BACKEND(name) CORE(backend__DOT__##name)
#define ROB(name) BACKEND(backend__DOT__backend__DOT__rob__DOT__##name)
#define MEMORY(name) BACKEND(systems__DOT__memory_service__DOT__##name)
static const char* kind(uint32_t word) {
    const unsigned rd=(word>>7)&31, rs1=(word>>15)&31;
    switch (word&127) {
    case 0x03: return "load";
    case 0x23: return "store";
    case 0x63: return "branch";
    case 0x6f: return "jal";
    case 0x67: return rd==0 && (rs1==1 || rs1==5) ? "return":"jalr";
    case 0x0f: case 0x73: return "system";
    default: return "alu";
    }
}
static void sample(Vcpu_top& dut,const std::vector<uint8_t>& memory,std::map<std::string,uint64_t>& c) {
    auto word=[&](uint32_t pc) { uint32_t w=0; for (unsigned n=0;n<4;++n) w|=pc+n<memory.size() ? uint32_t(memory[pc+n])<<(8*n):0; return w; };
    auto ones=[](unsigned bits) { return std::to_string((bits&1)+(bits>>1&1)); };
    ++c["cycles"];
    ++c["retire_"+ones(dut.retire_accept_o)];
    ++c["dispatch_"+ones(dut.dispatch_o)];
    ++c["issue_"+ones(BACKEND(issue_o))];
    c["fetch_absent"]+=!dut.fetch_valid_o;
    c["rob_empty"]+=!dut.occupancy_o;
    c["rob_full"]+=dut.occupancy_o==32;
    c["iq_empty"]+=!BACKEND(backend__DOT__queue__DOT__valid_q);
    c["iq_full"]+=BACKEND(backend__DOT__queue__DOT__valid_q)==0xffff;
    if (!dut.retire_accept_o) ++c[std::string("blocked_head_")+(dut.occupancy_o ? kind(word(ROB(pc_q)[ROB(head_q)])):"empty")];
    c["head_read"]+=BACKEND(head_read);
    c["serial_retire"]+=BACKEND(serial_accept);
    c["redirect"]+=dut.redirect_o;
    // Resolutions include wrong-path branches; their slot names the resolving instruction.
    const std::string branch=kind(word(ROB(pc_q)[BACKEND(completion_id_o)&31]));
    require(!CORE(branch_redirect) || BACKEND(resolve_accept_o),"branch redirect without an accepted resolution");
    if (BACKEND(resolve_accept_o)) ++c["resolve_"+branch];
    if (CORE(branch_redirect)) ++c["branch_redirect_"+branch];
    c["committed_busy"]+=dut.memory_committed_o;
#if TB_EARLY_LOADS
    c["early_memory_launch"]+=MEMORY(early_loads__DOT__lsu__DOT__launch_memory);
    c["forward_launch"]+=MEMORY(early_loads__DOT__lsu__DOT__launch_forward);
#endif
}

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try {
        require(argc>=5,"image, seed, event count and mode required");
        std::ifstream file(argv[1],std::ios::binary);
        require(bool(file),"cannot open program");
        std::vector<uint8_t> image((std::istreambuf_iterator<char>(file)),{});
        require(image.size()<=65536,"program exceeds BRAM");
        image.resize(65536);
        std::mt19937 random(std::stoul(argv[2]));
        const unsigned target=std::stoul(argv[3]);
        const std::string mode=argv[4];
        const bool stall=mode=="stall" || mode=="hold_drain";
        const bool perf=mode=="perf";
        const bool act4=argc>5 && argv[5][0]!='+';
        auto plusarg=[&](const std::string& name) -> std::string {
            for (int n=5;n<argc;++n) if (std::string(argv[n]).rfind("+"+name+"=",0)==0) return argv[n]+name.size()+2;
            return "";
        };
        unsigned read_latency=1, write_latency=1, terminal=0, warm[4]={};
        bool warm_window=false;
        if (perf) {
            require(!act4 && !plusarg("terminal").empty(),"perf mode needs a terminal PC");
            read_latency=std::stoul(plusarg("read_latency")); write_latency=std::stoul(plusarg("write_latency"));
            terminal=std::stoul(plusarg("terminal"),nullptr,0);
            require(read_latency && write_latency,"zero-cycle responses are not modeled");
            const std::string spec=plusarg("warm");
            warm_window=!spec.empty();
            for (unsigned n=0,at=0;warm_window && n<4;++n) {
                const size_t end=spec.find(':',at);
                warm[n]=std::stoul(spec.substr(at,end-at),nullptr,0);
                at=end+1;
            }
        }
        const unsigned tohost=act4 ? std::stoul(argv[5],nullptr,0):0;
        require(!act4 || (!(tohost&7) && tohost<=65528),"invalid tohost address");
        // The infallible RAM target is the explicit admission guarantor for cached stores.
        auto memory=image;
        std::array<uint8_t,48> mmio{};
        Vcpu_top dut;
        Transaction instruction, data;
        std::array<uint32_t,REQUEST_WORDS> held_i{}, held_d{};
        bool hold_i=false, hold_d=false, reset_done=false;
        unsigned events=0, dual=0, recycles=0;
        bool draining=false;
        bool halted=false, tohost_retired=false;
        // Ownership monitors: cached writes follow their retirement; MMIO traffic precedes it.
        std::deque<Write> cached_writes, mmio_writes;
        std::deque<unsigned> mmio_reads;
        auto byte=[&](unsigned address) -> uint8_t& {
            if (address<memory.size()) return memory[address];
            if (address>=0x10000000 && address<0x10000010) return mmio[address-0x10000000];
            if (address>=0x10001000 && address<0x10001020) return mmio[16+address-0x10001000];
            throw std::runtime_error("request outside PMA");
        };
        auto ready=[&] { return stall ? random()%4==0:random()%4!=0; };
        auto reset=[&] {
            instruction={}; data={}; memory=image; mmio.fill(0);
            cached_writes.clear(); mmio_writes.clear(); mmio_reads.clear();
            hold_i=hold_d=false; events=0; halted=tohost_retired=false;
            dut.rst_i=1; dut.response_valid_i=0; dut.data_response_valid_i=0;
            for (int n=0;n<3;++n) { dut.clk_i=0; dut.eval(); dut.clk_i=1; dut.eval(); }
            dut.rst_i=0;
            std::cout<<"RESET\n";
        };
        auto respond=[&](Transaction& tx,auto& response) {
            for (unsigned n=0;n<RESPONSE_WORDS;++n) response[n]=0;
            if (!tx.pending || tx.delay) return;
            put(response,RSP_TRANSACTION_ID,4,tx.id);
            if (tx.write) return;
            if (tx.uncached) put(response,RSP_UNCACHED_READ_DATA,32,tx.words[0]);
            else for (unsigned n=0;n<8;++n) put(response,RSP_LINE_READ_DATA+32*n,32,tx.words[n]);
        };
        // Read data is captured at acceptance; writes reach the target at their response.
        auto accept=[&](Transaction& tx,const auto& request,bool is_data) {
            require(!tx.pending,"request reused an occupied slot");
            tx.pending=true; tx.delay=perf ? (get32(request,REQ_WRITE,1) ? write_latency:read_latency)-1 : stall ? random()%12:random()%5;
            tx.id=get32(request,REQ_TRANSACTION_ID,4); tx.address=get32(request,REQ_ADDRESS,32);
            tx.uncached=get32(request,REQ_UNCACHED,1); tx.write=get32(request,REQ_WRITE,1);
            tx.size=get32(request,REQ_UNCACHED_SIZE,2);
            require(is_data || (!tx.write && !tx.uncached),"invalid instruction request");
            require(tx.uncached || !(tx.address&31),"unaligned line request");
            tx.mask=get32(request,tx.uncached ? REQ_UNCACHED_WRITE_STROBE:REQ_LINE_WRITE_MASK,tx.uncached ? 4:32);
            const unsigned base=tx.uncached ? tx.address&~3u:tx.address;
            for (unsigned w=0;w<(tx.uncached ? 1u:8u);++w) {
                if (tx.write) tx.words[w]=get32(request,(tx.uncached ? REQ_UNCACHED_WRITE_DATA:REQ_LINE_WRITE_DATA)+w*32,32);
                else {
                    uint32_t value=0;
                    for (unsigned lane=0;lane<4;++lane) value|=uint32_t(byte(base+4*w+lane))<<(8*lane);
                    if (tx.uncached) value&=(tx.size==2 ? 0xffffffffu:(1u<<(8u<<tx.size))-1)<<(8*(tx.address&3));
                    tx.words[w]=value;
                }
            }
            if (!is_data) return;
            if (tx.write && !tx.uncached) {
                require(!cached_writes.empty(),"cached store issued before retirement");
                const Write w=cached_writes.front(); cached_writes.pop_front();
                uint32_t lanes=0;
                for (unsigned lane=0;lane<4;++lane) if ((w.mask>>lane)&1) lanes|=0xffu<<(8*lane);
                require((w.address&~31u)==tx.address && tx.mask==w.mask<<(w.address&28)
                        && ((tx.words[(w.address&31)/4]^w.data)&lanes)==0,"cached store request differs from its retirement");
            } else if (tx.write) mmio_writes.push_back({tx.address&~3u,tx.mask,tx.words[0]});
            else if (tx.uncached) mmio_reads.push_back(tx.address);
        };
        auto complete=[&](Transaction& tx) {
            if (tx.write) {
                const unsigned base=tx.uncached ? tx.address&~3u:tx.address;
                for (unsigned lane=0;lane<(tx.uncached ? 4u:32u);++lane)
                    if ((tx.mask>>lane)&1) byte(base+lane)=uint8_t(tx.words[lane/4]>>(8*(lane%4)));
                uint64_t status=0;
                for (unsigned lane=0;act4 && lane<8;++lane) status|=uint64_t(memory[tohost+lane])<<(8*lane);
                require(!status || status==1,"ACT4 FAIL tohost="+std::to_string(status));
                halted|=status==1;
            }
            tx.pending=false;
        };
        // Perf counters: whole edges from the first enabled edge after reset; terminal edge inclusive.
        uint64_t cycle=0, retired=0, bins[3]={}, terminal_cycle=0, warm_at[2][2]={}, warm_edge=0;
        unsigned warm_seen[2]={};
        bool terminal_seen=false;
        auto observe=[&](const auto& bus,unsigned offset,unsigned lane) {
            std::array<uint32_t,SLOT_WORDS> slot{};
            for (unsigned n=0;n<SLOT_WORDS;++n) slot[n]=get32(bus,offset+32*n,std::min(32u,EVENT_BITS-32*n));
            const unsigned address=get32(slot,EV_MEM_ADDRESS,32), write=get32(slot,EV_MEM_WRITE_MASK,4);
            tohost_retired|=act4 && write && address>=tohost && address<tohost+8;
            if (write && address<0x10000000) cached_writes.push_back({address,write,get32(slot,EV_MEM_WRITE_DATA,32)});
            else if (write) {
                require(!mmio_writes.empty() && mmio_writes.front().address==(address&~3u) && mmio_writes.front().mask==write
                        && mmio_writes.front().data==get32(slot,EV_MEM_WRITE_DATA,32),"MMIO store retired without its device write");
                mmio_writes.pop_front();
            } else if (get32(slot,EV_MEM_READ_MASK,4) && address>=0x10000000) {
                require(!mmio_reads.empty() && mmio_reads.front()==address,"MMIO load retired without its device read");
                mmio_reads.pop_front();
            }
            if (!act4) {
                if (perf) std::cout<<"EVENT "<<cycle<<' '<<lane;
                else std::cout<<"EVENT 0 0";
                for (unsigned n=0;n<SLOT_WORDS;++n) std::cout<<' '<<std::hex<<slot[n];
                std::cout<<std::dec<<'\n';
            }
            ++events;
            if (perf && get32(slot,EV_RETIRED,1)) {
                const unsigned pc=get32(slot,EV_PC_BEFORE,32);
                terminal_seen|=pc==terminal;
                for (unsigned n=0;warm_window && n<2;++n) if (pc==warm[2*n] && ++warm_seen[n]==warm[2*n+1]) warm_at[n][0]=cycle+1;
            }
        };
        auto hold=[&](const auto& bus,auto& snapshot,bool& held,bool valid,bool accepted) {
            if (held) {
                require(valid,"request withdrawn under backpressure");
                for (unsigned n=0;n<snapshot.size();++n) require(snapshot[n]==bus[n],"request changed under backpressure");
            }
            held=valid && !accepted;
            for (unsigned n=0;n<snapshot.size();++n) snapshot[n]=bus[n];
        };
        dut.enable_i=1; dut.flush_i=0; dut.drained_i=0; dut.flush_pc_i=0;
        reset();
        unsigned settled=0;
        std::map<std::string,uint64_t> counters[2];  // whole run, warm region
        for (cycle=0;cycle<target*200+5000;++cycle) {
            require(!act4 || halted || events<target,tohost_retired ? "ACT4 tohost store did not drain"
                    :"ACT4 instruction limit without tohost completion");
            const bool done=act4 ? halted:perf ? terminal_seen:events>=target;
            dut.clk_i=0;
            dut.memory_issue_allowed_i=ready();
            dut.request_ready_i=ready();
            dut.data_request_ready_i=mode=="hold_drain" && (act4 ? tohost_retired:events+1>=target) ? 0:ready();
            dut.execution_ready_i=random()%4; dut.completion_enable_i=random()%4;
            dut.retire_ready_i=done ? 0:!act4 && events+1==target ? random()%2:random()%4;
            dut.trap_ready_i=!done && random()%3!=0;
            dut.resolve_grant_i=random()%3!=0;
            respond(instruction,dut.response_i);
            respond(data,dut.data_response_i);
            dut.response_valid_i=instruction.pending && !instruction.delay;
            dut.data_response_valid_i=data.pending && !data.delay;
            if (mode=="fatal" && events>=target/2) { put(dut.response_i,RSP_STATUS,2,2); dut.response_valid_i=1; }
            if (perf) {
                // A slot frees on the edge its response is consumed, so a new request waits one cycle.
                dut.memory_issue_allowed_i=1;
                dut.request_ready_i=!instruction.pending;
                dut.data_request_ready_i=!data.pending;
                dut.execution_ready_i=3; dut.completion_enable_i=3;
                dut.retire_ready_i=done ? 0:3;
                dut.trap_ready_i=1; dut.resolve_grant_i=1;
            }
            dut.eval();
            dut.admit_valid_i=dut.admission_valid_o; dut.admit_id_i=dut.admission_id_o;
            dut.eval();
            if (!reset_done && events>100 && ((mode=="reset_fetch" && instruction.pending)
                || (mode=="reset_data" && data.pending) || (mode=="reset_commit" && dut.retire_valid_o))) {
                reset(); reset_done=true; draining=false; continue;
            }
            hold(dut.request_o,held_i,hold_i,dut.request_valid_o,dut.request_ready_i);
            hold(dut.data_request_o,held_d,hold_d,dut.data_request_valid_o,dut.data_request_ready_i);
            require(dut.retire_accept_o!=2 && !(dut.trap_accept_o && dut.retire_accept_o),"retirement order");
            if (dut.retire_accept_o==3) ++dual;
            require(!perf || !dut.trap_accept_o,"unexpected trap in perf mode");
            const unsigned accepted=(dut.retire_accept_o&1)+(dut.retire_accept_o>>1);
            for (unsigned lane=0;lane<2;++lane) if ((dut.retire_accept_o>>lane)&1) observe(dut.retire_event_o,lane*EVENT_BITS,lane);
            if (dut.trap_accept_o) observe(dut.trap_event_o,0,0);
            if (perf && !terminal_cycle) {
                sample(dut,memory,counters[0]);
                // The region holds edges warm_at[0][0] .. warm_at[1][0]-1, the same edges as warm_cycles.
                if (warm_at[0][0] && cycle>=warm_at[0][0] && (!warm_at[1][0] || cycle<warm_at[1][0])) sample(dut,memory,counters[1]);
                retired+=accepted; ++bins[accepted];
                if (terminal_seen) terminal_cycle=cycle+1;
                for (unsigned n=0;n<2;++n) if (warm_at[n][0]==cycle+1 && !warm_at[n][1]) {
                    warm_at[n][1]=retired;
                    if (!n) warm_edge=accepted;
                }
            }
            if (dut.response_valid_i && dut.response_ready_o) instruction.pending=false;
            if (dut.data_response_valid_i && dut.data_response_ready_o) complete(data);
            if (instruction.pending && instruction.delay) --instruction.delay;
            if (data.pending && data.delay) --data.delay;
            if (dut.request_valid_o && dut.request_ready_i) accept(instruction,dut.request_o,false);
            if (dut.data_request_valid_o && dut.data_request_ready_i) accept(data,dut.data_request_o,true);
            dut.clk_i=1; dut.eval();
            require(!dut.fatal_o,"platform fatal");
            require(act4 || events<=target,"retired past the event limit");
            // A falling drain request marks an on-chip identity recycle.
            if (draining && !dut.identity_drain_o) ++recycles;
            draining=dut.identity_drain_o;
            // ACT4's halt-loop store may hold memory_busy after all retired writes drain.
            if (done && (act4 || !dut.memory_busy_o) && !data.pending && cached_writes.empty() && mmio_writes.empty() && mmio_reads.empty()) {
                if (++settled<4) continue;
                require(mode.rfind("reset_",0)!=0 || reset_done,"reset scenario did not fire");
                if (perf) {
                    require(!warm_window || (warm_at[0][1] && warm_at[1][1] && warm_at[1][0]>warm_at[0][0]),"warm markers not reached in order");
                    std::cout<<"PERF cycles="<<terminal_cycle<<" retired="<<retired<<" zero="<<bins[0]<<" one="<<bins[1]
                             <<" two="<<bins[2]<<" drain="<<cycle-3-terminal_cycle;
                    if (warm_window) std::cout<<" warm_cycles="<<warm_at[1][0]-warm_at[0][0]<<" warm_retired="<<warm_at[1][1]-warm_at[0][1]
                                              <<" warm_start_edge="<<warm_edge<<" warm_start="<<warm_at[0][0];
                    std::cout<<'\n';
                    for (unsigned n=0;n<1u+warm_window;++n)
                        for (const auto& [name,value]:counters[n]) std::cout<<"COUNTER "<<(n ? "region ":"all ")<<name<<' '<<value<<'\n';
                }
                std::cout<<(act4 ? "ACT4 PASS events=":"CORE PASS events=")<<events<<" cycles="<<cycle+1<<" dual="<<dual<<" recycles="<<recycles<<'\n';
                return 0;
            }
            settled=0;
        }
        if (act4) throw std::runtime_error(tohost_retired ? "ACT4 tohost store did not drain":"watchdog expired");
        throw std::runtime_error(events>=target ? "final memory transaction did not drain":"watchdog expired");
    } catch (const std::exception& error) { std::cerr<<"FETCHED CORE FAIL "<<error.what()<<'\n'; return 1; }
}
