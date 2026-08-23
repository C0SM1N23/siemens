// Passive AXI4-Lite protocol monitor, testbench only.
//
// One instance watches one bus and flags violations as they happen, so protocol
// legality is a checked property of every run, not trusted by inspection.
//
// Checks (AXI4-Lite handshake rules + this CPU's contract):
// - stability: VALID high with READY low -> VALID stays high and the payload
//   holds until the handshake (all 5 channels)
// - ordering: R only with a read outstanding, B only after AW+W both accepted;
//   a second AR/AW/W before the response breaks "max 1 outstanding per port"
// - X hygiene: no X on VALID/READY out of reset, no X on a payload under VALID
// - responses: EXOKAY (2'b01) is not legal in AXI4-Lite
//
// Results: err_cnt_o must read 0 at the end; rd_cnt_o/wr_cnt_o let the TB prove
// traffic actually flowed (a silent bus would otherwise look like a pass).

`timescale 1ns/1ps

module axi_lite_monitor #(
    parameter NAME      = "bus",
    parameter HAS_WRITE = 1          // 0 for the read-only ibus
)(
    input             clk_i,
    input             rst_n_i,

    input      [31:0] awaddr_i,
    input             awvalid_i,
    input             awready_i,
    input      [31:0] wdata_i,
    input      [3:0]  wstrb_i,
    input             wvalid_i,
    input             wready_i,
    input      [1:0]  bresp_i,
    input             bvalid_i,
    input             bready_i,
    input      [31:0] araddr_i,
    input             arvalid_i,
    input             arready_i,
    input      [31:0] rdata_i,
    input      [1:0]  rresp_i,
    input             rvalid_i,
    input             rready_i,

    output reg [15:0] err_cnt_o,
    output reg [31:0] rd_cnt_o,
    output reg [31:0] wr_cnt_o
);

task err;
    input [255:0] msg;
    begin
        $display("AXI-MON(%0s) FAIL @%0t: %0s", NAME, $time, msg);
        err_cnt_o = err_cnt_o + 1;
    end
endtask

wire ar_hs = arvalid_i && arready_i;
wire r_hs  = rvalid_i  && rready_i;
wire aw_hs = awvalid_i && awready_i;
wire w_hs  = wvalid_i  && wready_i;
wire b_hs  = bvalid_i  && bready_i;

// previous-cycle snapshots for the stability rules
reg        p_arvalid, p_arready, p_rvalid, p_rready;
reg        p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
reg [31:0] p_araddr, p_awaddr, p_wdata, p_rdata;
reg [3:0]  p_wstrb;
reg [1:0]  p_rresp, p_bresp;

// outstanding-transaction model (1 per port, per the CPU contract)
reg rd_out, aw_pend, w_pend;
reg armed;   // skip the cycle right after reset (snapshots not valid yet)

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        // err_cnt_o is blocking everywhere (the err task increments it
        // blocking); one style per signal keeps Verilator happy too
        err_cnt_o = 0;
        rd_cnt_o <= 0; wr_cnt_o <= 0;
        rd_out  <= 0; aw_pend <= 0; w_pend <= 0;
        armed   <= 0;
    end else begin
        armed <= 1;

        // 1. stability while stalled (compare against last cycle's snapshot)
        if (armed) begin
            if (p_arvalid && !p_arready) begin
                if (!arvalid_i)                err("ARVALID dropped before ARREADY");
                else if (araddr_i !== p_araddr) err("ARADDR changed while stalled");
            end
            if (p_rvalid && !p_rready) begin
                if (!rvalid_i)                 err("RVALID dropped before RREADY");
                else if (rdata_i !== p_rdata || rresp_i !== p_rresp)
                                             err("R payload changed while stalled");
            end
            if (HAS_WRITE) begin
                if (p_awvalid && !p_awready) begin
                    if (!awvalid_i)                 err("AWVALID dropped before AWREADY");
                    else if (awaddr_i !== p_awaddr) err("AWADDR changed while stalled");
                end
                if (p_wvalid && !p_wready) begin
                    if (!wvalid_i)                  err("WVALID dropped before WREADY");
                    else if (wdata_i !== p_wdata || wstrb_i !== p_wstrb)
                                                  err("W payload changed while stalled");
                end
                if (p_bvalid && !p_bready) begin
                    if (!bvalid_i)                  err("BVALID dropped before BREADY");
                    else if (bresp_i !== p_bresp)   err("BRESP changed while stalled");
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
        if (r_hs) rd_cnt_o <= rd_cnt_o + 1;
        if (HAS_WRITE) begin
            aw_pend <= aw_hs ? 1'b1 : (b_hs ? 1'b0 : aw_pend);
            w_pend  <= w_hs  ? 1'b1 : (b_hs ? 1'b0 : w_pend);
            if (b_hs) wr_cnt_o <= wr_cnt_o + 1;
        end

        // 3. X hygiene (armed: DUT outputs are only defined after reset)
        if (armed) begin
            if (arvalid_i === 1'bx || arready_i === 1'bx ||
                rvalid_i  === 1'bx || rready_i  === 1'bx) err("X on AR/R valid/ready");
            if (arvalid_i === 1'b1 && (^araddr_i === 1'bx)) err("X on ARADDR while valid");
            if (rvalid_i  === 1'b1 && (^rresp_i  === 1'bx)) err("X on RRESP while valid");
            if (HAS_WRITE) begin
                if (awvalid_i === 1'bx || awready_i === 1'bx || wvalid_i === 1'bx ||
                    wready_i  === 1'bx || bvalid_i  === 1'bx || bready_i === 1'bx)
                                                        err("X on AW/W/B valid/ready");
                if (awvalid_i === 1'b1 && (^awaddr_i === 1'bx)) err("X on AWADDR while valid");
                if (wvalid_i  === 1'b1 && ((^wdata_i === 1'bx) || (^wstrb_i === 1'bx)))
                                                        err("X on W payload while valid");
                if (bvalid_i  === 1'b1 && (^bresp_i  === 1'bx)) err("X on BRESP while valid");
            end

            // 4. EXOKAY is not a legal AXI4-Lite response
            if (r_hs && rresp_i === 2'b01) err("EXOKAY on R in AXI4-Lite");
            if (HAS_WRITE && b_hs && bresp_i === 2'b01) err("EXOKAY on B in AXI4-Lite");
        end

        // snapshots for next cycle
        p_arvalid <= arvalid_i; p_arready <= arready_i; p_araddr <= araddr_i;
        p_rvalid  <= rvalid_i;  p_rready  <= rready_i;
        p_rdata   <= rdata_i;   p_rresp   <= rresp_i;
        p_awvalid <= awvalid_i; p_awready <= awready_i; p_awaddr <= awaddr_i;
        p_wvalid  <= wvalid_i;  p_wready  <= wready_i;
        p_wdata   <= wdata_i;   p_wstrb   <= wstrb_i;
        p_bvalid  <= bvalid_i;  p_bready  <= bready_i;  p_bresp <= bresp_i;
    end
end

endmodule
