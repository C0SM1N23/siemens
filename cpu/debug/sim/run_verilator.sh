#!/usr/bin/env bash
# RTL lint, CPU functional coverage, then every CPU/PIC bench with bound SVA.
set -euo pipefail
cd "$(dirname "$0")"
source ./verilator_common.sh
python3 asm.py program_axi.s program_axi.hex > build_asm.log
python3 asm.py program_dual.s program_dual.hex >> build_asm.log
python3 isa_reference.py
python3 pic_reference.py
python3 check_lint.py cpu
SVA=(../sva/axi_lite_sva.sv ../sva/rv32i_cpu_core_sva.sv ../sva/pic_sva.sv ../sva/rv32i_bind_core_sva.sv)

# User coverage is separate from line/toggle coverage (Verilator 5.050 constraint).
mkdir -p obj_dir/coverage
verilator --cc --exe --build --timing --timescale 1ns/1ps --assert --coverage-user -Wno-fatal \
    --unroll-count 64 -j 4 --top-module rv32i_tb_cpu_axi \
    --Mdir obj_dir/coverage -o Vrv32i_tb_cpu_axi +incdir+. \
    "$PWD/sim_main.cpp" -f rtl.f -f tb_cpu.f "${SVA[@]}" \
    ../sva/rv32i_cpu_func_cov.sv ../sva/rv32i_bind_sva.sv > build_coverage.log 2>&1 \
    || { tail -80 build_coverage.log; exit 1; }
./obj_dir/coverage/Vrv32i_tb_cpu_axi 2>&1 | tee sim_run.log
grep -q "ALL TESTS PASSED" sim_run.log
grep -q "COVERAGE GATE PASSED" sim_run.log
if grep -Eq '%Error|FAIL:|GATE FAILED' sim_run.log; then exit 1; fi
verilator_coverage --annotate cov_annotated coverage.dat > /dev/null

for top in rv32i_tb_dual_core pic_tb_feature pic_tb_reference pic_tb_sched \
    pic_tb_reset rv32i_tb_reset pic_tb_ro pic_tb_status mtimer_tb_regs rv32i_tb_csr_ro \
    rv32i_tb_counters rv32i_tb_traps rv32i_tb_bp rv32i_tb_alu rv32i_tb_isa; do
    run_asserted "$top" -f rtl.f -f tb_cpu.f +incdir+. \
        ../hdl/axi_lite_arb2.v "../hdl/$top.v" "${SVA[@]}"
done
echo "SVA REGRESSION PASS: CPU, 16 benches; functional coverage gate passed"
