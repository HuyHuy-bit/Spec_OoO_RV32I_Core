"""Directed branch_predictor regressions (verif/frontend/branch_predictor_tb.sv)."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "rtl/frontend/branch_predictor.sv", ROOT / "verif/frontend/branch_predictor_tb.sv"]


class BranchPredictorRtlTest(unittest.TestCase):
    def test_directed(self):
        with tempfile.TemporaryDirectory() as tmp:
            # unique X init makes unreset state random, so a missing reset fails the RAS check.
            build = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
                                    "--x-initial", "unique", "--top-module", "branch_predictor_tb",
                                    "--Mdir", tmp, *map(str, SOURCES)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            for seed in (1, 2, 3):
                run = subprocess.run([f"{tmp}/Vbranch_predictor_tb", "+verilator+rand+reset+2",
                                      f"+verilator+seed+{seed}"], capture_output=True, text=True, timeout=60)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertIn("PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
