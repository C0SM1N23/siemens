// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// The CPU and the DMA writing the same words at the same time (program_same_addr.s).
//
// Phase 1, DMEM, checked strictly: the arbiter puts one master's write after the
// other's, so every destination word must end as the last write the memory
// received, whole - never a mix of the two patterns.
//
// Phases 2 and 3, the dual-port SRAM: when both ports write one word in the same
// cycle, the SRAM's FORCE_PRIORITY picks the winner and answers the loser SLVERR.
// Checked: a collision happens in both phases; every SLVERR the SRAM gives the
// CPU becomes exactly one precise store access fault; a DMA burst with a refused
// beat is answered SLVERR, so the channel ends in ERROR instead of reporting a
// transfer it did not make; and the winner of each phase is never refused.
//
// With both memories at full speed the CPU's stores and the DMA's beats move on
// the same two-cycle rhythm and never meet on one cycle, so the instruction
// memory stalls at random here (fixed seed) to make the two drift.

`timescale 1ns / 1ps

module soc_tb_same_addr #(
    parameter IMEM_STALL_PROB = 25,
    parameter IMEM_SEED       = 5
);

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
        .IMEM_INIT("program_same_addr.hex"),
        .DMEM_INIT(""),
        .IMEM_STALL_PROB(IMEM_STALL_PROB),
        .IMEM_SEED(IMEM_SEED)
    ) dut (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .cpu_in_trap_o(cpu_in_trap),
        .cpu_irq_o    (cpu_irq),
        .dma_irq_o    (dma_irq),
        .sram_irq_o   (sram_irq),
        .tmr_irq_o    (tmr_irq)
    );

    localparam integer SB    = 128;  // 0x200
    localparam integer DST   = 192;  // 0x300: phase-1 destination, 8 words
    localparam integer PHASE = 133;  // 0x214
    localparam [31:0] DONE_MARKER = 32'h5A3E_5A3E;
    localparam [31:0] CPU_WORD = 32'hC0C0_C0C0;
    localparam integer SD_SRAM = 1, SX_SRAM = 1;

    wire [1:0] phase = dut.dmem_inst.mem[PHASE][1:0];

    // Phase 1: the last write each destination word received at the memory.
    reg [31:0] last[0:7];
    integer cpu_wrote, dma_wrote, i;
    wire [10:0] widx = dut.dmem_inst.wr_idx;
    always @(posedge clk) begin
        if (rst_n && phase == 2'd1 && dut.dmem_inst.do_write && widx >= DST && widx < DST + 8) begin
            last[widx-DST] = dut.dmem_inst.wr_data;  // full-word stores from both masters
            if (dut.arb_dmem.gnt[0]) cpu_wrote = cpu_wrote + 1;
            else dma_wrote = dma_wrote + 1;
        end
    end

    // Phases 2 and 3: collisions and what each master was told.
    integer ww[0:3], cpu_slverr[0:3], dma_slverr[0:3], dma_burst_err[0:3];
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.sram_inst.collision_det_inst.is_wr_wr) ww[phase] = ww[phase] + 1;
            if (dut.d_bvalid[SD_SRAM] && dut.d_bready[SD_SRAM] && dut.d_bresp[SD_SRAM*2+:2] == 2'b10)
                cpu_slverr[phase] = cpu_slverr[phase] + 1;
            if (dut.x_bvalid[SX_SRAM] && dut.x_bready[SX_SRAM] && dut.x_bresp[SX_SRAM*2+:2] == 2'b10)
                dma_slverr[phase] = dma_slverr[phase] + 1;
            if (dut.dmam_bvalid && dut.dmam_bready && dut.dmam_bresp != 2'b00)
                dma_burst_err[phase] = dma_burst_err[phase] + 1;
        end
    end

    integer timeout;
    initial begin
        errors = 0;
        cpu_wrote = 0;
        dma_wrote = 0;
        for (i = 0; i < 4; i = i + 1) begin
            ww[i] = 0; cpu_slverr[i] = 0; dma_slverr[i] = 0; dma_burst_err[i] = 0;
        end
        timeout = 0;
        @(posedge rst_n);
        $display("\n== SoC: two masters writing the same words ==");
        while (dut.dmem_inst.mem[SB+6] !== DONE_MARKER && timeout < 400000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (dut.dmem_inst.mem[SB+6] !== DONE_MARKER) begin
            errors = errors + 1;
            $display("FAIL: the program never reached its end marker");
        end else begin
            $display("-- Phase 1: DMEM, serialised by the arbiter --");
            check(1, cpu_wrote > 0 && dma_wrote > 0, "both masters wrote the destination words");
            for (i = 0; i < 8; i = i + 1) begin
                check(last[i], dut.dmem_inst.mem[DST+i], "word holds the last write it received");
                check(1, dut.dmem_inst.mem[DST+i] == CPU_WORD || dut.dmem_inst.mem[DST+i] == 32'hD0A0_0000 + i,
                      "word is one master's value, whole");
            end
            check(4, dut.dmem_inst.mem[SB+0], "the transfer completed");

            $display("\n-- Phases 2 and 3: SRAM collisions --");
            check(dut.dmem_inst.mem[SB+2], cpu_slverr[2], "phase 2: one store fault per refused CPU store");
            check(dut.dmem_inst.mem[SB+4], cpu_slverr[3], "phase 3: one store fault per refused CPU store");
            check(1, ww[2] > 0 && ww[3] > 0, "write/write collisions occurred in both phases");
            check(0, cpu_slverr[2], "phase 2: the CPU wins, no CPU store refused");
            check(1, dma_slverr[2] > 0 && dma_burst_err[2] > 0, "phase 2: the refused DMA beat fails its burst");
            check(5, dut.dmem_inst.mem[SB+1], "phase 2: the channel ends in ERROR");
            check(0, dma_slverr[3] + dma_burst_err[3], "phase 3: the DMA wins, no DMA beat refused");
            check(1, cpu_slverr[3] > 0, "phase 3: the CPU store was refused");
            check(4, dut.dmem_inst.mem[SB+3], "phase 3: the transfer completed");
            $display("   phase 1: %0d CPU and %0d DMA writes reached the words", cpu_wrote, dma_wrote);
            $display("   phase 2 (CPU wins): %0d collisions, DMA state %0d, %0d refused DMA beats, %0d CPU faults",
                     ww[2], dut.dmem_inst.mem[SB+1], dma_slverr[2], dut.dmem_inst.mem[SB+2]);
            $display("   phase 3 (DMA wins): %0d collisions, DMA state %0d, %0d refused DMA beats, %0d CPU faults",
                     ww[3], dut.dmem_inst.mem[SB+3], dma_slverr[3], dut.dmem_inst.mem[SB+4]);
        end
        if (errors == 0) $display("== SAME-ADDRESS TESTBENCH: ALL TESTS PASSED ==");
        else $display("== SAME-ADDRESS TESTBENCH: %0d FAILURE(S) ==", errors);
        finish_test;
    end

endmodule
