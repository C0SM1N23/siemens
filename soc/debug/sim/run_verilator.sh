#!/usr/bin/env bash
# SoC RTL lint, then every integration bench with CPU, PIC, AXI and fabric SVA
# and cover properties: each bench at its default configuration plus the
# latency and backpressure variants regress.do runs.
set -euo pipefail
cd "$(dirname "$0")"
source ../../../cpu/debug/sim/verilator_common.sh
python3 ../../../cpu/debug/sim/check_lint.py soc
reset_coverage
CPUSVA=../../../cpu/debug/sva
SVA=("$CPUSVA/axi_lite_sva.sv" "$CPUSVA/rv32i_cpu_core_sva.sv"
     "$CPUSVA/pic_sva.sv" "$CPUSVA/rv32i_bind_core_sva.sv"
     ../sva/soc_axi_full_sva.sv ../sva/soc_fabric_sva.sv ../sva/soc_bind_sva.sv)
COMMON=(-f soc_rtl.f +incdir+../../../cpu/debug/hdl +incdir+../../hdl
        +incdir+../../../cpu/debug/sim ../../../cpu/debug/hdl/ck_rst_tb.v)

BENCHES=0
for top in soc_tb_map_consistency soc_tb_addr_map soc_tb_arb soc_tb_full2lite \
    soc_tb_full2lite_err soc_tb_perip_backpressure soc_tb_top soc_tb_stress \
    soc_tb_dma_len soc_tb_dma_irq soc_tb_dma_channels soc_tb_dma_err soc_tb_timer \
    soc_tb_pic_sources soc_tb_pic_nest soc_tb_pic_escalate soc_tb_isolation soc_tb_dma_fault \
    soc_tb_reset_traffic soc_tb_pic_spurious soc_tb_pic_deep_nest soc_tb_same_addr; do
    run_asserted "$top" "${COMMON[@]}" "../hdl/$top.v" "${SVA[@]}"
    BENCHES=$((BENCHES + 1))
done

# The latency and backpressure variants of regress.do, with the same seeds.
for top in soc_tb_top soc_tb_stress soc_tb_dma_len; do
    SRC=("${COMMON[@]}" "../hdl/$top.v" "${SVA[@]}")
    run_variant "${top}_lat" "$top" "${SRC[@]}" \
        -GIMEM_READ_LAT=2 -GDMEM_READ_LAT=3 -GDMEM_WRITE_LAT=2
    run_variant "${top}_bp25" "$top" "${SRC[@]}" \
        -GIMEM_STALL_PROB=25 -GIMEM_SEED=101 -GDMEM_STALL_PROB=35 -GDMEM_SEED=202
done
SRC=("${COMMON[@]}" ../hdl/soc_tb_top.v "${SVA[@]}")
run_variant soc_tb_top_bp40 soc_tb_top "${SRC[@]}" -GIMEM_STALL_PROB=40 -GIMEM_SEED=777 \
    -GDMEM_STALL_PROB=20 -GDMEM_SEED=888 -GDMEM_READ_LAT=1
SRC=("${COMMON[@]}" ../hdl/soc_tb_stress.v "${SVA[@]}")
run_variant soc_tb_stress_bp40 soc_tb_stress "${SRC[@]}" -GIMEM_STALL_PROB=40 -GIMEM_SEED=777 \
    -GDMEM_STALL_PROB=20 -GDMEM_SEED=888 -GDMEM_WRITE_LAT=1
SRC=("${COMMON[@]}" ../hdl/soc_tb_dma_len.v "${SVA[@]}")
run_variant soc_tb_dma_len_bp40 soc_tb_dma_len "${SRC[@]}" -GIMEM_STALL_PROB=40 -GIMEM_SEED=777 \
    -GDMEM_STALL_PROB=20 -GDMEM_SEED=888

# Random traffic through the real fabric: one build, twenty seeds.
run_variant soc_tb_fabric_random soc_tb_fabric_random "${COMMON[@]}" ../hdl/soc_tb_fabric_random.v "${SVA[@]}"
BENCHES=$((BENCHES + 1))
for seed in $(seq 2 20); do
    rerun soc_tb_fabric_random "soc_tb_fabric_random_s$seed" soc_tb_fabric_random "+seed=$seed"
done

python3 ../../../cpu/debug/sim/check_covers.py soc
echo "SVA REGRESSION PASS: SoC, $BENCHES benches, $SVA_RUNS runs; cover gate passed"
