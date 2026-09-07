// All sixteen interrupt sources are reachable from the CPU.
//
// The system wires eight of the controller's sixteen slots: the DMA on 0 to 3,
// the dual-port memory on 4, the machine timer on 7. Slots 5, 6 and 8 to 15 are
// tied low. Every system-level run so far has therefore exercised at most half
// the range, and the half it never touched is the half where an index one bit
// too narrow, a vector output truncated somewhere in the fabric, or an enable
// mask that stops at bit 8 would live. All three would look identical to a
// working system from any existing test.
//
// The program raises each slot in turn through its software trigger channel and
// records the source number the controller reported. The bench checks the
// recorded numbers, and separately counts the claims the controller actually
// made per slot, so a run in which two slots collapsed onto one number cannot
// pass by having the right total.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

module soc_tb_pic_sources;

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
    .IMEM_INIT ("program_pic_src.hex"),
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

// scoreboard: 0x200 is word index 128
localparam integer SB_VEC0    = 128;      // 0x200 .. 0x23C, sixteen words
localparam integer SB_ENTRIES = 144;      // 0x240
localparam integer SB_DEPTH   = 145;      // 0x244
localparam integer SB_DONE    = 146;      // 0x248

localparam [31:0] DONE_MARKER = 32'hD05E_D01E;

// ---------------------------------------------------------------------------
// claims counted per slot, straight off the controller
// ---------------------------------------------------------------------------
integer claims_of [0:15];
integer total_claims;
integer i;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0; i < 16; i = i + 1) claims_of[i] <= 0;
        total_claims <= 0;
    end else if (dut.pic_inst.claim_push) begin
        claims_of[dut.pic_inst.claimed_id] <= claims_of[dut.pic_inst.claimed_id] + 1;
        total_claims <= total_claims + 1;
    end
end

integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC: every interrupt source reaches the CPU ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 400000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        $display("      handler entries so far = %0d, claims = %0d",
                 dut.dmem_inst.mem[SB_ENTRIES], total_claims);
        for (i = 0; i < 16; i = i + 1)
            if (claims_of[i] == 0)
                $display("      slot %0d was never claimed", i);
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        $display("-- the handler was entered for the right source, sixteen times --");
        for (i = 0; i < 16; i = i + 1)
            check(32'h0000_0100 | i, dut.dmem_inst.mem[SB_VEC0 + i],
                  "the source number the handler read back");

        $display("\n-- and the controller claimed each slot exactly once --");
        for (i = 0; i < 16; i = i + 1)
            check(32'd1, claims_of[i][31:0], "claims on this slot");

        $display("");
        check(32'd16, dut.dmem_inst.mem[SB_ENTRIES], "sixteen handler entries");
        check(32'd16, total_claims[31:0], "sixteen claims in total");
        check(32'd0, dut.dmem_inst.mem[SB_DEPTH],
              "every level was released again");
        check(32'd0, {31'b0, cpu_in_trap}, "no trap level left open at the end");
    end

    $display("\n========================================");
    if (errors == 0)
        $display("== PIC SOURCE RANGE TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== PIC SOURCE RANGE TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

endmodule
