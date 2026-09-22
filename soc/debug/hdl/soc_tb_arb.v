// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// Arbitration: concurrent directions, contention, and response backpressure.
//
// The second half of this bench runs against a deliberately permissive slave -
// one that keeps AWREADY, WREADY and ARREADY asserted even while it still owes
// a response. A slave like that will happily accept a second address, so it is
// the arbiter, and only the arbiter, that has to refuse one. Against the strict
// slave used in the first half the slave's own READY hides that obligation, so
// a grant that let a second transaction through would go unnoticed.
`timescale 1ns / 1ps

module soc_tb_arb;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;
    integer errors = 0;
    `include "tb_check.vh"

    reg [1:0] awvalid = 0, wvalid = 0, arvalid = 0;
    reg [1:0] bready = 0, rready = 0;
    wire [1:0] awready, wready, arready, bvalid, rvalid;
    wire [63:0] rdata;
    wire s_awvalid, s_wvalid, s_arvalid, s_bready, s_rready;
    wire [31:0] s_awaddr, s_wdata, s_araddr;
    reg aw_seen = 0, w_seen = 0, read_valid = 0;
    reg  [31:0] read_data;
    wire        write_valid = aw_seen && w_seen;

    // eager = the slave stops using READY to serialise; the arbiter is then the
    // only thing standing between one grant and two transactions
    reg eager = 0;
    wire slv_awready = eager ? 1'b1 : !aw_seen;
    wire slv_wready = eager ? 1'b1 : !w_seen;
    wire slv_arready = eager ? 1'b1 : !read_valid;

    soc_axi_lite_arb #(
        .M(2)
    ) dut (
        .clk_i      (clk),
        .rst_n_i    (rst_n),
        .m_awaddr_i ({32'h200, 32'h100}),
        .m_awprot_i (6'b0),
        .m_awvalid_i(awvalid),
        .m_awready_o(awready),
        .m_wdata_i  ({32'hBBBB, 32'hAAAA}),
        .m_wstrb_i  (8'hFF),
        .m_wvalid_i (wvalid),
        .m_wready_o (wready),
        .m_bresp_o  (),
        .m_bvalid_o (bvalid),
        .m_bready_i (bready),
        .m_araddr_i ({32'h204, 32'h104}),
        .m_arprot_i (6'b0),
        .m_arvalid_i(arvalid),
        .m_arready_o(arready),
        .m_rdata_o  (rdata),
        .m_rresp_o  (),
        .m_rvalid_o (rvalid),
        .m_rready_i (rready),
        .s_awaddr_o (s_awaddr),
        .s_awprot_o (),
        .s_awvalid_o(s_awvalid),
        .s_awready_i(slv_awready),
        .s_wdata_o  (s_wdata),
        .s_wstrb_o  (),
        .s_wvalid_o (s_wvalid),
        .s_wready_i (slv_wready),
        .s_bresp_i  (2'b0),
        .s_bvalid_i (write_valid),
        .s_bready_o (s_bready),
        .s_araddr_o (s_araddr),
        .s_arprot_o (),
        .s_arvalid_o(s_arvalid),
        .s_arready_i(slv_arready),
        .s_rdata_i  (read_data),
        .s_rresp_i  (2'b0),
        .s_rvalid_i (read_valid),
        .s_rready_o (s_rready)
    );

    // handshakes at the shared slave port
    wire s_aw_hs = s_awvalid && slv_awready;
    wire s_w_hs = s_wvalid && slv_wready;
    wire s_b_hs = write_valid && s_bready;
    wire s_ar_hs = s_arvalid && slv_arready;
    wire s_r_hs = read_valid && s_rready;

    // Independent slave: AW and W are accepted separately; responses hold.
    always @(posedge clk) begin
        if (!rst_n || s_b_hs) aw_seen <= 0;
        else if (s_aw_hs) aw_seen <= 1;
    end
    always @(posedge clk) begin
        if (!rst_n || s_b_hs) w_seen <= 0;
        else if (s_w_hs) w_seen <= 1;
    end
    always @(posedge clk) begin
        if (!rst_n) read_valid <= 0;
        else if (s_ar_hs) read_valid <= 1;
        else if (s_r_hs) read_valid <= 0;
    end
    always @(posedge clk) begin
        if (s_ar_hs) read_data <= s_araddr ^ 32'hCAFE0000;
    end

    // A grant is one transaction: whatever the slave is willing to accept, the
    // arbiter must not present a second address or a second data beat until the
    // response to the current one has been taken.
    always @(posedge clk) begin
        if (rst_n) begin
            if (s_aw_hs && aw_seen) begin
                $display("FAIL: a second AW reached the slave inside one grant");
                errors = errors + 1;
            end
            if (s_w_hs && w_seen) begin
                $display("FAIL: a second W beat reached the slave inside one grant");
                errors = errors + 1;
            end
            if (s_ar_hs && read_valid) begin
                $display("FAIL: a second AR reached the slave inside one grant");
                errors = errors + 1;
            end
        end
    end

    // slave-port tally: accepted against completed
    integer s_aw_cnt = 0, s_w_cnt = 0, s_b_cnt = 0, s_ar_cnt = 0, s_r_cnt = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (s_aw_hs) s_aw_cnt = s_aw_cnt + 1;
            if (s_w_hs) s_w_cnt = s_w_cnt + 1;
            if (s_b_hs) s_b_cnt = s_b_cnt + 1;
            if (s_ar_hs) s_ar_cnt = s_ar_cnt + 1;
            if (s_r_hs) s_r_cnt = s_r_cnt + 1;
        end
    end

    // which master the arbiter accepted the request from, so the response can be
    // checked against it rather than against a hard-coded master index
    reg [1:0] wr_owner = 0, rd_owner = 0;
    always @(posedge clk) begin
        if (rst_n && |(awvalid & awready)) wr_owner <= awvalid & awready;
    end
    always @(posedge clk) begin
        if (rst_n && |(arvalid & arready)) rd_owner <= arvalid & arready;
    end

    integer reads = 0;
    integer writes = 0;
    always @(posedge clk) begin
        if (rst_n && |(rvalid & rready)) begin
            if (rvalid[0] && rready[0]) check(32'hCAFE0104, rdata[31:0], "master 0 read route");
            if (rvalid[1] && rready[1]) check(32'hCAFE0204, rdata[63:32], "master 1 read route");
            check({30'b0, rd_owner}, {30'b0, rvalid & rready},
                  "read response reaches the master that issued it");
            reads = reads + 1;
        end
    end
    always @(posedge clk) begin
        if (rst_n && |(bvalid & bready)) begin
            check({30'b0, wr_owner}, {30'b0, bvalid & bready},
                  "write response reaches the master that issued it");
            writes = writes + 1;
        end
    end

    // Take the response master `m` is waiting for, `hold` cycles after it
    // appears, so the grant is held across an idle master.
    task take_b(input integer m, input integer hold);
        begin
            @(posedge clk);
            while (!bvalid[m]) @(posedge clk);
            repeat (hold) begin
                @(posedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            bready[m] = 1'b1;
            @(posedge clk);
            while (!(bvalid[m] && bready[m])) @(posedge clk);
            #1;
            bready[m] = 1'b0;
        end
    endtask

    task take_r(input integer m, input integer hold);
        begin
            @(posedge clk);
            while (!rvalid[m]) @(posedge clk);
            repeat (hold) begin
                @(posedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            rready[m] = 1'b1;
            @(posedge clk);
            while (!(rvalid[m] && rready[m])) @(posedge clk);
            #1;
            rready[m] = 1'b0;
        end
    endtask

    // One write from master `m`. `w_first` offers the data before the address,
    // `skew` sets how far apart they arrive, `hold` how long the master leaves
    // its response unread. Each half is withdrawn at its own handshake, so the
    // master asks for exactly one write - the watchers start before the skew,
    // because the first half can be accepted while the second is still waiting.
    task do_write(input integer m, input w_first, input integer skew, input integer hold);
        begin
            @(posedge clk);
            #1;
            if (w_first) wvalid[m] = 1'b1;
            else awvalid[m] = 1'b1;
            fork
                begin
                    repeat (skew) begin
                        @(posedge clk);
                        #1;
                    end
                    if (w_first) awvalid[m] = 1'b1;
                    else wvalid[m] = 1'b1;
                end
                begin
                    @(posedge clk);
                    while (!(awvalid[m] && awready[m])) @(posedge clk);
                    #1;
                    awvalid[m] = 1'b0;
                end
                begin
                    @(posedge clk);
                    while (!(wvalid[m] && wready[m])) @(posedge clk);
                    #1;
                    wvalid[m] = 1'b0;
                end
                take_b(m, hold);
            join
        end
    endtask

    task do_read(input integer m, input integer hold);
        begin
            @(posedge clk);
            #1;
            arvalid[m] = 1'b1;
            fork
                begin
                    @(posedge clk);
                    while (!(arvalid[m] && arready[m])) @(posedge clk);
                    #1;
                    arvalid[m] = 1'b0;
                end
                take_r(m, hold);
            join
        end
    endtask

    integer writes_at_start, reads_at_start;

    initial begin
        repeat (3) begin
            @(posedge clk);
            #1;
        end
        rst_n   = 1;

        $display("-- 1. both directions requested at once, responses held back --");
        awvalid = 1;
        wvalid  = 1;
        arvalid = 3;
        fork
            begin
                @(posedge clk);
                while (!awready[0]) @(posedge clk);
                #1;
                awvalid[0] = 0;
            end
            begin
                @(posedge clk);
                while (!wready[0]) @(posedge clk);
                #1;
                wvalid[0] = 0;
            end
            begin
                @(posedge clk);
                while (!arready[0]) @(posedge clk);
                #1;
                arvalid[0] = 0;
            end
            begin
                @(posedge clk);
                while (!arready[1]) @(posedge clk);
                #1;
                arvalid[1] = 0;
            end
            begin
                repeat (5) begin
                    @(posedge clk);
                    #1;
                end
                rready = 3;
                repeat (15) begin
                    @(posedge clk);
                    #1;
                end
                bready = 3;
            end
        join
        wait (reads == 2 && writes == 1);
        repeat (3) begin
            @(posedge clk);
            #1;
        end
        bready = 0;
        rready = 0;
        check(2, reads, "two reads completed");
        check(1, writes, "one write completed");

        // From here the slave stops serialising for the arbiter.
        eager = 1;

        $display("-- 2. a master that already has its next write ready --");
        // AWVALID and WVALID never drop between the two writes, so every cycle
        // the first grant is held the arbiter is being offered a second write
        // it must not forward.
        writes_at_start = writes;
        @(posedge clk);
        #1;
        awvalid = 2'b01;
        wvalid  = 2'b01;
        fork
            begin : hold_aw
                integer n;
                for (n = 0; n < 2; n = n + 1) begin
                    @(posedge clk);
                    while (!(awvalid[0] && awready[0])) @(posedge clk);
                end
                #1;
                awvalid[0] = 1'b0;
            end
            begin : hold_w
                integer n;
                for (n = 0; n < 2; n = n + 1) begin
                    @(posedge clk);
                    while (!(wvalid[0] && wready[0])) @(posedge clk);
                end
                #1;
                wvalid[0] = 1'b0;
            end
            begin
                take_b(0, 4);
                take_b(0, 2);
            end
        join
        repeat (4) begin
            @(posedge clk);
            #1;
        end
        check(writes_at_start + 2, writes, "exactly two writes completed");

        $display("-- 3. write data before its address, and after it --");
        writes_at_start = writes;
        do_write(0, 1'b1, 4, 3);  // W offered first
        repeat (3) begin
            @(posedge clk);
            #1;
        end
        do_write(0, 1'b0, 4, 0);  // AW offered first
        repeat (3) begin
            @(posedge clk);
            #1;
        end
        check(writes_at_start + 2, writes, "both orderings completed once each");

        $display("-- 4. the other master's write, and its read, under contention --");
        // Master 1 writes while master 0 reads: each response must come back to
        // the master that asked, and the one held back must not cost the other
        // its turn.
        writes_at_start = writes;
        reads_at_start  = reads;
        fork
            do_write(1, 1'b0, 0, 5);
            do_read(0, 3);
        join
        repeat (4) begin
            @(posedge clk);
            #1;
        end
        check(writes_at_start + 1, writes, "master 1's write completed once");
        check(reads_at_start + 1, reads, "master 0's read completed once");

        $display("-- 5. accepted and completed transactions agree --");
        check(s_b_cnt[31:0], s_aw_cnt[31:0], "every accepted AW was answered by a B");
        check(s_b_cnt[31:0], s_w_cnt[31:0], "every accepted W beat was answered by a B");
        check(s_r_cnt[31:0], s_ar_cnt[31:0], "every accepted AR was answered by an R");
        check(writes[31:0], s_b_cnt[31:0], "the masters saw every write the slave completed");
        check(reads[31:0], s_r_cnt[31:0], "the masters saw every read the slave completed");

        if (errors == 0) $display("== ARBITER: ALL TESTS PASSED ==");
        finish_test;
    end
    initial begin
        #20000;
        $fatal(1, "arbiter timeout: reads=%0d writes=%0d", reads, writes);
    end
endmodule
