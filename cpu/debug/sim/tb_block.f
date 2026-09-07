// ---------------------------------------------------------------------------
// Block-level testbenches: reset, read-only, register-field and trap-cause
// verification. ModelSim-only (the Verilator flow runs the system bench plus
// the SVA layer), ordered by the same bottom-up rule as rtl.f.
//
// Every bench here instantiates exactly one RTL block and nothing else, so
// rtl.f must be compiled first. They are all leaves as far as this list is
// concerned: no bench instantiates another bench.
//
//   pic_tb_feature          PIC feature bench (bands, nesting, spurious, deadline, sw)
//   pic_tb_sched    PIC scheduling corners: CPU mask, edge-at-claim, bump, key
//   pic_tb_reset    PIC reset values, X-freedom, asynchronous reset
//   pic_tb_ro       PIC read-only registers and reserved bits
//   pic_tb_status   PIC SRCx_STATUS, field by field
//   mtimer_tb_regs  machine-timer registers, reset and access rules
//   rv32i_tb_csr_ro       CSR file: read-only, WARL, tied-off, absent
//   rv32i_tb_traps        one directed test per trap cause, at CPU level
//   rv32i_tb_bp           branch predictor: BTB/BHT, RAS boundaries, reset
//   rv32i_tb_alu          arithmetic path: the ALUOp decode and every operation
//
// The incdir resolves tb_check.vh / tb_axil_master.vh; rv32i_tb_traps and rv32i_tb_alu
// also need the RTL include path for rv32i_defines.vh.
// ---------------------------------------------------------------------------
+incdir+../hdl
+incdir+../../hdl

../hdl/pic_tb_feature.v
../hdl/pic_tb_sched.v
../hdl/pic_tb_reset.v
../hdl/pic_tb_ro.v
../hdl/pic_tb_status.v
../hdl/mtimer_tb_regs.v
../hdl/rv32i_tb_csr_ro.v
../hdl/rv32i_tb_traps.v
../hdl/rv32i_tb_bp.v
../hdl/rv32i_tb_alu.v
