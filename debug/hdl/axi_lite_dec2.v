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

module axi_lite_dec2 #(
    parameter S1_BASE = 32'h3000_0000,
    parameter S1_MASK = 32'hF000_0000
)(
    // master side
    input      [31:0] m_awaddr,
    input      [2:0]  m_awprot,
    input             m_awvalid,
    output            m_awready,
    input      [31:0] m_wdata,
    input      [3:0]  m_wstrb,
    input             m_wvalid,
    output            m_wready,
    output     [1:0]  m_bresp,
    output            m_bvalid,
    input             m_bready,
    input      [31:0] m_araddr,
    input      [2:0]  m_arprot,
    input             m_arvalid,
    output            m_arready,
    output     [31:0] m_rdata,
    output     [1:0]  m_rresp,
    output            m_rvalid,
    input             m_rready,

    // slave 0 (default)
    output     [31:0] s0_awaddr,
    output     [2:0]  s0_awprot,
    output            s0_awvalid,
    input             s0_awready,
    output     [31:0] s0_wdata,
    output     [3:0]  s0_wstrb,
    output            s0_wvalid,
    input             s0_wready,
    input      [1:0]  s0_bresp,
    input             s0_bvalid,
    output            s0_bready,
    output     [31:0] s0_araddr,
    output     [2:0]  s0_arprot,
    output            s0_arvalid,
    input             s0_arready,
    input      [31:0] s0_rdata,
    input      [1:0]  s0_rresp,
    input             s0_rvalid,
    output            s0_rready,

    // slave 1 (windowed)
    output     [31:0] s1_awaddr,
    output     [2:0]  s1_awprot,
    output            s1_awvalid,
    input             s1_awready,
    output     [31:0] s1_wdata,
    output     [3:0]  s1_wstrb,
    output            s1_wvalid,
    input             s1_wready,
    input      [1:0]  s1_bresp,
    input             s1_bvalid,
    output            s1_bready,
    output     [31:0] s1_araddr,
    output     [2:0]  s1_arprot,
    output            s1_arvalid,
    input             s1_arready,
    input      [31:0] s1_rdata,
    input      [1:0]  s1_rresp,
    input             s1_rvalid,
    output            s1_rready,

    input             clk,
    input             rst_n
);

// VALID-qualified on purpose, see the X note in the header
wire aw_match = m_awvalid && ((m_awaddr & S1_MASK) == (S1_BASE & S1_MASK));
wire ar_match = m_arvalid && ((m_araddr & S1_MASK) == (S1_BASE & S1_MASK));

reg wr_sel_q, rd_sel_q;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        wr_sel_q <= 1'b0;
    else if (m_awvalid && m_awready)
        wr_sel_q <= aw_match;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        rd_sel_q <= 1'b0;
    else if (m_arvalid && m_arready)
        rd_sel_q <= ar_match;
end

// live address while valid, latched select after the address handshake
wire wr_sel = m_awvalid ? aw_match : wr_sel_q;
wire rd_sel = m_arvalid ? ar_match : rd_sel_q;

// AW: routed by the live address
assign s0_awaddr  = m_awaddr;
assign s1_awaddr  = m_awaddr;
assign s0_awprot  = m_awprot;
assign s1_awprot  = m_awprot;
assign s0_awvalid = m_awvalid & ~aw_match;
assign s1_awvalid = m_awvalid &  aw_match;
assign m_awready  = aw_match ? s1_awready : s0_awready;

// W: no address, follows the write select
assign s0_wdata  = m_wdata;
assign s1_wdata  = m_wdata;
assign s0_wstrb  = m_wstrb;
assign s1_wstrb  = m_wstrb;
assign s0_wvalid = m_wvalid & ~wr_sel;
assign s1_wvalid = m_wvalid &  wr_sel;
assign m_wready  = wr_sel ? s1_wready : s0_wready;

// B: response of the selected write target
assign m_bresp   = wr_sel ? s1_bresp  : s0_bresp;
assign m_bvalid  = wr_sel ? s1_bvalid : s0_bvalid;
assign s0_bready = m_bready & ~wr_sel;
assign s1_bready = m_bready &  wr_sel;

// AR: routed by the live address
assign s0_araddr  = m_araddr;
assign s1_araddr  = m_araddr;
assign s0_arprot  = m_arprot;
assign s1_arprot  = m_arprot;
assign s0_arvalid = m_arvalid & ~ar_match;
assign s1_arvalid = m_arvalid &  ar_match;
assign m_arready  = ar_match ? s1_arready : s0_arready;

// R: response of the selected read target
assign m_rdata   = rd_sel ? s1_rdata  : s0_rdata;
assign m_rresp   = rd_sel ? s1_rresp  : s0_rresp;
assign m_rvalid  = rd_sel ? s1_rvalid : s0_rvalid;
assign s0_rready = m_rready & ~rd_sel;
assign s1_rready = m_rready &  rd_sel;

endmodule
