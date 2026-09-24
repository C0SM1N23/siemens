// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// Asynchronous reset of the whole SoC while transactions are in flight
// (program_reset.s, restarted by every reset).
//
// Six resets, each taken at a moment the regression otherwise never resets in:
//   1  a DMA write burst half-way through its beats
//   2  a DMA read burst half-way through its beats
//   3  a CPU load held off by the data memory for several cycles
//   4  a DECERR read response the CPU has not taken yet
//   5  the data-memory arbiter holding a grant with a write response owed
//   6  a DMA write burst in flight with the clock stopped high
// Reset is asserted between clock edges. One nanosecond later - before any edge,
// and in case 6 with no clock at all - every request and response valid of the
// CPU, the fabric, the memories, the PIC and the timer must already be low and
// the fabric's routing state empty. After reset, no port may see a response to
// a request made before it. The program restarts each time and the last run
// must complete normally: DMA transfer done and exact, data-memory traffic
// intact, one start counted per reset.
//
// The DMA and SRAM outputs are reported the same way but, being those blocks'
// own reset behaviour, do not fail the bench (TO_MODIFY.md).

`timescale 1ns / 1ps
`include "soc_addr_map.vh"

module soc_tb_reset_traffic;

    integer errors;
    `include "tb_check.vh"

    reg clk = 1'b0;
    reg clk_run = 1'b1;
    reg rst_n = 1'b0;
    always #5 if (clk_run) clk = ~clk;

    wire cpu_in_trap, cpu_irq, sram_irq, tmr_irq;
    wire [3:0] dma_irq;

    soc_top #(
        .RESET_PC (32'h0000_0000),
        .IMEM_INIT("program_reset.hex"),
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

    localparam integer SB    = 128;  // 0x200
    localparam integer BOOTS = 255;  // 0x3FC
    localparam [31:0] DONE_MARKER = 32'h0DD5_EED5;
    localparam integer SD_SRAM = 1, SD_PIC = 2, SD_TMR = 3, SD_DMA = 4, SX_SRAM = 1;

    integer resets, notes, timeout;

    // After a reset no response may answer a request made before it: count what
    // each master has outstanding, from zero at every reset.
    integer ib_r, db_r, db_b, full_r, full_b;
    always @(posedge clk or negedge rst_n) begin : orphans
        if (~rst_n) begin
            ib_r <= 0; db_r <= 0; db_b <= 0; full_r <= 0; full_b <= 0;
        end else begin
            ib_r <= ib_r + (dut.ibus_arvalid && dut.ibus_arready) - (dut.ibus_rvalid && dut.ibus_rready);
            db_r <= db_r + (dut.dbus_arvalid && dut.dbus_arready) - (dut.dbus_rvalid && dut.dbus_rready);
            db_b <= db_b + (dut.dbus_awvalid && dut.dbus_awready) - (dut.dbus_bvalid && dut.dbus_bready);
            full_r <= full_r + (dut.dmam_arvalid && dut.dmam_arready)
                    - (dut.dmam_rvalid && dut.dmam_rready && dut.dmam_rlast);
            full_b <= full_b + (dut.dmam_awvalid && dut.dmam_awready) - (dut.dmam_bvalid && dut.dmam_bready);
            if ((dut.ibus_rvalid && ib_r == 0) || (dut.dbus_rvalid && db_r == 0) || (dut.dbus_bvalid && db_b == 0)
                || (dut.dmam_rvalid && full_r == 0) || (dut.dmam_bvalid && full_b == 0)) begin
                errors = errors + 1;
                $display("FAIL: a response with no request outstanding at %0t", $time);
            end
        end
    end

    task observe;  // DMA and SRAM reset behaviour: reported, not a failure
        input [31:0] got;
        input [511:0] what;
        begin
            if (got !== 0) begin
                notes = notes + 1;
                $display("NOTE: %0s still high in reset (%0h), see TO_MODIFY.md", what, got);
            end
        end
    endtask

    // Everything of ours is quiet while reset is asserted, with or without a clock.
    task check_quiet;
        begin
            check(0, {dut.ibus_arvalid, dut.dbus_awvalid, dut.dbus_wvalid, dut.dbus_arvalid},
                  "CPU requests low in reset");
            check(0, {dut.ibus_rvalid, dut.dbus_bvalid, dut.dbus_rvalid}, "responses to the CPU low in reset");
            check(0, {dut.d_awvalid, dut.d_wvalid, dut.d_arvalid}, "data decoder towards slaves low");
            check(0, {dut.x_awvalid, dut.x_wvalid, dut.x_arvalid}, "DMA decoder towards slaves low");
            check(0, {dut.imem_arvalid, dut.imem_rvalid}, "instruction memory quiet");
            check(0, {dut.xl_awvalid, dut.xl_wvalid, dut.xl_arvalid, dut.xl_bvalid, dut.xl_rvalid},
                  "bridge Lite side quiet");
            // AXI leaves READY free during reset; only the VALIDs must be low.
            check(0, {dut.dmam_bvalid, dut.dmam_rvalid}, "bridge Full-side responses low");
            check(0, {dut.dmem_awvalid, dut.dmem_wvalid, dut.dmem_arvalid, dut.dmem_bvalid, dut.dmem_rvalid},
                  "data memory and its arbiter quiet");
            check(0, {dut.d_bvalid[SD_PIC], dut.d_rvalid[SD_PIC], dut.d_bvalid[SD_TMR], dut.d_rvalid[SD_TMR]},
                  "PIC and timer responses low");
            check(0, {dut.dec_d.wr_addr_valid_q, dut.dec_d.wr_data_valid_q, dut.dec_d.rd_addr_valid_q,
                      dut.dec_d.err_bvalid, dut.dec_d.err_rvalid, dut.dec_x.wr_addr_valid_q,
                      dut.dec_x.wr_data_valid_q, dut.dec_x.rd_addr_valid_q, dut.dec_i.rd_addr_valid_q},
                  "decoders hold no route");
            check(0, {dut.arb_dmem.gnt, dut.bridge_inst.r_state, dut.bridge_inst.w_state},
                  "arbiter and bridge idle");
            check(0, {cpu_irq, dut.cpu_inst.cpu_irq_ack_o, dut.cpu_inst.cpu_irq_eoi_o}, "no interrupt handshake");
            observe({dut.dmam_awvalid, dut.dmam_wvalid, dut.dmam_arvalid}, "DMA master request");
            observe({dut.d_bvalid[SD_DMA], dut.d_rvalid[SD_DMA]}, "DMA register-port response");
            observe({dut.d_bvalid[SD_SRAM], dut.d_rvalid[SD_SRAM], dut.x_bvalid[SX_SRAM], dut.x_rvalid[SX_SRAM]},
                    "SRAM response");
        end
    endtask

    // Assert reset 2 ns after the edge that met the condition, check, hold three
    // cycles, release 1 ns after an edge.
    task reset_now;
        input [511:0] what;
        begin
            #2;
            rst_n = 1'b0;
            #1;
            $display("\n-- reset: %0s --", what);
            check_quiet;
            release dut.dmem_arready;
            release dut.dbus_rready;
            release dut.dmem_bvalid;
            repeat (3) @(posedge clk);
            #1;
            rst_n  = 1'b1;
            resets = resets + 1;
        end
    endtask

    task wait_for_start;  // the restarted program has counted its start
        begin
            timeout = 0;
            while (dut.dmem_inst.mem[BOOTS] != resets + 1 && timeout < 100000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
        end
    endtask

    task missed;
        input [511:0] what;
        begin
            errors = errors + 1;
            $display("FAIL: the program never reached the moment for: %0s", what);
        end
    endtask

    integer held;

    initial begin
        errors = 0;
        notes  = 0;
        resets = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        $display("\n== SoC: asynchronous reset with transactions in flight ==");

        // 1. a DMA write burst half-way through
        timeout = 0;
        while (!(dut.bridge_inst.w_state == 2'd1 && dut.bridge_inst.w_beat == 8'd3) && timeout < 200000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 200000) missed("write burst");
        reset_now("DMA write burst, beat 3 of 8");

        // 2. a DMA read burst half-way through
        wait_for_start;
        timeout = 0;
        while (!(dut.bridge_inst.r_state == 2'd1 && dut.bridge_inst.r_beat == 8'd2) && timeout < 200000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 200000) missed("read burst");
        reset_now("DMA read burst, beat 2 of 8");

        // 3. a CPU load held off by the data memory
        wait_for_start;
        repeat (40) @(posedge clk);
        #1 force dut.dmem_arready = 1'b0;
        held    = 0;
        timeout = 0;
        while (held < 4 && timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
            held = (dut.dbus_arvalid && !dut.dbus_arready && ((dut.dbus_araddr & `SOC_DMEM_MASK) == `SOC_DMEM_BASE))
                 ? held + 1 : 0;
        end
        if (held < 4) missed("stalled load");
        reset_now("CPU load stalled by the data memory");

        // 4. a DECERR the CPU has not taken
        wait_for_start;
        timeout = 0;
        while (!(dut.dbus_arvalid && dut.dbus_arready && dut.dbus_araddr == 32'h5000_0000) && timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        #1 force dut.dbus_rready = 1'b0;
        repeat (3) @(posedge clk);
        if (!(dut.dec_d.err_rvalid && dut.dbus_rvalid)) missed("unread DECERR");
        reset_now("DECERR response not yet taken");

        // 5. the arbiter holding a grant with a write response owed
        wait_for_start;
        timeout = 0;
        while (!(dut.dmem_awvalid && dut.dmem_awready) && timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        #1 force dut.dmem_bvalid = 1'b0;
        repeat (3) @(posedge clk);
        if (!(|dut.arb_dmem.gnt && dut.arb_dmem.aw_taken_q)) missed("held grant");
        reset_now("arbiter grant held, write response owed");

        // 6. a DMA write burst with the clock stopped high
        wait_for_start;
        timeout = 0;
        while (!(dut.bridge_inst.w_state == 2'd1 && dut.bridge_inst.w_beat == 8'd5) && timeout < 200000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 200000) missed("write burst, clock stopped");
        #1 clk_run = 1'b0;  // clk stays high
        #20 rst_n = 1'b0;
        #1;
        $display("\n-- reset: DMA write burst, clock stopped --");
        check_quiet;
        #20;
        check(1, clk, "no clock edge while stopped");
        check_quiet;
        clk_run = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        rst_n  = 1'b1;
        resets = resets + 1;

        // the last run completes normally
        timeout = 0;
        while (dut.dmem_inst.mem[SB+4] !== DONE_MARKER && timeout < 400000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        $display("\n-- after the last reset --");
        if (dut.dmem_inst.mem[SB+4] !== DONE_MARKER) begin
            errors = errors + 1;
            $display("FAIL: the restarted program never finished (%0d cycles)", timeout);
        end else begin
            check(32'd7, dut.dmem_inst.mem[SB+3], "one start per reset, plus the first");
            check(32'd4, dut.dmem_inst.mem[SB+0], "DMA transfer done");
            check(32'd0, dut.dmem_inst.mem[SB+1], "every transferred word exact");
            check(32'd5, dut.dmem_inst.mem[SB+2], "unmapped load still a precise fault");
        end
        $display("   %0d DMA/SRAM reset observation(s)", notes);

        if (errors == 0) $display("== RESET UNDER TRAFFIC TESTBENCH: ALL TESTS PASSED ==");
        else $display("== RESET UNDER TRAFFIC TESTBENCH: %0d FAILURE(S) ==", errors);
        finish_test;
    end

endmodule
