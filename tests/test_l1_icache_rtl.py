"""l1_icache against model/cache.py, a memory model and directed timing checks (verif/frontend/l1_icache_tb.sv)."""
from pathlib import Path
import random
import re
import subprocess
import tempfile
import unittest

from model.cache import Cache, Geometry, Memory

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / p for p in ("rtl/generated/memory_protocol_pkg.sv", "rtl/memory/l1_cache_array.sv",
                              "rtl/frontend/l1_icache.sv", "verif/frontend/l1_icache_tb.sv")]
SEEDS = (1, 2, 3)
SETS, WAYS, LINE, HIT_STAGES = 16, 2, 32, 1
BASE = 0x8000_0000 // LINE
ANY, HIT, MISS = 0, 1, 2
PROTOCOL, WRONG_ID, UNCACHED_DATA, FAULT_DATA = 2, 3, 4, 6  # malformed responses


def line(tag, index):
    return BASE + tag * SETS + index


class Stimulus:
    """Stimulus lines whose hits, misses and line traffic come from the model, applied in program order."""

    def __init__(self, exact=False):
        self.cache = Cache(Geometry(SETS * WAYS * LINE, WAYS, LINE), Memory(LINE), writable=False)
        self.exact, self.lines, self.faulty = exact, [], set()

    def emit(self, op, *fields):
        fields = (*fields, 0, 0, 0, 0, 0, 0)[:6]  # the bench reads exactly seven fields
        self.lines.append(" ".join(f"{v & 0xFFFFFFFF:x}" for v in (op, *fields)) + "\n")

    def text(self):
        return "".join(self.lines)

    def _access(self, n):
        """Model one demand or prefetch of line n; returns whether it hit, and queues the expected request."""
        if n in self.faulty:
            self.emit(4, n, 0, 1)
            return False
        result = self.cache.load(n * LINE, 4)
        if not result.hit:
            tag, index, _ = self.cache.g.split(n * LINE)
            self.emit(4, n, next(k for k, w in enumerate(self.cache.sets[index]) if w.valid and w.tag == tag), 0)
        return result.hit

    def lookup(self, n, wait=True, expect=None):
        if self.exact:
            expect = HIT if self._access(n) else MISS
        self.emit(0, n, int(wait), expect or ANY)

    def prefetch(self, n, wait=False, once=False):
        """wait: until the cache is idle again; once: offered for one cycle only (may be refused)."""
        if self.exact:
            self._access(n)
        self.emit(1, n, 2 if once else int(wait))

    def invalidate(self, modify=None, next_too=False):
        self.cache.invalidate()
        self.emit(2, int(modify is not None), modify or 0, int(next_too))

    def barrier(self):
        self.emit(3)

    def fault_line(self, n, arm=True):
        (self.faulty.add if arm else self.faulty.discard)(n)
        self.emit(5, n, int(arm))

    def malformed(self, kind):
        self.emit(6, kind)

    def idle(self, cycles):
        self.emit(7, cycles)

    def expect_fatal(self):
        self.emit(8)

    def timing(self, latency, ready_delay=0, no_gaps=True):
        self.emit(9, latency, ready_delay, int(no_gaps))

    def sync_response(self, offset, after):
        self.emit(0xA, offset, int(after))

    def unsolicited(self):
        self.emit(0xB)


class Trace:
    def __init__(self, stdout):
        self.stdout = stdout
        self.events = [(int(f[1]), f[2], [int(x, 16) for x in f[3:]])
                       for f in (text.split() for text in stdout.splitlines()) if f and f[0] == "T"]
        self.stats = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", re.search(r"PASS .*", stdout)[0])}

    def at(self, kind, *args):
        """Cycles of events of this kind whose leading arguments match."""
        return [c for c, k, a in self.events if k == kind and a[:len(args)] == list(args)]

    def one(self, kind, *args):
        cycles = self.at(kind, *args)
        assert len(cycles) == 1, f"{kind} {args}: {cycles}"
        return cycles[0]


class L1IcacheRtlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        # unique X init makes the unreset array random, so only installed tags and lines may matter.
        build = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "--x-initial", "unique",
                                "--top-module", "l1_icache_tb", "--Mdir", cls.tmp.name, *map(str, SOURCES)],
                               capture_output=True, text=True)
        assert build.returncode == 0, build.stdout + build.stderr
        cls.binary = f"{cls.tmp.name}/Vl1_icache_tb"

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def replay(self, name, stimulus, exact=False, trace=True):
        path = Path(self.tmp.name) / f"{name}.txt"
        path.write_text(stimulus.text())
        traces = []
        for seed in SEEDS:
            run = subprocess.run([self.binary, f"+stimulus={path}", "+verilator+rand+reset+2",
                                  f"+verilator+seed+{seed}",
                                  *(["+exact"] if exact else []), *(["+trace"] if trace else [])],
                                 capture_output=True, text=True, timeout=900)
            self.assertEqual(run.returncode, 0, f"{name} seed {seed}: {run.stdout[-3000:]}{run.stderr[-3000:]}")
            match = re.search(r"PASS lines=(\d+)", run.stdout)
            self.assertIsNotNone(match, f"{name} seed {seed}: {run.stdout[-3000:]}")
            # a truncated replay must not pass
            self.assertEqual(int(match[1]), len(stimulus.lines), name)
            traces.append(Trace(run.stdout))
        print(f"{name}: seeds={SEEDS} lines={len(stimulus.lines)} {traces[0].stats}")
        return traces

    # three hot sets with four tags each, so 2-way sets evict; two faulting lines; invalidates change memory
    def random_stream(self, stimulus, seed, count, concurrent):
        rng = random.Random(seed)
        hot = rng.sample(range(SETS), 3)

        def pick():
            return line(rng.randrange(4), rng.choice(hot) if rng.random() < 0.85 else rng.randrange(SETS))
        for n in rng.sample([line(t, i) for t in range(4) for i in hot], 2):
            stimulus.fault_line(n)
        for _ in range(count):
            r = rng.random()
            if r < 0.55:
                stimulus.lookup(pick(), wait=not concurrent or rng.random() < 0.4)
            elif r < 0.8:
                stimulus.prefetch(pick(), wait=not concurrent, once=concurrent and rng.random() < 0.7)
            elif r < 0.84:
                stimulus.invalidate(modify=pick() if rng.random() < 0.8 else None,
                                    next_too=concurrent and rng.random() < 0.5)
            else:
                stimulus.idle(rng.randrange(1, 6))
        stimulus.barrier()

    def test_serialized_random_vs_model(self):
        stimulus = Stimulus(exact=True)
        self.random_stream(stimulus, 71, 4000, concurrent=False)
        for t in self.replay("serialized", stimulus, exact=True, trace=False):
            self.assertGreater(t.stats["misses"], 600)
            self.assertGreater(t.stats["hits"], 600)
            self.assertGreater(t.stats["faults"], 30)
            self.assertGreater(t.stats["installs"], 800)
            self.assertGreater(t.stats["invalidates"], 100)

    def test_concurrent_random_vs_memory(self):
        stimulus = Stimulus()
        stimulus.timing(0, ready_delay=0xFF, no_gaps=False)
        self.random_stream(stimulus, 72, 20000, concurrent=True)
        for t in self.replay("concurrent", stimulus, trace=False):
            self.assertGreater(t.stats["fills"], 500)
            self.assertGreater(t.stats["faults"], 50)
            self.assertGreater(t.stats["retries"], 20)
            self.assertGreater(t.stats["prefetches"], 300)
            self.assertGreater(t.stats["dropped"], 20)
            self.assertGreater(t.stats["prefetch_hits"], 100)

    def test_hit_latency_is_hit_stages(self):
        s = Stimulus()
        s.timing(10)
        lines = [line(0, i) for i in range(4)]
        for n in lines:
            s.lookup(n)
        s.barrier()
        burst = lines * 3
        for n in burst:
            s.lookup(n, wait=False, expect=HIT)
        s.barrier()
        for t in self.replay("hit_latency_is_hit_stages", s):
            looks = [c for c, k, _ in t.events if k == "LOOK"][len(lines):]
            hits = t.at("HIT")
            self.assertEqual(looks, list(range(looks[0], looks[0] + len(burst))))
            self.assertEqual([h - c for h, c in zip(hits, looks)], [HIT_STAGES] * len(burst))

    def test_demand_waits_for_inflight_prefetch_same_line(self):
        s = Stimulus()
        s.timing(20)
        n = line(0, 5)
        s.prefetch(n)
        s.idle(5)
        s.lookup(n, expect=MISS)
        s.barrier()
        s.lookup(n, expect=HIT)
        s.barrier()
        for t in self.replay("demand_waits_for_inflight_prefetch_same_line", s):
            self.assertEqual(t.at("REQ"), [t.one("REQ", n)])
            miss, response = t.one("MISS", n), t.one("MRSP")
            self.assertLess(t.one("REQ", n), miss)
            self.assertLess(miss, response)
            self.assertEqual(t.one("FILL", n), response + 1)
            self.assertEqual(t.one("INSTALL", 5), response + 1)

    def test_invalidate_drops_late_fill(self):
        s = Stimulus()
        s.timing(20)
        demand, prefetched, other = line(0, 6), line(0, 7), line(0, 8)
        s.lookup(demand, wait=False)
        s.idle(5)
        s.invalidate(modify=demand)        # the demand's request is in flight: its old line is dropped
        s.barrier()                        # the demand is requested again and filled with the new line
        s.lookup(demand, expect=HIT)
        s.barrier()
        s.prefetch(prefetched)
        s.idle(5)
        s.invalidate(modify=prefetched)
        s.barrier()
        s.lookup(other)
        s.lookup(prefetched, expect=MISS)  # the dropped prefetch left nothing behind
        s.barrier()
        for t in self.replay("invalidate_drops_late_fill", s):
            first, second = t.at("INV")
            self.assertEqual(len(t.at("REQ", demand)), 2)
            self.assertLess(t.at("REQ", demand)[0], first)
            self.assertGreater(t.at("REQ", demand)[1], t.at("MRSP")[0])
            self.assertEqual(len(t.at("INSTALL", 6)), 1)
            self.assertEqual(t.one("FILL", demand), t.at("MRSP")[1] + 1)
            self.assertEqual(len(t.at("REQ", prefetched)), 2)
            self.assertLess(t.at("REQ", prefetched)[0], second)
            self.assertGreater(t.one("INSTALL", 7), t.one("MISS", prefetched))

    def test_fill_fault_installs_nothing(self):
        s = Stimulus()
        s.timing(8)
        resident, faulting = line(0, 3), line(1, 3)
        s.lookup(resident)
        s.barrier()
        s.fault_line(faulting)
        s.lookup(faulting, expect=MISS)
        s.barrier()
        s.lookup(resident, expect=HIT)
        s.lookup(faulting, expect=MISS)    # nothing was installed: it faults again
        s.barrier()
        s.fault_line(faulting, arm=False)
        s.lookup(faulting, expect=MISS)
        s.barrier()
        s.lookup(faulting, expect=HIT)
        s.lookup(resident, expect=HIT)
        s.barrier()
        for t in self.replay("fill_fault_installs_nothing", s):
            self.assertEqual(len(t.at("FAULT", faulting)), 2)
            self.assertEqual(len(t.at("REQ", faulting)), 3)
            self.assertEqual(len(t.at("INSTALL", 3)), 2)
            self.assertGreater(t.at("INSTALL", 3)[1], t.at("FAULT", faulting)[1])
            self.assertEqual(t.one("FILL", faulting), t.at("INSTALL", 3)[1])

    def test_invalidate_same_cycle_as_lookup(self):
        s = Stimulus()
        s.timing(5)
        n = line(0, 9)
        s.lookup(n)
        s.barrier()
        s.invalidate(modify=n, next_too=True)
        s.lookup(n, wait=False, expect=MISS)  # read in the invalidate cycle (T7-A1)
        s.barrier()
        s.lookup(n, expect=HIT)
        s.barrier()
        for t in self.replay("invalidate_same_cycle_as_lookup", s):
            self.assertEqual(t.at("LOOK", n)[1], t.one("INV"))
            self.assertEqual(t.at("MISS", n)[1], t.one("INV") + HIT_STAGES)
            self.assertEqual(len(t.at("REQ", n)), 2)

    def test_invalidate_then_fill_then_stale_lookup(self):
        s = Stimulus()
        s.timing(10)
        stale, other, new = line(0, 4), line(1, 4), line(2, 4)
        s.lookup(stale)                    # way 0
        s.lookup(other)                    # way 1
        s.barrier()
        s.invalidate(modify=stale)         # both ways invalid; stale's old tag and line stay in way 0
        s.lookup(new, wait=False)          # fills way 0, the first invalid way
        s.sync_response(1, after=True)     # the install cycle
        s.lookup(stale, wait=False)        # reads way 0's old tag at the install edge (T7-A1)
        s.barrier()
        s.lookup(stale, expect=MISS)
        s.barrier()
        for t in self.replay("invalidate_then_fill_then_stale_lookup", s):
            install = t.at("INSTALL", 4, 0)[-1]
            self.assertEqual(t.at("LOOK", stale)[1], install)
            self.assertFalse(t.at("HIT", stale))
            self.assertEqual(len(t.at("REQ", stale)), 2)

    def test_fill_arrives_in_invalidate_cycle(self):
        s = Stimulus()
        s.timing(10)
        n = line(0, 10)
        s.lookup(n, wait=False)
        s.sync_response(0, after=True)
        s.invalidate(modify=n)             # in the response cycle
        s.barrier()
        s.lookup(n, expect=HIT)
        s.barrier()
        for t in self.replay("fill_arrives_in_invalidate_cycle", s):
            first = t.at("MRSP")[0]
            self.assertEqual(t.one("INV"), first)
            self.assertFalse([c for c in t.at("INSTALL") if c == first + 1])
            self.assertEqual(len(t.at("REQ", n)), 2)
            self.assertEqual(t.one("FILL", n), t.at("MRSP")[1] + 1)

    def test_request_after_invalidate_installs(self):
        s = Stimulus()
        s.timing(10)
        a, b, c = line(0, 11), line(0, 12), line(0, 13)
        s.lookup(a, wait=False)
        s.idle(3)
        s.invalidate(modify=a, next_too=True)
        s.lookup(b, wait=False)            # misses in the invalidate cycle's shadow; requested after it
        s.barrier()
        s.lookup(b, expect=HIT)
        s.lookup(a, expect=MISS)           # its dropped fill left nothing, and b superseded its demand
        s.barrier()
        s.lookup(c, wait=False)
        s.invalidate()                     # c's miss is decided here and requested in the next cycle
        s.barrier()
        s.lookup(c, expect=HIT)
        s.barrier()
        for t in self.replay("request_after_invalidate_installs", s):
            first, second = t.at("INV")
            self.assertLess(t.at("REQ", a)[0], first)
            self.assertGreater(t.one("REQ", b), first)
            self.assertEqual(len(t.at("INSTALL", 12)), 1)
            self.assertEqual(len(t.at("REQ", a)), 2)
            self.assertEqual(t.one("MISS", c), second)
            self.assertEqual(t.one("REQ", c), second + 1)
            self.assertEqual(len(t.at("INSTALL", 13)), 1)

    def test_prefetch_resident_line_no_request(self):
        s = Stimulus()
        s.timing(5)
        n = line(0, 2)
        s.lookup(n)
        s.barrier()
        for _ in range(3):
            s.prefetch(n, wait=True)
        s.barrier()
        for t in self.replay("prefetch_resident_line_no_request", s):
            self.assertEqual(len(t.at("PFACC", n)), 3)
            self.assertEqual(len(t.at("REQ")), 1)
            self.assertEqual(t.stats["prefetch_hits"], 3)

    def test_prefetch_fault_silent(self):
        s = Stimulus()
        s.timing(6)
        n = line(0, 14)
        s.fault_line(n)
        s.prefetch(n, wait=True)
        s.lookup(n, expect=MISS)           # the demand is requested again and faults precisely
        s.barrier()
        for t in self.replay("prefetch_fault_silent", s):
            requests = t.at("REQ", n)
            self.assertEqual(len(requests), 2)
            self.assertEqual(t.one("FAULT", n), t.at("MRSP")[1] + 1)
            self.assertFalse(t.at("INSTALL"))

    def test_demand_other_line_while_prefetch_inflight(self):
        s = Stimulus()
        s.timing(20)
        prefetched, demand, refused = line(0, 1), line(0, 15), line(0, 0)
        s.prefetch(prefetched)
        s.idle(4)
        s.prefetch(refused, once=True)     # a request is in flight
        s.lookup(demand, expect=MISS)
        s.barrier()
        s.lookup(prefetched, expect=HIT)
        s.barrier()
        for t in self.replay("demand_other_line_while_prefetch_inflight", s):
            self.assertEqual([a[0] for _, k, a in t.events if k == "REQ"], [prefetched, demand])
            self.assertEqual(t.at("PFACC"), [t.one("PFACC", prefetched)])
            first, second = t.at("MRSP")
            self.assertLess(t.one("MISS", demand), first)
            self.assertEqual(t.one("REQ", demand), first + 3)  # after DELIVER, then IDLE
            self.assertEqual(t.one("FILL", demand), second + 1)
            self.assertFalse(t.at("FILL", prefetched))

    def test_lookup_same_set_install_cycle(self):
        s = Stimulus()
        s.timing(10)
        filling, resident, other = line(1, 8), line(0, 9), line(1, 9)
        s.lookup(resident)
        s.barrier()
        s.lookup(filling, wait=False)
        s.sync_response(0, after=True)     # the response cycle
        s.lookup(filling, wait=False)      # decided in the install cycle: retry (T7-A2)
        s.lookup(filling, wait=False)      # read at the install edge: retry
        s.lookup(filling, wait=False, expect=HIT)
        s.barrier()
        s.lookup(other, wait=False)
        s.sync_response(0, after=True)
        s.lookup(resident, wait=False, expect=HIT)  # same set, decided in the install cycle: a hit stands
        s.lookup(resident, wait=False, expect=HIT)  # read at the install edge
        s.lookup(other, wait=False, expect=HIT)
        s.barrier()
        for t in self.replay("lookup_same_set_install_cycle", s):
            install = t.one("INSTALL", 8)
            self.assertEqual(t.at("LOOK", filling)[1:], [install - 1, install, install + 1])
            self.assertEqual(t.at("RETRY", filling), [install, install + 1])
            self.assertEqual(t.at("HIT", filling), [install + 2])
            self.assertEqual(len(t.at("REQ", filling)), 1)
            install = t.at("INSTALL", 9)[-1]
            self.assertEqual(t.at("HIT", resident), [install, install + 1])
            self.assertEqual(t.at("HIT", other), [install + 2])
            self.assertFalse(t.at("RETRY", resident) + t.at("RETRY", other))
            self.assertEqual(len(t.at("REQ")), 3)

    def test_protocol_fault_is_fatal(self):
        """Every malformed-response branch is fatal. The quiet window then requires busy_o high and every
        handshake output low while a lookup and a prefetch are presented."""
        resident, missing = line(0, 3), line(0, 6)
        cases = {}
        for name, kind in (("status", PROTOCOL), ("wrong_id", WRONG_ID), ("uncached_data", UNCACHED_DATA),
                           ("fault_data", FAULT_DATA)):
            s = Stimulus()
            s.timing(5)
            s.lookup(resident)
            s.barrier()
            s.malformed(kind)
            s.lookup(missing, wait=False)
            s.sync_response(0, after=True)
            s.lookup(resident, wait=False)  # answered in the cycle after the fault: gated
            cases[name] = s
        s = Stimulus()
        s.timing(5)
        s.lookup(resident)
        s.barrier()
        s.unsolicited()
        cases["unsolicited_idle"] = s
        s = Stimulus()
        s.timing(5, ready_delay=40)
        s.lookup(missing, wait=False)
        s.idle(3)
        s.unsolicited()                     # the request is still waiting for ready
        cases["unsolicited_request_pending"] = s
        s = Stimulus()
        s.timing(10)
        s.lookup(missing, wait=False)
        s.sync_response(0, after=True)
        s.idle(1)
        s.unsolicited()                     # the install cycle
        cases["unsolicited_install"] = s
        for name, faulting in (("unsolicited_request_accepted", False), ("unsolicited_request_accepted_fault", True)):
            s = Stimulus()
            s.timing(5)
            if faulting:
                s.fault_line(missing)
            s.lookup(missing, wait=False)
            s.idle(1)
            s.unsolicited()                 # in the request's handshake cycle: its real response still arrives
            cases[name] = s
        for name, s in cases.items():
            s.expect_fatal()
            for t in self.replay(f"protocol_fault_is_fatal_{name}", s):
                self.assertEqual(t.stdout.count("IC_PROTOCOL"), 1, name)
                fault = t.one("UNSOL") if name.startswith("unsolicited") else t.at("MRSP")[-1]
                self.assertEqual(t.one("FATAL"), fault + 1, name)
                self.assertFalse([c for c in t.at("INSTALL") if c > fault], name)
                self.assertFalse([c for c in t.at("REQ") if c > fault], name)
                self.assertFalse([c for c in t.at("HIT") + t.at("FILL") + t.at("FAULT") if c > fault], name)
                if name == "unsolicited_request_pending":
                    self.assertFalse(t.at("REQ"), name)
                if name.startswith("unsolicited_request_accepted"):
                    self.assertEqual(t.one("REQ", missing), fault, name)


if __name__ == "__main__":
    unittest.main()
