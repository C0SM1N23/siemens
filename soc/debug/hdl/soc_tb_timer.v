// The machine timer firing into the real core, through the controller.
//
// The timer is wired to interrupt source 7 in this system and no system program
// has ever armed it. Its compare register resets to all-ones, so it sits quiet
// through every existing run, and its own block bench reads and writes its
// registers without ever letting it fire. The whole delivery path is therefore
// untested as one piece: compare match, level output, controller source 7, the
// core's enable bit, the trap, the handler, and releasing the condition again.
//
// Releasing it is the part that needs a running core to be meaningful. The
// timer's request is the comparison itself, held as a level for as long as it
// holds, so a handler that returns without moving the compare register is
// re-entered on the next instruction and the program makes no progress. The
// bench counts claims rather than trusting the program's own counter, because a
// program stuck in a re-entry loop can still leave a plausible-looking
// scoreboard behind.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

module soc_tb_timer;

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
    .IMEM_INIT ("program_timer.hex"),
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

localparam integer SB_COUNT    = 128;  // 0x200
localparam integer SB_MCAUSE   = 129;  // 0x204
localparam integer SB_ACT_VEC  = 130;  // 0x208
localparam integer SB_MTIME    = 131;  // 0x20C
localparam integer SB_CMP      = 132;  // 0x210
localparam integer SB_ST_IN    = 133;  // 0x214
localparam integer SB_ST_AFTER = 134;  // 0x218
localparam integer SB_COUNT2   = 135;  // 0x21C
localparam integer SB_DONE     = 136;  // 0x220

localparam [31:0] DONE_MARKER = 32'hD05E_D01E;

// ---------------------------------------------------------------------------
// the line and the claims, watched directly
// ---------------------------------------------------------------------------
integer claims_of_7, tmr_high_cycles, wfi_cycles;
reg     tmr_seen_high;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        claims_of_7     <= 0;
        tmr_high_cycles <= 0;
        tmr_seen_high   <= 1'b0;
        wfi_cycles      <= 0;
    end else begin
        if (dut.pic_inst.claim_push && dut.pic_inst.claimed_id == 4'd7)
            claims_of_7 <= claims_of_7 + 1;
        if (tmr_irq) begin
            tmr_high_cycles <= tmr_high_cycles + 1;
            tmr_seen_high   <= 1'b1;
        end
        if (dut.cpu_inst.wfi_wait) wfi_cycles <= wfi_cycles + 1;
    end
end

integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC: the machine timer fires into the CPU ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 400000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        $display("      timer line high for %0d cycles, %0d claims on source 7",
                 tmr_high_cycles, claims_of_7);
        if (claims_of_7 > 1)
            $display("      -> the handler is being re-entered: the level was not released");
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        $display("-- it fired, once --");
        check(32'd1, dut.dmem_inst.mem[SB_COUNT],  "one handler entry");
        check(32'd1, dut.dmem_inst.mem[SB_COUNT2], "still one after the handler");
        check(32'd1, claims_of_7[31:0], "the controller claimed source 7 once");
        if (tmr_seen_high)
            $display("PASS: the timer really drove its line (%0d cycles)", tmr_high_cycles);
        else begin
            $display("FAIL: the timer line never went high");
            errors = errors + 1;
        end

        $display("\n-- the core saw it as the timer's source --");
        check(32'h8000_0017, dut.dmem_inst.mem[SB_MCAUSE],
              "the cause names an interrupt from source 7");
        check(32'h0000_0107, dut.dmem_inst.mem[SB_ACT_VEC],
              "the controller was serving source 7");
        check(32'h0000_0002, dut.dmem_inst.mem[SB_ST_IN] & 32'h0000_0002,
              "source 7 read as in service inside the handler");

        $display("\n-- it fired no earlier than it was told to --");
        if (dut.dmem_inst.mem[SB_MTIME] >= dut.dmem_inst.mem[SB_CMP])
            $display("PASS: the time at the trap (%0d) had reached the compare value (%0d)",
                     dut.dmem_inst.mem[SB_MTIME], dut.dmem_inst.mem[SB_CMP]);
        else begin
            $display("FAIL: fired early, time %0d against compare %0d",
                     dut.dmem_inst.mem[SB_MTIME], dut.dmem_inst.mem[SB_CMP]);
            errors = errors + 1;
        end

        $display("\n-- and moving the compare register released it --");
        check(32'd0, dut.dmem_inst.mem[SB_ST_AFTER],
              "source 7 is neither pending nor in service any more");
        check(32'd0, {31'b0, tmr_irq}, "the timer line is low at the end");
        check(32'd0, {31'b0, cpu_in_trap}, "no trap level left open");

        if (wfi_cycles > 0)
            $display("PASS: the core really slept waiting for it (%0d cycles)", wfi_cycles);
        else begin
            $display("FAIL: the core never entered its wait state");
            errors = errors + 1;
        end
    end

    $display("\n========================================");
    if (errors == 0)
        $display("== MACHINE TIMER TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== MACHINE TIMER TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

endmodule
