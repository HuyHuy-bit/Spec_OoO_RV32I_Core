#!/usr/bin/env python3
"""Run chip_top through the LibreLane Classic flow (SKY130 HD) with the A1 timing intent."""

import argparse
import json
import shutil
import subprocess

from run_a1_timing import sdc
from run_chip_timing import ROOT, SOURCES, TOP


OUT = ROOT / "out/chip_librelane"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", help="last LibreLane step id to run, e.g. OpenROAD.ResizerTimingPostCTS")
    parser.add_argument("--threads", type=int, default=4, help="detailed-routing threads; each costs memory")
    parser.add_argument("--period", type=float, help="clock period in ns; default: the A1 intent's")
    parser.add_argument("--from", dest="start", help="start at this step instead of overwriting the run")
    parser.add_argument("--state", help="initial state JSON for --from; resuming without one chains onto the run's last state")
    parser.add_argument("--tag", default="latest", help="run directory name under out/chip_librelane/runs")
    args = parser.parse_args()
    if not shutil.which("librelane"):
        raise RuntimeError("librelane not on PATH")
    OUT.mkdir(parents=True, exist_ok=True)
    intent = json.loads((ROOT / "config/a1_timing.json").read_text())
    if args.period:
        intent["period_ns"] = args.period
    # OpenROAD estimates parasitics from placement and routing, so the wire-load lines do not apply.
    constraints = "\n".join(line for line in sdc(intent, True).splitlines() if "wire_load" not in line)
    (OUT / "chip_top.sdc").write_text(constraints + "\n")
    config = {
        "DESIGN_NAME": TOP,
        "VERILOG_FILES": [str(ROOT / path) for path in SOURCES],
        "VERILOG_DEFINES": ["SYNTHESIS"],
        "USE_SLANG": True,
        # ABC on the flat 165k-gate core ran for over an hour and grew past 3.5 GB; map module by
        # module, then flatten for place and route.
        "SYNTH_HIERARCHY_MODE": "deferred_flatten",
        "SLANG_ARGUMENTS": ["--keep-hierarchy"],
        # every other strategy runs ABC's fraig_store/fraig_restore choice pass, which filled 7.6 GB
        # on reorder_buffer alone; DELAY 0 is the only one without it.
        "SYNTH_STRATEGY": "DELAY 0",
        # the RTL gates already lint every source with the pinned Verilator.
        "RUN_LINTER": False,
        # repair_design picked these delay cells as fanout buffers: 44 of them, 26 ns, on the post-CTS worst path.
        # sign-off is TT (plan O4); repairing every STA corner chases the SS corner's much larger violations.
        "RSZ_CORNERS": ["nom_tt_025C_1v80"],
        "EXTRA_EXCLUDED_CELLS": ["sky130_fd_sc_hd__clkdlybuf4s*"],
        "CLOCK_PORT": "clk_i",
        "CLOCK_PERIOD": intent["period_ns"],
        "PNR_SDC_FILE": str(OUT / "chip_top.sdc"),
        "SIGNOFF_SDC_FILE": str(OUT / "chip_top.sdc"),
        "MAX_FANOUT_CONSTRAINT": intent["max_fanout"],
        "FP_SIZING": "relative",
        "FP_CORE_UTIL": 45,
        "PL_TARGET_DENSITY_PCT": 55,
        "DRT_THREADS": args.threads,
    }
    (OUT / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    command = ["librelane", "--pdk", "sky130A", "--scl", "sky130_fd_sc_hd", "--run-tag", args.tag]
    command += ["--from", args.start] if args.start else ["--overwrite"]
    if args.state: command += ["--with-initial-state", args.state]
    command += [str(OUT / "config.json")] + (["--to", args.to] if args.to else [])
    print(f"chip librelane: {' '.join(command)}", flush=True)
    raise SystemExit(subprocess.run(command, cwd=ROOT).returncode)


if __name__ == "__main__":
    main()
