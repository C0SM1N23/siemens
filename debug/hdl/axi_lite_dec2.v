// 1-master / 2-slave AXI4-Lite address decoder: TB stand-in for the SoC
// interconnect (like axi_lite_arb2, but for the slave side).
//
// Slave 1 owns the window (addr & S1_MASK) == S1_BASE; everything else goes to
// slave 0 (the default, which answers DECERR out of its own range). Read and
// write paths route independently, as AXI keeps them.
//
// Routing per path: while the address is on the wire (xVALID high) the select
// comes from the address; after the handshake it is held in a register until
// the response completes. That covers both orders the CPU can produce: W before
// AW (route W by the live AW address), and a response after the address dropped
// (route by the latched select). Sound for <=1 outstanding per direction.
//
// The address compares are qualified with VALID: the master's address is
// undefined between transactions (payload registers carry no reset), so an
// unqualified compare would leak X into the READY muxes (found by the
// random-backpressure runs).

`timescale 1ns/1ps

module axi_lite_dec2 #(
    parameter S1_BASE = 32'h3000_0000,
    parameter S1_MASK = 32'hF000_0000
)(
    // master side
    input      [31:0] m_awaddr_i,
    input      [2:0]  m_awprot_i,
    input             m_awvalid_i,
    output            m_awready_o,
    input      [31:0] m_wdata_i,
    input      [3:0]  m_wstrb_i,
    input             m_wvalid_i,
    output            m_wready_o,
    output     [1:0]  m_bresp_o,
    output            m_bvalid_o,
    input             m_bready_i,
    input      [31:0] m_araddr_i,
    input      [2:0]  m_arprot_i,
    input             m_arvalid_i,
    output            m_arready_o,
    output     [31:0] m_rdata_o,
    output     [1:0]  m_rresp_o,
    output            m_rvalid_o,
    input             m_rready_i,

    // slave 0 (default)
    output     [31:0] s0_awaddr_o,
    output     [2:0]  s0_awprot_o,
    output            s0_awvalid_o,
    input             s0_awready_i,
    output     [31:0] s0_wdata_o,
    output     [3:0]  s0_wstrb_o,
    output            s0_wvalid_o,
    input             s0_wready_i,
    input      [1:0]  s0_bresp_i,
    input             s0_bvalid_i,
    output            s0_bready_o,
    output     [31:0] s0_araddr_o,
    output     [2:0]  s0_arprot_o,
    output            s0_arvalid_o,
    input             s0_arready_i,
    input      [31:0] s0_rdata_i,
    input      [1:0]  s0_rresp_i,
    input             s0_rvalid_i,
    output            s0_rready_o,

    // slave 1 (windowed)
    output     [31:0] s1_awaddr_o,
    output     [2:0]  s1_awprot_o,
    output            s1_awvalid_o,
    input             s1_awready_i,
    output     [31:0] s1_wdata_o,
    output     [3:0]  s1_wstrb_o,
    output            s1_wvalid_o,
    input             s1_wready_i,
    input      [1:0]  s1_bresp_i,
    input             s1_bvalid_i,
    output            s1_bready_o,
    output     [31:0] s1_araddr_o,
    output     [2:0]  s1_arprot_o,
    output            s1_arvalid_o,
    input             s1_arready_i,
    input      [31:0] s1_rdata_i,
    input      [1:0]  s1_rresp_i,
    input             s1_rvalid_i,
    output            s1_rready_o,

    input             clk_i,
    input             rst_n_i
);

// VALID-qualified on purpose, see the X note in the header
wire aw_match = m_awvalid_i && ((m_awaddr_i & S1_MASK) == (S1_BASE & S1_MASK));
wire ar_match = m_arvalid_i && ((m_araddr_i & S1_MASK) == (S1_BASE & S1_MASK));

reg wr_sel_q, rd_sel_q;

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        wr_sel_q <= 1'b0;
    else if (m_awvalid_i && m_awready_o)
        wr_sel_q <= aw_match;
end

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        rd_sel_q <= 1'b0;
    else if (m_arvalid_i && m_arready_o)
        rd_sel_q <= ar_match;
end

// live address while valid, latched select after the address handshake
wire wr_sel = m_awvalid_i ? aw_match : wr_sel_q;
wire rd_sel = m_arvalid_i ? ar_match : rd_sel_q;

// AW: routed by the live address
assign s0_awaddr_o  = m_awaddr_i;
assign s1_awaddr_o  = m_awaddr_i;
assign s0_awprot_o  = m_awprot_i;
assign s1_awprot_o  = m_awprot_i;
assign s0_awvalid_o = m_awvalid_i & ~aw_match;
assign s1_awvalid_o = m_awvalid_i &  aw_match;
assign m_awready_o  = aw_match ? s1_awready_i : s0_awready_i;

// W: no address, follows the write select
assign s0_wdata_o  = m_wdata_i;
assign s1_wdata_o  = m_wdata_i;
assign s0_wstrb_o  = m_wstrb_i;
assign s1_wstrb_o  = m_wstrb_i;
assign s0_wvalid_o = m_wvalid_i & ~wr_sel;
assign s1_wvalid_o = m_wvalid_i &  wr_sel;
assign m_wready_o  = wr_sel ? s1_wready_i : s0_wready_i;

// B: response of the selected write target
assign m_bresp_o   = wr_sel ? s1_bresp_i  : s0_bresp_i;
assign m_bvalid_o  = wr_sel ? s1_bvalid_i : s0_bvalid_i;
assign s0_bready_o = m_bready_i & ~wr_sel;
assign s1_bready_o = m_bready_i &  wr_sel;

// AR: routed by the live address
assign s0_araddr_o  = m_araddr_i;
assign s1_araddr_o  = m_araddr_i;
assign s0_arprot_o  = m_arprot_i;
assign s1_arprot_o  = m_arprot_i;
assign s0_arvalid_o = m_arvalid_i & ~ar_match;
assign s1_arvalid_o = m_arvalid_i &  ar_match;
assign m_arready_o  = ar_match ? s1_arready_i : s0_arready_i;

// R: response of the selected read target
assign m_rdata_o   = rd_sel ? s1_rdata_i  : s0_rdata_i;
assign m_rresp_o   = rd_sel ? s1_rresp_i  : s0_rresp_i;
assign m_rvalid_o  = rd_sel ? s1_rvalid_i : s0_rvalid_i;
assign s0_rready_o = m_rready_i & ~rd_sel;
assign s1_rready_o = m_rready_i &  rd_sel;

endmodule
