onerror {quit -code 1 -f}
# 25 runs; parameters are checked after elaboration.
do ../../../cpu/debug/sim/run_common.do
do compile.do

run_case soc_tb_map_consistency "soc_tb_map_consistency"
run_case soc_tb_arb "arbiter: contention and concurrent directions"
run_case soc_tb_addr_map "soc_tb_addr_map"
run_case soc_tb_full2lite "soc_tb_full2lite"
run_case soc_tb_full2lite_err "soc_tb_full2lite_err"
run_case soc_tb_perip_backpressure "soc_tb_perip_backpressure"
run_case soc_tb_top "soc_tb_top"
run_case soc_tb_top "soc_tb_top" -G/soc_tb_top/dut/IMEM_READ_LAT=2 -G/soc_tb_top/dut/DMEM_READ_LAT=3 -G/soc_tb_top/dut/DMEM_WRITE_LAT=2
run_case soc_tb_top "soc_tb_top" -G/soc_tb_top/dut/IMEM_STALL_PROB=25 -G/soc_tb_top/dut/IMEM_SEED=101 -G/soc_tb_top/dut/DMEM_STALL_PROB=35 -G/soc_tb_top/dut/DMEM_SEED=202
run_case soc_tb_top "soc_tb_top" -G/soc_tb_top/dut/IMEM_STALL_PROB=40 -G/soc_tb_top/dut/IMEM_SEED=777 -G/soc_tb_top/dut/DMEM_STALL_PROB=20 -G/soc_tb_top/dut/DMEM_SEED=888 -G/soc_tb_top/dut/DMEM_READ_LAT=1
run_case soc_tb_stress "soc_tb_stress"
run_case soc_tb_stress "soc_tb_stress" -G/soc_tb_stress/dut/IMEM_READ_LAT=2 -G/soc_tb_stress/dut/DMEM_READ_LAT=3 -G/soc_tb_stress/dut/DMEM_WRITE_LAT=2
run_case soc_tb_stress "soc_tb_stress" -G/soc_tb_stress/dut/IMEM_STALL_PROB=25 -G/soc_tb_stress/dut/IMEM_SEED=101 -G/soc_tb_stress/dut/DMEM_STALL_PROB=35 -G/soc_tb_stress/dut/DMEM_SEED=202
run_case soc_tb_stress "soc_tb_stress" -G/soc_tb_stress/dut/IMEM_STALL_PROB=40 -G/soc_tb_stress/dut/IMEM_SEED=777 -G/soc_tb_stress/dut/DMEM_STALL_PROB=20 -G/soc_tb_stress/dut/DMEM_SEED=888 -G/soc_tb_stress/dut/DMEM_WRITE_LAT=1
run_case soc_tb_dma_len "soc_tb_dma_len"
run_case soc_tb_dma_len "soc_tb_dma_len" -G/soc_tb_dma_len/dut/IMEM_READ_LAT=2 -G/soc_tb_dma_len/dut/DMEM_READ_LAT=3 -G/soc_tb_dma_len/dut/DMEM_WRITE_LAT=2
run_case soc_tb_dma_len "soc_tb_dma_len" -G/soc_tb_dma_len/dut/IMEM_STALL_PROB=25 -G/soc_tb_dma_len/dut/IMEM_SEED=101 -G/soc_tb_dma_len/dut/DMEM_STALL_PROB=35 -G/soc_tb_dma_len/dut/DMEM_SEED=202
run_case soc_tb_dma_len "soc_tb_dma_len" -G/soc_tb_dma_len/dut/IMEM_STALL_PROB=40 -G/soc_tb_dma_len/dut/IMEM_SEED=777 -G/soc_tb_dma_len/dut/DMEM_STALL_PROB=20 -G/soc_tb_dma_len/dut/DMEM_SEED=888
run_case soc_tb_dma_irq "soc_tb_dma_irq"
run_case soc_tb_dma_channels "soc_tb_dma_channels"
run_case soc_tb_dma_err "soc_tb_dma_err"
run_case soc_tb_timer "soc_tb_timer"
run_case soc_tb_pic_sources "soc_tb_pic_sources"
run_case soc_tb_pic_nest "soc_tb_pic_nest"
run_case soc_tb_pic_escalate "soc_tb_pic_escalate"

echo "REGRESSION PASS: $run_count runs"
