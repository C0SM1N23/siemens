# RV32I CPU — build/test entry points. The actual flows live in cpu/debug/sim;
# this just wires them up for one-command runs and for CI.
#
#   make test       assemble + run the Verilator SVA/coverage flow (CI default)
#   make modelsim   full 14-run ModelSim CPU regression (needs vsim; local)
#   make soc        SoC regression: 9 runs over four bus timings (needs vsim)
#   make soc-sva    SoC lint + SVA assertion run on Verilator
#   make asm        regenerate program hex + the label-address include
#   make clean      remove build artifacts

SIM    := cpu/debug/sim
SOCSIM := soc/debug/sim
PY     ?= python3

.PHONY: all test verilator modelsim soc soc-sva asm clean

all: test

# assemble the test programs -> .hex + _sym.vh (label addresses for the TB)
asm:
	cd $(SIM) && $(PY) asm.py program_axi.s  program_axi.hex
	cd $(SIM) && $(PY) asm.py program_dual.s program_dual.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_soc.s    program_soc.hex
	cd $(SOCSIM) && $(PY) ../../../cpu/debug/sim/asm.py program_stress.s program_stress.hex

# SVA + functional-coverage run on Verilator (free, CI-runnable). The script
# exits non-zero if the TB checks or the coverage gate fail.
verilator: asm
	cd $(SIM) && bash run_verilator.sh

test: verilator

# Full regression on ModelSim, 14 runs from one compile:
#   1-4  single-core system bench under four bus-timing configurations
#   5    dual-core shared memory
#   6    PIC feature bench
#   7-9  PIC reset / read-only / SRCx_STATUS block benches
#   10   machine-timer registers
#   11   CSR read-only, WARL and reset
#   12   one directed test per trap cause
#   13   branch predictor: BTB/BHT, RAS boundaries, reset
#   14   ALU operation decode and operand boundaries
modelsim: asm
	cd $(SIM) && vsim -c -do "do regress.do; quit -f"

# SoC regression, 9 runs from one compile:
#   1    AXI4-Full to AXI4-Lite burst bridge, block level
#   2-5  full system under four bus timings: CPU programs the DMA, sleeps on
#        WFI, DMA fills the dual-port SRAM, completion returns through the PIC
#   6-9  the same system under the same four timings with the CPU working the
#        bus throughout: arbiter under contention, both SRAM ports at once,
#        real collisions, DECERR
soc: asm
	cd $(SOCSIM) && vsim -c -do "do regress.do; quit -f"

# Lint the whole SoC with -Wall, then run every SoC bench with the bound SVA
# layer live. ModelSim ASE cannot compile assertions, so this is where the
# fabric's protocol and routing properties are actually checked.
soc-sva: asm
	bash $(SOCSIM)/run_verilator.sh

clean:
	rm -rf $(SIM)/obj_dir $(SIM)/work $(SIM)/cov_annotated
	rm -f  $(SIM)/coverage.dat $(SIM)/*.log $(SIM)/transcript $(SIM)/modelsim.ini
	rm -rf $(SOCSIM)/work $(SOCSIM)/obj_dir
	rm -f  $(SOCSIM)/transcript $(SOCSIM)/modelsim.ini $(SOCSIM)/*.wlf
	rm -f  $(SOCSIM)/build_*.log $(SOCSIM)/run_*.log
