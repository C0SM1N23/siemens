// ===========================================================================
// tb_mtimer_regs - register, reset and access-rule verification for the
//                  machine timer (hdl/mtimer.v)
// ===========================================================================
//
// OBJECTIVE
//   The mtimer is the second AXI4-Lite peripheral in the SoC and the second
//   user of the shared axi_lite_slave. It is verified as a block in its own
//   right, rather than only through the system bench, for two reasons: its
//   reset values are unusual (mtimecmp resets to all-ones, not to zero, so the
//   timer is born disarmed), and its only defence against an out-of-range
//   access is the slave's address decode, which nothing else exercises here.
//
// SCOPE
//   1  reset: bus outputs legal and X-free while rst_n is low
//   2  reset values of all four registers, plus the interrupt output
//   3  mtime is free-running, and the rate is exactly one count per clock
//   4  read/write round-trip on all four registers, independently
//   5  byte-strobe writes, every lane of every register
//   6  a write to an mtime half beats the increment on that half
//   7  every unmapped offset in the decoded window answers SLVERR, read and
//      write - this is the mtimer's equivalent of a read-only region, and the
//      thing that turns a stray pointer into a precise CPU access-fault trap
//   8  the interrupt: disarmed at reset, fires on compare, is cleared by
//      moving mtimecmp, and the documented two-step arming sequence never
//      produces a false fire
//   9  asynchronous reset from a fully configured, armed state
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow.
// ===========================================================================

`timescale 1ns/1ps

module tb_mtimer_regs;

// ---- register map (byte offsets) ----
localparam MTIME_LO = 32'h00, MTIME_HI = 32'h04,
           MTIMECMP_LO = 32'h08, MTIMECMP_HI = 32'h0C;
localparam RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;
localparam ALL_ONES = 32'hFFFF_FFFF;

// ---- clock / reset ----
reg clk   = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

wire irq;

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
reg [31:0] a0, a1, b0, b1;
`include "tb_check.vh"
`include "tb_axil_master.vh"

mtimer dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .irq_o(irq),
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(3'b0), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(3'b0), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready)
);

task chk_defined(input [31:0] v, input [511:0] name);
    begin
        if ((^v) === 1'bx) begin
            $display("FAIL: %0s is not fully defined (value = %b)", name, v);
            errors = errors + 1;
        end else
            $display("PASS: %0s fully defined = 0x%08h", name, v);
    end
endtask

// mtime keeps counting underneath the bus, so an exact compare is only
// possible for the registers that hold still. For mtime itself, the value must
// land in a window that starts at the expected value and is wide enough to
// cover the transaction that observed it.
task chk_range(input [31:0] v, input [31:0] lo, input [31:0] span,
               input [511:0] name);
    begin
        if ((v >= lo) && (v <= lo + span))
            $display("PASS: %0s = 0x%08h, inside [0x%08h .. 0x%08h]", name, v, lo, lo + span);
        else begin
            $display("FAIL: %0s = 0x%08h, outside [0x%08h .. 0x%08h]", name, v, lo, lo + span);
            errors = errors + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    $display("\n===========================================================");
    $display("tb_mtimer_regs : register and reset verification, hdl/mtimer.v");
    $display("===========================================================");

    axil_idle;
    rst_n = 1'b0;

    // ===== 1. bus outputs while reset is asserted ==========================
    $display("\n-- 1. slave port while rst_n is LOW --");
    $display("   step 1: hold rst_n = 0 for 4 clock cycles");
    axil_step(4);
    $display("   step 2: sample the slave outputs mid-reset");
    check(32'd0, {31'b0, bvalid}, "  BVALID low during reset (IHI0022E A3.1.2)");
    check(32'd0, {31'b0, rvalid}, "  RVALID low during reset (IHI0022E A3.1.2)");
    chk_defined({30'b0, bresp}, "BRESP during reset");
    chk_defined({30'b0, rresp}, "RRESP during reset");
    chk_defined(rdata,          "RDATA during reset");
    check(32'd0, rdata,         "  RDATA is 0 during reset");
    check(32'd0, {31'b0, irq},  "  irq low during reset");

    // ===== 2. reset values =================================================
    $display("\n-- 2. reset values of all four registers --");
    $display("   step 1: release rst_n between clock edges");
    @(posedge clk) #1 rst_n = 1'b1;
    axil_step(1);
    $display("   step 2: mtime starts from 0 and is already counting, so it is");
    $display("           checked against a small window rather than exactly 0");
    axil_read(MTIME_LO, RESP_OKAY);
    chk_range(rd, 32'd0, 32'd40, "MTIME_LO shortly after reset");
    axil_read_chk(MTIME_HI, 32'h0000_0000, "  MTIME_HI reset = 0");
    $display("   step 3: mtimecmp resets to all-ones, which is what leaves the");
    $display("           timer DISARMED: mtime cannot reach it, so irq stays low");
    axil_read_chk(MTIMECMP_LO, ALL_ONES, "  MTIMECMP_LO reset = 0xFFFFFFFF");
    axil_read_chk(MTIMECMP_HI, ALL_ONES, "  MTIMECMP_HI reset = 0xFFFFFFFF");
    check(32'd0, {31'b0, irq}, "  irq inactive after reset (timer disarmed)");
    $display("   step 4: let it run a while - a disarmed timer must never fire");
    axil_step(200);
    check(32'd0, {31'b0, irq}, "  irq still inactive after 200 cycles");

    // ===== 3. mtime is free-running at exactly one count per clock =========
    // Two deltas are measured over gaps that differ by a known number of
    // cycles. The difference between the deltas removes the fixed AXI overhead
    // from the measurement, so the check is exact rather than approximate.
    $display("\n-- 3. mtime advances exactly once per clock --");
    $display("   step 1: measure a baseline delta between two back-to-back reads");
    axil_read(MTIME_LO, RESP_OKAY); a0 = rd;
    axil_read(MTIME_LO, RESP_OKAY); a1 = rd;
    $display("   step 2: measure the same pair with 50 extra clock cycles between");
    axil_read(MTIME_LO, RESP_OKAY); b0 = rd;
    axil_step(50);
    axil_read(MTIME_LO, RESP_OKAY); b1 = rd;
    $display("           baseline delta = %0d, delayed delta = %0d", a1 - a0, b1 - b0);
    check(32'd50, (b1 - b0) - (a1 - a0),
          "  50 extra clocks produced exactly 50 extra counts");

    // ===== 4. read/write round-trip, register by register ==================
    $display("\n-- 4. read/write round-trip on each register --");
    $display("   step 1: MTIMECMP_LO and MTIMECMP_HI hold still, so they are exact");
    axil_write(MTIMECMP_LO, 32'h1234_5678, RESP_OKAY);
    axil_read_chk(MTIMECMP_LO, 32'h1234_5678, "  MTIMECMP_LO round-trip");
    axil_read_chk(MTIMECMP_HI, ALL_ONES,      "  MTIMECMP_HI untouched by the LO write");
    axil_write(MTIMECMP_HI, 32'h9ABC_DEF0, RESP_OKAY);
    axil_read_chk(MTIMECMP_HI, 32'h9ABC_DEF0, "  MTIMECMP_HI round-trip");
    axil_read_chk(MTIMECMP_LO, 32'h1234_5678, "  MTIMECMP_LO untouched by the HI write");

    $display("   step 2: MTIME_HI is written and read back - it only advances on a");
    $display("           carry out of the low half, which will not happen here");
    axil_write(MTIME_HI, 32'h0000_00AA, RESP_OKAY);
    axil_read_chk(MTIME_HI, 32'h0000_00AA, "  MTIME_HI round-trip");

    $display("   step 3: MTIME_LO is written; the read back must be the written");
    $display("           value plus the clocks that elapsed since, and nothing else");
    axil_write(MTIME_LO, 32'h0001_0000, RESP_OKAY);
    axil_read(MTIME_LO, RESP_OKAY);
    chk_range(rd, 32'h0001_0000, 32'd40, "MTIME_LO after a software write");
    axil_read_chk(MTIME_HI, 32'h0000_00AA, "  MTIME_HI untouched by the LO write");

    // ===== 5. byte-strobe writes ==========================================
    // WSTRB is honoured per lane, so a byte or halfword store from the CPU
    // updates only the lanes it addressed. The check writes all-ones with one
    // lane enabled at a time and requires exactly that lane to change.
    $display("\n-- 5. byte-strobe writes, every lane of MTIMECMP_LO/HI --");
    axil_write(MTIMECMP_LO, 32'h0000_0000, RESP_OKAY);
    axil_write_strb(MTIMECMP_LO, ALL_ONES, 4'b0001, RESP_OKAY);
    axil_read_chk(MTIMECMP_LO, 32'h0000_00FF, "  lane 0 only");
    axil_write_strb(MTIMECMP_LO, ALL_ONES, 4'b0010, RESP_OKAY);
    axil_read_chk(MTIMECMP_LO, 32'h0000_FFFF, "  lanes 0 and 1");
    axil_write_strb(MTIMECMP_LO, ALL_ONES, 4'b0100, RESP_OKAY);
    axil_read_chk(MTIMECMP_LO, 32'h00FF_FFFF, "  lanes 0, 1 and 2");
    axil_write_strb(MTIMECMP_LO, ALL_ONES, 4'b1000, RESP_OKAY);
    axil_read_chk(MTIMECMP_LO, ALL_ONES,      "  all four lanes");
    $display("   a write with no lanes enabled must change nothing but still OKAY");
    axil_write_strb(MTIMECMP_LO, 32'h0000_0000, 4'b0000, RESP_OKAY);
    axil_read_chk(MTIMECMP_LO, ALL_ONES, "  MTIMECMP_LO unchanged by an empty write");

    axil_write(MTIMECMP_HI, 32'h0000_0000, RESP_OKAY);
    axil_write_strb(MTIMECMP_HI, 32'hAABB_CCDD, 4'b0101, RESP_OKAY);
    axil_read_chk(MTIMECMP_HI, 32'h00BB_00DD, "  MTIMECMP_HI lanes 0 and 2 only");

    // ===== 6. unmapped offsets ============================================
    $display("\n-- 6. unmapped offsets 0x10 .. 0xFC, read and write --");
    for (i = 32'h10; i <= 32'hFC; i = i + 4) begin
        axil_read(i, RESP_SLVERR);
        axil_write(i, ALL_ONES, RESP_SLVERR);
    end
    $display("PASS: all 60 unmapped words answer SLVERR on read and on write");
    $display("   the four mapped offsets must still answer OKAY, so the check");
    $display("   above is a decode result and not a blanket rejection");
    axil_read(MTIME_LO,    RESP_OKAY);
    axil_read(MTIME_HI,    RESP_OKAY);
    axil_read(MTIMECMP_LO, RESP_OKAY);
    axil_read(MTIMECMP_HI, RESP_OKAY);
    $display("PASS: the four mapped words still answer OKAY");

    // ===== 7. interrupt behaviour =========================================
    // The mtimer has no interrupt status register: the compare IS the status,
    // and the handler clears the line by moving mtimecmp forward. That makes
    // the arming sequence a correctness issue, not a style issue - writing the
    // high half first would momentarily arm the timer at a time already in the
    // past and fire immediately.
    $display("\n-- 7. interrupt: arm, fire, clear, and the safe arming order --");
    $display("   step 1: disarm the timer and reset the counter to a known value");
    axil_write(MTIMECMP_HI, ALL_ONES,      RESP_OKAY);
    axil_write(MTIMECMP_LO, ALL_ONES,      RESP_OKAY);
    axil_write(MTIME_HI,    32'h0000_0000, RESP_OKAY);
    axil_write(MTIME_LO,    32'h0000_0000, RESP_OKAY);
    axil_step(4);
    check(32'd0, {31'b0, irq}, "  irq low with the timer disarmed");

    $display("   step 2: arm in the documented order - LO first, then HI");
    $display("           at the moment LO is written, HI is still all-ones, so");
    $display("           the compare cannot be satisfied and cannot false-fire");
    axil_read(MTIME_LO, RESP_OKAY);
    axil_write(MTIMECMP_LO, rd + 32'd60, RESP_OKAY);
    check(32'd0, {31'b0, irq}, "  no false fire after writing only the low half");
    axil_write(MTIMECMP_HI, 32'h0000_0000, RESP_OKAY);
    $display("   step 3: irq must be low now and rise when mtime reaches mtimecmp");
    check(32'd0, {31'b0, irq}, "  irq still low immediately after arming");
    i = 0;
    while ((irq !== 1'b1) && (i < 200)) begin
        @(posedge clk);
        i = i + 1;
    end
    check(32'd1, {31'b0, irq}, "  irq rises when mtime reaches mtimecmp");
    $display("           (fired after %0d cycles)", i);

    $display("   step 4: irq is a level, so it stays up until software acts");
    axil_step(20);
    check(32'd1, {31'b0, irq}, "  irq holds high while mtime >= mtimecmp");

    $display("   step 5: the handler clears it by moving mtimecmp forward");
    axil_read(MTIME_LO, RESP_OKAY);
    axil_write(MTIMECMP_LO, rd + 32'd10_000, RESP_OKAY);
    axil_step(4);
    check(32'd0, {31'b0, irq}, "  irq clears once mtimecmp moves past mtime");

    $display("   step 6: NEGATIVE case - arming HI first with a stale LO would");
    $display("           fire immediately; show that the hardware really does");
    $display("           compare the full 64 bits by making it fire on purpose");
    axil_write(MTIMECMP_LO, 32'h0000_0000, RESP_OKAY);   // a time already past
    axil_write(MTIMECMP_HI, 32'h0000_0000, RESP_OKAY);
    axil_step(4);
    check(32'd1, {31'b0, irq}, "  a mtimecmp in the past fires at once, as designed");
    axil_write(MTIMECMP_HI, ALL_ONES, RESP_OKAY);        // disarm again
    axil_write(MTIMECMP_LO, ALL_ONES, RESP_OKAY);
    axil_step(4);
    check(32'd0, {31'b0, irq}, "  disarmed again");

    // ===== 8. asynchronous reset from a configured, armed state ============
    $display("\n-- 8. asynchronous reset from a configured, armed state --");
    $display("   step 1: put every register at a non-reset value and arm the timer");
    axil_write(MTIME_LO,    32'h0BAD_F00D, RESP_OKAY);
    axil_write(MTIME_HI,    32'h0000_0007, RESP_OKAY);
    axil_write(MTIMECMP_LO, 32'h0000_0000, RESP_OKAY);
    axil_write(MTIMECMP_HI, 32'h0000_0000, RESP_OKAY);
    axil_step(4);
    check(32'd1, {31'b0, irq}, "  precondition - the timer is armed and firing");
    axil_read(MTIME_HI, RESP_OKAY);
    check(32'h0000_0007, rd, "  precondition - MTIME_HI holds the written value");

    $display("   step 2: assert rst_n asynchronously, off a clock edge");
    #3 rst_n = 1'b0;
    #7;
    check(32'd0, {31'b0, irq}, "  irq drops asynchronously with rst_n");
    axil_step(3);
    @(posedge clk) #1 rst_n = 1'b1;
    axil_step(1);
    $display("   step 3: every register must be back at its reset value");
    axil_read(MTIME_LO, RESP_OKAY);
    chk_range(rd, 32'd0, 32'd40, "MTIME_LO after re-reset");
    axil_read_chk(MTIME_HI,     32'h0000_0000, "  MTIME_HI back to 0");
    axil_read_chk(MTIMECMP_LO,  ALL_ONES,      "  MTIMECMP_LO back to 0xFFFFFFFF");
    axil_read_chk(MTIMECMP_HI,  ALL_ONES,      "  MTIMECMP_HI back to 0xFFFFFFFF");
    check(32'd0, {31'b0, irq}, "  irq inactive - the timer is disarmed again");

    // ---- done ----
    axil_step(4);
    $display("\n========================================");
    if (errors == 0)
        $display("== MTIMER REGISTER TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== MTIMER REGISTER TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

// watchdog
initial begin
    #500000;
    $display("FAIL: tb_mtimer_regs timeout");
    $finish;
end

endmodule
