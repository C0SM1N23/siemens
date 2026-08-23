// AXI4-Full protocol assertions (SVA) - bindable, verification only.
//
// The companion to cpu/debug/sva/axi_lite_sva.sv, for the one port in the SoC
// that is not AXI4-Lite: the DMA's master, which issues INCR bursts. The Lite
// checker cannot be used there, because everything interesting about a burst
// is in the fields Lite does not have - AWLEN/ARLEN, WLAST, RLAST.
//
// What it checks, beyond the handshake rules the Lite checker already covers:
//   - the beat count matches the length field: WLAST lands on beat AWLEN,
//     RLAST on beat ARLEN, and neither lands early
//   - one burst outstanding per direction, which is what the burst bridge in
//     front of it is designed for
//   - the burst attributes are inside the subset the bridge supports, so an
//     unsupported burst is caught here as well as refused there
//
// This watches the DMA's port from the outside, so it holds the DMA to the
// protocol as much as it holds the bridge to it. If the DMA ever issues a
// burst it should not, this fires before the bridge has to decide what to do
// with it.

`timescale 1ns/1ps

// CHECK_SUBSET selects whether the "burst is inside the bridge's supported
// subset" assertions are active. They are a contract on the MASTER, so they
// belong on the DMA's own port (bound with 1). They must be off when the same
// checker watches the bridge's slave side in tb_full2lite, because that bench
// deliberately drives a WRAP burst to prove the bridge refuses it - the very
// thing these assertions forbid.
module axi_full_sva #(
    parameter NAME = "axi_full",
    parameter CHECK_SUBSET = 1
)(
    input        clk_i,
    input        rst_n_i,

    input [31:0] awaddr_i,
    input [7:0]  awlen_i,
    input [2:0]  awsize_i,
    input [1:0]  awburst_i,
    input        awvalid_i,
    input        awready_i,
    input [31:0] wdata_i,
    input [3:0]  wstrb_i,
    input        wlast_i,
    input        wvalid_i,
    input        wready_i,
    input [1:0]  bresp_i,
    input        bvalid_i,
    input        bready_i,

    input [31:0] araddr_i,
    input [7:0]  arlen_i,
    input [2:0]  arsize_i,
    input [1:0]  arburst_i,
    input        arvalid_i,
    input        arready_i,
    input [31:0] rdata_i,
    input [1:0]  rresp_i,
    input        rlast_i,
    input        rvalid_i,
    input        rready_i
);

localparam [1:0] BURST_FIXED = 2'b00;
localparam [1:0] BURST_INCR  = 2'b01;
localparam [2:0] SIZE_32     = 3'b010;

wire aw_hs = awvalid_i && awready_i;
wire w_hs  = wvalid_i  && wready_i;
wire b_hs  = bvalid_i  && bready_i;
wire ar_hs = arvalid_i && arready_i;
wire r_hs  = rvalid_i  && rready_i;

// ---------------------------------------------------------------------------
// shadow state: which burst is in flight and how far through it we are
// ---------------------------------------------------------------------------
reg        rd_out_q;      // a read burst is in flight
reg [7:0]  rd_len_q;      // its ARLEN
reg [7:0]  rd_beat_q;     // beats delivered so far

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        rd_out_q  <= 1'b0;
        rd_len_q  <= 8'd0;
        rd_beat_q <= 8'd0;
    end else begin
        if (ar_hs) begin
            rd_out_q  <= 1'b1;
            rd_len_q  <= arlen_i;
            rd_beat_q <= 8'd0;
        end else if (r_hs) begin
            if (rlast_i) rd_out_q  <= 1'b0;
            else         rd_beat_q <= rd_beat_q + 8'd1;
        end
    end
end

reg        wr_out_q;
reg [7:0]  wr_len_q;
reg [7:0]  wr_beat_q;
reg        wr_data_done_q;   // WLAST seen, waiting for B

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        wr_out_q       <= 1'b0;
        wr_len_q       <= 8'd0;
        wr_beat_q      <= 8'd0;
        wr_data_done_q <= 1'b0;
    end else begin
        if (aw_hs) begin
            wr_out_q       <= 1'b1;
            wr_len_q       <= awlen_i;
            wr_beat_q      <= 8'd0;
            wr_data_done_q <= 1'b0;
        end
        if (w_hs && !wlast_i)
            wr_beat_q <= wr_beat_q + 8'd1;
        if (w_hs && wlast_i)
            wr_data_done_q <= 1'b1;
        if (b_hs) begin
            wr_out_q       <= 1'b0;
            wr_data_done_q <= 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------
// read channel
// ---------------------------------------------------------------------------
ar_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    arvalid_i && !arready_i |=> arvalid_i)
    else $error("[%0s] ARVALID dropped before ARREADY", NAME);

ar_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    arvalid_i && !arready_i |=> $stable(araddr_i) && $stable(arlen_i)
                             && $stable(arsize_i) && $stable(arburst_i))
    else $error("[%0s] AR payload changed while ARVALID waiting", NAME);

ar_one_outstanding: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    ar_hs |-> !rd_out_q)
    else $error("[%0s] second read burst issued while one is in flight", NAME);

r_needs_outstanding: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rvalid_i |-> rd_out_q)
    else $error("[%0s] RVALID with no outstanding AR", NAME);

r_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rvalid_i && !rready_i |=> rvalid_i)
    else $error("[%0s] RVALID dropped before RREADY", NAME);

r_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rvalid_i && !rready_i |=> $stable(rdata_i) && $stable(rresp_i) && $stable(rlast_i))
    else $error("[%0s] R payload changed while RVALID waiting", NAME);

// the two halves of "the beat count matches the length field"
r_last_on_final_beat: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    r_hs && rlast_i |-> rd_beat_q == rd_len_q)
    else $error("[%0s] RLAST on beat %0d of a burst of length %0d",
                NAME, rd_beat_q, rd_len_q);

r_no_last_before_final: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    r_hs && rd_beat_q != rd_len_q |-> !rlast_i)
    else $error("[%0s] RLAST asserted early", NAME);

r_beat_in_range: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rd_out_q |-> rd_beat_q <= rd_len_q)
    else $error("[%0s] more R beats delivered than ARLEN allows", NAME);

r_resp_legal: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    r_hs |-> rresp_i != 2'b01)
    else $error("[%0s] RRESP = EXOKAY is illegal here", NAME);

// ---------------------------------------------------------------------------
// write channel
// ---------------------------------------------------------------------------
aw_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    awvalid_i && !awready_i |=> awvalid_i)
    else $error("[%0s] AWVALID dropped before AWREADY", NAME);

aw_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    awvalid_i && !awready_i |=> $stable(awaddr_i) && $stable(awlen_i)
                             && $stable(awsize_i) && $stable(awburst_i))
    else $error("[%0s] AW payload changed while AWVALID waiting", NAME);

aw_one_outstanding: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    aw_hs |-> !wr_out_q)
    else $error("[%0s] second write burst issued while one is in flight", NAME);

w_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    wvalid_i && !wready_i |=> wvalid_i)
    else $error("[%0s] WVALID dropped before WREADY", NAME);

w_payload_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    wvalid_i && !wready_i |=> $stable(wdata_i) && $stable(wstrb_i) && $stable(wlast_i))
    else $error("[%0s] W payload changed while WVALID waiting", NAME);

w_needs_address: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_hs |-> wr_out_q)
    else $error("[%0s] W beat with no outstanding AW", NAME);

w_last_on_final_beat: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_hs && wlast_i |-> wr_beat_q == wr_len_q)
    else $error("[%0s] WLAST on beat %0d of a burst of length %0d",
                NAME, wr_beat_q, wr_len_q);

w_no_last_before_final: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_hs && wr_beat_q != wr_len_q |-> !wlast_i)
    else $error("[%0s] WLAST asserted early", NAME);

w_no_beat_after_last: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_hs |-> !wr_data_done_q)
    else $error("[%0s] W beat after WLAST, before the burst was answered", NAME);

b_needs_data_done: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    bvalid_i |-> wr_out_q && wr_data_done_q)
    else $error("[%0s] BVALID before the write burst finished its data", NAME);

b_valid_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    bvalid_i && !bready_i |=> bvalid_i && $stable(bresp_i))
    else $error("[%0s] B channel unstable while waiting for BREADY", NAME);

b_resp_legal: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    b_hs |-> bresp_i != 2'b01)
    else $error("[%0s] BRESP = EXOKAY is illegal here", NAME);

// ---------------------------------------------------------------------------
// the subset the bridge supports. These are not AXI rules - AXI allows WRAP
// and narrow transfers - they are the contract between this master and the
// bridge in front of it, asserted where it is cheapest to see violated.
// ---------------------------------------------------------------------------
generate if (CHECK_SUBSET) begin : g_subset

    ar_burst_supported: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        ar_hs |-> (arburst_i == BURST_INCR || arburst_i == BURST_FIXED)
                  && arsize_i == SIZE_32)
        else $error("[%0s] read burst outside the supported subset: burst=%0b size=%0b",
                    NAME, arburst_i, arsize_i);

    aw_burst_supported: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        aw_hs |-> (awburst_i == BURST_INCR || awburst_i == BURST_FIXED)
                  && awsize_i == SIZE_32)
        else $error("[%0s] write burst outside the supported subset: burst=%0b size=%0b",
                    NAME, awburst_i, awsize_i);

end endgenerate

reset_quiet: assert property (@(posedge clk_i)
    !rst_n_i |-> !arvalid_i && !awvalid_i && !wvalid_i)
    else $error("[%0s] a VALID was asserted during reset", NAME);

// ---------------------------------------------------------------------------
// functional cover: the burst shapes that actually occurred
// ---------------------------------------------------------------------------
cov_read_burst_8:  cover property (@(posedge clk_i) disable iff (!rst_n_i)
    ar_hs && arlen_i == 8'd7);
cov_write_burst_8: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    aw_hs && awlen_i == 8'd7);
cov_r_backpressure: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    rvalid_i && !rready_i);
cov_w_backpressure: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    wvalid_i && !wready_i);
cov_b_slverr: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    b_hs && bresp_i == 2'b10);
cov_r_slverr: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    r_hs && rresp_i == 2'b10);

endmodule
