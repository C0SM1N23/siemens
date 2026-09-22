onerror {quit -code 1 -f}
# 22 runs; parameters are checked after elaboration.
do run_common.do
do compile.do

run_case rv32i_tb_cpu_axi "rv32i_tb_cpu_axi"
run_case rv32i_tb_cpu_axi "rv32i_tb_cpu_axi" -G/rv32i_tb_cpu_axi/imem_inst/READ_LAT=2 -G/rv32i_tb_cpu_axi/dmem_inst/READ_LAT=3 -G/rv32i_tb_cpu_axi/dmem_inst/WRITE_LAT=2
run_case rv32i_tb_cpu_axi "rv32i_tb_cpu_axi" -G/rv32i_tb_cpu_axi/imem_inst/STALL_PROB=25 -G/rv32i_tb_cpu_axi/imem_inst/SEED=101 -G/rv32i_tb_cpu_axi/dmem_inst/STALL_PROB=35 -G/rv32i_tb_cpu_axi/dmem_inst/SEED=202
run_case rv32i_tb_cpu_axi "rv32i_tb_cpu_axi" -G/rv32i_tb_cpu_axi/imem_inst/STALL_PROB=40 -G/rv32i_tb_cpu_axi/imem_inst/SEED=777 -G/rv32i_tb_cpu_axi/dmem_inst/STALL_PROB=20 -G/rv32i_tb_cpu_axi/dmem_inst/SEED=888
run_case rv32i_tb_dual_core "rv32i_tb_dual_core"
run_case pic_tb_feature "pic_tb_feature"
run_case pic_tb_reference "PIC reference: band permutations and masks"
run_case pic_tb_sched "pic_tb_sched"
run_case pic_tb_reset "pic_tb_reset"
run_case rv32i_tb_reset "CPU asynchronous reset and stopped clock"
run_case pic_tb_ro "pic_tb_ro"
run_case pic_tb_status "pic_tb_status"
run_case mtimer_tb_regs "mtimer_tb_regs"
run_case rv32i_tb_counters "counter write priority and carry"
run_case rv32i_tb_csr_ro "rv32i_tb_csr_ro"
run_case rv32i_tb_traps "rv32i_tb_traps"
run_case rv32i_tb_bp "rv32i_tb_bp"
run_case rv32i_tb_alu "rv32i_tb_alu"

run_case rv32i_tb_isa "ISA reference: nominal"
run_case rv32i_tb_isa "ISA reference: latency" -G/rv32i_tb_isa/READ_LAT=2
run_case rv32i_tb_isa "ISA reference: backpressure 25%" -G/rv32i_tb_isa/STALL_PROB=25
run_case rv32i_tb_isa "ISA reference: backpressure 40%" -G/rv32i_tb_isa/STALL_PROB=40

echo "REGRESSION PASS: $run_count runs"
