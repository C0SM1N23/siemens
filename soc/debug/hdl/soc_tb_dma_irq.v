// A masked DMA channel must raise nothing, at system level.
//
// The DMA forms its request as INT_STATUS AND INT_ENABLE. Every system program
// in this tree enables the channel's interrupt before it looks at anything, so
// every one of them checks only that an enabled channel does interrupt. A DMA
// that ignored INT_ENABLE and drove its raw status onto the line would pass all
// of them, and the fault would reach software as an interrupt storm from a
// peripheral nobody had armed.
//
// The negative case needs the whole chain open except the one link under test,
// which is what the program does: the controller has source 0 enabled, the
// core has the matching enable bit and its global enable set, and only the
// DMA's own mask is clear. Anything that arrives is therefore the DMA's fault
// and not a coincidence of some other mask being closed.
//
// Proving silence needs the event to have happened. If the transfer had simply
// failed, silence would prove nothing at all, so the program records the DMA's
// own status bit and the channel's state alongside the three "nothing came"
// observations, and the bench checks all of them together.
//
// The run then unmasks and requires the same, still-pending event to arrive
// exactly once. A design that dropped events while masked rather than holding
// them would pass the silence checks and fail here.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

module soc_tb_dma_irq;

integer errors;
`include "tb_check.vh"

wire clk, rst_n;
ck_rst_tb #(
    .CK_SEMIPERIOD(5)
) ck_rst (
    .clk_o(clk),
    .rst_n_o(rst_n)
);

wire       cpu_in_trap, cpu_irq, sram_irq, tmr_irq;
wire [3:0] dma_irq;

soc_top #(
    .RESET_PC  (32'h0000_0000),
    .IMEM_INIT ("program_dma_irq.hex"),
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
// scoreboard: DMEM byte offset 0x200 is word index 128
// ---------------------------------------------------------------------------
localparam integer SB_MISMATCH   = 128;  // 0x200
localparam integer SB_IRQ_MASKED = 129;  // 0x204
localparam integer SB_DMA_STATUS = 130;  // 0x208
localparam integer SB_PIC_SRC0   = 131;  // 0x20C
localparam integer SB_MIP        = 132;  // 0x210
localparam integer SB_CH0_STATE  = 133;  // 0x214
localparam integer SB_IRQ_AFTER  = 134;  // 0x218
localparam integer SB_ACT_VEC    = 135;  // 0x21C
localparam integer SB_DONE       = 136;  // 0x220

localparam [31:0] DONE_MARKER = 32'hD05E_D01E;
localparam integer ST_DONE    = 4;       // dma_channel STATE_DONE

// ---------------------------------------------------------------------------
// The line itself, watched continuously.
//
// The program can only sample; a request that rose and fell between two of its
// loads would be invisible to it. This counts every cycle the DMA drove its
// request while the mask was still clear, so a glitch is caught as well as a
// level.
// ---------------------------------------------------------------------------
reg        unmasked_q;
integer    irq_while_masked;
integer    cpu_irq_while_masked;

// the mask is clear until the program writes INT_ENABLE, which is the write
// that sets the DMA's enable register to a non-zero value
wire dma_int_enable_nz = |dut.dma_inst.int_enable_w[3:0];

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        unmasked_q           <= 1'b0;
        irq_while_masked     <= 0;
        cpu_irq_while_masked <= 0;
    end else begin
        if (dma_int_enable_nz)
            unmasked_q <= 1'b1;
        if (!dma_int_enable_nz && !unmasked_q) begin
            if (|dma_irq) irq_while_masked     <= irq_while_masked + 1;
            if (cpu_irq)  cpu_irq_while_masked <= cpu_irq_while_masked + 1;
        end
    end
end

integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC: a DMA channel with its interrupt masked ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 300000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        $display("      CH0_STATUS=%0d irq_masked=%0d irq_after=%0d dma_irq=%b",
                 dut.dmem_inst.mem[SB_CH0_STATE],
                 dut.dmem_inst.mem[SB_IRQ_MASKED],
                 dut.dmem_inst.mem[SB_IRQ_AFTER], dma_irq);
        // the continuous counters say whether the mask was the thing that
        // broke, which the scoreboard cannot report if the program hung
        $display("      cycles with a request while masked: DMA %0d, controller %0d",
                 irq_while_masked, cpu_irq_while_masked);
        if (irq_while_masked != 0)
            $display("      -> the DMA drove its request line with INT_ENABLE clear");
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        $display("-- the event happened --");
        check(ST_DONE, dut.dmem_inst.mem[SB_CH0_STATE],
              "the transfer completed while the channel was masked");
        check(32'h0000_0001, dut.dmem_inst.mem[SB_DMA_STATUS],
              "the DMA recorded channel 0 in its own status register");
        check(32'd0, dut.dmem_inst.mem[SB_MISMATCH],
              "every transferred word matches its source");

        $display("\n-- and nothing was raised --");
        check(32'd0, dut.dmem_inst.mem[SB_IRQ_MASKED],
              "no interrupt was taken while the channel was masked");
        check(32'd0, dut.dmem_inst.mem[SB_PIC_SRC0],
              "controller source 0 never became pending");
        check(32'd0, dut.dmem_inst.mem[SB_MIP],
              "the core saw nothing pending either");
        check(32'd0, irq_while_masked[31:0],
              "the DMA request line stayed low for every masked cycle");
        check(32'd0, cpu_irq_while_masked[31:0],
              "the controller offered nothing for every masked cycle");

        $display("\n-- unmasking delivers the event that was held --");
        check(32'd1, dut.dmem_inst.mem[SB_IRQ_AFTER],
              "exactly one interrupt arrived once the mask was lifted");
        check(32'h0000_0100, dut.dmem_inst.mem[SB_ACT_VEC],
              "the handler was entered for source 0");
    end

    $display("\n========================================");
    if (errors == 0)
        $display("== DMA INTERRUPT MASK TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== DMA INTERRUPT MASK TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

endmodule
