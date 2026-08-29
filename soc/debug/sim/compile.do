# One canonical compile for the SoC, shared by sim.do and regress.do.
#
# COMPILE ORDER
#   1. soc_rtl.f   the whole design, levelled bottom-up: CPU/DMA/SRAM leaves,
#                  then the interconnect, then the block tops, then soc_top
#   2. benches     ck_rst_tb is a leaf and must precede the benches that use it
#
# The +incdir+ resolves tb_check.vh, the shared self-check task the CPU block's
# benches already use; the SoC benches use the same one rather than growing a
# second copy of it. tb_addr_map also needs the RTL include path, because it
# builds the decoder from the same soc_addr_map.vh the design uses.

vlib work
vmap work work

# 1. RTL, in dependency-level order
vlog -f soc_rtl.f

# 2. testbenches
vlog +incdir+../../../cpu/debug/hdl ../../../cpu/debug/hdl/ck_rst_tb.v
vlog +incdir+../../../cpu/debug/hdl +incdir+../../hdl ../hdl/tb_addr_map.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/tb_full2lite.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/tb_soc_top.v
vlog +incdir+../../../cpu/debug/hdl ../hdl/tb_soc_stress.v
