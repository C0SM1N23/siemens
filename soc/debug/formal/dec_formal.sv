// Formal harness for soc_axi_lite_dec: one master, two windows and the DECERR
// responder, proven for every input sequence the AXI4-Lite rules allow.
//
// The master and both slaves are unconstrained apart from the protocol: VALID
// holds with a stable payload until READY, a slave answers only a request it has
// accepted, a response holds until taken. Slaves may accept more than one request;
// the decoder must never give them the chance. Ghost state records where each
// accepted request was routed, independently of the decoder's own registers.
//
// Safety (proven by induction): protocol on both sides, one transaction per
// channel, every request reaches exactly the slave its address selects, every
// response comes from that slave or from the DECERR responder, nothing reaches a
// slave unasked. Bounded liveness (the "live" task): when slaves and master answer
// within two cycles, every request is accepted and answered within a fixed bound.
`default_nettype none
module dec_formal (
    input wire clk,
    input wire rst_n,

    input wire [31:0] m_awaddr,
    input wire        m_awvalid,
    input wire [31:0] m_wdata,
    input wire [ 3:0] m_wstrb,
    input wire        m_wvalid,
    input wire        m_bready,
    input wire [31:0] m_araddr,
    input wire        m_arvalid,
    input wire        m_rready,

    input wire [ 1:0] s_awready,
    input wire [ 1:0] s_wready,
    input wire [ 3:0] s_bresp,
    input wire [ 1:0] s_bvalid,
    input wire [ 1:0] s_arready,
    input wire [63:0] s_rdata,
    input wire [ 3:0] s_rresp,
    input wire [ 1:0] s_rvalid
);
    localparam [1:0] DECERR = 2'b11;

    wire        m_awready, m_wready, m_bvalid, m_arready, m_rvalid;
    wire [ 1:0] m_bresp, m_rresp;
    wire [31:0] m_rdata;
    wire [63:0] s_awaddr, s_wdata, s_araddr;
    wire [ 5:0] s_awprot, s_arprot;
    wire [ 7:0] s_wstrb;
    wire [ 1:0] s_awvalid, s_wvalid, s_bready, s_arvalid, s_rready;

    soc_axi_lite_dec #(
        .N   (2),
        .BASE({32'h1000_0000, 32'h0000_2000}),
        .MASK({32'hFFFF_FC00, 32'hFFFF_E000})
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .m_awaddr_i(m_awaddr), .m_awprot_i(3'b000), .m_awvalid_i(m_awvalid), .m_awready_o(m_awready),
        .m_wdata_i(m_wdata), .m_wstrb_i(m_wstrb), .m_wvalid_i(m_wvalid), .m_wready_o(m_wready),
        .m_bresp_o(m_bresp), .m_bvalid_o(m_bvalid), .m_bready_i(m_bready),
        .m_araddr_i(m_araddr), .m_arprot_i(3'b000), .m_arvalid_i(m_arvalid), .m_arready_o(m_arready),
        .m_rdata_o(m_rdata), .m_rresp_o(m_rresp), .m_rvalid_o(m_rvalid), .m_rready_i(m_rready),
        .s_awaddr_o(s_awaddr), .s_awprot_o(s_awprot), .s_awvalid_o(s_awvalid), .s_awready_i(s_awready),
        .s_wdata_o(s_wdata), .s_wstrb_o(s_wstrb), .s_wvalid_o(s_wvalid), .s_wready_i(s_wready),
        .s_bresp_i(s_bresp), .s_bvalid_i(s_bvalid), .s_bready_o(s_bready),
        .s_araddr_o(s_araddr), .s_arprot_o(s_arprot), .s_arvalid_o(s_arvalid), .s_arready_i(s_arready),
        .s_rdata_i(s_rdata), .s_rresp_i(s_rresp), .s_rvalid_i(s_rvalid), .s_rready_o(s_rready)
    );

    // The address map, written out independently of the decoder's parameters.
    function [1:0] route;  // one-hot slave select, zero = unmapped
        input [31:0] a;
        route = {(a & 32'hFFFF_FC00) == 32'h1000_0000, (a & 32'hFFFF_E000) == 32'h0000_2000};
    endfunction

    reg f_past_valid = 1'b0, f_past_rst_n = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    always @(posedge clk) f_past_rst_n <= rst_n;
    initial assume (!rst_n);
    wire f_run = f_past_valid && f_past_rst_n && rst_n;  // out of reset for two cycles

    wire m_aw_hs = m_awvalid && m_awready;
    wire m_w_hs  = m_wvalid && m_wready;
    wire m_b_hs  = m_bvalid && m_bready;
    wire m_ar_hs = m_arvalid && m_arready;
    wire m_r_hs  = m_rvalid && m_rready;
    wire [1:0] s_aw_hs = s_awvalid & s_awready;
    wire [1:0] s_w_hs  = s_wvalid & s_wready;
    wire [1:0] s_b_hs  = s_bvalid & s_bready;
    wire [1:0] s_ar_hs = s_arvalid & s_arready;
    wire [1:0] s_r_hs  = s_rvalid & s_rready;

    // master: AXI4-Lite rules for the requests it drives
    always @(*) if (!rst_n) assume (!m_awvalid && !m_wvalid && !m_arvalid);
    always @(posedge clk) if (f_run) begin
        if ($past(m_awvalid && !m_awready)) assume (m_awvalid && m_awaddr == $past(m_awaddr));
        if ($past(m_wvalid && !m_wready)) assume (m_wvalid && m_wdata == $past(m_wdata) && m_wstrb == $past(m_wstrb));
        if ($past(m_arvalid && !m_arready)) assume (m_arvalid && m_araddr == $past(m_araddr));
    end

    // ghost: the master's view of its own transactions and where they went
    reg       g_aw_open, g_w_open, g_ar_open;  // accepted, response not taken
    reg [1:0] g_wr_route, g_rd_route;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_aw_open <= 1'b0; else if (m_b_hs) g_aw_open <= 1'b0; else if (m_aw_hs) g_aw_open <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_w_open <= 1'b0; else if (m_b_hs) g_w_open <= 1'b0; else if (m_w_hs) g_w_open <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_ar_open <= 1'b0; else if (m_r_hs) g_ar_open <= 1'b0; else if (m_ar_hs) g_ar_open <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_wr_route <= 2'b00; else if (m_aw_hs) g_wr_route <= route(m_awaddr);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_rd_route <= 2'b00; else if (m_ar_hs) g_rd_route <= route(m_araddr);

    // The write a W beat belongs to: the accepted one, else the one on offer now.
    wire [1:0] g_w_route = g_aw_open ? g_wr_route : (m_awvalid ? route(m_awaddr) : 2'b00);

    // slaves: each one answers only what it accepted, and holds its response
    reg [1:0] s_aw_open, s_w_open, s_ar_open;
    genvar i;
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_slave
            always @(posedge clk or negedge rst_n)
                if (!rst_n) s_aw_open[i] <= 1'b0;
                else if (s_b_hs[i]) s_aw_open[i] <= s_aw_hs[i];
                else if (s_aw_hs[i]) s_aw_open[i] <= 1'b1;
            always @(posedge clk or negedge rst_n)
                if (!rst_n) s_w_open[i] <= 1'b0;
                else if (s_b_hs[i]) s_w_open[i] <= s_w_hs[i];
                else if (s_w_hs[i]) s_w_open[i] <= 1'b1;
            always @(posedge clk or negedge rst_n)
                if (!rst_n) s_ar_open[i] <= 1'b0;
                else if (s_r_hs[i]) s_ar_open[i] <= s_ar_hs[i];
                else if (s_ar_hs[i]) s_ar_open[i] <= 1'b1;

            always @(*) begin
                if (!rst_n) assume (!s_bvalid[i] && !s_rvalid[i]);
                if (s_bvalid[i]) assume (s_aw_open[i] && s_w_open[i]);
                if (s_rvalid[i]) assume (s_ar_open[i]);
                assume (s_bresp[2*i+:2] != 2'b01 && s_rresp[2*i+:2] != 2'b01);
            end
            always @(posedge clk) if (f_run) begin
                if ($past(s_bvalid[i] && !s_bready[i])) assume (s_bvalid[i] && s_bresp[2*i+:2] == $past(s_bresp[2*i+:2]));
                if ($past(s_rvalid[i] && !s_rready[i]))
                    assume (s_rvalid[i] && s_rdata[32*i+:32] == $past(s_rdata[32*i+:32]) && s_rresp[2*i+:2] == $past(s_rresp[2*i+:2]));
            end

            // decoder towards each slave: AXI4-Lite master rules, and one at a time
            always @(*) begin
                if (!rst_n) assert (!s_awvalid[i] && !s_wvalid[i] && !s_arvalid[i]);
                if (s_awvalid[i]) assert (!s_aw_open[i] || s_b_hs[i]);
                if (s_wvalid[i]) assert (!s_w_open[i] || s_b_hs[i]);
                if (s_arvalid[i]) assert (!s_ar_open[i] || s_r_hs[i]);
            end
            always @(posedge clk) if (f_run) begin
                if ($past(s_awvalid[i] && !s_awready[i])) assert (s_awvalid[i] && s_awaddr[32*i+:32] == $past(s_awaddr[32*i+:32]));
                if ($past(s_wvalid[i] && !s_wready[i]))
                    assert (s_wvalid[i] && s_wdata[32*i+:32] == $past(s_wdata[32*i+:32]) && s_wstrb[4*i+:4] == $past(s_wstrb[4*i+:4]));
                if ($past(s_arvalid[i] && !s_arready[i])) assert (s_arvalid[i] && s_araddr[32*i+:32] == $past(s_araddr[32*i+:32]));
            end

            // routing: a request reaches slave i only if its address selects i
            always @(*) begin
                if (s_awvalid[i]) assert (m_awvalid && route(m_awaddr) == (2'b01 << i) && !g_aw_open);
                if (s_arvalid[i]) assert (m_arvalid && route(m_araddr) == (2'b01 << i) && !g_ar_open);
                if (s_wvalid[i]) assert (m_wvalid && g_w_route == (2'b01 << i) && !g_w_open);
                if (s_bready[i]) assert (m_bready && g_aw_open && g_wr_route == (2'b01 << i));
                if (s_rready[i]) assert (m_rready && g_ar_open && g_rd_route == (2'b01 << i));
                assert (s_awaddr[32*i+:32] == m_awaddr && s_araddr[32*i+:32] == m_araddr);
                assert (s_wdata[32*i+:32] == m_wdata && s_wstrb[4*i+:4] == m_wstrb);
            end
        end
    endgenerate

    // one transaction per channel across all slaves
    always @(*) begin
        assert ($countones(s_aw_open | s_w_open) <= 1);
        assert ($countones(s_ar_open) <= 1);
    end

    // master side: acceptance means the selected slave accepted in the same cycle
    always @(*) begin
        if (m_aw_hs && route(m_awaddr) != 2'b00) assert (s_aw_hs == route(m_awaddr));
        if (m_aw_hs && route(m_awaddr) == 2'b00) assert (s_aw_hs == 2'b00);
        if (m_ar_hs && route(m_araddr) != 2'b00) assert (s_ar_hs == route(m_araddr));
        if (m_ar_hs && route(m_araddr) == 2'b00) assert (s_ar_hs == 2'b00);
        if (m_w_hs && g_w_route != 2'b00) assert (s_w_hs == g_w_route);
        if (m_w_hs && g_w_route == 2'b00) assert (s_w_hs == 2'b00 && (g_aw_open || m_awvalid));
        if (m_aw_hs) assert (!g_aw_open);
        if (m_w_hs) assert (!g_w_open);
        if (m_ar_hs) assert (!g_ar_open);
    end

    // master side: a response answers an accepted request, from the right place
    always @(*) begin
        if (m_bvalid) begin
            assert (g_aw_open && g_w_open);
            if (g_wr_route == 2'b00) assert (m_bresp == DECERR);
            else assert (|(s_bvalid & g_wr_route) && m_bresp == (g_wr_route[1] ? s_bresp[3:2] : s_bresp[1:0]));
        end
        if (m_rvalid) begin
            assert (g_ar_open);
            if (g_rd_route == 2'b00) assert (m_rresp == DECERR && m_rdata == 32'b0);
            else assert (|(s_rvalid & g_rd_route) && m_rresp == (g_rd_route[1] ? s_rresp[3:2] : s_rresp[1:0])
                         && m_rdata == (g_rd_route[1] ? s_rdata[63:32] : s_rdata[31:0]));
        end
        if (m_b_hs && g_wr_route != 2'b00) assert (s_b_hs == g_wr_route);
        if (m_r_hs && g_rd_route != 2'b00) assert (s_r_hs == g_rd_route);
        if (!rst_n) assert (!m_bvalid && !m_rvalid);
    end
    always @(posedge clk) if (f_run) begin
        if ($past(m_bvalid && !m_bready)) assert (m_bvalid && m_bresp == $past(m_bresp));
        if ($past(m_rvalid && !m_rready)) assert (m_rvalid && m_rresp == $past(m_rresp) && m_rdata == $past(m_rdata));
    end

`ifdef LIVE
    // Fair environment: every READY within two cycles of its VALID, every slave
    // response within two cycles of the request, and a W never far from its AW.
    reg [2:0] e_aw, e_w, e_ar, e_b, e_r, e_bs0, e_bs1, e_rs0, e_rs1, e_worphan, e_wlate;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {e_aw, e_w, e_ar, e_b, e_r, e_bs0, e_bs1, e_rs0, e_rs1, e_worphan, e_wlate} <= 33'b0;
        else begin
            e_aw <= |(s_awvalid & ~s_awready) ? e_aw + 3'd1 : 3'd0;
            e_w  <= |(s_wvalid & ~s_wready) ? e_w + 3'd1 : 3'd0;
            e_ar <= |(s_arvalid & ~s_arready) ? e_ar + 3'd1 : 3'd0;
            e_b  <= (m_bvalid && !m_bready) ? e_b + 3'd1 : 3'd0;
            e_r  <= (m_rvalid && !m_rready) ? e_r + 3'd1 : 3'd0;
            e_bs0 <= (s_aw_open[0] && s_w_open[0] && !s_bvalid[0]) ? e_bs0 + 3'd1 : 3'd0;
            e_bs1 <= (s_aw_open[1] && s_w_open[1] && !s_bvalid[1]) ? e_bs1 + 3'd1 : 3'd0;
            e_rs0 <= (s_ar_open[0] && !s_rvalid[0]) ? e_rs0 + 3'd1 : 3'd0;
            e_rs1 <= (s_ar_open[1] && !s_rvalid[1]) ? e_rs1 + 3'd1 : 3'd0;
            e_worphan <= (m_wvalid && !g_aw_open && !m_awvalid) ? e_worphan + 3'd1 : 3'd0;
            e_wlate <= (g_aw_open && !g_w_open && !m_wvalid) ? e_wlate + 3'd1 : 3'd0;
        end
    end
    always @(*) begin
        assume (e_aw < 3 && e_w < 3 && e_ar < 3 && e_b < 3 && e_r < 3);
        assume (e_bs0 < 3 && e_bs1 < 3 && e_rs0 < 3 && e_rs1 < 3 && e_worphan < 3 && e_wlate < 3);
    end

    // The decoder then accepts every request and answers it within a bound.
    reg [4:0] w_aw, w_w, w_ar, w_bresp, w_rresp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {w_aw, w_w, w_ar, w_bresp, w_rresp} <= 25'b0;
        else begin
            w_aw <= (m_awvalid && !m_awready) ? w_aw + 5'd1 : 5'd0;
            w_w  <= (m_wvalid && !m_wready) ? w_w + 5'd1 : 5'd0;
            w_ar <= (m_arvalid && !m_arready) ? w_ar + 5'd1 : 5'd0;
            w_bresp <= (g_aw_open && g_w_open && !m_bvalid) ? w_bresp + 5'd1 : 5'd0;
            w_rresp <= (g_ar_open && !m_rvalid) ? w_rresp + 5'd1 : 5'd0;
        end
    end
    always @(*) begin
        // A request may wait for the previous transaction on its channel: late W,
        // slave READY, slave response, master READY, then its own slave READY.
        assert (w_aw < 24 && w_w < 24 && w_ar < 24);
        assert (w_bresp < 6 && w_rresp < 6);
    end
`endif

    // reachability of the interesting states, counted from the end of reset
    reg c_wrote_slave0, c_read_slave1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) c_wrote_slave0 <= 1'b0; else if (m_b_hs && g_wr_route == 2'b01) c_wrote_slave0 <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) c_read_slave1 <= 1'b0; else if (m_r_hs && g_rd_route == 2'b10) c_read_slave1 <= 1'b1;
    always @(posedge clk) if (f_run) begin
        cover (m_b_hs && m_bresp == DECERR);
        cover (m_r_hs && m_rresp == DECERR);
        cover (m_w_hs && g_aw_open);                               // W after its AW
        cover (m_aw_hs && m_w_hs);                                 // AW and W together
        cover (m_arvalid && !m_arready && m_rvalid && !m_rready);  // next read waits
        cover (c_wrote_slave0 && m_b_hs && g_wr_route == 2'b10);   // two slaves in turn
        cover (c_read_slave1 && m_r_hs && g_rd_route == 2'b00);    // mapped read, then DECERR
    end
endmodule
`default_nettype wire
