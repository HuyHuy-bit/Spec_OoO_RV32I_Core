"""l1_cache_array against an associative-array shadow (verif/memory/l1_cache_array_tb.sv)."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "rtl/memory/l1_cache_array.sv", ROOT / "verif/memory/l1_cache_array_tb.sv"]
SEEDS = (1, 2, 3)


class L1CacheArrayRtlTest(unittest.TestCase):
    def test_random_against_shadow(self):
        with tempfile.TemporaryDirectory() as tmp:
            # unique X init makes unreset storage random, so the bench must only compare written bits.
            build = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
                                    "--x-initial", "unique", "--top-module", "l1_cache_array_tb",
                                    "--Mdir", tmp, *map(str, SOURCES)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            counts = set()
            for seed in SEEDS:
                run = subprocess.run([f"{tmp}/Vl1_cache_array_tb", "+verilator+rand+reset+2",
                                      f"+verilator+seed+{seed}"], capture_output=True, text=True, timeout=600)
                self.assertEqual(run.returncode, 0, f"seed {seed}: {run.stdout}{run.stderr}")
                match = re.search(r"PASS reads=(\d+) writes=(\d+)", run.stdout)
                self.assertIsNotNone(match, run.stdout)
                reads, writes = map(int, match.groups())
                self.assertGreater(reads, 10000)
                self.assertGreater(writes, 10000)
                counts.add((reads, writes))
            print(f"seeds={SEEDS} reads/writes={sorted(counts)}")


if __name__ == "__main__":
    unittest.main()
