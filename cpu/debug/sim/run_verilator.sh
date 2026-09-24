#!/usr/bin/env bash
# RTL lint, then every CPU/PIC bench with bound SVA and cover properties: each
# bench at its default configuration plus the timing variants regress.do runs.
# The system bench also carries the functional-coverage model; its bins are gated
# in every run and merged over the four bus timings.
set -euo pipefail
cd "$(dirname "$0")"
source ./verilator_common.sh
python3 asm.py program_axi.s program_axi.hex > build_asm.log
python3 asm.py program_dual.s program_dual.hex >> build_asm.log
python3 isa_reference.py
python3 pic_reference.py
python3 check_lint.py cpu
reset_coverage
SVA=(../sva/axi_lite_sva.sv ../sva/rv32i_cpu_core_sva.sv ../sva/pic_sva.sv ../sva/rv32i_bind_core_sva.sv)
SYS=(-f rtl.f -f tb_cpu.f +incdir+. "${SVA[@]}" ../sva/rv32i_cpu_func_cov.sv ../sva/rv32i_bind_sva.sv)

# The system program at the four bus timings of regress.do.
run_variant rv32i_tb_cpu_axi rv32i_tb_cpu_axi "${SYS[@]}"
grep -q "COVERAGE GATE PASSED" run_rv32i_tb_cpu_axi.log
# The per-run gate is calibrated for the nominal timing; the variants reach other
# corners of the same bins and count towards the merged gate below.
RUN_ARGS=+fcov_merge_only run_variant rv32i_tb_cpu_axi_lat rv32i_tb_cpu_axi "${SYS[@]}" \
    -GIMEM_READ_LAT=2 -GDMEM_READ_LAT=3 -GDMEM_WRITE_LAT=2
RUN_ARGS=+fcov_merge_only run_variant rv32i_tb_cpu_axi_bp25 rv32i_tb_cpu_axi "${SYS[@]}" \
    -GIMEM_STALL_PROB=25 -GIMEM_SEED=101 -GDMEM_STALL_PROB=35 -GDMEM_SEED=202
RUN_ARGS=+fcov_merge_only run_variant rv32i_tb_cpu_axi_bp40 rv32i_tb_cpu_axi "${SYS[@]}" \
    -GIMEM_STALL_PROB=40 -GIMEM_SEED=777 -GDMEM_STALL_PROB=20 -GDMEM_SEED=888
BENCHES=1
for top in rv32i_tb_dual_core pic_tb_feature pic_tb_reference pic_tb_sched \
    pic_tb_reset rv32i_tb_reset pic_tb_ro pic_tb_status mtimer_tb_regs rv32i_tb_csr_ro \
    rv32i_tb_counters rv32i_tb_traps rv32i_tb_bp rv32i_tb_alu; do
    run_asserted "$top" -f rtl.f -f tb_cpu.f +incdir+. \
        ../hdl/axi_lite_arb2.v "../hdl/$top.v" "${SVA[@]}"
    BENCHES=$((BENCHES + 1))
done
# Constrained-random PIC traffic: one build, seeds 1 to 11 (1 is the default),
# every trace replayed through the independent cycle model.
PICR=(-f rtl.f -f tb_cpu.f +incdir+. ../hdl/pic_tb_random.v "${SVA[@]}")
run_variant pic_tb_random pic_tb_random "${PICR[@]}"
BENCHES=$((BENCHES + 1))
python3 pic_model.py pic_random.trace > pic_model_s1.log || { cat pic_model_s1.log; exit 1; }
for seed in 2 3 4 5 6 7 8 9 10 11; do
    rerun pic_tb_random "pic_tb_random_s$seed" pic_tb_random "+seed=$seed" +cycles=20000
    python3 pic_model.py pic_random.trace > "pic_model_s$seed.log" || { cat "pic_model_s$seed.log"; exit 1; }
done

# ISA trace: the directed program and ten random ones, each at nominal timing and
# again at one stressed timing. The coverage model is bound here as well; its
# counts join the merged gate.
python3 isa_reference.py --random-set > build_isa.log
ISA=(-f rtl.f -f tb_cpu.f +incdir+. ../hdl/rv32i_tb_isa.v "${SVA[@]}"
     ../sva/rv32i_cpu_func_cov.sv ../sva/rv32i_bind_sva.sv)
RUN_ARGS=+fcov_merge_only run_variant rv32i_tb_isa rv32i_tb_isa "${ISA[@]}"
BENCHES=$((BENCHES + 1))
RUN_ARGS=+fcov_merge_only run_variant rv32i_tb_isa_lat rv32i_tb_isa "${ISA[@]}" -GREAD_LAT=2
RUN_ARGS=+fcov_merge_only run_variant rv32i_tb_isa_bp25 rv32i_tb_isa "${ISA[@]}" -GSTALL_PROB=25
RUN_ARGS=+fcov_merge_only run_variant rv32i_tb_isa_bp40 rv32i_tb_isa "${ISA[@]}" -GSTALL_PROB=40
STRESS=(rv32i_tb_isa_lat rv32i_tb_isa_bp25 rv32i_tb_isa_bp40)
for seed in 1 2 3 4 5 6 7 8 9 10; do
    rerun rv32i_tb_isa "rv32i_tb_isa_r$seed" rv32i_tb_isa +fcov_merge_only "+isa=program_isa_r$seed"
    build=${STRESS[$(( (seed - 1) % 3 ))]}
    rerun "$build" "${build}_r$seed" rv32i_tb_isa +fcov_merge_only "+isa=program_isa_r$seed"
done

python3 merge_fcov.py --report cov/fcov_report.txt run_rv32i_tb_cpu_axi.log \
    run_rv32i_tb_cpu_axi_lat.log run_rv32i_tb_cpu_axi_bp25.log run_rv32i_tb_cpu_axi_bp40.log \
    run_rv32i_tb_isa*.log

verilator_coverage --annotate cov_annotated cov/*.dat > /dev/null
python3 check_covers.py cpu
echo "SVA REGRESSION PASS: CPU, $BENCHES benches, $SVA_RUNS runs; functional and cover gates passed"
