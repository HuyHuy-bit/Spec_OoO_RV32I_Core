"""The fetched-core bench checks store order and external line writes against the committed-store stream."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_sail_differential import build_fetched
from verif.core.programs import i, store, jal, constant
from verif.core.reference import unpack_event

# Two cacheable stores that differ in address and data, so exchanging them is visible.
PROGRAM = constant(1, 0x8000) + [i(2, 0, 5), i(3, 0, 7), store(1, 2, 0, 2), store(1, 3, 4, 2), jal(0, 0)]
# A store (at 0xc), and a load (at 0x8), to a fresh line: the first data-port line read is that line's refill.
STORE_MISS = constant(1, 0x8000) + [i(2, 0, 5), store(1, 2, 0, 2), jal(0, 0)]
LOAD_MISS = constant(1, 0x8000) + [i(2, 1, 0, 2, 3), jal(0, 0)]


class FetchedCoreStoreCheckTest(unittest.TestCase):
    def run_bench(self, tmp, program=PROGRAM, **build):
        binary = build_fetched(Path(tmp) / "obj_dir", **build)[0]
        image = Path(tmp) / "program.bin"
        image.write_bytes(b"".join(w.to_bytes(4, "little") for w in program))
        return subprocess.run([str(binary), str(image), "1", "20", "normal"], cwd=ROOT,
                              capture_output=True, text=True, timeout=120)

    def refill_fault(self, program):
        """A refill access fault on the cached core stops it as a platform fatal, never a trap."""
        with tempfile.TemporaryDirectory() as tmp:
            run = self.run_bench(tmp, program, config_name="cached_core", bench_defines=["TB_REFILL_FAULT=1"])
        output = run.stdout + run.stderr
        self.assertNotEqual(run.returncode, 0, output)
        self.assertIn("platform fatal", output)
        self.assertIn("DC_REFILL_FAULT", output)
        events = [unpack_event(line.split()[3:]) for line in run.stdout.splitlines() if line.startswith("EVENT ")]
        self.assertFalse(any(e["trap"] for e in events), output)
        return [e["pc_before"] for e in events if e["retired"]]

    def test_refill_fault_is_fatal_store(self):
        # The store retires first; its write-allocate refill faults afterwards.
        self.assertIn(0xc, self.refill_fault(STORE_MISS))

    def test_refill_fault_is_fatal_load(self):
        self.assertNotIn(0x8, self.refill_fault(LOAD_MISS))

    def test_reordered_committed_store_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = self.run_bench(tmp, bench_defines=["TB_SWAP_COMMITTED=1"])
            self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("committed store differs from its retirement", run.stderr)

    def test_diverged_shadow_memory_fails(self):
        # Corrupting the bench's shadow application must be caught by the external line-write check.
        bench = ROOT / "verif/core/fetched_core_tb.cpp"
        old = "shadow[w.address+lane]=uint8_t(w.data>>(8*lane));"
        text = bench.read_text()
        self.assertEqual(text.count(old), 1, "mutation no longer matches")
        with tempfile.TemporaryDirectory() as tmp:
            mutant = Path(tmp) / bench.name
            mutant.write_text(text.replace(old, "shadow[w.address+lane]=uint8_t(w.data>>(8*lane))^1;"))
            run = self.run_bench(tmp, replace=("verif/core/fetched_core_tb.cpp", mutant))
            self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("external line write differs from committed memory", run.stderr)


if __name__ == "__main__":
    unittest.main()
