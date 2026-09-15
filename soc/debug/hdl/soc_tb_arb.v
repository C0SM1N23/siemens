// Arbitration: concurrent directions, contention, and response backpressure.
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
        .s_awready_i(!aw_seen),
        .s_wdata_o  (s_wdata),
        .s_wstrb_o  (),
        .s_wvalid_o (s_wvalid),
        .s_wready_i (!w_seen),
        .s_bresp_i  (2'b0),
        .s_bvalid_i (write_valid),
        .s_bready_o (s_bready),
        .s_araddr_o (s_araddr),
        .s_arprot_o (),
        .s_arvalid_o(s_arvalid),
        .s_arready_i(!read_valid),
        .s_rdata_i  (read_data),
        .s_rresp_i  (2'b0),
        .s_rvalid_i (read_valid),
        .s_rready_o (s_rready)
    );

    // Independent slave: AW and W are accepted separately; responses hold.
    always @(posedge clk) begin
        if (!rst_n || (write_valid && s_bready)) aw_seen <= 0;
        else if (s_awvalid && !aw_seen) aw_seen <= 1;
    end
    always @(posedge clk) begin
        if (!rst_n || (write_valid && s_bready)) w_seen <= 0;
        else if (s_wvalid && !w_seen) w_seen <= 1;
    end
    always @(posedge clk) begin
        if (!rst_n) read_valid <= 0;
        else if (s_arvalid && !read_valid) read_valid <= 1;
        else if (read_valid && s_rready) read_valid <= 0;
    end
    always @(posedge clk) begin
        if (s_arvalid && !read_valid) read_data <= s_araddr ^ 32'hCAFE0000;
    end

    integer reads = 0;
    integer writes = 0;
    always @(posedge clk) begin
        if (rst_n && |(rvalid & rready)) begin
            if (rvalid[0] && rready[0]) check(32'hCAFE0104, rdata[31:0], "master 0 read route");
            if (rvalid[1] && rready[1]) check(32'hCAFE0204, rdata[63:32], "master 1 read route");
            reads = reads + 1;
        end
    end
    always @(posedge clk) begin
        if (rst_n && |(bvalid & bready)) begin
            check(1, {30'b0, bvalid}, "write response owner");
            writes = writes + 1;
        end
    end

    initial begin
        repeat (3) @(negedge clk);
        rst_n   = 1;
        awvalid = 1;
        wvalid  = 1;
        arvalid = 3;
        fork
            begin
                @(posedge clk);
                while (!awready[0]) @(posedge clk);
                @(negedge clk);
                awvalid[0] = 0;
            end
            begin
                @(posedge clk);
                while (!wready[0]) @(posedge clk);
                @(negedge clk);
                wvalid[0] = 0;
            end
            begin
                @(posedge clk);
                while (!arready[0]) @(posedge clk);
                @(negedge clk);
                arvalid[0] = 0;
            end
            begin
                @(posedge clk);
                while (!arready[1]) @(posedge clk);
                @(negedge clk);
                arvalid[1] = 0;
            end
            begin
                repeat (5) @(negedge clk);
                rready = 3;
                repeat (15) @(negedge clk);
                bready = 3;
            end
        join
        wait (reads == 2 && writes == 1);
        repeat (3) @(negedge clk);
        check(2, reads, "two reads completed");
        check(1, writes, "one write completed");
        if (errors == 0) $display("== ARBITER: ALL TESTS PASSED ==");
        finish_test;
    end
    initial begin
        #5000;
        $fatal(1, "arbiter timeout: reads=%0d writes=%0d", reads, writes);
    end
endmodule
