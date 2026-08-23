// AXI4-Lite arbiter: M masters, one slave, round-robin, one transaction at a
// time.
//
// Used where two masters have to share a single-ported slave - in this SoC,
// the CPU's data bus and the DMA both reach the main data memory. The
// dual-port SRAM does not need one: it has two independent AXI ports, so each
// master gets its own, which is the whole reason a dual-port memory exists.
//
// ARBITRATION
// A grant is taken in IDLE by the round-robin pointer and held for exactly one
// transaction: it is released on the response beat (B for a write, R for a
// read). One transaction, not one burst - AXI4-Lite has no bursts - so no
// master can hold the slave for an unbounded time and none is starved.
//
// A parked master simply sees its READYs low, which AXI permits indefinitely.
// It never sees a partial handshake, because VALID/READY for the granted
// master are the only ones connected to the slave.
//
// CONTRACT
// A master must not have a read and a write outstanding at the same time.
// Both masters here honour that: the CPU's load/store unit runs one bus
// transaction at a time, and the burst bridge in front of the DMA issues one
// AXI4-Lite transaction per beat. The arbiter stays correct if the rule is
// broken - the second direction just waits for a later grant - but the
// property is worth stating, because it is why a single grant register is
// enough instead of one per direction.

`timescale 1ns/1ps

module axi_lite_arb #(
    parameter integer M = 2                  // number of master ports
)(
    input                  clk_i,
    input                  rst_n_i,

    // master side, packed: master i occupies bits [i*W +: W]
    input      [M*32-1:0]  m_awaddr_i,
    input      [M*3-1:0]   m_awprot_i,
    input      [M-1:0]     m_awvalid_i,
    output     [M-1:0]     m_awready_o,
    input      [M*32-1:0]  m_wdata_i,
    input      [M*4-1:0]   m_wstrb_i,
    input      [M-1:0]     m_wvalid_i,
    output     [M-1:0]     m_wready_o,
    output     [M*2-1:0]   m_bresp_o,
    output     [M-1:0]     m_bvalid_o,
    input      [M-1:0]     m_bready_i,
    input      [M*32-1:0]  m_araddr_i,
    input      [M*3-1:0]   m_arprot_i,
    input      [M-1:0]     m_arvalid_i,
    output     [M-1:0]     m_arready_o,
    output     [M*32-1:0]  m_rdata_o,
    output     [M*2-1:0]   m_rresp_o,
    output     [M-1:0]     m_rvalid_o,
    input      [M-1:0]     m_rready_i,

    // slave side
    output reg [31:0]      s_awaddr_o,
    output reg [2:0]       s_awprot_o,
    output     [0:0]       s_awvalid_o,
    input                  s_awready_i,
    output reg [31:0]      s_wdata_o,
    output reg [3:0]       s_wstrb_o,
    output     [0:0]       s_wvalid_o,
    input                  s_wready_i,
    input      [1:0]       s_bresp_i,
    input                  s_bvalid_i,
    output     [0:0]       s_bready_o,
    output reg [31:0]      s_araddr_o,
    output reg [2:0]       s_arprot_o,
    output     [0:0]       s_arvalid_o,
    input                  s_arready_i,
    input      [31:0]      s_rdata_i,
    input      [1:0]       s_rresp_i,
    input                  s_rvalid_i,
    output     [0:0]       s_rready_o
);

// ---------------------------------------------------------------------------
// request / grant
// ---------------------------------------------------------------------------
wire [M-1:0] req = m_awvalid_i | m_arvalid_i;

reg  [M-1:0] gnt;        // one-hot, zero while idle
reg  [31:0]  last;       // round-robin pointer: index of the last winner
reg  [M-1:0] sel;        // combinational winner for this cycle

integer j;
reg [31:0] cand;

always @(*) begin
    sel = {M{1'b0}};
    // walk the masters starting one past the last winner, take the first
    // one asking. Starting past `last` is what makes it round-robin rather
    // than fixed priority.
    for (j = 1; j <= M; j = j + 1) begin
        cand = (last + j) % M;
        if (sel == {M{1'b0}} && req[cand])
            sel[cand] = 1'b1;
    end
end

wire busy    = |gnt;
// one transaction per grant: let go on the response beat
wire release_gnt = (s_bvalid_i & s_bready_o[0]) | (s_rvalid_i & s_rready_o[0]);

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        gnt <= {M{1'b0}};
    else if (busy)
        gnt <= release_gnt ? {M{1'b0}} : gnt;
    else
        gnt <= sel;
end

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        last <= {32{1'b0}};
    else if (!busy && |sel) begin
        for (j = 0; j < M; j = j + 1)
            if (sel[j]) last <= j;
    end
end

// ---------------------------------------------------------------------------
// granted master's payload onto the slave
// ---------------------------------------------------------------------------
integer k;

always @(*) begin
    s_awaddr_o = 32'h0;
    s_awprot_o = 3'b000;
    s_wdata_o  = 32'h0;
    s_wstrb_o  = 4'h0;
    s_araddr_o = 32'h0;
    s_arprot_o = 3'b000;
    for (k = 0; k < M; k = k + 1)
        if (gnt[k]) begin
            s_awaddr_o = m_awaddr_i[k*32 +: 32];
            s_awprot_o = m_awprot_i[k*3  +: 3];
            s_wdata_o  = m_wdata_i [k*32 +: 32];
            s_wstrb_o  = m_wstrb_i [k*4  +: 4];
            s_araddr_o = m_araddr_i[k*32 +: 32];
            s_arprot_o = m_arprot_i[k*3  +: 3];
        end
end

assign s_awvalid_o[0] = |(gnt & m_awvalid_i);
assign s_wvalid_o [0] = |(gnt & m_wvalid_i);
assign s_bready_o [0] = |(gnt & m_bready_i);
assign s_arvalid_o[0] = |(gnt & m_arvalid_i);
assign s_rready_o [0] = |(gnt & m_rready_i);

// ---------------------------------------------------------------------------
// slave's responses back to the granted master, everyone else sees zeros
// ---------------------------------------------------------------------------
genvar g;
generate
    for (g = 0; g < M; g = g + 1) begin : g_fanin
        assign m_awready_o[g]         = gnt[g] & s_awready_i;
        assign m_wready_o [g]         = gnt[g] & s_wready_i;
        assign m_bvalid_o [g]         = gnt[g] & s_bvalid_i;
        assign m_bresp_o  [g*2  +: 2] = s_bresp_i;
        assign m_arready_o[g]         = gnt[g] & s_arready_i;
        assign m_rvalid_o [g]         = gnt[g] & s_rvalid_i;
        assign m_rresp_o  [g*2  +: 2] = s_rresp_i;
        assign m_rdata_o  [g*32 +: 32] = s_rdata_i;
    end
endgenerate

endmodule
