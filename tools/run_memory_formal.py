#!/usr/bin/env python3
"""Run source-bound RTL property checks with shared formal tooling."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import time

from run_assert_portability import digest, require

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--suite', type=Path, default=Path.home()/'tools/oss-cad-suite-20260905/oss-cad-suite')
    parser.add_argument('--profile', choices=['load_transaction_handshake', 'store_forward', 'load_store_queue'], required=True)
    args = parser.parse_args()
    suite = args.suite.resolve()
    config_path = f'config/{args.profile}.json'
    config = json.loads((ROOT/config_path).read_text())
    load = args.profile == 'load_transaction_handshake'
    selector = args.profile == 'store_forward'
    queue = args.profile == 'load_store_queue'
    lint = selector or queue
    title = 'Store forwarding' if selector else 'Load/store queue' if queue else 'Load handshake'
    if queue:
        require(config['reduced'] == dict(LQ_N=2, SQ_N=2, ROB_W=2, ID_W=4) and config['depth'] == 11
                and config['top'] == 'load_store_queue_properties', 'unsupported queue geometry')
    elif selector:
        require(config['candidates'] == 9 and config['depth'] == 1 and config['top'] == 'store_forward_properties', 'unsupported selector geometry')
    else:
        require(config['depth'] == 20 and config['top'] == args.profile, 'unsupported handshake bound or top')
    require(config['mode'] == 'bmc' and config['engine'] == ('smtbmc bitwuzla' if lint else 'smtbmc yices' if load else 'abc bmc3')
            and config['cover_engine'] == 'smtbmc yices', 'unsupported proof mode')
    mutations = config.get('mutations', [])
    if load:
        from unit_profiles import PROFILES
        mutations = []
        for name, assertions in config['unit_mutations'].items():
            source, old, new, count = PROFILES[config['unit_mutation_profile']]['mutations'][name]
            require(count == 1, 'unsupported mutation match count')
            mutations.append(dict(name=name, source=source, old=old, new=new, assertions=assertions))
    harness = (ROOT/config['sources'][-1]).read_text()
    require(set(re.findall(r'(\w+): cover', harness)) == set(config['required_covers']), 'cover contract differs')
    lock = json.loads((ROOT/'config/formal_tools.lock').read_text())
    synthesis = json.loads((ROOT/lock['synthesis_lock']).read_text())
    for name, value in {**synthesis['sha256'], **lock['sha256']}.items():
        require((suite/name).is_file() and digest(suite/name) == value, f'tool pin differs: {name}')
    require(digest(Path('/usr/bin/time')) == lock['time_sha256'], 'resource measurement tool differs')
    versions = {}
    for name, expected in {**lock['versions'], 'yosys': synthesis['yosys_version']}.items():
        versions[name] = subprocess.check_output([str(suite/'bin'/name), '--version'], text=True).splitlines()[0]
        require(versions[name] == expected, f'{name} version differs')
    if lint:
        toolchain = json.loads((ROOT/'config/toolchain.lock').read_text())
        # Pin the checked binary: the suite PATH used for later steps carries a different Verilator.
        verilator = shutil.which('verilator')
        require(verilator is not None, 'Verilator not found')
        versions['verilator'] = subprocess.check_output([verilator, '--version'], text=True).splitlines()[0]
        require(versions['verilator'] == next(t['expected_first_line'] for t in toolchain['tools'] if t['name'] == 'verilator'), 'Verilator version differs')
    paths = [*config['sources'], config_path, 'config/formal_tools.lock',
             lock['synthesis_lock'], 'tools/run_memory_formal.py', 'tools/run_assert_portability.py',
             *config.get('extra_inputs', [])]
    inputs = {p: digest(ROOT/p) for p in paths}
    run_hash = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:16]
    out = ROOT/'out'/args.profile/run_hash
    out.mkdir(parents=True, exist_ok=True)
    receipt = out/'receipt.json'
    receipt.unlink(missing_ok=True)
    retained = ROOT/f'evidence/receipts/{args.profile}.json'
    retained.unlink(missing_ok=True)
    started = datetime.now(timezone.utc).isoformat()
    env = dict(os.environ, PATH=str(suite/'bin')+os.pathsep+os.environ['PATH'])
    checks, cells = [], {}
    if lint:
        rtl = [str(ROOT/p) for p in config['sources'][:-1]]
        steps = [('lint', [verilator, '--lint-only', '--Wall', '--top-module', config['dut'], *rtl])]
        if selector:
            script = out/'synth.ys'
            script.write_text(f'plugin -i slang\nread_slang --top {config["dut"]} {" ".join(rtl)}\n'
                              f'synth -top {config["dut"]}\ncheck -assert\nwrite_json {out/"synth.json"}\n')
            steps.append(('synth', [str(suite/'bin/yosys'), '-s', str(script)]))
        for name, command in steps:
            log = out/(name+'.log')
            with log.open('w') as stream:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=config['timeout_seconds'])
            require(result.returncode == 0, f'{name} failed; see {log}')
            checks.append(dict(command=command, returncode=result.returncode, log=str(log.relative_to(ROOT))))
    if selector:
        modules = json.loads((out/'synth.json').read_text())['modules']
        for module in modules.values():
            for cell in module['cells'].values():
                kind = cell['type']
                require(kind.startswith('$_') and not any(k in kind.upper() for k in ('DFF', 'LATCH')), 'selector contains state or unmapped logic')
                cells[kind] = cells.get(kind, 0)+1
        require(cells, 'empty selector synthesis')
    jobs = []
    variants = [dict(name='covers', mode='cover')]
    variants += [dict(m, mode='bmc') for m in mutations]
    if selector:
        variants += [dict(name='baseline_'+name, mode='bmc', check=n)
                     for n, name in enumerate(('stall', 'mask', 'data', 'result'))]
    else:
        variants.append(dict(name='baseline', mode=config['mode']))
    for variant in variants:
        name = variant['name']
        directory = out/name
        directory.mkdir(exist_ok=True)
        sources = [ROOT/p for p in config['sources']]
        if 'old' in variant:
            index = config['sources'].index(variant['source']) if 'source' in variant else 2
            original = sources[index].read_text()
            require(original.count(variant['old']) == 1, f'mutation no longer matches: {name}')
            changed = directory/sources[index].name
            changed.write_text('`define SYNTHESIS\n'+original.replace(variant['old'], variant['new'])+'\n`undef SYNTHESIS\n')
            sources[index] = changed
        task = directory/'check.sby'
        engine = config['cover_engine'] if variant['mode'] == 'cover' else config['engine']
        parameter = f'-G CHECK={variant["check"]} ' if 'check' in variant else ''
        task.write_text(f'[options]\nmode {variant["mode"]}\ndepth {config["depth"]}\n\n'
                        f'[engines]\n{engine}\n\n[script]\nplugin -i slang\n'
                        f'read_slang --no-synthesis-define --top {config["top"]} {parameter}'+ ' '.join(p.name for p in sources)+'\n'
                        f'prep -top {config["top"]}\n\n[files]\n'+'\n'.join(str(p) for p in sources)+'\n')
        proof = directory/'proof'
        log = directory/'check.log'
        rss = directory/'memory.rss'
        command = ['/usr/bin/time', '-f', '%M', '-o', str(rss), str(suite/'bin/sby'), '-f', '-d', str(proof), str(task)]
        print(f'{title} {name}: running {variant["mode"]} depth={config["depth"]}', flush=True)
        before = time.monotonic()
        with log.open('w') as stream:
            child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = child.wait(timeout=config['timeout_seconds'])
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                raise RuntimeError(f'{name} interrupted or timed out; see {log}')
        output = log.read_text()
        status = (proof/'status').read_text().split()[0] if (proof/'status').is_file() else 'ERROR'
        mutant = 'old' in variant
        require(status == ('FAIL' if mutant else 'PASS') and ((code != 0) if mutant else (code == 0)), f'{name}: unexpected status {status}; see {log}')
        summary = (proof/status).read_text()
        assertions = []
        for filename, line in re.findall(r'failed assertion \S+ at (\w+\.sv):(\d+)\.', summary):
            source = next(p for p in sources if p.name == filename)
            label = re.search(r'(\w+):\s*assert\b', source.read_text().splitlines()[int(line)-1])
            assertions.append(label[1] if label else f'{filename}:{line}')
        traces = sorted(str(p.relative_to(ROOT)) for p in (proof/'engine_0').glob('trace*.vcd'))
        if mutant:
            require(traces, f'{name}: missing counterexample')
        engine_log = '\n'.join(p.read_text() for p in sorted((proof/'engine_0').glob('logfile*.txt')))
        top = re.escape(config['top'])
        assertions += re.findall(r'Assert failed in '+top+r': (\w+)', engine_log)
        assertions = sorted(set(assertions))
        if mutant:
            require(any(expected in assertions for expected in variant['assertions']), f'{name}: wrong assertion failed: {assertions}')
        reached = re.findall(r'reached cover statement '+top+r'\.(\w+)', summary)
        reached += re.findall(r'Reached cover statement in step \d+ at '+top+r': (\w+)', engine_log)
        reached = sorted(set(reached))
        if variant['mode'] == 'cover':
            require(set(reached) == set(config['required_covers']) and traces, 'incomplete required covers')
        # the selector is stateless, so its one-step run is exhaustive.
        if variant['mode'] == 'bmc' and not mutant:
            steps = [int(n) for n in re.findall(r'Checking assertions in step (\d+)', engine_log)]
            require(steps and max(steps) == config['depth']-1, 'incomplete bounded safety run')
        jobs.append(dict(name=name, mode=variant['mode'], engine=engine, depth=config['depth'], status=status,
                         expected_failure=mutant, command=command, duration_seconds=round(time.monotonic()-before, 6),
                         max_rss_kib=int(rss.read_text().splitlines()[-1]), log=str(log.relative_to(ROOT)),
                         assertions_failed=assertions, covers_reached=reached, traces=traces,
                         dut_assertions_enabled=not mutant))
        print(f'{title} {name}: PASS ({"fault detected" if mutant else status})', flush=True)
    require(all(digest(ROOT/p) == value for p, value in inputs.items()), 'inputs changed during run')
    artifacts = {str(p.relative_to(ROOT)): digest(p) for p in out.rglob('*') if p.is_file()}
    result = dict(schema=1, status='pass', profile=config['profile'], claim=config['claim'],
                  source_revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  dirty_tree=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
                  started_utc=started, finished_utc=datetime.now(timezone.utc).isoformat(), versions=versions,
                  inputs_sha256=inputs, artifacts_sha256=artifacts, assumptions=config['assumptions'],
                  environment=config['environment'], jobs=jobs, formal_readiness_accepted=False)
    if lint:
        result.update(checks=checks, synthesis_cells=cells)
    receipt.write_text(json.dumps(result, indent=2)+'\n')
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    archive = ROOT/f'evidence/{args.profile}/{run_id}.tar.gz'
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'w:gz') as bundle:
        for path, expected in sorted({**inputs, **artifacts}.items()):
            require(digest(ROOT/path) == expected, f'artifact changed before retention: {path}')
            bundle.add(ROOT/path, arcname=path, recursive=False)
        bundle.add(receipt, arcname='manifest.json', recursive=False)
    retained.parent.mkdir(parents=True, exist_ok=True)
    retained.write_text(json.dumps(dict(schema=1, status='pass', profile=config['profile'],
        claim=config['claim'], archive=str(archive.relative_to(ROOT)), archive_sha256=digest(archive),
        manifest_sha256=digest(receipt), inputs_sha256=inputs), indent=2)+'\n')
    print(f'{title} {"proof" if selector else "check" if queue else "smoke"}: PASS; receipt {receipt.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
