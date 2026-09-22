# Reproducible evidence for the specification figures. Run from cpu/debug/sim.
onerror {quit -code 1 -f}
do compile.do
file mkdir ../../docs/waves/raw
foreach top {rv32i_tb_cpu_axi rv32i_tb_reset rv32i_tb_bp rv32i_tb_traps pic_tb_feature pic_tb_sched pic_tb_status pic_tb_reset} {
    vsim -onfinish stop -voptargs=+acc work.$top
    vcd file ../../docs/waves/raw/$top.vcd
    vcd add -r /$top/*
    run -all
    vcd flush
    if {[examine -radix binary /$top/test_done] ne "1"} {quit -code 1 -f}
    if {[examine -radix decimal /$top/errors] != 0} {quit -code 1 -f}
    vcd off
    quit -sim
}
echo "WAVEFORM REGRESSION PASS: 8 benches"
quit -f
