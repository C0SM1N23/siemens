// The burst bridge under a slave error on one beat inside a burst.
//
// tb_full2lite covers the requests the bridge itself refuses - a wrapping
// burst, a narrow transfer - and both answer SLVERR because the bridge decided
// so before touching the lite side. Nothing there ever gets an error back
// FROM the lite side, and that is the case this bench exists for.
//
// A full burst becomes one lite transaction per beat, so it collects one
// response per beat, but the master gets a single B for the whole burst. The
// bridge therefore has to fold them: the burst's response is the worst response
// any of its beats returned. Without that fold the burst answers with whatever
// the last beat said, and a failed write in the middle of a transfer reports
// OKAY - the DMA marks the segment done, software believes the data arrived,
// and nothing anywhere says otherwise.
//
// The fold is only observable when the failing beat is NOT the last one, which
// is why the error is injected at the first beat, in the middle, and at the end
// separately. Only the first two can distinguish a real fold from no fold at
// all.
//
// Reads are the opposite case and are checked for the opposite property: AXI4
// carries RRESP per beat, so a read error must appear on its own beat and must
// NOT contaminate the others.
//
// What is checked, in order:
//   1  error on the first beat of an 8-beat write  -> burst answers SLVERR
//   2  error on a middle beat                       -> burst answers SLVERR
//   3  error on the last beat                       -> burst answers SLVERR
//   4  no error                                     -> burst answers OKAY
//   5  two failing beats in one burst               -> still one SLVERR
//   6  every beat of the burst is still consumed when a beat fails
//   7  the bridge is not left stuck: a clean burst after a failed one is OKAY
//   8  read error is per beat, does not spread, and RLAST still lands last
//
// The lite-side slave is the design's own AXI4-Lite register front end, with
// its "this offset is writable / readable" input driven from a beat counter.
// That way the error responses are produced by real RTL taking a real decision,
// not by a bench faking a response code.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

module soc_tb_full2lite_err;

integer errors;
`include "tb_check.vh"

localparam [1:0] BURST_INCR  = 2'b01;
localparam [2:0] SIZE_32     = 3'b010;
localparam [1:0] RESP_OKAY   = 2'b00;
localparam [1:0] RESP_SLVERR = 2'b10;

localparam integer NO_ERR = 99;   // an index no burst in this bench reaches

wire clk, rst_n;
ck_rst_tb #(
    .CK_SEMIPERIOD(5)
) ck_rst (
    .clk_o(clk),
    .rst_n_o(rst_n)
);

// ---------------------------------------------------------------------------
// full side, driven by this bench
// ---------------------------------------------------------------------------
reg  [31:0] f_awaddr;
reg  [7:0]  f_awlen;
reg  [2:0]  f_awsize;
reg  [1:0]  f_awburst;
reg         f_awvalid;
wire        f_awready;
reg  [31:0] f_wdata;
reg  [3:0]  f_wstrb;
reg         f_wlast, f_wvalid;
wire        f_wready;
wire [1:0]  f_bresp;
wire        f_bvalid;
reg         f_bready;
reg  [31:0] f_araddr;
reg  [7:0]  f_arlen;
reg  [2:0]  f_arsize;
reg  [1:0]  f_arburst;
reg         f_arvalid;
wire        f_arready;
wire [31:0] f_rdata;
wire [1:0]  f_rresp;
wire        f_rlast, f_rvalid;
reg         f_rready;

// lite side
wire [31:0] l_awaddr, l_wdata, l_araddr, l_rdata;
wire [2:0]  l_awprot, l_arprot;
wire [3:0]  l_wstrb;
wire [1:0]  l_bresp, l_rresp;
wire        l_awvalid, l_awready, l_wvalid, l_wready;
wire        l_bvalid, l_bready, l_arvalid, l_arready, l_rvalid, l_rready;

soc_axi_full2lite dut (
    .clk_i(clk),
    .rst_n_i(rst_n),
    .s_awaddr_i(f_awaddr),
    .s_awlen_i(f_awlen),
    .s_awsize_i(f_awsize),
    .s_awburst_i(f_awburst),
    .s_awvalid_i(f_awvalid),
    .s_awready_o(f_awready),
    .s_wdata_i(f_wdata),
    .s_wstrb_i(f_wstrb),
    .s_wlast_i(f_wlast),
    .s_wvalid_i(f_wvalid),
    .s_wready_o(f_wready),
    .s_bresp_o(f_bresp),
    .s_bvalid_o(f_bvalid),
    .s_bready_i(f_bready),
    .s_araddr_i(f_araddr),
    .s_arlen_i(f_arlen),
    .s_arsize_i(f_arsize),
    .s_arburst_i(f_arburst),
    .s_arvalid_i(f_arvalid),
    .s_arready_o(f_arready),
    .s_rdata_o(f_rdata),
    .s_rresp_o(f_rresp),
    .s_rlast_o(f_rlast),
    .s_rvalid_o(f_rvalid),
    .s_rready_i(f_rready),

    .m_awaddr_o(l_awaddr),
    .m_awprot_o(l_awprot),
    .m_awvalid_o(l_awvalid),
    .m_awready_i(l_awready),
    .m_wdata_o(l_wdata),
    .m_wstrb_o(l_wstrb),
    .m_wvalid_o(l_wvalid),
    .m_wready_i(l_wready),
    .m_bresp_i(l_bresp),
    .m_bvalid_i(l_bvalid),
    .m_bready_o(l_bready),
    .m_araddr_o(l_araddr),
    .m_arprot_o(l_arprot),
    .m_arvalid_o(l_arvalid),
    .m_arready_i(l_arready),
    .m_rdata_i(l_rdata),
    .m_rresp_i(l_rresp),
    .m_rvalid_i(l_rvalid),
    .m_rready_o(l_rready)
);

// ---------------------------------------------------------------------------
// lite-side slave with an injectable error
//
// The real register front end decides the response from wr_ok_i / rd_ok_i, so
// pointing those at a beat counter makes it answer SLVERR on a chosen beat and
// OKAY on every other, through the same path a genuine unmapped access takes.
// ---------------------------------------------------------------------------
integer err_wbeat, err_wbeat2, err_rbeat;
integer wbeat_cnt, rbeat_cnt;
integer wbeats_seen;

wire [5:0]  s_wr_addr, s_rd_addr;
wire [31:0] s_wr_data;
wire [3:0]  s_wr_strb;
wire        s_wr_en;

wire s_wr_ok = (wbeat_cnt != err_wbeat) && (wbeat_cnt != err_wbeat2);
wire s_rd_ok = (rbeat_cnt != err_rbeat);

// read data is a function of the offset, so a beat that returns an error can
// still be told apart from a beat that returned the wrong word
wire [31:0] s_rd_data = 32'hD0D0_0000 | {26'b0, s_rd_addr};

axi_lite_slave slv (
    .clk_i(clk),
    .rst_n_i(rst_n),
    .s_axi_awaddr_i(l_awaddr),
    .s_axi_awvalid_i(l_awvalid),
    .s_axi_awready_o(l_awready),
    .s_axi_wdata_i(l_wdata),
    .s_axi_wstrb_i(l_wstrb),
    .s_axi_wvalid_i(l_wvalid),
    .s_axi_wready_o(l_wready),
    .s_axi_bresp_o(l_bresp),
    .s_axi_bvalid_o(l_bvalid),
    .s_axi_bready_i(l_bready),
    .s_axi_araddr_i(l_araddr),
    .s_axi_arvalid_i(l_arvalid),
    .s_axi_arready_o(l_arready),
    .s_axi_rdata_o(l_rdata),
    .s_axi_rresp_o(l_rresp),
    .s_axi_rvalid_o(l_rvalid),
    .s_axi_rready_i(l_rready),
    .wr_en_o(s_wr_en),
    .wr_addr_o(s_wr_addr),
    .wr_data_o(s_wr_data),
    .wr_strb_o(s_wr_strb),
    .wr_ok_i(s_wr_ok),
    .rd_addr_o(s_rd_addr),
    .rd_data_i(s_rd_data),
    .rd_ok_i(s_rd_ok)
);

// beat counters: one lite write transaction and one lite read transaction per
// burst beat, so the counter index is the beat index
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        wbeat_cnt   <= 0;
        wbeats_seen <= 0;
    end else if (s_wr_en) begin
        wbeat_cnt   <= wbeat_cnt + 1;
        wbeats_seen <= wbeats_seen + 1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        rbeat_cnt <= 0;
    else if (l_arvalid && l_arready)
        rbeat_cnt <= rbeat_cnt + 1;
end

// ---------------------------------------------------------------------------
// full-side master
// ---------------------------------------------------------------------------
reg [1:0]  last_bresp;
reg [1:0]  beat_rresp [0:15];
integer    rlast_count, rlast_on_last, rbeats_taken;

task arm_write_err;
    input integer first;
    input integer second;
    begin
        err_wbeat   = first;
        err_wbeat2  = second;
        wbeat_cnt   = 0;
        wbeats_seen = 0;
    end
endtask

task arm_read_err;
    input integer which;
    begin
        err_rbeat = which;
        rbeat_cnt = 0;
    end
endtask

task do_write;
    input [31:0] addr;
    input [7:0]  len;      // AXI encoding: beats - 1
    integer b;
    begin
        @(negedge clk);
        f_awaddr  = addr;
        f_awlen   = len;
        f_awsize  = SIZE_32;
        f_awburst = BURST_INCR;
        f_awvalid = 1'b1;
        @(posedge clk);
        while (!f_awready) @(posedge clk);
        @(negedge clk);
        f_awvalid = 1'b0;

        for (b = 0; b <= len; b = b + 1) begin
            f_wdata  = 32'hA5A5_0000 + b;
            f_wstrb  = 4'hF;
            f_wlast  = (b == {24'd0, len});
            f_wvalid = 1'b1;
            @(posedge clk);
            while (!f_wready) @(posedge clk);
            @(negedge clk);
            f_wvalid = 1'b0;
            f_wlast  = 1'b0;
        end

        f_bready = 1'b1;
        @(posedge clk);
        while (!f_bvalid) @(posedge clk);
        last_bresp = f_bresp;
        @(negedge clk);
        f_bready = 1'b0;
    end
endtask

task do_read;
    input [31:0] addr;
    input [7:0]  len;
    integer b;
    begin
        rlast_count   = 0;
        rlast_on_last = 0;
        rbeats_taken  = 0;
        @(negedge clk);
        f_araddr  = addr;
        f_arlen   = len;
        f_arsize  = SIZE_32;
        f_arburst = BURST_INCR;
        f_arvalid = 1'b1;
        @(posedge clk);
        while (!f_arready) @(posedge clk);
        @(negedge clk);
        f_arvalid = 1'b0;

        for (b = 0; b <= len; b = b + 1) begin
            f_rready = 1'b1;
            @(posedge clk);
            while (!f_rvalid) @(posedge clk);
            beat_rresp[b] = f_rresp;
            rbeats_taken  = rbeats_taken + 1;
            if (f_rlast) begin
                rlast_count = rlast_count + 1;
                if (b == {24'd0, len}) rlast_on_last = 1;
            end
            @(negedge clk);
            f_rready = 1'b0;
        end
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
integer i, bad;

initial begin
    errors     = 0;
    f_awaddr   = 0; f_awlen = 0; f_awsize = 0; f_awburst = 0; f_awvalid = 0;
    f_wdata    = 0; f_wstrb = 0; f_wlast = 0; f_wvalid = 0; f_bready = 0;
    f_araddr   = 0; f_arlen = 0; f_arsize = 0; f_arburst = 0; f_arvalid = 0;
    f_rready   = 0;
    err_wbeat  = NO_ERR; err_wbeat2 = NO_ERR; err_rbeat = NO_ERR;
    wbeat_cnt  = 0; rbeat_cnt = 0; wbeats_seen = 0;
    last_bresp = RESP_OKAY;
    for (i = 0; i < 16; i = i + 1) beat_rresp[i] = RESP_OKAY;

    $display("=====================================================");
    $display("== BURST BRIDGE: SLAVE ERROR INSIDE A BURST ==");
    $display("=====================================================");

    wait (rst_n === 1'b1);
    repeat (2) @(posedge clk);

    // =====================================================================
    // 1. the failing beat is the FIRST of eight
    //
    // Seven OKAY responses arrive after it. A bridge that reported the last
    // response instead of the worst one answers OKAY here.
    // =====================================================================
    $display("\n-- 1. error on the first beat of an 8-beat write --");
    arm_write_err(0, NO_ERR);
    do_write(32'h0000_0000, 8'd7);
    check({30'd0, RESP_SLVERR}, {30'd0, last_bresp},
          "first beat failed -> burst answers SLVERR");
    check(32'd8, wbeats_seen[31:0],
          "all eight beats were still issued to the slave");

    // =====================================================================
    // 2. the failing beat is in the MIDDLE
    // =====================================================================
    $display("\n-- 2. error on beat 3 of eight --");
    arm_write_err(3, NO_ERR);
    do_write(32'h0000_0020, 8'd7);
    check({30'd0, RESP_SLVERR}, {30'd0, last_bresp},
          "middle beat failed -> burst answers SLVERR");
    check(32'd8, wbeats_seen[31:0],
          "the burst ran to completion after the failure");

    // =====================================================================
    // 3. the failing beat is the LAST one
    //
    // The one case a bridge with no fold at all still gets right, kept so the
    // three positions are covered rather than assumed.
    // =====================================================================
    $display("\n-- 3. error on the last beat of eight --");
    arm_write_err(7, NO_ERR);
    do_write(32'h0000_0040, 8'd7);
    check({30'd0, RESP_SLVERR}, {30'd0, last_bresp},
          "last beat failed -> burst answers SLVERR");

    // =====================================================================
    // 4. control: nothing fails, so nothing may be reported
    //
    // Without this an implementation that answered SLVERR unconditionally
    // would pass every check above.
    // =====================================================================
    $display("\n-- 4. no beat fails --");
    arm_write_err(NO_ERR, NO_ERR);
    do_write(32'h0000_0060, 8'd7);
    check({30'd0, RESP_OKAY}, {30'd0, last_bresp},
          "a clean burst answers OKAY");
    check(32'd8, wbeats_seen[31:0], "eight beats issued");

    // =====================================================================
    // 5. two beats fail in the same burst
    // =====================================================================
    $display("\n-- 5. two failing beats in one burst --");
    arm_write_err(1, 5);
    do_write(32'h0000_0080, 8'd7);
    check({30'd0, RESP_SLVERR}, {30'd0, last_bresp},
          "two failures still produce one SLVERR");
    check(32'd8, wbeats_seen[31:0], "eight beats issued");

    // =====================================================================
    // 6. the bridge recovers
    //
    // A burst that failed must not leave the write channel in a state where
    // the next one is refused, or the DMA stalls on the transfer after the one
    // that went wrong rather than on the one that did.
    // =====================================================================
    $display("\n-- 6. a clean burst after a failed one --");
    arm_write_err(2, NO_ERR);
    do_write(32'h0000_00A0, 8'd7);
    check({30'd0, RESP_SLVERR}, {30'd0, last_bresp}, "the failing burst reports it");
    arm_write_err(NO_ERR, NO_ERR);
    do_write(32'h0000_00C0, 8'd7);
    check({30'd0, RESP_OKAY}, {30'd0, last_bresp},
          "the next burst is unaffected");

    // =====================================================================
    // 7. a single-beat burst, where first and last are the same beat
    // =====================================================================
    $display("\n-- 7. single-beat burst that fails --");
    arm_write_err(0, NO_ERR);
    do_write(32'h0000_00E0, 8'd0);
    check({30'd0, RESP_SLVERR}, {30'd0, last_bresp},
          "single-beat burst reports its own failure");
    check(32'd1, wbeats_seen[31:0], "exactly one beat issued");

    // =====================================================================
    // 8. reads carry the response per beat
    //
    // The opposite rule to the write side, and it has to be checked as the
    // opposite: the failing beat reports, and no other beat does.
    // =====================================================================
    $display("\n-- 8. read error stays on its own beat --");
    arm_read_err(3);
    do_read(32'h0000_0000, 8'd7);
    check(32'd8, rbeats_taken[31:0], "all eight read beats were delivered");
    check({30'd0, RESP_SLVERR}, {30'd0, beat_rresp[3]},
          "beat 3 reports SLVERR");
    bad = 0;
    for (i = 0; i < 8; i = i + 1)
        if (i != 3 && beat_rresp[i] !== RESP_OKAY) bad = bad + 1;
    check(32'd0, bad[31:0], "no other beat was contaminated");
    check(32'd1, rlast_count[31:0], "exactly one RLAST in the burst");
    check(32'd1, rlast_on_last[31:0], "RLAST landed on the final beat");

    $display("\n-- 9. a clean read after a failed one --");
    arm_read_err(NO_ERR);
    do_read(32'h0000_0020, 8'd7);
    bad = 0;
    for (i = 0; i < 8; i = i + 1)
        if (beat_rresp[i] !== RESP_OKAY) bad = bad + 1;
    check(32'd0, bad[31:0], "every beat of the clean read is OKAY");

    repeat (4) @(posedge clk);
    $display("\n=====================================================");
    if (errors == 0)
        $display("== BRIDGE ERROR TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== BRIDGE ERROR TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("=====================================================");
    $finish;
end

initial begin
    #200000;
    $display("FAIL: tb_full2lite_err timeout");
    $finish;
end

endmodule
