"""tage_predictor RTL against the tage512 model, per branch (verif/frontend/tage_predictor_tb.sv)."""
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile
import unittest

from tools.run_predictor_comparison import collect, load_coremark
from verif.frontend.predictor_model import SmallTage

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "rtl/frontend/tage_predictor.sv", ROOT / "verif/frontend/tage_predictor_tb.sv"]
COREMARK = ROOT / "out/coremark"
SEEDS = (1, 2, 3)
EVENTS = {"no_provider", "provider_alternate", "weak_uses_alternate", "weak_uses_provider", "chooser_max",
          "chooser_min", "suppressed", "allocate", "replace", "deferred", "aging"}


def expect(stream, age_bits=18, region=None):
    """Model predictions as stimulus lines, plus which model paths the stream reached."""
    model = SmallTage()
    model.age_bits = age_bits  # instance override only; the class keeps 18
    lines, seen = [], set()
    for n, (pc, taken) in enumerate(stream):
        r, chooser = model.lookup(pc), model.use_alternate
        longer = [model.tables[b][r.indices[b]] for b in range(r.provider + 1, 4)]
        free = [e for e in longer if not e.valid or e.useful == 0]
        aging = (model.age + 1) % (1 << age_bits) == 0 and any(e.useful for t in model.tables for e in t)
        prediction = model.step(pc, taken)
        miss, split = prediction != taken, r.provider_prediction != r.alternate_prediction
        suppressed = miss and r.weak_new and r.provider_prediction == taken
        seen |= {k for k, v in dict(
            no_provider=r.provider < 0, provider_alternate=r.alternate >= 0,
            weak_uses_alternate=r.weak_new and split and chooser >= 0,
            weak_uses_provider=r.weak_new and split and chooser < 0,
            chooser_max=r.weak_new and split and chooser == 7 and r.alternate_prediction == taken,
            chooser_min=r.weak_new and split and chooser == -8 and r.alternate_prediction != taken,
            suppressed=suppressed, allocate=miss and not suppressed and bool(free),
            replace=miss and not suppressed and bool(free) and free[0].valid,
            deferred=miss and not suppressed and bool(longer) and not free, aging=aging).items() if v}
        lines.append(f"1 {pc:x} 1 {pc:x} {taken:x} {prediction:x} {int(region(n)) if region else 0:x}\n")
    return "".join(lines), seen


def pool_stream(seed, length, pcs, biases=(0.5,)):
    rng = random.Random(seed)
    pool = [(4 * rng.randrange(1 << 16), rng.choice(biases)) for _ in range(pcs)]
    return [(pc, int(rng.random() < bias)) for pc, bias in (rng.choice(pool) for _ in range(length))]


def pattern_stream(seed, period, pcs, repeats):
    rng = random.Random(seed)
    pattern = [rng.randrange(2) for _ in range(period)]
    return [(0x1000 + 4 * (n % pcs), pattern[n % period]) for n in range(period * repeats)]


def ports_stream(seed, length):
    """Independent ports: random valids, unrelated lookup and update pcs, junk upper and low pc bits."""
    rng, model, lines = random.Random(seed), SmallTage(), []
    # three pcs per low part: same table entry, different ignored upper bits.
    pool = [low | rng.randrange(1 << 14) << 18 for low in [rng.randrange(1 << 18) for _ in range(12)] for _ in range(3)]
    bias = {pc & 0x3fffc: rng.choice((0.1, 0.5, 0.9, 1.0)) for pc in pool}
    for _ in range(length):
        lookup_valid, update_valid = rng.random() < 0.8, rng.random() < 0.7
        update_pc = rng.choice(pool) ^ rng.randrange(4)
        lookup_pc = rng.randrange(1 << 32) if rng.random() < 0.05 else rng.choice((update_pc, rng.choice(pool)))
        taken = int(rng.random() < bias[update_pc & 0x3fffc])
        expected = model.lookup(lookup_pc).prediction  # state before this cycle's update
        if update_valid:
            model.step(update_pc, taken)
        lines.append(f"{lookup_valid:x} {lookup_pc:x} {update_valid:x} {update_pc:x} {taken:x} {expected:x} 0\n")
    return "".join(lines)


# each directed stream must reach its named paths in the model
DIRECTED = {
    "cold": ([(4 * n, n & 1) for n in range(64)], {"no_provider", "allocate"}),
    "pattern": (pattern_stream(7, 24, 1, 200), {"provider_alternate", "weak_uses_alternate", "suppressed"}),
    "pattern3": (pattern_stream(7, 24, 3, 200), {"replace", "weak_uses_provider"}),
    "noisy_bias": (pool_stream(3, 5000, 4, (0.97,)), {"chooser_max"}),
    "alias256": (pool_stream(4, 20000, 256), {"chooser_min"}),
    "contention": (pool_stream(1, 20000, 8), {"deferred", "chooser_min", "chooser_max"}),
}


class TagePredictorRtlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.binaries = {}
        for age_bits in (18, 10):
            out = f"{cls.tmp.name}/age{age_bits}"
            # unique X init makes unreset state random, so a missing reset diverges.
            build = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
                                    "--x-initial", "unique", "--top-module", "tage_predictor_tb",
                                    f"-GAGE_BITS={age_bits}", "--Mdir", out, *map(str, SOURCES)],
                                   capture_output=True, text=True)
            assert build.returncode == 0, build.stdout + build.stderr
            cls.binaries[age_bits] = f"{out}/Vtage_predictor_tb"

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def replay(self, name, text, age_bits=18):
        path = Path(self.tmp.name) / f"{name}.txt"
        path.write_text(text)
        results = []
        for seed in SEEDS:
            run = subprocess.run([self.binaries[age_bits], f"+stimulus={path}", "+verilator+rand+reset+2",
                                  f"+verilator+seed+{seed}"], capture_output=True, text=True, timeout=600)
            self.assertEqual(run.returncode, 0, f"{name} seed {seed}: {run.stdout}{run.stderr}")
            match = re.search(r"PASS lines=(\d+) region_misses=(\d+)", run.stdout)
            self.assertIsNotNone(match, run.stdout)
            # a truncated replay must not pass
            self.assertEqual(int(match[1]), text.count("\n"), name)
            results.append(int(match[2]))
        self.assertEqual(len(set(results)), 1, results)
        print(f"{name}: age_bits={age_bits} seeds={SEEDS} lines={text.count(chr(10))} region_misses={results[0]}")
        return results[0]

    def test_directed(self):
        reached = set()
        for name, (stream, targets) in DIRECTED.items():
            text, seen = expect(stream)
            self.assertLessEqual(targets, seen, name)
            reached |= seen
            self.replay(name, text)
        self.assertEqual(reached, EVENTS - {"aging"})

    def test_random_past_aging_period(self):
        stream = pool_stream(11, (1 << 18) + 20000, 8)
        text, seen = expect(stream)
        self.assertEqual(seen, EVENTS)
        self.replay("random_long", text)

    def test_short_aging_period(self):
        stream = pool_stream(12, 30000, 8) + pattern_stream(5, 20, 3, 500)
        text, seen = expect(stream, age_bits=10)
        self.assertEqual(seen, EVENTS)
        self.replay("random_age10", text, age_bits=10)

    def test_coremark_stream(self):
        if not (COREMARK / "coremark.elf").exists():
            if os.environ.get("REQUIRE_COREMARK"):
                self.fail("CoreMark not built; run `make coremark-check` first")
            self.skipTest("SKIPPED CoreMark replay: not built; run `make coremark-check` first")
        program, _, _ = load_coremark(COREMARK, 1)
        trace = collect(**program)
        branches = trace["branches"]
        start, end = trace["region_start_exclusive"], trace["region_end_inclusive"]
        text, _ = expect([(pc, taken) for _, pc, taken in branches],
                         region=lambda n: start < branches[n][0] <= end)
        model_misses = sum(1 for line in map(str.split, text.splitlines()) if line[6] == "1" and line[4] != line[5])
        self.assertEqual(model_misses, 43324)
        self.assertEqual(self.replay("coremark", text), 43324)

    def test_independent_ports(self):
        for seed in (1, 2):
            self.replay(f"ports{seed}", ports_stream(seed, 50000))


if __name__ == "__main__":
    unittest.main()
