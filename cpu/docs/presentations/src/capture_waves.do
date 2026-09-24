# VCD traces for the v3 deck figures. Run from soc/debug/sim:
#   vsim -c -do "do ../../../cpu/docs/presentations/src/capture_waves.do"
onerror {quit -code 1 -f}
do ../../../cpu/debug/sim/run_common.do
do compile.do
file mkdir ../../../cpu/docs/waves/raw
foreach top {soc_tb_pic_nest soc_tb_pic_escalate} {
    vsim -onfinish stop -voptargs=+acc work.$top
    vcd file ../../../cpu/docs/waves/raw/$top.vcd
    vcd add -r /$top/*
    run -all
    vcd flush
    if {[examine -radix binary /$top/test_done] ne "1"} {quit -code 1 -f}
    if {[examine -radix decimal /$top/errors] != 0} {quit -code 1 -f}
    vcd off
    quit -sim
}
echo "DECK WAVEFORMS PASS: 2 benches"
quit -f
