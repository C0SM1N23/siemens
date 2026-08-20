// S1 fetch: the PC plus the ibus AXI4-Lite read master (AR/R only).
// REQ# = spec requirement, D# = design choice, both listed in the README.
//
// Holds the PC, keeps one instruction read in flight, and asks the predictor for
// the next address. When S2 stalls it parks the returned fetch (dropping it on a
// redirect_i). Fetch bus errors ride downstream and trap in S2, not here.
//
// REQ5:  S1 stalls until the AXI read response is valid.
// REQ12: every response code is handled: OKAY plus SLVERR/DECERR (see D8).
//
// D6: the ibus master is independent of dbus, at most one outstanding, issued
//     back to back. The next ARVALID goes up the same cycle the current R beat
//     is accepted, so a latency-1 memory keeps us at 1 instr_o/cycle. The next
//     address is whatever the predictor gives us (BTB hit and taken -> target,
//     otherwise PC+4), and that prediction rides into IF/DX so S2 can check it.
// D7: when S2 stalls, a returned fetch waits in a holding reg and we issue no new
//     one until it drains, so S1 can't run ahead. An issued AXI read can't be
//     cancelled, so on a redirect_i we mark the in-flight one discard, take its
//     beat, drop it, and restart at redirect_pc_i.
// D8: a fetch bus error (RRESP = SLVERR/DECERR) doesn't stall S1. The word still
//     comes through with fetch_fault_o set and traps as an instruction access
//     fault in S2, so a wrong-path fetch error is flushed before it can trap.
//
// Reset: every flop in this module is reset by the asynchronous, active-low
// rst_n_i. The control bits and the architectural addresses need it to define the
// reset behaviour; the holding payload does not (it is never trusted unless
// hold_valid_q is set, and that bit is written in the same cycle as the
// payload), but it is reset anyway so that no flop leaves reset holding X and a
// waveform of the fetch stage is readable from time zero. The holding payload
// resets to the same canonical NOP that IF/DX uses, so even a hypothetical read
// of an invalid holding slot decodes to a harmless instruction.

`timescale 1ns/1ps

module fetch_unit #(
    parameter RESET_PC = 32'h0000_0000  // reset vector, until the memory map is settled
)(
    input             clk_i,
    input             rst_n_i,

    // ibus AXI4-Lite master, AR/R
    output     [31:0] ibus_araddr_o,
    output     [2:0]  ibus_arprot_o,
    output            ibus_arvalid_o,
    input             ibus_arready_i,
    input      [31:0] ibus_rdata_i,
    input      [1:0]  ibus_rresp_i,
    input             ibus_rvalid_i,
    output            ibus_rready_o,

    // predictor lookup for the instruction offered this cycle
    output     [31:0] bp_lookup_pc_o,
    input             bp_pred_taken_i,
    input      [31:0] bp_pred_target_i,

    // redirect_i from S2, overrides any S1 stall
    input             redirect_i,
    input      [31:0] redirect_pc_i,

    // hand-off to IF/DX
    input             s2_ready_i,      // IF/DX can load this cycle
    output            instr_valid_o,
    output     [31:0] instr_o,
    output     [31:0] instr_pc_o,
    output            pred_taken_o,
    output     [31:0] pred_target_o,
    output            fetch_fault_o
);

// instruction access, privileged (M-mode), non-secure
assign ibus_arprot_o = 3'b111;

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

// deferred fetch address (after reset, or after a redirect_i hit a busy slot)
reg [31:0] npc_q;

wire beat    = inflight_q && ibus_rvalid_i;              // R beat lands (rready=inflight)
wire beat_ok = beat && !discard_q && !redirect_i;        // beat is on the good path

assign ibus_rready_o = inflight_q;

// what we offer IF/DX; holding first (it can't coexist with a beat, since we
// never issue a fetch while the holding reg is full)
assign instr_valid_o = hold_valid_q || beat_ok;
assign instr_o       = hold_valid_q ? hold_instr_q : ibus_rdata_i;
assign instr_pc_o    = hold_valid_q ? hold_pc_q    : issued_pc_q;
assign fetch_fault_o = hold_valid_q ? hold_fault_q : ibus_rresp_i[1];

// one predictor lookup feeds both the next PC and the prediction we pass on, so
// the two always line up
assign bp_lookup_pc_o = instr_pc_o;
assign pred_taken_o   = bp_pred_taken_i;
assign pred_target_o  = bp_pred_target_i;

wire [31:0] next_pc = bp_pred_taken_i ? bp_pred_target_i : (instr_pc_o + 32'd4);

// issue a new fetch when the AXI slot is free (or frees right now via the
// beat) and the holding reg ends the cycle empty
wire slot_free  = !ar_pending_q && (!inflight_q || beat);
wire hold_after = !redirect_i && instr_valid_o && !s2_ready_i;
wire issue_now  = slot_free && !hold_after;

wire [31:0] issue_addr = redirect_i    ? redirect_pc_i :
                         instr_valid_o ? next_pc     :
                                       npc_q;       // post-reset / post-discard

// gated by rst_n_i: AXI wants VALID low in reset (IHI0022E A3.1.2), and issue_now
// is combinational so it would otherwise request RESET_PC mid-reset
assign ibus_arvalid_o = rst_n_i & (ar_pending_q | issue_now);
assign ibus_araddr_o  = ar_pending_q ? issued_pc_q : issue_addr;

wire ar_hs = ibus_arvalid_o && ibus_arready_i;

// ARVALID pending: set on an unaccepted issue, cleared by ARREADY
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        ar_pending_q <= 1'b0;
    else
        ar_pending_q <= issue_now ? !ibus_arready_i : (ar_pending_q && !ibus_arready_i);
end

// in-flight: address accepted, R beat still owed to us
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        inflight_q <= 1'b0;
    else
        inflight_q <= ar_hs ? 1'b1 : (inflight_q && !beat);
end

// address of the outstanding fetch, held stable on ARADDR until ARREADY
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        issued_pc_q <= RESET_PC;
    else if (issue_now)
        issued_pc_q <= issue_addr;
end

// discard: if a redirect_i lands while a transaction is still out, its beat is
// wrong-path, so we have to swallow it
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        discard_q <= 1'b0;
    else if (redirect_i && !slot_free)
        discard_q <= 1'b1;
    else if (beat)
        discard_q <= 1'b0;
end

// holding control: filled on an S2 stall, drained on consume, dropped on redirect_i
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        hold_valid_q <= 1'b0;
    else if (redirect_i)
        hold_valid_q <= 1'b0;
    else if (beat_ok && !s2_ready_i)
        hold_valid_q <= 1'b1;
    else if (hold_valid_q && s2_ready_i)
        hold_valid_q <= 1'b0;
end

// holding payload: written together with the fill above; reset to the canonical
// NOP / the reset vector so the slot is defined even while hold_valid_q is 0
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        hold_instr_q <= 32'h0000_0013;              // addi x0, x0, 0
        hold_pc_q    <= RESET_PC;
        hold_fault_q <= 1'b0;
    end else if (beat_ok && !s2_ready_i) begin
        hold_instr_q <= ibus_rdata_i;
        hold_pc_q    <= issued_pc_q;
        hold_fault_q <= ibus_rresp_i[1];
    end
end

// deferred address: consumed only when nothing is being delivered
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        npc_q <= RESET_PC;
    else if (redirect_i)
        npc_q <= redirect_pc_i;
end

endmodule
