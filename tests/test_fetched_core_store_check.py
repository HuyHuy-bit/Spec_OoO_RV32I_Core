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

# Two cacheable stores that differ in address and data, so exchanging them is visible.
PROGRAM = constant(1, 0x8000) + [i(2, 0, 5), i(3, 0, 7), store(1, 2, 0, 2), store(1, 3, 4, 2), jal(0, 0)]


class FetchedCoreStoreCheckTest(unittest.TestCase):
    def run_bench(self, tmp, **build):
        binary = build_fetched(Path(tmp) / "obj_dir", **build)[0]
        image = Path(tmp) / "program.bin"
        image.write_bytes(b"".join(w.to_bytes(4, "little") for w in PROGRAM))
        return subprocess.run([str(binary), str(image), "1", "20", "normal"], cwd=ROOT,
                              capture_output=True, text=True, timeout=120)

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
