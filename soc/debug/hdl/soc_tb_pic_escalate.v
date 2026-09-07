// Deadline escalation changing which handler the CPU enters first.
//
// The controller escalates a source that has waited longer than its deadline,
// moving it to a more urgent band so it stops losing to its neighbours. The
// controller's own bench proves that by watching the offer change. What it
// cannot show is the thing the feature exists for: that a real processor
// services the escalated source first.
//
// The service order is the proof. Slot 8 sits in band 1 and slot 9 in band 3,
// so slot 8 outranks slot 9 and would be entered first. Only slot 9 carries a
// deadline. Both are raised while the core's global interrupt enable is still
// clear, which leaves slot 9 waiting long enough to miss it. If the escalation
// works the core enters slot 9's handler first; if it does not, slot 8's.
//
// The bench checks the controller's own view as well as the program's, because
// the two can disagree in a way that matters: the effective band moving without
// the offer following it, or the offer changing without the flag being set,
// would each leave one of the two views looking right.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

module soc_tb_pic_escalate;

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
    .IMEM_INIT ("program_pic_esc.hex"),
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

localparam integer SB_FIRST   = 128;  // 0x200
localparam integer SB_SECOND  = 129;  // 0x204
localparam integer SB_ST9     = 130;  // 0x208
localparam integer SB_ST8     = 131;  // 0x20C
localparam integer SB_INT_ST  = 132;  // 0x210
localparam integer SB_ENTRIES = 133;  // 0x214
localparam integer SB_DONE    = 134;  // 0x218

localparam [31:0] DONE_MARKER = 32'hD05E_D01E;

// ---------------------------------------------------------------------------
// the order the controller actually claimed them in
// ---------------------------------------------------------------------------
integer claim_seq [0:3];
integer claim_n;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        claim_n <= 0;
    end else if (dut.pic_inst.claim_push && claim_n < 4) begin
        claim_seq[claim_n] <= {28'b0, dut.pic_inst.claimed_id};
        claim_n <= claim_n + 1;
    end
end

integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC: deadline escalation changes the service order ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 400000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        $display("      entries=%0d, claims seen=%0d",
                 dut.dmem_inst.mem[SB_ENTRIES], claim_n);
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        $display("-- the escalation happened while both were waiting --");
        check(32'h0000_0004, dut.dmem_inst.mem[SB_ST9] & 32'h0000_0004,
              "the waiting source records that it escalated");
        check(32'h0000_0000, dut.dmem_inst.mem[SB_ST9] & 32'h0000_0030,
              "its effective band moved to the target band");
        check(32'h0000_0002, dut.dmem_inst.mem[SB_INT_ST] & 32'h0000_0002,
              "and the global escalation flag is set");

        $display("\n-- its neighbour was left alone --");
        check(32'h0000_0000, dut.dmem_inst.mem[SB_ST8] & 32'h0000_0004,
              "the source without a deadline did not escalate");
        check(32'h0000_0010, dut.dmem_inst.mem[SB_ST8] & 32'h0000_0030,
              "and its effective band is still the one configured");

        $display("\n-- so the order the CPU serviced them in was reversed --");
        check(32'h0000_0109, dut.dmem_inst.mem[SB_FIRST],
              "the escalated source was entered first");
        check(32'h0000_0108, dut.dmem_inst.mem[SB_SECOND],
              "the nominally more urgent one came second");
        check(32'd2, dut.dmem_inst.mem[SB_ENTRIES], "two handler entries");

        $display("\n-- and the controller claimed them in that order too --");
        check(32'd2, claim_n[31:0], "two claims in total");
        check(32'd9, claim_seq[0][31:0], "the first claim named the escalated source");
        check(32'd8, claim_seq[1][31:0], "the second named the other one");
        check(32'd0, {31'b0, cpu_in_trap}, "no trap level left open");
    end

    $display("\n========================================");
    if (errors == 0)
        $display("== PIC ESCALATION TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== PIC ESCALATION TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

endmodule
