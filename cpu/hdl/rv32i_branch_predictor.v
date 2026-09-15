// Branch predictor: one-bit BHT, tagged BTB and return-address stack.
// ENTRIES must be a power of two; RAS_DEPTH must be at least one.
// Updates occur on committed control transfers. Wrong-path instructions never train.
// Calls push PC+4; returns use the stack when nonempty, otherwise the BTB.

module rv32i_branch_predictor #(
    parameter RAS_DEPTH = 8,   // return-address stack entries; 0 disables (D24)
    parameter ENTRIES   = 128  // BTB/BHT entries, power of 2 (index = PC[IDX_W+1:2])
) (
    input clk_i,
    input rst_n_i,

    // read port (S1)
    input  [31:0] lookup_pc_i,
    output        pred_taken_o,
    output [31:0] pred_target_o,

    // write port (S2 resolution)
    input        update_en_i,
    input [31:0] update_pc_i,
    input        update_taken_i,
    input [31:0] update_target_i,

    // RAS port (S2 resolution, D24)
    input        update_is_ret_i,  // committing instr is a return -> tag entry
    input        update_call_i,    // committed call: push update_link_i
    input        update_ret_i,     // committed return: pop
    input [31:0] update_link_i     // pc+4 of the committing call
);

    localparam IDX_W = $clog2(ENTRIES);  // index bits: PC[IDX_W+1:2]
    localparam TAG_W = 32 - IDX_W - 2;   // the remaining high PC bits are the tag

    // Packed arrays allow a single reset assignment per array.
    reg  [      ENTRIES-1:0] valid;  // entry holds something believable
    reg  [      ENTRIES-1:0] isret;  // entry predicts via the RAS (D24)
    reg  [      ENTRIES-1:0] state;  // 1-bit saturating direction (REQ8)
    reg  [ENTRIES*TAG_W-1:0] tag;  // TAG_W bits per entry
    reg  [   ENTRIES*32-1:0] target;  // 32 bits per entry

    wire [        IDX_W-1:0] r_idx = lookup_pc_i[IDX_W+1:2];

    // per-entry slices of the packed vectors
    wire [        TAG_W-1:0] r_tag = tag[r_idx*TAG_W+:TAG_W];
    wire [             31:0] r_target = target[r_idx*32+:32];

    wire                     hit = valid[r_idx] && (r_tag == lookup_pc_i[31:IDX_W+2]);

    // RAS top + non-empty flag, tied off when the stack is disabled
    wire [             31:0] ras_top;
    wire                     ras_ok;

    // pred_target_o is junk on a miss, only consumed when pred_taken_o=1. A return entry
    // prefers the RAS; an empty RAS falls back to the BTB target.
    assign pred_taken_o  = hit && state[r_idx];
    assign pred_target_o = (isret[r_idx] && ras_ok) ? ras_top : r_target;

    wire [IDX_W-1:0] w_idx = update_pc_i[IDX_W+1:2];

    // valid bits
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) valid <= {ENTRIES{1'b0}};
        else if (update_en_i) valid[w_idx] <= 1'b1;
    end

    // entry payload, written together with the valid bit (reset, see header).
    // One always block per register, each resetting its whole vector at once.
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) tag <= {(ENTRIES * TAG_W) {1'b0}};
        else if (update_en_i) tag[w_idx*TAG_W+:TAG_W] <= update_pc_i[31:IDX_W+2];
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) state <= {ENTRIES{1'b0}};
        else if (update_en_i) state[w_idx] <= update_taken_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) target <= {(ENTRIES * 32) {1'b0}};
        else if (update_en_i) target[w_idx*32+:32] <= update_target_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) isret <= {ENTRIES{1'b0}};
        else if (update_en_i) isret[w_idx] <= update_is_ret_i;
    end

    // Return-address stack: sp_q indexes the top; cnt_q tracks occupancy.
    // Pushes wrap and replace the oldest entry when full. Empty pops do nothing.
    generate
        if (RAS_DEPTH > 0) begin : g_ras

            localparam PW = (RAS_DEPTH <= 2) ? 1 : $clog2(RAS_DEPTH);

            reg [31:0] ras[0:RAS_DEPTH-1];
            reg [PW-1:0] sp_q;
            reg [PW:0] cnt_q;

            // push+pop together = a return that is itself a call (both-link JALR):
            // the popped slot is immediately refilled, so just replace the top
            wire push_only = update_call_i && (!update_ret_i || cnt_q == 0);
            wire pop_only = update_ret_i && !update_call_i && cnt_q != 0;
            wire replace = update_call_i && update_ret_i && cnt_q != 0;

            // top-of-stack index, sized to the pointer so the wrap compare/assign stay
            // PW bits wide (RAS_DEPTH itself is a 32-bit parameter)
            localparam [31:0] SP_MAX_W = RAS_DEPTH - 1;
            localparam [PW-1:0] SP_MAX = SP_MAX_W[PW-1:0];

            wire [PW-1:0] sp_inc = (sp_q == SP_MAX) ? {PW{1'b0}} : sp_q + 1'b1;
            wire [PW-1:0] sp_dec = (sp_q == {PW{1'b0}}) ? SP_MAX : sp_q - 1'b1;

            assign ras_top = ras[sp_q];
            assign ras_ok  = (cnt_q != 0);

            always @(posedge clk_i or negedge rst_n_i) begin
                if (~rst_n_i) sp_q <= {PW{1'b0}};
                else if (push_only) sp_q <= sp_inc;
                else if (pop_only) sp_q <= sp_dec;
            end

            always @(posedge clk_i or negedge rst_n_i) begin
                if (~rst_n_i) cnt_q <= {(PW + 1) {1'b0}};
                else if (push_only && cnt_q != RAS_DEPTH) cnt_q <= cnt_q + 1'b1;
                else if (pop_only) cnt_q <= cnt_q - 1'b1;
            end

            // stack payload: reset, so ras_top is defined even while cnt_q says empty
            integer r;
            always @(posedge clk_i or negedge rst_n_i) begin
                if (~rst_n_i) begin
                    for (r = 0; r < RAS_DEPTH; r = r + 1) ras[r] <= 32'b0;
                end else if (push_only) ras[sp_inc] <= update_link_i;
                else if (replace) ras[sp_q] <= update_link_i;
            end

        end else begin : g_no_ras
            assign ras_top = 32'b0;
            assign ras_ok  = 1'b0;
        end
    endgenerate

endmodule
