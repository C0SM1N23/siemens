// Reusable AXI4-Lite slave register interface: the handshake shared by pic.v and
// mtimer.v (and open to any register-mapped peripheral, e.g. the DP-SRAM ports
// or the DMA config port). It owns AW/W collection, the B response and the AR/R
// response; the peripheral only describes its registers.
//
// Contract: <=1 transaction per direction, matching the CPU's 1-outstanding
// master. AW and W are collected independently and may arrive in either order.
//
// Write: on wr_en_o (one cycle) wr_addr_o/wr_data_o/wr_strb_o are valid, and the
//   peripheral updates its registers gated by (wr_en_o && wr_addr_o == OFFSET).
//   wr_ok_i is a combinational function of wr_addr_o; a non-writable offset SLVERRs.
// Read: rd_addr_o is the requested word offset (valid while ARVALID). The
//   peripheral drives rd_data_i and rd_ok_i combinationally from it, and the slave
//   registers them into RDATA/RRESP on the AR handshake.
//
// Reset policy: every flop in this module is reset by the asynchronous, active-
// low rst_n_i. Handshake and response flops are reset because the protocol
// requires it (IHI0022E A3.1.2: VALID low while reset is asserted); payload and
// response-code flops are reset because an unreset flop drives X onto BRESP /
// RRESP / the register-write path until its first capture, and X on a bus
// output cannot be distinguished from a real protocol violation by a monitor.

`timescale 1ns/1ps

module axi_lite_slave (
    input             clk_i,
    input             rst_n_i,

    // AXI4-Lite slave port
    input      [31:0] s_axi_awaddr_i,
    input             s_axi_awvalid_i,
    output            s_axi_awready_o,
    input      [31:0] s_axi_wdata_i,
    input      [3:0]  s_axi_wstrb_i,
    input             s_axi_wvalid_i,
    output            s_axi_wready_o,
    output     [1:0]  s_axi_bresp_o,
    output reg        s_axi_bvalid_o,
    input             s_axi_bready_i,
    input      [31:0] s_axi_araddr_i,
    input             s_axi_arvalid_i,
    output            s_axi_arready_o,
    output reg [31:0] s_axi_rdata_o,
    output     [1:0]  s_axi_rresp_o,
    output reg        s_axi_rvalid_o,
    input             s_axi_rready_i,

    // write hook to the peripheral
    output            wr_en_o,          // one-cycle pulse: a write committed
    output     [5:0]  wr_addr_o,        // word offset (addr[7:2])
    output     [31:0] wr_data_o,
    output     [3:0]  wr_strb_o,
    input             wr_ok_i,          // combinational: this offset is writable

    // read hook to the peripheral
    output     [5:0]  rd_addr_o,        // word offset requested (valid while ARVALID)
    input      [31:0] rd_data_i,        // combinational read mux from the peripheral
    input             rd_ok_i           // combinational: this offset is readable
);

localparam RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

// --- write: collect AW and W independently, respond once both are in ---
reg        aw_got_q, w_got_q;
reg [5:0]  awoff_q;
reg [31:0] wdata_q;
reg [3:0]  wstrb_q;

wire aw_hs     = s_axi_awvalid_i && s_axi_awready_o;
wire w_hs      = s_axi_wvalid_i  && s_axi_wready_o;
wire wr_commit = aw_got_q && w_got_q && !s_axi_bvalid_o;

assign s_axi_awready_o = !aw_got_q && !s_axi_bvalid_o;
assign s_axi_wready_o  = !w_got_q  && !s_axi_bvalid_o;

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)         aw_got_q <= 1'b0;
    else if (aw_hs)     aw_got_q <= 1'b1;
    else if (wr_commit) aw_got_q <= 1'b0;
end

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)         w_got_q <= 1'b0;
    else if (w_hs)      w_got_q <= 1'b1;
    else if (wr_commit) w_got_q <= 1'b0;
end

// Command payload. Functionally it is only consumed under the got bits above,
// so a reset value is not needed to make the handshake correct; it is reset all
// the same so that no flop in the block leaves reset holding X. See the reset
// policy note in the header.
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)     awoff_q <= 6'd0;
    else if (aw_hs) awoff_q <= s_axi_awaddr_i[7:2];
end

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        wdata_q <= 32'd0;
        wstrb_q <= 4'd0;
    end else if (w_hs) begin
        wdata_q <= s_axi_wdata_i;
        wstrb_q <= s_axi_wstrb_i;
    end
end

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)           s_axi_bvalid_o <= 1'b0;
    else if (wr_commit)   s_axi_bvalid_o <= 1'b1;
    else if (s_axi_bready_i) s_axi_bvalid_o <= 1'b0;
end

// BRESP error flag. Resetting it matters on the bus, not just in the reset
// tree: BRESP is a combinational function of this flop and is driven whether or
// not BVALID is high, so without a reset the slave presents X on BRESP from
// time zero until the first write commits.
reg bresp_err_q;
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)         bresp_err_q <= 1'b0;
    else if (wr_commit) bresp_err_q <= !wr_ok_i;
end
assign s_axi_bresp_o = bresp_err_q ? RESP_SLVERR : RESP_OKAY;

assign wr_en_o   = wr_commit;
assign wr_addr_o = awoff_q;
assign wr_data_o = wdata_q;
assign wr_strb_o = wstrb_q;

// --- read: accept AR when no response pending, register data next cycle ---
wire ar_hs = s_axi_arvalid_i && s_axi_arready_o;
assign s_axi_arready_o = !s_axi_rvalid_o;
assign rd_addr_o = s_axi_araddr_i[7:2];

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)           s_axi_rvalid_o <= 1'b0;
    else if (ar_hs)       s_axi_rvalid_o <= 1'b1;
    else if (s_axi_rready_i) s_axi_rvalid_o <= 1'b0;
end

// RRESP error flag: same argument as BRESP above.
reg rresp_err_q;
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)     rresp_err_q <= 1'b0;
    else if (ar_hs) rresp_err_q <= !rd_ok_i;
end
assign s_axi_rresp_o = rresp_err_q ? RESP_SLVERR : RESP_OKAY;

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)    s_axi_rdata_o <= 32'd0;
    else if (ar_hs) s_axi_rdata_o <= rd_data_i;
end

endmodule
