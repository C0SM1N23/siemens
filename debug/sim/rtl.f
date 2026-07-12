// RTL source list — single source of truth, shared by the ModelSim and
// Verilator flows (vlog -f rtl.f  /  verilator -f rtl.f). Paths are relative
// to debug/sim, where both flows run. Add a module here once, not per flow.
// The incdir resolves `include "defines.vh" (shared encodings) in both flows.
+incdir+../../hdl
../../hdl/alu.v
../../hdl/alu_top.v
../../hdl/axi_lite_slave.v
../../hdl/branch_predictor.v
../../hdl/branch_unit.v
../../hdl/control.v
../../hdl/cpu_top.v
../../hdl/csr_file.v
../../hdl/decode.v
../../hdl/exception_unit.v
../../hdl/fetch_unit.v
../../hdl/hazard_unit.v
../../hdl/imm_gen.v
../../hdl/lsu.v
../../hdl/mtimer.v
../../hdl/pic.v
../../hdl/regfile.v
../../hdl/writeback_mux.v
