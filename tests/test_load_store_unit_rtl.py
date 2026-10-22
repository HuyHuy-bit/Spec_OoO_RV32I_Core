"""Directed load_store_unit regressions (verif/memory/load_store_unit_tb.sv)."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LoadStoreUnitRtlTest(unittest.TestCase):
    def test_directed(self):
        sources = json.loads((ROOT / "config/early_load_core.json").read_text())["sources"]
        sources = [str(ROOT / p) for p in sources] + [str(ROOT / "verif/memory/load_store_unit_tb.sv")]
        with tempfile.TemporaryDirectory() as tmp:
            build = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
                                    "--top-module", "load_store_unit_tb", "--Mdir", tmp, *sources],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([f"{tmp}/Vload_store_unit_tb"], capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
