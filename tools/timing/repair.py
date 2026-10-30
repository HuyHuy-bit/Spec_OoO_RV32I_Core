"""Emulated pre-placement repair and register cuts on a parsed netlist (timing emulation only, no design change)."""
import re
import netlist

BUF = re.compile(r"sky130_fd_sc_hd__(buf|clkbuf)_\d+$")


def repair(cells, port_names, fanout):
    """OpenROAD-like remove_buffers, then every net with more than `fanout` sinks rebuilt as a balanced buf_4 tree.
    No sizing, no placement. Returns (cells, new nets, buffers removed, buffers inserted)."""
    parent = {}
    def find(n):
        while n in parent: n = parent[n]
        return n
    for typ, pins in cells.values():
        if BUF.match(typ) and not netlist.is_port(pins["X"], port_names):
            parent[pins["X"]] = pins["A"]
    live = {k: (t, {p: find(n) for p, n in pins.items()}) for k, (t, pins) in cells.items()
            if not (BUF.match(t) and pins["X"] in parent)}
    sinks = {}
    for name, (typ, pins) in live.items():
        for p, n in pins.items():
            if p not in netlist.OUTPUTS and n != "clk_i":
                sinks.setdefault(n, []).append((name, p))
    new_nets = []
    for n, ss in sinks.items():
        while len(ss) > fanout:
            groups, ss = [ss[i:i + fanout] for i in range(0, len(ss), fanout)], []
            for g in groups:
                k = len(new_nets) + 1
                b, w = f"_rb{k}_", f"rbnet{k}"
                live[b] = ("sky130_fd_sc_hd__buf_4", {"A": n, "X": w})
                new_nets.append(w)
                for c, p in g: live[c][1][p] = w
                ss.append((b, "A"))
    return live, new_nets, len(parent), len(new_nets)


def cut(cells, targets):
    """Drive each named net from a new dfxtp_1 whose D is the old net ("register this signal").
    'x*' matches every bit of x; 'net@prefix' registers the net only for sinks whose cell name starts with prefix.
    Mutates cells; returns the new wires."""
    def match(n, t): return n == t or (t.endswith("*") and (n == t[:-1] or n.startswith(t[:-1] + "[")))
    whole = [t for t in targets if "@" not in t]
    partial = [t.split("@") for t in targets if "@" in t]
    new, wires = {}, []
    for typ, pins in list(cells.values()):
        for p, n in list(pins.items()):
            if p in netlist.OUTPUTS and any(match(n, t) for t in whole):
                d = n + "__d"
                pins[p] = d
                wires.append(d)
                new[f"_cut{len(new)}_"] = ("sky130_fd_sc_hd__dfxtp_1", {"CLK": "clk_i", "D": d, "Q": n})
    for t, prefix in partial:
        for name, (typ, pins) in list(cells.items()):
            if not name.startswith(prefix): continue
            for p, n in list(pins.items()):
                if p not in netlist.OUTPUTS and match(n, t):
                    q = n + "__q" + str(len(new))
                    pins[p] = q
                    wires.append(q)
                    new[f"_cut{len(new)}_"] = ("sky130_fd_sc_hd__dfxtp_1", {"CLK": "clk_i", "D": n, "Q": q})
    assert new, f"no net matched {targets}"
    cells.update(new)
    return wires
