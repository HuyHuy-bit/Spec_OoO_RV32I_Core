"""TAGE speculative lookup, ordered dual retirement and checkpoint recovery."""
from pathlib import Path
import random
import subprocess
import tempfile
import unittest

from verif.frontend.predictor_model import SmallTage

ROOT = Path(__file__).resolve().parents[1]


def ports_stimulus(seed, cycles=12000):
    rng, model = random.Random(seed), SmallTage()
    model.age_bits = 10
    for n in range(cycles):
        valid, branch, path = (rng.randrange(4) for _ in range(3))
        pcs = [4 * rng.randrange(8) for _ in range(2)]
        updates = rng.randrange(4)
        upcs = [4 * rng.randrange(8) for _ in range(2)]
        outcome = rng.randrange(4)
        # Include repeated indices and adjacent updates around every age boundary.
        if n % 8 == 0:
            updates, outcome, upcs = 3, 0, [0, 0]
        committed = model.history
        h = rng.choice([committed, rng.getrandbits(32)])
        initial, prediction = h, 0
        for lane in range(2):
            model.history = h
            taken = bool(valid & (1 << lane)) and model.lookup(pcs[lane]).prediction
            prediction |= int(taken) << lane
            if valid & branch & (1 << lane):
                h = ((h << 1) | int(taken and bool(path & (1 << lane)))) & 0xffffffff
        model.history = committed
        for lane in range(2):
            if updates & (1 << lane):
                model.step(upcs[lane], (outcome >> lane) & 1)
        base = sum(v << (2 * i) for i, v in enumerate(model.base))
        banks = sum((int(e.valid) << 13 | e.tag << 5 | (e.counter & 7) << 2 | e.useful)
                    << (14 * (64 * b + i)) for b, table in enumerate(model.tables) for i, e in enumerate(table))
        values = [valid, pcs[0] | pcs[1] << 32, initial, branch, path, updates, outcome,
                  upcs[0] | upcs[1] << 32, prediction, base, banks, model.history,
                  model.use_alternate & 15, model.age]
        yield ' '.join(f'{v:x}' for v in values) + '\n'


class TageIntegrationRtlTest(unittest.TestCase):
    def run_bench(self, top, stimulus=False):
        with tempfile.TemporaryDirectory() as tmp:
            sources = ['rtl/frontend/tage_predictor.sv', 'rtl/frontend/branch_predictor.sv',
                       f'verif/frontend/{top}.sv']
            result = subprocess.run(['verilator', '--binary', '--timing', '--assert', '-Wall',
                                     '--x-initial', 'unique', '--top-module', top, '--Mdir', tmp,
                                     *sources], cwd=ROOT, capture_output=True, text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for seed in (1, 2, 3):
                args = []
                if stimulus:
                    path = Path(tmp) / 'stimulus.txt'
                    path.write_text(''.join(ports_stimulus(seed)))
                    args = [f'+stimulus={path}']
                result = subprocess.run([f'{tmp}/V{top}', *args, '+verilator+rand+reset+2',
                                         f'+verilator+seed+{seed}'], cwd=ROOT, capture_output=True,
                                        text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('PASS', result.stdout)

    def test_speculative_ports_and_dual_retirement(self):
        self.run_bench('tage_ports_tb', stimulus=True)

    def test_recovery(self):
        self.run_bench('tage_recovery_tb')


if __name__ == '__main__':
    unittest.main()
