"""Direction-model invariants and trace-window regressions."""

from copy import deepcopy
import random
import unittest

from tools.run_predictor_comparison import collect, score
from verif.core.programs import branch, i, jal
from verif.frontend.predictor_model import CounterPredictor, SmallTage, TaggedEntry, fold, models


class CounterTests(unittest.TestCase):
    def test_prediction_precedes_update_and_saturates(self):
        model = CounterPredictor(1)
        self.assertEqual([model.step(0, t) for t in [1, 1, 1, 1, 0, 0, 0, 0]],
                         [False, True, True, True, True, True, False, False])
        self.assertEqual(model.counters, [0])

    def test_against_independent_counter_machine(self):
        rng = random.Random(193)
        stream = [(4*rng.randrange(2048), rng.randrange(2)) for _ in range(2000)]
        for size, bits in ((256, 0), (256, 8), (2048, 8), (2048, 11)):
            table, history = {}, []
            model = CounterPredictor(size, bits)
            for pc, outcome in stream:
                value = sum(bit << n for n, bit in enumerate(reversed(history)))
                index = (pc//4 ^ value) % size
                state = table.get(index, 1)
                self.assertEqual(model.step(pc, outcome), state in (2, 3))
                table[index] = ((0, 0, 1, 2), (1, 2, 3, 3))[outcome][state]
                history = (history+[outcome])[-bits:] if bits else []

    def test_folding_and_upper_history(self):
        self.assertEqual(fold(0b101_011_110, 3), 0b101 ^ 0b011 ^ 0b110)
        model = SmallTage()
        before = model.addresses(0x100)
        model.history = 1 << 31
        after = model.addresses(0x100)
        self.assertEqual([x[:3] for x in before], [x[:3] for x in after])
        self.assertNotEqual(before[0][3], after[0][3])
        self.assertNotEqual(before[1][3], after[1][3])


class TageTests(unittest.TestCase):
    def setUp(self):
        self.model = SmallTage()
        self.pc = 0x100

    def install(self, bank, counter=3, useful=1):
        indices, tags = self.model.addresses(self.pc)
        entry = TaggedEntry(tags[bank], counter, useful, True)
        self.model.tables[bank][indices[bank]] = entry
        return entry

    def test_invalid_and_wrong_tags_do_not_hit(self):
        entry = self.install(3)
        entry.valid = False
        self.assertEqual(self.model.lookup(self.pc).provider, -1)
        entry.valid = True
        entry.tag ^= 1
        self.assertEqual(self.model.lookup(self.pc).provider, -1)
        entry.tag ^= 1
        self.assertEqual(self.model.lookup(self.pc).provider, 3)

    def test_longest_and_alternate_selection(self):
        self.install(0, -4)
        entry = self.install(3, 0, 0)
        result = self.model.lookup(self.pc)
        self.assertEqual((result.provider, result.alternate), (3, 0))
        self.assertFalse(result.prediction)
        self.model.use_alternate = -1
        self.assertTrue(self.model.lookup(self.pc).prediction)
        self.model.use_alternate = 7
        entry.counter = 1
        self.assertTrue(self.model.lookup(self.pc).prediction)

    def test_correct_weak_provider_does_not_allocate_after_alternate_miss(self):
        entry = self.install(0, 0, 0)
        alternate = self.model.base[64]
        self.assertFalse(self.model.step(self.pc, True))
        self.assertEqual((entry.counter, entry.useful, self.model.use_alternate), (1, 1, -1))
        self.assertEqual(self.model.base[64], alternate+1)
        self.assertEqual(sum(e.valid for t in self.model.tables for e in t), 1)

    def test_alternate_correct_trains_chooser_and_provider(self):
        self.model.use_alternate = -1
        entry = self.install(0, 0, 0)
        self.assertTrue(self.model.step(self.pc, False))
        self.assertEqual((entry.counter, entry.useful, self.model.use_alternate), (-1, 0, 0))
        self.assertEqual(sum(e.valid for t in self.model.tables for e in t), 2)

    def test_usefulness_requires_provider_alternate_disagreement(self):
        entry = self.install(3, -4, 2)
        self.model.step(self.pc, False)
        self.assertEqual(entry.useful, 2)
        self.model.history = 0
        entry.counter = 3
        self.model.step(self.pc, False)
        self.assertEqual(entry.useful, 1)

    def test_alternate_training_uses_old_usefulness(self):
        alternate = self.install(0, -4, 1)
        entry = self.install(2, 3, 0)
        self.model.step(self.pc, True)
        self.assertEqual((entry.useful, alternate.counter), (1, -3))

    def test_allocation_uses_prebranch_history_and_weak_direction(self):
        self.model.history = 5
        indices, tags = self.model.addresses(self.pc)
        self.model.step(self.pc, True)
        self.assertEqual(self.model.tables[0][indices[0]], TaggedEntry(tags[0], 0, 0, True))
        self.assertEqual(self.model.history, 11)
        self.assertEqual(sum(e.valid for t in self.model.tables for e in t), 1)

    def test_allocation_replaces_tag_collision_only_when_not_useful(self):
        entry = self.install(0, 3, 1)
        entry.tag ^= 1
        indices, _ = self.model.addresses(self.pc)
        self.model.step(self.pc, True)
        self.assertIs(self.model.tables[0][indices[0]], entry)
        self.assertTrue(self.model.tables[1][indices[1]].valid)
        self.model = SmallTage()
        entry = self.install(0, 3, 0)
        entry.tag ^= 1
        self.model.step(self.pc, True)
        self.assertIsNot(self.model.tables[0][indices[0]], entry)

    def test_blocked_allocation_ages_only_longer_candidates(self):
        provider = self.install(1, -4, 2)
        candidates = [self.install(b, 3, 2) for b in (2, 3)]
        for entry in candidates:
            entry.tag ^= 1
        self.model.step(self.pc, True)
        self.assertEqual([e.useful for e in candidates], [1, 1])
        self.assertEqual(provider.useful, 2)

    def test_longest_provider_miss_does_not_allocate_shorter(self):
        self.install(3, -4, 1)
        self.model.step(self.pc, True)
        self.assertFalse(any(e.valid for t in self.model.tables[:3] for e in t))

    def test_periodic_aging_and_wrap(self):
        self.model.tables[3][0] = TaggedEntry(1, 3, 3, True)
        self.model.age = (1 << self.model.age_bits)-1
        self.model.history = 0xffffffff
        self.model.step(self.pc, False)
        self.assertEqual(self.model.tables[3][0].useful, 1)
        self.assertEqual((self.model.age, self.model.history), (0, 0xfffffffe))

    def test_state_ranges_and_repeatability(self):
        rng = random.Random(47)
        twin = SmallTage()
        for _ in range(3000):
            pc, outcome = 4*rng.randrange(256), rng.randrange(2)
            self.assertEqual(self.model.step(pc, outcome), twin.step(pc, outcome))
        self.assertEqual(self.model.tables, twin.tables)
        for table in self.model.tables:
            for e in table:
                self.assertTrue(0 <= e.tag <= 255 and -4 <= e.counter <= 3 and 0 <= e.useful <= 3)
        self.assertTrue(-8 <= self.model.use_alternate <= 7)

    def test_learns_repeating_direction_pattern(self):
        bimodal = CounterPredictor()
        outcomes = [1, 0] * 100
        tage_misses = sum(self.model.step(0x100, t) != t for t in outcomes)
        base_misses = sum(bimodal.step(0x100, t) != t for t in outcomes)
        self.assertLess(tage_misses, 15)
        self.assertEqual(base_misses, 200)


class TraceTests(unittest.TestCase):
    def test_region_keeps_cold_training_and_excludes_start(self):
        trace = dict(branches=[(0, 0, 1), (1, 0, 1), (2, 0, 0), (3, 0, 1)],
                     instructions=4, region_start_exclusive=0, region_end_inclusive=2, region_instructions=2)
        result = score(trace)
        self.assertEqual(result['region']['branches'], 2)
        self.assertEqual(result['region']['models']['bimodal256']['misses'], 1)
        self.assertEqual(result, score(deepcopy(trace)))

    def test_collect_markers_and_watchdog(self):
        words = [i(1, 0, 3), i(1, 1, -1), branch(1, 0, -4, 1), jal(0, 0)]
        image = b''.join(w.to_bytes(4, 'little') for w in words)
        trace = collect(image, 12, warm=(8, 1, 8, 3), limit=20)
        self.assertEqual(trace['branches'], [(2, 8, 1), (4, 8, 1), (6, 8, 0)])
        self.assertEqual((trace['instructions'], trace['region_instructions']), (8, 4))
        with self.assertRaisesRegex(ValueError, 'terminal'):
            collect(image, 12, limit=2)
        with self.assertRaisesRegex(ValueError, 'markers'):
            collect(image, 12, warm=(8, 4, 12, 1))

    def test_flow_history_convention_for_pc_plus_four(self):
        image = branch(0, 0, 4).to_bytes(4, 'little') + jal(0, 0).to_bytes(4, 'little')
        trace = collect(image, 4)
        self.assertEqual(trace['branches'], [(0, 0, 0)])
        self.assertEqual(trace['pc_plus4_branches'], 1)

    def test_model_storage_and_fresh_state(self):
        first, second = models(), models()
        for name in first:
            first[name].step(0, True)
            self.assertFalse(second[name].step(0, True))
        self.assertEqual(SmallTage().configuration()['table_bits'], 4096)
        self.assertEqual(CounterPredictor(2048).configuration()['table_bits'], 4096)


if __name__ == '__main__':
    unittest.main()
