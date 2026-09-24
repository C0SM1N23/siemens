# riscv-tests in ModelSim: every program run_riscv_tests.sh built and passed on
# Verilator, run again here at nominal timing and at 40% backpressure.
onerror {quit -code 1 -f}
do run_common.do
do compile.do
vlog +incdir+. +incdir+../hdl ../hdl/rv32i_tb_riscv_tests.v

if {![file exists riscv_tests/pass_list.txt]} {
    echo "FAIL: riscv_tests/pass_list.txt is missing; run run_riscv_tests.sh first"
    quit -code 1 -f
}
set list [open riscv_tests/pass_list.txt r]
set tests [split [string trim [read $list]] "\n"]
close $list
foreach line $tests {
    lassign $line name tohost
    run_case rv32i_tb_riscv_tests "riscv-tests $name" +test=$name +tohost=$tohost
    run_case rv32i_tb_riscv_tests "riscv-tests $name, 40% backpressure" \
        -G/rv32i_tb_riscv_tests/STALL_PROB=40 +test=$name +tohost=$tohost
}
echo "RISCV-TESTS PASS: $run_count runs"
