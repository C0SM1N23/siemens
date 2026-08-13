// Reusable AXI4-Lite slave register interface: the handshake shared by pic.v and
// mtimer.v (and open to any register-mapped peripheral, e.g. the DP-SRAM ports
// or the DMA config port). It owns AW/W collection, the B response and the AR/R
// response; the peripheral only describes its registers.
//
// Contract: <=1 transaction per direction, matching the CPU's 1-outstanding
// master. AW and W are collected independently and may arrive in either order.
//
// Write: on wr_en (one cycle) wr_addr/wr_data/wr_strb are valid, and the
//   peripheral updates its registers gated by (wr_en && wr_addr == OFFSET).
//   wr_ok is a combinational function of wr_addr; a non-writable offset SLVERRs.
// Read: rd_addr is the requested word offset (valid while ARVALID). The
//   peripheral drives rd_data and rd_ok combinationally from it, and the slave
//   registers them into RDATA/RRESP on the AR handshake.

`timescale 1ns/1ps

module axi_lite_slave (
    input             clk,
    input             rst_n,

    // AXI4-Lite slave port
    input      [31:0] s_axi_awaddr,
    input             s_axi_awvalid,
    output            s_axi_awready,
    input      [31:0] s_axi_wdata,
    input      [3:0]  s_axi_wstrb,
    input             s_axi_wvalid,
    output            s_axi_wready,
    output     [1:0]  s_axi_bresp,
    output reg        s_axi_bvalid,
    input             s_axi_bready,
    input      [31:0] s_axi_araddr,
    input             s_axi_arvalid,
    output            s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output     [1:0]  s_axi_rresp,
    output reg        s_axi_rvalid,
    input             s_axi_rready,

    // write hook to the peripheral
    output            wr_en,          // one-cycle pulse: a write committed
    output     [5:0]  wr_addr,        // word offset (addr[7:2])
    output     [31:0] wr_data,
    output     [3:0]  wr_strb,
    input             wr_ok,          // combinational: this offset is writable

    // read hook to the peripheral
    output     [5:0]  rd_addr,        // word offset requested (valid while ARVALID)
    input      [31:0] rd_data,        // combinational read mux from the peripheral
    input             rd_ok           // combinational: this offset is readable
);

localparam RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

// --- write: collect AW and W independently, respond once both are in ---
reg        aw_got_q, w_got_q;
reg [5:0]  awoff_q;
reg [31:0] wdata_q;
reg [3:0]  wstrb_q;

wire aw_hs     = s_axi_awvalid && s_axi_awready;
wire w_hs      = s_axi_wvalid  && s_axi_wready;
wire wr_commit = aw_got_q && w_got_q && !s_axi_bvalid;

assign s_axi_awready = !aw_got_q && !s_axi_bvalid;
assign s_axi_wready  = !w_got_q  && !s_axi_bvalid;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)         aw_got_q <= 1'b0;
    else if (aw_hs)     aw_got_q <= 1'b1;
    else if (wr_commit) aw_got_q <= 1'b0;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)         w_got_q <= 1'b0;
    else if (w_hs)      w_got_q <= 1'b1;
    else if (wr_commit) w_got_q <= 1'b0;
end

// command payload: consumed only under the got bits above, no reset
always @(posedge clk)
    if (aw_hs) awoff_q <= s_axi_awaddr[7:2];

always @(posedge clk)
    if (w_hs) begin wdata_q <= s_axi_wdata; wstrb_q <= s_axi_wstrb; end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)           s_axi_bvalid <= 1'b0;
    else if (wr_commit)   s_axi_bvalid <= 1'b1;
    else if (s_axi_bready) s_axi_bvalid <= 1'b0;
end

reg bresp_err_q;
always @(posedge clk)
    if (wr_commit) bresp_err_q <= !wr_ok;
assign s_axi_bresp = bresp_err_q ? RESP_SLVERR : RESP_OKAY;

assign wr_en   = wr_commit;
assign wr_addr = awoff_q;
assign wr_data = wdata_q;
assign wr_strb = wstrb_q;

// --- read: accept AR when no response pending, register data next cycle ---
wire ar_hs = s_axi_arvalid && s_axi_arready;
assign s_axi_arready = !s_axi_rvalid;
assign rd_addr = s_axi_araddr[7:2];

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)           s_axi_rvalid <= 1'b0;
    else if (ar_hs)       s_axi_rvalid <= 1'b1;
    else if (s_axi_rready) s_axi_rvalid <= 1'b0;
end

reg rresp_err_q;
always @(posedge clk)
    if (ar_hs) rresp_err_q <= !rd_ok;
assign s_axi_rresp = rresp_err_q ? RESP_SLVERR : RESP_OKAY;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)    s_axi_rdata <= 32'd0;
    else if (ar_hs) s_axi_rdata <= rd_data;
end

endmodule
