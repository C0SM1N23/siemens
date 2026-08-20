// ===========================================================================
// tb_pic_ro - read-only and reserved-bit verification for the PIC (hdl/pic.v)
// ===========================================================================
//
// OBJECTIVE
//   Prove that every part of the PIC register map that the specification calls
//   read-only really is read-only, and that every bit position the map calls
//   reserved really is hardwired to zero.
//
//   "Read-only" is two separate promises, and a test that checks only one of
//   them is not a test:
//     (a) the access is REJECTED - the write answers SLVERR, so software finds
//         out rather than silently believing it changed something;
//     (b) the state is UNCHANGED - the register still holds what the hardware
//         put there.
//   Promise (b) is only meaningful if the register holds a non-trivial value at
//   the time of the attempt. Writing 0 to a register that already reads 0 and
//   then observing 0 proves nothing at all. So every read-only register in this
//   bench is first driven to a known NON-ZERO value by real hardware activity,
//   and only then written to.
//
// SCOPE - every read-only object in the map is covered, none by sampling:
//   1  SRC0_STATUS .. SRC15_STATUS   16 registers, all 16 indices attempted
//   2  NEST_STATUS                    whole register
//   3  ACTIVE_VEC                     whole register
//   4  unmapped offsets               0xE0 .. 0xFC, read and write
//   5  reserved bits inside writable registers, register by register
//   6  SRCx_SW_TRIG.KEY               write-only field, must read back as 0
//   7  W1C registers                  a written 0 must NOT clear a set bit
//   8  NEST_MAX                       WARL clamping of out-of-range writes
//   9  byte-strobe writes             a single-lane write to a read-only
//                                     register is still rejected
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow.
// ===========================================================================

`timescale 1ns/1ps

module tb_pic_ro;

// ---- register map (byte offsets) ----
localparam CFG0 = 32'h00, SWT0 = 32'h40, STA0 = 32'h80;
localparam BAND_CONFIG   = 32'hC0, NEST_STATUS  = 32'hC4, NEST_MAX_R = 32'hC8,
           ACTIVE_VEC    = 32'hCC, SPURIOUS_LOG = 32'hD0, ESCALATION = 32'hD4,
           INT_ENABLE    = 32'hD8, INT_STATUS   = 32'hDC;
localparam RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;
localparam SW_KEY = 16'hA5A5;

localparam ALL_ONES = 32'hFFFF_FFFF;

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
reg [31:0] before_val;
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

// per-source register address helpers
function [31:0] CFG; input [31:0] k; CFG = CFG0 + (k << 2); endfunction
function [31:0] SWT; input [31:0] k; SWT = SWT0 + (k << 2); endfunction
function [31:0] STA; input [31:0] k; STA = STA0 + (k << 2); endfunction

// ---------------------------------------------------------------------------
// The read-only test, as one reusable four-step sequence:
//   1  read the register and remember what the hardware put there
//   2  require it to be non-zero, so step 4 can actually prove something
//   3  write `pattern` to it and require SLVERR
//   4  read it back and require the value to be identical to step 1
//
// `cmp_mask` selects the bits that are stable across the write attempt. It is
// all-ones for a register that holds still, and narrower for SRCx_STATUS, whose
// top half is a free-running deadline counter that legitimately changes between
// the two reads. The counter is not left untested: it is checked separately,
// against the stronger property that it keeps counting rather than taking the
// written value (see check_ro_counter below).
// ---------------------------------------------------------------------------
task check_read_only(input [31:0] a, input [31:0] pattern, input [31:0] cmp_mask,
                     input [511:0] name);
    begin
        axil_read(a, RESP_OKAY);
        before_val = rd;
        if ((before_val & cmp_mask) == 32'd0) begin
            $display("FAIL: %0s - precondition, the compared bits are 0 so the test is vacuous", name);
            errors = errors + 1;
        end
        $display("  %0s : holds 0x%08h before the write attempt", name, before_val);
        axil_write(a, pattern, RESP_SLVERR);
        $display("       write of 0x%08h rejected with SLVERR", pattern);
        axil_read(a, RESP_OKAY);
        check(before_val & cmp_mask, rd & cmp_mask,
              "       compared bits unchanged after the rejected write");
    end
endtask

// A read-only field that is a live counter cannot be checked by "unchanged".
// The property that matters is that it kept counting on its own instead of
// taking the value the rejected write carried, so check both: it advanced, and
// it is not the written pattern.
task check_ro_counter(input [31:0] a, input [511:0] name);
    reg [15:0] t0, t1;
    begin
        axil_read(a, RESP_OKAY);
        t0 = rd[31:16];
        axil_write(a, ALL_ONES, RESP_SLVERR);
        axil_read(a, RESP_OKAY);
        t1 = rd[31:16];
        if (t1 == 16'hFFFF) begin
            $display("FAIL: %0s took the written value 0xFFFF", name);
            errors = errors + 1;
        end else if (t1 <= t0) begin
            $display("FAIL: %0s did not advance across the rejected write (0x%04h -> 0x%04h)",
                     name, t0, t1);
            errors = errors + 1;
        end else
            $display("PASS: %0s kept counting across the rejected write (0x%04h -> 0x%04h)",
                     name, t0, t1);
    end
endtask

// Reserved bits: write all-ones into the register, then require the reserved
// positions to read back as 0 while the live positions keep the value.
task check_reserved(input [31:0] a, input [31:0] resv_mask, input [511:0] name);
    begin
        axil_write(a, ALL_ONES, RESP_OKAY);
        axil_read(a, RESP_OKAY);
        check(32'd0, rd & resv_mask, name);
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    $display("\n===========================================================");
    $display("tb_pic_ro : read-only and reserved-bit verification, hdl/pic.v");
    $display("===========================================================");

    irq_src = 16'b0; cpu_irq_ack = 1'b0; cpu_irq_eoi = 1'b0;
    axil_idle;
    rst_n = 1'b0;
    axil_step(4);
    @(posedge clk) #1 rst_n = 1'b1;
    axil_step(2);

    // =====================================================================
    // 1. SRC0_STATUS .. SRC15_STATUS : 16 read-only registers
    // =====================================================================
    $display("\n-- 1. SRCx_STATUS (0x80 + 4*x), read-only, all 16 indices --");
    $display("   step 1: enable all 16 sources so a raised line becomes a request");
    axil_write(INT_ENABLE, 32'h0000_FFFF, RESP_OKAY);
    $display("   step 2: give every source the maximum deadline, so DDL_TIMER[31:16]");
    $display("           runs (making the register hardware-driven and non-zero)");
    $display("           without ever reaching the deadline inside this run");
    for (i = 0; i < 16; i = i + 1)
        axil_write(CFG(i), 32'hFFFF_0000, RESP_OKAY);   // deadline 65535, band 0, level
    $display("   step 3: raise all 16 source lines and let the timers advance");
    irq_src = 16'hFFFF;
    axil_step(10);
    $display("   step 4: for each index, attempt a write and require SLVERR + no change");
    $display("           on the six state bits PEND/ACTIVE/ESC/SPUR/EFF_BAND");
    for (i = 0; i < 16; i = i + 1)
        check_read_only(STA(i), ALL_ONES, 32'h0000_003F, "SRCx_STATUS");
    $display("   step 5: the DDL_TIMER field is a live counter, so check the stronger");
    $display("           property: it keeps counting instead of taking the written value");
    for (i = 0; i < 16; i = i + 1)
        check_ro_counter(STA(i), "SRCx_STATUS.DDL_TIMER");

    $display("   step 6: the same 16 registers must also reject a write of 0");
    $display("           (a rejected write is not allowed to depend on the data)");
    for (i = 0; i < 16; i = i + 1) begin
        axil_read(STA(i), RESP_OKAY);
        before_val = rd;
        axil_write(STA(i), 32'h0000_0000, RESP_SLVERR);
        axil_read(STA(i), RESP_OKAY);
        check(before_val & 32'h0000_003F, rd & 32'h0000_003F,
              "  SRCx_STATUS state bits unchanged after a rejected write of 0");
    end

    // =====================================================================
    // 2. NEST_STATUS : read-only
    // =====================================================================
    $display("\n-- 2. NEST_STATUS (0xC4), read-only --");
    $display("   step 1: claim one interrupt so DEPTH and TOP_ID are both non-zero");
    axil_step(2);
    @(posedge clk) #1 cpu_irq_ack = 1'b1; @(posedge clk) #1 cpu_irq_ack = 1'b0;
    axil_step(3);
    $display("   step 2: attempt a write, require SLVERR and an unchanged value");
    check_read_only(NEST_STATUS, ALL_ONES, ALL_ONES, "NEST_STATUS");

    // =====================================================================
    // 3. ACTIVE_VEC : read-only
    // =====================================================================
    $display("\n-- 3. ACTIVE_VEC (0xCC), read-only --");
    $display("   step 1: an interrupt is still in service, so VALID and ID are set");
    check_read_only(ACTIVE_VEC, ALL_ONES, ALL_ONES, "ACTIVE_VEC");

    $display("   step 2: return from the handler, clear the sources, reset the state");
    @(posedge clk) #1 cpu_irq_eoi = 1'b1; @(posedge clk) #1 cpu_irq_eoi = 1'b0;
    irq_src = 16'h0000;
    axil_step(4);
    axil_write(INT_ENABLE, 32'h0000_0000, RESP_OKAY);
    axil_write(INT_STATUS, 32'h0000_0007, RESP_OKAY);
    for (i = 0; i < 16; i = i + 1)
        axil_write(CFG(i), 32'h0000_0000, RESP_OKAY);

    // =====================================================================
    // 4. unmapped offsets
    // =====================================================================
    // The map ends at word 55 (0xDC). Everything above it inside the 8-bit
    // decoded window must answer SLVERR on both directions, so a stray pointer
    // produces a precise access-fault trap in the CPU instead of a silent
    // read of 0 or a silent discarded write.
    $display("\n-- 4. unmapped offsets 0xE0 .. 0xFC, read and write --");
    for (i = 32'hE0; i <= 32'hFC; i = i + 4) begin
        axil_read(i, RESP_SLVERR);
        axil_write(i, ALL_ONES, RESP_SLVERR);
    end
    $display("PASS: all 8 unmapped words answer SLVERR on read and on write");

    // =====================================================================
    // 5. reserved bits inside writable registers
    // =====================================================================
    // Reserved bits are hardwired to zero: writing 1 into them must not stick.
    // Otherwise software that sets a "don't care" bit today acquires a
    // dependency on it, and a later revision that defines the bit breaks it.
    $display("\n-- 5. reserved bits read 0 after a write of all-ones --");

    $display("   step 1: SRCx_CONFIG - reserved [15:8] and [3], all 16 indices");
    for (i = 0; i < 16; i = i + 1) begin
        check_reserved(CFG(i), 32'h0000_FF08, "  SRCx_CONFIG reserved [15:8],[3] read 0");
        axil_read(CFG(i), RESP_OKAY);
        check(32'hFFFF_00F7, rd, "  SRCx_CONFIG live fields keep the written ones");
        axil_write(CFG(i), 32'h0000_0000, RESP_OKAY);
    end

    $display("   step 2: BAND_CONFIG - reserved [31:8]");
    check_reserved(BAND_CONFIG, 32'hFFFF_FF00, "  BAND_CONFIG reserved [31:8] read 0");
    axil_read(BAND_CONFIG, RESP_OKAY);
    check(32'h0000_00FF, rd, "  BAND_CONFIG live field [7:0] keeps the written ones");
    axil_write(BAND_CONFIG, 32'h0000_001B, RESP_OKAY);        // back to the reset value

    $display("   step 3: NEST_MAX - reserved [31:5]");
    check_reserved(NEST_MAX_R, 32'hFFFF_FFE0, "  NEST_MAX reserved [31:5] read 0");

    $display("   step 4: ESCALATION_CFG - reserved [31:9], [7:5] and [3:2]");
    check_reserved(ESCALATION, 32'hFFFF_FEEC, "  ESCALATION_CFG reserved bits read 0");
    axil_read(ESCALATION, RESP_OKAY);
    check(32'h0000_0113, rd, "  ESCALATION_CFG live fields MULTI/MODE/TARGET only");
    axil_write(ESCALATION, 32'h0000_0000, RESP_OKAY);

    $display("   step 5: INT_ENABLE - reserved [31:16]");
    check_reserved(INT_ENABLE, 32'hFFFF_0000, "  INT_ENABLE reserved [31:16] read 0");
    axil_write(INT_ENABLE, 32'h0000_0000, RESP_OKAY);

    $display("   step 6: SPURIOUS_LOG - reserved [31:16]");
    axil_read(SPURIOUS_LOG, RESP_OKAY);
    check(32'd0, rd & 32'hFFFF_0000, "  SPURIOUS_LOG reserved [31:16] read 0");

    $display("   step 7: INT_STATUS - reserved [31:3]");
    axil_read(INT_STATUS, RESP_OKAY);
    check(32'd0, rd & 32'hFFFF_FFF8, "  INT_STATUS reserved [31:3] read 0");

    $display("   step 8: SRCx_SW_TRIG - only bit [0] is readable state");
    for (i = 0; i < 16; i = i + 1) begin
        axil_write(SWT(i), ALL_ONES, RESP_OKAY);    // key field is 0xFFFF, not the key
        axil_read(SWT(i), RESP_OKAY);
        check(32'd0, rd & 32'hFFFF_FFFE, "  SRCx_SW_TRIG bits [31:1] read 0");
    end

    // =====================================================================
    // 6. SRCx_SW_TRIG.KEY is write-only
    // =====================================================================
    // The key is consumed by the write decode and is never stored, so it must
    // read back as 0. If it read back, software could discover the key by
    // reading the register, which defeats the point of having one.
    $display("\n-- 6. SRCx_SW_TRIG.KEY [31:16] is write-only and reads 0 --");
    $display("   step 1: enable source 0 and set its software channel with the real key");
    axil_write(INT_ENABLE, 32'h0000_0001, RESP_OKAY);
    axil_write(SWT(0), {SW_KEY, 16'h0001}, RESP_OKAY);
    axil_step(2);
    $display("   step 2: read the register back");
    axil_read(SWT(0), RESP_OKAY);
    check(32'h0000_0001, rd, "  SRC0_SW_TRIG reads back SWREQ=1 with KEY=0");
    check(32'd0, rd[31:16], "  KEY field is not readable");
    $display("   step 3: clear the channel again (a clear needs no key)");
    axil_write(SWT(0), 32'h0000_0000, RESP_OKAY);
    axil_read_chk(SWT(0), 32'h0000_0000, "  SRC0_SW_TRIG cleared");
    axil_write(INT_ENABLE, 32'h0000_0000, RESP_OKAY);

    // =====================================================================
    // 7. write-1-to-clear registers ignore a written 0
    // =====================================================================
    // W1C is the other half of read-only-ness: a bit software cannot SET. A
    // read-modify-write that puts a 0 back must leave a set bit alone,
    // otherwise every handler that touches the register loses events it never
    // meant to acknowledge.
    $display("\n-- 7. W1C registers: a written 0 must not clear, a written 1 must --");
    $display("   step 1: produce a spurious claim so SPURIOUS_LOG[6] and");
    $display("           INT_STATUS.SPUR are both set by hardware");
    axil_write(CFG(6), 32'h0000_0000, RESP_OKAY);
    axil_write(INT_ENABLE, 32'h0000_0040, RESP_OKAY);
    irq_src[6] = 1'b1;
    axil_step(4);
    @(posedge clk) #1 irq_src[6] = 1'b0;            // drops before the claim
    @(posedge clk) #1 cpu_irq_ack = 1'b1; @(posedge clk) #1 cpu_irq_ack = 1'b0;
    axil_step(3);
    axil_read(SPURIOUS_LOG, RESP_OKAY);
    check(32'h0000_0040, rd, "  SPURIOUS_LOG[6] set by hardware");
    axil_read(INT_STATUS, RESP_OKAY);
    check(32'h1, rd & 32'h1, "  INT_STATUS.SPUR set by hardware");

    $display("   step 2: write 0 to both registers - nothing may change");
    axil_write(SPURIOUS_LOG, 32'h0000_0000, RESP_OKAY);
    axil_write(INT_STATUS,   32'h0000_0000, RESP_OKAY);
    axil_read_chk(SPURIOUS_LOG, 32'h0000_0040, "  SPURIOUS_LOG[6] survives a written 0");
    axil_read(INT_STATUS, RESP_OKAY);
    check(32'h1, rd & 32'h1, "  INT_STATUS.SPUR survives a written 0");

    $display("   step 3: write 1 to the wrong bit - the set bit must still survive");
    axil_write(SPURIOUS_LOG, 32'h0000_0001, RESP_OKAY);
    axil_read_chk(SPURIOUS_LOG, 32'h0000_0040, "  clearing bit 0 leaves bit 6 alone");

    $display("   step 4: write 1 to the right bit - now it clears");
    axil_write(SPURIOUS_LOG, 32'h0000_0040, RESP_OKAY);
    axil_read_chk(SPURIOUS_LOG, 32'h0000_0000, "  SPURIOUS_LOG[6] cleared by W1C");
    axil_write(INT_STATUS, 32'h0000_0007, RESP_OKAY);
    axil_read_chk(INT_STATUS, 32'h0000_0000, "  INT_STATUS cleared by W1C");

    @(posedge clk) #1 cpu_irq_eoi = 1'b1; @(posedge clk) #1 cpu_irq_eoi = 1'b0;
    axil_step(3);
    axil_write(INT_ENABLE, 32'h0000_0000, RESP_OKAY);

    // =====================================================================
    // 8. NEST_MAX is WARL: out-of-range writes are clamped, not stored
    // =====================================================================
    $display("\n-- 8. NEST_MAX (0xC8) clamps out-of-range writes to [1,16] --");
    $display("   step 1: write 0 - a depth limit of 0 would mask every offer forever");
    axil_write(NEST_MAX_R, 32'd0, RESP_OKAY);
    axil_read_chk(NEST_MAX_R, 32'd1, "  NEST_MAX write of 0 stores 1");
    $display("   step 2: write 17 - above the physical stack depth of 16");
    axil_write(NEST_MAX_R, 32'd17, RESP_OKAY);
    axil_read_chk(NEST_MAX_R, 32'd16, "  NEST_MAX write of 17 stores 16");
    $display("   step 3: write 31 - the largest value the 5-bit field can carry");
    axil_write(NEST_MAX_R, 32'd31, RESP_OKAY);
    axil_read_chk(NEST_MAX_R, 32'd16, "  NEST_MAX write of 31 stores 16");
    $display("   step 4: write a legal value - it must be stored exactly");
    axil_write(NEST_MAX_R, 32'd5, RESP_OKAY);
    axil_read_chk(NEST_MAX_R, 32'd5, "  NEST_MAX write of 5 stores 5");
    axil_write(NEST_MAX_R, 32'd8, RESP_OKAY);       // back to the reset value

    // =====================================================================
    // 9. byte-strobe writes to a read-only register
    // =====================================================================
    // wr_ok is decoded from the address alone, so a narrow write must be
    // rejected exactly like a word write. A slave that only checked the full
    // word case would let a byte store slip through.
    $display("\n-- 9. narrow (byte-strobe) writes to read-only registers --");
    axil_write(INT_ENABLE, 32'h0000_0100, RESP_OKAY);
    axil_write(CFG(8), 32'h00FF_0000, RESP_OKAY);
    irq_src[8] = 1'b1;
    axil_step(6);
    axil_read(STA(8), RESP_OKAY);
    before_val = rd;
    $display("   step 1: SRC8_STATUS holds 0x%08h", before_val);
    $display("   step 2: attempt a byte write to each of the four lanes");
    axil_write_strb(STA(8), ALL_ONES, 4'b0001, RESP_SLVERR);
    axil_write_strb(STA(8), ALL_ONES, 4'b0010, RESP_SLVERR);
    axil_write_strb(STA(8), ALL_ONES, 4'b0100, RESP_SLVERR);
    axil_write_strb(STA(8), ALL_ONES, 4'b1000, RESP_SLVERR);
    $display("   step 3: attempt a write with no lanes enabled at all");
    axil_write_strb(STA(8), ALL_ONES, 4'b0000, RESP_SLVERR);
    $display("   step 4: the status bits must be exactly what they were");
    axil_read(STA(8), RESP_OKAY);
    check(before_val & 32'h0000_FFFF, rd & 32'h0000_FFFF,
          "  SRC8_STATUS status bits unchanged after 5 narrow writes");
    $display("   step 5: a narrow write to a WRITABLE register must still work,");
    $display("           proving step 2 rejected on the address, not on the strobe");
    axil_write_strb(BAND_CONFIG, 32'h0000_0027, 4'b0001, RESP_OKAY);
    axil_read_chk(BAND_CONFIG, 32'h0000_0027, "  BAND_CONFIG takes a byte-lane write");
    axil_write(BAND_CONFIG, 32'h0000_001B, RESP_OKAY);

    irq_src = 16'h0000;
    axil_write(INT_ENABLE, 32'h0000_0000, RESP_OKAY);

    // ---- done ----
    axil_step(4);
    $display("\n========================================");
    if (errors == 0)
        $display("== PIC READ-ONLY TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== PIC READ-ONLY TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

// watchdog
initial begin
    #500000;
    $display("FAIL: tb_pic_ro timeout");
    $finish;
end

endmodule
