# RV32I CPU — build/test entry points. The actual flows live in debug/sim;
# this just wires them up for one-command runs and for CI.
#
#   make test       assemble + run the Verilator SVA/coverage flow (CI default)
#   make modelsim   full 5-config ModelSim regression (needs vsim; local/Windows)
#   make asm        regenerate program hex + the label-address include
#   make clean      remove build artifacts

SIM := debug/sim
PY  ?= python3

.PHONY: all test verilator modelsim asm clean

all: test

# assemble the test programs -> .hex + _sym.vh (label addresses for the TB)
asm:
	cd $(SIM) && $(PY) asm.py program_axi.s  program_axi.hex
	cd $(SIM) && $(PY) asm.py program_dual.s program_dual.hex

# SVA + functional-coverage run on Verilator (free, CI-runnable). The script
# exits non-zero if the TB checks or the coverage gate fail.
verilator: asm
	cd $(SIM) && bash run_verilator.sh

test: verilator

# full regression on ModelSim: default latencies, high latencies, two
# random-backpressure seeds, dual-core
modelsim: asm
	cd $(SIM) && vsim -c -do "do regress.do; quit -f"

clean:
	rm -rf $(SIM)/obj_dir $(SIM)/work $(SIM)/cov_annotated
	rm -f  $(SIM)/coverage.dat $(SIM)/*.log $(SIM)/transcript $(SIM)/modelsim.ini
