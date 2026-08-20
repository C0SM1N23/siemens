// Branch predictor: combined BHT + BTB + RAS.
// REQ# = spec requirement, D# = design choice, both tracked in the README.
//
// REQ8: 1-bit saturating predictor: each branch records its last outcome, which
//       predicts the next encounter.
// D9:  direct-mapped, 128 entries, index PC[8:2], tag PC[31:9], plus a stored
//      32-bit target next to the 1-bit state. The target is the whole point of
//      the BTB: at fetch the immediate isn't decoded yet, so a direction bit
//      alone can't say where to go.
// D10: a miss predicts not-taken (no target, so fetch PC+4).
// D11: entries are learned at S2 resolution, committed instructions only, so
//      state is never speculative. They survive traps/MRET, whose redirects
//      (mtvec/mepc) are architectural and bypass the predictor.
// D24: return-address stack (RAS_DEPTH entries, 0 disables). The BTB's stored
//      target is the last target, wrong for a return reached from several call
//      sites. Calls (rd = x1/x5, the ISA JALR hint table) push pc+4 at commit,
//      returns pop, and a BTB entry learned from a return is tagged is_ret and
//      predicts the RAS top instead. Push+pop together (both-link JALR, rd !=
//      rs1) replaces the top. Updates happen at the BTB commit point, so RAS
//      state is never speculative; wrong-path fetches only peek. Overflow wraps
//      and underflow falls back to the BTB target, so only accuracy is ever at
//      stake, never correctness.
//
// Reset: every flop in this module, including the BTB payload arrays and the
// return-address stack, is reset by the asynchronous, active-low rst_n_i.
// Functionally only the valid bits and the RAS counter need it -- an entry is
// never believed until its valid bit is set, and valid is set together with a
// full payload write. The payload arrays are reset all the same so that the
// predictor holds no X after reset: pred_target_o is read combinationally on every
// lookup, hit or miss, and an X there is visible in every waveform of the fetch
// path and would propagate into the next-PC mux in a 2-state model.
//
// Cost note: this puts ENTRIES x (TAG_W + 1 + 32) + RAS_DEPTH x 32 flops (about
// 7.2 kbit at the default ENTRIES = 128, RAS_DEPTH = 8) on the reset tree. This
// is a deliberate trade of area/reset-tree size for a fully X-free design; if a
// future synthesis target cannot afford it, the two payload always blocks below
// are the only places to change, and the design stays functionally identical.

`timescale 1ns/1ps

module branch_predictor #(
    parameter RAS_DEPTH = 8,    // return-address stack entries; 0 disables (D24)
    parameter ENTRIES   = 128   // BTB/BHT entries, power of 2 (index = PC[IDX_W+1:2])
)(
    input             clk_i,
    input             rst_n_i,

    // read port (S1)
    input      [31:0] lookup_pc_i,
    output            pred_taken_o,
    output     [31:0] pred_target_o,

    // write port (S2 resolution)
    input             update_en_i,
    input      [31:0] update_pc_i,
    input             update_taken_i,
    input      [31:0] update_target_i,

    // RAS port (S2 resolution, D24)
    input             update_is_ret_i,  // committing instr is a return -> tag entry
    input             update_call_i,    // committed call: push update_link_i
    input             update_ret_i,     // committed return: pop
    input      [31:0] update_link_i     // pc+4 of the committing call
);

localparam IDX_W = $clog2(ENTRIES);   // index bits: PC[IDX_W+1:2]
localparam TAG_W = 32 - IDX_W - 2;    // the remaining high PC bits are the tag

reg [ENTRIES-1:0] valid;              // packed: resets in one assignment
reg [ENTRIES-1:0] isret;              // entry predicts via the RAS (D24)
reg  [TAG_W-1:0]  tag    [0:ENTRIES-1];
reg               state  [0:ENTRIES-1];
reg  [31:0]       target [0:ENTRIES-1];

wire [IDX_W-1:0] r_idx = lookup_pc_i[IDX_W+1:2];
wire             hit   = valid[r_idx] && (tag[r_idx] == lookup_pc_i[31:IDX_W+2]);

// RAS top + non-empty flag, tied off when the stack is disabled
wire [31:0] ras_top;
wire        ras_ok;

// pred_target_o is junk on a miss, only consumed when pred_taken_o=1. A return entry
// prefers the RAS; an empty RAS falls back to the BTB target.
assign pred_taken_o  = hit && state[r_idx];
assign pred_target_o = (isret[r_idx] && ras_ok) ? ras_top : target[r_idx];

wire [IDX_W-1:0] w_idx = update_pc_i[IDX_W+1:2];

// valid bits: the only resettable state
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        valid <= {ENTRIES{1'b0}};
    else if (update_en_i)
        valid[w_idx] <= 1'b1;
end

// entry payload, written together with the valid bit (reset, see header)
integer e;
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        for (e = 0; e < ENTRIES; e = e + 1) begin
            tag   [e] <= {TAG_W{1'b0}};
            state [e] <= 1'b0;
            target[e] <= 32'b0;
        end
        isret <= {ENTRIES{1'b0}};
    end else if (update_en_i) begin
        tag   [w_idx] <= update_pc_i[31:IDX_W+2];
        state [w_idx] <= update_taken_i;
        target[w_idx] <= update_target_i;
        isret [w_idx] <= update_is_ret_i;
    end
end

// --- return address stack (D24) ---
// sp_q points at the top; cnt_q saturates at RAS_DEPTH, just for the empty
// check. Call chains deeper than RAS_DEPTH wrap and lose the oldest entry, and
// pops past a wrap read stale links: a mispredict, never a correctness problem
// (branch_unit computes the real target regardless).
generate if (RAS_DEPTH > 0) begin : g_ras

    localparam PW = (RAS_DEPTH <= 2) ? 1 : $clog2(RAS_DEPTH);

    reg [31:0]   ras [0:RAS_DEPTH-1];
    reg [PW-1:0] sp_q;
    reg [PW:0]   cnt_q;

    // push+pop together = a return that is itself a call (both-link JALR):
    // the popped slot is immediately refilled, so just replace the top
    wire push_only = update_call_i && (!update_ret_i || cnt_q == 0);
    wire pop_only  = update_ret_i  && !update_call_i && cnt_q != 0;
    wire replace   = update_call_i &&  update_ret_i  && cnt_q != 0;

    // top-of-stack index, sized to the pointer so the wrap compare/assign stay
    // PW bits wide (RAS_DEPTH itself is a 32-bit parameter)
    localparam [31:0]   SP_MAX_W = RAS_DEPTH - 1;
    localparam [PW-1:0] SP_MAX   = SP_MAX_W[PW-1:0];

    wire [PW-1:0] sp_inc = (sp_q == SP_MAX) ? {PW{1'b0}} : sp_q + 1'b1;
    wire [PW-1:0] sp_dec = (sp_q == {PW{1'b0}}) ? SP_MAX : sp_q - 1'b1;

    assign ras_top = ras[sp_q];
    assign ras_ok  = (cnt_q != 0);

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            sp_q <= {PW{1'b0}};
        else if (push_only)
            sp_q <= sp_inc;
        else if (pop_only)
            sp_q <= sp_dec;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            cnt_q <= {(PW+1){1'b0}};
        else if (push_only && cnt_q != RAS_DEPTH)
            cnt_q <= cnt_q + 1'b1;
        else if (pop_only)
            cnt_q <= cnt_q - 1'b1;
    end

    // stack payload: reset, so ras_top is defined even while cnt_q says empty
    integer r;
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            for (r = 0; r < RAS_DEPTH; r = r + 1)
                ras[r] <= 32'b0;
        end else if (push_only)
            ras[sp_inc] <= update_link_i;
        else if (replace)
            ras[sp_q] <= update_link_i;
    end

end else begin : g_no_ras
    assign ras_top = 32'b0;
    assign ras_ok  = 1'b0;
end endgenerate

endmodule
