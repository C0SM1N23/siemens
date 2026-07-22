# one canonical compile, shared by sim.do and regress.do

vlib work
vmap work work

# RTL + the tb_cpu_axi collateral come from the shared filelists (rtl.f /
# tb_cpu.f), so a new module is added in one place for both flows.
# +incdir+. lets tb_cpu_axi find program_axi_sym.vh (label addresses from asm.py)
vlog -f rtl.f
vlog +incdir+. -f tb_cpu.f

# dual-core bench is ModelSim-only (Verilator runs the single-core bench)
vlog ../hdl/axi_lite_arb2.v
vlog +incdir+../hdl ../hdl/tb_dual_core.v

# standalone PIC feature bench (exercises bands/nesting/spurious/deadline/sw)
vlog +incdir+../hdl ../hdl/tb_pic.v
