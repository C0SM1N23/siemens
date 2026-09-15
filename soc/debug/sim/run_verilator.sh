#!/usr/bin/env bash
# SoC RTL lint and all integration benches with CPU, PIC, AXI and fabric SVA.
set -euo pipefail
cd "$(dirname "$0")"
source ../../../cpu/debug/sim/verilator_common.sh
python3 ../../../cpu/debug/sim/check_lint.py soc
CPUSVA=../../../cpu/debug/sva
SVA=("$CPUSVA/axi_lite_sva.sv" "$CPUSVA/rv32i_cpu_core_sva.sv"
     "$CPUSVA/pic_sva.sv" "$CPUSVA/rv32i_bind_core_sva.sv"
     ../sva/soc_axi_full_sva.sv ../sva/soc_fabric_sva.sv ../sva/soc_bind_sva.sv)
for top in soc_tb_map_consistency soc_tb_addr_map soc_tb_arb soc_tb_full2lite \
    soc_tb_full2lite_err soc_tb_perip_backpressure soc_tb_top soc_tb_stress \
    soc_tb_dma_len soc_tb_dma_irq soc_tb_dma_channels soc_tb_dma_err soc_tb_timer \
    soc_tb_pic_sources soc_tb_pic_nest soc_tb_pic_escalate; do
    run_asserted "$top" -f soc_rtl.f +incdir+../../../cpu/debug/hdl \
        +incdir+../../hdl +incdir+../../../cpu/debug/sim \
        ../../../cpu/debug/hdl/ck_rst_tb.v "../hdl/$top.v" "${SVA[@]}"
done
echo "SVA REGRESSION PASS: SoC, 16 benches"
