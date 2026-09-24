// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// Sixteen nested interrupts through the real CPU (program_pic_deep.s).
//
// Sixteen is the documented maximum on both sides: the PIC's nesting stack and
// the core's trap-kind stack, which tells an interrupt return (EOI) from an
// exception return. The program climbs from source 0 to source 15, each level
// preempting the one below, and unwinds. The bench checks the order of entry
// and exit, the depth seen at every level, that both stacks reached sixteen,
// that each claim was matched by exactly one EOI, and that both stacks are
// empty again at the end.

`timescale 1ns / 1ps

module soc_tb_pic_deep_nest;

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
        .IMEM_INIT("program_pic_deep.hex"),
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

    localparam integer ENTRY = 128;  // 0x200
    localparam integer EXIT  = 192;  // 0x300
    localparam integer AFTER = 224;  // 0x380
    localparam [31:0] DONE_MARKER = 32'hDEE9_DEE9;

    integer claims, eois, pic_max, cpu_max;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            claims  <= 0;
            eois    <= 0;
            pic_max <= 0;
            cpu_max <= 0;
        end else begin
            if (dut.cpu_irq_ack) claims <= claims + 1;
            if (dut.cpu_irq_eoi) eois <= eois + 1;
            if (dut.pic_inst.depth > pic_max) pic_max <= dut.pic_inst.depth;
            if (dut.cpu_inst.trap_depth_q > cpu_max) cpu_max <= dut.cpu_inst.trap_depth_q;
        end
    end

    integer i, timeout;

    initial begin
        errors  = 0;
        timeout = 0;
        @(posedge rst_n);
        $display("\n== SoC: sixteen nested interrupts ==");
        while (dut.dmem_inst.mem[AFTER+3] !== DONE_MARKER && timeout < 200000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (dut.dmem_inst.mem[AFTER+3] !== DONE_MARKER) begin
            errors = errors + 1;
            $display("FAIL: the program never reached its end marker");
        end else begin
            $display("-- Climb: source n entered at depth n + 1 --");
            for (i = 0; i < 16; i = i + 1) begin
                check(i, dut.dmem_inst.mem[ENTRY+2*i], "entry order");
                check(i + 1, dut.dmem_inst.mem[ENTRY+2*i+1], "depth on entry");
            end
            $display("\n-- Unwind: innermost first --");
            for (i = 0; i < 16; i = i + 1) check(15 - i, dut.dmem_inst.mem[EXIT+i], "exit order");
            $display("\n-- Both stacks --");
            check(32'd16, pic_max, "PIC stack reached sixteen");
            check(32'd16, cpu_max, "core trap-kind stack reached sixteen");
            check(32'd16, claims, "sixteen claims");
            check(32'd16, eois, "sixteen EOIs, one per claim");
            check(32'd0, dut.dmem_inst.mem[AFTER] & 32'h1F, "NEST_STATUS depth zero at the end");
            check(32'd0, {dut.pic_inst.depth, dut.pic_inst.active, dut.cpu_inst.trap_depth_q},
                  "both stacks empty, no source active");
        end

        if (errors == 0) $display("== PIC DEEP NESTING TESTBENCH: ALL TESTS PASSED ==");
        else $display("== PIC DEEP NESTING TESTBENCH: %0d FAILURE(S) ==", errors);
        finish_test;
    end

endmodule
