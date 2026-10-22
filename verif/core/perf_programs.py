"""Trap-free programs for perf-mode CPI measurement. Each ends in a self-loop at its terminal PC."""
from verif.core.programs import i, r, store, branch, jal, constant

ALIGNED, SPLIT = 0x40, 0x58  # loop tops: start of a 32-byte fetch line, and 24 bytes into one


def image(words):
    return b''.join(w.to_bytes(4, 'little') for w in words)


def straight():
    """Four independent addi chains, no branches: exercises dual retirement and the cold window."""
    words = [i(reg, 0, reg) for reg in range(1, 5)]
    words += [i(1 + n % 4, 1 + n % 4, 1) for n in range(64)]
    terminal = 4*len(words)
    return dict(image=image(words + [jal(0, 0)]), terminal=terminal)


def loop_memory(iterations=32):
    """Load/add/store loop over a resident array; the warm window spans loop-branch occurrences 4..28."""
    words = constant(1, 0x8000) + [i(2, 0, iterations), i(3, 0, 0)]
    top = 4*len(words)
    words += [i(4, 1, 0, 2, 3), i(3, 3, 1), i(4, 4, 7), store(1, 4, 0, 2), i(1, 1, 4), i(2, 2, -1)]
    loop = 4*len(words)
    words += [branch(2, 0, top - loop, 1)]
    terminal = 4*len(words)
    return dict(image=image(words + [jal(0, 0)]), terminal=terminal, warm=(loop, 4, loop, 28))


def loop(body, top, iterations=32, tail=()):
    """Counted loop (x2) whose first body word sits at the fixed PC top; x1 = 0x8000, x3..x6 = 0.
    tail words follow the terminal self-loop. The warm window spans loop-branch occurrences 4..28."""
    words = constant(1, 0x8000) + [i(2, 0, iterations)] + [i(reg, 0, 0) for reg in range(3, 7)]
    assert 4*len(words) <= top
    words += [i(0, 0, 0)] * (top//4 - len(words))
    words += body
    end = 4*len(words)
    words += [branch(2, 0, top - end, 1)]
    terminal = 4*len(words)
    return dict(image=image(words + [jal(0, 0)] + list(tail)), terminal=terminal, warm=(end, 4, end, 28))


ALU = [i(4, 0, 0), i(3, 3, 1), i(4, 4, 7), i(5, 0, 1), i(1, 1, 4), i(2, 2, -1)]
MEMORY = [i(4, 1, 0, 2, 3), i(3, 3, 1), i(4, 4, 7), store(1, 4, 0, 2), i(1, 1, 4), i(2, 2, -1)]


def branches():
    """Taken forward beq, call and return each iteration; the leaf sits after the terminal."""
    body = lambda leaf: [branch(0, 0, 8), i(5, 5, 1), jal(1, leaf - (ALIGNED + 8)), i(2, 2, -1)]
    leaf = ALIGNED + 4*(len(body(0)) + 2)
    return loop(body(leaf), ALIGNED, tail=[i(6, 6, 1), i(0, 1, 0, 0, 0x67)])


PROGRAMS = {
    'straight': straight,
    'loop_memory': loop_memory,
    'alu_aligned': lambda: loop(ALU, ALIGNED),
    'alu_split': lambda: loop(ALU, SPLIT),
    'dependency': lambda: loop([i(3, 3, 1)]*5 + [i(2, 2, -1)], ALIGNED),
    'branches': branches,
    'load_hit': lambda: loop([i(4, 1, 0, 2, 3), i(5, 1, 4, 2, 3), r(6, 4, 5), i(3, 3, 1), i(2, 2, -1)], ALIGNED),
    'store_hit': lambda: loop([store(1, 3, 0, 2), store(1, 3, 4, 2), i(3, 3, 1), i(2, 2, -1)], ALIGNED),
    'forward': lambda: loop([store(1, 3, 0, 2), i(4, 1, 0, 2, 3), i(3, 3, 1), i(2, 2, -1)], ALIGNED),
    'memory_aligned': lambda: loop(MEMORY, ALIGNED),
    'memory_split': lambda: loop(MEMORY, SPLIT),
}
