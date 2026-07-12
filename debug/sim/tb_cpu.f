// Testbench collateral for the tb_cpu_axi bench — shared by both flows.
// The dual-core bench (arb2 + tb_dual_core) is ModelSim-only and stays in
// compile.do; the SVA layer is Verilator-only and stays in run_verilator.sh.
../hdl/ck_rst_tb.v
../hdl/axi_lite_mem_model.v
../hdl/axi_lite_monitor.v
../hdl/axi_lite_dec2.v
../hdl/tb_cpu_axi.v
