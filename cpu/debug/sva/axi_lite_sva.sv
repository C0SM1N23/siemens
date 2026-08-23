// AXI4-Lite protocol assertions (SVA) — bindable, verification only.
//
// One instance watches one AXI4-Lite port and checks the rules the design is
// built around (ARCHITECTURE.md section 4) as formal properties:
// - VALID never waits for READY, and once VALID is up the payload holds until
//   the handshake (the two obligations fetch_unit and lsu rely on)
// - a response only ever answers an outstanding request (R after AR, B after
//   AW+W), at most one in flight per direction — the ≤1-outstanding claim (D6, D12)
// - response codes are legal AXI4-Lite (EXOKAY never appears)
// - all VALIDs are low in reset
//
// axi_lite_monitor.v stays the ModelSim-compatible checker; this is the same
// contract in SVA for tools that support it (Verilator --assert, Questa). Bound
// from bind_sva.sv — no RTL is touched.
//
// Parameters: NAME tags the messages; HAS_WRITE 0 = read-only port (no write
// checks); CHECK_ALIGN 1 = ARADDR must be word-aligned (instruction fetch, not
// dbus where LB/LBU legally carry a byte address).

`timescale 1ns/1ps

module axi_lite_sva #(
    parameter NAME        = "axi",
    parameter HAS_WRITE   = 1,
    parameter CHECK_ALIGN = 0
)(
    input        clk_i,
    input        rst_n_i,

    input [31:0] awaddr_i,
    input        awvalid_i,
    input        awready_i,
    input [31:0] wdata_i,
    input [3:0]  wstrb_i,
    input        wvalid_i,
    input        wready_i,
    input [1:0]  bresp_i,
    input        bvalid_i,
    input        bready_i,

    input [31:0] araddr_i,
    input        arvalid_i,
    input        arready_i,
    input [31:0] rdata_i,
    input [1:0]  rresp_i,
    input        rvalid_i,
    input        rready_i
);

wire ar_hs = arvalid_i && arready_i;
wire r_hs  = rvalid_i  && rready_i;
wire aw_hs = awvalid_i && awready_i;
wire w_hs  = wvalid_i  && wready_i;
wire b_hs  = bvalid_i  && bready_i;

// read transaction in flight: set by the AR handshake, cleared by the R beat.
// One bit is enough — issuing a second AR while set is exactly the violation
// the rd_max_one assertion reports.
reg rd_out_q;
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        rd_out_q <= 1'b0;
    else if (ar_hs && !r_hs)
        rd_out_q <= 1'b1;
    else if (r_hs && !ar_hs)
        rd_out_q <= 1'b0;
end

// --- read channel properties ---

ar_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    arvalid_i && !arready_i |=> arvalid_i)
    else $error("[%0s] ARVALID dropped before ARREADY", NAME);

ar_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    arvalid_i && !arready_i |=> $stable(araddr_i))
    else $error("[%0s] ARADDR changed while ARVALID waiting", NAME);

r_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rvalid_i && !rready_i |=> rvalid_i)
    else $error("[%0s] RVALID dropped before RREADY", NAME);

r_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rvalid_i && !rready_i |=> $stable(rdata_i) && $stable(rresp_i))
    else $error("[%0s] R payload changed while RVALID waiting", NAME);

r_needs_outstanding: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rvalid_i |-> rd_out_q)
    else $error("[%0s] RVALID with no outstanding AR", NAME);

rd_max_one: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    ar_hs |-> !rd_out_q || r_hs)
    else $error("[%0s] second AR issued while one read in flight", NAME);

r_resp_legal: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    r_hs |-> rresp_i != 2'b01)
    else $error("[%0s] RRESP = EXOKAY is illegal on AXI4-Lite", NAME);

ar_reset_quiet: assert property (@(posedge clk_i)
    !rst_n_i |-> !arvalid_i)
    else $error("[%0s] ARVALID asserted during reset", NAME);

generate if (CHECK_ALIGN) begin : g_align
    ar_addr_aligned: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        ar_hs |-> araddr_i[1:0] == 2'b00)
        else $error("[%0s] misaligned ARADDR", NAME);
end endgenerate

// --- read channel functional cover points ---

cov_ar_backpressure: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    arvalid_i && !arready_i);
cov_r_wait: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    rvalid_i && !rready_i);
cov_r_slverr: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    r_hs && rresp_i == 2'b10);
cov_r_decerr: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    r_hs && rresp_i == 2'b11);

// --- write channel properties (masters with a write path only) ---

generate if (HAS_WRITE) begin : g_write

    // write phases collected so far: AW and W each arm once, the B beat
    // closes the transaction and rearms both
    reg aw_done_q, w_done_q;
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            aw_done_q <= 1'b0;
        else if (aw_hs)
            aw_done_q <= 1'b1;
        else if (b_hs)
            aw_done_q <= 1'b0;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            w_done_q <= 1'b0;
        else if (w_hs)
            w_done_q <= 1'b1;
        else if (b_hs)
            w_done_q <= 1'b0;
    end

    aw_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        awvalid_i && !awready_i |=> awvalid_i)
        else $error("[%0s] AWVALID dropped before AWREADY", NAME);

    aw_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        awvalid_i && !awready_i |=> $stable(awaddr_i))
        else $error("[%0s] AWADDR changed while AWVALID waiting", NAME);

    w_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        wvalid_i && !wready_i |=> wvalid_i)
        else $error("[%0s] WVALID dropped before WREADY", NAME);

    w_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        wvalid_i && !wready_i |=> $stable(wdata_i) && $stable(wstrb_i))
        else $error("[%0s] W payload changed while WVALID waiting", NAME);

    b_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        bvalid_i && !bready_i |=> bvalid_i)
        else $error("[%0s] BVALID dropped before BREADY", NAME);

    b_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        bvalid_i && !bready_i |=> $stable(bresp_i))
        else $error("[%0s] BRESP changed while BVALID waiting", NAME);

    b_needs_both: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        bvalid_i |-> aw_done_q && w_done_q)
        else $error("[%0s] BVALID before AW+W handshakes completed", NAME);

    aw_max_one: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        aw_hs |-> !aw_done_q || b_hs)
        else $error("[%0s] second AW issued while one write in flight", NAME);

    w_max_one: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        w_hs |-> !w_done_q || b_hs)
        else $error("[%0s] second W issued while one write in flight", NAME);

    b_resp_legal: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        b_hs |-> bresp_i != 2'b01)
        else $error("[%0s] BRESP = EXOKAY is illegal on AXI4-Lite", NAME);

    awvalid_reset_quiet: assert property (@(posedge clk_i)
        !rst_n_i |-> !awvalid_i && !wvalid_i)
        else $error("[%0s] AW/W VALID asserted during reset", NAME);

    cov_aw_backpressure: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        awvalid_i && !awready_i);
    cov_w_backpressure: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        wvalid_i && !wready_i);
    cov_b_wait: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        bvalid_i && !bready_i);
    cov_b_slverr: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        b_hs && bresp_i == 2'b10);
    cov_b_decerr: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        b_hs && bresp_i == 2'b11);

end endgenerate

endmodule
