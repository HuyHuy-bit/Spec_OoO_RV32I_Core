"""Sequential, immediate-update direction models; no speculative execution or cycle timing."""

from dataclasses import dataclass


def saturate(value, taken, low, high):
    return min(high, value + 1) if taken else max(low, value - 1)


def fold(value, width):
    result = 0
    mask = (1 << width) - 1
    while value:
        result ^= value & mask
        value >>= width
    return result


class CounterPredictor:
    def __init__(self, entries=256, history_bits=0):
        if entries < 1 or entries & (entries - 1) or history_bits < 0:
            raise ValueError('invalid counter geometry')
        self.entries = entries
        self.history_bits = history_bits
        self.history = 0
        self.counters = [1] * entries

    def step(self, pc, taken):
        index = ((pc >> 2) ^ self.history) & (self.entries - 1)
        prediction = self.counters[index] >= 2
        self.counters[index] = saturate(self.counters[index], taken, 0, 3)
        self.history = ((self.history << 1) | taken) & ((1 << self.history_bits) - 1)
        return prediction

    def configuration(self):
        return dict(kind='gshare' if self.history_bits else 'bimodal', entries=self.entries,
                    history_bits=self.history_bits, table_bits=2*self.entries,
                    control_bits=self.history_bits, initial_counter=1)


@dataclass(slots=True)
class TaggedEntry:
    tag: int = 0
    counter: int = -1
    useful: int = 0
    valid: bool = False


@dataclass(frozen=True, slots=True)
class Lookup:
    base_index: int
    indices: tuple
    tags: tuple
    provider: int
    alternate: int
    provider_prediction: bool
    alternate_prediction: bool
    weak_new: bool
    useful: int
    prediction: bool


class SmallTage:
    """Fixed experimental TAGE variant; policies and hashes are specified in README.md."""

    histories = (4, 8, 16, 32)
    entries = 64
    age_bits = 18

    def __init__(self):
        self.base = [1] * 256
        self.tables = [[TaggedEntry() for _ in range(self.entries)] for _ in self.histories]
        self.history = 0
        self.use_alternate = 0
        self.age = 0

    def addresses(self, pc):
        word = pc >> 2
        histories = [self.history & ((1 << length) - 1) for length in self.histories]
        indices = tuple((word ^ (word >> 6) ^ fold(h, 6)) & 63 for h in histories)
        tags = tuple((word ^ (word >> 8) ^ fold(h, 8) ^ (fold(h, 7) << 1)) & 255 for h in histories)
        return indices, tags

    def lookup(self, pc):
        indices, tags = self.addresses(pc)
        hits = [bank for bank in range(4) if self.tables[bank][indices[bank]].valid
                and self.tables[bank][indices[bank]].tag == tags[bank]]
        provider = hits[-1] if hits else -1
        alternate = hits[-2] if len(hits) > 1 else -1
        base_index = (pc >> 2) & 255
        alternate_prediction = (self.tables[alternate][indices[alternate]].counter >= 0
                                 if alternate >= 0 else self.base[base_index] >= 2)
        if provider < 0:
            return Lookup(base_index, indices, tags, -1, -1, alternate_prediction,
                          alternate_prediction, False, 0, alternate_prediction)
        entry = self.tables[provider][indices[provider]]
        provider_prediction = entry.counter >= 0
        weak_new = entry.useful == 0 and entry.counter in (-1, 0)
        prediction = alternate_prediction if weak_new and self.use_alternate >= 0 else provider_prediction
        return Lookup(base_index, indices, tags, provider, alternate, provider_prediction,
                      alternate_prediction, weak_new, entry.useful, prediction)

    def step(self, pc, taken):
        result = self.lookup(pc)
        provider = result.provider
        if provider < 0:
            self.base[result.base_index] = saturate(self.base[result.base_index], taken, 0, 3)
        else:
            entry = self.tables[provider][result.indices[provider]]
            if result.weak_new and result.provider_prediction != result.alternate_prediction:
                self.use_alternate = saturate(self.use_alternate, result.alternate_prediction == taken, -8, 7)
            entry.counter = saturate(entry.counter, taken, -4, 3)
            if result.provider_prediction != result.alternate_prediction:
                entry.useful = saturate(entry.useful, result.provider_prediction == taken, 0, 3)
            if result.useful == 0:
                if result.alternate < 0:
                    self.base[result.base_index] = saturate(self.base[result.base_index], taken, 0, 3)
                else:
                    alternate = self.tables[result.alternate][result.indices[result.alternate]]
                    alternate.counter = saturate(alternate.counter, taken, -4, 3)

        # a correct new provider should mature instead of causing another allocation.
        allocate = result.prediction != taken and not (result.weak_new and result.provider_prediction == taken)
        if allocate:
            candidates = [self.tables[b][result.indices[b]] for b in range(provider + 1, 4)]
            chosen = next((b for b in range(provider + 1, 4)
                           if not self.tables[b][result.indices[b]].valid
                           or self.tables[b][result.indices[b]].useful == 0), None)
            if chosen is not None:
                self.tables[chosen][result.indices[chosen]] = TaggedEntry(result.tags[chosen], 0 if taken else -1, 0, True)
            else:
                for entry in candidates:
                    entry.useful = max(0, entry.useful - 1)

        self.age = (self.age + 1) & ((1 << self.age_bits) - 1)
        if self.age == 0:
            for table in self.tables:
                for entry in table:
                    entry.useful >>= 1
        self.history = ((self.history << 1) | taken) & 0xffffffff
        return result.prediction

    def configuration(self):
        return dict(kind='small_tage_v1', base_entries=256, tagged_entries=64,
                    histories=list(self.histories), tag_bits=8, counter_bits=3, useful_bits=2,
                    valid_bits=1, table_bits=256*2 + 4*64*(8+3+2+1), control_bits=32+4+self.age_bits,
                    chooser_initial=0, chooser_range=[-8, 7], age_period=1 << self.age_bits,
                    allocation='shortest eligible longer bank; one entry',
                    usefulness='raw provider correctness when provider and alternate disagree')


def models():
    return {'gshare256_h8': CounterPredictor(256, 8), 'bimodal256': CounterPredictor(256),
            'gshare2048_h8': CounterPredictor(2048, 8), 'gshare2048_h11': CounterPredictor(2048, 11),
            'bimodal2048': CounterPredictor(2048), 'tage512': SmallTage()}
