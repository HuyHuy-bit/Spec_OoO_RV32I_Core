#!/usr/bin/env python3
"""CoreMark on the fetched core: reference validation, store-overlap census and RTL CPI.

CPI is reported for the whole program and for a kernel region: from the first core_bench_list call of
iteration WARMUP (0-based) to stop_time, so it covers ITERATIONS - WARMUP iterations. Boot is everything
before the region and tail is from stop_time to the terminal; the fixed timer gives no CoreMark score.

The census bounds the partial-overlap merge (docs: lsq-roadmap): a load waits only when an
older store still in flight covers some, not all, of its bytes. Every older store within the
last ROB_N retired instructions is counted as in flight, so the census is an upper bound.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_cpi import check
from tools.run_sail_differential import build_fetched
from verif.core.reference import Reference

URL = 'https://github.com/eembc/coremark.git'
REVISION = '1f483d5b8316753a742cbf5590caf5bd0a4e4777'
SOURCE = ROOT/'out/coremark_src/coremark'
OUT = ROOT/'out/coremark'
FLAGS = ['-O2', '-march=rv32i', '-mabi=ilp32']
ROB_N = 32
PROFILES = ('early_load_core',)
LATENCIES = (1, 10)


def fetch():
    if not SOURCE.exists():
        subprocess.run(['git', 'clone', '-q', URL, str(SOURCE)], check=True)
    subprocess.run(['git', '-C', str(SOURCE), 'checkout', '-q', REVISION], check=True)
    head = subprocess.run(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], check=True, capture_output=True, text=True)
    if head.stdout.strip() != REVISION: raise RuntimeError('CoreMark checkout is not the pinned revision')


def build(iterations):
    """Barebones ee_printf with its #error uart_send_char removed; the port supplies one."""
    OUT.mkdir(parents=True, exist_ok=True)
    text = (SOURCE/'barebones/ee_printf.c').read_text()
    start = text.index('void\nuart_send_char(char c)')
    end = text.index('\n}\n', start) + 3
    (OUT/'ee_printf.c').write_text(text[:start] + 'void uart_send_char(char c);\n' + text[end:])
    elf = OUT/'coremark.elf'
    sources = ['sw/coremark/start.S', *(SOURCE/f'core_{n}.c' for n in ('list_join', 'main', 'matrix', 'state', 'util')),
               'sw/coremark/core_portme.c', OUT/'ee_printf.c']
    subprocess.run(['riscv64-unknown-elf-gcc', *FLAGS, f'-DITERATIONS={iterations}', f'-DFLAGS_STR="{" ".join(FLAGS)}"',
                    '-ffreestanding', '-nostdlib', '-nostartfiles', '-Wl,--no-relax,--build-id=none',
                    '-T', 'sw/link/platform.ld', '-Isw/coremark', f'-I{SOURCE}', *map(str, sources), '-lgcc',
                    '-o', str(elf)], cwd=ROOT, check=True)
    subprocess.run(['riscv64-unknown-elf-objcopy', '-O', 'binary', str(elf), str(OUT/'coremark.bin')], check=True)
    symbols = subprocess.run(['riscv64-unknown-elf-nm', str(elf)], check=True, capture_output=True, text=True).stdout
    symbols = {f[2]: int(f[0], 16) for f in map(str.split, symbols.splitlines()) if len(f) == 3}
    return (OUT/'coremark.bin').read_bytes(), symbols


def digest(*items):
    h = hashlib.sha256()
    for item in items: h.update(item if isinstance(item, bytes) else Path(item).read_bytes())
    return h.hexdigest()


def mem_bytes(event, mask):
    return {(event['mem_address'] & ~3) + lane for lane in range(4) if (mask >> lane) & 1}


def census(events):
    """Classify each load by the bytes older stores in the ROB window own: none, all (forwarded) or some."""
    counts = dict(loads=0, stores=0, no_overlap=0, covered=0, partial=0)
    for n, event in enumerate(events):
        if event.get('mem_write_mask'): counts['stores'] += 1
        if not event.get('mem_read_mask'): continue
        counts['loads'] += 1
        wanted = mem_bytes(event, event['mem_read_mask'])
        owned = set().union(*(mem_bytes(e, e['mem_write_mask']) for e in events[max(0, n-ROB_N):n]
                              if e.get('mem_write_mask'))) & wanted
        counts['no_overlap' if not owned else 'covered' if owned == wanted else 'partial'] += 1
    return counts


def run_rtl(binary, image_path, program, latency, expected):
    """The run_cpi recount: whole-program and region windows, retirement bins and counters against the reference."""
    command = [str(binary), str(image_path), '1', str(len(expected) + 16), 'perf', f'+read_latency={latency}',
               f'+write_latency={latency}', f'+terminal={program["terminal"]}',
               '+warm=' + ':'.join(map(str, program['warm']))]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=7200)
    if result.returncode: raise RuntimeError(result.stdout[-1500:])
    perf, counters = check(result.stdout, program, expected)
    return dict(**perf, counters=counters)


def main():
    import argparse
    parser = argparse.ArgumentParser()
    # Both traces stay in memory; three iterations (2.3M events) exceed an 8 GB host.
    parser.add_argument('--iterations', type=int, default=2)
    parser.add_argument('--warmup', type=int, default=1, help='iterations before the kernel region')
    parser.add_argument('--census-only', action='store_true')
    args = parser.parse_args()
    if not 0 <= args.warmup < args.iterations: raise ValueError('warmup must leave at least one region iteration')
    fetch()
    image, symbols = build(args.iterations)
    reference = Reference(image)
    expected = []
    while not expected or expected[-1]['pc_before'] != symbols['coremark_done']:
        expected.append(reference.step())
        if expected[-1].get('trap'): raise RuntimeError(f'reference trapped: {expected[-1]}')
    # iterate() calls core_bench_list twice per iteration.
    program = dict(image=image, terminal=symbols['coremark_done'],
                   warm=(symbols['core_bench_list'], 2*args.warmup + 1, symbols['stop_time'], 1))
    log = bytes(reference.memory[symbols['coremark_log']:symbols['coremark_log']+2048]).split(b'\0')[0].decode()
    if 'Correct operation validated' not in log: raise RuntimeError('CoreMark did not validate:\n' + log)
    store = lambda mask: dict(mem_address=0x100, mem_write_mask=mask)
    load = dict(mem_address=0x100, mem_read_mask=0xf)
    if (census([store(1), load])['partial'], census([store(3), store(12), load])['covered']) != (1, 1):
        raise RuntimeError('census misclassifies sb;lw or sh;sh;lw')
    counts = census(expected)
    print(f'CoreMark x{args.iterations}: {len(expected)} instructions, validated; census (window {ROB_N}) {counts}', flush=True)
    receipt_path = OUT/'receipt.json'
    receipt = dict(schema=2, status='partial', coremark_revision=REVISION, flags=FLAGS, iterations=args.iterations,
                   warmup=args.warmup, region=dict(start=['core_bench_list', 2*args.warmup + 1], end=['stop_time', 1]),
                   instructions=len(expected), rob_window=ROB_N, census=counts, results=[],
                   claim='CoreMark 2K performance run validates on the reference; RTL traces match it. Census counts '
                         'are an upper bound on partial store overlaps.')
    # A recorded run is reused only while the image, RTL sources and bench it ran on are unchanged.
    previous = json.loads(receipt_path.read_text()).get('results', []) if receipt_path.exists() else []
    for profile in () if args.census_only else PROFILES:
        config = json.loads((ROOT/f'config/{profile}.json').read_text())
        inputs = digest(image, *(ROOT/s for s in config['sources'] + [f'config/{profile}.json', config['lint_config'],
                                                                     'verif/core/fetched_core_tb.cpp', 'verif/core/trace_lockstep.sv']))
        binary = None
        for latency in LATENCIES:
            done = next((r for r in previous if (r['profile'], r['latency'], r.get('inputs_sha256'))
                         == (profile, latency, inputs)), None)
            if done: print(f'CPI {profile} latency={latency}: recorded, skipped', flush=True)
            else:
                binary = binary or build_fetched(OUT/f'obj_{profile}', config_name=profile)[0]
                perf = run_rtl(binary, OUT/'coremark.bin', program, latency, expected)
                done = dict(profile=profile, latency=latency, inputs_sha256=inputs, **perf)
            receipt['results'].append(done)
            receipt_path.write_text(json.dumps(receipt, indent=2)+'\n')
            print(f'CPI {profile} latency={latency}: whole {done["cycles"]/done["retired"]:.3f} '
                  f'({done["cycles"]} cycles, {done["retired"]} retired); kernel {done["warm_cycles"]/done["warm_retired"]:.3f} '
                  f'({done["warm_cycles"]} cycles, {done["warm_retired"]} retired); boot {done["warm_start"]} cycles, '
                  f'tail {done["cycles"] - done["warm_start"] - done["warm_cycles"]} cycles', flush=True)
    if args.census_only: receipt['results'] = previous
    receipt['status'] = 'pass' if len(receipt['results']) == len(PROFILES)*len(LATENCIES) else 'partial'
    receipt_path.write_text(json.dumps(receipt, indent=2)+'\n')
    print(f'CoreMark check: {receipt["status"].upper()}; receipt {(OUT/"receipt.json").relative_to(ROOT)}')


if __name__ == '__main__':
    main()
