#!/usr/bin/env python3
"""Repaired-timing gate for chip_top: emulated fanout repair on the chip-timing-check netlist, timed at the library
wire load and at 10x wire capacitance, with the worst endpoint registers attributed to RTL modules.
Raw chip-timing-check slack is dominated by unbuffered fanout; this is the logic-depth progress metric."""
import argparse, hashlib, json, os, pickle, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/timing"))
import netlist, paths, repair  # noqa: E402
from attribute import Attributor  # noqa: E402

DEPS = ROOT / "out/deps/a1_timing"
LIB = DEPS / "sky130_fd_sc_hd__tt_025C_1v80.lib"
STA = DEPS / "opensta/usr/bin/sta"
SDC = ROOT / "out/chip_timing/constraints.sdc"
ROW = re.compile(r"^(\S+)\s+\(\S+\)\s+(\S+)\s+(\S+)\s+(\S+)")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def wire10x(out):
    # the library's own wire load gives a fanout-1 net ~0.33 fF, about a tenth of a short routed net
    if not out.exists():
        text, n = re.subn(r"capacitance : 1\.42e-05;", "capacitance : 1.42e-04;", LIB.read_text())
        assert n == 4, f"expected the 4 wire_load capacitances, found {n}"
        out.write_text(text)
    return out


def first_row(report):
    for line in Path(report).read_text().splitlines():
        m = ROW.match(line)
        if m and m.group(1) != "Endpoint":
            return {"endpoint": m.group(1), "slack": float(m.group(4))}
    return None


def sta(lib, design, reports, pins=None):
    env = dict(os.environ, TIMING_LIB=str(lib), TIMING_NETLIST=str(design), TIMING_SDC=str(SDC),
               TIMING_REPORTS=str(reports))
    if pins: env["TIMING_PINS"] = str(pins)
    log = subprocess.run([str(STA), "-no_splash", "-exit", str(ROOT / "tools/timing/sta_repaired.tcl")],
                         env=env, capture_output=True, text=True)
    name = "sta_paths.log" if pins else "sta.log"
    (reports / name).write_text(log.stdout + log.stderr)
    if log.returncode or "DONE" not in log.stdout:
        sys.exit(f"OpenSTA failed, see {reports / name}")


def run_sta(lib, design, reports):
    reports.mkdir(parents=True, exist_ok=True)
    sta(lib, design, reports)
    worst = (reports / "worst_path.rpt").read_text()
    r2r = reports / "r2r_endpoints.rpt"
    return {
        "worst": float(re.search(r"(\S+)\s+slack", worst).group(1)),
        "worst_startpoint": re.search(r"^Startpoint: (\S+)", worst, re.M).group(1),
        "input_to_register": first_row(reports / "input_worst.rpt"),
        "hold": first_row(reports / "hold_worst.rpt"),
        "reg_to_reg": first_row(r2r)["slack"],
        "reg_to_reg_violating": r2r.read_text().count("VIOLATED"),
        "slew_violations": (reports / "slew.rpt").read_text().count("VIOLATED"),
    }


def worst_pins(r2r_endpoints, attributor, want):
    """The worst bit of each of the `want` worst endpoint registers; a wide register fills many bit paths."""
    pins, seen = [], set()
    for line in Path(r2r_endpoints).read_text().splitlines():
        m = ROW.match(line)
        if not m or m.group(1) == "Endpoint": continue
        reg = attributor.register(m.group(1).split("/")[0])
        if reg not in seen:
            seen.add(reg)
            pins.append(m.group(1))
            if len(pins) == want: break
    assert len(pins) == want, f"only {len(pins)} endpoint registers in {r2r_endpoints}"
    return pins


CHAINS = (("E", ("tage_",)),  # retirement training, added by this plan
          ("D", ("lsu.cached.", "load_transaction")),  # load launch through store forwarding
          # frontend-rename loop; the LSU queue pointers are loaded by allocation, so they belong here
          ("C", ("core.frontend", "prediction_", "allocate_", "systems.dispatch", "rename", "rob.", "lsu.queues.")))


def chain(register):
    """Study chain of an endpoint register. A and B (recovery, wakeup-select-execute) share everything else:
    the study lists alu1_event, agu.saved_q, mispredict_i, producer0.event_o and the IQ registers under both."""
    for name, keys in CHAINS:
        if any(k in register for k in keys): return name
    return "A/B"


def worst_per_chain(r2r_endpoints, attributor):
    """Worst endpoint register of every chain over all violating endpoints, not only the plotted top few."""
    worst = {}
    for line in Path(r2r_endpoints).read_text().splitlines():
        m = ROW.match(line)
        if not m or m.group(1) == "Endpoint": continue
        reg = attributor.register(m.group(1).split("/")[0])
        worst.setdefault(chain(reg), {"register": reg, "slack": float(m.group(4))})
    return worst


def worst_endpoints(report, attributor, want):
    rows, text = [], []
    for p in sorted(paths.parse(report), key=lambda p: p["slack"]):
        reg = attributor.register(p["end"])
        start = attributor.register(p["start"])
        rows.append({"register": reg, "slack": p["slack"], "logic_levels": paths.logic_levels(p),
                     "cells": len(p["stages"]), "start": start})
        text.append(f"== {reg}  slack {p['slack']:.2f}  logic levels {rows[-1]['logic_levels']}  start {start}")
        for a, b, key, side in attributor.segments(p):
            regs = ", ".join(sorted({r.split(".")[-1] for r in side}))[:120]
            text.append(f"  {a:6.2f}-{b:6.2f}  {' | '.join(key)}  <- {regs}")
    assert len(rows) == want, f"{len(rows)} paths in {report}, expected {want}"
    return rows, "\n".join(text) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--netlist", type=Path, default=ROOT / "out/chip_timing/mapped.v")
    parser.add_argument("--out", type=Path, default=ROOT / "out/chip_timing_repaired")
    parser.add_argument("--tag", default="baseline", help="report subdirectory")
    parser.add_argument("--fanout", type=int, default=10)
    parser.add_argument("--top", type=int, default=12)
    parser.add_argument("--cut", nargs="*", default=[], help="nets to register first (timing emulation of a cut)")
    args = parser.parse_args()
    if not args.netlist.exists():
        sys.exit(f"{args.netlist} is missing; run make chip-timing-check first")

    out = args.out / args.tag
    out.mkdir(parents=True, exist_ok=True)
    cells = netlist.load(str(args.netlist), str(args.out / "cache"))
    port_names = netlist.ports(str(args.netlist))
    live, new_nets, removed, inserted = repair.repair(cells, port_names, args.fanout)
    if args.cut: new_nets += repair.cut(live, args.cut)
    design = out / "repaired.v"
    netlist.write(live, str(design), str(args.netlist), new_nets)
    pickle.dump(live, open(out / "repaired.pkl", "wb"))

    libs = {"ideal": LIB, "wire10x": wire10x(args.out / "sky130_hd_tt_wire10x.lib")}
    attributor = Attributor(live)
    summary = {"netlist": str(args.netlist), "netlist_sha256": sha(args.netlist), "cuts": args.cut,
               "repair": {"fanout": args.fanout, "buffers_removed": removed, "buffers_inserted": inserted,
                          "cells": len(live)},
               "liberty_sha256": {k: sha(v) for k, v in libs.items()}, "columns": {}}
    for column, lib in libs.items():
        reports = out / column
        summary["columns"][column] = run_sta(lib, design, reports)
        pins = reports / "worst_pins.txt"
        pins.write_text("\n".join(worst_pins(reports / "r2r_endpoints.rpt", attributor, args.top)) + "\n")
        sta(lib, design, reports, pins)
        rows, text = worst_endpoints(reports / "r2r_top.rpt", attributor, args.top)
        c = summary["columns"][column]
        c["worst_endpoints"] = rows
        c["worst_per_chain"] = worst_per_chain(reports / "r2r_endpoints.rpt", attributor)
        for key in ("input_to_register", "hold"):
            c[key]["register"] = attributor.register(c[key]["endpoint"].split("/")[0])
        (reports / "chains.txt").write_text(text)
        print(f"{column}: reg-to-reg {c['reg_to_reg']:.2f} ns ({c['reg_to_reg_violating']} violating), "
              f"overall {c['worst']:.2f} from {c['worst_startpoint']}, "
              f"input {c['input_to_register']['slack']:.2f}, hold {c['hold']['slack']:.2f}, "
              f"worst endpoint {rows[0]['register']} ({rows[0]['logic_levels']} levels)")
        print("  per chain: " + ", ".join(f"{k} {v['slack']:.2f}" for k, v in sorted(c["worst_per_chain"].items())))
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"summary: {out / 'summary.json'}")


if __name__ == "__main__":
    main()
