// A minimal AXI4-Lite slave: one transaction outstanding per direction, both
// responses registered, and read data that says which slave answered and which
// address it answered for.
//
// Used by soc_tb_pulp_compare, where the same stub sits behind both
// interconnects under comparison, so a difference in the recorded data is a
// difference in routing and not a difference in the slaves.

module soc_lite_slave_stub #(
    parameter [15:0] ID = 16'h0000
) (
    input clk_i,
    input rst_n_i,

    input  [31:0] s_awaddr_i,
    input         s_awvalid_i,
    output        s_awready_o,
    input  [31:0] s_wdata_i,
    input  [ 3:0] s_wstrb_i,
    input         s_wvalid_i,
    output        s_wready_o,
    output [ 1:0] s_bresp_o,
    output        s_bvalid_o,
    input         s_bready_i,
    input  [31:0] s_araddr_i,
    input         s_arvalid_i,
    output        s_arready_o,
    output [31:0] s_rdata_o,
    output [ 1:0] s_rresp_o,
    output        s_rvalid_o,
    input         s_rready_i,

    // how many address handshakes this slave accepted
    output reg [31:0] ar_count_o,
    output reg [31:0] aw_count_o
);

    reg        aw_q, w_q, b_q, r_q;
    reg [31:0] rdata_q;
    reg [31:0] last_wdata_q;

    assign s_awready_o = ~aw_q & ~b_q;
    assign s_wready_o  = ~w_q & ~b_q;
    assign s_bresp_o   = 2'b00;
    assign s_bvalid_o  = b_q;
    assign s_arready_o = ~r_q;
    assign s_rdata_o   = rdata_q;
    assign s_rresp_o   = 2'b00;
    assign s_rvalid_o  = r_q;

    wire aw_hs = s_awvalid_i & s_awready_o;
    wire w_hs = s_wvalid_i & s_wready_o;
    wire b_hs = b_q & s_bready_i;
    wire ar_hs = s_arvalid_i & s_arready_o;
    wire r_hs = r_q & s_rready_i;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) aw_q <= 1'b0;
        else if (b_hs) aw_q <= 1'b0;
        else if (aw_hs) aw_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_q <= 1'b0;
        else if (b_hs) w_q <= 1'b0;
        else if (w_hs) w_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) b_q <= 1'b0;
        else if (b_hs) b_q <= 1'b0;
        else if ((aw_q | aw_hs) && (w_q | w_hs)) b_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) r_q <= 1'b0;
        else if (r_hs) r_q <= 1'b0;
        else if (ar_hs) r_q <= 1'b1;
    end

    // the answer names the slave and the word it came from
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rdata_q <= 32'h0;
        else if (ar_hs) rdata_q <= {ID, s_araddr_i[15:0]};
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) last_wdata_q <= 32'h0;
        else if (w_hs) last_wdata_q <= s_wdata_i & {{8{s_wstrb_i[3]}}, {8{s_wstrb_i[2]}},
                                                   {8{s_wstrb_i[1]}}, {8{s_wstrb_i[0]}}};
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) ar_count_o <= 32'd0;
        else if (ar_hs) ar_count_o <= ar_count_o + 32'd1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) aw_count_o <= 32'd0;
        else if (aw_hs) aw_count_o <= aw_count_o + 32'd1;
    end

endmodule
