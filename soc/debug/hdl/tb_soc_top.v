// System bench for soc_top: CPU + DMA + dual-port SRAM running as one SoC.
//
// The bench does almost nothing itself. It supplies a clock and a reset,
// loads the program into instruction memory, and then waits: the checking is
// done by the software in program_soc.s, which sets up a DMA transfer, sleeps
// on WFI, is woken through the PIC, and compares what the DMA moved against
// what it was asked to move. The bench reads the scoreboard the program
// leaves in data memory and turns it into PASS/FAIL lines.
//
// That split is deliberate. A bench that drove the buses itself would prove
// the fabric works when the bench drives it; letting the CPU's own software
// do the work proves it works when the CPU drives it, which is the thing that
// actually has to hold.
//
// What the run covers end to end:
//   - CPU data bus decoded to four different slaves (DMEM, SRAM, PIC, DMA)
//   - the DMA fetching a descriptor and reading source data out of DMEM,
//     arbitrated against the CPU's own data bus
//   - 8-beat AXI4-Full bursts turned into AXI4-Lite beats by the bridge
//   - the dual-port SRAM written by the DMA on port B and read by the CPU on
//     port A
//   - a 64-byte transfer, so the channel loops over two 32-byte chunks
//     instead of finishing on its first pass
//   - DMA completion -> PIC source 0 -> CPU interrupt -> handler -> MRET,
//     including the WFI wake

`timescale 1ns/1ps

module tb_soc_top;

integer errors;
`include "tb_check.vh"

wire clk, rst_n;
ck_rst_tb #(.CK_SEMIPERIOD(5)) ck_rst (.clk_o(clk), .rst_n_o(rst_n));

wire       cpu_in_trap, cpu_irq, sram_irq, tmr_irq;
wire [3:0] dma_irq;

soc_top #(
    .RESET_PC  (32'h0000_0000),
    .IMEM_INIT ("program_soc.hex"),
    .DMEM_INIT ("")
) dut (
    .clk_i         (clk),
    .rst_n_i       (rst_n),
    .cpu_in_trap_o (cpu_in_trap),
    .cpu_irq_o     (cpu_irq),
    .dma_irq_o     (dma_irq),
    .sram_irq_o    (sram_irq),
    .tmr_irq_o     (tmr_irq)
);

// ---------------------------------------------------------------------------
// scoreboard: DMEM byte offset 0x200 is word index 128 of the data memory
// ---------------------------------------------------------------------------
localparam integer SB_MISMATCH = 128;  // 0x200
localparam integer SB_STATUS   = 129;  // 0x204  status seen inside the handler
localparam integer SB_DMA_INT  = 130;  // 0x208
localparam integer SB_ACT_VEC  = 131;  // 0x20C
localparam integer SB_IRQ_CNT  = 132;  // 0x210
localparam integer SB_FIRST    = 133;  // 0x214
localparam integer SB_LAST     = 134;  // 0x218
localparam integer SB_DONE     = 135;  // 0x21C
localparam integer SB_IDLE     = 136;  // 0x220  status after the handler cleared it

localparam [31:0] DONE_MARKER = 32'hD05E_D01E;
localparam integer ST_DONE    = 4;     // dma_channel STATE_DONE

// source words live at DMEM 0x2100 -> word index 64
localparam integer SRC_WORD0 = 64;

integer i;
integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC system test: CPU programs the DMA, DMA fills the SRAM ==");

    // wait for the program to publish its done marker
    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 200000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        $display("      CH0_STATUS=%0d  irq_count=%0d  dma_irq=%b  cpu_irq=%b",
                 dut.dmem_inst.mem[SB_STATUS], dut.dmem_inst.mem[SB_IRQ_CNT],
                 dma_irq, cpu_irq);
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        // -- the transfer itself ------------------------------------------
        check(32'd0, dut.dmem_inst.mem[SB_MISMATCH],
              "every transferred word matches its source");
        check(32'hC0DE0000, dut.dmem_inst.mem[SB_FIRST],
              "first word of the transfer landed in the SRAM");
        check(32'hC0DE000F, dut.dmem_inst.mem[SB_LAST],
              "last word of the transfer landed in the SRAM");

        // -- read the SRAM array directly, so a symmetric addressing error
        //    on the CPU's own read path could not have masked a bad transfer
        for (i = 0; i < 16; i = i + 1)
            check(32'hC0DE0000 + i, dut.sram_inst.u_dpram.mem[i],
                  "the SRAM array itself holds the transferred word");

        // -- the DMA's own view -------------------------------------------
        check(ST_DONE, dut.dmem_inst.mem[SB_STATUS],
              "channel 0 was in STATE_DONE when the handler ran");
        check(32'd0, dut.dmem_inst.mem[SB_IDLE],
              "clearing CONTROL.enable returned the channel to STATE_IDLE");
        check(32'h1, dut.dmem_inst.mem[SB_DMA_INT],
              "DMA INT_STATUS named channel 0");

        // -- the interrupt chain ------------------------------------------
        check(32'd1, dut.dmem_inst.mem[SB_IRQ_CNT],
              "the handler ran exactly once");
        // ACTIVE_VEC is {[8] valid, [3:0] id}: in service, source 0
        check(32'h0000_0100, dut.dmem_inst.mem[SB_ACT_VEC],
              "the PIC reported source 0 in service");
        check(1'b0, {31'd0, cpu_irq},
              "the interrupt line is released after the handler");
        check(4'b0000, {28'd0, dma_irq},
              "the DMA dropped its request once the channel was cleared");
        check(1'b0, {31'd0, sram_irq},
              "no SRAM collision was raised by a clean transfer");
    end

    repeat (20) @(posedge clk);
    $display("\n=====================================================");
    if (errors == 0)
        $display("== SOC SYSTEM TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== SOC SYSTEM TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("=====================================================\n");
    $finish;
end

endmodule
