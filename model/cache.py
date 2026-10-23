"""Transaction-level reference model of a write-back, write-allocate L1 cache.

No timing: each access completes before the next. Result carries the line traffic
(fill/writeback base addresses) so RTL scoreboards can check it per access.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass


class CacheError(ValueError):
    pass


@dataclass(frozen=True)
class Geometry:
    size_bytes: int
    ways: int
    line_bytes: int

    def __post_init__(self):
        for key in ("size_bytes", "ways", "line_bytes"):
            value = getattr(self, key)
            if type(value) is not int or value < 1 or value & (value - 1):
                raise CacheError(f"geometry.{key}: {value!r} must be a power of two")
        if self.line_bytes < 4 or self.size_bytes < self.ways * self.line_bytes:
            raise CacheError(f"geometry.shape: {self}")

    @property
    def sets(self) -> int:
        return self.size_bytes // (self.ways * self.line_bytes)

    def split(self, addr: int) -> tuple[int, int, int]:
        """Return (tag, index, offset)."""
        line = addr // self.line_bytes
        return line // self.sets, line % self.sets, addr % self.line_bytes


class Memory:
    """Sparse line-granular backing memory; unwritten bytes read as zero."""

    def __init__(self, line_bytes: int):
        self.line_bytes = line_bytes
        self.lines: dict[int, bytearray] = {}
        self.log: list[tuple] = []

    def line(self, base: int) -> bytearray:
        return self.lines.setdefault(base, bytearray(self.line_bytes))

    def fill(self, base: int) -> bytes:
        self.log.append(("fill", base))
        return bytes(self.line(base))

    def writeback(self, base: int, data: bytes) -> None:
        self.log.append(("writeback", base, bytes(data)))
        self.line(base)[:] = data

    def load(self, addr: int, size: int) -> int:
        """Direct read of backing memory, bypassing any cache."""
        base = addr - addr % self.line_bytes
        return int.from_bytes(self.line(base)[addr - base:addr - base + size], "little")


@dataclass
class Way:
    tag: int = 0
    valid: bool = False
    dirty: bool = False
    data: bytearray | None = None


@dataclass(frozen=True)
class Result:
    hit: bool
    value: int = 0                    # loads only
    victim_dirty: bool = False        # a dirty line was evicted by this access
    fill: int | None = None           # base of the line fetched on a miss
    writeback: int | None = None      # base of the dirty victim written back


class Cache:
    def __init__(self, geometry: Geometry, memory: Memory, writable: bool = True):
        if memory.line_bytes != geometry.line_bytes:
            raise CacheError("memory.line_bytes differs from geometry")
        self.g, self.memory, self.writable = geometry, memory, writable
        self.sets = [[Way() for _ in range(geometry.ways)] for _ in range(geometry.sets)]
        # Per set, way indices from least to most recently used.
        self.lru = [list(range(geometry.ways)) for _ in range(geometry.sets)]
        self.stats: Counter = Counter()

    def _touch(self, index: int, way: int) -> None:
        self.lru[index].remove(way)
        self.lru[index].append(way)

    def _check(self, addr: int, size: int) -> None:
        if type(size) is not int or size not in (1, 2, 4) or type(addr) is not int or addr < 0 or addr % size:
            raise CacheError(f"access.alignment: addr={addr!r} size={size!r}")

    def _base(self, tag: int, index: int) -> int:
        return (tag * self.g.sets + index) * self.g.line_bytes

    def _lookup(self, addr: int, kind: str) -> tuple[Way, int, Result]:
        """Return the way holding addr (filling on a miss), its offset, and the traffic."""
        tag, index, offset = self.g.split(addr)
        ways = self.sets[index]
        for n, way in enumerate(ways):
            if way.valid and way.tag == tag:
                self._touch(index, n)
                self.stats[f"{kind}_hit"] += 1
                return way, offset, Result(True)
        self.stats[f"{kind}_miss"] += 1
        victim = next((n for n, w in enumerate(ways) if not w.valid), self.lru[index][0])
        way, written = ways[victim], None
        if way.valid:
            self.stats["eviction"] += 1
            if way.dirty:
                self.stats["writeback"] += 1
                written = self._base(way.tag, index)
                self.memory.writeback(written, way.data)
        base = self._base(tag, index)
        way.tag, way.valid, way.dirty = tag, True, False
        way.data = bytearray(self.memory.fill(base))
        self._touch(index, victim)
        return way, offset, Result(False, victim_dirty=written is not None, fill=base, writeback=written)

    def load(self, addr: int, size: int) -> Result:
        self._check(addr, size)
        way, offset, result = self._lookup(addr, "load")
        return Result(result.hit, int.from_bytes(way.data[offset:offset + size], "little"),
                      result.victim_dirty, result.fill, result.writeback)

    def store(self, addr: int, size: int, value: int) -> Result:
        if not self.writable:
            raise CacheError("access.store_to_read_only_cache")
        self._check(addr, size)
        if type(value) is not int or not 0 <= value < 1 << 8 * size:
            raise CacheError(f"access.store_value: {value!r}")
        way, offset, result = self._lookup(addr, "store")
        way.data[offset:offset + size] = value.to_bytes(size, "little")
        way.dirty = True
        return result

    def flush(self) -> None:
        """Clean every dirty line; lines stay valid."""
        for index, ways in enumerate(self.sets):
            for way in ways:
                if way.valid and way.dirty:
                    self.stats["writeback"] += 1
                    self.memory.writeback(self._base(way.tag, index), way.data)
                    way.dirty = False

    def invalidate(self) -> None:
        for ways in self.sets:
            for way in ways:
                way.valid = way.dirty = False
