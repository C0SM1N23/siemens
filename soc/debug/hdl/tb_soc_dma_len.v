// SoC bench for DMA transfer lengths that do not divide into whole 32-byte
// bursts. Runs program_dma_len.s.
//
// The other two system benches move 64 and 256 bytes, both exact multiples of
// the DMA's 32-byte burst, so neither one ever makes the channel issue a short
// final burst. That is the case where a DMA writes past the end of what it was
// asked to move, and it was unreachable from the SoC tests until this bench.
//
// The program runs five transfers - 64, 40, 20, 8 and 4 bytes - each into its
// own 128-byte slot of the SRAM, over a destination area filled with a guard
// word beforehand. This bench reads the SRAM array directly rather than
// trusting a value the program read back, so a symmetric addressing error on
// the CPU's own read path cannot hide a bad transfer.
//
// Two things are checked per slot, and they fail for opposite reasons:
//   - every word inside the requested length equals its source word, so a
//     transfer that stops early is caught
//   - every word after it still holds the guard, so a transfer that runs long
//     is caught, and the report says how far past the end it went
//
// The protocol assertions cannot catch either one. A burst with the wrong
// length is still a well-formed burst: AWLEN and the beat count agree with each
// other, they just do not agree with the descriptor. Only the data shows it.

`timescale 1ns/1ps

module tb_soc_dma_len;

integer errors;
`include "tb_check.vh"

wire clk, rst_n;
ck_rst_tb #(.CK_SEMIPERIOD(5)) ck_rst (.clk_o(clk), .rst_n_o(rst_n));

wire       cpu_in_trap, cpu_irq, sram_irq, tmr_irq;
wire [3:0] dma_irq;

soc_top #(
    .RESET_PC  (32'h0000_0000),
    .IMEM_INIT ("program_dma_len.hex"),
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
// what the program was asked to do
// ---------------------------------------------------------------------------
localparam integer NSLOT      = 5;
localparam integer SLOT_WORDS = 32;            // 128 bytes per slot
localparam [31:0]  GUARD      = 32'hBADD_0000;
localparam [31:0]  SRC_BASE   = 32'hC0DE_0000;

// DMEM byte 0x400 is word index 256
localparam integer SB_DONE     = 256;
localparam [31:0]  DONE_MARKER = 32'hD05E_D01E;

// lengths in bytes, slot 0 first; must match the table in program_dma_len.s
integer len_bytes [0:NSLOT-1];

integer s, i, w, words, timeout;
integer over, short_ct, first_over;

initial begin
    errors  = 0;
    timeout = 0;

    len_bytes[0] = 64;
    len_bytes[1] = 40;
    len_bytes[2] = 20;
    len_bytes[3] = 8;
    len_bytes[4] = 4;

    @(posedge rst_n);
    $display("\n== SoC DMA transfer lengths: 64, 40, 20, 8, 4 bytes ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 400000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        $display("      CH0_STATUS=%0d  dma_irq=%b", dut.dmem_inst.mem[SB_DONE], dma_irq);
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        for (s = 0; s < NSLOT; s = s + 1) begin
            words      = len_bytes[s] / 4;
            over       = 0;
            short_ct   = 0;
            first_over = -1;

            // inside the requested length: must be the source data
            for (i = 0; i < words; i = i + 1) begin
                w = s*SLOT_WORDS + i;
                if (dut.sram_inst.u_dpram.mem[w] !== (SRC_BASE + i))
                    short_ct = short_ct + 1;
            end

            // after it: must still be the guard, all the way to the slot end
            for (i = words; i < SLOT_WORDS; i = i + 1) begin
                w = s*SLOT_WORDS + i;
                if (dut.sram_inst.u_dpram.mem[w] !== GUARD) begin
                    over = over + 1;
                    if (first_over < 0) first_over = i;
                end
            end

            $display("   %0d bytes (%0d words): %0d word(s) wrong inside, %0d past the end",
                     len_bytes[s], words, short_ct, over);

            if (short_ct != 0) begin
                errors = errors + 1;
                $display("FAIL: %0d-byte transfer did not deliver %0d word(s)",
                         len_bytes[s], short_ct);
            end
            if (over != 0) begin
                errors = errors + 1;
                $display("FAIL: %0d-byte transfer wrote %0d word(s) past the end, from byte %0d",
                         len_bytes[s], over, first_over*4);
            end
        end

        $display("");
        check(1'b0, {31'd0, sram_irq}, "no SRAM collision was raised");
        check(4'b0000, {28'd0, dma_irq},
              "the DMA dropped every request once its channel was cleared");
    end

    repeat (20) @(posedge clk);
    $display("\n=====================================================");
    if (errors == 0)
        $display("== SOC DMA LENGTH TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== SOC DMA LENGTH TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("=====================================================\n");
    $finish;
end

endmodule
