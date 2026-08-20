#!/usr/bin/env bash
# SVA + functional coverage run — Verilator (free, open source).
#
# Why this exists: ModelSim ASE cannot compile SystemVerilog assertions o
# report functional coverage, so the SVA layer under debug/sva/ runs here.
# The RTL, the testbench and the ModelSim .do flow are untouched — this is
# a second pair of eyes on the same tb_cpu_axi run.
#
# Usage (from Windows): powershell debug/sim/run_verilator.ps1
#        (from Linux):  bash debug/sim/run_verilator.sh
#
# Outputs:
# - console: the usual PASS/FAIL lines, %Error on any assertion failure,
#   and the [FCOV] functional coverage table at the end
# - debug/sim/cov_annotated/: per-line hit counts for the cover properties

set -e
cd "$(dirname "$0")"

SVA="../sva"

# RTL + tb collateral come from the shared filelists (same rtl.f / tb_cpu.f the
# ModelSim flow uses); only the Verilator-only SVA layer is listed here.
#
# --unroll-count 64 is pinned deliberately. Verilator rejects a non-blocking
# assignment to an unpacked array inside a loop it cannot unroll (BLKLOOPINIT),
# and the limit is a version-dependent default. Pinning it to 64 -- the value
# the oldest Verilator the CI may install uses -- means a loop that would break
# the CI build breaks the local build first, instead of passing here on a newer
# Verilator with a larger budget and failing after the push.
verilator --cc --exe --build --timing --assert --coverage -Wno-fatal \
  --unroll-count 64 \
  --top-module tb_cpu_axi -o Vtb_cpu_axi +incdir+. \
  sim_main.cpp \
  -f rtl.f -f tb_cpu.f \
  "$SVA"/axi_lite_sva.sv "$SVA"/cpu_core_sva.sv "$SVA"/pic_sva.sv \
  "$SVA"/cpu_func_cov.sv "$SVA"/bind_sva.sv

./obj_dir/Vtb_cpu_axi | tee sim_run.log

verilator_coverage --annotate cov_annotated coverage.dat > /dev/null
echo "cover-property annotation written to debug/sim/cov_annotated/"

# pass criteria: the TB self-check passed, no assertion fired, and every
# required functional-coverage bin was hit
status=0
grep -q "== ALL TESTS PASSED ==" sim_run.log || { echo "FAIL: TB checks";       status=1; }
grep -q "COVERAGE GATE PASSED"   sim_run.log || { echo "FAIL: coverage gate";    status=1; }
grep -q "GATE FAILED"            sim_run.log && { echo "FAIL: coverage gate";     status=1; }
[ $status -eq 0 ] && echo "== run_verilator: PASS ==" || echo "== run_verilator: FAIL =="
exit $status
