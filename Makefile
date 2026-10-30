PROFILE ?= s0-host
LOCKSTEP_SPIKE ?= ../riscv-isa-sim/build/spike
ACT4_CHECKOUT ?= out/deps/riscv-arch-test-4.0.0
ACT4_SAIL ?= out/deps/sail-riscv-0.10/bin/sail_riscv_sim
OSS_CAD_SUITE ?= $(HOME)/tools/oss-cad-suite-20260905/oss-cad-suite

.PHONY: doctor platform-generate platform-check event-generate event-check memory-protocol-generate memory-protocol-check lockstep-check act4-check act4-upstream-check prf-check a1-probe-check a1-synth-check check-fast check nightly reference-check
.PHONY: a1-timing-fetch a1-timing-check chip-timing-check chip-timing-repaired chip-librelane
.PHONY: act4-tools act4-fetched-check
.PHONY: sail-log-check sail-fetched-differential-check spike-fetched-differential-check
.PHONY: assert-portability
.PHONY: execution-backend-check fetch-unit-check cpu-top-check frontend-faults-check
.PHONY: system-core-check
.PHONY: unit-runner-check
.PHONY: head-trap-core-check
.PHONY: csr-unit-check

doctor:
	@python3 tools/doctor.py --lock config/toolchain.lock --profile "$(PROFILE)"

assert-portability:
	@python3 tools/run_assert_portability.py --suite "$(OSS_CAD_SUITE)"

.PHONY: committed-store-check
committed-store-check:
	@python3 tools/run_unit.py committed_store --suite "$(OSS_CAD_SUITE)"

.PHONY: cpi-check
cpi-check:
	@python3 tools/run_cpi.py

.PHONY: coremark-check
coremark-check:
	@python3 tools/run_coremark.py

.PHONY: memory-core-check
memory-core-check:
	@python3 tools/run_unit.py memory_core --suite "$(OSS_CAD_SUITE)"

system-core-check:
	@python3 tools/run_unit.py system_core --suite "$(OSS_CAD_SUITE)"

unit-runner-check:
	@python3 -m unittest -v tests/test_unit_runner.py

head-trap-core-check:
	@python3 tools/run_unit.py head_trap_core --suite "$(OSS_CAD_SUITE)"

csr-unit-check:
	@python3 tools/run_unit.py csr_unit --suite "$(OSS_CAD_SUITE)"

frontend-faults-check:
	@python3 tools/run_unit.py frontend_faults --suite "$(OSS_CAD_SUITE)"

cpu-top-check:
	@python3 tools/run_unit.py cpu_top --suite "$(OSS_CAD_SUITE)"

fetch-unit-check:
	@python3 tools/run_unit.py fetch_unit --suite "$(OSS_CAD_SUITE)"
	@python3 tools/run_unit.py fetch_unit_icache --suite "$(OSS_CAD_SUITE)"

execution-backend-check:
	@python3 tools/run_unit.py execution_backend --suite "$(OSS_CAD_SUITE)"

platform-generate:
	@python3 tools/gen_platform.py --input config/platform.yaml --write

platform-check:
	@python3 tools/gen_platform.py --input config/platform.yaml --check
	@python3 -m unittest -v tests/test_platform.py

event-generate:
	@python3 tools/gen_commit_event.py --input config/commit_event.yaml --write

event-check:
	@python3 tools/gen_commit_event.py --input config/commit_event.yaml --check
	@python3 -m unittest -v tests/test_commit_event.py

memory-protocol-generate:
	@python3 tools/gen_memory_protocol.py --input config/memory_protocol.yaml --write

memory-protocol-check:
	@python3 tools/gen_memory_protocol.py --input config/memory_protocol.yaml --check
	@python3 -m unittest -v tests/test_memory_protocol.py

lockstep-check:
	@python3 -m unittest -v tests/test_lockstep.py
	@python3 tools/run_lockstep_smoke.py --spike "$(LOCKSTEP_SPIKE)"

act4-check:
	@python3 tools/check_act4.py
	@python3 -m unittest -v tests/test_act4_elf.py

act4-tools:
	@python3 tools/act4_tools.py --checkout "$(ACT4_CHECKOUT)"

act4-fetched-check:
	@python3 tools/run_act4_core.py --checkout "$(ACT4_CHECKOUT)" --sail "$(ACT4_SAIL)"

act4-upstream-check:
	@python3 tools/check_act4.py --checkout "$(ACT4_CHECKOUT)" --sail "$(ACT4_SAIL)"

prf-check:
	@python3 tools/run_prf_check.py

a1-probe-check:
	@python3 tools/run_a1_probe.py

a1-synth-check:
	@python3 tools/run_a1_probe.py --synth --suite "$(OSS_CAD_SUITE)"

a1-timing-fetch:
	@python3 tools/fetch_a1_timing.py

a1-timing-check:
	@python3 tools/run_a1_timing.py --suite "$(OSS_CAD_SUITE)"

chip-timing-check:
	@python3 tools/run_chip_timing.py --suite "$(OSS_CAD_SUITE)" $(if $(PERIOD),--period $(PERIOD)) $(if $(ABC_PERIOD),--abc-period $(ABC_PERIOD))

# logic-depth metric: emulated fanout repair of chip-timing-check's netlist, library and 10x wire load
chip-timing-repaired:
	@python3 tools/run_chip_timing_repaired.py $(if $(TAG),--tag $(TAG)) $(if $(CUT),--cut $(CUT))

chip-librelane:
	@python3 tools/run_chip_librelane.py $(if $(TO),--to $(TO)) $(if $(FROM),--from $(FROM)) $(if $(STATE),--state $(STATE)) $(if $(TAG),--tag $(TAG)) $(if $(PERIOD),--period $(PERIOD))

.PHONY: branch-predictor-check
branch-predictor-check:
	@verilator --lint-only -Wall rtl/frontend/branch_predictor.sv
	@python3 -m unittest -v tests/test_branch_predictor_rtl.py

.PHONY: l1-icache-check
l1-icache-check:
	@verilator --lint-only -Wall --top-module l1_icache config/fetch_unit.vlt rtl/generated/memory_protocol_pkg.sv rtl/memory/l1_cache_array.sv rtl/frontend/l1_icache.sv
	@python3 -m unittest -v tests/test_l1_icache_rtl.py

.PHONY: tage-predictor-check
tage-predictor-check:
	@verilator --lint-only -Wall rtl/frontend/tage_predictor.sv
	@python3 -m unittest -v tests/test_tage_predictor_rtl.py tests/test_tage_integration_rtl.py

.PHONY: load-store-unit-check
load-store-unit-check:
	@python3 -m unittest -v tests/test_load_store_unit_rtl.py

.PHONY: load-store-queue-random-check
load-store-queue-random-check:
	@python3 -m unittest -v tests/test_load_store_queue_rtl.py

sail-log-check:
	@python3 -m unittest -v tests/test_sail_log.py

sail-fetched-differential-check:
	@python3 tools/run_sail_differential.py --sail "$(ACT4_SAIL)"

spike-fetched-differential-check:
	@python3 tools/run_sail_differential.py --reference spike --spike "$(LOCKSTEP_SPIKE)"

check-fast: branch-predictor-check load-store-unit-check load-store-queue-random-check unit-runner-check platform-check event-check memory-protocol-check lockstep-check act4-check prf-check a1-probe-check sail-log-check
	@python3 tools/check_s0.py
	@git diff --check

check: doctor check-fast

nightly: check reference-check

reference-check:
	@$(MAKE) --no-print-directory -C verif/reference/rv32i check

.PHONY: early-load-core-check
early-load-core-check:
	@python3 tools/run_sail_differential.py --config early_load_core --sail "$(ACT4_SAIL)"

.PHONY: fetched-core-store-check
fetched-core-store-check:
	@python3 -m unittest -v tests/test_fetched_core_store_check.py

# Subsystem gates, ordered like the pipeline. check-all runs every one (hours); check stays the quick tier.
.PHONY: l1-cache-array-check
l1-cache-array-check:
	@verilator --lint-only -Wall rtl/memory/l1_cache_array.sv
	@python3 -m unittest -v tests/test_l1_cache_array_rtl.py

.PHONY: l1-dcache-check
l1-dcache-check:
	@verilator --lint-only -Wall --top-module l1_dcache config/fetch_unit.vlt rtl/generated/memory_protocol_pkg.sv rtl/memory/l1_cache_array.sv rtl/memory/l1_dcache.sv
	@python3 -m unittest -v tests/test_l1_dcache_rtl.py

.PHONY: store-buffer-check
store-buffer-check:
	@verilator --lint-only -Wall rtl/memory/store_buffer.sv
	@python3 -m unittest -v tests/test_store_buffer_rtl.py

.PHONY: cache-array-timing-check
cache-array-timing-check:
	@python3 tools/run_chip_timing.py --top l1_cache_array --sources-config l1_cache_array --suite "$(OSS_CAD_SUITE)"
	@python3 tools/run_chip_timing.py --top l1_hit_path_probe --sources-config l1_hit_path_probe --suite "$(OSS_CAD_SUITE)"

.PHONY: frontend-check backend-check execute-check memory-check system-check core-check check-all
frontend-check: branch-predictor-check tage-predictor-check l1-icache-check fetch-unit-check
backend-check: prf-check
execute-check: execution-backend-check
memory-check: l1-cache-array-check l1-dcache-check store-buffer-check load-store-unit-check load-store-queue-random-check committed-store-check
system-check: csr-unit-check
core-check: cpu-top-check frontend-faults-check head-trap-core-check system-core-check memory-core-check act4-fetched-check fetched-core-store-check sail-fetched-differential-check spike-fetched-differential-check early-load-core-check
check-all: check frontend-check backend-check execute-check memory-check system-check core-check
