// ===========================================================================
// tb_pic_status - field-by-field verification of SRCx_STATUS (hdl/pic.v)
// ===========================================================================
//
// OBJECTIVE
//   SRCx_STATUS is the only window software has into what a source is doing.
//   It is read-only, so tb_pic_ro proves software cannot write it; this bench
//   proves the other half - that the hardware puts the right thing in it.
//
//   Every field is verified on its own, with a named step sequence, and each
//   field is checked in BOTH directions: it must come up when the condition
//   holds and go away when it stops holding. A status bit that is stuck at 1 is
//   as useless as one stuck at 0, and only the two-sided check finds the first.
//
// FIELDS COVERED (all six, none by inference)
//   [0]     PEND       enabled request present, not yet in service
//   [1]     ACTIVE     in service, on the nesting stack
//   [2]     ESC        deadline missed, priority escalated
//   [3]     SPUR       the current claim was spurious
//   [5:4]   EFF_BAND   band actually in use, differs from the configured band
//                      after an escalation
//   [31:16] DDL_TIMER  cycles elapsed on the deadline counter
//
// PLUS the full life cycle of one source as a state walk:
//   idle -> pending -> in service -> returned -> idle
//   with the register read at every step, so the transitions are shown as a
//   sequence rather than as six independent facts.
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow.
// ===========================================================================

`timescale 1ns/1ps

module tb_pic_status;

// ---- register map (byte offsets) ----
localparam CFG0 = 32'h00, SWT0 = 32'h40, STA0 = 32'h80;
localparam BAND_CONFIG   = 32'hC0, NEST_STATUS  = 32'hC4, NEST_MAX_R = 32'hC8,
           ACTIVE_VEC    = 32'hCC, SPURIOUS_LOG = 32'hD0, ESCALATION = 32'hD4,
           INT_ENABLE    = 32'hD8, INT_STATUS   = 32'hDC;
localparam RESP_OKAY = 2'b00;
localparam SW_KEY = 16'hA5A5;

// ---- SRCx_STATUS field masks ----
localparam [31:0] M_PEND   = 32'h0000_0001;
localparam [31:0] M_ACTIVE = 32'h0000_0002;
localparam [31:0] M_ESC    = 32'h0000_0004;
localparam [31:0] M_SPUR   = 32'h0000_0008;
localparam [31:0] M_EFFB   = 32'h0000_0030;
localparam [31:0] M_DDL    = 32'hFFFF_0000;
localparam [31:0] M_STATE  = 32'h0000_003F;   // the six state bits together

// ---- clock / reset ----
reg clk   = 1'b0;
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
integer i;
reg [31:0] rd;
reg [15:0] t0, t1;

// Effective-band watcher for the bump-escalation check. It samples the
// per-source effective band every clock edge, counts the transitions and flags
// any transition that moved more than one band. A register read over AXI costs
// several cycles, so it cannot tell a correct 3 -> 2 -> 1 -> 0 walk from a
// single 3 -> 0 jump; this can.
reg        watch_en   = 1'b0;
reg  [1:0] band_prev  = 2'd0;
integer    band_steps = 0;
reg        band_bad   = 1'b0;
`include "tb_check.vh"
`include "tb_axil_master.vh"

pic dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .irq_src_i(irq_src),
    .cpu_irq_o(cpu_irq), .cpu_irq_vec_o(cpu_irq_vec),
    .cpu_irq_ack_i(cpu_irq_ack), .cpu_irq_eoi_i(cpu_irq_eoi),
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(3'b0), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(3'b0), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready)
);

always @(posedge clk) begin
    if (watch_en && (dut.eff_band[8] !== band_prev)) begin
        if (dut.eff_band[8] !== (band_prev - 2'd1))
            band_bad <= 1'b1;
        band_steps <= band_steps + 1;
        band_prev  <= dut.eff_band[8];
    end
end

// per-source register address helpers
function [31:0] CFG; input [31:0] k; CFG = CFG0 + (k << 2); endfunction
function [31:0] SWT; input [31:0] k; SWT = SWT0 + (k << 2); endfunction
function [31:0] STA; input [31:0] k; STA = STA0 + (k << 2); endfunction

// Read SRCx_STATUS and compare the selected field against an expected value.
task chk_field(input [31:0] src, input [31:0] mask, input [31:0] expect_val,
               input [511:0] name);
    begin
        axil_read(STA(src), RESP_OKAY);
        check(expect_val, rd & mask, name);
    end
endtask

// Claim the currently-offered source. cpu_irq_ack is aligned one cycle after
// the offer so the PIC's delayed presented-vector has settled, which is the
// same alignment the CPU produces.
task claim_offer;
    begin
        while (cpu_irq !== 1'b1) @(posedge clk);
        @(posedge clk);
        @(posedge clk) #1 cpu_irq_ack = 1'b1;
        @(posedge clk) #1 cpu_irq_ack = 1'b0;
        axil_step(2);
    end
endtask

task end_of_interrupt;
    begin
        @(posedge clk) #1 cpu_irq_eoi = 1'b1;
        @(posedge clk) #1 cpu_irq_eoi = 1'b0;
        axil_step(2);
    end
endtask

// Put the block back into its reset configuration between sections, so each
// section starts from a known state and no section can pass on leftovers.
task quiesce;
    begin
        irq_src = 16'h0000;
        axil_step(2);
        axil_write(INT_ENABLE, 32'h0000_0000, RESP_OKAY);
        for (i = 0; i < 16; i = i + 1) begin
            axil_write(CFG(i), 32'h0000_0000, RESP_OKAY);
            axil_write(SWT(i), 32'h0000_0000, RESP_OKAY);
        end
        axil_write(ESCALATION,   32'h0000_0000, RESP_OKAY);
        axil_write(BAND_CONFIG,  32'h0000_001B, RESP_OKAY);
        axil_write(NEST_MAX_R,   32'd8,         RESP_OKAY);
        axil_write(SPURIOUS_LOG, 32'h0000_FFFF, RESP_OKAY);
        axil_write(INT_STATUS,   32'h0000_0007, RESP_OKAY);
        axil_step(2);
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    $display("\n===========================================================");
    $display("tb_pic_status : SRCx_STATUS field-by-field verification");
    $display("===========================================================");

    irq_src = 16'b0; cpu_irq_ack = 1'b0; cpu_irq_eoi = 1'b0;
    axil_idle;
    rst_n = 1'b0;
    axil_step(4);
    @(posedge clk) #1 rst_n = 1'b1;
    axil_step(2);

    // =====================================================================
    // 1. PEND, bit [0]
    // =====================================================================
    // PEND is "this source has an ENABLED request and is not in service". The
    // enable term is the part worth proving: a raised line with the source
    // masked must NOT show as pending, otherwise software cannot tell an
    // ignored peripheral from a quiet one.
    $display("\n-- 1. SRCx_STATUS[0] PEND --");
    $display("   step 1: source 1 is configured level-triggered, band 0, no deadline");
    axil_write(CFG(1), 32'h0000_0000, RESP_OKAY);
    $display("   step 2: with INT_ENABLE = 0, raise the line -> PEND must stay 0");
    irq_src[1] = 1'b1;
    axil_step(4);
    chk_field(1, M_PEND, 32'd0, "  PEND = 0 while the source is masked");
    $display("   step 3: enable source 1 -> PEND must become 1 with the same line");
    axil_write(INT_ENABLE, 32'h0000_0002, RESP_OKAY);
    axil_step(3);
    chk_field(1, M_PEND, M_PEND, "  PEND = 1 once the source is enabled");
    $display("   step 4: drop the line -> PEND must go back to 0 (level-sensitive)");
    irq_src[1] = 1'b0;
    axil_step(3);
    chk_field(1, M_PEND, 32'd0, "  PEND = 0 again once the line drops");
    $display("   step 5: a neighbouring source must not have moved");
    chk_field(2, M_STATE, 32'd0, "  SRC2_STATUS untouched by SRC1 activity");
    quiesce;

    // =====================================================================
    // 2. ACTIVE, bit [1]
    // =====================================================================
    // ACTIVE means "on the nesting stack". The interesting property is that
    // PEND and ACTIVE are independent: a level source that is still asserted
    // while its handler runs is both pending and active at the same time.
    $display("\n-- 2. SRCx_STATUS[1] ACTIVE --");
    $display("   step 1: enable source 3, level-triggered, and raise its line");
    axil_write(CFG(3), 32'h0000_0000, RESP_OKAY);
    axil_write(INT_ENABLE, 32'h0000_0008, RESP_OKAY);
    irq_src[3] = 1'b1;
    axil_step(3);
    chk_field(3, M_STATE, M_PEND, "  before the claim: PEND=1, ACTIVE=0");
    $display("   step 2: claim the interrupt (cpu_irq_ack)");
    claim_offer;
    $display("   step 3: the line is still high, so PEND and ACTIVE are both 1");
    chk_field(3, M_PEND | M_ACTIVE, M_PEND | M_ACTIVE, "  in service: PEND=1, ACTIVE=1");
    axil_read_chk(ACTIVE_VEC, 32'h0000_0103, "  ACTIVE_VEC = VALID | id 3");
    $display("   step 4: the handler clears the peripheral -> PEND drops, ACTIVE holds");
    irq_src[3] = 1'b0;
    axil_step(3);
    chk_field(3, M_STATE, M_ACTIVE, "  cleared in handler: PEND=0, ACTIVE=1");
    $display("   step 5: end of interrupt -> ACTIVE drops");
    end_of_interrupt;
    chk_field(3, M_STATE, 32'd0, "  after end-of-interrupt: all state bits 0");
    quiesce;

    // =====================================================================
    // 3. DDL_TIMER, bits [31:16], and its gating
    // =====================================================================
    // The counter runs only while the source is PENDING AND NOT ACTIVE. That
    // gate is the whole point: it measures how long the source waited for
    // service, so it must stop the moment service starts.
    $display("\n-- 3. SRCx_STATUS[31:16] DDL_TIMER --");
    $display("   step 1: source 5, deadline 0x4000 (large enough never to expire here)");
    axil_write(CFG(5), 32'h4000_0000, RESP_OKAY);
    axil_write(INT_ENABLE, 32'h0000_0020, RESP_OKAY);
    $display("   step 2: with the line low, the counter must sit at 0");
    axil_step(6);
    chk_field(5, M_DDL, 32'd0, "  DDL_TIMER = 0 while the source is idle");
    $display("   step 3: raise the line and sample the counter twice");
    irq_src[5] = 1'b1;
    axil_step(6);
    axil_read(STA(5), RESP_OKAY); t0 = rd[31:16];
    axil_step(10);
    axil_read(STA(5), RESP_OKAY); t1 = rd[31:16];
    if (t1 > t0)
        $display("PASS: DDL_TIMER advances while pending (0x%04h -> 0x%04h)", t0, t1);
    else begin
        $display("FAIL: DDL_TIMER did not advance while pending (0x%04h -> 0x%04h)", t0, t1);
        errors = errors + 1;
    end
    $display("   step 4: claim the interrupt - the counter must stop and clear");
    claim_offer;
    chk_field(5, M_DDL, 32'd0, "  DDL_TIMER cleared once the source is in service");
    axil_step(10);
    chk_field(5, M_DDL, 32'd0, "  DDL_TIMER stays 0 for the whole handler");
    $display("   step 5: return, drop the line, counter stays at 0 when idle");
    irq_src[5] = 1'b0;
    end_of_interrupt;
    axil_step(8);
    chk_field(5, M_DDL, 32'd0, "  DDL_TIMER = 0 again once the source is idle");
    $display("   step 6: a source with NO deadline configured holds the counter at 0");
    axil_write(CFG(6), 32'h0000_0000, RESP_OKAY);          // deadline field = 0
    axil_write(INT_ENABLE, 32'h0000_0040, RESP_OKAY);
    irq_src[6] = 1'b1;
    axil_step(12);
    chk_field(6, M_PEND, M_PEND, "  source 6 really is pending");
    chk_field(6, M_DDL,  32'd0,  "  DDL_TIMER stays 0 with the deadline disabled");
    quiesce;

    // =====================================================================
    // 4. ESC, bit [2], and EFF_BAND, bits [5:4]
    // =====================================================================
    // These two are checked together because they are two views of one event:
    // ESC says an escalation happened, EFF_BAND says where the source ended up.
    // Checking only ESC would not catch an escalation that sets the flag and
    // forgets to move the band, which is a silent loss of the whole feature.
    $display("\n-- 4. SRCx_STATUS[2] ESC and [5:4] EFF_BAND --");
    $display("   step 1: ESCALATION_CFG = jump to band 0, single escalation");
    axil_write(ESCALATION, 32'h0000_0000, RESP_OKAY);
    $display("   step 2: source 7 in band 3 with a deadline of 8 cycles");
    axil_write(CFG(7), 32'h0008_0006, RESP_OKAY);          // deadline 8, band 3, level
    axil_write(INT_ENABLE, 32'h0000_0080, RESP_OKAY);
    axil_step(3);
    chk_field(7, M_EFFB, 32'h30, "  EFF_BAND = 3 while idle, tracking the config");
    chk_field(7, M_ESC,  32'd0,  "  ESC = 0 before anything happens");
    $display("   step 3: raise the line and hold it for more than 8 cycles");
    $display("           without claiming, so the deadline is missed");
    irq_src[7] = 1'b1;
    axil_step(14);
    $display("   step 4: ESC must be set and EFF_BAND must now read 0, not 3");
    chk_field(7, M_ESC,  M_ESC,  "  ESC = 1 after the deadline is missed");
    chk_field(7, M_EFFB, 32'h00, "  EFF_BAND escalated from band 3 to band 0");
    $display("   step 5: the configured band must be untouched - escalation is");
    $display("           an effective-priority change, not a reconfiguration");
    axil_read(CFG(7), RESP_OKAY);
    check(32'h0008_0006, rd, "  SRC7_CONFIG unchanged by the escalation");
    $display("   step 6: serve the source and return - both fields go back");
    claim_offer;
    irq_src[7] = 1'b0;
    end_of_interrupt;
    axil_step(4);
    chk_field(7, M_ESC,  32'd0,  "  ESC cleared once the source returns to idle");
    chk_field(7, M_EFFB, 32'h30, "  EFF_BAND back to the configured band 3");
    quiesce;

    // Bump mode moves the band one step per missed deadline. Sampling it over
    // AXI cannot prove that: a register read costs several cycles, so a bump
    // that jumped 3 -> 0 in one go would look identical to three correct steps.
    // The band is therefore watched on every clock edge by the monitor below,
    // which records how many transitions happened and whether any of them
    // skipped a band.
    $display("   step 7: bump mode - EFF_BAND must step 3 -> 2 -> 1 -> 0,");
    $display("           one band per missed deadline, watched every clock edge");
    axil_write(ESCALATION, 32'h0000_0110, RESP_OKAY);      // MODE=bump, MULTI=1
    axil_write(CFG(8), 32'h0004_0006, RESP_OKAY);          // deadline 4, band 3
    axil_write(INT_ENABLE, 32'h0000_0100, RESP_OKAY);
    axil_step(3);
    band_prev  = dut.eff_band[8];
    band_steps = 0;
    band_bad   = 1'b0;
    check(32'd3, {30'b0, band_prev}, "  EFF_BAND starts at the configured band 3");
    watch_en = 1'b1;
    irq_src[8] = 1'b1;
    axil_step(40);                                          // ample time for 3+ misses
    watch_en = 1'b0;
    check(32'd3, band_steps, "  exactly 3 band transitions were observed");
    check(32'd0, {31'b0, band_bad}, "  every transition moved exactly one band");
    chk_field(8, M_EFFB, 32'h00, "  EFF_BAND ended at band 0");
    chk_field(8, M_ESC,  M_ESC,  "  ESC is set after the escalations");
    $display("   step 8: EFF_BAND saturates at band 0 instead of wrapping to 3");
    axil_step(40);
    chk_field(8, M_EFFB, 32'h00, "  EFF_BAND still 0 after many more deadlines");
    quiesce;

    // =====================================================================
    // 5. SPUR, bit [3]
    // =====================================================================
    // A claim is spurious when the request has already gone away by the time
    // the CPU acknowledges it. The negative case is the one that matters: a
    // source still asserted at the claim and cleared later, inside the handler,
    // is a perfectly normal interrupt and must NOT be flagged.
    $display("\n-- 5. SRCx_STATUS[3] SPUR --");
    $display("   step 1: NEGATIVE case first - a normal interrupt must not set SPUR");
    axil_write(CFG(10), 32'h0000_0000, RESP_OKAY);
    axil_write(INT_ENABLE, 32'h0000_0400, RESP_OKAY);
    irq_src[10] = 1'b1;
    axil_step(3);
    claim_offer;                                    // still asserted at the claim
    chk_field(10, M_SPUR, 32'd0, "  SPUR = 0 for a source still asserted at the claim");
    irq_src[10] = 1'b0;                             // handler clears it afterwards
    axil_step(2);
    chk_field(10, M_SPUR, 32'd0, "  SPUR still 0 after an in-handler clear");
    axil_read(SPURIOUS_LOG, RESP_OKAY);
    check(32'd0, rd, "  SPURIOUS_LOG untouched by a legitimate claim");
    end_of_interrupt;
    quiesce;

    $display("   step 2: POSITIVE case - drop the line between the offer and the claim");
    axil_write(CFG(11), 32'h0000_0000, RESP_OKAY);
    axil_write(INT_ENABLE, 32'h0000_0800, RESP_OKAY);
    irq_src[11] = 1'b1;
    while (cpu_irq !== 1'b1) @(posedge clk);
    @(posedge clk);
    #1 irq_src[11] = 1'b0;                          // deasserts before the ack lands
    @(posedge clk) #1 cpu_irq_ack = 1'b1;
    @(posedge clk) #1 cpu_irq_ack = 1'b0;
    axil_step(3);
    $display("   step 3: SPUR must be set, and the sticky log must record it");
    chk_field(11, M_SPUR, M_SPUR, "  SPUR = 1 for a request that vanished before the claim");
    axil_read_chk(SPURIOUS_LOG, 32'h0000_0800, "  SPURIOUS_LOG bit 11 set");
    axil_read(INT_STATUS, RESP_OKAY);
    check(32'h1, rd & 32'h1, "  INT_STATUS.SPUR set");
    $display("   step 4: the claim is still accounted, so ack and eoi stay balanced");
    axil_read(NEST_STATUS, RESP_OKAY);
    check(32'd1, rd & 32'h1F, "  nesting depth = 1 even for a spurious claim");
    $display("   step 5: end of interrupt -> SPUR clears, the sticky log does not");
    end_of_interrupt;
    chk_field(11, M_SPUR, 32'd0, "  SPUR cleared on return");
    axil_read_chk(SPURIOUS_LOG, 32'h0000_0800, "  SPURIOUS_LOG is sticky across the return");
    quiesce;
    axil_read_chk(SPURIOUS_LOG, 32'h0000_0000, "  SPURIOUS_LOG cleared by W1C");

    // =====================================================================
    // 6. full life cycle of one source, read at every transition
    // =====================================================================
    $display("\n-- 6. life cycle of source 12, SRCx_STATUS read at every step --");
    axil_write(CFG(12), 32'h0020_0000, RESP_OKAY);         // deadline 32, band 0, level
    axil_write(INT_ENABLE, 32'h0000_1000, RESP_OKAY);
    axil_step(2);
    $display("   state 1 - IDLE           : nothing set, timer stopped");
    chk_field(12, M_STATE, 32'd0, "  IDLE: state bits all 0");
    chk_field(12, M_DDL,   32'd0, "  IDLE: DDL_TIMER = 0");

    $display("   state 2 - PENDING        : line raised, PEND set, timer running");
    irq_src[12] = 1'b1;
    axil_step(5);
    chk_field(12, M_STATE, M_PEND, "  PENDING: PEND=1, everything else 0");
    axil_read(STA(12), RESP_OKAY);
    if (rd[31:16] != 16'd0)
        $display("PASS: PENDING: DDL_TIMER is running = 0x%04h", rd[31:16]);
    else begin
        $display("FAIL: PENDING: DDL_TIMER should be running");
        errors = errors + 1;
    end

    $display("   state 3 - IN SERVICE     : claimed, ACTIVE set, timer stopped");
    claim_offer;
    chk_field(12, M_ACTIVE, M_ACTIVE, "  IN SERVICE: ACTIVE=1");
    chk_field(12, M_DDL,    32'd0,    "  IN SERVICE: DDL_TIMER cleared");
    axil_read_chk(ACTIVE_VEC, 32'h0000_010C, "  ACTIVE_VEC = VALID | id 12");
    axil_read(NEST_STATUS, RESP_OKAY);
    check(32'd1, rd & 32'h1F, "  IN SERVICE: nesting depth = 1");

    $display("   state 4 - SERVICED       : handler clears the source, PEND drops");
    irq_src[12] = 1'b0;
    axil_step(3);
    chk_field(12, M_STATE, M_ACTIVE, "  SERVICED: PEND=0, ACTIVE=1");

    $display("   state 5 - RETURNED       : end of interrupt, back to IDLE");
    end_of_interrupt;
    chk_field(12, M_STATE, 32'd0, "  RETURNED: state bits all 0");
    axil_read_chk(ACTIVE_VEC,  32'h0000_0000, "  RETURNED: ACTIVE_VEC invalid again");
    axil_read(NEST_STATUS, RESP_OKAY);
    check(32'd0, rd & 32'h1F, "  RETURNED: nesting depth back to 0");
    quiesce;

    // ---- done ----
    axil_step(4);
    $display("\n========================================");
    if (errors == 0)
        $display("== PIC STATUS TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== PIC STATUS TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

// watchdog
initial begin
    #500000;
    $display("FAIL: tb_pic_status timeout");
    $finish;
end

endmodule
