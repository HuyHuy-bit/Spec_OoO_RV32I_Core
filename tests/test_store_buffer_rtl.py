"""store_buffer against a queue model (verif/memory/store_buffer_tb.sv), its contract checks and RTL mutants."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/memory/store_buffer.sv"
BENCH = ROOT / "verif/memory/store_buffer_tb.sv"
SEEDS = (1, 2, 3)
# Each must make the bench fail: (name, old, new).
MUTATIONS = [
    ("push_ignores_pop", "!shifted[k] && occupied[k]", "!valid_q[k] && occupied[k]"),
    ("pop_keeps_order_slot", "address_q[k] <= address_up[k];", "address_q[k] <= address_q[k];"),
    ("drain_youngest", "assign drain_address_o = address_q[0];", "assign drain_address_o = address_q[DEPTH-1];"),
    ("ready_when_full", "assign push_ready_o = !valid_q[DEPTH-1];", "assign push_ready_o = 1'b1;"),
]


def build(tmp, rtl=RTL):
    run = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wall", "-Wno-fatal",
                          "--top-module", "store_buffer_tb", "--Mdir", str(tmp), str(rtl), str(BENCH)],
                         capture_output=True, text=True)
    return run, Path(tmp) / "Vstore_buffer_tb"


def simulate(binary, *args):
    return subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=120)


class StoreBufferRtlTest(unittest.TestCase):
    def test_random_against_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            made, binary = build(tmp)
            self.assertEqual(made.returncode, 0, made.stdout + made.stderr)
            for seed in SEEDS:
                run = simulate(binary, f"+verilator+seed+{seed}")
                self.assertEqual(run.returncode, 0, f"seed {seed}: {run.stdout}{run.stderr}")
                match = re.search(r"PASS pushes=(\d+) pops=(\d+) both=(\d+) full=(\d+) held=(\d+)", run.stdout)
                self.assertIsNotNone(match, run.stdout)
                pushes, pops, both, full, held = map(int, match.groups())
                self.assertEqual(pushes, pops)
                self.assertGreater(pushes, 5000)
                self.assertGreater(both, 1000)
                self.assertGreater(full, 500)
                self.assertGreater(held, 1000)

    def test_contract_assertions(self):
        with tempfile.TemporaryDirectory() as tmp:
            made, binary = build(tmp)
            self.assertEqual(made.returncode, 0, made.stdout + made.stderr)
            for negative, marker in (("push_full", "SB_PUSH_FULL"), ("pop_empty", "SB_POP_EMPTY")):
                run = simulate(binary, f"+negative={negative}")
                self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertIn(marker, run.stdout + run.stderr)

    def test_mutants_detected(self):
        text = RTL.read_text()
        for name, old, new in MUTATIONS:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                self.assertEqual(text.count(old), 1, f"{name}: mutation no longer matches")
                mutant = Path(tmp) / RTL.name
                mutant.write_text(text.replace(old, new))
                made, binary = build(Path(tmp) / "obj", mutant)
                self.assertEqual(made.returncode, 0, made.stdout + made.stderr)
                run = simulate(binary, "+verilator+seed+1")
                self.assertNotEqual(run.returncode, 0, f"{name} survived: {run.stdout}")
                self.assertIn("FAIL", run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
