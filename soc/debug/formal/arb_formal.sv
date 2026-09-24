// Formal harness for soc_axi_lite_arb: two masters, one slave.
//
// Masters and slave are unconstrained apart from the AXI4-Lite rules; the slave
// may accept any number of requests, so nothing but the arbiter keeps it to one.
// Ghost state records which master owns the request the slave is working on.
//
// Safety (proven by induction): one master at a time, one transaction and one
// direction per grant, every beat reaches the slave with its owner's payload,
// every response goes back to its owner unchanged, a parked master sees nothing.
// Bounded liveness (the "live" task): with sequential masters - the CPU load/store
// unit and the DMA are both sequential - and a slave and masters that answer
// within two cycles, every request is granted and completed within a bound.
`default_nettype none
module arb_formal (
    input wire clk,
    input wire rst_n,

    input wire [63:0] m_awaddr,
    input wire [ 1:0] m_awvalid,
    input wire [63:0] m_wdata,
    input wire [ 7:0] m_wstrb,
    input wire [ 1:0] m_wvalid,
    input wire [ 1:0] m_bready,
    input wire [63:0] m_araddr,
    input wire [ 1:0] m_arvalid,
    input wire [ 1:0] m_rready,

    input wire        s_awready,
    input wire        s_wready,
    input wire [ 1:0] s_bresp,
    input wire        s_bvalid,
    input wire        s_arready,
    input wire [31:0] s_rdata,
    input wire [ 1:0] s_rresp,
    input wire        s_rvalid
);
    wire [ 1:0] m_awready, m_wready, m_bvalid, m_arready, m_rvalid;
    wire [ 3:0] m_bresp, m_rresp;
    wire [63:0] m_rdata;
    wire [31:0] s_awaddr, s_wdata, s_araddr;
    wire [ 2:0] s_awprot, s_arprot;
    wire [ 3:0] s_wstrb;
    wire s_awvalid, s_wvalid, s_bready, s_arvalid, s_rready;

    soc_axi_lite_arb #(.M(2)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .m_awaddr_i(m_awaddr), .m_awprot_i(6'b0), .m_awvalid_i(m_awvalid), .m_awready_o(m_awready),
        .m_wdata_i(m_wdata), .m_wstrb_i(m_wstrb), .m_wvalid_i(m_wvalid), .m_wready_o(m_wready),
        .m_bresp_o(m_bresp), .m_bvalid_o(m_bvalid), .m_bready_i(m_bready),
        .m_araddr_i(m_araddr), .m_arprot_i(6'b0), .m_arvalid_i(m_arvalid), .m_arready_o(m_arready),
        .m_rdata_o(m_rdata), .m_rresp_o(m_rresp), .m_rvalid_o(m_rvalid), .m_rready_i(m_rready),
        .s_awaddr_o(s_awaddr), .s_awprot_o(s_awprot), .s_awvalid_o(s_awvalid), .s_awready_i(s_awready),
        .s_wdata_o(s_wdata), .s_wstrb_o(s_wstrb), .s_wvalid_o(s_wvalid), .s_wready_i(s_wready),
        .s_bresp_i(s_bresp), .s_bvalid_i(s_bvalid), .s_bready_o(s_bready),
        .s_araddr_o(s_araddr), .s_arprot_o(s_arprot), .s_arvalid_o(s_arvalid), .s_arready_i(s_arready),
        .s_rdata_i(s_rdata), .s_rresp_i(s_rresp), .s_rvalid_i(s_rvalid), .s_rready_o(s_rready)
    );

    reg f_past_valid = 1'b0, f_past_rst_n = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    always @(posedge clk) f_past_rst_n <= rst_n;
    initial assume (!rst_n);
    wire f_run = f_past_valid && f_past_rst_n && rst_n;

    wire [1:0] m_aw_hs = m_awvalid & m_awready;
    wire [1:0] m_w_hs  = m_wvalid & m_wready;
    wire [1:0] m_b_hs  = m_bvalid & m_bready;
    wire [1:0] m_ar_hs = m_arvalid & m_arready;
    wire [1:0] m_r_hs  = m_rvalid & m_rready;
    wire s_aw_hs = s_awvalid && s_awready;
    wire s_w_hs  = s_wvalid && s_wready;
    wire s_b_hs  = s_bvalid && s_bready;
    wire s_ar_hs = s_arvalid && s_arready;
    wire s_r_hs  = s_rvalid && s_rready;

    // the slave's view: what it accepted and still owes a response for
    reg s_aw_open, s_w_open, s_ar_open;
    reg g_wr_owner, g_rd_owner;  // master whose address the slave accepted
    always @(posedge clk or negedge rst_n)
        if (!rst_n) s_aw_open <= 1'b0; else if (s_b_hs) s_aw_open <= s_aw_hs; else if (s_aw_hs) s_aw_open <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) s_w_open <= 1'b0; else if (s_b_hs) s_w_open <= s_w_hs; else if (s_w_hs) s_w_open <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) s_ar_open <= 1'b0; else if (s_r_hs) s_ar_open <= s_ar_hs; else if (s_ar_hs) s_ar_open <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_wr_owner <= 1'b0; else if (s_aw_hs) g_wr_owner <= m_aw_hs[1];
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_rd_owner <= 1'b0; else if (s_ar_hs) g_rd_owner <= m_ar_hs[1];

    // slave: AXI4-Lite rules for its responses
    always @(*) begin
        if (!rst_n) assume (!s_bvalid && !s_rvalid);
        if (s_bvalid) assume (s_aw_open && s_w_open);
        if (s_rvalid) assume (s_ar_open);
        assume (s_bresp != 2'b01 && s_rresp != 2'b01);
    end
    always @(posedge clk) if (f_run) begin
        if ($past(s_bvalid && !s_bready)) assume (s_bvalid && s_bresp == $past(s_bresp));
        if ($past(s_rvalid && !s_rready)) assume (s_rvalid && s_rdata == $past(s_rdata) && s_rresp == $past(s_rresp));
    end

    // each master: AXI4-Lite rules, and its own record of what it has open
    reg [1:0] m_aw_open, m_w_open, m_ar_open;
    genvar k;
    generate
        for (k = 0; k < 2; k = k + 1) begin : g_master
            always @(*) if (!rst_n) assume (!m_awvalid[k] && !m_wvalid[k] && !m_arvalid[k]);
            always @(posedge clk) if (f_run) begin
                if ($past(m_awvalid[k] && !m_awready[k])) assume (m_awvalid[k] && m_awaddr[32*k+:32] == $past(m_awaddr[32*k+:32]));
                if ($past(m_wvalid[k] && !m_wready[k]))
                    assume (m_wvalid[k] && m_wdata[32*k+:32] == $past(m_wdata[32*k+:32]) && m_wstrb[4*k+:4] == $past(m_wstrb[4*k+:4]));
                if ($past(m_arvalid[k] && !m_arready[k])) assume (m_arvalid[k] && m_araddr[32*k+:32] == $past(m_araddr[32*k+:32]));
            end
            always @(posedge clk or negedge rst_n)
                if (!rst_n) m_aw_open[k] <= 1'b0; else if (m_b_hs[k]) m_aw_open[k] <= 1'b0; else if (m_aw_hs[k]) m_aw_open[k] <= 1'b1;
            always @(posedge clk or negedge rst_n)
                if (!rst_n) m_w_open[k] <= 1'b0; else if (m_b_hs[k]) m_w_open[k] <= 1'b0; else if (m_w_hs[k]) m_w_open[k] <= 1'b1;
            always @(posedge clk or negedge rst_n)
                if (!rst_n) m_ar_open[k] <= 1'b0; else if (m_r_hs[k]) m_ar_open[k] <= 1'b0; else if (m_ar_hs[k]) m_ar_open[k] <= 1'b1;

            // towards each master: AXI4-Lite slave rules
            always @(*) begin
                if (m_bvalid[k]) assert (m_aw_open[k] && m_w_open[k]);
                if (m_rvalid[k]) assert (m_ar_open[k]);
                if (m_aw_hs[k]) assert (!m_aw_open[k]);
                if (m_w_hs[k]) assert (!m_w_open[k]);
                if (m_ar_hs[k]) assert (!m_ar_open[k]);
                if (!rst_n) assert (!m_bvalid[k] && !m_rvalid[k]);
            end
            always @(posedge clk) if (f_run) begin
                if ($past(m_bvalid[k] && !m_bready[k])) assert (m_bvalid[k] && m_bresp[2*k+:2] == $past(m_bresp[2*k+:2]));
                if ($past(m_rvalid[k] && !m_rready[k]))
                    assert (m_rvalid[k] && m_rresp[2*k+:2] == $past(m_rresp[2*k+:2]) && m_rdata[32*k+:32] == $past(m_rdata[32*k+:32]));
            end

            // every beat is the owner's, every response goes back to its owner
            always @(*) begin
                if (m_aw_hs[k]) assert (s_aw_hs && s_awaddr == m_awaddr[32*k+:32]);
                if (m_w_hs[k]) assert (s_w_hs && s_wdata == m_wdata[32*k+:32] && s_wstrb == m_wstrb[4*k+:4]);
                if (m_ar_hs[k]) assert (s_ar_hs && s_araddr == m_araddr[32*k+:32]);
                if (m_bvalid[k]) assert (s_bvalid && g_wr_owner == k && s_aw_open && m_bresp[2*k+:2] == s_bresp);
                if (m_rvalid[k]) assert (s_rvalid && g_rd_owner == k && s_ar_open && m_rresp[2*k+:2] == s_rresp
                                         && m_rdata[32*k+:32] == s_rdata);
            end
        end
    endgenerate

    // one master at a time, one transaction and one direction per grant
    always @(*) begin
        assert ($countones(m_awready | m_wready | m_arready | m_bvalid | m_rvalid) <= 1);
        assert (!(s_ar_open && (s_aw_open || s_w_open)));
        if (s_awvalid) assert (!s_aw_open || s_b_hs);
        if (s_wvalid) assert (!s_w_open || s_b_hs);
        if (s_arvalid) assert (!s_ar_open || s_r_hs);
        if (s_aw_hs) assert ($countones(m_aw_hs) == 1);
        if (s_w_hs) assert ($countones(m_w_hs) == 1);
        if (s_ar_hs) assert ($countones(m_ar_hs) == 1);
        if (s_b_hs) assert (m_b_hs == (2'b01 << g_wr_owner));
        if (s_r_hs) assert (m_r_hs == (2'b01 << g_rd_owner));
        if (s_w_open && s_aw_open) assert (m_aw_open[g_wr_owner] && m_w_open[g_wr_owner]);
        if (s_ar_open) assert (m_ar_open[g_rd_owner]);
        if (!rst_n) assert (!s_awvalid && !s_wvalid && !s_arvalid);
    end
    always @(posedge clk) if (f_run) begin
        if ($past(s_awvalid && !s_awready)) assert (s_awvalid && s_awaddr == $past(s_awaddr));
        if ($past(s_wvalid && !s_wready)) assert (s_wvalid && s_wdata == $past(s_wdata) && s_wstrb == $past(s_wstrb));
        if ($past(s_arvalid && !s_arready)) assert (s_arvalid && s_araddr == $past(s_araddr));
    end

`ifdef LIVE
    // Sequential masters: a new request only when nothing of theirs is open, and
    // the W of a write never far from its AW. Slave and masters answer in time.
    reg [2:0] e_saw, e_sw, e_sar, e_sb, e_sr, e_mb0, e_mb1, e_mr0, e_mr1, e_w0, e_w1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {e_saw, e_sw, e_sar, e_sb, e_sr, e_mb0, e_mb1, e_mr0, e_mr1, e_w0, e_w1} <= 33'b0;
        else begin
            e_saw <= (s_awvalid && !s_awready) ? e_saw + 3'd1 : 3'd0;
            e_sw  <= (s_wvalid && !s_wready) ? e_sw + 3'd1 : 3'd0;
            e_sar <= (s_arvalid && !s_arready) ? e_sar + 3'd1 : 3'd0;
            e_sb  <= (s_aw_open && s_w_open && !s_bvalid) ? e_sb + 3'd1 : 3'd0;
            e_sr  <= (s_ar_open && !s_rvalid) ? e_sr + 3'd1 : 3'd0;
            e_mb0 <= (m_bvalid[0] && !m_bready[0]) ? e_mb0 + 3'd1 : 3'd0;
            e_mb1 <= (m_bvalid[1] && !m_bready[1]) ? e_mb1 + 3'd1 : 3'd0;
            e_mr0 <= (m_rvalid[0] && !m_rready[0]) ? e_mr0 + 3'd1 : 3'd0;
            e_mr1 <= (m_rvalid[1] && !m_rready[1]) ? e_mr1 + 3'd1 : 3'd0;
            e_w0  <= ((m_awvalid[0] || m_aw_open[0]) && !m_w_open[0] && !m_wvalid[0]) ? e_w0 + 3'd1 : 3'd0;
            e_w1  <= ((m_awvalid[1] || m_aw_open[1]) && !m_w_open[1] && !m_wvalid[1]) ? e_w1 + 3'd1 : 3'd0;
        end
    end
    always @(*) begin
        assume (e_saw < 3 && e_sw < 3 && e_sar < 3 && e_sb < 3 && e_sr < 3);
        assume (e_mb0 < 3 && e_mb1 < 3 && e_mr0 < 3 && e_mr1 < 3 && e_w0 < 3 && e_w1 < 3);
    end
    generate
        for (k = 0; k < 2; k = k + 1) begin : g_sequential
            always @(*) begin
                if (m_awvalid[k]) assume (!m_arvalid[k] && !m_ar_open[k] && !m_aw_open[k]);
                if (m_arvalid[k]) assume (!m_aw_open[k] && !m_w_open[k] && !m_ar_open[k]);
                if (m_wvalid[k]) assume (!m_w_open[k] && (m_awvalid[k] || m_aw_open[k]));
            end
        end
    endgenerate

    // every request is granted and completed within a bound
    reg [5:0] w_req0, w_req1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {w_req0, w_req1} <= 12'b0;
        else begin
            w_req0 <= (m_awvalid[0] || m_arvalid[0] || m_aw_open[0] || m_ar_open[0]) && !(m_b_hs[0] || m_r_hs[0]) ? w_req0 + 6'd1 : 6'd0;
            w_req1 <= (m_awvalid[1] || m_arvalid[1] || m_aw_open[1] || m_ar_open[1]) && !(m_b_hs[1] || m_r_hs[1]) ? w_req1 + 6'd1 : 6'd0;
        end
    end
    always @(*) assert (w_req0 < 40 && w_req1 < 40);
`endif

    // reachability, counted from the end of reset
    reg c_m0_wrote, c_m1_read;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) c_m0_wrote <= 1'b0; else if (m_b_hs[0]) c_m0_wrote <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) c_m1_read <= 1'b0; else if (m_r_hs[1]) c_m1_read <= 1'b1;
    always @(posedge clk) if (f_run) begin
        cover (m_awvalid == 2'b11 && m_bvalid != 2'b00);         // contention with a write open
        cover (c_m0_wrote && m_r_hs[1]);                         // grant passed to the other master
        cover (c_m1_read && m_b_hs[0] && m_arvalid[1]);          // and back, with a request parked
        cover (m_awvalid[0] && m_arvalid[0] && m_b_hs[0]);       // both directions offered, write first
        cover (s_bvalid && !s_bready);                           // slave response held by the master
    end
endmodule
`default_nettype wire
