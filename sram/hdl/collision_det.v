// =============================================================================
//
// Decides what happens when there are collisions on the two ports
// Applies stall when there are too many collisions
// Real collisions = R+W and W+W
// Collisions are resolved on the spot (combinationally), no state needed for that
// added collision/cooldown event signals so they can be used in regfile
//
// =============================================================================

module collision_det #(
    parameter ADDR_W = 10 // address width
) (
    // Clock and reset
    input  wire              clk_i,
    input  wire              rst_n_i,

    // Port A request
    input  wire               a_mem_valid_i, // does Port A have an active request?
    input  wire [ADDR_W-1:0]  a_mem_addr_i,  // requested address
    input  wire                a_mem_write_i,// write or read

    // Port B request
    input  wire               b_mem_valid_i,
    input  wire [ADDR_W-1:0]  b_mem_addr_i,
    input  wire                b_mem_write_i,

    // From regfile
    input  wire                force_priority_i, // 0 = Port A, 1 = Port B wins

    input  wire [7:0]         collision_threshold_i, // threshold before entering stall
    input  wire [7:0]         cooldown_cycles_i,     // how long it stays in stall

    // To axi4lite_slave_fsm.v
    output wire                a_mem_error_o, // 1 = SLVERR Port A
    output wire                b_mem_error_o, // 1 = SLVERR Port B

    output wire                a_stall_o,
    output wire                b_stall_o,

    // To mem_array.v
    output wire                a_write_grant_o,
    output wire                b_write_grant_o,

    // To regfile.v
    output wire                collision_event_o, // a collision occurred
    output wire                cooldown_event_o   // entered cooldown
);

    // collision classification
    wire addr_match = a_mem_valid_i & b_mem_valid_i & (a_mem_addr_i == b_mem_addr_i);
    wire is_rd_rd   = addr_match & !a_mem_write_i & !b_mem_write_i;
    wire is_rd_wr   = addr_match & (a_mem_write_i ^ b_mem_write_i);
    wire is_wr_wr   = addr_match & a_mem_write_i & b_mem_write_i;

    wire real_conflict = is_rd_wr | is_wr_wr;

    wire a_loses = (is_rd_wr & !a_mem_write_i) | (is_wr_wr & force_priority_i);
    wire b_loses = (is_rd_wr & !b_mem_write_i) | (is_wr_wr & !force_priority_i);

    assign a_mem_error_o = a_loses; // Port A gets SLVERR
    assign b_mem_error_o = b_loses; // Port B gets SLVERR

    assign a_write_grant_o = a_mem_write_i & !(is_wr_wr & a_loses); // A gets the write grant
    assign b_write_grant_o = b_mem_write_i & !(is_wr_wr & b_loses); // B gets the write grant

    // fsm states
    localparam S_ACTIVE   = 1'b0;
    localparam S_COOLDOWN = 1'b1; // stall active on both A and B

    reg       arb_state;
    reg       next_arb_state;
    reg [7:0] collision_cnt;  // count the collisions
    reg [7:0] cooldown_cnt;   // cooldown counter

    wire threshold_hit = (arb_state == S_ACTIVE) && real_conflict &&
                          (collision_cnt + 8'd1 == collision_threshold_i);
    wire cooldown_done = (cooldown_cnt + 8'd1 == cooldown_cycles_i);

    assign collision_event_o = real_conflict;
    assign cooldown_event_o  = threshold_hit;

    assign a_stall_o = (arb_state == S_COOLDOWN);
    assign b_stall_o = (arb_state == S_COOLDOWN);

    // transition logic
    always @(*) begin
        case (arb_state)
            S_ACTIVE:   next_arb_state = threshold_hit ? S_COOLDOWN : S_ACTIVE;
            S_COOLDOWN: next_arb_state = cooldown_done ? S_ACTIVE   : S_COOLDOWN;
            default:    next_arb_state = S_ACTIVE;
        endcase
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            arb_state <= S_ACTIVE;
        else
            arb_state <= next_arb_state;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            collision_cnt <= 8'd0;
        else if (arb_state == S_ACTIVE && real_conflict) begin
            if (threshold_hit)
                collision_cnt <= 8'd0;
            else
                collision_cnt <= collision_cnt + 8'd1;
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            cooldown_cnt <= 8'd0;
        else if (arb_state == S_COOLDOWN)
            cooldown_cnt <= cooldown_done ? 8'd0 : cooldown_cnt + 8'd1;
        else
            cooldown_cnt <= 8'd0;
    end

endmodule
