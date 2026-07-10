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

RTL="../../hdl"
TBH="../hdl"
SVA="../sva"

verilator --cc --exe --build --timing --assert --coverage -Wno-fatal \
  --top-module tb_cpu_axi -o Vtb_cpu_axi \
  sim_main.cpp \
  "$RTL"/alu.v "$RTL"/alu_top.v "$RTL"/branch_predictor.v "$RTL"/branch_unit.v \
  "$RTL"/control.v "$RTL"/cpu_top.v "$RTL"/csr_file.v "$RTL"/decode.v \
  "$RTL"/exception_unit.v "$RTL"/fetch_unit.v "$RTL"/hazard_unit.v \
  "$RTL"/imm_gen.v "$RTL"/lsu.v "$RTL"/mtimer.v "$RTL"/pic.v "$RTL"/regfile.v \
  "$RTL"/writeback_mux.v \
  "$TBH"/ck_rst_tb.v "$TBH"/axi_lite_mem_model.v "$TBH"/axi_lite_dec2.v \
  "$TBH"/axi_lite_monitor.v "$TBH"/tb_cpu_axi.v \
  "$SVA"/axi_lite_sva.sv "$SVA"/cpu_core_sva.sv "$SVA"/pic_sva.sv \
  "$SVA"/cpu_func_cov.sv "$SVA"/bind_sva.sv

./obj_dir/Vtb_cpu_axi

verilator_coverage --annotate cov_annotated coverage.dat > /dev/null
echo "cover-property annotation written to debug/sim/cov_annotated/"
