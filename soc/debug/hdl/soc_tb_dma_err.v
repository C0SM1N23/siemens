// A DMA burst that meets an error response part way through, in the real SoC.
//
// The bridge folds the responses of a burst's beats into one, worst case first,
// so a transfer that failed part way cannot report success to the DMA. That
// fold is checked exhaustively at block level. What no system run has ever done
// is produce the situation: every error response any of them sees comes from a
// request the bridge refuses before touching the bus, and the DMA has never
// been aimed anywhere that could answer with one.
//
// The memory's decode window is exactly the size of the memory behind it, so a
// transfer aimed at its last words has some beats land and the rest miss every
// window. That is an overrun, which is what a descriptor one segment too long
// produces in practice, and it puts a real error response inside a real burst
// with the real DMA on the other end of it.
//
// Two opposite things have to hold afterwards. The channel must end in its error
// state rather than reporting the transfer complete - that is the fold doing its
// job - and the beats that were inside the window must still have been written,
// which says the bridge finished the burst instead of abandoning it. The bench
// also counts the error responses on the bridge's own slave side, so a run in
// which the address unexpectedly resolved somewhere valid is a failure rather
// than a silent pass.
//
// A clean transfer into the same memory runs first, so a failure here means
// "this address fails" and not "this memory never worked".
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

module soc_tb_dma_err;

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
    .IMEM_INIT ("program_dma_err.hex"),
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

localparam integer SB_ST_GOOD = 128;  // 0x200
localparam integer SB_MISM    = 129;  // 0x204
localparam integer SB_ST_BAD  = 130;  // 0x208
localparam integer SB_FIRST   = 131;  // 0x20C
localparam integer SB_LAST    = 132;  // 0x210
localparam integer SB_DONE    = 133;  // 0x214

localparam [31:0] DONE_MARKER = 32'hD05E_D01E;
localparam integer ST_DONE    = 4;
localparam integer ST_ERROR   = 5;

// ---------------------------------------------------------------------------
// the responses the bridge collected, and the one it produced
// ---------------------------------------------------------------------------
localparam [1:0] RESP_OKAY = 2'b00;

integer lite_err_beats;      // beats the fabric answered with an error
integer full_err_bursts;     // bursts the bridge reported as failed
integer full_ok_bursts;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        lite_err_beats  <= 0;
        full_err_bursts <= 0;
        full_ok_bursts  <= 0;
    end else begin
        if (dut.bridge_inst.m_bvalid_i && dut.bridge_inst.m_bready_o &&
            dut.bridge_inst.m_bresp_i !== RESP_OKAY)
            lite_err_beats <= lite_err_beats + 1;
        if (dut.bridge_inst.s_bvalid_o && dut.bridge_inst.s_bready_i) begin
            if (dut.bridge_inst.s_bresp_o !== RESP_OKAY)
                full_err_bursts <= full_err_bursts + 1;
            else
                full_ok_bursts <= full_ok_bursts + 1;
        end
    end
end

integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC: a DMA burst that overruns its window ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 400000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        $display("      clean run state=%0d, overrun state=%0d",
                 dut.dmem_inst.mem[SB_ST_GOOD], dut.dmem_inst.mem[SB_ST_BAD]);
        $display("      error beats on the fabric=%0d, failed bursts=%0d",
                 lite_err_beats, full_err_bursts);
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        $display("-- the same memory works when the transfer fits --");
        check(ST_DONE, dut.dmem_inst.mem[SB_ST_GOOD],
              "the clean transfer completed");
        check(32'd0, dut.dmem_inst.mem[SB_MISM],
              "and every word of it matched");

        $display("\n-- the overrunning burst really did meet an error --");
        if (lite_err_beats > 0)
            $display("PASS: %0d beats were answered with an error response",
                     lite_err_beats);
        else begin
            $display("FAIL: no beat was ever answered with an error");
            errors = errors + 1;
        end
        check(32'd1, full_err_bursts[31:0],
              "exactly one burst was reported to the DMA as failed");

        $display("\n-- and the DMA was told, rather than reporting success --");
        check(ST_ERROR, dut.dmem_inst.mem[SB_ST_BAD],
              "the channel ended in its error state");

        $display("\n-- while the beats inside the window still landed --");
        check(32'hBAD00000, dut.dmem_inst.mem[SB_FIRST],
              "the first in-window word was written");
        check(32'hBAD00003, dut.dmem_inst.mem[SB_LAST],
              "the last in-window word was written");
        // The memory's data region starts at word 8 of its window, and the
        // block subtracts that offset before indexing its array, so window word
        // 252 is array entry 244. The array is declared with 256 entries and
        // only 248 of them are reachable; that is a property of the memory
        // block, recorded separately, and the indices here follow the block as
        // it is rather than as it will be.
        check(32'hBAD00000, dut.sram_inst.u_dpram.mem[244],
              "and the memory array itself holds it");
        check(32'hBAD00003, dut.sram_inst.u_dpram.mem[247],
              "up to the last word the window covers");
    end

    $display("\n========================================");
    if (errors == 0)
        $display("== DMA BURST ERROR TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== DMA BURST ERROR TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

endmodule
