// All four DMA channels, contending, under round-robin arbitration.
//
// Every system-level run in this tree drives channel 0 with the scheduler in
// fixed-priority mode. Channels 1 to 3 and the round-robin path are covered
// only in the DMA's own block bench, which means nothing in the assembled
// system says a channel other than the first can reach the fabric: a descriptor
// fetch that ignored the channel index, a register decode that aliased the
// upper channels onto the lower one, or an arbiter that never moved its grant
// would all leave the existing runs passing.
//
// The program starts all four at once, each moving its own pattern into its own
// quarter of the dual-port memory, and compares each quarter against its own
// source. That is what separates "the transfers happened" from "channel 2 moved
// channel 2's bytes".
//
// The bench measures the arbitration itself, because the program cannot see it.
// Two things have to be true for the run to mean what it claims: every channel
// must have been granted, and the grant must have moved between channels rather
// than one channel finishing before the next was allowed to start. A run in
// which the four transfers were serialised would produce identical memory
// contents and prove nothing about the arbiter, so it is treated as a failure.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

module soc_tb_dma_channels;

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
    .IMEM_INIT ("program_dma_ch.hex"),
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

localparam integer SB_MISM0   = 128;  // 0x200 .. 0x20C, one per channel
localparam integer SB_INT_ST  = 132;  // 0x210
localparam integer SB_ST0     = 133;  // 0x214 .. 0x220, one per channel
localparam integer SB_DONE    = 137;  // 0x224

localparam [31:0] DONE_MARKER = 32'hD05E_D01E;
localparam integer ST_DONE    = 4;

// ---------------------------------------------------------------------------
// the grant, watched directly
//
// The arbiter issues a one-cycle grant pulse per burst and the top level latches
// which channel owns the bus, so the two things worth counting are how many
// bursts each channel won and how often ownership moved.
// ---------------------------------------------------------------------------
wire [3:0] gnt_pulse = dut.dma_inst.ch_gnt;
wire [3:0] owner     = dut.dma_inst.active_master_ch;

integer grants_of [0:3];
integer grant_changes;          // ownership moved from one channel to another
reg [3:0] owner_prev;
integer i;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0; i < 4; i = i + 1) grants_of[i] <= 0;
        grant_changes <= 0;
        owner_prev    <= 4'b0;
    end else begin
        for (i = 0; i < 4; i = i + 1)
            if (gnt_pulse[i]) grants_of[i] <= grants_of[i] + 1;
        if (owner != 4'b0 && owner_prev != 4'b0 && owner != owner_prev)
            grant_changes <= grant_changes + 1;
        owner_prev <= owner;
    end
end

integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC: four DMA channels under round-robin arbitration ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 400000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        for (i = 0; i < 4; i = i + 1)
            $display("      channel %0d: state=%0d, granted %0d times",
                     i, dut.dmem_inst.mem[SB_ST0 + i], grants_of[i]);
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        $display("-- every channel finished --");
        for (i = 0; i < 4; i = i + 1)
            check(ST_DONE, dut.dmem_inst.mem[SB_ST0 + i],
                  "this channel reported STATE_DONE");
        check(32'h0000_000F, dut.dmem_inst.mem[SB_INT_ST],
              "all four channels are set in the DMA status register");

        $display("\n-- and each one moved its own bytes --");
        for (i = 0; i < 4; i = i + 1)
            check(32'd0, dut.dmem_inst.mem[SB_MISM0 + i],
                  "no mismatched word for this channel");

        // read the memory array directly: a symmetric addressing fault on the
        // CPU's own read path could otherwise hide a wrongly placed transfer
        $display("\n-- read straight out of the memory array --");
        for (i = 0; i < 4; i = i + 1) begin
            check(32'hC0DE0000 | (i << 12), dut.sram_inst.u_dpram.mem[i*8],
                  "first word of this channel's quarter");
            check(32'hC0DE0007 | (i << 12), dut.sram_inst.u_dpram.mem[i*8 + 7],
                  "last word of this channel's quarter");
        end

        $display("\n-- the arbiter actually arbitrated --");
        for (i = 0; i < 4; i = i + 1) begin
            if (grants_of[i] > 0)
                $display("PASS: channel %0d was granted the bus %0d times",
                         i, grants_of[i]);
            else begin
                $display("FAIL: channel %0d was never granted the bus", i);
                errors = errors + 1;
            end
        end
        if (grant_changes > 0)
            $display("PASS: the grant moved between channels %0d times", grant_changes);
        else begin
            $display("FAIL: the grant never moved, so the transfers were serialised");
            errors = errors + 1;
        end
    end

    $display("\n========================================");
    if (errors == 0)
        $display("== DMA CHANNEL TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== DMA CHANNEL TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

endmodule
