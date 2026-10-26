"""Directed load_store_unit regressions (verif/memory/load_store_unit_tb.sv)."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LoadStoreUnitRtlTest(unittest.TestCase):
    def run_bench(self, profile, top):
        sources = json.loads((ROOT / f"config/{profile}.json").read_text())["sources"]
        sources = [str(ROOT / p) for p in sources] + [str(ROOT / f"verif/memory/{top}.sv")]
        with tempfile.TemporaryDirectory() as tmp:
            build = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
                                    "--top-module", top, "--Mdir", tmp, *sources],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([f"{tmp}/V{top}"], capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS", run.stdout)

    def test_directed(self):
        self.run_bench("early_load_core", "load_store_unit_tb")

    def test_dcache_squashed_loads(self):
        # response_same_cycle_as_recovery, zombie_response_after_slot_reuse,
        # identity_recycle_with_dcache_miss_outstanding and a flush under a miss.
        self.run_bench("cached_core", "load_store_unit_dcache_tb")


if __name__ == "__main__":
    unittest.main()
