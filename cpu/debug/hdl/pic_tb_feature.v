// Dedicated testbench for the advanced-scheduling PIC (hdl/pic.v).
//
// The system bench (tb_cpu_axi) drives the PIC through the real CPU and covers
// the integrated path (priority, masking, suppression, WFI wake). This bench
// exercises the PIC as a standalone IP over its AXI4-Lite port + source/CPU
// pins, so every feature the brief calls out gets a directed test:
//
//   1  reset defaults + a basic level interrupt (enable, offer, claim, eoi)
//   2  custom priority grouping: inter-band, intra-band, lowest-index tie
//   3  preemption with nesting: a higher source preempts, eoi restores context
//   4  NEST_MAX enforcement + overflow flag
//   5  spurious detection (source drops before the claim) + SPURIOUS_LOG W1C
//   6  deadline-aware escalation (jump-to-band) flips the offer
//   7  software triggers: keyed set, key guard, auto-clear on claim, clear
//   8  edge-triggered source latching
//   9  AXI responses: SLVERR on unmapped read + read-only write, OKAY otherwise
//  10  a source re-banded while active keeps its claimed priority (grouping Q4)
//  11  escalation drives preemption of an already-active lower source
//  12  bump + multi escalation walks the effective band up
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow (compile.do, run 6
// of regress.do).

`timescale 1ns/1ps

module tb_pic;

// ---- register map (byte offsets) ----
localparam CFG0 = 32'h00, SWT0 = 32'h40, STA0 = 32'h80;
localparam BAND_CONFIG   = 32'hC0, NEST_STATUS = 32'hC4, NEST_MAX_R  = 32'hC8,
           ACTIVE_VEC    = 32'hCC, SPURIOUS_LOG = 32'hD0, ESCALATION  = 32'hD4,
           INT_ENABLE    = 32'hD8, INT_STATUS   = 32'hDC;
localparam RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;
localparam SW_KEY = 16'hA5A5;

// ---- clock / reset ----
reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

// ---- DUT source / CPU pins ----
reg  [15:0] irq_src;
reg         cpu_irq_ack, cpu_irq_eoi;
wire        cpu_irq;
wire [3:0]  cpu_irq_vec;

// ---- AXI4-Lite master side ----
reg  [31:0] awaddr, wdata, araddr;
reg  [3:0]  wstrb;
reg         awvalid, wvalid, bready, arvalid, rready;
wire        awready, wready, bvalid, arready, rvalid;
wire [1:0]  bresp, rresp;
wire [31:0] rdata;

integer errors = 0;
reg [31:0] rd;                 // scratch for reads
`include "tb_check.vh"
`include "tb_axil_master.vh"

wire [15:0] pic_pending;
pic dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .irq_src_i(irq_src),
    .cpu_mask_i(16'hFFFF),          // no CPU-side mask in the standalone bench
    .cpu_irq_o(cpu_irq), .cpu_irq_vec_o(cpu_irq_vec), .pending_o(pic_pending),
    .cpu_irq_ack_i(cpu_irq_ack), .cpu_irq_eoi_i(cpu_irq_eoi),
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(3'b0), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(3'b0), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready)
);

// ---------------------------------------------------------------------------
// AXI4-Lite master access. The driver itself lives in tb_axil_master.vh, shared
// with the block-level register benches, so all five benches drive the slave
// exactly the same way and a change to the protocol handling happens once.
// These two names are kept because the stimulus below reads better with them.
// ---------------------------------------------------------------------------
task axi_write(input [31:0] a, input [31:0] d, input [1:0] exp);
    begin
        axil_write(a, d, exp);
    end
endtask

task axi_read(input [31:0] a, input [1:0] exp);   // result in `rd`
    begin
        axil_read(a, exp);
    end
endtask

// ---------------------------------------------------------------------------
// interrupt-handshake helpers
// ---------------------------------------------------------------------------
task wait_offer(input [3:0] ev);
    integer to;
    begin
        to = 0;
        while (!(cpu_irq === 1'b1 && cpu_irq_vec === ev) && to < 60) begin
            @(posedge clk); to = to + 1;
        end
        if (!(cpu_irq === 1'b1 && cpu_irq_vec === ev)) begin
            $display("FAIL: no offer for src %0d (cpu_irq=%b vec=%0d)", ev, cpu_irq, cpu_irq_vec);
            errors = errors + 1;
        end
    end
endtask

task no_offer_for(input [3:0] nev, input [511:0] msg);   // 64 chars, same as check
    begin  // cpu_irq must not currently present nev
        if (cpu_irq === 1'b1 && cpu_irq_vec === nev) begin
            $display("FAIL: %0s (src %0d unexpectedly offered)", msg, nev);
            errors = errors + 1;
        end else
            $display("PASS: %0s", msg);
    end
endtask

task pulse_ack; begin @(posedge clk) #1; cpu_irq_ack = 1'b1; @(posedge clk) #1; cpu_irq_ack = 1'b0; end endtask
task pulse_eoi; begin @(posedge clk) #1; cpu_irq_eoi = 1'b1; @(posedge clk) #1; cpu_irq_eoi = 1'b0; end endtask

// claim the currently-offered source `ev` (holds one extra cycle so the delayed
// presented-vector the PIC claims has settled to ev)
task claim(input [3:0] ev);
    begin
        wait_offer(ev);
        @(posedge clk);
        pulse_ack;
    end
endtask

task step(input integer n); integer k; begin for (k=0;k<n;k=k+1) @(posedge clk); end endtask

// per-source register address helpers
function [31:0] CFG; input [31:0] i; CFG = CFG0 + (i<<2); endfunction
function [31:0] SWT; input [31:0] i; SWT = SWT0 + (i<<2); endfunction
function [31:0] STA; input [31:0] i; STA = STA0 + (i<<2); endfunction

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    irq_src = 16'b0; cpu_irq_ack = 1'b0; cpu_irq_eoi = 1'b0;
    awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0;
    awaddr=0; wdata=0; wstrb=0; araddr=0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    step(2);

    // ===== 1. reset defaults + basic level interrupt =====================
    $display("\n-- 1. reset defaults + basic level interrupt --");
    axi_read(BAND_CONFIG, RESP_OKAY);   check(32'h0000001B, rd, "BAND_CONFIG default");
    axi_read(NEST_MAX_R, RESP_OKAY);    check(32'd8,        rd, "NEST_MAX default");
    axi_read(INT_ENABLE, RESP_OKAY);    check(32'd0,        rd, "INT_ENABLE default");
    axi_read(INT_STATUS, RESP_OKAY);    check(32'd0,        rd, "INT_STATUS default");
    check(32'd0, {31'b0, cpu_irq}, "cpu_irq idle after reset");

    axi_write(INT_ENABLE, 32'h0008, RESP_OKAY);     // enable src3
    irq_src[3] = 1'b1;
    wait_offer(4'd3);
    check(32'd1, {31'b0, cpu_irq}, "cpu_irq asserted for src3");
    check(32'd3, {28'b0, cpu_irq_vec}, "cpu_irq_vec = 3");
    axi_read(STA(3), RESP_OKAY);  check(32'h0000_0001, rd & 32'hF, "src3 status pending");
    claim(4'd3);
    step(2);
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'd1, rd & 32'h1F, "depth = 1 after claim");
    axi_read(ACTIVE_VEC, RESP_OKAY);   check(32'h0000_0103, rd, "ACTIVE_VEC = valid|id3");
    axi_read(STA(3), RESP_OKAY);       check(32'h2, rd & 32'h2, "src3 status active");
    check(32'd0, {31'b0, cpu_irq}, "cpu_irq clears once src3 in service");
    irq_src[3] = 1'b0;                 // handler cleared the source
    pulse_eoi;
    step(2);
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'd0, rd & 32'h1F, "depth = 0 after eoi");
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);

    // ===== 2. custom priority grouping ===================================
    $display("\n-- 2. priority grouping (inter-band / intra-band / tie) --");
    // src1 band0, src2 band1  -> band0 wins
    axi_write(CFG(1), 32'h0000_0000, RESP_OKAY);    // band0, intra0
    axi_write(CFG(2), 32'h0000_0002, RESP_OKAY);    // band1
    // src4 band2 intra5, src5 band2 intra10 -> src5 wins (higher intra)
    axi_write(CFG(4), 32'h0000_0054, RESP_OKAY);    // band2(=100b at[2:1]) intra5
    axi_write(CFG(5), 32'h0000_00A4, RESP_OKAY);    // band2 intra10
    // src6 band2 intra3, src7 band2 intra3 -> src6 wins (lower index)
    axi_write(CFG(6), 32'h0000_0034, RESP_OKAY);
    axi_write(CFG(7), 32'h0000_0034, RESP_OKAY);
    axi_write(INT_ENABLE, 32'h00F6, RESP_OKAY);     // en src1,2,4,5,6,7

    irq_src[2] = 1'b1; irq_src[1] = 1'b1;
    claim(4'd1);                                     // band0 outranks band1
    $display("PASS: inter-band - band0 src1 served before band1 src2");
    irq_src[1] = 1'b0; pulse_eoi; step(2);
    claim(4'd2);                                     // now src2
    irq_src[2] = 1'b0; pulse_eoi; step(2);

    irq_src[4] = 1'b1; irq_src[5] = 1'b1;
    claim(4'd5);                                     // higher intra wins
    $display("PASS: intra-band - higher intra src5 before src4");
    irq_src[5] = 1'b0; pulse_eoi; step(2);
    irq_src[4] = 1'b0; step(2);

    irq_src[6] = 1'b1; irq_src[7] = 1'b1;
    claim(4'd6);                                     // tie -> lowest index
    $display("PASS: tie-break - lowest index src6 before src7");
    irq_src[6] = 1'b0; irq_src[7] = 1'b0; pulse_eoi; step(2);
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);

    // ===== 3. preemption with nesting ===================================
    $display("\n-- 3. preemption with nesting --");
    axi_write(CFG(8), 32'h0000_0004, RESP_OKAY);    // band2
    axi_write(CFG(9), 32'h0000_0000, RESP_OKAY);    // band0 (higher)
    axi_write(INT_ENABLE, 32'h0300, RESP_OKAY);     // en src8, src9
    irq_src[8] = 1'b1;
    claim(4'd8);                                     // depth 1
    step(2);
    irq_src[9] = 1'b1;                              // higher-priority preemptor
    claim(4'd9);                                     // preempts -> depth 2
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'd2, rd & 32'h1F, "depth = 2 (nested)");
    axi_read(ACTIVE_VEC, RESP_OKAY);   check(32'h0000_0109, rd, "top of stack = src9");
    irq_src[9] = 1'b0; pulse_eoi; step(2);          // return to src8 context
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'd1, rd & 32'h1F, "depth = 1 after inner eoi");
    axi_read(ACTIVE_VEC, RESP_OKAY);   check(32'h0000_0108, rd, "restored context = src8");
    irq_src[8] = 1'b0; pulse_eoi; step(2);
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'd0, rd & 32'h1F, "depth = 0 after outer eoi");

    // ===== 4. NEST_MAX enforcement + overflow ===========================
    $display("\n-- 4. NEST_MAX enforcement --");
    axi_write(INT_STATUS, 32'h7, RESP_OKAY);        // clear sticky flags
    axi_write(NEST_MAX_R, 32'd1, RESP_OKAY);        // limit nesting to depth 1
    irq_src[8] = 1'b1;
    claim(4'd8);                                     // depth 1 == limit
    step(2);
    irq_src[9] = 1'b1;                              // would preempt, but limit hit
    step(4);
    no_offer_for(4'd9, "depth limit blocks preemption");
    axi_read(INT_STATUS, RESP_OKAY);   check(32'h4, rd & 32'h4, "INT_STATUS.OVF set");
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'h1_0000, rd & 32'h1_0000, "NEST_STATUS.OVF set");
    axi_write(NEST_MAX_R, 32'd8, RESP_OKAY);        // relax the limit
    claim(4'd9);                                     // now it preempts
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'd2, rd & 32'h1F, "depth = 2 once limit relaxed");
    irq_src[9] = 1'b0; pulse_eoi; step(2);
    irq_src[8] = 1'b0; pulse_eoi; step(2);
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);
    axi_write(INT_STATUS, 32'h7, RESP_OKAY);

    // ===== 5. spurious detection ========================================
    $display("\n-- 5. spurious interrupt detection --");
    axi_write(CFG(12), 32'h0000_0000, RESP_OKAY);   // level, band0
    axi_write(INT_ENABLE, 32'h1000, RESP_OKAY);
    irq_src[12] = 1'b1;
    wait_offer(4'd12);
    @(posedge clk);                                 // let the presented vector settle
    #1 irq_src[12] = 1'b0;                          // source drops before the claim
    pulse_ack;                                       // CPU had already committed -> spurious
    step(2);
    axi_read(STA(12), RESP_OKAY);      check(32'h8, rd & 32'h8, "src12 status SPUR");
    axi_read(SPURIOUS_LOG, RESP_OKAY); check(32'h1000, rd, "SPURIOUS_LOG bit12");
    axi_read(INT_STATUS, RESP_OKAY);   check(32'h1, rd & 32'h1, "INT_STATUS.SPUR");
    pulse_eoi; step(2);                             // balance the accounted claim
    axi_write(SPURIOUS_LOG, 32'h1000, RESP_OKAY);   // W1C
    axi_read(SPURIOUS_LOG, RESP_OKAY); check(32'h0, rd, "SPURIOUS_LOG cleared (W1C)");
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);
    axi_write(INT_STATUS, 32'h7, RESP_OKAY);

    // ===== 6. deadline-aware escalation =================================
    $display("\n-- 6. deadline escalation (jump to band0) --");
    axi_write(ESCALATION, 32'h0000_0000, RESP_OKAY);      // jump to band0, single
    axi_write(CFG(13), 32'h0008_0006, RESP_OKAY);         // band3, deadline 8 cycles
    axi_write(CFG(14), 32'h0000_0002, RESP_OKAY);         // band1, no deadline
    axi_write(INT_ENABLE, 32'h6000, RESP_OKAY);
    irq_src[14] = 1'b1; irq_src[13] = 1'b1;
    wait_offer(4'd14);                                    // band1 wins first
    $display("PASS: before deadline - band1 src14 is offered");
    step(14);                                             // let src13 miss its deadline
    wait_offer(4'd13);                                    // escalated src13 now outranks src14
    axi_read(STA(13), RESP_OKAY);  check(32'h4, rd & 32'h4, "src13 status ESC");
    axi_read(INT_STATUS, RESP_OKAY); check(32'h2, rd & 32'h2, "INT_STATUS.ESC");
    claim(4'd13);
    irq_src[13] = 1'b0; irq_src[14] = 1'b0; pulse_eoi; step(2);
    axi_read(STA(13), RESP_OKAY);  check(32'h0, rd & 32'hF, "src13 escalation cleared at idle");
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);
    axi_write(INT_STATUS, 32'h7, RESP_OKAY);

    // ===== 7. software triggers =========================================
    $display("\n-- 7. software-triggered interrupts --");
    axi_write(CFG(15), 32'h0000_0000, RESP_OKAY);   // band0
    axi_write(INT_ENABLE, 32'h8000, RESP_OKAY);
    axi_write(SWT(15), 32'h0000_0001, RESP_OKAY);   // no key -> ignored
    step(3);
    no_offer_for(4'd15, "sw trigger without key is ignored");
    axi_read(SWT(15), RESP_OKAY);  check(32'h0, rd, "sw channel still clear");
    axi_write(SWT(15), {SW_KEY, 16'h0001}, RESP_OKAY);   // keyed set
    wait_offer(4'd15);
    axi_read(SWT(15), RESP_OKAY);  check(32'h1, rd, "sw channel set");
    claim(4'd15);                                    // consumed on claim
    step(2);
    axi_read(SWT(15), RESP_OKAY);  check(32'h0, rd, "sw channel auto-cleared on claim");
    pulse_eoi; step(2);
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);

    // ===== 8. edge-triggered source =====================================
    $display("\n-- 8. edge-triggered source --");
    axi_write(CFG(0), 32'h0000_0001, RESP_OKAY);    // edge, band0
    axi_write(INT_ENABLE, 32'h0001, RESP_OKAY);
    @(posedge clk) #1 irq_src[0] = 1'b1;            // one-cycle pulse
    @(posedge clk) #1 irq_src[0] = 1'b0;
    wait_offer(4'd0);                                // latched despite source low
    $display("PASS: edge pulse latched into a pending request");
    claim(4'd0);
    pulse_eoi; step(2);
    no_offer_for(4'd0, "edge request consumed (no re-fire)");
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);
    axi_write(CFG(0), 32'h0000_0000, RESP_OKAY);

    // ===== 9. AXI error responses =======================================
    $display("\n-- 9. AXI4-Lite responses --");
    axi_read(32'h00F0, RESP_SLVERR);                 // unmapped word
    $display("PASS: unmapped read -> SLVERR");
    axi_write(STA0, 32'h1, RESP_SLVERR);             // SRCx_STATUS is read-only
    $display("PASS: write to read-only SRC_STATUS -> SLVERR");
    axi_write(NEST_STATUS, 32'h1, RESP_SLVERR);      // NEST_STATUS is read-only
    $display("PASS: write to read-only NEST_STATUS -> SLVERR");
    axi_write(INT_ENABLE, 32'h0, RESP_OKAY);         // a normal write still OKAYs

    // ===== 10. source re-banded while active keeps its claimed priority ===
    // brief "Custom Priority Grouping" Q4: a source moved between bands while
    // an interrupt from it is already active must not corrupt nesting. The key
    // is snapshotted at claim, so the active threshold is stable.
    $display("\n-- 10. re-band a source while it is in service (grouping Q4) --");
    axi_write(CFG(8), 32'h0000_0004, RESP_OKAY);    // src8 band2
    axi_write(CFG(9), 32'h0000_0002, RESP_OKAY);    // src9 band1 (more urgent than band2)
    axi_write(INT_ENABLE, 32'h0300, RESP_OKAY);
    irq_src[8] = 1'b1;
    claim(4'd8);                                     // src8 active, key snapshot = band2
    axi_write(CFG(8), 32'h0000_0000, RESP_OKAY);    // live-remap src8 to band0 (most urgent)
    irq_src[9] = 1'b1;                              // band1 vs the band2 *snapshot* of src8
    claim(4'd9);                                     // must still preempt (snapshot honored)
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'd2, rd & 32'h1F, "re-banded active src still preempted -> depth 2");
    $display("PASS: active source's claimed priority survives a live re-band");
    irq_src[9] = 1'b0; pulse_eoi; step(2);
    irq_src[8] = 1'b0; pulse_eoi; step(2);
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);

    // ===== 11. deadline escalation preempts an active lower source ========
    $display("\n-- 11. escalation drives preemption of an in-service source --");
    axi_write(ESCALATION, 32'h0000_0000, RESP_OKAY);      // jump to band0
    axi_write(CFG(10), 32'h0000_0004, RESP_OKAY);         // src10 band2, no deadline
    axi_write(CFG(11), 32'h0008_0006, RESP_OKAY);         // src11 band3, deadline 8
    axi_write(INT_ENABLE, 32'h0C00, RESP_OKAY);
    irq_src[10] = 1'b1;
    claim(4'd10);                                          // src10 active (band2)
    irq_src[11] = 1'b1;                                   // band3: cannot preempt band2 yet
    step(3);
    no_offer_for(4'd11, "low-band src cannot preempt yet");
    step(12);                                              // src11 misses its deadline -> band0
    claim(4'd11);                                          // escalated: now preempts src10
    axi_read(NEST_STATUS, RESP_OKAY);  check(32'd2, rd & 32'h1F, "escalated src preempted active src -> depth 2");
    $display("PASS: a deadline-escalated source preempts an active lower source");
    irq_src[11] = 1'b0; pulse_eoi; step(2);
    irq_src[10] = 1'b0; pulse_eoi; step(2);
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);
    axi_write(INT_STATUS, 32'h7, RESP_OKAY);

    // ===== 12. bump + multi escalation walks the effective band up ========
    $display("\n-- 12. bump mode + multi-escalation --");
    axi_write(ESCALATION, 32'h0000_0110, RESP_OKAY);      // MODE=bump[4], MULTI[8]
    axi_write(CFG(12), 32'h0004_0006, RESP_OKAY);         // src12 band3, deadline 4
    axi_write(INT_ENABLE, 32'h1000, RESP_OKAY);
    irq_src[12] = 1'b1;
    step(24);                                             // 3 -> 2 -> 1 -> 0 over repeated misses
    axi_read(STA(12), RESP_OKAY);  check(32'h0, rd & 32'h30, "src12 effective band bumped to 0");
    axi_read(STA(12), RESP_OKAY);  check(32'h4, rd & 32'h4, "src12 ESC flag set");
    claim(4'd12);
    irq_src[12] = 1'b0; pulse_eoi; step(2);
    axi_write(ESCALATION, 32'h0000_0000, RESP_OKAY);
    axi_write(INT_ENABLE, 32'h0000, RESP_OKAY);
    axi_write(INT_STATUS, 32'h7, RESP_OKAY);

    // ---- done ----
    step(4);
    $display("\n========================================");
    if (errors == 0)
        $display("== PIC TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== PIC TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

// watchdog
initial begin
    #200000;
    $display("FAIL: tb_pic timeout");
    $finish;
end

endmodule
