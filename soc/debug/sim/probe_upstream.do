onerror {quit -code 1 -f}
do compile.do
vlog -sv ../hdl/soc_probe_upstream.v
vsim -onfinish stop work.soc_probe_upstream
run -all
quit -f
