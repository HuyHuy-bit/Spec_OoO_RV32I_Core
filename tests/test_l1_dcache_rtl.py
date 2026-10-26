"""l1_dcache against model/cache.py, a byte shadow and directed timing checks (verif/memory/l1_dcache_tb.sv)."""
from pathlib import Path
import random
import re
import subprocess
import tempfile
import unittest

from model.cache import Cache, Geometry, Memory

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / p for p in ("rtl/generated/memory_protocol_pkg.sv", "rtl/memory/l1_cache_array.sv",
                              "rtl/memory/l1_dcache.sv", "verif/memory/l1_dcache_tb.sv")]
SEEDS = (1, 2, 3)
SETS, WAYS, LINE, HIT_STAGES = 16, 2, 32, 1
BASE = 0x8000_0000
FILL, WRITEBACK, PROTOCOL = 0, 1, 2
WRONG_ID, UNCACHED_DATA, WRITEBACK_DATA, FAULT_DATA = 3, 4, 5, 6  # malformed responses


def initial_word(address):
    """Matches initial_line() in the bench."""
    return (address * 0x9E3779B1 & 0xFFFFFFFF) ^ 0x5BD1E995


class InitializedMemory(Memory):
    def line(self, base):
        if base not in self.lines:
            self.lines[base] = bytearray(b"".join(initial_word(base + 4 * w).to_bytes(4, "little") for w in range(8)))
        return self.lines[base]


def address(tag, index, offset=0):
    return BASE + (tag * SETS + index) * LINE + offset


class Stimulus:
    """Stimulus lines whose load values and line traffic come from the model, applied in program order."""

    def __init__(self, exact=False):
        self.memory = InitializedMemory(LINE)
        self.cache = Cache(Geometry(SETS * WAYS * LINE, WAYS, LINE), self.memory)
        self.exact, self.lines, self.ids = exact, [], 0

    def emit(self, op, *fields):
        fields = (*fields, 0, 0, 0, 0, 0, 0)[:6]  # the bench reads exactly seven fields
        self.lines.append(" ".join(f"{v & 0xFFFFFFFF:x}" for v in (op, *fields)) + "\n")

    def text(self):
        return "".join(self.lines)

    def _expect(self, mark):
        if not self.exact:
            return
        for entry in self.memory.log[mark:]:
            if entry[0] == "writeback":
                self.emit(5, WRITEBACK, entry[1], 0)
            else:
                tag, index, _ = self.cache.g.split(entry[1])
                way = next(n for n, w in enumerate(self.cache.sets[index]) if w.valid and w.tag == tag)
                self.emit(5, FILL, entry[1], way)

    def load(self, addr, size=4, unsigned=False, expected=None):
        """Returns the load id; expected overrides the model (a load that must see older bytes)."""
        load_id, self.ids = self.ids % 8192, self.ids + 1
        timed = False
        if expected is None:
            mark = len(self.memory.log)
            result = self.cache.load(addr, size)
            self._expect(mark)
            expected, timed = result.value, self.exact and result.hit
        if not unsigned and size < 4 and expected >> (8 * size - 1):
            expected -= 1 << 8 * size
        self.emit(0, load_id, addr, size.bit_length() - 1, int(unsigned), expected, int(timed))
        if self.exact:
            self.barrier()
        return load_id

    def write(self, addr, size, value):
        mark = len(self.memory.log)
        result = self.cache.store(addr, size, value)
        self._expect(mark)
        lane = addr & 3
        self.emit(1, addr & ~3, value << 8 * lane, ((1 << size) - 1) << lane, int(self.exact and result.hit))
        if self.exact:
            self.barrier()

    def clean(self):
        mark = len(self.memory.log)
        self.cache.flush()
        self._expect(mark)
        self.emit(2)
        if self.exact:
            self.barrier()

    def kill(self, keep_issuing=False):
        self.emit(3, int(keep_issuing))

    def barrier(self):
        self.emit(4)

    def fault(self, kind):
        self.emit(6, kind)

    def idle(self, cycles):
        self.emit(7, cycles)

    def sync_done(self):
        self.emit(8)

    def expect_fatal(self):
        self.emit(9)

    def timing(self, latency, ready_delay=0, no_gaps=True):
        self.emit(0xA, latency, ready_delay, int(no_gaps))

    def sync_response(self, offset, after):
        self.emit(0xB, offset, int(after))

    def unsolicited(self):
        self.emit(0xC)

    def value(self, addr, size=4):
        return self.cache.load(addr, size).value


class Trace:
    def __init__(self, stdout):
        self.stdout = stdout
        self.events = [(int(f[1]), f[2], [int(x, 16) for x in f[3:]])
                       for f in (line.split() for line in stdout.splitlines()) if f and f[0] == "T"]
        self.stats = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", re.search(r"PASS .*", stdout)[0])}

    def at(self, kind, *args):
        """Cycles of events of this kind whose leading arguments match."""
        return [c for c, k, a in self.events if k == kind and a[:len(args)] == list(args)]

    def one(self, kind, *args):
        cycles = self.at(kind, *args)
        assert len(cycles) == 1, f"{kind} {args}: {cycles}"
        return cycles[0]


class L1DcacheRtlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        # unique X init makes the unreset array random, so only installed tags and bytes may matter.
        build = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "--x-initial", "unique",
                                "--top-module", "l1_dcache_tb", "--Mdir", cls.tmp.name, *map(str, SOURCES)],
                               capture_output=True, text=True)
        assert build.returncode == 0, build.stdout + build.stderr
        cls.binary = f"{cls.tmp.name}/Vl1_dcache_tb"

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

    # random streams over three hot sets with four tags each, so 2-way sets conflict and evict dirty lines
    def random_stream(self, stimulus, seed, count, concurrent):
        rng = random.Random(seed)
        hot = rng.sample(range(SETS), 3)
        for _ in range(count):
            size = rng.choice((1, 2, 4))
            addr = address(rng.randrange(4), rng.choice(hot) if rng.random() < 0.85 else rng.randrange(SETS),
                           rng.randrange(0, LINE, size))
            r = rng.random()
            if r < 0.55:
                stimulus.load(addr, size, unsigned=size < 4 and rng.random() < 0.5)
            elif r < 0.9:
                stimulus.write(addr, size, rng.randrange(1 << 8 * size))
            elif r < 0.915:
                stimulus.clean()
            elif concurrent and r < 0.95:
                stimulus.kill(keep_issuing=rng.random() < 0.5)
            else:
                stimulus.idle(rng.randrange(1, 6))
        stimulus.barrier()

    def test_serialized_random_vs_model(self):
        stimulus = Stimulus(exact=True)
        self.random_stream(stimulus, 41, 4000, concurrent=False)
        for t in self.replay("serialized", stimulus, exact=True, trace=False):
            self.assertGreater(t.stats["writebacks"], 300)
            self.assertGreater(t.stats["fills"], 1000)
            self.assertGreater(t.stats["cleans"], 30)

    def test_concurrent_random_vs_shadow(self):
        stimulus = Stimulus()
        self.random_stream(stimulus, 42, 20000, concurrent=True)
        for t in self.replay("concurrent", stimulus, trace=False):
            self.assertGreater(t.stats["writebacks"], 1000)
            self.assertGreater(t.stats["kills"], 300)
            self.assertGreater(t.stats["parks"], 1000)

    def test_hit_latency_is_hit_stages(self):
        s = Stimulus()
        s.timing(10)
        line = address(0, 5)
        s.load(line)
        s.barrier()
        burst = [s.load(line + offset, size, unsigned) for offset, size, unsigned in
                 [(0, 4, False), (4, 4, False), (9, 1, True), (11, 1, False), (14, 2, False), (18, 2, True),
                  (24, 4, False), (28, 4, False)]]
        s.barrier()
        for t in self.replay("hit_latency_is_hit_stages", s):
            accepted = [t.one("ACC", i) for i in burst]
            self.assertEqual([t.one("RSP", i) - c for i, c in zip(burst, accepted)], [HIT_STAGES] * len(burst))
            self.assertEqual(accepted, list(range(accepted[0], accepted[0] + len(burst))))

    def test_hit_under_miss(self):
        s = Stimulus()
        s.timing(30)
        resident = address(0, 5)
        s.load(resident)
        s.barrier()
        miss = s.load(address(0, 9))
        hits = [s.load(resident + 4 * k) for k in range(3)]
        s.barrier()
        for t in self.replay("hit_under_miss", s):
            for i in hits:
                self.assertEqual(t.one("RSP", i) - t.one("ACC", i), HIT_STAGES)
                self.assertLess(t.one("RSP", i), t.at("MRSP", FILL)[-1])
            self.assertGreater(t.one("RSP", miss), t.at("MRSP", FILL)[-1])

    def test_secondary_miss_same_line(self):
        s = Stimulus()
        s.timing(20)
        line, other = address(0, 9), address(0, 10)
        first = s.load(line)
        s.write(line + 16, 4, 0x1234_5678)    # parks behind the miss to its own line
        loads = [s.load(line + 8), s.load(line + 20, 2)]
        s.load(other)
        loads.append(s.load(other + 4))       # a load parked behind the miss to its own line
        s.barrier()
        loads.append(s.load(line + 16))
        s.barrier()
        for t in self.replay("secondary_miss_same_line", s):
            self.assertEqual(len(t.at("REQ", FILL, line)), 1)
            self.assertEqual(len(t.at("REQ", FILL, other)), 1)
            self.assertEqual(len(t.at("REQ", FILL)), 2)
            self.assertEqual(len(t.at("WDONE")), 1)
            for i in [first, *loads]:
                t.one("RSP", i)

    def dirty_lru(self, s, index, tags):
        """Leaves tags[0] dirty and least recently used in set index, tags[1] resident; returns their lines."""
        dirty, resident = address(tags[0], index), address(tags[1], index)
        s.load(dirty)
        s.load(resident)
        s.write(dirty + 4, 4, 0xD00D_0000 + index)
        s.load(resident + 8)
        s.barrier()
        return dirty, resident

    def test_dirty_victim_writeback_then_fill(self):
        s = Stimulus()
        s.timing(12)
        dirty, _ = self.dirty_lru(s, 3, (0, 1))
        new = address(2, 3)
        s.load(new + 12)
        s.barrier()
        s.load(dirty + 4)
        s.barrier()
        for t in self.replay("dirty_victim_writeback_then_fill", s):
            request = t.one("REQ", WRITEBACK, dirty)
            self.assertEqual([c for c in t.at("REQ") if c >= request][:2], [request, t.one("REQ", FILL, new)])
            self.assertGreater(t.one("REQ", FILL, new), t.one("MRSP", WRITEBACK))
            self.assertEqual(len(t.at("REQ", FILL, dirty)), 2)

    def test_write_hit_lands_after_lookup(self):
        s = Stimulus()
        s.timing(5)
        line = address(0, 4)
        s.load(line)
        s.barrier()
        old = s.value(line + 8)
        s.write(line + 8, 4, 0xCAFE_F00D)
        s.sync_done()
        before = s.load(line + 8, expected=old)
        after = s.load(line + 8)
        s.barrier()
        for t in self.replay("write_hit_lands_after_lookup", s):
            done = t.one("WDONE")
            self.assertEqual(done - t.one("WPRES"), HIT_STAGES + 1)
            self.assertEqual(t.one("LAND", 4), done)
            self.assertEqual((t.one("ACC", before), t.one("ACC", after)), (done, done + 1))

    def test_write_miss_allocates_then_lands(self):
        s = Stimulus()
        s.timing(25)
        dirty, _ = self.dirty_lru(s, 6, (0, 1))
        others = [address(0, 1), address(0, 2)]
        for line in others:
            s.load(line)
        s.barrier()
        target = address(2, 6)
        s.write(target + 4, 4, 0xA110_CA7E)
        hits = [s.load(others[k % 2] + 4 * k) for k in range(6)]
        s.barrier()
        s.load(target + 4)
        s.load(dirty + 4)
        s.barrier()
        for t in self.replay("write_miss_allocates_then_lands", s):
            present, done = t.at("WPRES")[-1], t.at("WDONE")[-1]
            window = [(c, a) for c, k, a in t.events if k == "REQ" and present <= c <= done]
            self.assertEqual([a for _, a in window], [[WRITEBACK, dirty], [FILL, target]])
            self.assertEqual(len([c for c in t.at("INSTALL", 6) if present <= c <= done]), 1)
            for i in hits:
                self.assertEqual(t.one("RSP", i) - t.one("ACC", i), HIT_STAGES)
                self.assertLess(t.one("RSP", i), done)

    def test_write_enters_before_load(self):
        s = Stimulus()
        s.timing(5)
        a, b = address(0, 1), address(0, 2)
        s.load(a)
        s.load(b)
        s.barrier()
        s.write(a, 4, 0x5555_AAAA)
        load = s.load(b + 4)
        s.barrier()
        for t in self.replay("write_enters_before_load", s):
            present = t.one("WPRES")
            self.assertEqual(t.one("LWAIT", load), present)
            self.assertEqual(t.one("ACC", load), present + 1)
            self.assertEqual(t.one("WDONE"), present + HIT_STAGES + 1)

    def test_install_waits_for_landing_write(self):
        s = Stimulus()
        s.timing(10)
        resident, miss = address(0, 5), address(0, 2)
        s.load(resident)
        s.barrier()
        s.load(miss + 4)
        s.sync_response(1, after=False)
        s.write(resident + 4, 4, 0x0BAD_CAFE)  # decides in the response cycle, lands in the would-be install cycle
        s.barrier()
        s.load(resident + 4)
        s.load(miss + 4)
        s.barrier()
        for t in self.replay("install_waits_for_landing_write", s):
            response = t.at("MRSP", FILL)[1]
            self.assertEqual(t.one("LAND", 5), response + 1)
            self.assertEqual(t.one("WDONE"), response + 1)
            self.assertEqual(t.one("INSTALL", 2), response + 2)

    def test_clean_writes_all_dirty_keeps_valid(self):
        s = Stimulus()
        s.timing(8)
        lines = [address(t, i) for i in (0, 7, 15) for t in (0, 1)]
        for line in lines:
            s.load(line)
        for line in lines[::2] + lines[3:4]:
            s.write(line + 8, 4, line ^ 0xFFFF)
        s.barrier()
        mark = len(s.memory.log)
        s.clean()
        expected = [entry[1] for entry in s.memory.log[mark:]]
        s.barrier()
        hits = [s.load(line + 8) for line in lines]
        s.barrier()
        for t in self.replay("clean_writes_all_dirty_keeps_valid", s):
            start, done = t.one("CLEAN"), t.one("CDONE")
            self.assertEqual([a[1] for c, k, a in t.events if k == "REQ" and start <= c <= done], expected)
            self.assertEqual(len(expected), 4)
            self.assertFalse([c for c in t.at("REQ", FILL) if c > start])
            for i in hits:
                self.assertEqual(t.one("RSP", i) - t.one("ACC", i), HIT_STAGES)

    def test_refill_fault_is_fatal(self):
        cases = {}
        load = Stimulus()
        load.timing(5)
        load.fault(FILL)
        cases["load_refill"] = (load, load.load(address(0, 3)), "DC_REFILL_FAULT")
        write = Stimulus()
        write.timing(5)
        write.fault(FILL)
        write.write(address(0, 3), 4, 0x1111_2222)
        cases["write_refill"] = (write, None, "DC_REFILL_FAULT")
        writeback = Stimulus()
        writeback.timing(5)
        dirty, _ = self.dirty_lru(writeback, 3, (0, 1))
        writeback.fault(WRITEBACK)
        cases["writeback"] = (writeback, writeback.load(address(2, 3)), "DC_WRITEBACK_FAULT")
        protocol = Stimulus()
        protocol.timing(5)
        protocol.fault(PROTOCOL)
        cases["protocol"] = (protocol, protocol.load(address(0, 3)), "DC_PROTOCOL")
        for name, (s, load_id, message) in cases.items():
            s.expect_fatal()
            for t in self.replay(f"refill_fault_is_fatal_{name}", s):
                self.assertEqual(t.stdout.count("DC_"), 1, name)
                self.assertIn(message, t.stdout, name)
                fault = t.at("MRSP")[-1]
                self.assertEqual(t.one("FATAL"), fault + 1)
                self.assertFalse([c for c in t.at("INSTALL") if c >= fault], name)
                self.assertFalse([c for c in t.at("REQ") if c > fault], name)
                self.assertFalse([c for c in t.at("WDONE") + t.at("RSP") if c >= fault], name)
                if load_id is not None:
                    self.assertFalse(t.at("RSP", load_id), name)
                if name == "write_refill":
                    self.assertFalse(t.at("WDONE"), name)
                if name == "writeback":
                    self.assertEqual(t.at("REQ", WRITEBACK, dirty), [fault - 5])

    def test_protocol_fault_is_fatal(self):
        """Every malformed-response branch is fatal. The bench's quiet window then requires busy_o high and every
        handshake output low, while a load and a clean are presented. Each case leaves different work in flight at
        the fault: an access, an install, a pending request or an idle clean walk."""
        resident, miss = address(0, 3), address(0, 6)
        cases = {}
        for name, kind in (("wrong_id", WRONG_ID), ("uncached_data", UNCACHED_DATA), ("fault_data", FAULT_DATA)):
            s = Stimulus()
            s.timing(5)
            s.load(resident)
            s.barrier()
            s.fault(kind)
            s.load(miss)
            s.sync_response(0, after=False)
            if name == "uncached_data":
                s.write(resident + 8, 4, 0x5EED_0001)  # enters in the fault cycle and hits
                cases[name] = (s, None)
            else:
                cases[name] = (s, s.load(resident + 4))  # accepted in the fault cycle and hits
        s = Stimulus()
        s.timing(5)
        self.dirty_lru(s, 6, (0, 1))
        s.fault(WRITEBACK_DATA)
        s.load(address(2, 6))
        cases["writeback_data"] = (s, None)
        s = Stimulus()
        s.timing(5)
        s.load(resident)
        s.load(miss)
        s.barrier()
        s.unsolicited()  # idle: the quiet window's clean walks a clean cache to completion
        cases["unsolicited_idle"] = (s, None)
        s = Stimulus()
        s.timing(5, ready_delay=40)
        s.load(miss)
        s.idle(3)
        s.unsolicited()  # the refill request is still waiting for ready
        cases["unsolicited_request_pending"] = (s, None)
        s = Stimulus()
        s.timing(10)
        s.load(resident)
        s.barrier()
        s.load(miss + 4)
        s.sync_response(1, after=False)
        s.write(resident + 4, 4, 0x0BAD_CAFE)  # lands in the would-be install cycle
        s.sync_response(1, after=True)
        s.unsolicited()  # in INSTALL, which waits behind the landing
        cases["unsolicited_install"] = (s, None)
        for name, (s, load_id) in cases.items():
            s.expect_fatal()
            for t in self.replay(f"protocol_fault_is_fatal_{name}", s):
                self.assertEqual(t.stdout.count("DC_"), 1, name)
                self.assertIn("DC_PROTOCOL", t.stdout, name)
                fault = t.one("UNSOL") if name.startswith("unsolicited") else t.at("MRSP")[-1]
                self.assertEqual(t.one("FATAL"), fault + 1, name)
                self.assertFalse([c for c in t.at("INSTALL") if c >= fault], name)
                self.assertFalse([c for c in t.at("REQ") if c > fault], name)
                self.assertFalse([c for c in t.at("RSP") if c >= fault], name)
                self.assertFalse([c for c in t.at("WDONE") if c > fault], name)
                if load_id is not None:
                    self.assertEqual(t.one("ACC", load_id), fault, name)
                if name == "uncached_data":
                    self.assertEqual(t.one("WPRES"), fault, name)
                if name == "unsolicited_request_pending":
                    self.assertFalse(t.at("REQ"), name)
                if name == "unsolicited_install":
                    self.assertEqual(t.one("WDONE"), fault, name)

    def test_kill_drops_responses_keeps_fill(self):
        s = Stimulus()
        s.timing(15)
        line = address(0, 8)
        killed = s.load(line)
        s.idle(4)
        s.kill()
        s.barrier()
        later = s.load(line + 4)
        s.barrier()
        for t in self.replay("kill_drops_responses_keeps_fill", s):
            self.assertFalse(t.at("RSP", killed))
            self.assertEqual(len(t.at("REQ", FILL, line)), 1)
            self.assertGreater(t.one("INSTALL", 8), t.one("KILL"))
            self.assertEqual(t.one("RSP", later) - t.one("ACC", later), HIT_STAGES)

    def test_kill_never_drops_write(self):
        s = Stimulus()
        s.timing(3, ready_delay=1)
        offsets = range(17)  # entry, decision, writeback request/wait, fill request/wait, install, re-read, landing
        for n in offsets:
            index = n % SETS
            self.dirty_lru(s, index, (3 * n + 4, 3 * n + 5))
            s.write(address(3 * n + 6, index, 4), 4, 0x7000_0000 + n)
            s.idle(n)
            s.kill()
            s.barrier()
            s.load(address(3 * n + 6, index, 4))
        # a write parked in the slot behind a load miss, killed with the load
        s.barrier()
        s.load(address(90, 0))
        s.write(address(91, 1, 8), 4, 0x7777_0000)
        s.idle(2)
        s.kill()
        s.barrier()
        s.load(address(91, 1, 8))
        s.barrier()
        for t in self.replay("kill_never_drops_write", s):
            self.assertEqual(len(t.at("WDONE")), len(t.at("WPRES")))
            self.assertEqual(len(t.at("KILL")), len(offsets) + 1)

    def test_back_to_back_park_while_busy(self):
        s = Stimulus()
        s.timing(20)
        lines = [address(0, 1), address(0, 2), address(0, 3)]
        ids = [s.load(line) for line in lines]
        s.barrier()
        for t in self.replay("back_to_back_park_while_busy", s):
            self.assertEqual([a[1] for _, k, a in t.events if k == "REQ"], lines)
            self.assertTrue(t.at("LWAIT", ids[2]))
            self.assertGreater(t.one("ACC", ids[2]), t.one("INSTALL", 1))
            self.assertEqual(sorted(t.one("RSP", i) for i in ids), [t.one("RSP", i) for i in ids])

    def test_load_in_install_cycle_same_set(self):
        s = Stimulus()
        s.timing(10)
        line = address(0, 8)
        s.load(line)
        s.sync_response(1, after=True)
        same = s.load(line + 4)        # reads at the install edge
        s.barrier()
        for t in self.replay("load_in_install_cycle_same_set", s):
            install = t.one("INSTALL", 8)
            self.assertEqual(t.one("ACC", same), install)
            self.assertGreater(t.one("RSP", same), install + HIT_STAGES)
            self.assertEqual(len(t.at("REQ", FILL, line)), 1)

    def test_stale_tag_in_invalid_way_not_hit(self):
        s = Stimulus()
        s.timing(10)
        stale, resident, new = address(0, 3), address(1, 3), address(2, 3)
        s.load(stale)
        s.load(resident)
        s.barrier()
        s.load(new)                      # evicts stale; its tag stays in the way until the install
        s.sync_response(1, after=True)
        s.write(stale + 4, 4, 0x5747_E000)  # reads the old tag at the install edge
        s.barrier()
        checks = [s.load(new + 4), s.load(stale + 4), s.load(resident)]
        s.barrier()
        for t in self.replay("stale_tag_in_invalid_way_not_hit", s):
            self.assertEqual(t.one("WPRES"), t.at("INSTALL", 3)[2])
            self.assertEqual(len(t.at("REQ", FILL, stale)), 2)
            for i in checks:
                t.one("RSP", i)

    def test_evict_after_last_write(self):
        s = Stimulus()
        s.timing(10)
        written, other, new = address(0, 3), address(1, 3), address(2, 3)
        s.load(written)
        s.load(other)
        s.barrier()
        s.write(written + 4, 4, 0xEEEE_1111)  # lands one cycle before the eviction decision
        s.load(other + 8)                       # makes the written line least recently used
        evicting = s.load(new)                  # reads at the landing edge, misses, picks the written line
        s.barrier()
        s.load(written + 4)
        s.barrier()
        for t in self.replay("evict_after_last_write", s):
            done = t.one("WDONE")
            self.assertEqual(done, t.one("WPRES") + HIT_STAGES + 1)
            self.assertEqual(t.one("ACC", evicting), done)
            self.assertGreater(t.one("REQ", WRITEBACK, written), done)

    def test_load_hits_victim_during_miss(self):
        s = Stimulus()
        s.timing(10)
        victim, resident, new = address(0, 3), address(1, 3), address(2, 3)
        s.load(victim)
        s.load(resident)
        s.barrier()
        s.load(new)
        s.write(victim + 4, 4, 0x71C7_1111)   # reads at the edge that captures the victim
        s.barrier()
        s.load(victim + 4)
        s.barrier()
        victim2, resident2, new2 = address(0, 9), address(1, 9), address(2, 9)
        s.load(victim2)
        s.load(resident2)
        s.barrier()
        s.load(new2)
        s.idle(3)
        late = s.load(victim2 + 8)            # well after the capture
        s.barrier()
        for t in self.replay("load_hits_victim_during_miss", s):
            install = t.at("INSTALL", 3)[1]
            self.assertGreater(t.one("WDONE"), install)
            self.assertEqual(len(t.at("REQ", FILL, victim)), 2)
            self.assertGreater(t.one("RSP", late), t.at("INSTALL", 9)[1])
            self.assertEqual(len(t.at("REQ", FILL, victim2)), 2)

    def test_kill_in_every_miss_state(self):
        s = Stimulus()
        s.timing(3, ready_delay=1)
        offsets = range(14)  # decision, writeback request/wait, fill request/wait, install, re-read, response
        killed = []
        for n in offsets:
            index = n % SETS
            dirty, _ = self.dirty_lru(s, index, (3 * n + 4, 3 * n + 5))
            line = address(3 * n + 6, index)
            killed.append((s.load(line), line, dirty))
            s.idle(n)
            s.kill()
            s.barrier()
            s.load(line + 4)
            s.barrier()
        for t in self.replay("kill_in_every_miss_state", s):
            for i, line, dirty in killed:
                self.assertFalse(t.at("RSP", i))
                self.assertEqual(len(t.at("REQ", FILL, line)), 1)
                self.assertEqual(len(t.at("REQ", WRITEBACK, dirty)), 1)

    def test_kill_same_cycle_as_accept(self):
        s = Stimulus()
        s.timing(10)
        resident, miss = address(0, 4), address(0, 12)
        s.load(resident)
        s.barrier()
        s.kill(keep_issuing=True)
        hit = s.load(resident + 4)
        s.barrier()
        s.kill(keep_issuing=True)
        missed = s.load(miss)
        s.barrier()
        later = [s.load(resident + 8), s.load(miss + 4)]
        s.barrier()
        for t in self.replay("kill_same_cycle_as_accept", s):
            self.assertEqual([t.one("ACC", hit), t.one("ACC", missed)], t.at("KILL"))
            self.assertFalse(t.at("RSP", hit) + t.at("RSP", missed))
            for i in later:
                t.one("RSP", i)

    def test_clean_while_busy(self):
        s = Stimulus()
        s.timing(20)
        dirty = [address(0, 1), address(0, 2)]
        for line in dirty:
            s.write(line, 4, line)
        s.barrier()
        busy = [s.load(address(0, 5)), s.load(address(0, 6))]
        s.clean()
        after = s.load(address(0, 5) + 4)
        s.barrier()
        for t in self.replay("clean_while_busy", s):
            start, done = t.one("CLEAN"), t.one("CDONE")
            self.assertLess(start, min(t.one("RSP", i) for i in busy))
            cleaned = [c for c in t.at("REQ", WRITEBACK) if c > start]
            self.assertEqual(len(cleaned), 2)
            self.assertGreater(min(cleaned), max(t.one("RSP", i) for i in busy))
            self.assertGreaterEqual(t.one("ACC", after), done)

    def test_clean_done_after_last_response(self):
        s = Stimulus()
        s.timing(50)
        for index in (0, 15):
            s.write(address(0, index), 4, index)
        s.barrier()
        s.clean()
        s.barrier()
        for t in self.replay("clean_done_after_last_response", s):
            self.assertEqual(len(t.at("MRSP", WRITEBACK)), 2)
            self.assertGreater(t.one("CDONE"), t.at("MRSP", WRITEBACK)[-1])
            self.assertGreaterEqual(t.one("CDONE") - t.at("REQ", WRITEBACK)[-1], 50)

    def test_clean_twice_writes_nothing(self):
        s = Stimulus()
        s.timing(8)
        for index in (2, 3, 9):
            s.write(address(1, index, 4), 2, index)
        s.barrier()
        s.clean()
        s.barrier()
        s.clean()
        s.barrier()
        for t in self.replay("clean_twice_writes_nothing", s):
            first, second = t.at("CLEAN")
            self.assertEqual(len([c for c in t.at("REQ", WRITEBACK) if first < c < second]), 3)
            self.assertFalse([c for c in t.at("REQ") if c > second])
            self.assertEqual(len(t.at("CDONE")), 2)

    def test_miss_same_set_during_writeback(self):
        s = Stimulus()
        s.timing(20)
        dirty, _ = self.dirty_lru(s, 3, (0, 1))
        new, other = address(2, 3), address(3, 3)
        s.load(new)
        s.idle(3)
        waiting = s.load(other + 4)            # same set, while the dirty victim is written back
        s.barrier()
        dirty2, _ = self.dirty_lru(s, 11, (0, 1))
        s.load(address(2, 11))
        s.idle(3)
        refetched = s.load(dirty2 + 4)         # the line being written back
        s.barrier()
        for t in self.replay("miss_same_set_during_writeback", s):
            self.assertGreater(t.one("REQ", FILL, other), t.at("INSTALL", 3)[-2])
            self.assertGreater(t.one("RSP", waiting), t.one("REQ", FILL, other))
            self.assertGreater(t.at("REQ", FILL, dirty2)[-1], t.one("REQ", WRITEBACK, dirty2))
            t.one("RSP", refetched)


if __name__ == "__main__":
    unittest.main()
