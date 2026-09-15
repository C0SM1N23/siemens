# quick single run of the main TB, with the AXI waveform loaded automatically.
# (rebuild programs first if edited:
#    py asm.py program_axi.s  program_axi.hex
#    py asm.py program_dual.s program_dual.hex)

onerror {quit -code 1 -f}
do compile.do

if {![info exists sim_args]} {set sim_args {}}
eval vsim -onfinish stop -voptargs=+acc work.rv32i_tb_cpu_axi $sim_args
do wave.do          ;# add + log the AXI signals BEFORE the run (else "-No Data-")
run -all
if {[examine -radix binary /rv32i_tb_cpu_axi/test_done] ne "1" || [examine -radix decimal /rv32i_tb_cpu_axi/errors] != 0} {
    echo "FAIL: CPU simulation incomplete or mismatched"
    quit -code 1 -f
}
echo "SIMULATION PASS: rv32i_tb_cpu_axi"
wave zoom full
