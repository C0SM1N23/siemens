# quick single run of the main TB
# (rebuild programs first if edited:
#    py asm.py program_axi.s  program_axi.hex
#    py asm.py program_dual.s program_dual.hex)

do compile.do

vsim -voptargs=+acc work.tb_cpu_axi
run -all
