// Passive AXI4-Lite protocol monitor — testbench only. One instance watches
// one bus and flags violations as they happen, so protocol legality is a
// checked property of every run instead of something we trust by inspection.
//
// Checks, per the AXI4-Lite handshake rules plus this CPU's own contract:
//   1. stability: once VALID is high with READY low, VALID must stay high and
//      the payload must not change until the handshake (all 5 channels)
//   2. ordering: R only with a read outstanding, B only after AW and W both
//      accepted; a second AR/AW/W before the response = violation of the
//      "max 1 outstanding per port" contract
//   3. no X on VALID/READY out of reset, no X on a payload while its VALID=1
//   4. RRESP/BRESP = EXOKAY (2'b01) is not legal in AXI4-Lite
//
// err_cnt must read 0 at the end of the test; rd_cnt/wr_cnt let the TB prove
// traffic actually flowed.

module axi_lite_monitor #(
    parameter NAME      = "bus",
    parameter HAS_WRITE = 1          // 0 for the read-only ibus
)(
    input             clk,
    input             rst_n,

    input      [31:0] awaddr,
    input             awvalid,
    input             awready,
    input      [31:0] wdata,
    input      [3:0]  wstrb,
    input             wvalid,
    input             wready,
    input      [1:0]  bresp,
    input             bvalid,
    input             bready,
    input      [31:0] araddr,
    input             arvalid,
    input             arready,
    input      [31:0] rdata,
    input      [1:0]  rresp,
    input             rvalid,
    input             rready,

    output reg [15:0] err_cnt,
    output reg [31:0] rd_cnt,
    output reg [31:0] wr_cnt
);

task err;
    input [255:0] msg;
    begin
        $display("AXI-MON(%0s) FAIL @%0t: %0s", NAME, $time, msg);
        err_cnt = err_cnt + 1;
    end
endtask

wire ar_hs = arvalid && arready;
wire r_hs  = rvalid  && rready;
wire aw_hs = awvalid && awready;
wire w_hs  = wvalid  && wready;
wire b_hs  = bvalid  && bready;

// previous-cycle snapshots for the stability rules
reg        p_arvalid, p_arready, p_rvalid, p_rready;
reg        p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
reg [31:0] p_araddr, p_awaddr, p_wdata, p_rdata;
reg [3:0]  p_wstrb;
reg [1:0]  p_rresp, p_bresp;

// outstanding-transaction model (1 per port, per the CPU contract)
reg rd_out, aw_pend, w_pend;
reg armed;   // skip the cycle right after reset (snapshots not valid yet)

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        err_cnt <= 0; rd_cnt <= 0; wr_cnt <= 0;
        rd_out  <= 0; aw_pend <= 0; w_pend <= 0;
        armed   <= 0;
    end else begin
        armed <= 1;

        // 1. stability while stalled (compare against last cycle's snapshot)
        if (armed) begin
            if (p_arvalid && !p_arready) begin
                if (!arvalid)                err("ARVALID dropped before ARREADY");
                else if (araddr !== p_araddr) err("ARADDR changed while stalled");
            end
            if (p_rvalid && !p_rready) begin
                if (!rvalid)                 err("RVALID dropped before RREADY");
                else if (rdata !== p_rdata || rresp !== p_rresp)
                                             err("R payload changed while stalled");
            end
            if (HAS_WRITE) begin
                if (p_awvalid && !p_awready) begin
                    if (!awvalid)                 err("AWVALID dropped before AWREADY");
                    else if (awaddr !== p_awaddr) err("AWADDR changed while stalled");
                end
                if (p_wvalid && !p_wready) begin
                    if (!wvalid)                  err("WVALID dropped before WREADY");
                    else if (wdata !== p_wdata || wstrb !== p_wstrb)
                                                  err("W payload changed while stalled");
                end
                if (p_bvalid && !p_bready) begin
                    if (!bvalid)                  err("BVALID dropped before BREADY");
                    else if (bresp !== p_bresp)   err("BRESP changed while stalled");
                end
            end
        end

        // 2. ordering / outstanding discipline
        if (armed) begin
            if (ar_hs && rd_out && !r_hs) err("2nd AR while read outstanding");
            if (r_hs && !rd_out)          err("R beat with no read outstanding");
            if (HAS_WRITE) begin
                if (aw_hs && aw_pend && !b_hs) err("second AW before write response");
                if (w_hs  && w_pend  && !b_hs) err("second W before write response");
                if (b_hs && !(aw_pend && w_pend))
                                               err("B beat before AW+W both accepted");
            end
        end
        rd_out <= ar_hs ? 1'b1 : (r_hs ? 1'b0 : rd_out);
        if (r_hs) rd_cnt <= rd_cnt + 1;
        if (HAS_WRITE) begin
            aw_pend <= aw_hs ? 1'b1 : (b_hs ? 1'b0 : aw_pend);
            w_pend  <= w_hs  ? 1'b1 : (b_hs ? 1'b0 : w_pend);
            if (b_hs) wr_cnt <= wr_cnt + 1;
        end

        // 3. X hygiene (armed: DUT outputs are only defined after reset)
        if (armed) begin
            if (arvalid === 1'bx || arready === 1'bx ||
                rvalid  === 1'bx || rready  === 1'bx) err("X on AR/R valid/ready");
            if (arvalid === 1'b1 && (^araddr === 1'bx)) err("X on ARADDR while valid");
            if (rvalid  === 1'b1 && (^rresp  === 1'bx)) err("X on RRESP while valid");
            if (HAS_WRITE) begin
                if (awvalid === 1'bx || awready === 1'bx || wvalid === 1'bx ||
                    wready  === 1'bx || bvalid  === 1'bx || bready === 1'bx)
                                                        err("X on AW/W/B valid/ready");
                if (awvalid === 1'b1 && (^awaddr === 1'bx)) err("X on AWADDR while valid");
                if (wvalid  === 1'b1 && ((^wdata === 1'bx) || (^wstrb === 1'bx)))
                                                        err("X on W payload while valid");
                if (bvalid  === 1'b1 && (^bresp  === 1'bx)) err("X on BRESP while valid");
            end

            // 4. EXOKAY is not a legal AXI4-Lite response
            if (r_hs && rresp === 2'b01) err("EXOKAY on R in AXI4-Lite");
            if (HAS_WRITE && b_hs && bresp === 2'b01) err("EXOKAY on B in AXI4-Lite");
        end

        // snapshots for next cycle
        p_arvalid <= arvalid; p_arready <= arready; p_araddr <= araddr;
        p_rvalid  <= rvalid;  p_rready  <= rready;
        p_rdata   <= rdata;   p_rresp   <= rresp;
        p_awvalid <= awvalid; p_awready <= awready; p_awaddr <= awaddr;
        p_wvalid  <= wvalid;  p_wready  <= wready;
        p_wdata   <= wdata;   p_wstrb   <= wstrb;
        p_bvalid  <= bvalid;  p_bready  <= bready;  p_bresp <= bresp;
    end
end

endmodule
