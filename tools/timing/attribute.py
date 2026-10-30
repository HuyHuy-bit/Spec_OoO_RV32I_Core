"""Attribute each stage of a path to RTL modules by the registers feeding its side inputs (<= 4 levels back)."""
import re
import netlist

FLOP = re.compile(r"dfxtp|edfxtp")


class Attributor:
    def __init__(self, cells):
        self.cells = cells
        self.driver, _ = netlist.nets(cells)
        self.memo = {}

    def register(self, cell):
        return re.sub(r"\[\d+\]", "", self.cells.get(cell, ("", {}))[1].get("Q", cell))

    def regs(self, net, depth):
        key = (net, depth)
        if key not in self.memo:
            out, d = set(), self.driver.get(net)
            if d:
                typ, pins = self.cells[d[0]]
                if FLOP.search(typ):
                    out.add(re.sub(r"\[\d+\]", "", pins["Q"]))
                elif depth > 0:
                    for p, n in pins.items():
                        if p not in netlist.OUTPUTS: out |= self.regs(n, depth - 1)
            self.memo[key] = out
        return self.memo[key]

    def segments(self, p, depth=4):
        """[(start ns, end ns, up to 3 modules, side-input registers)], merged while the module set repeats."""
        segs, prev_net = [], None
        for s in p["stages"]:
            side = set()
            for pin, n in self.cells[s["cell"]][1].items():
                if pin not in netlist.OUTPUTS and n != prev_net: side |= self.regs(n, depth)
            prev_net = s.get("net")
            if not side: continue
            key = tuple(sorted({r.rsplit(".", 1)[0] if "." in r else r for r in side}))[:3]
            if segs and segs[-1][2] == key:
                segs[-1][1] = s["t"]
                segs[-1][3] |= side
            else:
                segs.append([s["t"], s["t"], key, set(side)])
        return segs
