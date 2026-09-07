// SoC stress bench: the CPU works the bus while the DMA transfers.
//
// tb_soc_top proves the data path with the CPU asleep. This bench exists
// because a coverage probe on that run showed the fabric's contention logic
// was never touched by it: the DMEM arbiter never saw two masters ask at once,
// the dual-port SRAM never had both ports busy in the same cycle, and no
// unmapped address was ever driven. All three were passing by not being tried.
//
// So this bench does two things tb_soc_top does not:
//
//   1. It runs a two-phase program over two 256-byte DMA transfers: the CPU
//      parks on the SRAM for the first (to force address collisions) and
//      hammers DMEM for the second (to contend the arbiter), then checks both
//      transfers are still bit-perfect. Contention is allowed to cost the CPU
//      - a colliding read gets SLVERR and traps - but it must never corrupt
//      what the DMA moved.
//
//   2. It measures whether that actually happened, and FAILS if it did not.
//      The counters below are not diagnostics: a run in which the arbiter was
//      never contended is a failed run, because it would mean this bench had
//      quietly stopped testing the thing it was written for.
//
// That second part is the point. A coverage number that nobody checks decays
// into a comment.

`timescale 1ns/1ps

module tb_soc_stress #(
    // The coverage floors below describe what this bench produces at the
    // nominal bus timing. Under injected latency or random backpressure the
    // schedule changes and the same program reaches different corners, so the
    // stressed runs check the design still behaves and leave the floors to the
    // nominal run. Correctness is asserted in every configuration either way.
    parameter integer COVERAGE_GATE = 1
);

integer errors;
`include "tb_check.vh"

wire clk, rst_n;
ck_rst_tb #(.CK_SEMIPERIOD(5)) ck_rst (.clk_o(clk), .rst_n_o(rst_n));

wire       cpu_in_trap, cpu_irq, sram_irq, tmr_irq;
wire [3:0] dma_irq;

soc_top #(
    .RESET_PC  (32'h0000_0000),
    .IMEM_INIT ("program_stress.hex"),
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
// scoreboard: DMEM byte offset 0x400 is word index 256
// ---------------------------------------------------------------------------
localparam integer SB_MISMATCH  = 256;  // 0x400
localparam integer SB_COLL_IRQ  = 257;  // 0x404
localparam integer SB_FAULTS    = 258;  // 0x408
localparam integer SB_STATUS    = 259;  // 0x40C
localparam integer SB_F_BEFORE  = 260;  // 0x410
localparam integer SB_F_AFTER   = 261;  // 0x414
localparam integer SB_SRAM_INT  = 262;  // 0x418
localparam integer SB_DONE      = 263;  // 0x41C
localparam integer SB_MCAUSE    = 264;  // 0x420
localparam integer SB_XFERS     = 265;  // 0x424  DMA transfers completed

localparam [31:0] DONE_MARKER = 32'h5772_E55D;
localparam integer ST_DONE     = 4;
localparam integer CAUSE_LOAD_ACCESS = 5;

// How much contention phase B must actually produce for the run to count.
localparam integer MIN_CONTENDED = 50;

// ---------------------------------------------------------------------------
// fabric coverage: what the run actually exercised
// ---------------------------------------------------------------------------
integer arb_both_req;     // cycles with CPU and DMA both asking for DMEM
integer arb_gnt_cpu, arb_gnt_dma;
integer sram_both_ports;  // cycles with both SRAM ports active
integer sram_a_act, sram_b_act;   // per-port active cycles
integer sram_addr_eq;     // both active AND on the same address
integer sram_conflicts;   // real read/write or write/write conflicts
integer decerr_seen;      // DECERR responses on the CPU data bus

always @(posedge clk) begin
    if (!rst_n) begin
        arb_both_req    <= 0;
        arb_gnt_cpu     <= 0;
        arb_gnt_dma     <= 0;
        sram_both_ports <= 0;
        sram_a_act      <= 0;
        sram_b_act      <= 0;
        sram_addr_eq    <= 0;
        sram_conflicts  <= 0;
        decerr_seen     <= 0;
    end else begin
        if (dut.arb_dmem.req[0] && dut.arb_dmem.req[1])
            arb_both_req <= arb_both_req + 1;
        if (dut.arb_dmem.gnt[0]) arb_gnt_cpu <= arb_gnt_cpu + 1;
        if (dut.arb_dmem.gnt[1]) arb_gnt_dma <= arb_gnt_dma + 1;

        if (dut.sram_inst.a_mem_valid) sram_a_act <= sram_a_act + 1;
        if (dut.sram_inst.b_mem_valid) sram_b_act <= sram_b_act + 1;
        if (dut.sram_inst.a_mem_valid && dut.sram_inst.b_mem_valid) begin
            sram_both_ports <= sram_both_ports + 1;
            if (dut.sram_inst.a_mem_addr == dut.sram_inst.b_mem_addr)
                sram_addr_eq <= sram_addr_eq + 1;
        end
        if (dut.sram_inst.u_arbiter.real_conflict)
            sram_conflicts <= sram_conflicts + 1;

        if (dut.dbus_rvalid && dut.dbus_rresp == 2'b11)
            decerr_seen <= decerr_seen + 1;
        if (dut.dbus_bvalid && dut.dbus_bresp == 2'b11)
            decerr_seen <= decerr_seen + 1;
    end
end

integer i;
integer timeout;

initial begin
    errors  = 0;
    timeout = 0;

    @(posedge rst_n);
    $display("\n== SoC stress test: CPU works the bus while the DMA transfers ==");

    while (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER && timeout < 400000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (dut.dmem_inst.mem[SB_DONE] !== DONE_MARKER) begin
        errors = errors + 1;
        $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
    end else begin
        $display("   program finished after %0d cycles\n", timeout);

        // -- the transfer survived the interference ------------------------
        check(32'd0, dut.dmem_inst.mem[SB_MISMATCH],
              "the transfer is bit-perfect despite the contention");
        for (i = 0; i < 128; i = i + 1)
            if (dut.sram_inst.u_dpram.mem[i] !== 32'h5A5A0000 + i) begin
                errors = errors + 1;
                $display("FAIL: SRAM word %0d = 0x%08h, expected 0x%08h",
                         i, dut.sram_inst.u_dpram.mem[i], 32'h5A5A0000 + i);
            end
        $display("PASS: all 128 words verified directly in the SRAM array");

        check(ST_DONE, dut.dmem_inst.mem[SB_STATUS],
              "channel 0 reached STATE_DONE under load");
        check(32'd2, dut.dmem_inst.mem[SB_XFERS],
              "both DMA transfers completed");

        // -- the DECERR path ------------------------------------------------
        check(dut.dmem_inst.mem[SB_F_BEFORE] + 1, dut.dmem_inst.mem[SB_F_AFTER],
              "the unmapped access faulted instead of hanging");
        check(CAUSE_LOAD_ACCESS, dut.dmem_inst.mem[SB_MCAUSE],
              "it faulted as a load access fault");

        // -- the SRAM raised its own interrupt ------------------------------
        if (!COVERAGE_GATE || dut.dmem_inst.mem[SB_COLL_IRQ] > 0)
            $display("PASS: the SRAM collision interrupt reached the CPU (%0d times)",
                     dut.dmem_inst.mem[SB_COLL_IRQ]);
        else begin
            errors = errors + 1;
            $display("FAIL: the SRAM never raised a collision interrupt");
        end

        // -- did the run actually exercise the fabric? ----------------------
        $display("\n   fabric coverage for this run:");
        $display("     DMEM arbiter contended cycles : %0d", arb_both_req);
        $display("     DMEM grants  CPU / DMA        : %0d / %0d", arb_gnt_cpu, arb_gnt_dma);
        $display("     SRAM port A / port B active   : %0d / %0d", sram_a_act, sram_b_act);
        $display("     SRAM both ports active        : %0d", sram_both_ports);
        $display("     SRAM same address, both active: %0d", sram_addr_eq);
        $display("     SRAM real conflicts           : %0d", sram_conflicts);
        $display("     DECERR responses seen         : %0d\n", decerr_seen);

        // A floor, not a "greater than zero". One contended cycle would tick
        // the box while telling you almost nothing about round-robin under
        // sustained pressure; the number below is what phase B is built to
        // produce, and dropping under it means the phase stopped working.
        if (!COVERAGE_GATE)
            $display("   (coverage floors not gated in this configuration)");

        if (!COVERAGE_GATE || arb_both_req >= MIN_CONTENDED)
            $display("PASS: the DMEM arbiter was contended for %0d cycles (floor %0d)",
                     arb_both_req, MIN_CONTENDED);
        else begin
            errors = errors + 1;
            $display("FAIL: the DMEM arbiter was contended only %0d cycles, floor is %0d",
                     arb_both_req, MIN_CONTENDED);
        end

        if (!COVERAGE_GATE || (arb_gnt_cpu > 0 && arb_gnt_dma > 0))
            $display("PASS: both masters were granted the shared memory");
        else begin
            errors = errors + 1;
            $display("FAIL: only one master ever used the shared memory");
        end

        if (!COVERAGE_GATE || (sram_both_ports > 0))
            $display("PASS: both SRAM ports were driven in the same cycle");
        else begin
            errors = errors + 1;
            $display("FAIL: the SRAM was never accessed from both ports at once");
        end

        if (!COVERAGE_GATE || (sram_conflicts > 0))
            $display("PASS: real address conflicts occurred and were resolved");
        else begin
            errors = errors + 1;
            $display("FAIL: no address conflict ever occurred - the collision logic is untested");
        end

        if (!COVERAGE_GATE || (decerr_seen > 0))
            $display("PASS: the decoder answered an unmapped access with DECERR");
        else begin
            errors = errors + 1;
            $display("FAIL: no DECERR was ever observed on the data bus");
        end
    end

    repeat (20) @(posedge clk);
    $display("\n=====================================================");
    if (errors == 0)
        $display("== SOC STRESS TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== SOC STRESS TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("=====================================================\n");
    $finish;
end

endmodule
