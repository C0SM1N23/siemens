// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// DMA transfers that meet error responses (program_dma_fault.s).
//
// Two kinds of result come out of this run, and they are kept apart.
//
// The fabric contract is checked strictly, beat by beat, whatever the DMA does:
// every burst beat whose address lies outside the DMA's two windows (DMEM and
// the SRAM) is answered DECERR by the DMA decoder and reaches no slave, every
// beat inside them reaches its slave and returns its response unchanged, a burst
// the bridge refuses is answered SLVERR on every beat without a single Lite
// transaction, the write response of a burst is the worst of its beats, and the
// PIC configuration and IMEM - both outside the DMA's map - never change. Each
// case must also produce the situation it exists for.
//
// The DMA channel's own reaction - the state it ends in, whether it stops after
// an error, whether a failing channel leaves the other one alone - is the DMA
// block's contract. It is compared with the documented behaviour and reported;
// a difference is recorded in TO_MODIFY.md and does not fail this bench.

`timescale 1ns / 1ps
`include "soc_addr_map.vh"

module soc_tb_dma_fault;

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
        .IMEM_INIT("program_dma_fault.hex"),
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

    localparam integer SB      = 128;  // 0x200
    localparam integer SB_CASE = 252;  // 0x3F0
    localparam [31:0] DONE_MARKER = 32'hFA17_ED0E;
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10, DECERR = 2'b11;
    localparam integer DONE = 4, ERROR = 5;

    function dma_mapped;  // the DMA decoder's two windows
        input [31:0] a;
        dma_mapped = ((a & `SOC_DMEM_MASK) == `SOC_DMEM_BASE) || ((a & `SOC_SRAM_MASK) == `SOC_SRAM_BASE);
    endfunction

    wire [3:0] case_id = dut.dmem_inst.mem[SB_CASE][3:0];

    // Per-case beat counters on the bridge's Full side (what the DMA sees).
    integer r_ok[0:8], r_dec[0:8], r_slv[0:8], b_err[0:8], lite_ar[0:8], lite_aw[0:8];
    integer bad_beat;  // a response that contradicts the address map
    integer i;
    reg [1:0] lite_worst;
    reg       w_refused;  // the write burst in progress was refused by the bridge

    wire bridge_run_r = dut.bridge_inst.r_state == 2'd1;
    wire full_r_hs = dut.bridge_inst.s_rvalid_o && dut.bridge_inst.s_rready_i;
    wire full_b_hs = dut.bridge_inst.s_bvalid_o && dut.bridge_inst.s_bready_i;
    wire lite_r_hs = dut.xl_rvalid && dut.xl_rready;
    wire lite_b_hs = dut.xl_bvalid && dut.xl_bready;
    wire lite_ar_hs = dut.xl_arvalid && dut.xl_arready;
    wire lite_aw_hs = dut.xl_awvalid && dut.xl_awready;

    always @(posedge clk or negedge rst_n) begin : count
        if (~rst_n) begin
            for (i = 0; i <= 8; i = i + 1) begin
                r_ok[i] = 0; r_dec[i] = 0; r_slv[i] = 0; b_err[i] = 0; lite_ar[i] = 0; lite_aw[i] = 0;
            end
            bad_beat   = 0;
            lite_worst = OKAY;
            w_refused  = 1'b0;
        end else begin
            if (dut.bridge_inst.write_start) w_refused = !dut.bridge_inst.aw_supported;
            if (full_r_hs) begin
                if (dut.bridge_inst.s_rresp_o == OKAY) r_ok[case_id] = r_ok[case_id] + 1;
                if (dut.bridge_inst.s_rresp_o == DECERR) r_dec[case_id] = r_dec[case_id] + 1;
                if (dut.bridge_inst.s_rresp_o == SLVERR) r_slv[case_id] = r_slv[case_id] + 1;
                // a beat the bridge fetched: its response follows the address map
                if (bridge_run_r && dut.bridge_inst.s_rresp_o != (dma_mapped(dut.bridge_inst.r_addr) ? OKAY : DECERR)) begin
                    bad_beat = bad_beat + 1;
                    $display("FAIL: read beat at 0x%08h answered %0d", dut.bridge_inst.r_addr, dut.bridge_inst.s_rresp_o);
                end
                // a refused burst: SLVERR, data zero
                if (!bridge_run_r && (dut.bridge_inst.s_rresp_o != SLVERR || dut.bridge_inst.s_rdata_o != 0))
                    bad_beat = bad_beat + 1;
            end
            if (lite_b_hs) begin
                if (dut.xl_bresp != (dma_mapped(dut.bridge_inst.w_addr) ? OKAY : DECERR)) begin
                    bad_beat = bad_beat + 1;
                    $display("FAIL: write beat at 0x%08h answered %0d", dut.bridge_inst.w_addr, dut.xl_bresp);
                end
                if (dut.xl_bresp > lite_worst) lite_worst = dut.xl_bresp;
            end
            if (full_b_hs) begin
                if (dut.bridge_inst.s_bresp_o != OKAY) b_err[case_id] = b_err[case_id] + 1;
                // the burst's response is the worst of its beats, SLVERR if refused
                if (dut.bridge_inst.s_bresp_o != (w_refused ? SLVERR : lite_worst)) begin
                    bad_beat = bad_beat + 1;
                    $display("FAIL: write burst answered %0d, worst beat %0d", dut.bridge_inst.s_bresp_o, lite_worst);
                end
                lite_worst = OKAY;
            end
            if (lite_ar_hs) lite_ar[case_id] = lite_ar[case_id] + 1;
            if (lite_aw_hs) lite_aw[case_id] = lite_aw[case_id] + 1;
        end
    end

    // Nothing the DMA does may reach a slave outside its windows.
    integer stray;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) stray <= 0;
        else if ((|dut.x_awvalid && !dma_mapped(dut.xl_awaddr)) || (|dut.x_arvalid && !dma_mapped(dut.xl_araddr)))
            stray <= stray + 1;
    end

    reg [31:0] pic_cfg0, imem_word;
    integer timeout, notes;

    task observe;  // DMA-block behaviour: reported, recorded, not a failure
        input [31:0] expected, got;
        input [511:0] what;
        begin
            if (expected === got) begin
                if ($test$plusargs("verbose")) $display("DMA: %0s = %0d, as documented", what, got);
            end else begin
                notes = notes + 1;
                $display("DMA NOTE: %0s: documented %0d, observed %0d (DMA block, see TO_MODIFY.md)",
                         what, expected, got);
            end
        end
    endtask

    initial begin
        errors  = 0;
        notes   = 0;
        timeout = 0;
        @(posedge rst_n);
        pic_cfg0  = dut.pic_inst.src_config[0];
        imem_word = dut.imem_inst.mem[64];  // byte address 0x100
        $display("\n== SoC: DMA transfers that meet error responses ==");

        while (dut.dmem_inst.mem[SB+12] !== DONE_MARKER && timeout < 800000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (dut.dmem_inst.mem[SB+12] !== DONE_MARKER) begin
            errors = errors + 1;
            $display("FAIL: the program never reached its end marker (%0d cycles)", timeout);
        end else begin
            $display("-- Responses follow the address map --");
            check(32'd0, bad_beat, "every beat answered as its address dictates");
            check(32'd0, stray, "no request reached a slave outside the DMA's windows");
            check(pic_cfg0, dut.pic_inst.src_config[0], "PIC SRC0_CONFIG unchanged");
            check(imem_word, dut.imem_inst.mem[64], "IMEM word unchanged");

            $display("\n-- Each case produced its situation --");
            check(32'd1, {31'b0, r_dec[1] > 0}, "1: unmapped source answered DECERR");
            check(32'd1, {31'b0, r_dec[2] > 0 && r_ok[2] > 8}, "2: one burst with OKAY and DECERR beats");
            check(32'd1, {31'b0, r_dec[3] > 0 && lite_aw[3] == 0}, "3: descriptor fetch answered DECERR");
            check(32'd1, {31'b0, b_err[4] > 0}, "4: write towards the PIC answered DECERR");
            check(32'd1, {31'b0, b_err[5] > 0}, "5: write towards IMEM answered DECERR");
            check(32'd1, {31'b0, r_slv[6] > 0}, "6: unaligned burst refused with SLVERR");
            check(32'd8, lite_ar[6], "6: only the descriptor fetch reached the bus");
            check(32'd1, {31'b0, r_dec[7] > 0 && r_ok[7] > 0}, "7: one channel failing beside another");
            check(32'd0, r_dec[8] + r_slv[8] + b_err[8], "8: the clean transfer saw no error");

            $display("\n-- DMA channel behaviour (observed) --");
            observe(ERROR, dut.dmem_inst.mem[SB+0], "1: final state, unmapped source");
            observe(ERROR, dut.dmem_inst.mem[SB+1], "2: final state, source past the window");
            observe(ERROR, dut.dmem_inst.mem[SB+2], "3: final state, unmapped descriptor");
            observe(ERROR, dut.dmem_inst.mem[SB+3], "4: final state, destination PIC");
            observe(ERROR, dut.dmem_inst.mem[SB+4], "5: final state, destination IMEM");
            observe(ERROR, dut.dmem_inst.mem[SB+5], "6: final state, unaligned source");
            observe(DONE, dut.dmem_inst.mem[SB+6], "7: final state, channel 0");
            observe(ERROR, dut.dmem_inst.mem[SB+8], "7: final state, channel 1");
            observe(DONE, dut.dmem_inst.mem[SB+7], "8: final state after the failures");
            observe(0, dut.dmem_inst.mem[SB+9], "7: channel 0 words that differ");
            observe(0, dut.dmem_inst.mem[SB+10], "8: words that differ");
            observe(16, dut.dmem_inst.mem[SB+11], "1, 2: destination words left untouched");
            observe(0, lite_aw[1] + lite_aw[2], "1, 2: write beats after the failed read");
            $display("   %0d DMA observation(s) differ from the documented behaviour", notes);
        end

        if (errors == 0) $display("== DMA FAULT TESTBENCH: ALL TESTS PASSED ==");
        else $display("== DMA FAULT TESTBENCH: %0d FAILURE(S) ==", errors);
        finish_test;
    end

endmodule
