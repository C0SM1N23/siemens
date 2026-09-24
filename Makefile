# RV32I CPU — build/test entry points. The actual flows live in cpu/debug/sim;
# this just wires them up for one-command runs and for CI.
#
#   make test         assemble + run the CPU Verilator SVA/coverage flow (CI default)
#   make modelsim     CPU/PIC ModelSim regression: 39 runs (needs vsim; local)
#   make soc          SoC ModelSim regression: 34 runs (needs vsim)
#   make soc-sva      SoC lint + SVA/cover run on Verilator
#   make soc-pulp     compare decoder/register interfaces against pulp-platform/axi (network)
#   make riscv-tests  official rv32ui/rv32mi tests (RISC-V GCC, network on first run)
#   make formal       SymbiYosys proofs of the PIC and the fabric, with injected defects
#   make mutations    inject RTL defects one at a time; each must fail its bench (needs vsim)
#   make asm          regenerate program hex + the label-address include
#   make clean        remove build artifacts

SIM    := cpu/debug/sim
SOCSIM := soc/debug/sim
PY     ?= python3

.PHONY: all test verilator modelsim soc soc-sva soc-pulp riscv-tests formal mutations asm clean

all: test

# assemble the test programs -> .hex + _sym.vh (label addresses for the TB)
asm:
	cd $(SIM) && $(PY) isa_reference.py --random-set
	cd $(SIM) && $(PY) pic_reference.py
	cd $(SIM) && $(PY) asm.py program_axi.s  program_axi.hex
	cd $(SIM) && $(PY) asm.py program_dual.s program_dual.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_soc.s    program_soc.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_stress.s program_stress.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_dma_len.s program_dma_len.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_dma_irq.s program_dma_irq.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_dma_ch.s program_dma_ch.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_dma_err.s program_dma_err.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_timer.s program_timer.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_pic_src.s program_pic_src.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_pic_nest.s program_pic_nest.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_pic_esc.s program_pic_esc.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_isolation.s program_isolation.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_dma_fault.s program_dma_fault.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_reset.s program_reset.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_spurious.s program_spurious.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_pic_deep.s program_pic_deep.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_same_addr.s program_same_addr.hex

# SVA + functional-coverage run on Verilator (free, CI-runnable). The script
# exits non-zero if the TB checks or the coverage gate fail.
verilator: asm
	cd $(SIM) && bash run_verilator.sh

test: verilator

# CPU/PIC: 17 benches, 39 runs. See cpu/debug/VERIFICATION.md.
modelsim: asm
	cd $(SIM) && vsim -c -do "do regress.do; quit -f"

# SoC: 23 benches, 34 runs. See soc/docs/VERIFICATION.md.
soc: asm
	cd $(SOCSIM) && vsim -c -do "do regress.do; quit -f"

# Lint the whole SoC with -Wall, then run every SoC bench with the bound SVA
# layer live. ModelSim ASE cannot compile assertions, so this is where the
# fabric's protocol and routing properties are actually checked.
soc-sva: asm
	bash $(SOCSIM)/run_verilator.sh

# Drive the SoC decoder and pulp-platform/axi's axi_lite_demux with one shared
# stimulus and compare what came back. Fetches the upstream sources on the first
# run; they are never vendored into this repository.
soc-pulp:
	cd $(SOCSIM) && bash run_pulp_compare.sh

# rv32ui and rv32mi from riscv-software-src/riscv-tests at a pinned revision,
# at nominal timing and 40% backpressure, with the core's SVA bound.
riscv-tests:
	bash $(SIM)/run_riscv_tests.sh

# PIC, decoder, arbiter and bridge: induction proofs, bounded liveness and
# covers, then each harness against injected defects (needs yosys, sby, z3).
formal:
	bash cpu/debug/formal/run_formal.sh
	bash soc/debug/formal/run_formal.sh

mutations: asm
	$(PY) $(SIM)/mutation_check.py

clean:
	rm -rf $(SIM)/obj_dir $(SIM)/work $(SIM)/cov_annotated
	rm -f  $(SIM)/coverage.dat $(SIM)/*.log $(SIM)/transcript $(SIM)/modelsim.ini
	rm -rf $(SOCSIM)/work $(SOCSIM)/obj_dir
	rm -f  $(SOCSIM)/transcript $(SOCSIM)/modelsim.ini $(SOCSIM)/*.wlf
	rm -f  $(SOCSIM)/build_*.log $(SOCSIM)/run_*.log
	rm -rf $(SIM)/cov $(SOCSIM)/cov $(SIM)/riscv_tests
	rm -rf cpu/debug/formal/*/ soc/debug/formal/*/
	rm -f  cpu/debug/formal/*.log soc/debug/formal/*.log
