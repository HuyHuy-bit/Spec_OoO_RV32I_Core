#!/usr/bin/env python3
"""Compare direction models on validated architectural traces; this does not measure CPI."""
# ruff: noqa: E402

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from verif.core.perf_programs import PROGRAMS
from verif.core.reference import Reference
from verif.frontend.predictor_model import models


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def collect(image, terminal, warm=None, limit=5_000_000, log_address=None):
    reference = Reference(image)
    branches, marks, seen = [], [None, None], [0, 0]
    plus4 = 0
    for order in range(limit):
        event = reference.step()
        if event.get('trap') or not event.get('retired'):
            raise ValueError(f'non-retired or trapping event at {event["pc_before"]:#x}')
        pc, instruction = event['pc_before'], event['instruction']
        if warm:
            for index in range(2):
                if pc == warm[index*2]:
                    seen[index] += 1
                    if seen[index] == warm[index*2+1]:
                        marks[index] = order
        if instruction & 127 == 0x63:
            taken = event['pc_after'] != ((pc + 4) & 0xffffffff)
            branches.append((order, pc, int(taken)))
            immediate = ((instruction >> 31) << 12) | ((instruction >> 7 & 1) << 11)
            immediate |= ((instruction >> 25 & 63) << 5) | ((instruction >> 8 & 15) << 1)
            plus4 += immediate == 4
        if pc == terminal:
            break
    else:
        raise ValueError('terminal not reached before instruction limit')
    if warm and (None in marks or marks[1] <= marks[0]):
        raise ValueError('region markers missing or reversed')
    if not warm:
        marks = [-1, order]
    log = None
    if log_address is not None:
        log = bytes(reference.memory[log_address:log_address+2048]).split(b'\0')[0].decode()
        if 'Correct operation validated' not in log:
            raise ValueError('CoreMark reference CRC validation failed: ' + log)
    trace_hash = hashlib.sha256()
    for branch in branches:
        trace_hash.update(struct.pack('<IIB', *branch))
    return dict(branches=branches, instructions=order+1, region_start_exclusive=marks[0],
                region_end_inclusive=marks[1], region_instructions=marks[1]-marks[0],
                branch_trace_sha256=trace_hash.hexdigest(), pc_plus4_branches=plus4,
                image_sha256=hashlib.sha256(image).hexdigest(), validation_log=log,
                terminal=terminal, warm=list(warm) if warm else None)


def score(trace):
    predictors = models()
    totals = {'all': Counter(), 'region': Counter()}
    misses = {scope: {name: Counter() for name in predictors} for scope in totals}
    start, end = trace['region_start_exclusive'], trace['region_end_inclusive']
    for order, pc, taken in trace['branches']:
        scopes = ('all', 'region') if start < order <= end else ('all',)
        for scope in scopes:
            totals[scope][pc] += 1
        for name, predictor in predictors.items():
            if predictor.step(pc, taken) != taken:
                for scope in scopes:
                    misses[scope][name][pc] += 1
    result = {}
    for scope, counts in totals.items():
        instructions = trace['instructions' if scope == 'all' else 'region_instructions']
        branches = sum(counts.values())
        result[scope] = dict(instructions=instructions, branches=branches, models={})
        for name, predictor in predictors.items():
            count = sum(misses[scope][name].values())
            result[scope]['models'][name] = dict(misses=count,
                miss_rate=count/branches if branches else 0,
                mpki=1000*count/instructions,
                configuration=predictor.configuration())
        result[scope]['per_pc'] = [dict(pc=f'0x{pc:08x}', branches=n,
            misses={name: misses[scope][name][pc] for name in predictors})
            for pc, n in sorted(counts.items())]
    return result


def load_coremark(directory, warmup):
    raw, elf = directory/'coremark.bin', directory/'coremark.elf'
    with tempfile.TemporaryDirectory() as tmp:
        copied = Path(tmp)/'image.bin'
        subprocess.run(['riscv64-unknown-elf-objcopy', '-O', 'binary', str(elf), str(copied)], check=True)
        image = raw.read_bytes()
        if copied.read_bytes() != image:
            raise ValueError('CoreMark ELF and raw image differ')
    output = subprocess.check_output(['riscv64-unknown-elf-nm', str(elf)], text=True)
    symbols = {f[2]: int(f[0], 16) for f in map(str.split, output.splitlines()) if len(f) == 3}
    seed = symbols['seed4_volatile']
    if seed + 4 > len(image):
        raise ValueError('CoreMark iteration count is outside the image')
    iterations = int.from_bytes(image[seed:seed+4], 'little', signed=True)
    if not 0 <= warmup < iterations:
        raise ValueError('warmup must leave at least one CoreMark iteration')
    return dict(image=image, terminal=symbols['coremark_done'],
                warm=(symbols['core_bench_list'], 2*warmup+1, symbols['stop_time'], 1)), symbols, iterations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--coremark-dir', type=Path, default=ROOT/'out/coremark')
    parser.add_argument('--warmup', type=int, default=1)
    parser.add_argument('--output', type=Path, default=ROOT/'evidence/predictor_comparison/receipt.json')
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.unlink(missing_ok=True)
    artifact_hashes = {n: digest(args.coremark_dir/n) for n in ('coremark.bin', 'coremark.elf')}
    program, symbols, iterations = load_coremark(args.coremark_dir, args.warmup)
    inputs = ['tools/run_predictor_comparison.py', 'verif/frontend/predictor_model.py',
              'verif/frontend/README.md', 'tests/test_predictor_model.py', 'verif/core/reference.py',
              'verif/core/perf_programs.py', 'verif/core/programs.py', 'config/platform.yaml',
              'rtl/frontend/branch_predictor.sv']
    hashes = {p: digest(ROOT/p) for p in inputs}
    results = {}
    for name, settings in [('coremark', program)] + [(n, build()) for n, build in PROGRAMS.items()]:
        trace = collect(**settings, log_address=symbols['coremark_log'] if name == 'coremark' else None)
        measured = score(trace)
        repeated = score(trace)
        if measured != repeated:
            raise ValueError(f'{name}: replay is not deterministic')
        results[name] = dict(trace={k: v for k, v in trace.items() if k != 'branches'}, results=measured)
        region = measured['region']
        print(f'{name}: {region["branches"]} region branches, {region["instructions"]} instructions; '
              + ', '.join(f'{n}={r["misses"]}' for n, r in region['models'].items()), flush=True)
    if any(digest(ROOT/p) != h for p, h in hashes.items()):
        raise ValueError('comparison inputs changed during the run')
    if any(digest(args.coremark_dir/n) != h for n, h in artifact_hashes.items()):
        raise ValueError('CoreMark image or ELF changed during the run')
    receipt = dict(schema=1, status='pass', coremark_iterations=iterations, warmup=args.warmup,
                   inputs_sha256=hashes,
                   coremark_files_sha256=artifact_hashes,
                   semantics='Sequential committed conditional branches; predict before immediate training; '
                             'history uses pc_after != pc_before+4. Full prefix trains before scoring region.',
                   region='Instruction-order window: start marker excluded, end marker included. '
                          'Not the cycle-edge window used by the RTL CPI bench.',
                   limits='No wrong-path execution, delayed training, prediction latency, target prediction, '
                          'CPI, area or timing measurement. One fixed TAGE variant and one CoreMark input.',
                   deterministic_replays=2, results=results)
    args.output.write_text(json.dumps(receipt, indent=2)+'\n')
    print(f'Predictor comparison: PASS; {args.output}')


if __name__ == '__main__':
    main()
