// Branch predictor — combined BHT + BTB.
// REQ# = spec requirement, D# = design decision; both indexed in the README.
//
// Spec requirement met here:
//   REQ8  a 1-bit saturating predictor — each branch records its last outcome
//     and that predicts the next encounter.
//
// Design decisions (the structure the spec left to the intern):
//   D9   direct-mapped, 128 entries, index = PC[8:2], tag = PC[31:9], with a
//     stored 32-bit target next to the 1-bit state. The target is the point of
//     the BTB: it lets S1 redirect on a taken prediction, which a bare
//     direction bit can't do — in fetch the immediate isn't decoded yet.
//   D10  a miss predicts not-taken (no target is known, so fetch PC+4).
//   D11  entries are learned at S2 resolution, committed instructions only, so
//     the state is never speculative. They are kept across traps/MRET; those
//     redirects (mtvec/mepc) are architectural and bypass the predictor.
//
// Read port is combinational in S1; the write port updates in S2.

module branch_predictor (
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
    input      [31:0] update_target
);

reg         valid  [0:127];
reg  [22:0] tag    [0:127];
reg         state  [0:127];
reg  [31:0] target [0:127];

wire [6:0] r_idx = lookup_pc[8:2];
wire       hit   = valid[r_idx] && (tag[r_idx] == lookup_pc[31:9]);

// pred_target is junk on a miss — only consumed when pred_taken=1
assign pred_taken  = hit && state[r_idx];
assign pred_target = target[r_idx];

wire [6:0] w_idx = update_pc[8:2];

integer i;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0; i < 128; i = i + 1)
            valid[i] <= 1'b0;
    end else if (update_en) begin
        valid [w_idx] <= 1'b1;
        tag   [w_idx] <= update_pc[31:9];
        state [w_idx] <= update_taken;
        target[w_idx] <= update_target;
    end
end

endmodule
