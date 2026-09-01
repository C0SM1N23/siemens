// ---------------------------------------------------------------------------
// SoC RTL source list and COMPILE ORDER.
//
// Paths are relative to soc/debug/sim, where the flow runs. The order follows
// the same bottom-up rule the CPU block uses (the reasoning is written out in
// debug/sim/rtl.f): a module appears only after everything it instantiates.
// Verilog resolves instances at elaboration, so a wrong order usually still
// works - but `include and `define visibility is order-dependent, a missing
// module is then reported at the level that needed it instead of as one
// unresolved instance at the top, and lint/synthesis front-ends do require
// definition before use.
//
// LEVELS (a module may only instantiate modules from a strictly lower level)
//   L0  leaves: instantiate nothing
//   L1  instantiate L0 only
//   L2  block tops
//   L3  the SoC
// ---------------------------------------------------------------------------

// --- include paths ----------------------------------------------------------
+incdir+../../../cpu/hdl        // defines.vh, shared CPU encodings
+incdir+../../hdl           // soc_addr_map.vh

// --- L0: CPU leaves ---------------------------------------------------------
../../../cpu/hdl/alu.v
../../../cpu/hdl/axi_lite_slave.v
../../../cpu/hdl/branch_predictor.v
../../../cpu/hdl/branch_unit.v
../../../cpu/hdl/control.v
../../../cpu/hdl/csr_file.v
../../../cpu/hdl/decode.v
../../../cpu/hdl/exception_unit.v
../../../cpu/hdl/fetch_unit.v
../../../cpu/hdl/hazard_unit.v
../../../cpu/hdl/imm_gen.v
../../../cpu/hdl/lsu.v
../../../cpu/hdl/regfile.v
../../../cpu/hdl/writeback_mux.v

// --- L0: DMA leaves ---------------------------------------------------------
../../../dma/hdl/axi4_lite_slave.v
../../../dma/hdl/axi4_full_master.v
../../../dma/hdl/dma_channel.v
../../../dma/hdl/priority_arbiter.v

// --- L0: DP-SRAM leaves -----------------------------------------------------
../../../sram/hdl/axi4lite_slave_fsm.v
../../../sram/hdl/collision_det.v
../../../sram/hdl/mem_array.v
../../../sram/hdl/dp_sram_regfile.v

// --- L0: interconnect -------------------------------------------------------
../../hdl/axi_lite_dec.v      // 1 master -> N slaves, DECERR on a miss
../../hdl/axi_lite_arb.v      // M masters -> 1 slave, round-robin
../../hdl/axi_full2lite.v     // AXI4-Full burst -> AXI4-Lite beats
../../hdl/axi_lite_ram.v      // AXI4-Lite RAM slave (IMEM / DMEM)

// --- L1: depend on L0 only --------------------------------------------------
../../../cpu/hdl/alu_top.v        // -> alu
../../../cpu/hdl/mtimer.v         // -> axi_lite_slave
../../../cpu/hdl/pic.v            // -> axi_lite_slave
../../../sram/hdl/dp_sram_top.v   // -> slave_fsm, collision_det, mem_array, dp_sram_regfile

// --- L2: block tops ---------------------------------------------------------
../../../cpu/hdl/cpu_top.v
../../../dma/hdl/mc_dma_top.v

// --- L3: the SoC ------------------------------------------------------------
../../hdl/soc_top.v
