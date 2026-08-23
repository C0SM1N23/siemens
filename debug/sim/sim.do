# quick single run of the main TB, with the AXI waveform loaded automatically.
# (rebuild programs first if edited:
#    py asm.py program_axi.s  program_axi.hex
#    py asm.py program_dual.s program_dual.hex)

do compile.do

vsim -voptargs=+acc work.tb_cpu_axi
do wave.do          ;# add + log the AXI signals BEFORE the run (else "-No Data-")
run -all
wave zoom full
