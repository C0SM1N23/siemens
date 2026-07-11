// Hazard & control unit — the single owner of stall/flush.
// REQ# = spec requirement, D# = design choice; both tracked in the README.
//
// Tells each stage to advance, bubble or squash (stages never manage their own
// stalls) and detects when S3's result must forward into S2.
//
// REQ6: dedicated centralized hazard/stall/flush unit. Stall sources: fetch AXI
//       not done -> S2 bubble, PC held in S1; data AXI not done -> lsu_busy
//       freezes S2 and S1 with it.
// D13: load-use is solved by S3->S2 forwarding, not a stall — a load feeding
//      the next instruction costs zero extra cycles.
// D14: flush beats stall. Every flush (mispredict/trap/MRET) is gated by
//      s2_advance, which encodes both priority rules: an older flush overrides a
//      younger stall, and a multi-cycle S2 stall finishes before S2 emits a
//      flush that depends on the op's result (e.g. an access fault known only
//      once the AXI response lands).
// D23: WFI sleeps here as a third stall source — wfi_wait freezes S2 like
//      lsu_busy, and S1 with it (the parked fetch stops all ibus traffic).
//      cpu_top drops wfi_wait on wake, so no extra rule is needed: an interrupt
//      wake becomes a normal trap_take, a masked wake just commits.

module hazard_unit (
    // pipeline state
    input        fetch_valid,   // S1 offers an instruction this cycle
    input        lsu_busy,      // data AXI op still in flight in S2
    input        wfi_wait,      // WFI in S2, no wake condition yet (D23)

    // redirect requests resolved in S2
    input        trap_take,     // sync exception or accepted interrupt
    input        mret_exec,
    input        mispredict,

    // S3 -> S2 forwarding detect
    input  [4:0] rs1,
    input  [4:0] rs2,
    input        wb_valid,
    input        wb_reg_write,
    input  [4:0] wb_rd,

    // per-stage commands
    output       s2_advance,    // S2 finishes its instruction this cycle
    output       redirect,      // fetch changes path; S1 content dropped
    output       if_dx_we,      // IF/DX loads (new instruction or bubble)
    output       if_dx_bubble,  // what it loads is a bubble
    output       dx_squash,     // S2 instruction must not commit to S3
    output       fwd_rs1,
    output       fwd_rs2
);

assign s2_advance   = ~lsu_busy & ~wfi_wait;
assign redirect     = (trap_take | mret_exec | mispredict) & s2_advance;
assign if_dx_we     = s2_advance;
assign if_dx_bubble = redirect | ~fetch_valid;
assign dx_squash    = trap_take;

// bypass when the S3 instruction writes a register S2 is reading (x0 excluded)
assign fwd_rs1 = wb_valid & wb_reg_write & (wb_rd != 5'd0) & (wb_rd == rs1);
assign fwd_rs2 = wb_valid & wb_reg_write & (wb_rd != 5'd0) & (wb_rd == rs2);

endmodule
