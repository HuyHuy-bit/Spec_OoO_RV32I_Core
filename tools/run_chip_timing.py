#!/usr/bin/env python3
"""Map chip_top to SKY130 cells and measure its constrained pre-layout timing with the A1 intent."""

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess

from fetch_a1_timing import DEPS, verify
from run_a1_probe import ROOT, digest, run, verify_synthesis_suite
from run_a1_timing import analyze, sdc


# chip_top pins cpu_top to the cached profile parameters, so it shares that profile's sources.
DEFAULT_TOP = "chip_top"
DEFAULT_SOURCES = "cached_core"
# module-level defaults are imported by run_chip_librelane.py; main() overrides them for other tops.
OUT = ROOT / "out/chip_timing"
TOP = DEFAULT_TOP
SOURCES = json.loads((ROOT / f"config/{DEFAULT_SOURCES}.json").read_text())["sources"] + ["rtl/core/chip_top.sv"]
TIE = "sky130_fd_sc_hd__conb_1"
BUFFER = "sky130_fd_sc_hd__buf_1"
REGISTER_PATHS = """read_liberty $liberty
read_verilog $netlist
link_design $top
read_sdc $constraints
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -path_delay max -group_count 10 -fields {fanout slew net} -digits 4 > $reports/register_setup.rpt
puts "CHIP REGISTER STA COMPLETE"
"""


def constant_endpoints(netlist: str) -> tuple[str, ...]:
    """Tie-cell nets and the data pins they drive carry no timing arc, so STA leaves them unconstrained."""
    ties = {net.strip() for net in re.findall(r"\.(?:HI|LO)\(([^()]+)\)", netlist)}
    pins = re.findall(r"(?m)^  \S+ (\S+) \(\n(?:    \.\w+\(.*\),\n)*?    \.D\(([^()]+)\)", netlist)
    return tuple(sorted(ties)) + tuple(f"{cell}/D" for cell, net in pins if net.strip() in ties)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", type=Path,
                        default=Path.home() / "tools/oss-cad-suite-20260905/oss-cad-suite")
    parser.add_argument("--top", default=DEFAULT_TOP)
    parser.add_argument("--sources-config", default=DEFAULT_SOURCES, help="config/NAME.json with a sources list")
    args = parser.parse_args()
    global OUT, TOP, SOURCES
    TOP = args.top
    # chip_top keeps out/chip_timing so existing consumers still find its receipt.
    OUT = ROOT / "out/chip_timing" / ("" if TOP == DEFAULT_TOP else TOP)
    SOURCES = json.loads((ROOT / f"config/{args.sources_config}.json").read_text())["sources"]
    if TOP == DEFAULT_TOP:
        SOURCES = SOURCES + ["rtl/core/chip_top.sv"]
    OUT.mkdir(parents=True, exist_ok=True)
    receipt = OUT / "receipt.json"
    receipt.unlink(missing_ok=True)
    lock = verify()
    yosys = verify_synthesis_suite(args.suite.resolve())
    sta = str(DEPS / lock["opensta"]["executable"])
    if run([sta, "-version"], OUT / "sta_version.log").strip() != lock["opensta"]["version"]:
        raise RuntimeError("OpenSTA version mismatch")
    config = json.loads((ROOT / "config/a1_timing.json").read_text())
    dont_use = " ".join(f"-dont_use {pattern}" for pattern in config["dont_use"])
    liberty = (DEPS / lock["library"]["path"]).relative_to(ROOT)
    abc = OUT / "abc.constr"
    abc.write_text(f'set_driving_cell {config["abc_driver"]}\nset_load {config["abc_load_ff"]}\n')
    prefix = OUT.relative_to(ROOT)
    # splitnets and hilomap remove the concatenated and constant assigns the pinned OpenSTA cannot parse;
    # insbuf replaces the rest, output bits driven by one net (the cache's line write mask).
    script = (f'read_slang --top {TOP} -D SYNTHESIS {" ".join(SOURCES)}; '
              f'synth -top {TOP} -flatten -noabc; dfflibmap -liberty {liberty} {dont_use}; '
              f'abc -liberty {liberty} {dont_use} -constr {abc.relative_to(ROOT)} -D {config["period_ns"] * 1000}; '
              f'clean -purge; splitnets; hilomap -hicell {TIE} HI -locell {TIE} LO; opt_clean -purge; insbuf -buf {BUFFER} A X; '
              f'read_liberty -lib {liberty}; check -assert; '
              f'stat -liberty {liberty}; write_json {prefix}/mapped.json; '
              f'write_verilog -noattr -noexpr {prefix}/mapped.v')
    (OUT / "synth.ys").write_text(script + "\n")
    print(f"chip timing: synthesizing {TOP} (several minutes)", flush=True)
    # The shared run() caps commands at 300 s; full-core synthesis takes longer.
    result = subprocess.run([yosys, "-Q", "-T", "-m", "slang", "-s", str(OUT / "synth.ys")], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3600)
    (OUT / "synth.log").write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"synthesis failed; see {(OUT / 'synth.log').relative_to(ROOT)}\n{result.stdout[-5000:]}")
    log = result.stdout
    net = json.loads((OUT / "mapped.json").read_text())
    counts = Counter(cell["type"] for cell in net["modules"][TOP]["cells"].values())
    if any(not cell.startswith("sky130_fd_sc_hd__") for cell in counts):
        raise RuntimeError(f"unmapped cell in {TOP}")
    bits = sum(count for cell, count in counts.items()
               if cell.startswith(("sky130_fd_sc_hd__df", "sky130_fd_sc_hd__edf")))
    area = re.search(r'Chip area for (?:top )?module.*?:\s*([\d.]+)', log)
    if not area:
        raise RuntimeError("missing mapped area")
    netlist = (OUT / "mapped.v").read_text()
    if re.search(r"(?m)^\s*assign\b", netlist):
        raise RuntimeError("netlist still contains assigns OpenSTA cannot parse")
    timing = analyze(sta, liberty, prefix / "mapped.v", TOP, OUT, sdc(config, True), constant_endpoints(netlist))
    (OUT / "register.tcl").write_text(f'set liberty {liberty}\nset netlist {prefix}/mapped.v\nset top {TOP}\n'
                                      f'set constraints {prefix}/constraints.sdc\nset reports {prefix}\n'
                                      + REGISTER_PATHS)
    if "CHIP REGISTER STA COMPLETE" not in run([sta, "-no_init", "-exit", str(OUT / "register.tcl")],
                                               OUT / "register_sta.log"):
        raise RuntimeError("register-to-register STA did not finish")
    registers = (OUT / "register_setup.rpt").read_text()
    slack = re.search(r'(-?[\d.]+)\s+slack \(', registers)
    end = re.search(r"(?m)^Endpoint: (\S+)", registers)
    if not slack or not end:
        raise RuntimeError("missing register-to-register path")
    register = re.search(rf"(?m)^  \S+ {re.escape(end[1])} \(\n(?:    \..*\n)*?    \.Q\(([^()]+)\)", netlist)
    results = {"schema": 1, "inputs_sha256": {p: digest(ROOT / p) for p in SOURCES + [
                   f"config/{args.sources_config}.json", "config/a1_timing.json", "config/a1_timing.lock",
                   "config/synthesis.lock", "synth/a1_timing.tcl", "tools/run_chip_timing.py",
                   "tools/run_a1_timing.py"]},
               "intent": config, "library": lock["library"], "opensta": lock["opensta"],
               "physical_implementation": False, "mapped_simulation": False,
               "cell_counts": dict(sorted(counts.items())), "stored_bits": bits,
               "cell_area_um2": float(area[1]), **timing,
               "register_setup_worst_slack_ns": float(slack[1]),
               "register_setup_endpoint": end[1],
               "register_setup_endpoint_register": register[1].strip() if register else None,
               "netlist_sha256": digest(OUT / "mapped.v")}
    receipt.write_text(json.dumps(results, indent=2) + "\n")
    print(f'chip timing {TOP}: area={area[1]} um^2, flops={bits}, setup slack={timing["setup_worst_slack_ns"]} ns '
          f'(register-to-register {slack[1]} ns), hold slack={timing["hold_worst_slack_ns"]} ns, '
          f'met={timing["setup_hold_met"]}', flush=True)


if __name__ == "__main__":
    main()
