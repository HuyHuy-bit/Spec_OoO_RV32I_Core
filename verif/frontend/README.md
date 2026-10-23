# Direction predictor comparison

Run `python3 tools/run_predictor_comparison.py` after building CoreMark with
`make coremark-check`. Run the model regressions with
`python3 -m unittest discover -s tests -p test_predictor_model.py`.
The runner reads the existing CoreMark ELF/binary without rebuilding or changing
the CPI receipt. `--warmup N` selects the scoring window; results are never cached.
The output defaults to ignored `evidence/predictor_comparison/receipt.json`.

## Measurement contract

The ELF must reproduce the raw binary through objcopy. The interpreter must reach
the terminal without trapping and CoreMark must print its CRC validation message.
The iteration count comes from `seed4_volatile` in that binary. The branch stream
contains every committed conditional branch, in architectural order. Each model
predicts with its old state, trains immediately, then shifts the actual outcome.
Outcome means `pc_after != pc_before + 4`, matching current RTL retirement history.
The receipt counts branches with a +4 immediate explicitly; the known RTL
direction-versus-flow recovery edge case is not simulated here.

All models start cold and train on the entire program. The region starts after
the `(2 * warmup + 1)`th `core_bench_list` entry and ends at the first `stop_time`
entry, inclusive. These are instruction-order boundaries, not the CPI bench's
whole-cycle boundaries; co-retiring instructions can make counts differ.
Counters include all-program and region instruction/branch counts, misses, MPKI,
and per-PC miss counts. Every replay repeats with fresh models and must agree.
The receipt binds the inputs, binary, ELF and branch stream by SHA-256; the branch
stream hash encodes `(instruction_order, pc, outcome)` as little-endian `<IIB>`.

This is a policy comparison, not cycle-accurate RTL simulation. It omits wrong-path
history, delayed training, prediction latency, targets, and recovery bubbles. It
does not establish CPI, timing, area, or performance on other workload inputs.

## Fixed models

| Model | Counter/table bits | History/control bits |
|---|---:|---:|
| gshare256_h8 | 512 | 8 |
| bimodal256 | 512 | 0 |
| gshare2048_h8 | 4096 | 8 |
| gshare2048_h11 | 4096 | 11 |
| bimodal2048 | 4096 | 0 |
| tage512 | 4096 | 54 |

The larger baselines control for table storage, not total silicon cost or ports.
The gshare models index `(pc >> 2) XOR history`, masked to table size. Bimodal
omits history. All two-bit counters start at weak not-taken (1).

`tage512` is an experimental TAGE-style model, not a reproduction of a published
configuration. It has a 256-entry two-bit bimodal base and four 64-entry tagged
banks with history lengths 4, 8, 16 and 32. Each tagged entry stores valid (1), tag
(8), signed prediction counter (3), and usefulness (2) bits. The control budget is
32 history bits, a four-bit alternate chooser and an 18-bit aging counter.
There is no path history, loop predictor, statistical corrector, or random state.

For each bank, let `w = pc >> 2` and `h` be the low history-length bits of history.
`fold(x, k)` XORs the consecutive k-bit chunks of x. Lookup uses:

```
index = (w XOR (w >> 6) XOR fold(h, 6)) AND 63
tag   = (w XOR (w >> 8) XOR fold(h, 8) XOR (fold(h, 7) << 1)) AND 255
```

The longest valid tag match is the provider. The next-longest match is the
alternate, falling back to the base. A signed counter >= 0 predicts taken. A
provider is weak/new when usefulness is zero and its counter is -1 or 0. It uses
the alternate while the global signed chooser is >= 0; the chooser starts at 0.
On weak/new disagreement, alternate correctness increments the chooser toward 7;
otherwise it decrements toward -8.

The provider counter always trains. When raw provider and alternate predictions
disagree, raw provider correctness increments usefulness toward 3, otherwise
decrements it toward 0. This also applies when the alternate was selected. The
alternate counter trains when the provider's *pre-update* usefulness was zero.
With no provider, only the base trains before allocation.

A final misprediction allocates one entry above the provider, except when a
weak/new provider was correct and the alternate caused the miss. Choose the
shortest longer bank whose indexed entry is invalid or has usefulness zero.
Set its tag, valid, weak actual direction (0 for taken, -1 otherwise), and
usefulness zero. If every longer candidate is useful, decrement those candidates'
usefulness and defer allocation. No shorter bank is allocated. Every 2^18
conditional updates, halve all usefulness counters after that update. Prediction,
training and allocation indices all use the same pre-branch history.

Shortest-eligible allocation and the single chooser are deliberate simplifications.
One fixed configuration cannot establish the merit of the entire TAGE family.
The design basis is [Seznec and Michaud's TAGE paper](https://jilp.org/vol8/v8paper1.pdf).
The [gem5 TAGE implementation](https://gem5.googlesource.com/public/gem5/+/a40950a5c97d484b30922fa60091e04e9efd2a99/src/cpu/pred/tage_base.cc)
is a reference for alternate selection, allocation suppression and usefulness aging;
its hashing, allocation, and update policies are not reproduced here.
