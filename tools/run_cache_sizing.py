#!/usr/bin/env python3
"""Replay the CoreMark reference trace through the cache model per size; this does not measure CPI."""
# ruff: noqa: E402

import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.cache import Cache, Geometry, Memory
from tools.run_predictor_comparison import load_coremark
from verif.core.reference import Reference

WAYS, LINE = 2, 32
CACHEABLE_END = 0x10000000
LIMIT = 5_000_000


def accesses(program):
    """Yield (order, kind, addr, size) per fetch ('i'), load ('l') and store ('s')."""
    reference = Reference(program['image'])
    for order in range(LIMIT):
        event = reference.step()
        if event.get('trap') or not event.get('retired'):
            raise ValueError(f'non-retired or trapping event at {event["pc_before"]:#x}')
        yield order, 'i', event['pc_before'], 4
        if event.get('mem_valid') and event['mem_address'] < CACHEABLE_END:
            mask = event.get('mem_write_mask') or event['mem_read_mask']
            kind = 's' if event.get('mem_write_mask') else 'l'
            yield order, kind, event['mem_address'], bin(mask).count('1')
        if event['pc_before'] == program['terminal']:
            return
    raise ValueError('terminal not reached before instruction limit')


def region_bounds(program):
    """Instruction-order window used by the predictor comparison: start excluded, end included."""
    reference, seen, marks = Reference(program['image']), [0, 0], [None, None]
    warm = program['warm']
    for order in range(LIMIT):
        pc = reference.step()['pc_before']
        for i in range(2):
            if pc == warm[2*i]:
                seen[i] += 1
                if seen[i] == warm[2*i+1]:
                    marks[i] = order
        if pc == program['terminal']:
            break
    if None in marks or marks[1] <= marks[0]:
        raise ValueError('region markers missing or reversed')
    return marks


def run(program, sizes):
    start, end = region_bounds(program)
    caches = {(k, s): Cache(Geometry(s, WAYS, LINE), Memory(LINE), writable=k == 'd')
              for s in sizes for k in 'id'}
    counts = {key: {'all': [0, 0], 'region': [0, 0]} for key in caches}
    instructions, last_line = 0, None
    for order, kind, addr, size in accesses(program):
        instructions = order + 1
        key_kind = 'i' if kind == 'i' else 'd'
        if kind == 'i':
            if addr // LINE == last_line:
                continue  # same line as the previous fetch: served from the fetch buffer
            last_line = addr // LINE
        for (k, s), cache in caches.items():
            if k != key_kind:
                continue
            if kind == 'i':
                result = cache.load(addr & ~3, 4)
            elif kind == 'l':
                result = cache.load(addr, size)
            else:
                result = cache.store(addr, size, 0)
            for scope in ('all', 'region') if start < order <= end else ('all',):
                counts[(k, s)][scope][0] += 1
                counts[(k, s)][scope][1] += not result.hit
    return counts, instructions, end - start


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sizes', type=int, nargs='+', default=[1024, 2048])
    parser.add_argument('--coremark-dir', type=Path, default=ROOT/'out/coremark')
    parser.add_argument('--warmup', type=int, default=1)
    parser.add_argument('--output', type=Path, default=ROOT/'out/cache_sizing/receipt.json')
    args = parser.parse_args()
    program, _, iterations = load_coremark(args.coremark_dir, args.warmup)
    counts, instructions, region_instructions = run(program, args.sizes)
    results = []
    for (kind, size), scopes in counts.items():
        for scope, (n, misses) in scopes.items():
            rate = 100*misses/n if n else 0
            results.append(dict(cache=kind, size=size, scope=scope, accesses=n, misses=misses, miss_rate_pct=rate))
            tag = 'SIZING' if scope == 'all' else 'SIZING-REGION'
            print(f'{tag} {kind} size={size} accesses={n} misses={misses} miss_rate={rate:.3f}%')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(
        schema=1, ways=WAYS, line_bytes=LINE, iterations=iterations, warmup=args.warmup,
        instructions=instructions, region_instructions=region_instructions, results=results,
        limits='Cold caches from reset; fetch is one lookup per line change; no timing.'),
        indent=2)+'\n')


if __name__ == '__main__':
    main()
