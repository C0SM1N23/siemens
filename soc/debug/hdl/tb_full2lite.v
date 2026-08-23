// Block bench for axi_full2lite, the AXI4-Full to AXI4-Lite burst bridge.
//
// The bridge is the one piece of new RTL the whole SoC data path runs through,
// and a fault in it shows up at system level as "the DMA copied the wrong
// bytes" - the hardest kind of bug to localise from a system waveform. So it
// gets its own bench, driven directly on the full side against a real
// axi_lite_ram on the lite side.
//
// What is checked, in order:
//   1  write burst of 8 beats, then read it back - the DMA's actual traffic
//   2  single-beat burst (LEN=0) - the boundary where "first beat" and "last
//      beat" are the same beat
//   3  odd length (LEN=2) with per-beat byte strobes
//   4  FIXED burst - every beat to the same address, last writer wins
//   5  WRAP burst - unsupported, must come back SLVERR and must NOT touch
//      memory
//   6  narrow transfer (SIZE=2 bytes) - unsupported, same treatment
//   7  RLAST placement: exactly one, on the final beat
//
// The read path is checked against what the write path put there, so a bridge
// that consistently mistranslated addresses in both directions could in
// principle hide - which is why test 1 also verifies the data through a second
// path, by reading the memory array directly.

`timescale 1ns/1ps

module tb_full2lite;

integer errors;
`include "tb_check.vh"

localparam [1:0] BURST_FIXED = 2'b00;
localparam [1:0] BURST_INCR  = 2'b01;
localparam [1:0] BURST_WRAP  = 2'b10;
localparam [2:0] SIZE_16     = 3'b001;
localparam [2:0] SIZE_32     = 3'b010;
localparam [1:0] RESP_OKAY   = 2'b00;
localparam [1:0] RESP_SLVERR = 2'b10;

wire clk, rst_n;
ck_rst_tb #(.CK_SEMIPERIOD(5)) ck_rst (.clk_o(clk), .rst_n_o(rst_n));

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

// lite side, into the RAM
wire [31:0] l_awaddr, l_wdata, l_araddr, l_rdata;
wire [2:0]  l_awprot, l_arprot;
wire [3:0]  l_wstrb;
wire [1:0]  l_bresp, l_rresp;
wire        l_awvalid, l_awready, l_wvalid, l_wready;
wire        l_bvalid, l_bready, l_arvalid, l_arready, l_rvalid, l_rready;

axi_full2lite dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .s_awaddr_i(f_awaddr), .s_awlen_i(f_awlen), .s_awsize_i(f_awsize),
    .s_awburst_i(f_awburst), .s_awvalid_i(f_awvalid), .s_awready_o(f_awready),
    .s_wdata_i(f_wdata), .s_wstrb_i(f_wstrb), .s_wlast_i(f_wlast),
    .s_wvalid_i(f_wvalid), .s_wready_o(f_wready),
    .s_bresp_o(f_bresp), .s_bvalid_o(f_bvalid), .s_bready_i(f_bready),
    .s_araddr_i(f_araddr), .s_arlen_i(f_arlen), .s_arsize_i(f_arsize),
    .s_arburst_i(f_arburst), .s_arvalid_i(f_arvalid), .s_arready_o(f_arready),
    .s_rdata_o(f_rdata), .s_rresp_o(f_rresp), .s_rlast_o(f_rlast),
    .s_rvalid_o(f_rvalid), .s_rready_i(f_rready),

    .m_awaddr_o(l_awaddr), .m_awprot_o(l_awprot), .m_awvalid_o(l_awvalid),
    .m_awready_i(l_awready),
    .m_wdata_o(l_wdata), .m_wstrb_o(l_wstrb), .m_wvalid_o(l_wvalid),
    .m_wready_i(l_wready),
    .m_bresp_i(l_bresp), .m_bvalid_i(l_bvalid), .m_bready_o(l_bready),
    .m_araddr_o(l_araddr), .m_arprot_o(l_arprot), .m_arvalid_o(l_arvalid),
    .m_arready_i(l_arready),
    .m_rdata_i(l_rdata), .m_rresp_i(l_rresp), .m_rvalid_i(l_rvalid),
    .m_rready_o(l_rready)
);

axi_lite_ram #(.WORDS(256)) ram (
    .clk_i(clk), .rst_n_i(rst_n),
    .s_awaddr_i(l_awaddr), .s_awprot_i(l_awprot), .s_awvalid_i(l_awvalid),
    .s_awready_o(l_awready),
    .s_wdata_i(l_wdata), .s_wstrb_i(l_wstrb), .s_wvalid_i(l_wvalid),
    .s_wready_o(l_wready),
    .s_bresp_o(l_bresp), .s_bvalid_o(l_bvalid), .s_bready_i(l_bready),
    .s_araddr_i(l_araddr), .s_arprot_i(l_arprot), .s_arvalid_i(l_arvalid),
    .s_arready_o(l_arready),
    .s_rdata_o(l_rdata), .s_rresp_o(l_rresp), .s_rvalid_o(l_rvalid),
    .s_rready_i(l_rready)
);

// ---------------------------------------------------------------------------
// full-side master tasks
// ---------------------------------------------------------------------------
reg [31:0] wr_seed;         // pattern the write task lays down
reg [1:0]  last_bresp;
reg [31:0] rd_word [0:15];  // what the read task collected
reg [1:0]  last_rresp;
integer    rlast_count;
integer    rlast_on_last;

task do_write;
    input [31:0] addr;
    input [7:0]  len;       // AXI encoding: beats - 1
    input [2:0]  size;
    input [1:0]  burst;
    input [31:0] seed;
    input [3:0]  strb;
    integer b;
    begin
        @(negedge clk);
        f_awaddr  = addr;
        f_awlen   = len;
        f_awsize  = size;
        f_awburst = burst;
        f_awvalid = 1'b1;
        @(posedge clk);
        while (!f_awready) @(posedge clk);
        @(negedge clk);
        f_awvalid = 1'b0;

        for (b = 0; b <= len; b = b + 1) begin
            f_wdata  = seed + b;
            f_wstrb  = strb;
            f_wlast  = (b == len);
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
    input [2:0]  size;
    input [1:0]  burst;
    integer b;
    begin
        rlast_count   = 0;
        rlast_on_last = 0;
        @(negedge clk);
        f_araddr  = addr;
        f_arlen   = len;
        f_arsize  = size;
        f_arburst = burst;
        f_arvalid = 1'b1;
        @(posedge clk);
        while (!f_arready) @(posedge clk);
        @(negedge clk);
        f_arvalid = 1'b0;

        for (b = 0; b <= len; b = b + 1) begin
            f_rready = 1'b1;
            @(posedge clk);
            while (!f_rvalid) @(posedge clk);
            rd_word[b] = f_rdata;
            last_rresp = f_rresp;
            if (f_rlast) begin
                rlast_count = rlast_count + 1;
                if (b == len) rlast_on_last = 1;
            end
            @(negedge clk);
            f_rready = 1'b0;
        end
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
integer i;

initial begin
    errors    = 0;
    f_awaddr  = 0; f_awlen = 0; f_awsize = SIZE_32; f_awburst = BURST_INCR;
    f_awvalid = 0;
    f_wdata   = 0; f_wstrb = 4'hF; f_wlast = 0; f_wvalid = 0; f_bready = 0;
    f_araddr  = 0; f_arlen = 0; f_arsize = SIZE_32; f_arburst = BURST_INCR;
    f_arvalid = 0; f_rready = 0;
    wr_seed   = 0;

    @(posedge rst_n);
    repeat (4) @(posedge clk);

    // -- 1: the DMA's own traffic shape, 8-beat INCR write then read ---------
    $display("\n-- 1: 8-beat INCR write, then read back --");
    do_write(32'h0000_0040, 8'd7, SIZE_32, BURST_INCR, 32'hA000_0000, 4'hF);
    check(RESP_OKAY, {30'd0, last_bresp}, "8-beat write burst answers OKAY");

    do_read(32'h0000_0040, 8'd7, SIZE_32, BURST_INCR);
    for (i = 0; i < 8; i = i + 1)
        check(32'hA000_0000 + i, rd_word[i], "8-beat read returns the written word");
    check(RESP_OKAY, {30'd0, last_rresp}, "8-beat read answers OKAY");
    check(32'd1, rlast_count,   "exactly one RLAST in the burst");
    check(32'd1, rlast_on_last, "RLAST lands on the final beat");

    // the burst started at byte 0x40 = word 16: check the array itself, so a
    // symmetric address error in both directions cannot pass unnoticed
    for (i = 0; i < 8; i = i + 1)
        check(32'hA000_0000 + i, ram.mem[16 + i], "the word landed at the right address");

    // -- 2: single beat, where first and last beat coincide ------------------
    $display("\n-- 2: single-beat burst (LEN=0) --");
    do_write(32'h0000_0080, 8'd0, SIZE_32, BURST_INCR, 32'hB0000000, 4'hF);
    check(RESP_OKAY, {30'd0, last_bresp}, "single-beat write answers OKAY");
    do_read(32'h0000_0080, 8'd0, SIZE_32, BURST_INCR);
    check(32'hB0000000, rd_word[0], "single-beat read returns the word");
    check(32'd1, rlast_count,   "single beat carries exactly one RLAST");
    check(32'd1, rlast_on_last, "the single beat is the last beat");

    // -- 3: odd length with a partial byte strobe ----------------------------
    $display("\n-- 3: LEN=2 with a half-word strobe --");
    for (i = 0; i < 3; i = i + 1) ram.mem[48 + i] = 32'hFFFF_FFFF;
    do_write(32'h0000_00C0, 8'd2, SIZE_32, BURST_INCR, 32'h1234_5678, 4'h3);
    check(RESP_OKAY, {30'd0, last_bresp}, "strobed write answers OKAY");
    check(32'hFFFF_5678, ram.mem[48], "WSTRB kept the upper half untouched");
    check(32'hFFFF_5679, ram.mem[49], "second beat also honoured the strobe");
    check(32'hFFFF_567A, ram.mem[50], "third beat also honoured the strobe");

    // -- 4: FIXED burst, every beat to the same address ----------------------
    $display("\n-- 4: FIXED burst --");
    do_write(32'h0000_0100, 8'd3, SIZE_32, BURST_FIXED, 32'hC000_0000, 4'hF);
    check(RESP_OKAY, {30'd0, last_bresp}, "FIXED write answers OKAY");
    check(32'hC000_0003, ram.mem[64], "FIXED wrote every beat to one address");
    check(32'h0000_0000, ram.mem[65], "FIXED did not advance to the next word");

    // -- 5: WRAP is outside the supported subset -----------------------------
    $display("\n-- 5: WRAP burst is rejected, not mistranslated --");
    ram.mem[80] = 32'hDEAD_BEEF;
    do_write(32'h0000_0140, 8'd3, SIZE_32, BURST_WRAP, 32'hE000_0000, 4'hF);
    check(RESP_SLVERR, {30'd0, last_bresp}, "WRAP write answers SLVERR");
    check(32'hDEAD_BEEF, ram.mem[80], "WRAP write left memory untouched");

    do_read(32'h0000_0140, 8'd3, SIZE_32, BURST_WRAP);
    check(RESP_SLVERR, {30'd0, last_rresp}, "WRAP read answers SLVERR");
    check(32'd1, rlast_count,   "a rejected read still delivers one RLAST");
    check(32'd1, rlast_on_last, "the rejected read delivers all its beats");

    // -- 6: narrow transfer is outside the supported subset ------------------
    $display("\n-- 6: narrow (16-bit) transfer is rejected --");
    ram.mem[96] = 32'hCAFE_F00D;
    do_write(32'h0000_0180, 8'd1, SIZE_16, BURST_INCR, 32'hF000_0000, 4'hF);
    check(RESP_SLVERR, {30'd0, last_bresp}, "narrow write answers SLVERR");
    check(32'hCAFE_F00D, ram.mem[96], "narrow write left memory untouched");

    // -- 7: back-to-back bursts, no state left behind ------------------------
    $display("\n-- 7: back-to-back bursts after a rejected one --");
    do_write(32'h0000_01C0, 8'd7, SIZE_32, BURST_INCR, 32'h5A5A_0000, 4'hF);
    check(RESP_OKAY, {30'd0, last_bresp}, "the bridge recovered from SLVERR");
    do_read(32'h0000_01C0, 8'd7, SIZE_32, BURST_INCR);
    for (i = 0; i < 8; i = i + 1)
        check(32'h5A5A_0000 + i, rd_word[i], "recovered burst reads back clean");

    repeat (10) @(posedge clk);
    $display("\n=====================================================");
    if (errors == 0)
        $display("== FULL2LITE BRIDGE TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== FULL2LITE BRIDGE TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("=====================================================\n");
    $finish;
end

// a bench that hangs must say so rather than run to the simulator's limit
initial begin
    #200000;
    $display("FAIL: tb_full2lite timed out");
    $display("== FULL2LITE BRIDGE TESTBENCH: TIMEOUT ==");
    $finish;
end

endmodule
