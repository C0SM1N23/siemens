// AXI4-Lite protocol assertions (SVA) — bindable, verification only.
//
// One instance watches one AXI4-Lite port and checks the protocol rules the
// design is built around (ARCHITECTURE.md section 4), as formal properties
// instead of procedural checks:
//
// - VALID never waits for READY, and once VALID is up the payload holds
//   until the handshake (the two obligations fetch_unit and lsu are built on)
// - a response only ever answers an outstanding request (R after AR,
//   B after AW+W), and at most one transaction is in flight per direction —
//   the <=1-outstanding claim (D6, D12) as a checked property
// - response codes are legal for AXI4-Lite (EXOKAY never appears)
// - all VALIDs are low while in reset
//
// The existing axi_lite_monitor.v stays the ModelSim-compatible checker;
// this file is the same contract written in SVA for tools that support it
// (Verilator --assert, Questa). Bound from bind_sva.sv — no RTL is touched.
//
// Parameters:
// - NAME        tag used in assertion messages
// - HAS_WRITE   0 = read-only port (ibus): write checks are not generated
// - CHECK_ALIGN 1 = ARADDR must be word-aligned (true for instruction fetch;
//                   not for dbus, where LB/LBU legally carry a byte address)

module axi_lite_sva #(
    parameter NAME        = "axi",
    parameter HAS_WRITE   = 1,
    parameter CHECK_ALIGN = 0
)(
    input        clk,
    input        rst_n,

    input [31:0] awaddr,
    input        awvalid,
    input        awready,
    input [31:0] wdata,
    input [3:0]  wstrb,
    input        wvalid,
    input        wready,
    input [1:0]  bresp,
    input        bvalid,
    input        bready,

    input [31:0] araddr,
    input        arvalid,
    input        arready,
    input [31:0] rdata,
    input [1:0]  rresp,
    input        rvalid,
    input        rready
);

wire ar_hs = arvalid && arready;
wire r_hs  = rvalid  && rready;
wire aw_hs = awvalid && awready;
wire w_hs  = wvalid  && wready;
wire b_hs  = bvalid  && bready;

// read transaction in flight: set by the AR handshake, cleared by the R beat.
// One bit is enough — issuing a second AR while set is exactly the violation
// the rd_max_one assertion reports.
reg rd_out_q;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        rd_out_q <= 1'b0;
    else if (ar_hs && !r_hs)
        rd_out_q <= 1'b1;
    else if (r_hs && !ar_hs)
        rd_out_q <= 1'b0;
end

// --- read channel properties ---

ar_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    arvalid && !arready |=> arvalid)
    else $error("[%0s] ARVALID dropped before ARREADY", NAME);

ar_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
    arvalid && !arready |=> $stable(araddr))
    else $error("[%0s] ARADDR changed while ARVALID waiting", NAME);

r_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    rvalid && !rready |=> rvalid)
    else $error("[%0s] RVALID dropped before RREADY", NAME);

r_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
    rvalid && !rready |=> $stable(rdata) && $stable(rresp))
    else $error("[%0s] R payload changed while RVALID waiting", NAME);

r_needs_outstanding: assert property (@(posedge clk) disable iff (!rst_n)
    rvalid |-> rd_out_q)
    else $error("[%0s] RVALID with no outstanding AR", NAME);

rd_max_one: assert property (@(posedge clk) disable iff (!rst_n)
    ar_hs |-> !rd_out_q || r_hs)
    else $error("[%0s] second AR issued while one read in flight", NAME);

r_resp_legal: assert property (@(posedge clk) disable iff (!rst_n)
    r_hs |-> rresp != 2'b01)
    else $error("[%0s] RRESP = EXOKAY is illegal on AXI4-Lite", NAME);

ar_reset_quiet: assert property (@(posedge clk)
    !rst_n |-> !arvalid)
    else $error("[%0s] ARVALID asserted during reset", NAME);

generate if (CHECK_ALIGN) begin : g_align
    ar_addr_aligned: assert property (@(posedge clk) disable iff (!rst_n)
        ar_hs |-> araddr[1:0] == 2'b00)
        else $error("[%0s] misaligned ARADDR", NAME);
end endgenerate

// --- read channel functional cover points ---

cov_ar_backpressure: cover property (@(posedge clk) disable iff (!rst_n)
    arvalid && !arready);
cov_r_wait: cover property (@(posedge clk) disable iff (!rst_n)
    rvalid && !rready);
cov_r_slverr: cover property (@(posedge clk) disable iff (!rst_n)
    r_hs && rresp == 2'b10);
cov_r_decerr: cover property (@(posedge clk) disable iff (!rst_n)
    r_hs && rresp == 2'b11);

// --- write channel properties (masters with a write path only) ---

generate if (HAS_WRITE) begin : g_write

    // write phases collected so far: AW and W each arm once, the B beat
    // closes the transaction and rearms both
    reg aw_done_q, w_done_q;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            aw_done_q <= 1'b0;
        else if (aw_hs)
            aw_done_q <= 1'b1;
        else if (b_hs)
            aw_done_q <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            w_done_q <= 1'b0;
        else if (w_hs)
            w_done_q <= 1'b1;
        else if (b_hs)
            w_done_q <= 1'b0;
    end

    aw_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid && !awready |=> awvalid)
        else $error("[%0s] AWVALID dropped before AWREADY", NAME);

    aw_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid && !awready |=> $stable(awaddr))
        else $error("[%0s] AWADDR changed while AWVALID waiting", NAME);

    w_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        wvalid && !wready |=> wvalid)
        else $error("[%0s] WVALID dropped before WREADY", NAME);

    w_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
        wvalid && !wready |=> $stable(wdata) && $stable(wstrb))
        else $error("[%0s] W payload changed while WVALID waiting", NAME);

    b_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        bvalid && !bready |=> bvalid)
        else $error("[%0s] BVALID dropped before BREADY", NAME);

    b_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
        bvalid && !bready |=> $stable(bresp))
        else $error("[%0s] BRESP changed while BVALID waiting", NAME);

    b_needs_both: assert property (@(posedge clk) disable iff (!rst_n)
        bvalid |-> aw_done_q && w_done_q)
        else $error("[%0s] BVALID before AW+W handshakes completed", NAME);

    aw_max_one: assert property (@(posedge clk) disable iff (!rst_n)
        aw_hs |-> !aw_done_q || b_hs)
        else $error("[%0s] second AW issued while one write in flight", NAME);

    w_max_one: assert property (@(posedge clk) disable iff (!rst_n)
        w_hs |-> !w_done_q || b_hs)
        else $error("[%0s] second W issued while one write in flight", NAME);

    b_resp_legal: assert property (@(posedge clk) disable iff (!rst_n)
        b_hs |-> bresp != 2'b01)
        else $error("[%0s] BRESP = EXOKAY is illegal on AXI4-Lite", NAME);

    awvalid_reset_quiet: assert property (@(posedge clk)
        !rst_n |-> !awvalid && !wvalid)
        else $error("[%0s] AW/W VALID asserted during reset", NAME);

    cov_aw_backpressure: cover property (@(posedge clk) disable iff (!rst_n)
        awvalid && !awready);
    cov_w_backpressure: cover property (@(posedge clk) disable iff (!rst_n)
        wvalid && !wready);
    cov_b_wait: cover property (@(posedge clk) disable iff (!rst_n)
        bvalid && !bready);
    cov_b_slverr: cover property (@(posedge clk) disable iff (!rst_n)
        b_hs && bresp == 2'b10);
    cov_b_decerr: cover property (@(posedge clk) disable iff (!rst_n)
        b_hs && bresp == 2'b11);

end endgenerate

endmodule
