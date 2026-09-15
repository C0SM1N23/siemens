# RV32I CPU — build/test entry points. The actual flows live in cpu/debug/sim;
# this just wires them up for one-command runs and for CI.
#
#   make test       assemble + run the Verilator SVA/coverage flow (CI default)
#   make modelsim   full 21-run ModelSim CPU regression (needs vsim; local)
#   make soc        SoC regression: 25 runs over four bus timings (needs vsim)
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
	cd $(SIM) && $(PY) isa_reference.py
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

# SVA + functional-coverage run on Verilator (free, CI-runnable). The script
# exits non-zero if the TB checks or the coverage gate fail.
verilator: asm
	cd $(SIM) && bash run_verilator.sh

test: verilator

# CPU: 15 benches, 21 timing configurations. See cpu/debug/VERIFICATION.md.
modelsim: asm
	cd $(SIM) && vsim -c -do "do regress.do; quit -f"

# SoC: 16 benches, 25 timing configurations. See soc/docs/VERIFICATION.md.
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
