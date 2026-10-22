# Speculative Out-of-Order RV32I Core

A two-wide, speculative, out-of-order RISC-V CPU core (RV32I + Zicsr + Zifencei,
machine mode) in SystemVerilog. It fetches and decodes two instructions per
cycle, predicts branches, renames registers, executes out of order, and retires
in order through a reorder buffer, with precise traps and a load/store queue.

This is the core-only fork of a larger project that also has L1 caches and the
memory system; I plan to finish that one later. This fork drops them to keep
physical implementation light.
