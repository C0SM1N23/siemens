vlib work
vmap work work

vlog ../../hdl/sistem_parcare.v
vlog ../hdl/sistem_parcare_tb.v

vsim -gui -voptargs=+acc work.sistem_parcare_tb

log -r /*

do wave.do

run 5us

wave zoom full