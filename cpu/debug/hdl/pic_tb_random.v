// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// PIC under constrained-random traffic, checked against pic_model.py.
//
// Three independent processes drive the controller for +cycles=N clocks from
// +seed=S:
//   sources    hardware lines toggle at random, some level, some edge-triggered
//   cpu        claims an offered source after a random delay, sometimes after
//              the source has gone (spurious), issues EOIs, changes its mask,
//              and now and then claims or ends with nothing offered or open
//   registers  random AXI writes to every register: configurations with short
//              deadlines, keyed and unkeyed software triggers, band orderings,
//              NEST_MAX inside and outside 1..16, escalation modes, enables,
//              write-1-to-clear of the logs, partial byte strobes, and writes to
//              read-only offsets, each with its expected response
// Every clock edge the bench writes one trace line: the inputs the controller
// sampled at that edge and its architectural state before it. pic_model.py
// replays the inputs through an independent cycle model and compares every
// line; the bench itself checks the AXI responses.

`timescale 1ns / 1ps

module pic_tb_random;

    localparam [31:0] CFG0 = 32'h00, SWT0 = 32'h40, BAND_CONFIG = 32'hC0, NEST_MAX = 32'hC8,
                      SPURIOUS_LOG = 32'hD0, ESCALATION = 32'hD4, INT_ENABLE = 32'hD8,
                      INT_STATUS = 32'hDC;
    localparam [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [15:0] irq_src = 16'b0;
    reg  [15:0] cpu_mask = 16'hFFFF;
    reg         cpu_irq_ack = 1'b0, cpu_irq_eoi = 1'b0;
    wire        cpu_irq;
    wire [ 3:0] cpu_irq_vec;
    wire [15:0] pending;

    reg [31:0] awaddr, wdata, araddr;
    reg [3:0] wstrb;
    reg awvalid, wvalid, bready, arvalid, rready;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;

    integer errors = 0;
    integer seed, seed0, cycles, trace, k;
    reg [31:0] rd;
    reg running = 1'b0;
    reg busy = 1'b0;
    `include "tb_check.vh"
    `include "tb_axil_master.vh"

    pic dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .irq_src_i      (irq_src),
        .cpu_mask_i     (cpu_mask),
        .cpu_irq_o      (cpu_irq),
        .cpu_irq_vec_o  (cpu_irq_vec),
        .pending_o      (pending),
        .cpu_irq_ack_i  (cpu_irq_ack),
        .cpu_irq_eoi_i  (cpu_irq_eoi),
        .s_axi_awaddr_i (awaddr),
        .s_axi_awprot_i (3'b000),
        .s_axi_awvalid_i(awvalid),
        .s_axi_awready_o(awready),
        .s_axi_wdata_i  (wdata),
        .s_axi_wstrb_i  (wstrb),
        .s_axi_wvalid_i (wvalid),
        .s_axi_wready_o (wready),
        .s_axi_bresp_o  (bresp),
        .s_axi_bvalid_o (bvalid),
        .s_axi_bready_i (bready),
        .s_axi_araddr_i (araddr),
        .s_axi_arprot_i (3'b000),
        .s_axi_arvalid_i(arvalid),
        .s_axi_arready_o(arready),
        .s_axi_rdata_o  (rdata),
        .s_axi_rresp_o  (rresp),
        .s_axi_rvalid_o (rvalid),
        .s_axi_rready_i (rready)
    );

    function [31:0] rnd;  // uniform in [0, n)
        input integer n;
        rnd = ($random(seed) & 32'h7FFF_FFFF) % n;
    endfunction

    // ---- trace: inputs sampled at this edge, state before it -------------------
    reg [255:0] ddl_all;
    reg [31:0] band_all;
    always @(posedge clk) begin : dump
        integer s;
        if (running) begin
            for (s = 0; s < 16; s = s + 1) begin
                ddl_all[16*s+:16] = dut.ddl_cnt[s];
                band_all[2*s+:2]  = dut.eff_band[s];
            end
            $fwrite(trace, "%h %h %h %h %h %h %h %h ", irq_src, cpu_mask, cpu_irq_ack, cpu_irq_eoi,
                    dut.reg_wr, dut.reg_waddr, dut.reg_wdata, dut.reg_wstrb);
            $fwrite(trace, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                    cpu_irq, cpu_irq_vec, pending, dut.depth, dut.active, dut.spurious,
                    dut.spurious_log, dut.int_status, dut.escalated, dut.sw_pend, dut.edge_pend,
                    dut.int_enable, dut.band_cfg, dut.nest_max, dut.esc_cfg, dut.cpu_irq_vec_d,
                    band_all, ddl_all, dut.irq_src_q);
        end
    end

    // ---- hardware sources ----------------------------------------------------------
    always @(posedge clk) begin
        if (running) begin
            #1;
            for (k = 0; k < 16; k = k + 1) if (rnd(24) == 0) irq_src[k] = ~irq_src[k];
        end
    end

    // ---- the CPU ---------------------------------------------------------------------
    always @(posedge clk) begin
        if (running) begin
            #1;
            cpu_irq_ack = 1'b0;
            cpu_irq_eoi = 1'b0;
            if (cpu_irq && rnd(3) == 0) begin
                cpu_irq_ack = 1'b1;
                if (rnd(8) == 0) irq_src[cpu_irq_vec] = 1'b0;  // withdrawn: spurious
            end else if (!cpu_irq && rnd(600) == 0) begin
                cpu_irq_ack = 1'b1;  // a claim with nothing offered
            end else if (dut.depth != 0 && rnd(16) == 0) begin
                cpu_irq_eoi = 1'b1;
            end else if (dut.depth == 0 && rnd(600) == 0) begin
                cpu_irq_eoi = 1'b1;  // an EOI with nothing open
            end
            if (rnd(300) == 0) cpu_mask = rnd(4) == 0 ? rnd(65536) : 16'hFFFF;
        end
    end

    // ---- register traffic ------------------------------------------------------------
    task random_write;
        reg [31:0] a, d;
        reg [ 3:0] s;
        reg [ 1:0] exp;
        integer    which;
        begin
            which = rnd(12);
            s     = rnd(8) == 0 ? rnd(16) : 4'hF;
            exp   = RESP_OKAY;
            case (which)
                0, 1, 2: begin  // SRCx_CONFIG: short deadlines so escalation happens
                    a         = CFG0 + 4 * rnd(16);
                    d         = 32'b0;
                    d[31:16]  = rnd(4) == 0 ? 16'd0 : rnd(24);
                    d[15:8]   = rnd(4) == 0 ? rnd(256) : 8'd0;  // reserved: must read 0
                    d[7:4]    = rnd(16);
                    d[3]      = rnd(2);                         // reserved
                    d[2:1]    = rnd(4);
                    d[0]      = rnd(2);
                end
                3, 4: begin  // SRCx_SW_TRIG: keyed set, unkeyed set, clear
                    a = SWT0 + 4 * rnd(16);
                    case (rnd(4))
                        0, 1: d = 32'hA5A5_0001;
                        2: begin
                            d        = 32'h0000_0001;
                            d[31:16] = rnd(65536);  // a random key, rarely the right one
                        end
                        default: d = 32'h0;
                    endcase
                end
                5: begin
                    a = BAND_CONFIG;
                    d = rnd(256);
                end
                6: begin
                    a = NEST_MAX;
                    d = rnd(22);
                end
                7: begin
                    a = ESCALATION;
                    d = rnd(512);
                end
                8: begin
                    a = INT_ENABLE;
                    d = rnd(3) == 0 ? rnd(65536) : 32'h0000_FFFF;
                end
                9: begin
                    a = rnd(2) ? SPURIOUS_LOG : INT_STATUS;
                    d = rnd(65536);
                end
                10: begin  // read-only and unmapped offsets
                    a = 32'h80 + 4 * rnd(24);
                    d = rnd(65536);
                    if (a != BAND_CONFIG && a != NEST_MAX && a != SPURIOUS_LOG && a != ESCALATION
                        && a != INT_ENABLE && a != INT_STATUS) exp = RESP_SLVERR;
                end
                default: begin  // a read, for traffic on the other channel
                    a = 4 * rnd(64);
                    axil_read(a, a <= 32'hDC ? RESP_OKAY : RESP_SLVERR);
                    a = 32'hFFFF_FFFF;
                end
            endcase
            if (a != 32'hFFFF_FFFF) axil_write_strb(a, d, s, exp);
        end
    endtask

    initial begin : traffic
        integer gap;
        wait (running);
        while (running) begin
            gap = rnd(20);
            repeat (gap) @(posedge clk);
            if (running) begin
                busy = 1'b1;
                random_write;
                busy = 1'b0;
            end
        end
    end

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        seed0 = seed;
        if (!$value$plusargs("cycles=%d", cycles)) cycles = 20000;
        trace = $fopen("pic_random.trace", "w");
        $fwrite(trace, "# pic_tb_random seed=%0d cycles=%0d\n", seed, cycles);
        axil_idle;
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk);
        #1 running = 1'b1;
        repeat (cycles) @(posedge clk);
        running = 1'b0;
        wait (!busy);
        repeat (2) @(posedge clk);
        $fclose(trace);
        if (errors == 0) $display("== PIC RANDOM TESTBENCH: ALL TESTS PASSED (seed %0d, %0d cycles; compare with pic_model.py) ==", seed0, cycles);
        else $display("== PIC RANDOM TESTBENCH: %0d FAILURE(S) ==", errors);
        finish_test;
    end
endmodule
