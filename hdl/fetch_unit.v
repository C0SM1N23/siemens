// S1 fetch — PC + AXI4-Lite read master on ibus, AR/R channels only.
// REQ# = spec requirement, D# = design decision; both indexed in the README.
//
// Spec requirements met here:
//   REQ5   S1 stalls while the AXI read response isn't valid yet.
//   REQ12  all response codes are handled — OKAY, and SLVERR/DECERR (see D8).
//
// Design decisions:
//   D6  the ibus master is fully independent of the dbus and keeps one
//     outstanding transaction, issued back-to-back — the next ARVALID goes up
//     the same cycle the current R beat is accepted, so a latency-1 memory
//     sustains 1 instruction/cycle. The next address is the predictor's (BTB
//     hit & taken -> target, else PC+4); the prediction rides into IF/DX so S2
//     can check it.
//   D7  if S2 stalls, a finished fetch parks in a holding register and no new
//     fetch is issued until it drains, so S1 never runs ahead. A redirect
//     (mispredict/trap/MRET) drops S1; an in-flight read can't be cancelled, so
//     it's marked discard, its beat accepted and ignored, then fetch restarts
//     at redirect_pc. This is where "flush beats stall" actually happens.
//   D8  a fetch bus error (RRESP = SLVERR/DECERR) doesn't stop S1 — the word is
//     delivered with fetch_fault set and traps as instruction-access-fault in
//     S2, so a wrong-path fetch error gets flushed before it can trap.

module fetch_unit #(
    parameter RESET_PC = 32'h0000_0000  // reset vector (pending the global memory map)
)(
    input             clk,
    input             rst_n,

    // ibus AXI4-Lite master, AR/R
    output     [31:0] ibus_araddr,
    output     [2:0]  ibus_arprot,
    output            ibus_arvalid,
    input             ibus_arready,
    input      [31:0] ibus_rdata,
    input      [1:0]  ibus_rresp,
    input             ibus_rvalid,
    output            ibus_rready,

    // predictor lookup for the instruction offered this cycle
    output     [31:0] bp_lookup_pc,
    input             bp_pred_taken,
    input      [31:0] bp_pred_target,

    // redirect from S2, overrides any S1 stall
    input             redirect,
    input      [31:0] redirect_pc,

    // hand-off to IF/DX
    input             s2_ready,      // IF/DX can load this cycle
    output            instr_valid,
    output     [31:0] instr,
    output     [31:0] instr_pc,
    output            pred_taken,
    output     [31:0] pred_target,
    output            fetch_fault
);

// instruction access, privileged (M-mode), non-secure
assign ibus_arprot = 3'b111;

// outstanding transaction state
reg        ar_pending_q;             // ARVALID up, not yet accepted
reg        inflight_q;               // address accepted, waiting for the R beat
reg        discard_q;                // in-flight fetch is wrong-path
reg [31:0] issued_pc_q;              // address of the outstanding fetch

// holding (skid) reg: instruction that arrived while S2 was stalled
reg        hold_valid_q;
reg [31:0] hold_instr_q;
reg [31:0] hold_pc_q;
reg        hold_fault_q;

// deferred fetch address (after reset, or after a redirect hit a busy slot)
reg [31:0] npc_q;

wire beat    = inflight_q && ibus_rvalid;              // R beat lands (rready=inflight)
wire beat_ok = beat && !discard_q && !redirect;        // beat is on the good path

assign ibus_rready = inflight_q;

// what we offer IF/DX; holding first (it can't coexist with a beat, since we
// never issue a fetch while the holding reg is full)
assign instr_valid = hold_valid_q || beat_ok;
assign instr       = hold_valid_q ? hold_instr_q : ibus_rdata;
assign instr_pc    = hold_valid_q ? hold_pc_q    : issued_pc_q;
assign fetch_fault = hold_valid_q ? hold_fault_q : ibus_rresp[1];

// same lookup decides the next PC and the prediction we propagate, so the two
// can never disagree
assign bp_lookup_pc = instr_pc;
assign pred_taken   = bp_pred_taken;
assign pred_target  = bp_pred_target;

wire [31:0] next_pc = bp_pred_taken ? bp_pred_target : (instr_pc + 32'd4);

// issue a new fetch when the AXI slot is free (or frees right now via the
// beat) and the holding reg ends the cycle empty
wire slot_free  = !ar_pending_q && (!inflight_q || beat);
wire hold_after = !redirect && instr_valid && !s2_ready;
wire issue_now  = slot_free && !hold_after;

wire [31:0] issue_addr = redirect    ? redirect_pc :
                         instr_valid ? next_pc     :
                                       npc_q;       // post-reset / post-discard

assign ibus_arvalid = ar_pending_q | issue_now;
assign ibus_araddr  = ar_pending_q ? issued_pc_q : issue_addr;

wire ar_hs = ibus_arvalid && ibus_arready;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        ar_pending_q <= 1'b0;
        inflight_q   <= 1'b0;
        discard_q    <= 1'b0;
        issued_pc_q  <= RESET_PC;
        hold_valid_q <= 1'b0;
        hold_instr_q <= 32'b0;
        hold_pc_q    <= 32'b0;
        hold_fault_q <= 1'b0;
        npc_q        <= RESET_PC;
    end else begin
        // AR: once VALID is up the address holds (issued_pc_q) until ARREADY
        ar_pending_q <= issue_now ? !ibus_arready : (ar_pending_q && !ibus_arready);
        inflight_q   <= ar_hs ? 1'b1 : (inflight_q && !beat);
        if (issue_now)
            issued_pc_q <= issue_addr;

        // redirect with a transaction still out -> ignore its future beat
        if (redirect && !slot_free)
            discard_q <= 1'b1;
        else if (beat)
            discard_q <= 1'b0;

        // holding: filled on an S2 stall, drained on consume, dropped on redirect
        if (redirect)
            hold_valid_q <= 1'b0;
        else if (beat_ok && !s2_ready) begin
            hold_valid_q <= 1'b1;
            hold_instr_q <= ibus_rdata;
            hold_pc_q    <= issued_pc_q;
            hold_fault_q <= ibus_rresp[1];
        end else if (hold_valid_q && s2_ready)
            hold_valid_q <= 1'b0;

        // deferred address, used only when nothing is being delivered
        if (redirect)
            npc_q <= redirect_pc;
    end
end

endmodule
