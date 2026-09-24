// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// CPU isolation in the SoC (program_isolation.s).
//
// Each bus reaches only its own windows: the instruction bus only IMEM, the data
// bus everything except IMEM. The program makes eight accesses that no window
// accepts - data accesses to IMEM, to unmapped space and just past the three
// 256-byte peripheral windows and the 1 KiB SRAM window, and instruction fetches
// from DMEM and from the PIC. Each must end in the precise trap for its kind,
// with mtval naming the address.
//
// The bench also watches every slave port for the whole run: none of those
// accesses may reach a slave, so the peripheral and SRAM ports must stay idle,
// and the IMEM word the program tried to overwrite and the PIC configuration
// the byte store would alias must keep their values.

`timescale 1ns / 1ps

module soc_tb_isolation;

    integer errors;
    `include "tb_check.vh"

    wire clk, rst_n;
    ck_rst_tb #(
        .CK_SEMIPERIOD(5)
    ) ck_rst (
        .clk_o  (clk),
        .rst_n_o(rst_n)
    );

    wire cpu_in_trap, cpu_irq, sram_irq, tmr_irq;
    wire [3:0] dma_irq;

    soc_top #(
        .RESET_PC (32'h0000_0000),
        .IMEM_INIT("program_isolation.hex"),
        .DMEM_INIT("")
    ) dut (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .cpu_in_trap_o(cpu_in_trap),
        .cpu_irq_o    (cpu_irq),
        .dma_irq_o    (dma_irq),
        .sram_irq_o   (sram_irq),
        .tmr_irq_o    (tmr_irq)
    );

    localparam integer SB_BASE  = 128;  // 0x200: {mcause, mtval} pairs
    localparam integer SB_COUNT = 192;  // 0x300
    localparam integer SB_DONE  = 193;  // 0x304
    localparam [31:0] DONE_MARKER = 32'h15C0_A7ED;

    // decoder slave indices, as in soc_top.v
    localparam integer SD_SRAM = 1, SD_PIC = 2, SD_TMR = 3, SD_DMA = 4;

    // Any request that reaches a slave port this program should never touch.
    integer stray;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) stray <= 0;
        else if (dut.d_awvalid[SD_SRAM] || dut.d_arvalid[SD_SRAM] || dut.d_wvalid[SD_SRAM]
              || dut.d_awvalid[SD_PIC]  || dut.d_arvalid[SD_PIC]  || dut.d_wvalid[SD_PIC]
              || dut.d_awvalid[SD_TMR]  || dut.d_arvalid[SD_TMR]  || dut.d_wvalid[SD_TMR]
              || dut.d_awvalid[SD_DMA]  || dut.d_arvalid[SD_DMA]  || dut.d_wvalid[SD_DMA])
            stray <= stray + 1;
    end

    // Fetches the instruction decoder answered itself, with DECERR.
    integer ibus_decerr;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) ibus_decerr <= 0;
        else if (dut.ibus_rvalid && dut.ibus_rready && dut.ibus_rresp == 2'b11)
            ibus_decerr <= ibus_decerr + 1;
    end

    reg [31:0] imem_before, pic_src1_before;
    reg [31:0] exp_cause[0:7];
    reg [31:0] exp_tval [0:7];
    integer i, timeout;

    initial begin
        errors  = 0;
        timeout = 0;
        exp_cause[0] = 7; exp_tval[0] = 32'h5000_0000;
        exp_cause[1] = 5; exp_tval[1] = 32'h0000_0100;
        exp_cause[2] = 7; exp_tval[2] = 32'h0000_0100;
        exp_cause[3] = 7; exp_tval[3] = 32'h3000_0104;
        exp_cause[4] = 5; exp_tval[4] = 32'h1000_0400;
        exp_cause[5] = 5; exp_tval[5] = 32'h3001_0100;
        exp_cause[6] = 1; exp_tval[6] = 32'h0000_2000;
        exp_cause[7] = 1; exp_tval[7] = 32'h3000_0000;

        @(posedge rst_n);
        imem_before     = dut.imem_inst.mem[64];  // byte address 0x100
        pic_src1_before = dut.pic_inst.src_config[1];
        $display("\n== SoC: accesses outside every reachable window ==");

        while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
            errors = errors + 1;
            $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        end else begin
            $display("-- Precise traps --");
            check(32'd8, dut.dmem_inst.mem[SB_COUNT], "eight accesses trapped");
            for (i = 0; i < 8; i = i + 1) begin
                check(exp_cause[i], dut.dmem_inst.mem[SB_BASE+2*i], "mcause of the access");
                check(exp_tval[i], dut.dmem_inst.mem[SB_BASE+2*i+1], "mtval names the address");
            end
            $display("\n-- Nothing reached a slave --");
            check(32'd0, stray, "no request reached a peripheral or the SRAM");
            // a fetch past the faulting one may be in flight when the trap flushes it
            check(32'd1, {31'b0, ibus_decerr >= 2}, "both fetches answered DECERR by the decoder");
            check(imem_before, dut.imem_inst.mem[64], "IMEM word unchanged");
            check(pic_src1_before, dut.pic_inst.src_config[1], "PIC SRC1_CONFIG unchanged");
        end

        if (errors == 0) $display("== SOC ISOLATION TESTBENCH: ALL TESTS PASSED ==");
        else $display("== SOC ISOLATION TESTBENCH: %0d FAILURE(S) ==", errors);
        finish_test;
    end

endmodule
