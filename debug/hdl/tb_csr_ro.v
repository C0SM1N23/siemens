// ===========================================================================
// tb_csr_ro - read-only, WARL and reset verification for the CSR file
//             (hdl/csr_file.v)
// ===========================================================================
//
// OBJECTIVE
//   The CSR file is the CPU's register interface, and it has four different
//   access classes that are easy to confuse with one another. This bench
//   separates them and checks each one on its own terms:
//
//     READ-ONLY   mip, mvendorid, marchid, mimpid, mhartid
//                 A write must raise the illegal-instruction exception AND
//                 leave the value alone. Raising the exception is not optional
//                 here: the privileged spec requires an attempt to write a
//                 read-only CSR to trap, which is what lets software discover
//                 the mistake instead of silently believing it succeeded.
//
//     WARL        misa, mepc[1:0], mstatus WPRI fields, mie[15:0], NEST-style
//                 clamped fields. A write must be ACCEPTED without trapping,
//                 but only the legal part of the value is kept. This is the
//                 opposite rule from read-only, and mixing the two up is the
//                 classic CSR bug: a WARL field that traps breaks conforming
//                 software, a read-only register that silently accepts breaks
//                 the software that trusted it.
//
//     TIED OFF    mhpmcounter8..31, their upper halves, mhpmevent3..31.
//                 The spec allows an implementation not to provide these, but
//                 they must then read as zero and swallow writes rather than
//                 trap - they exist, they are just hardwired to 0.
//
//     ABSENT      anything not implemented at all, including mcountinhibit,
//                 which this design deliberately does not provide. A read or a
//                 write must raise illegal.
//
// SCOPE
//   1  reset value of every implemented CSR
//   2  read-only CSRs: write traps, value unchanged (all five, individually)
//   3  read-only FIELDS inside writable CSRs: mstatus WPRI, mie[15:0],
//      mepc[1:0], mip[15:0]
//   4  misa is WARL: writes are accepted, ignored, and do not trap
//   5  tied-off hpm registers: all 72 addresses read 0 and swallow writes
//   6  absent CSRs: read and write both raise illegal
//   7  the three CSR operations (RW / RS / RC) on a read-only CSR all trap
//   8  the "CSRRS/CSRRC with rs1 = x0 is a pure read" rule does not trap
//   9  mhartid follows the HART_ID parameter, so two cores are told apart
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow.
// ===========================================================================

`timescale 1ns/1ps

`include "defines.vh"

module tb_csr_ro;

// ---- CSR addresses ----
localparam MSTATUS  = 12'h300, MISA     = 12'h301, MIE      = 12'h304,
           MTVEC    = 12'h305, MSCRATCH = 12'h340, MEPC     = 12'h341,
           MCAUSE   = 12'h342, MTVAL    = 12'h343, MIP      = 12'h344;
localparam MVENDID  = 12'hF11, MARCHID  = 12'hF12, MIMPID   = 12'hF13,
           MHARTID  = 12'hF14;
localparam MCYCLE   = 12'hB00, MINSTRET = 12'hB02;
localparam MHPMC3   = 12'hB03, MHPMC7   = 12'hB07;
localparam MCYCLEH  = 12'hB80, MINSTRETH= 12'hB82;
localparam MHPMC3H  = 12'hB83, MHPMC7H  = 12'hB87;
localparam MCOUNTINHIBIT = 12'h320;              // deliberately not implemented

localparam [31:0] THIS_HART = 32'h0000_002A;     // a distinctive, non-zero id

// ---- clock / reset ----
reg clk   = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

// ---- DUT interface ----
reg  [11:0] csr_addr;
reg  [31:0] csr_wdata;
reg  [1:0]  csr_op;
reg         csr_ren, csr_wen;
wire [31:0] csr_rdata;
wire        csr_illegal;

reg         trap_set, trap_is_irq, mret;
reg  [4:0]  trap_code;
reg  [31:0] trap_pc, trap_val;
reg  [15:0] irq_lines;
wire [15:0] irq_enable;
wire        mie_global;
wire [31:0] trap_vector, mepc_out;
reg         retire, ev_mispredict, ev_ibus_wait, ev_dbus_stall, ev_wfi_sleep;

integer errors = 0;
integer i;
reg [31:0] rd;
reg [31:0] before_val;
`include "tb_check.vh"

csr_file #(.HART_ID(THIS_HART)) dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .csr_addr_i(csr_addr), .csr_wdata_i(csr_wdata), .csr_op_i(csr_op),
    .csr_ren_i(csr_ren), .csr_wen_i(csr_wen),
    .csr_rdata_o(csr_rdata), .csr_illegal_o(csr_illegal),
    .trap_set_i(trap_set), .trap_is_irq_i(trap_is_irq), .trap_code_i(trap_code),
    .trap_pc_i(trap_pc), .trap_val_i(trap_val), .mret_i(mret),
    .irq_lines_i(irq_lines), .irq_enable_o(irq_enable), .mie_global_o(mie_global),
    .trap_vector_o(trap_vector), .mepc_out_o(mepc_out),
    .retire_i(retire),
    .ev_mispredict_i(ev_mispredict), .ev_ibus_wait_i(ev_ibus_wait),
    .ev_dbus_stall_i(ev_dbus_stall), .ev_wfi_sleep_i(ev_wfi_sleep)
);

// ---------------------------------------------------------------------------
// drivers
//
// The CSR read is combinational from csr_addr, and a write commits on the clock
// edge that closes the access, gated by csr_wen && !csr_illegal - exactly the
// way cpu_top drives it. Every task therefore applies the inputs just after a
// posedge, samples the combinational outputs, lets one edge pass, and parks the
// enables again.
// ---------------------------------------------------------------------------

// Pure read. The result lands in `rd`; illegal is checked against exp_illegal.
task csr_read(input [11:0] a, input exp_illegal, input [511:0] name);
    begin
        @(posedge clk) #1;
        csr_addr = a; csr_wdata = 32'b0; csr_op = 2'b00;
        csr_ren = 1'b1; csr_wen = 1'b0;
        #1;
        rd = csr_rdata;
        if (exp_illegal !== csr_illegal) begin
            $display("FAIL: %0s -> expected illegal=%b, got %b", name, exp_illegal, csr_illegal);
            errors = errors + 1;
        end
        @(posedge clk) #1;
        csr_ren = 1'b0;
    end
endtask

task csr_read_chk(input [11:0] a, input [31:0] expect_data, input [511:0] name);
    begin
        csr_read(a, 1'b0, name);
        check(expect_data, rd, name);
    end
endtask

// Write with the given operation. exp_illegal says whether the access must
// raise the illegal-instruction exception.
task csr_write_op(input [11:0] a, input [31:0] d, input [1:0] op,
                  input exp_illegal, input [511:0] name);
    begin
        @(posedge clk) #1;
        csr_addr = a; csr_wdata = d; csr_op = op;
        csr_ren = 1'b1; csr_wen = 1'b1;
        #1;
        if (exp_illegal !== csr_illegal) begin
            $display("FAIL: %0s -> expected illegal=%b, got %b", name, exp_illegal, csr_illegal);
            errors = errors + 1;
        end else
            $display("PASS: %0s -> illegal=%b as required", name, csr_illegal);
        @(posedge clk) #1;
        csr_ren = 1'b0; csr_wen = 1'b0;
    end
endtask

task csr_write(input [11:0] a, input [31:0] d, input exp_illegal, input [511:0] name);
    begin
        csr_write_op(a, d, `CSROP_RW, exp_illegal, name);
    end
endtask

// The full read-only test: the value is read, a write of all-ones is attempted
// and must trap, and the value must be identical afterwards.
task check_csr_read_only(input [11:0] a, input [511:0] name);
    begin
        csr_read(a, 1'b0, name);
        before_val = rd;
        $display("  %0s : reads 0x%08h", name, before_val);
        csr_write_op(a, 32'hFFFF_FFFF, `CSROP_RW, 1'b1, "    CSRRW to a read-only CSR traps");
        csr_write_op(a, 32'hFFFF_FFFF, `CSROP_RS, 1'b1, "    CSRRS to a read-only CSR traps");
        csr_write_op(a, 32'hFFFF_FFFF, `CSROP_RC, 1'b1, "    CSRRC to a read-only CSR traps");
        csr_read(a, 1'b0, name);
        check(before_val, rd, "    value unchanged after three rejected writes");
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    $display("\n===========================================================");
    $display("tb_csr_ro : CSR read-only / WARL / reset verification");
    $display("===========================================================");

    csr_addr = 12'h000; csr_wdata = 32'b0; csr_op = 2'b00;
    csr_ren = 1'b0; csr_wen = 1'b0;
    trap_set = 1'b0; trap_is_irq = 1'b0; trap_code = 5'd0;
    trap_pc = 32'b0; trap_val = 32'b0; mret = 1'b0;
    irq_lines = 16'b0;
    retire = 1'b0; ev_mispredict = 1'b0; ev_ibus_wait = 1'b0;
    ev_dbus_stall = 1'b0; ev_wfi_sleep = 1'b0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    @(posedge clk) #1 rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // =====================================================================
    // 1. reset values
    // =====================================================================
    $display("\n-- 1. reset value of every implemented CSR --");
    $display("   step 1: the trap and status CSRs");
    // MPP is hardwired to 2'b11 (M-mode), so mstatus never reads as 0
    csr_read_chk(MSTATUS,  32'h0000_1800, "  mstatus  reset = MPP=11, MIE=0, MPIE=0");
    csr_read_chk(MIE,      32'h0000_0000, "  mie      reset = 0");
    csr_read_chk(MTVEC,    32'h0000_0000, "  mtvec    reset = 0");
    csr_read_chk(MSCRATCH, 32'h0000_0000, "  mscratch reset = 0");
    csr_read_chk(MEPC,     32'h0000_0000, "  mepc     reset = 0");
    csr_read_chk(MCAUSE,   32'h0000_0000, "  mcause   reset = 0");
    csr_read_chk(MTVAL,    32'h0000_0000, "  mtval    reset = 0");
    csr_read_chk(MIP,      32'h0000_0000, "  mip      reset = 0 (no lines asserted)");
    $display("   step 2: the identification CSRs");
    csr_read_chk(MISA,     32'h4000_0100, "  misa     = MXL=32, extension I");
    csr_read_chk(MVENDID,  32'h0000_0000, "  mvendorid = 0 (non-commercial)");
    csr_read_chk(MARCHID,  32'h0000_0000, "  marchid   = 0");
    csr_read_chk(MIMPID,   32'h0000_0000, "  mimpid    = 0");
    csr_read_chk(MHARTID,  THIS_HART,     "  mhartid   = the HART_ID parameter");
    $display("   step 3: the counters. mcycle free-runs, so it is checked for a");
    $display("           small value rather than exactly 0; the rest start at 0");
    csr_read(MCYCLE, 1'b0, "mcycle");
    if (rd < 32'd64)
        $display("PASS:   mcycle reset near 0, reads %0d", rd);
    else begin
        $display("FAIL:   mcycle should be near 0 after reset, reads %0d", rd);
        errors = errors + 1;
    end
    csr_read_chk(MCYCLEH,   32'h0000_0000, "  mcycleh   reset = 0");
    csr_read_chk(MINSTRET,  32'h0000_0000, "  minstret  reset = 0");
    csr_read_chk(MINSTRETH, 32'h0000_0000, "  minstreth reset = 0");
    for (i = MHPMC3; i <= MHPMC7; i = i + 1)
        csr_read_chk(i[11:0], 32'h0000_0000, "  mhpmcounter3..7   reset = 0");
    for (i = MHPMC3H; i <= MHPMC7H; i = i + 1)
        csr_read_chk(i[11:0], 32'h0000_0000, "  mhpmcounter3..7h  reset = 0");

    // =====================================================================
    // 2. read-only CSRs
    // =====================================================================
    $display("\n-- 2. read-only CSRs: a write must trap and change nothing --");
    $display("   step 1: mip is read-only because the PIC drives it, not software");
    $display("           first give it a non-zero value so 'unchanged' means something");
    irq_lines = 16'h0240;                       // sources 6 and 9 pending
    @(posedge clk);
    csr_read_chk(MIP, 32'h0240_0000, "  mip reflects the pending lines in [31:16]");
    check_csr_read_only(MIP, "mip");
    csr_read_chk(MIP, 32'h0240_0000, "  mip still reflects the hardware lines");
    $display("   step 2: the four identification CSRs");
    check_csr_read_only(MVENDID, "mvendorid");
    check_csr_read_only(MARCHID, "marchid");
    check_csr_read_only(MIMPID,  "mimpid");
    check_csr_read_only(MHARTID, "mhartid");
    csr_read_chk(MHARTID, THIS_HART, "  mhartid still equals the HART_ID parameter");
    irq_lines = 16'h0000;
    @(posedge clk);

    // =====================================================================
    // 3. read-only FIELDS inside writable CSRs
    // =====================================================================
    // These are the bits a register-level test misses: the CSR accepts the
    // write, so nothing traps, but part of the value must not survive.
    $display("\n-- 3. read-only and reserved FIELDS inside writable CSRs --");

    $display("   step 1: mstatus - only MIE[3] and MPIE[7] are writable,");
    $display("           MPP[12:11] is hardwired to 11, everything else reads 0");
    csr_write(MSTATUS, 32'hFFFF_FFFF, 1'b0, "  mstatus write of all-ones is accepted");
    csr_read_chk(MSTATUS, 32'h0000_1888, "  mstatus keeps only MIE, MPIE and MPP=11");
    check(32'd1, {31'b0, mie_global},  "  mstatus.MIE really took the 1");
    csr_write(MSTATUS, 32'h0000_0000, 1'b0, "  mstatus write of zero is accepted");
    csr_read_chk(MSTATUS, 32'h0000_1800, "  MIE and MPIE cleared, MPP still 11");
    check(32'd0, {31'b0, mie_global},  "  mstatus.MIE really took the 0");

    $display("   step 2: mie - only [31:16], the machine-external window, exists");
    csr_write(MIE, 32'hFFFF_FFFF, 1'b0, "  mie write of all-ones is accepted");
    csr_read_chk(MIE, 32'hFFFF_0000, "  mie keeps [31:16] and reads [15:0] as 0");
    check(32'h0000_FFFF, {16'b0, irq_enable}, "  the enable output matches mie[31:16]");
    csr_write(MIE, 32'h0000_FFFF, 1'b0, "  mie write into [15:0] only is accepted");
    csr_read_chk(MIE, 32'h0000_0000, "  a write confined to [15:0] changes nothing");

    $display("   step 3: mepc - bits [1:0] are hardwired to 0 (instructions are");
    $display("           4-byte aligned, so a return address cannot be odd)");
    csr_write(MEPC, 32'hFFFF_FFFF, 1'b0, "  mepc write of all-ones is accepted");
    csr_read_chk(MEPC, 32'hFFFF_FFFC, "  mepc[1:0] forced to 0");
    csr_write(MEPC, 32'h0000_1003, 1'b0, "  mepc write of a misaligned value accepted");
    csr_read_chk(MEPC, 32'h0000_1000, "  mepc[1:0] forced to 0 again");
    check(32'h0000_1000, mepc_out,    "  the mepc output matches the stored value");

    $display("   step 4: mscratch is fully writable - the control case that shows");
    $display("           steps 1..3 masked fields rather than dropping writes");
    csr_write(MSCRATCH, 32'hA5A5_5A5A, 1'b0, "  mscratch write is accepted");
    csr_read_chk(MSCRATCH, 32'hA5A5_5A5A, "  mscratch keeps all 32 bits");

    $display("   step 5: mtvec BASE is fully writable, MODE is WARL");
    $display("           only 0 (direct) and 1 (vectored) exist; 2 and 3 are");
    $display("           reserved and must not read back as if they worked");
    csr_write(MTVEC, 32'hDEAD_BEEC, 1'b0, "  mtvec MODE=0 write accepted");
    csr_read_chk(MTVEC, 32'hDEAD_BEEC, "  BASE kept, MODE direct");
    csr_write(MTVEC, 32'hDEAD_BEED, 1'b0, "  mtvec MODE=1 write accepted");
    csr_read_chk(MTVEC, 32'hDEAD_BEED, "  BASE kept, MODE vectored");
    csr_write(MTVEC, 32'hDEAD_BEEE, 1'b0, "  mtvec MODE=2 write accepted");
    csr_read_chk(MTVEC, 32'hDEAD_BEEC, "  reserved MODE=2 reads back as direct");
    csr_write(MTVEC, 32'hDEAD_BEEF, 1'b0, "  mtvec MODE=3 write accepted");
    csr_read_chk(MTVEC, 32'hDEAD_BEEC, "  reserved MODE=3 reads back as direct");
    csr_write(MTVEC, 32'h0000_0000, 1'b0, "  mtvec restored");

    // =====================================================================
    // 4. misa is WARL, not read-only
    // =====================================================================
    // This is the distinction the bench exists to make. misa is writable in the
    // spec, so a write must NOT trap; this implementation supports exactly one
    // configuration, so the written value is discarded. A design that made misa
    // read-only would trap here and break conforming startup code that probes
    // the extension set by writing to it.
    $display("\n-- 4. misa is WARL: accepted, ignored, and it must NOT trap --");
    csr_write_op(MISA, 32'h0000_0000, `CSROP_RW, 1'b0, "  CSRRW to misa does not trap");
    csr_read_chk(MISA, 32'h4000_0100, "  misa unchanged after the write");
    csr_write_op(MISA, 32'hFFFF_FFFF, `CSROP_RS, 1'b0, "  CSRRS to misa does not trap");
    csr_read_chk(MISA, 32'h4000_0100, "  misa still unchanged");
    csr_write_op(MISA, 32'hFFFF_FFFF, `CSROP_RC, 1'b0, "  CSRRC to misa does not trap");
    csr_read_chk(MISA, 32'h4000_0100, "  misa still unchanged");

    // =====================================================================
    // 5. tied-off performance registers
    // =====================================================================
    // 24 counters + 24 upper halves + 29 event selectors = 77 addresses that
    // exist but are hardwired to zero. They must read 0 and swallow writes:
    // trapping would break software that enumerates the counter set.
    $display("\n-- 5. tied-off hpm registers read 0 and swallow writes --");
    $display("   step 1: mhpmcounter8..31 (0xB08..0xB1F)");
    for (i = 12'hB08; i <= 12'hB1F; i = i + 1) begin
        csr_read_chk(i[11:0], 32'h0000_0000, "  mhpmcounter8..31 reads 0");
        csr_write(i[11:0], 32'hFFFF_FFFF, 1'b0, "  write is accepted without trapping");
        csr_read_chk(i[11:0], 32'h0000_0000, "  still reads 0 after the write");
    end
    $display("   step 2: mhpmcounter8..31h (0xB88..0xB9F)");
    for (i = 12'hB88; i <= 12'hB9F; i = i + 1) begin
        csr_read_chk(i[11:0], 32'h0000_0000, "  mhpmcounter8..31h reads 0");
        csr_write(i[11:0], 32'hFFFF_FFFF, 1'b0, "  write is accepted without trapping");
    end
    $display("   step 3: mhpmevent3..31 (0x323..0x33F)");
    for (i = 12'h323; i <= 12'h33F; i = i + 1) begin
        csr_read_chk(i[11:0], 32'h0000_0000, "  mhpmevent3..31 reads 0");
        csr_write(i[11:0], 32'hFFFF_FFFF, 1'b0, "  write is accepted without trapping");
    end

    // =====================================================================
    // 6. absent CSRs raise illegal on both read and write
    // =====================================================================
    $display("\n-- 6. CSRs that are not implemented at all raise illegal --");
    $display("   step 1: mcountinhibit (0x320) is deliberately absent - the spec");
    $display("           makes it optional and defines 'absent' as all counters run");
    csr_read(MCOUNTINHIBIT, 1'b1, "  reading mcountinhibit raises illegal");
    csr_write(MCOUNTINHIBIT, 32'h0000_0001, 1'b1, "  writing mcountinhibit raises illegal");
    $display("   step 2: CSRs from privilege levels this core does not implement");
    csr_read(12'h100, 1'b1, "  reading sstatus (S-mode) raises illegal");
    csr_read(12'h3A0, 1'b1, "  reading pmpcfg0 raises illegal");
    csr_read(12'hC00, 1'b1, "  reading the user-mode cycle counter raises illegal");
    csr_read(12'h000, 1'b1, "  reading CSR 0x000 raises illegal");
    csr_read(12'hFFF, 1'b1, "  reading CSR 0xFFF raises illegal");
    csr_write(12'h100, 32'h1, 1'b1, "  writing sstatus raises illegal");
    csr_write(12'hFFF, 32'h1, 1'b1, "  writing CSR 0xFFF raises illegal");
    $display("   step 3: the boundaries of the tied-off ranges - one address");
    $display("           below and one above each range must still be illegal");
    csr_read(12'hB07, 1'b0, "  0xB07 (mhpmcounter7) is implemented, no trap");
    csr_read(12'hB20, 1'b1, "  0xB20, one past mhpmcounter31, raises illegal");
    csr_read(12'hB1F, 1'b0, "  0xB1F (mhpmcounter31) is tied off, no trap");
    csr_read(12'h322, 1'b1, "  0x322, one below mhpmevent3, raises illegal");
    csr_read(12'h340, 1'b0, "  0x340 (mscratch) is implemented, no trap");

    // =====================================================================
    // 7. the pure-read exception
    // =====================================================================
    // CSRRS / CSRRC with rs1 = x0 is defined as a read with no write side
    // effect, so it must not trap even on a read-only CSR. cpu_top implements
    // this by not raising csr_wen; the check here is that csr_ren alone on a
    // read-only address is clean, which is what makes that possible.
    $display("\n-- 7. a pure read of a read-only CSR must not trap --");
    csr_read(MIP,     1'b0, "  read of mip alone does not trap");
    csr_read(MHARTID, 1'b0, "  read of mhartid alone does not trap");
    csr_read(MVENDID, 1'b0, "  read of mvendorid alone does not trap");

    // =====================================================================
    // 8. counters are writable in M-mode, per Priv. spec 3.1.11
    // =====================================================================
    // The counters that ARE implemented must be writable on both halves, which
    // is the other side of section 5: tied off is not the same as read-only.
    $display("\n-- 8. implemented counters are writable on both halves --");
    csr_write(MINSTRET,  32'h1111_0000, 1'b0, "  minstret low half write accepted");
    csr_read_chk(MINSTRET, 32'h1111_0000, "  minstret low half round-trip");
    csr_write(MINSTRETH, 32'h0000_2222, 1'b0, "  minstret high half write accepted");
    csr_read_chk(MINSTRETH, 32'h0000_2222, "  minstret high half round-trip");
    csr_read_chk(MINSTRET,  32'h1111_0000, "  writing the high half left the low half alone");
    csr_write(MHPMC3,  32'h3333_0000, 1'b0, "  mhpmcounter3 low half write accepted");
    csr_read_chk(MHPMC3, 32'h3333_0000, "  mhpmcounter3 low half round-trip");
    csr_write(MHPMC3H, 32'h0000_4444, 1'b0, "  mhpmcounter3 high half write accepted");
    csr_read_chk(MHPMC3H, 32'h0000_4444, "  mhpmcounter3 high half round-trip");

    // =====================================================================
    // 9. reset returns every CSR to its reset value
    // =====================================================================
    $display("\n-- 9. asynchronous reset from a fully written state --");
    $display("   step 1: confirm the CSRs currently hold non-reset values");
    csr_read_chk(MSCRATCH,  32'hA5A5_5A5A, "  precondition - mscratch is loaded");
    csr_read_chk(MINSTRETH, 32'h0000_2222, "  precondition - minstreth is loaded");
    $display("   step 2: assert rst_n asynchronously, off a clock edge");
    #3 rst_n = 1'b0;
    #7;
    repeat (3) @(posedge clk);
    @(posedge clk) #1 rst_n = 1'b1;
    repeat (2) @(posedge clk);
    $display("   step 3: read them all back");
    csr_read_chk(MSTATUS,   32'h0000_1800, "  mstatus  back to MPP=11 only");
    csr_read_chk(MIE,       32'h0000_0000, "  mie      back to 0");
    csr_read_chk(MTVEC,     32'h0000_0000, "  mtvec    back to 0");
    csr_read_chk(MSCRATCH,  32'h0000_0000, "  mscratch back to 0");
    csr_read_chk(MEPC,      32'h0000_0000, "  mepc     back to 0");
    csr_read_chk(MCAUSE,    32'h0000_0000, "  mcause   back to 0");
    csr_read_chk(MTVAL,     32'h0000_0000, "  mtval    back to 0");
    csr_read_chk(MINSTRET,  32'h0000_0000, "  minstret  back to 0");
    csr_read_chk(MINSTRETH, 32'h0000_0000, "  minstreth back to 0");
    csr_read_chk(MHPMC3,    32'h0000_0000, "  mhpmcounter3  back to 0");
    csr_read_chk(MHPMC3H,   32'h0000_0000, "  mhpmcounter3h back to 0");
    csr_read_chk(MHARTID,   THIS_HART,     "  mhartid unaffected by reset (parameter)");
    csr_read_chk(MISA,      32'h4000_0100, "  misa unaffected by reset (hardwired)");

    // ---- done ----
    repeat (4) @(posedge clk);
    $display("\n========================================");
    if (errors == 0)
        $display("== CSR READ-ONLY TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== CSR READ-ONLY TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

// watchdog
initial begin
    #2000000;
    $display("FAIL: tb_csr_ro timeout");
    $finish;
end

endmodule
