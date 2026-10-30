"""Parse full OpenSTA path reports (report_checks -fields {fanout slew net}) into stages."""
import re
from netlist import OUTPUTS

STAGE = re.compile(r"\s+(\S+)\s+(\S+)\s+(\S+) [v^] (\S+)/(\w+) \((\S+)\)")
NET = re.compile(r"\s+(\d+)\s+(\S+) \(net\)")
SLACK = re.compile(r"\s+(\S+)\s+slack")


def parse(path):
    paths, cur = [], None
    for line in open(path):
        if line.startswith("Startpoint:"):
            cur = {"start": line.split()[1], "stages": []}
            paths.append(cur)
        elif line.startswith("Endpoint:"):
            cur["end"] = line.split()[1]
        elif cur is not None:
            m = STAGE.match(line)
            if m and m.group(5) in OUTPUTS:
                cur["stages"].append({"slew": float(m.group(1)), "d": float(m.group(2)), "t": float(m.group(3)),
                                      "cell": m.group(4), "type": m.group(6).replace("sky130_fd_sc_hd__", "")})
            m = NET.match(line)
            if m and cur["stages"]:
                cur["stages"][-1]["fo"], cur["stages"][-1]["net"] = int(m.group(1)), m.group(2)
            m = SLACK.match(line)
            if m: cur["slack"] = float(m.group(1))
    return paths


def logic_levels(p):
    return sum(1 for s in p["stages"] if not re.match(r"(buf|clkbuf)_", s["type"]))
