#!/usr/bin/env python3
"""Perf-mode CPI runs of the calibration and layout-controlled programs with independently recounted windows
and verification-only activity counters (docs_plan/learning-materials/perf-counters.md)."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_sail_differential import build_fetched, packets
from verif.core.perf_programs import PROGRAMS
from verif.core.reference import Reference, unpack_event
from verif.lockstep.comparator import compare_traces

LATENCIES = (1, 10, 50)
CHUNK = 50000
LIMIT = 4000
# Counting faults that the recount must reject: (name, old, new).
MUTATIONS = [
    ('cold_off_by_one', 'if (terminal_seen) terminal_cycle=cycle+1;', 'if (terminal_seen) terminal_cycle=cycle;'),
    ('dropped_lane', 'retired+=accepted; ++bins[accepted];', 'retired+=accepted&1; ++bins[accepted&1];'),
    ('region_off_by_one', 'cycle<warm_at[1][0])) sample', 'cycle<=warm_at[1][0])) sample'),
]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(binary, raw, program, latency):
    command = [str(binary), str(raw), '1', str(LIMIT), 'perf', f'+read_latency={latency}',
               f'+write_latency={latency}', f'+terminal={program["terminal"]}']
    if 'warm' in program: command.append('+warm=' + ':'.join(map(str, program['warm'])))
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    if result.returncode: raise RuntimeError(result.stdout[-1500:])
    return result.stdout


def check(output, program, expected_events=None):
    """Recount every window from per-event edge stamps and compare with the bench and the reference.
    Returns the PERF fields and the COUNTER lines as {'all': {...}, 'region': {...}}."""
    events, stamps = [], []
    for line in output.splitlines():
        if line.startswith('EVENT '):
            fields = line.split()
            stamps.append(int(fields[1])); events.append(unpack_event(fields[3:]))
    perf = dict(item.split('=') for item in next(l for l in output.splitlines() if l.startswith('PERF ')).split()[1:])
    perf = {k: int(v) for k, v in perf.items()}
    if expected_events is None:
        reference = Reference(program['image'])
        expected_events = [reference.step() for _ in events]
    # Chunked: packets() and validation copy each event, which a whole CoreMark trace cannot afford.
    if len(expected_events) != len(events):
        raise ValueError(f'event count differs: expected {len(expected_events)}, got {len(events)}')
    for at in range(0, len(events), CHUNK):
        compare_traces(packets(expected_events[at:at+CHUNK]), packets(events[at:at+CHUNK]))
    end = next(s for s, e in zip(stamps, events) if e['pc_before'] == program['terminal'])
    per_edge = [0] * (end+1)
    for s in stamps:
        if s <= end: per_edge[s] += 1
    expected = dict(cycles=end+1, retired=sum(per_edge), zero=per_edge.count(0), one=per_edge.count(1),
                    two=per_edge.count(2), drain=perf['drain'])
    if 'warm' in program:
        pc0, n0, pc1, n1 = program['warm']
        marks = [[s for s, e in zip(stamps, events) if e['pc_before'] == pc][n-1] for pc, n in ((pc0, n0), (pc1, n1))]
        expected.update(warm_cycles=marks[1]-marks[0], warm_retired=sum(marks[0] < s <= marks[1] for s in stamps),
                        warm_start_edge=per_edge[marks[0]], warm_start=marks[0]+1)
    if perf != expected: raise ValueError(f'perf counters {perf} differ from recount {expected}')
    if any(s > end for s in stamps) or perf['retired'] > 2*perf['cycles'] or not perf['retired']:
        raise ValueError('retirement outside the window or beyond two per cycle')
    counters = {}
    for line in output.splitlines():
        if line.startswith('COUNTER '):
            _, scope, name, value = line.split()
            counters.setdefault(scope, {})[name] = int(value)
    # The counters sample the same edges as the windows, so their cycle and retirement bins must agree.
    windows = [('all', perf['cycles'], (perf['zero'], perf['one'], perf['two']))]
    if 'warm' in program:
        region = per_edge[perf['warm_start']:perf['warm_start']+perf['warm_cycles']]
        windows.append(('region', perf['warm_cycles'], tuple(region.count(k) for k in range(3))))
    for scope, cycles, bins in windows:
        c = counters.get(scope, {})
        if (c.get('cycles'), tuple(c.get(f'retire_{k}', 0) for k in range(3))) != (cycles, bins):
            raise ValueError(f'{scope} counters {c} disagree with the recount ({cycles} cycles, bins {bins})')
    return perf, counters


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default='early_load_core', help='fetched-core profile under config/')
    name = parser.parse_args().config
    config = json.loads((ROOT/f'config/{name}.json').read_text())
    out = ROOT/f'out/cpi_{name}'
    out.mkdir(parents=True, exist_ok=True)
    (out/'receipt.json').unlink(missing_ok=True)
    binary = build_fetched(out/'obj_dir', config_name=name)[0]
    results = []
    for program_name, build in PROGRAMS.items():
        program = build()
        raw = out/f'{program_name}.bin'
        raw.write_bytes(program['image'])
        for latency in LATENCIES:
            output = run(binary, raw, program, latency)
            if run(binary, raw, program, latency) != output: raise ValueError(f'{program_name}: nondeterministic run')
            perf, counters = check(output, program)
            results.append(dict(program=program_name, latency=latency, image_sha256=digest(raw), **perf, counters=counters))
            warm = f' warm CPI={perf["warm_cycles"]/perf["warm_retired"]:.3f}' if 'warm_cycles' in perf else ''
            print(f'CPI {program_name} latency={latency}: cold CPI={perf["cycles"]/perf["retired"]:.3f} '
                  f'({perf["cycles"]} cycles, {perf["retired"]} retired){warm}', flush=True)
    tb = ROOT/'verif/core/fetched_core_tb.cpp'
    caught = []
    for mutation, old, new in MUTATIONS:
        text = tb.read_text()
        if text.count(old) != 1: raise ValueError(f'{mutation}: mutation no longer matches')
        directory = out/mutation
        directory.mkdir(exist_ok=True)
        (directory/tb.name).write_text(text.replace(old, new))
        mutant = build_fetched(directory/'obj_dir', ('verif/core/fetched_core_tb.cpp', directory/tb.name), name)[0]
        program = PROGRAMS['loop_memory']()
        try: check(run(mutant, out/'loop_memory.bin', program, 1), program)
        except ValueError: caught.append(mutation)
        else: raise RuntimeError(f'counting mutation {mutation} was not detected')
        print(f'CPI counting mutation {mutation}: PASS (detected)', flush=True)
    inputs = {p: digest(ROOT/p) for p in sorted(config['sources'] + [f'config/{name}.json', 'tools/run_cpi.py',
              'tools/run_sail_differential.py', 'verif/core/fetched_core_tb.cpp', 'verif/core/trace_lockstep.sv', 'verif/core/perf_programs.py',
              'verif/core/reference.py'])}
    (out/'receipt.json').write_text(json.dumps(dict(schema=1, status='pass', profile='cpi_measurement_task1',
        parameters=config['parameters'], latencies=LATENCIES, results=results, mutations=caught, inputs_sha256=inputs,
        claim='Perf-mode window counting on the core matches an independent recount from per-edge retirement '
              'stamps; traces match the reference interpreter. Calibration programs only; not a workload baseline.'),
        indent=2)+'\n')
    print(f'CPI measurement check: PASS; receipt {(out/"receipt.json").relative_to(ROOT)}')


if __name__ == '__main__':
    main()
