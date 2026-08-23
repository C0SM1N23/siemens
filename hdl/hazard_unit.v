// Hazard & control unit: the single owner of stall/flush.
// REQ# = spec requirement, D# = design choice, both tracked in the README.
//
// Tells each stage to advance, bubble or squash, and works out S3->S2 forwarding.
//
// REQ6: centralized hazard/stall/flush unit. Stalls: fetch AXI not done -> S2
//       bubble, PC held in S1; data AXI not done -> lsu_busy_i freezes S2 and S1.
// D13: load-use uses S3->S2 forwarding instead of a stall, so zero extra cycles.
// D14: flush beats stall. Every flush (mispredict_i/trap/MRET) is gated by
//      s2_advance_o, which folds in both rules: an older flush overrides a younger
//      stall, and a multi-cycle stall finishes before S2 emits a flush that
//      depends on the op's result (e.g. an access fault known only once the AXI
//      response lands).
// D23: WFI is a third stall source: wfi_wait_i freezes S2 (and S1) like lsu_busy_i,
//      so the parked fetch stops ibus traffic. cpu_top drops wfi_wait_i on wake,
//      so an interrupt wake is just a normal trap_take_i, a masked wake commits.

`timescale 1ns/1ps

module hazard_unit (
    // pipeline state
    input        fetch_valid_i,   // S1 offers an instruction this cycle
    input        lsu_busy_i,      // data AXI op still in flight in S2
    input        wfi_wait_i,      // WFI in S2, no wake condition yet (D23)

    // redirect_o requests resolved in S2
    input        trap_take_i,     // sync exception or accepted interrupt
    input        mret_exec_i,
    input        mispredict_i,

    // S3 -> S2 forwarding detect
    input  [4:0] rs1_i,
    input  [4:0] rs2_i,
    input        wb_valid_i,
    input        wb_reg_write_i,
    input  [4:0] wb_rd_i,

    // per-stage commands
    output       s2_advance_o,    // S2 finishes its instruction this cycle
    output       redirect_o,      // fetch changes path; S1 content dropped
    output       if_dx_we_o,      // IF/DX loads (new instruction or bubble)
    output       if_dx_bubble_o,  // what it loads is a bubble
    output       dx_squash_o,     // S2 instruction must not commit to S3
    output       fwd_rs1_o,
    output       fwd_rs2_o
);

assign s2_advance_o   = ~lsu_busy_i & ~wfi_wait_i;
assign redirect_o     = (trap_take_i | mret_exec_i | mispredict_i) & s2_advance_o;
assign if_dx_we_o     = s2_advance_o;
assign if_dx_bubble_o = redirect_o | ~fetch_valid_i;
assign dx_squash_o    = trap_take_i;

// bypass when the S3 instruction writes a register S2 is reading (x0 excluded)
assign fwd_rs1_o = wb_valid_i & wb_reg_write_i & (wb_rd_i != 5'd0) & (wb_rd_i == rs1_i);
assign fwd_rs2_o = wb_valid_i & wb_reg_write_i & (wb_rd_i != 5'd0) & (wb_rd_i == rs2_i);

endmodule
