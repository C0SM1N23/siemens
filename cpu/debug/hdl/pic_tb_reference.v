// PIC register-port comparison with independently generated priority vectors.
`timescale 1ns / 1ps

module pic_tb_reference;

    // ---- register map (byte offsets) ----
    localparam CFG0 = 32'h00, SWT0 = 32'h40, STA0 = 32'h80;
    localparam BAND_CONFIG = 32'hC0, ESCALATION = 32'hD4, INT_ENABLE = 32'hD8;
    localparam RESP_OKAY = 2'b00;

    // ---- clock / reset ----
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- DUT source / CPU pins ----
    reg [15:0] irq_src;
    reg [15:0] cpu_mask;
    reg cpu_irq_ack, cpu_irq_eoi;
    wire        cpu_irq;
    wire [ 3:0] cpu_irq_vec;
    wire [15:0] pending;

    // ---- AXI4-Lite master side ----
    reg [31:0] awaddr, wdata, araddr;
    reg [3:0] wstrb;
    reg awvalid, wvalid, bready, arvalid, rready;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire    [31:0] rdata;

    integer        errors = 0;
    reg     [31:0] rd;
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
        .s_axi_awprot_i (3'b0),
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
        .s_axi_arprot_i (3'b0),
        .s_axi_arvalid_i(arvalid),
        .s_axi_arready_o(arready),
        .s_axi_rdata_o  (rdata),
        .s_axi_rresp_o  (rresp),
        .s_axi_rvalid_o (rvalid),
        .s_axi_rready_i (rready)
    );

    `include "pic_reference_count.vh"
    reg     [31:0] vectors    [0:PIC_CASES*22-1];
    integer        test_index;
    integer        source;
    integer        base;
    initial begin
        $readmemh("pic_reference.hex", vectors);
        irq_src     = 0;
        cpu_mask    = 0;
        cpu_irq_ack = 0;
        cpu_irq_eoi = 0;
        axil_idle;
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (test_index = 0; test_index < PIC_CASES; test_index = test_index + 1) begin
            base    = test_index * 22;
            irq_src = 0;
            for (source = 0; source < 16; source = source + 1)
            axil_write(source * 4, vectors[base+source], RESP_OKAY);
            axil_write(BAND_CONFIG, vectors[base+16], RESP_OKAY);
            axil_write(INT_ENABLE, vectors[base+17], RESP_OKAY);
            @(negedge clk);
            cpu_mask = vectors[base+18][15:0];
            irq_src  = vectors[base+19][15:0];
            repeat (4) @(negedge clk);
            check(vectors[base+20] >> 4, {31'b0, cpu_irq}, "reference offer valid");
            if (vectors[base+20][4])
                check(vectors[base+20] & 15, {28'b0, cpu_irq_vec}, "reference priority winner");
            check(vectors[base+21], {16'b0, pending}, "reference pending mask");
        end
        if (errors == 0) $display("== PIC REFERENCE: ALL TESTS PASSED (%0d cases) ==", PIC_CASES);
        finish_test;
    end
    initial begin
        #1000000;
        $fatal(1, "PIC reference timeout");
    end
endmodule
