// ---------------------------------------------------------------------------
// Testbench collateral for the tb_cpu_axi bench — shared by both flows, and
// ordered by the same bottom-up rule as rtl.f (see the long note there).
//
// The dual-core bench (axi_lite_arb2 + tb_dual_core) and the block-level
// benches are ModelSim-only and stay in compile.do; the SVA layer is
// Verilator-only and stays in run_verilator.sh. rtl.f must be compiled before
// this file: tb_cpu_axi instantiates cpu_top, pic and mtimer.
//
//   L0  ck_rst_tb, axi_lite_mem_model, axi_lite_monitor, axi_lite_dec2
//   L1  tb_cpu_axi (instantiates the four above plus the RTL from rtl.f)
// ---------------------------------------------------------------------------

// Resolves `include "axi_lite_macros.vh" in both flows.
+incdir+../hdl

// --- Level 0: leaf testbench models ------------------------------------------
../hdl/ck_rst_tb.v           // clock + async reset generator     (leaf)
../hdl/axi_lite_mem_model.v  // behavioural AXI4-Lite memory      (leaf)
../hdl/axi_lite_monitor.v    // passive protocol checker          (leaf)
../hdl/axi_lite_dec2.v       // 1-to-2 AXI4-Lite address decoder  (leaf)

// --- Level 1: the bench itself -------------------------------------------------
../hdl/tb_cpu_axi.v
