# one canonical compile list, shared by sim.do and regress.do

vlib work
vmap work work

# modules carried over from the single-cycle core
vlog ../../hdl/decode.v
vlog ../../hdl/imm_gen.v
vlog ../../hdl/regfile.v
vlog ../../hdl/alu.v
vlog ../../hdl/alu_top.v
vlog ../../hdl/branch_unit.v
vlog ../../hdl/writeback_mux.v

# extended / new modules for the 3-stage AXI pipeline
vlog ../../hdl/control.v
vlog ../../hdl/csr_file.v
vlog ../../hdl/exception_unit.v
vlog ../../hdl/branch_predictor.v
vlog ../../hdl/fetch_unit.v
vlog ../../hdl/lsu.v
vlog ../../hdl/hazard_unit.v
vlog ../../hdl/cpu_top.v

# testbench collateral
vlog ../hdl/ck_rst_tb.v
vlog ../hdl/axi_lite_mem_model.v
vlog ../hdl/axi_lite_monitor.v
vlog ../hdl/axi_lite_arb2.v
vlog ../hdl/tb_cpu_axi.v
vlog ../hdl/tb_dual_core.v
