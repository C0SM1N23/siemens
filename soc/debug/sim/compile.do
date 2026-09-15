onerror {quit -code 1 -f}
vlib work
vmap work work

# 1. RTL, in dependency-level order
vlog -sv -f soc_rtl.f

# 2. testbenches
vlog +incdir+../../../cpu/debug/hdl ../../../cpu/debug/hdl/ck_rst_tb.v
vlog +incdir+../../../cpu/debug/hdl +incdir+../../hdl ../hdl/soc_tb_addr_map.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_full2lite.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_top.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_stress.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_dma_len.v

# The benches added for the gaps the regression did not reach. Two of them need
# the RTL include path as well: the map-consistency check includes both address
# maps, and the backpressure bench builds the peripheral leg from the same
# window definitions the design uses.
vlog +incdir+../../../cpu/debug/hdl +incdir+../../hdl +incdir+../../../cpu/debug/sim ../hdl/soc_tb_map_consistency.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_full2lite_err.v
vlog +incdir+../../../cpu/debug/hdl +incdir+../../hdl ../hdl/soc_tb_perip_backpressure.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_dma_irq.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_dma_channels.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_dma_err.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_timer.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_pic_sources.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_pic_nest.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_pic_escalate.v

vlog +incdir+../../../cpu/debug/hdl ../hdl/soc_tb_arb.v
