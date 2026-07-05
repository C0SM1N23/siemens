// Hazard & control unit — the single owner of stall/flush.
// REQ# = spec requirement, D# = design decision; both indexed in the README.
//
// Spec requirement met here:
//   REQ6  a dedicated, centralized hazard/stall/flush unit — the stages don't
//     manage their own stalls; this block tells each stage to advance, bubble,
//     or squash. Stall sources: fetch AXI not done (S2 bubbles, PC held in S1)
//     and data AXI not done (lsu_busy freezes S2, and S1 with it).
//
// Design decisions:
//   D13  the load-use hazard is solved by S3->S2 forwarding, not by a stall, so
//     a load feeding the next instruction costs zero extra cycles.
//   D14  flush beats stall. Every flush (mispredict / trap / MRET) is gated by
//     s2_advance, which is exactly the two priority rules: an older stage's
//     flush overrides a younger stage's stall, and a multi-cycle S2 stall
//     finishes before S2 emits a flush that depends on the op's result (e.g. an
//     access fault only known once the AXI response lands).

module hazard_unit (
    // pipeline state
    input        fetch_valid,   // S1 offers an instruction this cycle
    input        lsu_busy,      // data AXI op still in flight in S2

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

assign s2_advance   = ~lsu_busy;
assign redirect     = (trap_take | mret_exec | mispredict) & s2_advance;
assign if_dx_we     = s2_advance;
assign if_dx_bubble = redirect | ~fetch_valid;
assign dx_squash    = trap_take;

// bypass when the S3 instruction writes a register S2 is reading (x0 excluded)
assign fwd_rs1 = wb_valid & wb_reg_write & (wb_rd != 5'd0) & (wb_rd == rs1);
assign fwd_rs2 = wb_valid & wb_reg_write & (wb_rd != 5'd0) & (wb_rd == rs2);

endmodule
