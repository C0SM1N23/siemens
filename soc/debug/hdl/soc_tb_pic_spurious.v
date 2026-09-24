// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// A spurious claim with the real CPU (program_spurious.s).
//
// The PIC flags a claim as spurious when the offered source is no longer
// requesting by the time the claim arrives. At block level a bench can place the
// claim anywhere; here the claim comes from the core. PIC sources 5 and 6 are
// unused in the SoC, so the bench drives the PIC's source bus directly: it raises
// source 5, waits for the edge at which the core commits to it, and withdraws
// the source one nanosecond later: the core's registered claim reaches the PIC
// one edge after that, and by then the source is gone. The handler runs for source 5 with the spurious flag set, and its
// MRET closes the nesting level like any other.
//
// Source 6 then raises and stays up until the PIC has taken its claim: a normal
// service behind the spurious one, which shows the stack, the active mask and
// the spurious flag all came back to their idle values.

`timescale 1ns / 1ps

module soc_tb_pic_spurious;

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
        .IMEM_INIT("program_spurious.hex"),
        .DMEM_INIT("")
    ) dut (
        .clk_i        (clk),
        .rst_n_i      (rst_n),
        .cpu_in_trap_o(cpu_in_trap),
        .cpu_irq_o    (cpu_irq),
        .dma_irq_o    (dma_irq),
        .sram_irq_o   (sram_irq),
        .tmr_irq_o    (tmr_irq)
    );

    localparam integer REC   = 128;  // 0x200: four words per interrupt
    localparam integer AFTER = 192;  // 0x300
    localparam integer READY = 252;  // 0x3F0
    localparam [31:0] DONE_MARKER = 32'h5B0B_5B0B;

    // sampled at an edge: the core takes source 5 there, its claim leaves next cycle
    wire commit_to_5 = dut.cpu_inst.irq_take && dut.cpu_inst.s2_advance && dut.cpu_irq_vec == 4'd5;
    wire claim_of_6 = dut.cpu_irq_ack && dut.pic_inst.cpu_irq_vec_d == 4'd6;
    integer timeout;

    initial begin
        errors = 0;
        @(posedge rst_n);
        $display("\n== SoC: a spurious claim with the real CPU ==");
        timeout = 0;
        while (dut.dmem_inst.mem[READY] !== 32'd1 && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        // source 5 up; withdrawn as soon as the core has committed to it
        @(posedge clk);
        #1 force dut.pic_src = 16'h0020;
        timeout = 0;
        while (!commit_to_5 && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        check(1, commit_to_5, "the core committed to source 5");
        #1 force dut.pic_src = 16'h0000;
        repeat (2) @(posedge clk);  // the claim is registered, then taken
        #1;
        check(1, dut.pic_inst.spurious_log[5], "the claim of source 5 was spurious");
        check(1, dut.pic_inst.spurious[5], "source 5 is marked spurious while in service");

        // the handler returns; source 6 up until the PIC takes its claim
        timeout = 0;
        while (!(dut.dmem_inst.mem[REC] !== 32'd0 && dut.pic_inst.depth == 5'd0) && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        #1 force dut.pic_src = 16'h0040;
        timeout = 0;
        while (!claim_of_6 && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        check(1, claim_of_6, "the core claimed source 6");
        @(posedge clk);  // the PIC takes the claim at this edge
        #1 force dut.pic_src = 16'h0000;

        timeout = 0;
        while (dut.dmem_inst.mem[AFTER+4] !== DONE_MARKER && timeout < 50000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        release dut.pic_src;

        if (dut.dmem_inst.mem[AFTER+4] !== DONE_MARKER) begin
            errors = errors + 1;
            $display("FAIL: the program never reached its end marker");
        end else begin
            $display("-- Spurious service of source 5 --");
            check(32'h8000_0015, dut.dmem_inst.mem[REC+0], "mcause = interrupt 16 + 5");
            check(32'h0000_0020, dut.dmem_inst.mem[REC+1], "SPURIOUS_LOG shows source 5");
            check(32'h1, dut.dmem_inst.mem[REC+2] & 32'h1, "INT_STATUS.SPUR set");
            check(32'h0000_0501, dut.dmem_inst.mem[REC+3], "NEST_STATUS: depth 1, top source 5");
            $display("\n-- Normal service of source 6 behind it --");
            check(32'h8000_0016, dut.dmem_inst.mem[REC+4], "mcause = interrupt 16 + 6");
            check(32'h0000_0601, dut.dmem_inst.mem[REC+7], "NEST_STATUS: depth 1, top source 6");
            $display("\n-- Controller idle again --");
            check(32'd0, dut.dmem_inst.mem[AFTER+0] & 32'h0000_0F1F, "NEST_STATUS: empty stack");
            check(32'h20, dut.dmem_inst.mem[AFTER+1], "SPURIOUS_LOG sticky until cleared");
            check(32'd0, dut.dmem_inst.mem[AFTER+2], "SPURIOUS_LOG cleared by W1C");
            check(32'd2, dut.dmem_inst.mem[AFTER+3], "two interrupts taken");
            check(32'd0, {dut.pic_inst.depth, dut.pic_inst.active, dut.pic_inst.spurious},
                  "no depth, no active source, no spurious flag");
        end

        if (errors == 0) $display("== PIC SPURIOUS TESTBENCH: ALL TESTS PASSED ==");
        else $display("== PIC SPURIOUS TESTBENCH: %0d FAILURE(S) ==", errors);
        finish_test;
    end

endmodule
