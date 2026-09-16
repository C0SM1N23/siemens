// The project's AXI4-Lite decoder against an external one, on the same stimulus.
//
// The reference is pulp-platform/axi's axi_lite_demux, configured with
// MaxTrans = 1 - one transaction outstanding per channel, which is the profile
// soc_axi_lite_dec implements. Nothing here requires knowing that module: both
// interconnects get the same sequence, behind the same slaves, and what is
// compared is what came back.
//
// Both sides are driven by one instance each of soc_lite_seq_master, so the
// stimulus is the same by construction rather than by two copies of a bench
// that are meant to agree. Timing is deliberately NOT compared - each side runs
// its own handshakes at its own pace. What is compared is:
//   - the data and response of every transaction, in the order they completed
//   - how many address handshakes each slave saw, so a request that was routed
//     to the wrong place shows up even when the data happens to match
//
// Two differences are structural and are outside what this bench compares:
//   - soc_axi_lite_dec decodes the address itself and answers DECERR for an
//     unmapped one. axi_lite_demux takes the routing decision as an input and
//     has no error responder; upstream puts an axi_err_slv behind a spare port
//     for that. The sequence therefore only uses mapped addresses, and the
//     DECERR behaviour is covered by soc_tb_addr_map instead.
//   - upstream's write response aggregation in the burst splitter turns any
//     error into SLVERR, where this project keeps DECERR > SLVERR > OKAY. That
//     is a response-policy difference, compared separately in soc/README.md
//     rather than here.

`timescale 1ns / 1ps

module soc_tb_pulp_compare;

    localparam integer N = 2;
    localparam integer MAX_REC = 16;
    localparam [31:0] ADDR_A = 32'h0000_0000;
    localparam [31:0] ADDR_B = 32'h0000_1000;
    localparam [31:0] WIN_MASK = 32'hFFFF_F000;

    integer errors = 0;
    `include "tb_check.vh"

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------- ours
    wire [31:0] a_awaddr, a_wdata, a_araddr, a_rdata;
    wire [ 3:0] a_wstrb;
    wire [ 1:0] a_bresp, a_rresp;
    wire a_awvalid, a_awready, a_wvalid, a_wready, a_bvalid, a_bready;
    wire a_arvalid, a_arready, a_rvalid, a_rready, a_done;
    wire [31:0] a_rec_count;
    wire [MAX_REC*2-1:0] a_rec_kind, a_rec_resp;
    wire [MAX_REC*32-1:0] a_rec_data;

    wire [N*32-1:0] a_s_awaddr, a_s_wdata, a_s_araddr, a_s_rdata;
    wire [N*4-1:0] a_s_wstrb;
    wire [N*2-1:0] a_s_bresp, a_s_rresp;
    wire [N-1:0] a_s_awvalid, a_s_awready, a_s_wvalid, a_s_wready;
    wire [N-1:0] a_s_bvalid, a_s_bready, a_s_arvalid, a_s_arready, a_s_rvalid, a_s_rready;

    soc_lite_seq_master #(
        .ADDR_A (ADDR_A),
        .ADDR_B (ADDR_B),
        .MAX_REC(MAX_REC)
    ) seq_a (
        .clk_i      (clk),
        .rst_n_i    (rst_n),
        .start_i    (start),
        .done_o     (a_done),
        .awaddr_o   (a_awaddr),
        .awvalid_o  (a_awvalid),
        .awready_i  (a_awready),
        .wdata_o    (a_wdata),
        .wstrb_o    (a_wstrb),
        .wvalid_o   (a_wvalid),
        .wready_i   (a_wready),
        .bresp_i    (a_bresp),
        .bvalid_i   (a_bvalid),
        .bready_o   (a_bready),
        .araddr_o   (a_araddr),
        .arvalid_o  (a_arvalid),
        .arready_i  (a_arready),
        .rdata_i    (a_rdata),
        .rresp_i    (a_rresp),
        .rvalid_i   (a_rvalid),
        .rready_o   (a_rready),
        .rec_count_o(a_rec_count),
        .rec_kind_o (a_rec_kind),
        .rec_data_o (a_rec_data),
        .rec_resp_o (a_rec_resp)
    );

    soc_axi_lite_dec #(
        .N   (N),
        .BASE({ADDR_B, ADDR_A}),
        .MASK({WIN_MASK, WIN_MASK})
    ) ours (
        .clk_i      (clk),
        .rst_n_i    (rst_n),
        .m_awaddr_i (a_awaddr),
        .m_awprot_i (3'b000),
        .m_awvalid_i(a_awvalid),
        .m_awready_o(a_awready),
        .m_wdata_i  (a_wdata),
        .m_wstrb_i  (a_wstrb),
        .m_wvalid_i (a_wvalid),
        .m_wready_o (a_wready),
        .m_bresp_o  (a_bresp),
        .m_bvalid_o (a_bvalid),
        .m_bready_i (a_bready),
        .m_araddr_i (a_araddr),
        .m_arprot_i (3'b000),
        .m_arvalid_i(a_arvalid),
        .m_arready_o(a_arready),
        .m_rdata_o  (a_rdata),
        .m_rresp_o  (a_rresp),
        .m_rvalid_o (a_rvalid),
        .m_rready_i (a_rready),
        .s_awaddr_o (a_s_awaddr),
        .s_awprot_o (),
        .s_awvalid_o(a_s_awvalid),
        .s_awready_i(a_s_awready),
        .s_wdata_o  (a_s_wdata),
        .s_wstrb_o  (a_s_wstrb),
        .s_wvalid_o (a_s_wvalid),
        .s_wready_i (a_s_wready),
        .s_bresp_i  (a_s_bresp),
        .s_bvalid_i (a_s_bvalid),
        .s_bready_o (a_s_bready),
        .s_araddr_o (a_s_araddr),
        .s_arprot_o (),
        .s_arvalid_o(a_s_arvalid),
        .s_arready_i(a_s_arready),
        .s_rdata_i  (a_s_rdata),
        .s_rresp_i  (a_s_rresp),
        .s_rvalid_i (a_s_rvalid),
        .s_rready_o (a_s_rready)
    );

    // ------------------------------------------------------------ upstream
    wire [31:0] b_awaddr, b_wdata, b_araddr, b_rdata;
    wire [ 3:0] b_wstrb;
    wire [ 1:0] b_bresp, b_rresp;
    wire b_awvalid, b_awready, b_wvalid, b_wready, b_bvalid, b_bready;
    wire b_arvalid, b_arready, b_rvalid, b_rready, b_done;
    wire [31:0] b_rec_count;
    wire [MAX_REC*2-1:0] b_rec_kind, b_rec_resp;
    wire [MAX_REC*32-1:0] b_rec_data;

    wire [N*32-1:0] b_s_awaddr, b_s_wdata, b_s_araddr, b_s_rdata;
    wire [N*4-1:0] b_s_wstrb;
    wire [N*2-1:0] b_s_bresp, b_s_rresp;
    wire [N-1:0] b_s_awvalid, b_s_awready, b_s_wvalid, b_s_wready;
    wire [N-1:0] b_s_bvalid, b_s_bready, b_s_arvalid, b_s_arready, b_s_rvalid, b_s_rready;

    soc_lite_seq_master #(
        .ADDR_A (ADDR_A),
        .ADDR_B (ADDR_B),
        .MAX_REC(MAX_REC)
    ) seq_b (
        .clk_i      (clk),
        .rst_n_i    (rst_n),
        .start_i    (start),
        .done_o     (b_done),
        .awaddr_o   (b_awaddr),
        .awvalid_o  (b_awvalid),
        .awready_i  (b_awready),
        .wdata_o    (b_wdata),
        .wstrb_o    (b_wstrb),
        .wvalid_o   (b_wvalid),
        .wready_i   (b_wready),
        .bresp_i    (b_bresp),
        .bvalid_i   (b_bvalid),
        .bready_o   (b_bready),
        .araddr_o   (b_araddr),
        .arvalid_o  (b_arvalid),
        .arready_i  (b_arready),
        .rdata_i    (b_rdata),
        .rresp_i    (b_rresp),
        .rvalid_i   (b_rvalid),
        .rready_o   (b_rready),
        .rec_count_o(b_rec_count),
        .rec_kind_o (b_rec_kind),
        .rec_data_o (b_rec_data),
        .rec_resp_o (b_rec_resp)
    );

    // upstream takes the routing decision as an input; the window compare that
    // soc_axi_lite_dec does internally is done here instead, from the same
    // BASE/MASK, so both sides route by the same rule
    wire b_aw_select = ((b_awaddr & WIN_MASK) == (ADDR_B & WIN_MASK));
    wire b_ar_select = ((b_araddr & WIN_MASK) == (ADDR_B & WIN_MASK));

    pulp_lite_demux_wrap #(
        .N       (N),
        .MaxTrans(1)
    ) upstream (
        .clk_i      (clk),
        .rst_n_i    (rst_n),
        .m_awaddr_i (b_awaddr),
        .m_awvalid_i(b_awvalid),
        .m_awready_o(b_awready),
        .m_wdata_i  (b_wdata),
        .m_wstrb_i  (b_wstrb),
        .m_wvalid_i (b_wvalid),
        .m_wready_o (b_wready),
        .m_bresp_o  (b_bresp),
        .m_bvalid_o (b_bvalid),
        .m_bready_i (b_bready),
        .m_araddr_i (b_araddr),
        .m_arvalid_i(b_arvalid),
        .m_arready_o(b_arready),
        .m_rdata_o  (b_rdata),
        .m_rresp_o  (b_rresp),
        .m_rvalid_o (b_rvalid),
        .m_rready_i (b_rready),
        .aw_select_i(b_aw_select),
        .ar_select_i(b_ar_select),
        .s_awaddr_o (b_s_awaddr),
        .s_awvalid_o(b_s_awvalid),
        .s_awready_i(b_s_awready),
        .s_wdata_o  (b_s_wdata),
        .s_wstrb_o  (b_s_wstrb),
        .s_wvalid_o (b_s_wvalid),
        .s_wready_i (b_s_wready),
        .s_bresp_i  (b_s_bresp),
        .s_bvalid_i (b_s_bvalid),
        .s_bready_o (b_s_bready),
        .s_araddr_o (b_s_araddr),
        .s_arvalid_o(b_s_arvalid),
        .s_arready_i(b_s_arready),
        .s_rdata_i  (b_s_rdata),
        .s_rresp_i  (b_s_rresp),
        .s_rvalid_i (b_s_rvalid),
        .s_rready_o (b_s_rready)
    );

    // ------------------------------------------- the same slaves, both sides
    wire [31:0] a_ar_cnt[0:N-1];
    wire [31:0] a_aw_cnt[0:N-1];
    wire [31:0] b_ar_cnt[0:N-1];
    wire [31:0] b_aw_cnt[0:N-1];

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_slv
            soc_lite_slave_stub #(
                .ID(16'h5000 + g[15:0])
            ) slv_a (
                .clk_i      (clk),
                .rst_n_i    (rst_n),
                .s_awaddr_i (a_s_awaddr[g*32+:32]),
                .s_awvalid_i(a_s_awvalid[g]),
                .s_awready_o(a_s_awready[g]),
                .s_wdata_i  (a_s_wdata[g*32+:32]),
                .s_wstrb_i  (a_s_wstrb[g*4+:4]),
                .s_wvalid_i (a_s_wvalid[g]),
                .s_wready_o (a_s_wready[g]),
                .s_bresp_o  (a_s_bresp[g*2+:2]),
                .s_bvalid_o (a_s_bvalid[g]),
                .s_bready_i (a_s_bready[g]),
                .s_araddr_i (a_s_araddr[g*32+:32]),
                .s_arvalid_i(a_s_arvalid[g]),
                .s_arready_o(a_s_arready[g]),
                .s_rdata_o  (a_s_rdata[g*32+:32]),
                .s_rresp_o  (a_s_rresp[g*2+:2]),
                .s_rvalid_o (a_s_rvalid[g]),
                .s_rready_i (a_s_rready[g]),
                .ar_count_o (a_ar_cnt[g]),
                .aw_count_o (a_aw_cnt[g])
            );

            soc_lite_slave_stub #(
                .ID(16'h5000 + g[15:0])
            ) slv_b (
                .clk_i      (clk),
                .rst_n_i    (rst_n),
                .s_awaddr_i (b_s_awaddr[g*32+:32]),
                .s_awvalid_i(b_s_awvalid[g]),
                .s_awready_o(b_s_awready[g]),
                .s_wdata_i  (b_s_wdata[g*32+:32]),
                .s_wstrb_i  (b_s_wstrb[g*4+:4]),
                .s_wvalid_i (b_s_wvalid[g]),
                .s_wready_o (b_s_wready[g]),
                .s_bresp_o  (b_s_bresp[g*2+:2]),
                .s_bvalid_o (b_s_bvalid[g]),
                .s_bready_i (b_s_bready[g]),
                .s_araddr_i (b_s_araddr[g*32+:32]),
                .s_arvalid_i(b_s_arvalid[g]),
                .s_arready_o(b_s_arready[g]),
                .s_rdata_o  (b_s_rdata[g*32+:32]),
                .s_rresp_o  (b_s_rresp[g*2+:2]),
                .s_rvalid_o (b_s_rvalid[g]),
                .s_rready_i (b_s_rready[g]),
                .ar_count_o (b_ar_cnt[g]),
                .aw_count_o (b_aw_cnt[g])
            );
        end
    endgenerate

    // ----------------------------------------------------------- comparison
    integer i;

    initial begin
        $display("== SoC DECODER vs pulp-platform/axi axi_lite_demux (MaxTrans=1) ==");
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (2) @(posedge clk);
        start = 1'b1;

        wait (a_done === 1'b1 && b_done === 1'b1);
        repeat (2) @(posedge clk);

        $display("\n-- transaction records --");
        check(a_rec_count, b_rec_count, "both sides completed the same number of transactions");
        if (a_rec_count === b_rec_count) begin
            for (i = 0; i < a_rec_count; i = i + 1) begin
                check({30'b0, a_rec_kind[i*2+:2]}, {30'b0, b_rec_kind[i*2+:2]},
                      "transaction kinds agree");
                check(a_rec_data[i*32+:32], b_rec_data[i*32+:32], "transaction data agrees");
                check({30'b0, a_rec_resp[i*2+:2]}, {30'b0, b_rec_resp[i*2+:2]},
                      "transaction responses agree");
                if ($test$plusargs("verbose"))
                    $display("   %0d: kind=%0d ours=0x%08h upstream=0x%08h resp=%b/%b", i,
                             a_rec_kind[i*2+:2], a_rec_data[i*32+:32], b_rec_data[i*32+:32],
                             a_rec_resp[i*2+:2], b_rec_resp[i*2+:2]);
            end
        end

        $display("\n-- where the requests went --");
        for (i = 0; i < N; i = i + 1) begin
            check(a_ar_cnt[i], b_ar_cnt[i], "reads reaching this slave agree");
            check(a_aw_cnt[i], b_aw_cnt[i], "writes reaching this slave agree");
            if ($test$plusargs("verbose"))
                $display("   slave %0d: AR ours=%0d upstream=%0d, AW ours=%0d upstream=%0d", i,
                         a_ar_cnt[i], b_ar_cnt[i], a_aw_cnt[i], b_aw_cnt[i]);
        end

        // the sequence reads A three times and B four times; if either side had
        // re-pointed a route the totals would move between the slaves
        check(32'd3, a_ar_cnt[0], "ours: slave 0 saw its three reads");
        check(32'd4, a_ar_cnt[1], "ours: slave 1 saw its four reads");

        if (errors == 0) $display("\n== PULP COMPARISON: ALL TESTS PASSED ==");
        else $display("\n== PULP COMPARISON: %0d MISMATCH(ES) ==", errors);
        finish_test;
    end

    // A divergence can show up as a mismatch or as one side never finishing -
    // a decoder that re-points a live read route strands the response and stops
    // there. Either way the useful evidence is the same: what each side managed
    // to complete before it stopped.
    task dump(input [511:0] who, input [31:0] count, input [MAX_REC*2-1:0] kind,
              input [MAX_REC*32-1:0] data, input [MAX_REC*2-1:0] resp);
        integer j;
        begin
            $display("   %0s: %0d transaction(s)", who, count);
            for (j = 0; j < count; j = j + 1)
                $display("      %0d: %0s data=0x%08h resp=%b", j,
                         kind[j*2+:2] == 2'd0 ? "read " : "write", data[j*32+:32],
                         resp[j*2+:2]);
        end
    endtask

    initial begin
        #50000;
        $display("\n== PULP COMPARISON: TIMED OUT (ours done=%0b upstream done=%0b) ==", a_done,
                 b_done);
        dump("ours", a_rec_count, a_rec_kind, a_rec_data, a_rec_resp);
        dump("upstream", b_rec_count, b_rec_kind, b_rec_data, b_rec_resp);
        $fatal(1, "FAIL: the two implementations did not complete the same sequence");
    end

endmodule
