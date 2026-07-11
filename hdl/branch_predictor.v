// Branch predictor — combined BHT + BTB + RAS.
// REQ# = spec requirement, D# = design choice; both tracked in the README.
//
// REQ8: 1-bit saturating predictor — each branch records its last outcome,
//       which predicts the next encounter.
// D9:  direct-mapped, 128 entries, index PC[8:2], tag PC[31:9], plus a stored
//      32-bit target next to the 1-bit state. The target is the point of the
//      BTB: at fetch the immediate isn't decoded yet, so a direction bit alone
//      couldn't say where to go.
// D10: a miss predicts not-taken (no target, so fetch PC+4).
// D11: entries are learned at S2 resolution, committed instructions only, so
//      state is never speculative. Entries survive traps/MRET — those redirects
//      (mtvec/mepc) are architectural and bypass the predictor.
// D24: return-address stack (RAS_DEPTH entries, 0 disables). The BTB's stored
//      target is the last target, wrong for a return reached from several call
//      sites. Calls (rd = x1/x5, the ISA JALR hint table) push pc+4 at commit,
//      returns pop, and a BTB entry learned from a return is tagged is_ret and
//      predicts the RAS top instead. Push+pop together (both-link JALR,
//      rd != rs1) replaces the top. Updates happen at the BTB's commit point,
//      so RAS state is never speculative — wrong-path fetches only peek.
//      Overflow wraps, underflow falls back to the BTB target; either way only
//      accuracy is at stake, never correctness.
//
// Only the valid bits get a reset. The tag/state/target arrays (~7k bits)
// don't: an entry is never believed until its valid bit is set, and valid is
// set together with a full payload write, so keeping reset off the big arrays
// keeps the reset tree small.

module branch_predictor #(
    parameter RAS_DEPTH = 8     // return-address stack entries; 0 disables (D24)
)(
    input             clk,
    input             rst_n,

    // read port (S1)
    input      [31:0] lookup_pc,
    output            pred_taken,
    output     [31:0] pred_target,

    // write port (S2 resolution)
    input             update_en,
    input      [31:0] update_pc,
    input             update_taken,
    input      [31:0] update_target,

    // RAS port (S2 resolution, D24)
    input             update_is_ret,  // committing instr is a return -> tag entry
    input             update_call,    // committed call: push update_link
    input             update_ret,     // committed return: pop
    input      [31:0] update_link     // pc+4 of the committing call
);

reg [127:0] valid;              // packed: resets in one assignment
reg [127:0] isret;              // entry predicts via the RAS (D24)
reg  [22:0] tag    [0:127];
reg         state  [0:127];
reg  [31:0] target [0:127];

wire [6:0] r_idx = lookup_pc[8:2];
wire       hit   = valid[r_idx] && (tag[r_idx] == lookup_pc[31:9]);

// RAS top + non-empty flag, tied off when the stack is disabled
wire [31:0] ras_top;
wire        ras_ok;

// pred_target is junk on a miss — only consumed when pred_taken=1;
// a return entry prefers the RAS, an empty RAS falls back to the BTB target
assign pred_taken  = hit && state[r_idx];
assign pred_target = (isret[r_idx] && ras_ok) ? ras_top : target[r_idx];

wire [6:0] w_idx = update_pc[8:2];

// valid bits: the only resettable state
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        valid <= 128'b0;
    else if (update_en)
        valid[w_idx] <= 1'b1;
end

// entry payload, written together with the valid bit (no reset — see header)
always @(posedge clk) begin
    if (update_en) begin
        tag   [w_idx] <= update_pc[31:9];
        state [w_idx] <= update_taken;
        target[w_idx] <= update_target;
        isret [w_idx] <= update_is_ret;
    end
end

// --- return address stack (D24) ---
// sp_q points at the top; cnt_q saturates at RAS_DEPTH and only exists for
// the empty check. Deeper-than-RAS_DEPTH call chains wrap and lose the
// oldest entry; pops past a wrap read stale links — a mispredict, never a
// correctness problem (branch_unit computes the real target regardless).
generate if (RAS_DEPTH > 0) begin : g_ras

    localparam PW = (RAS_DEPTH <= 2) ? 1 : $clog2(RAS_DEPTH);

    reg [31:0]   ras [0:RAS_DEPTH-1];
    reg [PW-1:0] sp_q;
    reg [PW:0]   cnt_q;

    // push+pop together = a return that is itself a call (both-link JALR):
    // the popped slot is immediately refilled, so just replace the top
    wire push_only = update_call && (!update_ret || cnt_q == 0);
    wire pop_only  = update_ret  && !update_call && cnt_q != 0;
    wire replace   = update_call &&  update_ret  && cnt_q != 0;

    wire [PW-1:0] sp_inc = (sp_q == RAS_DEPTH - 1) ? {PW{1'b0}} : sp_q + 1'b1;
    wire [PW-1:0] sp_dec = (sp_q == {PW{1'b0}}) ? RAS_DEPTH - 1 : sp_q - 1'b1;

    assign ras_top = ras[sp_q];
    assign ras_ok  = (cnt_q != 0);

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            sp_q <= {PW{1'b0}};
        else if (push_only)
            sp_q <= sp_inc;
        else if (pop_only)
            sp_q <= sp_dec;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            cnt_q <= {(PW+1){1'b0}};
        else if (push_only && cnt_q != RAS_DEPTH)
            cnt_q <= cnt_q + 1'b1;
        else if (pop_only)
            cnt_q <= cnt_q - 1'b1;
    end

    // stack payload — no reset, never believed while cnt_q says empty
    always @(posedge clk) begin
        if (push_only)
            ras[sp_inc] <= update_link;
        else if (replace)
            ras[sp_q] <= update_link;
    end

end else begin : g_no_ras
    assign ras_top = 32'b0;
    assign ras_ok  = 1'b0;
end endgenerate

endmodule
