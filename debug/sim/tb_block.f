// ---------------------------------------------------------------------------
// Block-level testbenches: reset, read-only, register-field and trap-cause
// verification. ModelSim-only (the Verilator flow runs the system bench plus
// the SVA layer), ordered by the same bottom-up rule as rtl.f.
//
// Every bench here instantiates exactly one RTL block and nothing else, so
// rtl.f must be compiled first. They are all leaves as far as this list is
// concerned: no bench instantiates another bench.
//
//   tb_pic          PIC feature bench (bands, nesting, spurious, deadline, sw)
//   tb_pic_reset    PIC reset values, X-freedom, asynchronous reset
//   tb_pic_ro       PIC read-only registers and reserved bits
//   tb_pic_status   PIC SRCx_STATUS, field by field
//   tb_mtimer_regs  machine-timer registers, reset and access rules
//   tb_csr_ro       CSR file: read-only, WARL, tied-off, absent
//   tb_traps        one directed test per trap cause, at CPU level
//   tb_bp           branch predictor: BTB/BHT, RAS boundaries, reset
//   tb_alu          arithmetic path: the ALUOp decode and every operation
//
// The incdir resolves tb_check.vh / tb_axil_master.vh; tb_traps and tb_alu
// also need the RTL include path for defines.vh.
// ---------------------------------------------------------------------------
+incdir+../hdl
+incdir+../../hdl

../hdl/tb_pic.v
../hdl/tb_pic_reset.v
../hdl/tb_pic_ro.v
../hdl/tb_pic_status.v
../hdl/tb_mtimer_regs.v
../hdl/tb_csr_ro.v
../hdl/tb_traps.v
../hdl/tb_bp.v
../hdl/tb_alu.v
