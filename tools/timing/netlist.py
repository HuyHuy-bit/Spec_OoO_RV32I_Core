"""Flat sky130 Yosys netlist: parse instances, find drivers and sinks, write it back."""
import hashlib, os, pickle, re
OUTPUTS = {"X", "Y", "Q", "Q_N", "HI", "LO", "COUT", "SUM"}
INST = re.compile(r"^  (sky130_fd_sc_hd__\w+) (\S+)\s+\(\n(.*?)\n  \);", re.S | re.M)
PIN = re.compile(r"\.(\w+)\((.*?)\)(?:,|$)", re.M)
PORT = re.compile(r"^  (?:input|output) (?:\[\d+:\d+\] )?(\w+);", re.M)


def norm(n):
    n = n.strip()
    return n[1:] if n.startswith("\\") else n


def load(path, cache_dir):
    # the cache is keyed by content, so a resynthesized netlist never reuses stale cells
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]
    cache = os.path.join(cache_dir, f"cells-{digest}.pkl")
    if os.path.exists(cache):
        return pickle.load(open(cache, "rb"))
    cells = {norm(m.group(2)): (m.group(1), {p: norm(n) for p, n in PIN.findall(m.group(3))})
             for m in INST.finditer(open(path).read())}
    assert cells, f"no instances parsed from {path}"
    os.makedirs(cache_dir, exist_ok=True)
    pickle.dump(cells, open(cache, "wb"))
    return cells


def header(src):
    text = open(src).read()
    return text[: text.index("  sky130_fd_sc_hd__")]


def ports(src):
    return set(PORT.findall(header(src)))


def is_port(n, port_names):
    return n.split("[")[0] in port_names and not n.startswith("core.")


def nets(cells):
    driver, sinks = {}, {}
    for name, (typ, pins) in cells.items():
        for p, n in pins.items():
            if p in OUTPUTS:
                driver[n] = (name, p)
            else:
                sinks.setdefault(n, []).append((name, p))
    return driver, sinks


def write(cells, out, src, extra_wires=()):
    head = header(src)
    port_names = set(PORT.findall(head))
    def esc(n):
        return n if is_port(n, port_names) or re.fullmatch(r"\w+", n) else "\\" + n + " "
    with open(out, "w") as f:
        f.write(head)
        for w in extra_wires: f.write(f"  wire {esc(w)};\n")
        for name, (typ, pins) in cells.items():
            f.write(f"  {typ} {esc(name)} (" + ", ".join(f".{p}({esc(n)})" for p, n in pins.items()) + ");\n")
        f.write("endmodule\n")
