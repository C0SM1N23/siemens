// Preemption and nesting, driven by the real core rather than by a driver.
//
// The controller's own bench drives the claim and end-of-interrupt pulses
// itself, one cycle after the offer, at moments it chooses. That is the right
// way to reach the corners, and it is also the reason a system-level version is
// needed: none of it says the mechanism still works when the pulses come from a
// core that answers at its own instruction boundaries, that clears its global
// interrupt enable on entry, and that has a handler doing real bus work in
// between.
//
// Three things have to hold together for nesting to work here, and each one
// belongs to a different block: the core has to accept a second interrupt while
// the first handler is running, the controller has to offer only a strictly
// more urgent source, and the end-of-interrupt pulse has to release exactly one
// level. A system run is the only place all three are in the loop at once.
//
// The bench watches the depth continuously as well as reading what the handlers
// recorded, because the interesting value is one the program can only sample
// from inside itself: if the depth ever went past two, or the second claim
// replaced the first level instead of stacking on it, the recorded values could
// still look right.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

module soc_tb_pic_nest;

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
    .IMEM_INIT ("program_pic_nest.hex"),
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
// scoreboard
// ---------------------------------------------------------------------------
localparam integer SB_ENTRIES    = 128;  // 0x200
localparam integer SB_VEC_OUTER  = 129;  // 0x204
localparam integer SB_DEPTH_OUT  = 130;  // 0x208
localparam integer SB_VEC_INNER  = 131;  // 0x20C
localparam integer SB_DEPTH_IN   = 132;  // 0x210
localparam integer SB_DEPTH_BACK = 133;  // 0x214
localparam integer SB_DEPTH_END  = 134;  // 0x218
localparam integer SB_CNT_OUTER  = 135;  // 0x21C
localparam integer SB_CNT_INNER  = 136;  // 0x220
localparam integer SB_DONE       = 137;  // 0x224

localparam [31:0] DONE_MARKER = 32'hD05E_D01E;

// ---------------------------------------------------------------------------
// continuous observation of the nesting stack
// ---------------------------------------------------------------------------
wire [4:0] depth   = dut.pic_inst.depth;
wire       claim   = dut.pic_inst.claim_push;
wire [3:0] claim_id = dut.pic_inst.claimed_id;
wire       eoi     = dut.pic_inst.eoi_pop;

integer max_depth;
integer claims, eois;
integer claim_of_8, claim_of_9;
integer depth_jump;          // the depth moved by more than one in a cycle
reg [4:0] depth_prev;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        max_depth  <= 0;
        claims     <= 0;
        eois       <= 0;
        claim_of_8 <= 0;
        claim_of_9 <= 0;
        depth_jump <= 0;
        depth_prev <= 5'd0;
    end else begin
        if (depth > max_depth[4:0]) max_depth <= {27'b0, depth};
        if (claim) begin
            claims <= claims + 1;
            if (claim_id == 4'd8) claim_of_8 <= claim_of_8 + 1;
            if (claim_id == 4'd9) claim_of_9 <= claim_of_9 + 1;
        end
        if (eoi) eois <= eois + 1;
        depth_prev <= depth;
        if ((depth > depth_prev && depth - depth_prev > 5'd1) ||
            (depth_prev > depth && depth_prev - depth > 5'd1))
            depth_jump <= depth_jump + 1;
    end
end

integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC: interrupt preemption and nesting through the CPU ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 300000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        $display("      entries=%0d depth now=%0d max depth=%0d claims=%0d eois=%0d",
                 dut.dmem_inst.mem[SB_ENTRIES], depth, max_depth, claims, eois);
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        $display("-- the outer handler --");
        check(32'h0000_0109, dut.dmem_inst.mem[SB_VEC_OUTER],
              "entered for the less urgent source");
        check(32'd1, dut.dmem_inst.mem[SB_DEPTH_OUT],
              "one level open while it runs");

        $display("\n-- preempted from inside it --");
        check(32'h0000_0108, dut.dmem_inst.mem[SB_VEC_INNER],
              "the inner handler is the more urgent source");
        check(32'd2, dut.dmem_inst.mem[SB_DEPTH_IN],
              "two levels open: the second claim stacked, not replaced");
        check(32'd2, max_depth[31:0],
              "the depth reached two and never went past it");

        $display("\n-- and unwound one level at a time --");
        check(32'd1, dut.dmem_inst.mem[SB_DEPTH_BACK],
              "back to one level once the inner handler returned");
        check(32'd0, dut.dmem_inst.mem[SB_DEPTH_END],
              "back to none once the outer handler returned");
        check(32'd0, depth_jump[31:0],
              "the depth only ever moved one level at a time");

        $display("\n-- the accounting balances --");
        check(32'd2, dut.dmem_inst.mem[SB_ENTRIES], "two handler entries");
        check(32'd1, dut.dmem_inst.mem[SB_CNT_OUTER],
              "the less urgent source was serviced once");
        check(32'd1, dut.dmem_inst.mem[SB_CNT_INNER],
              "the more urgent source was serviced once");
        check(32'd2, claims[31:0], "two claims reached the controller");
        check(32'd2, eois[31:0],   "two end-of-interrupt pulses came back");
        check(32'd1, claim_of_9[31:0], "one claim named the less urgent source");
        check(32'd1, claim_of_8[31:0], "one claim named the more urgent source");
        check(32'd0, {31'b0, cpu_in_trap}, "no trap level left open at the end");
    end

    $display("\n========================================");
    if (errors == 0)
        $display("== PIC NESTING TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== PIC NESTING TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

endmodule
