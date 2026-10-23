import random
import unittest

from model.cache import Cache, CacheError, Geometry, Memory

SMALL = Geometry(128, 2, 32)  # 2 sets: line bases 0x00, 0x40, 0x80 share set 0


def cache(geometry=SMALL, writable=True):
    return Cache(geometry, Memory(geometry.line_bytes), writable)


class CacheModelTest(unittest.TestCase):
    def test_geometry_split(self):
        g = Geometry(1024, 2, 32)
        self.assertEqual(g.sets, 16)
        self.assertEqual(g.split(0x1234), (0x1234 // 32 // 16, 0x1234 // 32 % 16, 0x14))

    def test_miss_then_hit_and_lru_victim(self):
        c = cache()
        c.memory.line(0x40)[0:4] = (0x11223344).to_bytes(4, "little")
        first = c.load(0x40, 4)
        self.assertEqual((first.hit, first.value, first.fill, first.writeback), (False, 0x11223344, 0x40, None))
        self.assertTrue(c.load(0x42, 2).hit)
        c.load(0x00, 4)          # set 0 now holds 0x40 (LRU) and 0x00
        c.load(0x40, 1)          # 0x00 becomes LRU
        c.load(0x80, 4)          # evicts 0x00
        self.assertTrue(c.load(0x40, 4).hit)
        self.assertFalse(c.load(0x00, 4).hit)
        self.assertNotIn("writeback", c.stats)
        self.assertEqual(c.stats["eviction"], 2)

    def test_dirty_victim_written_back_before_fill(self):
        c = cache()
        self.assertFalse(c.store(0x04, 4, 0xdeadbeef).hit)   # write-allocate
        self.assertEqual(c.memory.load(0x04, 4), 0)
        c.load(0x40, 4)
        r = c.load(0x80, 4)                                  # evicts dirty 0x00
        self.assertEqual((r.victim_dirty, r.fill, r.writeback), (True, 0x80, 0x00))
        self.assertEqual(c.memory.log[-2][:2], ("writeback", 0x00))
        self.assertEqual(c.memory.log[-1], ("fill", 0x80))
        self.assertEqual(c.memory.load(0x04, 4), 0xdeadbeef)
        self.assertEqual(c.load(0x04, 4).value, 0xdeadbeef)

    def test_flush_keeps_lines_valid(self):
        c = cache()
        c.store(0x00, 4, 7)
        c.flush()
        self.assertEqual(c.memory.load(0x00, 4), 7)
        self.assertTrue(c.load(0x00, 4).hit)
        c.flush()
        self.assertEqual(c.stats["writeback"], 1)            # clean line not written again

    def test_invalidate_drops_all_lines(self):
        c = cache(writable=False)
        c.load(0x00, 4)
        c.load(0x40, 4)
        c.invalidate()
        r = c.load(0x00, 4)
        self.assertEqual((r.hit, r.victim_dirty, r.fill), (False, False, 0x00))
        self.assertFalse(c.load(0x40, 4).hit)

    def test_illegal_accesses(self):
        c = cache()
        for addr, size in ((1, 2), (2, 4), (0, 3), (-4, 4), (0, 4.0), (0, True), (0.0, 4)):
            with self.subTest(addr=addr, size=size), self.assertRaisesRegex(CacheError, "access.alignment"):
                c.load(addr, size)
            with self.subTest(store=True, addr=addr, size=size), self.assertRaisesRegex(CacheError, "access.alignment"):
                c.store(addr, size, 0)
        self.assertEqual((c.memory.log, dict(c.stats)), ([], {}))   # rejected before any lookup
        with self.assertRaisesRegex(CacheError, "access.store_value"):
            c.store(0, 1, 0x100)
        with self.assertRaisesRegex(CacheError, "store_to_read_only"):
            cache(writable=False).store(0, 4, 0)
        with self.assertRaisesRegex(CacheError, "geometry.size_bytes"):
            Geometry(96, 2, 32)

    def test_random_against_flat_memory_and_lru_oracle(self):
        for geometry in (SMALL, Geometry(256, 1, 16), Geometry(512, 4, 32), Geometry(1024, 2, 32)):
            for seed in (1, 42, 20261004):
                with self.subTest(geometry=geometry, seed=seed):
                    self._random(geometry, random.Random(seed))

    def _random(self, g, rng):
        c, flat = cache(g), {}
        recent = [[] for _ in range(g.sets)]  # per set, line numbers oldest first
        span = g.size_bytes * 3
        for _ in range(3000):
            size = rng.choice((1, 2, 4))
            addr = rng.randrange(0, span, size)
            line = addr // g.line_bytes
            hit = line in recent[line % g.sets]
            if hit:
                recent[line % g.sets].remove(line)
            recent[line % g.sets] = (recent[line % g.sets] + [line])[-g.ways:]
            if rng.random() < 0.4:
                value = rng.getrandbits(8 * size)
                result = c.store(addr, size, value)
                flat.update({addr + n: value >> 8 * n & 0xff for n in range(size)})
            else:
                result = c.load(addr, size)
                expect = sum(flat.get(addr + n, 0) << 8 * n for n in range(size))
                self.assertEqual(result.value, expect)
            self.assertEqual(result.hit, hit)
            self.assertEqual(result.fill is None, hit)
        dirty = sum(w.valid and w.dirty for ways in c.sets for w in ways)
        before = c.stats["writeback"]
        c.flush()
        self.assertEqual(c.stats["writeback"], before + dirty)
        self.assertEqual(c.stats["writeback"], sum(1 for e in c.memory.log if e[0] == "writeback"))
        for addr, byte in flat.items():
            self.assertEqual(c.memory.load(addr, 1), byte)
        fills = sum(1 for e in c.memory.log if e[0] == "fill")
        self.assertEqual(fills, c.stats["load_miss"] + c.stats["store_miss"])


if __name__ == "__main__":
    unittest.main()
