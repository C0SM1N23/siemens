// AXI4-Lite arbiter: M masters, one slave, round-robin between transactions.
// Each grant locks one direction until its response handshake, and carries
// exactly one address and one data beat: a grant is one transaction, not a
// window during which the holder may start more.
// A simultaneous read/write request receives a write grant first; the read waits.
// Forward progress requires the selected slave and master to complete their handshakes.

module soc_axi_lite_arb #(
    parameter integer M = 2  // number of master ports
) (
    input clk_i,
    input rst_n_i,

    // master side, packed: master i occupies bits [i*W +: W]
    input  [M*32-1:0] m_awaddr_i,
    input  [ M*3-1:0] m_awprot_i,
    input  [   M-1:0] m_awvalid_i,
    output [   M-1:0] m_awready_o,
    input  [M*32-1:0] m_wdata_i,
    input  [ M*4-1:0] m_wstrb_i,
    input  [   M-1:0] m_wvalid_i,
    output [   M-1:0] m_wready_o,
    output [ M*2-1:0] m_bresp_o,
    output [   M-1:0] m_bvalid_o,
    input  [   M-1:0] m_bready_i,
    input  [M*32-1:0] m_araddr_i,
    input  [ M*3-1:0] m_arprot_i,
    input  [   M-1:0] m_arvalid_i,
    output [   M-1:0] m_arready_o,
    output [M*32-1:0] m_rdata_o,
    output [ M*2-1:0] m_rresp_o,
    output [   M-1:0] m_rvalid_o,
    input  [   M-1:0] m_rready_i,

    // slave side
    output reg [31:0] s_awaddr_o,
    output reg [ 2:0] s_awprot_o,
    output     [ 0:0] s_awvalid_o,
    input             s_awready_i,
    output reg [31:0] s_wdata_o,
    output reg [ 3:0] s_wstrb_o,
    output     [ 0:0] s_wvalid_o,
    input             s_wready_i,
    input      [ 1:0] s_bresp_i,
    input             s_bvalid_i,
    output     [ 0:0] s_bready_o,
    output reg [31:0] s_araddr_o,
    output reg [ 2:0] s_arprot_o,
    output     [ 0:0] s_arvalid_o,
    input             s_arready_i,
    input      [31:0] s_rdata_i,
    input      [ 1:0] s_rresp_i,
    input             s_rvalid_i,
    output     [ 0:0] s_rready_o
);

    // request / grant
    wire [M-1:0] req = m_awvalid_i | m_arvalid_i;

    reg  [M-1:0] gnt;  // one-hot, zero while idle
    reg  [ 31:0] last;  // round-robin pointer: index of the last winner
    reg  [M-1:0] sel;  // combinational winner for this cycle

    always @(*) begin : select_master
        integer j;
        sel = {M{1'b0}};
        // walk the masters starting one past the last winner, take the first
        // one asking. Starting past `last` is what makes it round-robin rather
        // than fixed priority.
        for (j = 1; j <= M; j = j + 1) begin
            if (sel == {M{1'b0}} && req[(last+j)%M]) sel[(last+j)%M] = 1'b1;
        end
    end

    // A grant owns one direction. If both request, service the write first.
    reg  write_grant_q;
    wire busy = |gnt;
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) write_grant_q <= 1'b0;
        else if (!busy && |sel) write_grant_q <= |(sel & m_awvalid_i);
    end

    // one transaction per grant: let go on the response beat
    wire release_gnt = (s_bvalid_i & s_bready_o[0]) | (s_rvalid_i & s_rready_o[0]);

    // What this grant has already handed to the slave. A write's address and
    // data may arrive in either order and in different cycles, so they are
    // tracked apart; each is forwarded once. Without this, a master that raises
    // its next AWVALID before taking the B of the current write would reach the
    // slave a second time under the same grant, and a Lite slave that accepts
    // one transaction at a time would be holding two - the second write's data
    // paired with the first write's address.
    reg  aw_taken_q, w_taken_q, ar_taken_q;

    wire s_aw_hs = s_awvalid_o[0] & s_awready_i;
    wire s_w_hs = s_wvalid_o[0] & s_wready_i;
    wire s_ar_hs = s_arvalid_o[0] & s_arready_i;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) aw_taken_q <= 1'b0;
        else if (release_gnt) aw_taken_q <= 1'b0;
        else if (s_aw_hs) aw_taken_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) w_taken_q <= 1'b0;
        else if (release_gnt) w_taken_q <= 1'b0;
        else if (s_w_hs) w_taken_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) ar_taken_q <= 1'b0;
        else if (release_gnt) ar_taken_q <= 1'b0;
        else if (s_ar_hs) ar_taken_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) gnt <= {M{1'b0}};
        else if (busy) gnt <= release_gnt ? {M{1'b0}} : gnt;
        else gnt <= sel;
    end

    always @(posedge clk_i or negedge rst_n_i) begin : remember_master
        integer j;
        if (~rst_n_i) last <= {32{1'b0}};
        else if (!busy && |sel) begin
            for (j = 0; j < M; j = j + 1) if (sel[j]) last <= j;
        end
    end

    // granted master's payload onto the slave

    always @(*) begin : update_s_awaddr_o
        integer k;
        s_awaddr_o = 32'h0;
        for (k = 0; k < M; k = k + 1) if (gnt[k]) s_awaddr_o = m_awaddr_i[k*32+:32];
    end

    always @(*) begin : update_s_awprot_o
        integer k;
        s_awprot_o = 3'b000;
        for (k = 0; k < M; k = k + 1) if (gnt[k]) s_awprot_o = m_awprot_i[k*3+:3];
    end

    always @(*) begin : update_s_wdata_o
        integer k;
        s_wdata_o = 32'h0;
        for (k = 0; k < M; k = k + 1) if (gnt[k]) s_wdata_o = m_wdata_i[k*32+:32];
    end

    always @(*) begin : update_s_wstrb_o
        integer k;
        s_wstrb_o = 4'h0;
        for (k = 0; k < M; k = k + 1) if (gnt[k]) s_wstrb_o = m_wstrb_i[k*4+:4];
    end

    always @(*) begin : update_s_araddr_o
        integer k;
        s_araddr_o = 32'h0;
        for (k = 0; k < M; k = k + 1) if (gnt[k]) s_araddr_o = m_araddr_i[k*32+:32];
    end

    always @(*) begin : update_s_arprot_o
        integer k;
        s_arprot_o = 3'b000;
        for (k = 0; k < M; k = k + 1) if (gnt[k]) s_arprot_o = m_arprot_i[k*3+:3];
    end

    assign s_awvalid_o[0] = write_grant_q && !aw_taken_q && |(gnt & m_awvalid_i);
    assign s_wvalid_o[0]  = write_grant_q && !w_taken_q && |(gnt & m_wvalid_i);
    assign s_bready_o[0]  = write_grant_q && |(gnt & m_bready_i);
    assign s_arvalid_o[0] = !write_grant_q && !ar_taken_q && |(gnt & m_arvalid_i);
    assign s_rready_o[0]  = !write_grant_q && |(gnt & m_rready_i);

    // slave's responses back to the granted master, everyone else sees zeros
    genvar g;
    generate
        for (g = 0; g < M; g = g + 1) begin : g_fanin
            assign m_awready_o[g]      = gnt[g] & write_grant_q & ~aw_taken_q & s_awready_i;
            assign m_wready_o[g]       = gnt[g] & write_grant_q & ~w_taken_q & s_wready_i;
            assign m_bvalid_o[g]       = gnt[g] & write_grant_q & s_bvalid_i;
            assign m_bresp_o[g*2+:2]   = s_bresp_i;
            assign m_arready_o[g]      = gnt[g] & ~write_grant_q & ~ar_taken_q & s_arready_i;
            assign m_rvalid_o[g]       = gnt[g] & ~write_grant_q & s_rvalid_i;
            assign m_rresp_o[g*2+:2]   = s_rresp_i;
            assign m_rdata_o[g*32+:32] = s_rdata_i;
        end
    endgenerate

endmodule
