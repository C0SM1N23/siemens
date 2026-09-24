// Formal harness for soc_axi_full2lite: AXI4-Full bursts in, AXI4-Lite beats out.
//
// The Full-side master and the Lite-side slave are unconstrained apart from the
// protocol; burst length, size, type and address are free. Ghost state keeps
// each burst's parameters and counts beats on both sides.
//
// Safety (proven by induction), for every length from 1 to 256 beats: a
// supported burst (INCR or FIXED, 32-bit beats, word-aligned address) becomes
// exactly LEN+1 Lite transactions at the right addresses, read data and each
// beat's response pass through, RLAST marks the last beat only, the write
// response is the worst beat response (DECERR > SLVERR > OKAY) and arrives once
// after the last beat; any other burst is answered with SLVERR on every beat and
// never reaches the Lite side. The "live" task bounds the time a burst of up to
// 16 beats takes when both neighbours answer within two cycles.
`default_nettype none
module bridge_formal (
    input wire clk,
    input wire rst_n,

    input wire [31:0] s_awaddr,
    input wire [ 7:0] s_awlen,
    input wire [ 2:0] s_awsize,
    input wire [ 1:0] s_awburst,
    input wire        s_awvalid,
    input wire [31:0] s_wdata,
    input wire [ 3:0] s_wstrb,
    input wire        s_wlast,
    input wire        s_wvalid,
    input wire        s_bready,
    input wire [31:0] s_araddr,
    input wire [ 7:0] s_arlen,
    input wire [ 2:0] s_arsize,
    input wire [ 1:0] s_arburst,
    input wire        s_arvalid,
    input wire        s_rready,

    input wire        m_awready,
    input wire        m_wready,
    input wire [ 1:0] m_bresp,
    input wire        m_bvalid,
    input wire        m_arready,
    input wire [31:0] m_rdata,
    input wire [ 1:0] m_rresp,
    input wire        m_rvalid
);
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    wire        s_awready, s_wready, s_bvalid, s_arready, s_rvalid, s_rlast;
    wire [ 1:0] s_bresp, s_rresp;
    wire [31:0] s_rdata;
    wire [31:0] m_awaddr, m_wdata, m_araddr;
    wire [ 2:0] m_awprot, m_arprot;
    wire [ 3:0] m_wstrb;
    wire        m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;

    soc_axi_full2lite dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .s_awaddr_i(s_awaddr), .s_awlen_i(s_awlen), .s_awsize_i(s_awsize), .s_awburst_i(s_awburst),
        .s_awvalid_i(s_awvalid), .s_awready_o(s_awready),
        .s_wdata_i(s_wdata), .s_wstrb_i(s_wstrb), .s_wlast_i(s_wlast), .s_wvalid_i(s_wvalid), .s_wready_o(s_wready),
        .s_bresp_o(s_bresp), .s_bvalid_o(s_bvalid), .s_bready_i(s_bready),
        .s_araddr_i(s_araddr), .s_arlen_i(s_arlen), .s_arsize_i(s_arsize), .s_arburst_i(s_arburst),
        .s_arvalid_i(s_arvalid), .s_arready_o(s_arready),
        .s_rdata_o(s_rdata), .s_rresp_o(s_rresp), .s_rlast_o(s_rlast), .s_rvalid_o(s_rvalid), .s_rready_i(s_rready),
        .m_awaddr_o(m_awaddr), .m_awprot_o(m_awprot), .m_awvalid_o(m_awvalid), .m_awready_i(m_awready),
        .m_wdata_o(m_wdata), .m_wstrb_o(m_wstrb), .m_wvalid_o(m_wvalid), .m_wready_i(m_wready),
        .m_bresp_i(m_bresp), .m_bvalid_i(m_bvalid), .m_bready_o(m_bready),
        .m_araddr_o(m_araddr), .m_arprot_o(m_arprot), .m_arvalid_o(m_arvalid), .m_arready_i(m_arready),
        .m_rdata_i(m_rdata), .m_rresp_i(m_rresp), .m_rvalid_i(m_rvalid), .m_rready_o(m_rready)
    );

    reg f_past_valid = 1'b0, f_past_rst_n = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    always @(posedge clk) f_past_rst_n <= rst_n;
    initial assume (!rst_n);
    wire f_run = f_past_valid && f_past_rst_n && rst_n;

    wire s_aw_hs = s_awvalid && s_awready;
    wire s_w_hs  = s_wvalid && s_wready;
    wire s_b_hs  = s_bvalid && s_bready;
    wire s_ar_hs = s_arvalid && s_arready;
    wire s_r_hs  = s_rvalid && s_rready;
    wire m_aw_hs = m_awvalid && m_awready;
    wire m_w_hs  = m_wvalid && m_wready;
    wire m_b_hs  = m_bvalid && m_bready;
    wire m_ar_hs = m_arvalid && m_arready;
    wire m_r_hs  = m_rvalid && m_rready;

    // ---- read path ghost ------------------------------------------------------
    reg        g_rd_open, g_rd_ok, g_rd_fixed;
    reg [ 7:0] g_rd_len;
    reg [ 8:0] g_lite_ar, g_full_r;  // Lite ARs issued, Full R beats delivered
    reg        g_lite_r_open;        // a Lite AR accepted, its R not yet taken
    wire ar_ok = (s_arburst == 2'b01 || s_arburst == 2'b00) && s_arsize == 3'b010 && s_araddr[1:0] == 2'b00;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_rd_open <= 1'b0; else if (s_ar_hs) g_rd_open <= 1'b1; else if (s_r_hs && s_rlast) g_rd_open <= 1'b0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) {g_rd_ok, g_rd_fixed, g_rd_len} <= 10'b0;
        else if (s_ar_hs) {g_rd_ok, g_rd_fixed, g_rd_len} <= {ar_ok, s_arburst == 2'b00, s_arlen};
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_lite_ar <= 9'd0; else if (s_ar_hs) g_lite_ar <= 9'd0; else if (m_ar_hs) g_lite_ar <= g_lite_ar + 9'd1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_full_r <= 9'd0; else if (s_ar_hs) g_full_r <= 9'd0; else if (s_r_hs) g_full_r <= g_full_r + 9'd1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_lite_r_open <= 1'b0; else if (m_r_hs) g_lite_r_open <= m_ar_hs; else if (m_ar_hs) g_lite_r_open <= 1'b1;
    // address the next Lite read must carry: the burst start, plus 4 per delivered
    // beat for INCR
    reg [31:0] g_next_raddr;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_next_raddr <= 32'b0;
        else if (s_ar_hs) g_next_raddr <= s_araddr;
        else if (s_r_hs && !g_rd_fixed) g_next_raddr <= g_next_raddr + 32'd4;

    // ---- write path ghost -----------------------------------------------------
    reg        g_wr_open, g_wr_ok, g_wr_fixed;
    reg [ 7:0] g_wr_len;
    reg [ 8:0] g_lite_aw, g_lite_b, g_full_w;
    reg [ 1:0] g_worst;              // worst Lite B response of this burst
    reg        g_lite_aw_open, g_lite_w_open;
    wire aw_ok = (s_awburst == 2'b01 || s_awburst == 2'b00) && s_awsize == 3'b010 && s_awaddr[1:0] == 2'b00;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_wr_open <= 1'b0; else if (s_aw_hs) g_wr_open <= 1'b1; else if (s_b_hs) g_wr_open <= 1'b0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) {g_wr_ok, g_wr_fixed, g_wr_len} <= 10'b0;
        else if (s_aw_hs) {g_wr_ok, g_wr_fixed, g_wr_len} <= {aw_ok, s_awburst == 2'b00, s_awlen};
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_lite_aw <= 9'd0; else if (s_aw_hs) g_lite_aw <= 9'd0; else if (m_aw_hs) g_lite_aw <= g_lite_aw + 9'd1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_lite_b <= 9'd0; else if (s_aw_hs) g_lite_b <= 9'd0; else if (m_b_hs) g_lite_b <= g_lite_b + 9'd1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_full_w <= 9'd0; else if (s_aw_hs) g_full_w <= 9'd0; else if (s_w_hs) g_full_w <= g_full_w + 9'd1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_worst <= OKAY; else if (s_aw_hs) g_worst <= OKAY; else if (m_b_hs && m_bresp > g_worst) g_worst <= m_bresp;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_lite_aw_open <= 1'b0; else if (m_b_hs) g_lite_aw_open <= 1'b0; else if (m_aw_hs) g_lite_aw_open <= 1'b1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_lite_w_open <= 1'b0; else if (m_b_hs) g_lite_w_open <= 1'b0; else if (m_w_hs) g_lite_w_open <= 1'b1;
    reg [31:0] g_next_waddr;  // address of the next Lite write, as for reads
    always @(posedge clk or negedge rst_n)
        if (!rst_n) g_next_waddr <= 32'b0;
        else if (s_aw_hs) g_next_waddr <= s_awaddr;
        else if (m_b_hs && !g_wr_fixed) g_next_waddr <= g_next_waddr + 32'd4;

    // ---- Full-side master: AXI4 rules -----------------------------------------
    // A burst's W beats: LEN+1 of them, WLAST on the last. A beat may be offered
    // before its AW or while the previous burst's response is pending; the bridge
    // must hold it off until the burst it belongs to is accepted.
    always @(*) begin
        if (!rst_n) assume (!s_awvalid && !s_wvalid && !s_arvalid);
        if (s_wvalid && g_wr_open && g_full_w <= {1'b0, g_wr_len}) assume (s_wlast == (g_full_w == {1'b0, g_wr_len}));
        if (s_w_hs) assert (g_wr_open && g_full_w <= {1'b0, g_wr_len});  // never a beat too many
    end
    always @(posedge clk) if (f_run) begin
        if ($past(s_awvalid && !s_awready))
            assume (s_awvalid && s_awaddr == $past(s_awaddr) && s_awlen == $past(s_awlen)
                    && s_awsize == $past(s_awsize) && s_awburst == $past(s_awburst));
        if ($past(s_arvalid && !s_arready))
            assume (s_arvalid && s_araddr == $past(s_araddr) && s_arlen == $past(s_arlen)
                    && s_arsize == $past(s_arsize) && s_arburst == $past(s_arburst));
        if ($past(s_wvalid && !s_wready))
            assume (s_wvalid && s_wdata == $past(s_wdata) && s_wstrb == $past(s_wstrb) && s_wlast == $past(s_wlast));
    end

    // ---- Lite-side slave: AXI4-Lite rules ---------------------------------------
    always @(*) begin
        if (!rst_n) assume (!m_bvalid && !m_rvalid);
        if (m_bvalid) assume (g_lite_aw_open && g_lite_w_open);
        if (m_rvalid) assume (g_lite_r_open);
        assume (m_bresp != 2'b01 && m_rresp != 2'b01);
    end
    always @(posedge clk) if (f_run) begin
        if ($past(m_bvalid && !m_bready)) assume (m_bvalid && m_bresp == $past(m_bresp));
        if ($past(m_rvalid && !m_rready)) assume (m_rvalid && m_rdata == $past(m_rdata) && m_rresp == $past(m_rresp));
    end

    // ---- properties: read path --------------------------------------------------
    always @(*) begin
        if (!rst_n) assert (!s_rvalid && !s_bvalid && !m_awvalid && !m_wvalid && !m_arvalid);
        if (s_ar_hs) assert (!g_rd_open);                      // one burst per direction
        if (s_rvalid) assert (g_rd_open && g_full_r <= {1'b0, g_rd_len});
        if (s_rvalid) assert (s_rlast == (g_full_r == {1'b0, g_rd_len}));
        if (m_arvalid) begin                                   // Lite reads: only for a supported burst
            assert (g_rd_open && g_rd_ok && g_lite_ar <= {1'b0, g_rd_len} && g_lite_ar == g_full_r);
            assert (m_araddr == g_next_raddr);
            assert (!g_lite_r_open);                           // one Lite read at a time
        end
        if (g_rd_open && !g_rd_ok) assert (!m_arvalid && !g_lite_r_open && g_lite_ar == 9'd0);
        if (s_rvalid && !g_rd_ok) assert (s_rresp == SLVERR && s_rdata == 32'b0);
        if (s_rvalid && g_rd_ok) assert (m_rvalid && s_rresp == m_rresp && s_rdata == m_rdata && g_lite_r_open
                                         || m_rvalid && m_arvalid);
        if (m_r_hs) assert (s_r_hs);                           // every Lite beat is delivered
        if (s_r_hs && g_rd_ok) assert (m_r_hs);
        if (g_rd_open && g_rd_ok) assert (g_lite_ar == g_full_r + {8'd0, g_lite_r_open} || m_ar_hs);
    end
    always @(posedge clk) if (f_run) begin
        if ($past(s_rvalid && !s_rready))
            assert (s_rvalid && s_rdata == $past(s_rdata) && s_rresp == $past(s_rresp) && s_rlast == $past(s_rlast));
        if ($past(m_arvalid && !m_arready)) assert (m_arvalid && m_araddr == $past(m_araddr));
    end

    // ---- properties: write path -------------------------------------------------
    always @(*) begin
        if (s_aw_hs) assert (!g_wr_open);
        if (m_awvalid || m_wvalid) assert (g_wr_open && g_wr_ok && !s_bvalid);
        if (m_awvalid) begin
            assert (g_lite_aw <= {1'b0, g_wr_len} && g_lite_aw == g_lite_b && !g_lite_aw_open);
            assert (m_awaddr == g_next_waddr);
        end
        if (m_wvalid) assert (s_wvalid && m_wdata == s_wdata && m_wstrb == s_wstrb && !g_lite_w_open
                              && g_full_w == g_lite_b);
        if (s_w_hs && g_wr_ok) assert (m_w_hs);                 // a Full beat becomes a Lite beat
        if (m_w_hs) assert (s_w_hs);
        if (g_wr_open && !g_wr_ok) assert (!m_awvalid && !m_wvalid && g_lite_aw == 9'd0);
        if (s_bvalid) begin                                     // one B, after the last beat
            assert (g_wr_open && g_full_w == {1'b0, g_wr_len} + 9'd1);
            assert (s_bresp == (g_wr_ok ? g_worst : SLVERR));
            if (g_wr_ok) assert (g_lite_b == {1'b0, g_wr_len} + 9'd1 && !g_lite_aw_open && !g_lite_w_open);
        end
    end
    always @(posedge clk) if (f_run) begin
        if ($past(s_bvalid && !s_bready)) assert (s_bvalid && s_bresp == $past(s_bresp));
        if ($past(m_awvalid && !m_awready)) assert (m_awvalid && m_awaddr == $past(m_awaddr));
        if ($past(m_wvalid && !m_wready)) assert (m_wvalid && m_wdata == $past(m_wdata) && m_wstrb == $past(m_wstrb));
    end

    // ---- the bridge's own state agrees with the ghost -------------------------
    // The bridge's internal registers, connected by bridge.sby after flattening.
    wire [1:0] h_r_state;
    wire h_r_ar_sent;
    wire [7:0] h_r_len;
    wire h_r_fixed;
    wire [7:0] h_r_beat;
    wire [31:0] h_r_addr;
    wire [1:0] h_w_state;
    wire [7:0] h_w_len;
    wire h_w_fixed;
    wire [7:0] h_w_beat;
    wire [31:0] h_w_addr;
    wire h_w_aw_sent;
    wire h_w_w_sent;
    wire [1:0] h_w_resp;
    // Stated so the properties above are inductive; proven like everything else.
    // Out of reset only: the connected wire is the register itself, which in the
    // formal model takes its reset value at the first edge in reset.
    localparam [1:0] R_IDLE = 2'd0, R_RUN = 2'd1, R_ERR = 2'd2;
    localparam [1:0] W_IDLE = 2'd0, W_RUN = 2'd1, W_ERR = 2'd2, W_RESP = 2'd3;
    always @(*) if (rst_n && f_past_valid) begin
        assert (h_r_state != 2'd3);
        assert (g_rd_open == (h_r_state != R_IDLE));
        assert (g_lite_r_open == h_r_ar_sent);
        if (g_rd_open) begin
            assert (h_r_len == g_rd_len && h_r_fixed == g_rd_fixed);
            assert (g_rd_ok == (h_r_state == R_RUN));
            assert (!g_full_r[8] && h_r_beat == g_full_r[7:0] && h_r_beat <= h_r_len);
            if (g_rd_ok) assert (h_r_addr == g_next_raddr && g_lite_ar == g_full_r + {8'd0, g_lite_r_open});
            else assert (g_lite_ar == 9'd0 && !h_r_ar_sent);
        end else begin
            assert (!g_lite_r_open);
        end

        assert (g_wr_open == (h_w_state != W_IDLE));
        if (h_w_state == W_RUN) begin
            assert (g_wr_ok && h_w_len == g_wr_len && h_w_fixed == g_wr_fixed);
            assert (!g_lite_b[8] && h_w_beat == g_lite_b[7:0] && h_w_beat <= h_w_len);
            assert (h_w_addr == g_next_waddr);
            assert (g_lite_aw_open == h_w_aw_sent && g_lite_w_open == h_w_w_sent);
            assert (g_lite_aw == g_lite_b + {8'd0, g_lite_aw_open});
            assert (g_full_w == g_lite_b + {8'd0, g_lite_w_open});
            assert (h_w_resp == g_worst);
        end
        if (h_w_state == W_ERR) begin
            assert (!g_wr_ok && h_w_len == g_wr_len && h_w_resp == SLVERR);
            assert (!g_full_w[8] && h_w_beat == g_full_w[7:0] && h_w_beat <= h_w_len);
            assert (g_lite_aw == 9'd0 && !g_lite_aw_open && !g_lite_w_open);
        end
        if (h_w_state == W_RESP) begin
            assert (g_full_w == {1'b0, g_wr_len} + 9'd1);
            assert (h_w_resp == (g_wr_ok ? g_worst : SLVERR));
            if (g_wr_ok) assert (g_lite_b == {1'b0, g_wr_len} + 9'd1 && g_lite_aw == g_lite_b);
            else assert (g_lite_aw == 9'd0);
            assert (!g_lite_aw_open && !g_lite_w_open);
        end
        if (h_w_state == W_IDLE) assert (!g_lite_aw_open && !g_lite_w_open);
    end

`ifdef LIVE
    // Bursts of up to 16 beats; every neighbour answers within two cycles.
    always @(*) begin
        if (s_arvalid) assume (s_arlen < 8'd16);
        if (s_awvalid) assume (s_awlen < 8'd16);
    end
    reg [2:0] e_rr, e_bb, e_w, e_maw, e_mw, e_mar, e_mb, e_mr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {e_rr, e_bb, e_w, e_maw, e_mw, e_mar, e_mb, e_mr} <= 24'b0;
        else begin
            e_rr  <= (s_rvalid && !s_rready) ? e_rr + 3'd1 : 3'd0;
            e_bb  <= (s_bvalid && !s_bready) ? e_bb + 3'd1 : 3'd0;
            e_w   <= (g_wr_open && g_full_w <= {1'b0, g_wr_len} && !s_wvalid) ? e_w + 3'd1 : 3'd0;
            e_maw <= (m_awvalid && !m_awready) ? e_maw + 3'd1 : 3'd0;
            e_mw  <= (m_wvalid && !m_wready) ? e_mw + 3'd1 : 3'd0;
            e_mar <= (m_arvalid && !m_arready) ? e_mar + 3'd1 : 3'd0;
            e_mb  <= (g_lite_aw_open && g_lite_w_open && !m_bvalid) ? e_mb + 3'd1 : 3'd0;
            e_mr  <= (g_lite_r_open && !m_rvalid) ? e_mr + 3'd1 : 3'd0;
        end
    end
    always @(*) assume (e_rr < 3 && e_bb < 3 && e_w < 3 && e_maw < 3 && e_mw < 3 && e_mar < 3 && e_mb < 3 && e_mr < 3);

    reg [7:0] w_rd, w_wr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {w_rd, w_wr} <= 16'b0;
        else begin
            w_rd <= g_rd_open ? w_rd + 8'd1 : 8'd0;
            w_wr <= g_wr_open ? w_wr + 8'd1 : 8'd0;
        end
    end
    always @(*) assert (w_rd < 8'd200 && w_wr < 8'd200);  // 16 beats, under ten cycles each
`endif

    // reachability, counted from the end of reset
    always @(posedge clk) if (f_run) begin
        cover (s_r_hs && s_rlast && g_rd_ok && g_rd_len == 8'd3);          // a 4-beat read completes
        cover (s_b_hs && g_wr_ok && g_wr_len == 8'd2 && s_bresp == 2'b11);  // a write folds a DECERR
        cover (s_b_hs && !g_wr_ok);                                         // refused write burst
        cover (s_r_hs && s_rlast && !g_rd_ok);                              // refused read burst
        cover (s_r_hs && g_rd_ok && s_rresp == SLVERR && !s_rlast);         // per-beat read error
        cover (m_aw_hs && g_wr_fixed && g_lite_aw == 9'd1);                 // FIXED keeps the address
    end
endmodule
`default_nettype wire
