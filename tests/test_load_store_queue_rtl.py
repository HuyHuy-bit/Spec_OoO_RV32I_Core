"""Full-size load_store_queue random scoreboard (verif/memory/load_store_queue_tb.sv)."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["rtl/memory/store_forward.sv", "rtl/memory/load_store_queue.sv", "verif/memory/load_store_queue_tb.sv"]


class LoadStoreQueueRtlTest(unittest.TestCase):
    def test_random(self):
        with tempfile.TemporaryDirectory() as tmp:
            build = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
                                    "--top-module", "load_store_queue_tb", "--Mdir", tmp,
                                    *[str(ROOT / p) for p in SOURCES]], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            for seed in (1, 2, 3):
                with self.subTest(seed=seed):
                    run = subprocess.run([f"{tmp}/Vload_store_queue_tb", f"+verilator+seed+{seed}"],
                                         capture_output=True, text=True, timeout=300)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertIn("PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
