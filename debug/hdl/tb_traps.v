// ===========================================================================
// tb_traps - one directed test per trap cause (hdl/cpu_top.v)
// ===========================================================================
//
// OBJECTIVE
//   The system bench (tb_cpu_axi) proves that all the synchronous causes are
//   reachable and counts them exactly, but it does so inside one long program
//   where the causes are interleaved. That is the right test for "the trap
//   mechanism works end to end"; it is the wrong test for "cause 6 records the
//   right mtval", because a single failing cause is one line in a hundred.
//
//   This bench gives every cause its own isolated case:
//     - the core is reset,
//     - a program of a few instructions is loaded, written so that exactly one
//       thing can go wrong and it is the thing under test,
//     - the core runs until it takes its trap,
//     - and the four architectural results are checked individually:
//         mcause, mepc, mtval, and the handler address actually entered.
//
//   Isolating them this way also makes the negative half checkable: for every
//   cause that must NOT commit its instruction or NOT issue a bus transaction,
//   that is asserted in the same case rather than inferred.
//
// CAUSES COVERED - the complete supported set from hdl/defines.vh
//    0  instruction address misaligned    (taken jump to a target with bit 1 set)
//    1  instruction access fault          (fetch outside the instruction memory)
//    2  illegal instruction               (undefined opcode)
//    3  breakpoint                        (EBREAK)
//    4  load address misaligned           (LW at addr[1:0] != 0, and LH at addr[0] = 1)
//    5  load access fault                 (LW into unmapped data space)
//    6  store address misaligned          (SW at addr[1:0] != 0, and SH at addr[0] = 1)
//    7  store access fault                (SW into unmapped data space)
//   11  environment call from M-mode      (ECALL)
//   16+n machine external interrupt       (the PIC line, vectors 0, 3 and 15)
//
//   plus mtvec vectored mode, where an interrupt must enter at BASE + 4*cause
//   while an exception still enters at BASE.
//
// METHOD
//   The core runs against two behavioural AXI4-Lite memories. The instruction
//   image is written directly into the instruction memory by the bench, one
//   hand-encoded word at a time, so each case is readable as a listing instead
//   of as an offset into a shared program. Architectural results are read from
//   the CSR file through hierarchical references after the trap is taken, which
//   is what lets the check be exact without adding a debug port to the RTL.
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow.
// ===========================================================================

`timescale 1ns/1ps

module tb_traps;

// ---- memory map for this bench ----
localparam [31:0] IMEM_BASE  = 32'h0000_0000;   // 256 words: 0x0000 .. 0x03FF
localparam [31:0] DMEM_BASE  = 32'h0000_2000;   // 256 words: 0x2000 .. 0x23FF
localparam [31:0] BAD_FETCH  = 32'h0000_8000;   // outside the instruction memory
localparam [31:0] BAD_DATA   = 32'h0000_4000;   // outside the data memory
localparam        IWORDS     = 256;

// ---- program layout ----
localparam [31:0] HANDLER    = 32'h0000_0080;   // word 32: direct-mode handler
localparam        CASE_WORD  = 2;               // the case body starts at 0x08

// ---- opcodes ----
localparam [6:0] OP_LUI    = 7'b0110111, OP_JAL   = 7'b1101111,
                 OP_JALR   = 7'b1100111, OP_LOAD  = 7'b0000011,
                 OP_STORE  = 7'b0100011, OP_OPIMM = 7'b0010011,
                 OP_SYSTEM = 7'b1110011;

localparam [31:0] NOP    = 32'h0000_0013;       // addi x0, x0, 0
localparam [31:0] ECALL  = 32'h0000_0073;
localparam [31:0] EBREAK = 32'h0010_0073;
localparam [31:0] BAD_IW = 32'hFFFF_FFFF;       // undefined opcode 1111111
localparam [31:0] MRET   = 32'h3020_0073;

// ---- CSR numbers used by the test programs ----
localparam [11:0] CSR_MSTATUS = 12'h300, CSR_MTVEC = 12'h305, CSR_MIE = 12'h304,
                  CSR_MEPC    = 12'h341;

// ---- clock / reset ----
reg clk   = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

// ---- CPU buses ----
wire [31:0] ib_araddr, ib_rdata;
wire [2:0]  ib_arprot;
wire        ib_arvalid, ib_arready, ib_rvalid, ib_rready;
wire [1:0]  ib_rresp;

wire [31:0] db_awaddr, db_wdata, db_araddr, db_rdata;
wire [2:0]  db_awprot, db_arprot;
wire [3:0]  db_wstrb;
wire        db_awvalid, db_awready, db_wvalid, db_wready, db_bvalid, db_bready;
wire        db_arvalid, db_arready, db_rvalid, db_rready;
wire [1:0]  db_bresp, db_rresp;

// ---- interrupt pins, driven directly by the bench ----
reg         cpu_irq;
reg  [3:0]  cpu_irq_vec;
wire        cpu_irq_ack, cpu_irq_eoi, cpu_in_trap;

integer errors = 0;
integer i;
reg [31:0] prog [0:IWORDS-1];
`include "tb_check.vh"

cpu_top #(.RESET_PC(IMEM_BASE)) dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .ibus_axi_araddr_o(ib_araddr), .ibus_axi_arprot_o(ib_arprot),
    .ibus_axi_arvalid_o(ib_arvalid), .ibus_axi_arready_i(ib_arready),
    .ibus_axi_rdata_i(ib_rdata), .ibus_axi_rresp_i(ib_rresp),
    .ibus_axi_rvalid_i(ib_rvalid), .ibus_axi_rready_o(ib_rready),
    .dbus_axi_awaddr_o(db_awaddr), .dbus_axi_awprot_o(db_awprot),
    .dbus_axi_awvalid_o(db_awvalid), .dbus_axi_awready_i(db_awready),
    .dbus_axi_wdata_o(db_wdata), .dbus_axi_wstrb_o(db_wstrb),
    .dbus_axi_wvalid_o(db_wvalid), .dbus_axi_wready_i(db_wready),
    .dbus_axi_bresp_i(db_bresp), .dbus_axi_bvalid_i(db_bvalid), .dbus_axi_bready_o(db_bready),
    .dbus_axi_araddr_o(db_araddr), .dbus_axi_arprot_o(db_arprot),
    .dbus_axi_arvalid_o(db_arvalid), .dbus_axi_arready_i(db_arready),
    .dbus_axi_rdata_i(db_rdata), .dbus_axi_rresp_i(db_rresp),
    .dbus_axi_rvalid_i(db_rvalid), .dbus_axi_rready_o(db_rready),
    .cpu_irq_i(cpu_irq), .cpu_irq_vec_i(cpu_irq_vec),
    .irq_pending_i(16'b0), .irq_mask_o(),
    .cpu_irq_ack_o(cpu_irq_ack), .cpu_irq_eoi_o(cpu_irq_eoi), .cpu_in_trap_o(cpu_in_trap)
);

// instruction memory: read-only from the CPU, written directly by the bench
axi_lite_mem_model #(.WORDS(IWORDS), .BASE(IMEM_BASE), .READ_LAT(0), .SEED(3)) imem (
    .clk_i(clk), .rst_n_i(rst_n),
    .awaddr_i(32'b0), .awvalid_i(1'b0), .awready_o(),
    .wdata_i(32'b0), .wstrb_i(4'b0), .wvalid_i(1'b0), .wready_o(),
    .bresp_o(), .bvalid_o(), .bready_i(1'b0),
    .araddr_i(ib_araddr), .arvalid_i(ib_arvalid), .arready_o(ib_arready),
    .rdata_o(ib_rdata), .rresp_o(ib_rresp), .rvalid_o(ib_rvalid), .rready_i(ib_rready)
);

// data memory
axi_lite_mem_model #(.WORDS(256), .BASE(DMEM_BASE), .READ_LAT(1), .WRITE_LAT(1), .SEED(5)) dmem (
    .clk_i(clk), .rst_n_i(rst_n),
    .awaddr_i(db_awaddr), .awvalid_i(db_awvalid), .awready_o(db_awready),
    .wdata_i(db_wdata), .wstrb_i(db_wstrb), .wvalid_i(db_wvalid), .wready_o(db_wready),
    .bresp_o(db_bresp), .bvalid_o(db_bvalid), .bready_i(db_bready),
    .araddr_i(db_araddr), .arvalid_i(db_arvalid), .arready_o(db_arready),
    .rdata_o(db_rdata), .rresp_o(db_rresp), .rvalid_o(db_rvalid), .rready_i(db_rready)
);

// ---------------------------------------------------------------------------
// bus-activity counters: how the "no transaction was issued" checks are made.
// A misaligned access must trap BEFORE anything reaches the bus, and an
// illegal store must never write memory; both are negative properties, so they
// need a witness that counts what did happen rather than what did not.
// ---------------------------------------------------------------------------
integer db_ar_cnt, db_aw_cnt, ack_cnt, eoi_cnt;

// eoi_at_marker samples the EOI count at the instant a handler stores to the
// marker word. The nesting cases below need to know not just how many EOIs the
// core sent but WHEN: an EOI sent one MRET too early and an EOI sent at the
// right time both leave the same total behind.
localparam [31:0] MARK_ADDR = DMEM_BASE + 32'd0;
integer eoi_at_marker;
reg     marker_seen;

always @(posedge clk) begin
    if (!rst_n) begin
        db_ar_cnt     <= 0;
        db_aw_cnt     <= 0;
        ack_cnt       <= 0;
        eoi_cnt       <= 0;
        eoi_at_marker <= -1;
        marker_seen   <= 1'b0;
    end else begin
        if (db_arvalid && db_arready) db_ar_cnt <= db_ar_cnt + 1;
        if (db_awvalid && db_awready) db_aw_cnt <= db_aw_cnt + 1;
        if (cpu_irq_ack)              ack_cnt   <= ack_cnt + 1;
        if (cpu_irq_eoi)              eoi_cnt   <= eoi_cnt + 1;
        if (db_awvalid && db_awready && db_awaddr == MARK_ADDR && !marker_seen) begin
            eoi_at_marker <= eoi_cnt;
            marker_seen   <= 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// RV32I instruction encoders. Written out in full so each test program below
// reads as a listing; the field order is the one in the unprivileged spec.
// ---------------------------------------------------------------------------
function [31:0] enc_i;
    input [11:0] imm; input [4:0] rs1; input [2:0] f3; input [4:0] rd; input [6:0] op;
    enc_i = {imm, rs1, f3, rd, op};
endfunction

function [31:0] enc_s;
    input [11:0] imm; input [4:0] rs2; input [4:0] rs1; input [2:0] f3; input [6:0] op;
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
endfunction

function [31:0] enc_u;
    input [19:0] imm20; input [4:0] rd; input [6:0] op;
    enc_u = {imm20, rd, op};
endfunction

function [31:0] enc_j;                       // imm is a signed byte offset, bit 0 = 0
    input [20:0] imm; input [4:0] rd; input [6:0] op;
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
endfunction

function [31:0] I_ADDI;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    I_ADDI = enc_i(imm, rs1, 3'b000, rd, OP_OPIMM); endfunction
function [31:0] I_LUI;   input [4:0] rd; input [19:0] imm20;
    I_LUI = enc_u(imm20, rd, OP_LUI); endfunction
function [31:0] I_LW;    input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    I_LW = enc_i(imm, rs1, 3'b010, rd, OP_LOAD); endfunction
function [31:0] I_LH;    input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    I_LH = enc_i(imm, rs1, 3'b001, rd, OP_LOAD); endfunction
function [31:0] I_SW;    input [4:0] rs2; input [4:0] rs1; input [11:0] imm;
    I_SW = enc_s(imm, rs2, rs1, 3'b010, OP_STORE); endfunction
function [31:0] I_SH;    input [4:0] rs2; input [4:0] rs1; input [11:0] imm;
    I_SH = enc_s(imm, rs2, rs1, 3'b001, OP_STORE); endfunction
function [31:0] I_JAL;   input [4:0] rd; input [20:0] off;
    I_JAL = enc_j(off, rd, OP_JAL); endfunction
function [31:0] I_JALR;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    I_JALR = enc_i(imm, rs1, 3'b000, rd, OP_JALR); endfunction
function [31:0] I_CSRRW; input [4:0] rd; input [11:0] csr; input [4:0] rs1;
    I_CSRRW = enc_i(csr, rs1, 3'b001, rd, OP_SYSTEM); endfunction
function [31:0] I_CSRRSI; input [4:0] rd; input [11:0] csr; input [4:0] uimm;
    I_CSRRSI = enc_i(csr, uimm, 3'b110, rd, OP_SYSTEM); endfunction
function [31:0] I_CSRRS;  input [4:0] rd; input [11:0] csr; input [4:0] rs1;
    I_CSRRS = enc_i(csr, rs1, 3'b010, rd, OP_SYSTEM); endfunction

// ---------------------------------------------------------------------------
// case scaffolding
// ---------------------------------------------------------------------------

// Fill the image with NOPs and put a self-loop at every handler entry the
// bench uses. The self-loop matters: after the trap the core must sit at a
// known address, which is what makes "which handler was entered" checkable.
task prog_init;
    begin
        for (i = 0; i < IWORDS; i = i + 1)
            prog[i] = NOP;
        // direct-mode handler at 0x80, and the vectored entries above it
        for (i = 32; i < 64; i = i + 1)
            prog[i] = I_JAL(5'd0, 21'd0);        // jal x0, 0  -> spin here
        // prologue: mtvec <- HANDLER, direct mode (bits [1:0] = 00)
        prog[0] = I_ADDI (5'd3, 5'd0, HANDLER[11:0]);
        prog[1] = I_CSRRW(5'd0, CSR_MTVEC, 5'd3);
    end
endtask

// Reset the core, load the image, release reset between clock edges.
task start_case(input [511:0] name);
    begin
        $display("\n-----------------------------------------------------------");
        $display("CASE: %0s", name);
        $display("-----------------------------------------------------------");
        rst_n = 1'b0;
        cpu_irq = 1'b0; cpu_irq_vec = 4'd0;
        repeat (4) @(posedge clk);
        for (i = 0; i < IWORDS; i = i + 1)
            imem.mem[i] = prog[i];
        @(posedge clk) #1 rst_n = 1'b1;
    end
endtask

// Wait for the trap and check the four architectural results one by one.
// mcause carries the interrupt flag in bit 31, so it is compared as a full
// 32-bit value rather than as a code, which is what catches an exception
// wrongly reported as an interrupt or the other way round.
task expect_trap(input [31:0] exp_mcause, input [31:0] exp_mepc,
                 input [31:0] exp_mtval,  input [31:0] exp_handler);
    integer timeout;
    begin
        timeout = 0;
        while ((cpu_in_trap !== 1'b1) && (timeout < 2000)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (cpu_in_trap !== 1'b1) begin
            $display("FAIL:   no trap was taken within %0d cycles", timeout);
            errors = errors + 1;
        end else begin
            $display("  trap taken after %0d cycles", timeout);
            check(exp_mcause, dut.csr_file_inst.mcause_q, "  mcause");
            check(exp_mepc,   dut.csr_file_inst.mepc_q,   "  mepc");
            check(exp_mtval,  dut.csr_file_inst.mtval_q,  "  mtval");
            // let the pipeline settle on the handler's self-loop before
            // reading back which handler was actually entered
            repeat (20) @(posedge clk);
            check(exp_handler, dut.ifdx_pc_q, "  handler entry address");
            check(32'd1, {31'b0, cpu_in_trap}, "  cpu_in_trap held until MRET");
        end
    end
endtask

// A trapping instruction must never commit. x5 is the destination of every
// load in this bench and is never written by anything else, so it staying 0 is
// a direct statement that the faulting instruction produced no result.
task check_no_writeback(input [511:0] name);
    begin
        check(32'h0000_0000, dut.regfile_inst.regs[5], name);
    end
endtask

task check_no_dbus_traffic;
    begin
        check(32'd0, db_ar_cnt, "  no read transaction was issued on dbus");
        check(32'd0, db_aw_cnt, "  no write transaction was issued on dbus");
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    $display("\n===========================================================");
    $display("tb_traps : one directed test per trap cause");
    $display("===========================================================");

    // =====================================================================
    // cause 0 : instruction address misaligned
    // =====================================================================
    // A taken jump whose target has bit 1 set. RV32I without the C extension
    // requires 4-byte aligned instructions, so the target is illegal and the
    // jump traps instead of being taken.
    prog_init;
    prog[CASE_WORD] = I_JAL(5'd0, 21'd6);       // jal x0, +6  from 0x08 -> 0x0E
    start_case("cause 0 - instruction address misaligned");
    $display("   step 1: mtvec <- 0x%08h (direct mode)", HANDLER);
    $display("   step 2: at 0x08, execute  jal x0, +6");
    $display("   step 3: the branch target is 0x08 + 6 = 0x0E, and bit 1 is set");
    $display("   step 4: expect mcause = 0, mepc = 0x08 (the jump itself),");
    $display("           mtval = 0x0E (the illegal target)");
    expect_trap(32'd0, 32'h0000_0008, 32'h0000_000E, HANDLER);
    $display("   step 5: no data transaction may have been issued");
    check_no_dbus_traffic;

    // =====================================================================
    // cause 1 : instruction access fault
    // =====================================================================
    // The jump itself is legal; the fetch at the destination is not. The
    // faulting instruction is the one that could not be fetched, so mepc is
    // the destination, not the jump.
    prog_init;
    prog[CASE_WORD] = I_JAL(5'd0, BAD_FETCH - 32'h8);   // jump to 0x8000
    start_case("cause 1 - instruction access fault");
    $display("   step 1: mtvec <- 0x%08h (direct mode)", HANDLER);
    $display("   step 2: at 0x08, jump to 0x%08h, outside the instruction memory", BAD_FETCH);
    $display("   step 3: the memory answers DECERR on that fetch");
    $display("   step 4: expect mcause = 1, mepc = mtval = 0x%08h", BAD_FETCH);
    $display("           (the address that could not be fetched, not the jump)");
    expect_trap(32'd1, BAD_FETCH, BAD_FETCH, HANDLER);

    // =====================================================================
    // cause 2 : illegal instruction
    // =====================================================================
    prog_init;
    prog[CASE_WORD] = BAD_IW;
    start_case("cause 2 - illegal instruction");
    $display("   step 1: mtvec <- 0x%08h (direct mode)", HANDLER);
    $display("   step 2: place the word 0x%08h at 0x08 - opcode 1111111 is undefined", BAD_IW);
    $display("   step 3: expect mcause = 2, mepc = 0x08,");
    $display("           mtval = the instruction word itself (spec: mtval holds the");
    $display("           faulting instruction on an illegal-instruction trap)");
    expect_trap(32'd2, 32'h0000_0008, BAD_IW, HANDLER);
    $display("   step 4: the illegal instruction must not have written a register");
    check_no_writeback("  x5 untouched by the illegal instruction");
    check_no_dbus_traffic;

    // =====================================================================
    // cause 3 : breakpoint
    // =====================================================================
    prog_init;
    prog[CASE_WORD] = EBREAK;
    start_case("cause 3 - breakpoint (EBREAK)");
    $display("   step 1: mtvec <- 0x%08h (direct mode)", HANDLER);
    $display("   step 2: at 0x08, execute EBREAK");
    $display("   step 3: expect mcause = 3, mepc = 0x08, mtval = 0x08");
    $display("           (mepc points AT the EBREAK, so a debugger can resume it)");
    expect_trap(32'd3, 32'h0000_0008, 32'h0000_0008, HANDLER);

    // =====================================================================
    // cause 11 : environment call from M-mode
    // =====================================================================
    prog_init;
    prog[CASE_WORD] = ECALL;
    start_case("cause 11 - environment call from M-mode (ECALL)");
    $display("   step 1: mtvec <- 0x%08h (direct mode)", HANDLER);
    $display("   step 2: at 0x08, execute ECALL");
    $display("   step 3: expect mcause = 11, mepc = 0x08, mtval = 0");
    $display("           (an ECALL has no faulting address or word to report,");
    $display("            so mtval is 0 - the handler must add 4 to mepc itself)");
    expect_trap(32'd11, 32'h0000_0008, 32'h0000_0000, HANDLER);

    // =====================================================================
    // cause 4 : load address misaligned - word form
    // =====================================================================
    prog_init;
    prog[CASE_WORD + 0] = I_LUI(5'd1, DMEM_BASE[31:12]);        // x1 = 0x2000
    prog[CASE_WORD + 1] = I_LW (5'd5, 5'd1, 12'd1);             // lw x5, 1(x1)
    start_case("cause 4 - load address misaligned (LW)");
    $display("   step 1: mtvec <- 0x%08h (direct mode)", HANDLER);
    $display("   step 2: at 0x08,  lui x1, 0x%05h   -> x1 = 0x%08h, a VALID address",
             DMEM_BASE[31:12], DMEM_BASE);
    $display("   step 3: at 0x0C,  lw x5, 1(x1)     -> byte address 0x%08h", DMEM_BASE + 1);
    $display("           the address is mapped, so only the alignment can fault");
    $display("   step 4: expect mcause = 4, mepc = 0x0C, mtval = 0x%08h", DMEM_BASE + 1);
    expect_trap(32'd4, 32'h0000_000C, DMEM_BASE + 32'd1, HANDLER);
    $display("   step 5: the access must have been stopped BEFORE the bus,");
    $display("           so no AXI transaction may exist and x5 must be untouched");
    check_no_dbus_traffic;
    check_no_writeback("  x5 untouched by the misaligned load");

    // =====================================================================
    // cause 4 : load address misaligned - halfword form
    // =====================================================================
    // The halfword rule is different from the word rule (bit 0 only), so it is
    // a separate case: a check that only tested LW would pass on an
    // implementation that forgot halfword alignment entirely.
    prog_init;
    prog[CASE_WORD + 0] = I_LUI(5'd1, DMEM_BASE[31:12]);
    prog[CASE_WORD + 1] = I_LH (5'd5, 5'd1, 12'd1);             // lh x5, 1(x1)
    start_case("cause 4 - load address misaligned (LH, odd byte address)");
    $display("   step 1: at 0x0C,  lh x5, 1(x1)  -> byte address 0x%08h", DMEM_BASE + 1);
    $display("   step 2: a halfword needs bit 0 clear; bit 1 is irrelevant here");
    $display("   step 3: expect mcause = 4, mepc = 0x0C, mtval = 0x%08h", DMEM_BASE + 1);
    expect_trap(32'd4, 32'h0000_000C, DMEM_BASE + 32'd1, HANDLER);
    check_no_dbus_traffic;

    // =====================================================================
    // cause 6 : store address misaligned - word form
    // =====================================================================
    prog_init;
    prog[CASE_WORD + 0] = I_LUI(5'd1, DMEM_BASE[31:12]);
    prog[CASE_WORD + 1] = I_SW (5'd0, 5'd1, 12'd2);             // sw x0, 2(x1)
    start_case("cause 6 - store address misaligned (SW)");
    $display("   step 1: at 0x08,  lui x1, 0x%05h   -> x1 = 0x%08h", DMEM_BASE[31:12], DMEM_BASE);
    $display("   step 2: at 0x0C,  sw x0, 2(x1)     -> byte address 0x%08h", DMEM_BASE + 2);
    $display("   step 3: expect mcause = 6, mepc = 0x0C, mtval = 0x%08h", DMEM_BASE + 2);
    expect_trap(32'd6, 32'h0000_000C, DMEM_BASE + 32'd2, HANDLER);
    $display("   step 4: a misaligned STORE is the dangerous one - if the write");
    $display("           reached the bus before the trap it would have corrupted");
    $display("           memory, so the transaction count must be exactly zero");
    check_no_dbus_traffic;

    // =====================================================================
    // cause 6 : store address misaligned - halfword form
    // =====================================================================
    prog_init;
    prog[CASE_WORD + 0] = I_LUI(5'd1, DMEM_BASE[31:12]);
    prog[CASE_WORD + 1] = I_SH (5'd0, 5'd1, 12'd1);             // sh x0, 1(x1)
    start_case("cause 6 - store address misaligned (SH, odd byte address)");
    $display("   step 1: at 0x0C,  sh x0, 1(x1)  -> byte address 0x%08h", DMEM_BASE + 1);
    $display("   step 2: expect mcause = 6, mepc = 0x0C, mtval = 0x%08h", DMEM_BASE + 1);
    expect_trap(32'd6, 32'h0000_000C, DMEM_BASE + 32'd1, HANDLER);
    check_no_dbus_traffic;

    // =====================================================================
    // cause 5 : load access fault
    // =====================================================================
    // The address is aligned, so alignment cannot fire; only the bus response
    // can. This is the ordering that makes the two load causes distinguishable.
    prog_init;
    prog[CASE_WORD + 0] = I_LUI(5'd1, BAD_DATA[31:12]);         // x1 = 0x4000
    prog[CASE_WORD + 1] = I_LW (5'd5, 5'd1, 12'd0);             // lw x5, 0(x1)
    start_case("cause 5 - load access fault");
    $display("   step 1: at 0x08,  lui x1, 0x%05h   -> x1 = 0x%08h, UNMAPPED",
             BAD_DATA[31:12], BAD_DATA);
    $display("   step 2: at 0x0C,  lw x5, 0(x1)     -> aligned, so alignment cannot fault");
    $display("   step 3: the data memory answers DECERR");
    $display("   step 4: expect mcause = 5, mepc = 0x0C, mtval = 0x%08h", BAD_DATA);
    expect_trap(32'd5, 32'h0000_000C, BAD_DATA, HANDLER);
    $display("   step 5: the transaction DID go out this time (it had to, for the");
    $display("           slave to answer), but the load must not have written x5");
    check(32'd1, db_ar_cnt, "  exactly one read transaction was issued");
    check_no_writeback("  x5 untouched by the faulting load");

    // =====================================================================
    // cause 7 : store access fault
    // =====================================================================
    prog_init;
    prog[CASE_WORD + 0] = I_LUI(5'd1, BAD_DATA[31:12]);
    prog[CASE_WORD + 1] = I_SW (5'd0, 5'd1, 12'd0);             // sw x0, 0(x1)
    start_case("cause 7 - store access fault");
    $display("   step 1: at 0x08,  lui x1, 0x%05h   -> x1 = 0x%08h, UNMAPPED",
             BAD_DATA[31:12], BAD_DATA);
    $display("   step 2: at 0x0C,  sw x0, 0(x1)     -> aligned, so only the bus can fault");
    $display("   step 3: expect mcause = 7, mepc = 0x0C, mtval = 0x%08h", BAD_DATA);
    expect_trap(32'd7, 32'h0000_000C, BAD_DATA, HANDLER);
    check(32'd1, db_aw_cnt, "  exactly one write transaction was issued");

    // =====================================================================
    // cause priority : two candidate faults on one instruction
    // =====================================================================
    // An unmapped AND misaligned address could produce cause 4 or cause 5. The
    // design checks alignment before issuing, so cause 4 must win and no bus
    // transaction may be issued at all. Without this case, an implementation
    // that issued first and trapped later would still pass every case above.
    prog_init;
    prog[CASE_WORD + 0] = I_LUI(5'd1, BAD_DATA[31:12]);
    prog[CASE_WORD + 1] = I_LW (5'd5, 5'd1, 12'd3);             // lw x5, 3(x1)
    start_case("cause priority - misaligned AND unmapped load");
    $display("   step 1: at 0x0C,  lw x5, 3(x1)  -> address 0x%08h", BAD_DATA + 3);
    $display("           this address is BOTH misaligned and unmapped");
    $display("   step 2: alignment is checked before the access is issued, so");
    $display("           cause 4 must win over cause 5");
    $display("   step 3: expect mcause = 4, and zero bus transactions");
    expect_trap(32'd4, 32'h0000_000C, BAD_DATA + 32'd3, HANDLER);
    check_no_dbus_traffic;

    // =====================================================================
    // machine external interrupt, vector 0 : cause 16
    // =====================================================================
    prog_init;
    prog[CASE_WORD + 0] = I_CSRRSI(5'd0, CSR_MSTATUS, 5'd8);    // mstatus.MIE <- 1
    prog[CASE_WORD + 1] = I_LUI   (5'd4, 20'h00010);            // x4 = 0x00010000 (mie[16])
    prog[CASE_WORD + 2] = I_CSRRW (5'd0, CSR_MIE, 5'd4);        // mie <- x4
    start_case("cause 16 - machine external interrupt, PIC vector 0");
    $display("   step 1: mtvec <- 0x%08h (direct mode)", HANDLER);
    $display("   step 2: at 0x08,  csrrsi mstatus, 8  -> mstatus.MIE = 1");
    $display("   step 3: at 0x0C/0x10, mie <- 0x00010000, enabling machine");
    $display("           external cause 16 (PIC vector 0)");
    run_irq_case(4'd0);
    $display("   step 4: expect mcause = 0x80000010 (interrupt flag + code 16),");
    $display("           mtval = 0, and mepc at an instruction boundary");
    expect_irq_trap(4'd0, HANDLER);

    // =====================================================================
    // machine external interrupt, vector 3 : cause 19
    // =====================================================================
    prog_init;
    prog[CASE_WORD + 0] = I_CSRRSI(5'd0, CSR_MSTATUS, 5'd8);
    prog[CASE_WORD + 1] = I_LUI   (5'd4, 20'h00080);            // mie[19]
    prog[CASE_WORD + 2] = I_CSRRW (5'd0, CSR_MIE, 5'd4);
    start_case("cause 19 - machine external interrupt, PIC vector 3");
    $display("   step 1: mie <- 0x00080000, enabling cause 19 only");
    run_irq_case(4'd3);
    $display("   step 2: expect mcause = 0x80000013");
    expect_irq_trap(4'd3, HANDLER);

    // =====================================================================
    // machine external interrupt, vector 15 : cause 31
    // =====================================================================
    prog_init;
    prog[CASE_WORD + 0] = I_CSRRSI(5'd0, CSR_MSTATUS, 5'd8);
    prog[CASE_WORD + 1] = I_LUI   (5'd4, 20'h80000);            // mie[31]
    prog[CASE_WORD + 2] = I_CSRRW (5'd0, CSR_MIE, 5'd4);
    start_case("cause 31 - machine external interrupt, PIC vector 15");
    $display("   step 1: mie <- 0x80000000, enabling the top cause only");
    run_irq_case(4'd15);
    $display("   step 2: expect mcause = 0x8000001F");
    expect_irq_trap(4'd15, HANDLER);

    // =====================================================================
    // negative case : an interrupt masked in mie must never be taken
    // =====================================================================
    // This is the other half of every case above. If the vector were ignored
    // and any request were taken, all three interrupt cases would still pass.
    prog_init;
    prog[CASE_WORD + 0] = I_CSRRSI(5'd0, CSR_MSTATUS, 5'd8);
    prog[CASE_WORD + 1] = I_LUI   (5'd4, 20'h00010);            // enable vector 0 only
    prog[CASE_WORD + 2] = I_CSRRW (5'd0, CSR_MIE, 5'd4);
    start_case("negative - a request on a vector masked in mie is never taken");
    $display("   step 1: mstatus.MIE = 1 and mie enables cause 16 (vector 0) ONLY");
    $display("   step 2: raise a request on vector 5, which is NOT enabled");
    while (!(dut.mie_global === 1'b1 && dut.irq_enable !== 16'h0000)) @(posedge clk);
    repeat (2) @(posedge clk);
    cpu_irq_vec = 4'd5;
    cpu_irq     = 1'b1;
    $display("   step 3: hold it for 300 cycles");
    repeat (300) @(posedge clk);
    $display("   step 4: no trap may be taken and no claim may be issued");
    check(32'd0, {31'b0, cpu_in_trap}, "  cpu_in_trap stayed low");
    check(32'd0, ack_cnt,              "  cpu_irq_ack never pulsed");
    check(32'd0, dut.csr_file_inst.mcause_q, "  mcause was never written");
    $display("   step 5: switch the same request to the ENABLED vector 0 -");
    $display("           it must be taken at once, proving step 4 was masking");
    cpu_irq_vec = 4'd0;
    repeat (200) @(posedge clk);
    check(32'd1, {31'b0, cpu_in_trap}, "  the enabled vector is taken");
    check(32'h8000_0010, dut.csr_file_inst.mcause_q, "  mcause = 0x80000010");

    // =====================================================================
    // negative case : an interrupt with mstatus.MIE = 0 must never be taken
    // =====================================================================
    prog_init;
    prog[CASE_WORD + 0] = I_LUI  (5'd4, 20'h00010);             // mie enables cause 16
    prog[CASE_WORD + 1] = I_CSRRW(5'd0, CSR_MIE, 5'd4);         // but MIE is left at 0
    start_case("negative - a request with mstatus.MIE = 0 is never taken");
    $display("   step 1: mie enables cause 16, but mstatus.MIE is left at its");
    $display("           reset value of 0, so interrupts are globally disabled");
    while (dut.irq_enable === 16'h0000) @(posedge clk);
    repeat (2) @(posedge clk);
    cpu_irq_vec = 4'd0;
    cpu_irq     = 1'b1;
    $display("   step 2: raise the enabled vector and hold it for 300 cycles");
    repeat (300) @(posedge clk);
    $display("   step 3: no trap may be taken and no claim may be issued");
    check(32'd0, {31'b0, cpu_in_trap}, "  cpu_in_trap stayed low");
    check(32'd0, ack_cnt,              "  cpu_irq_ack never pulsed");

    // =====================================================================
    // mtvec vectored mode
    // =====================================================================
    // In vectored mode interrupts enter at BASE + 4*cause while exceptions
    // still enter at BASE. Both halves are checked, because a design that sent
    // everything to BASE + 4*cause would pass an interrupt-only check.
    prog_init;
    prog[0] = I_ADDI (5'd3, 5'd0, HANDLER[11:0] | 12'd1);       // BASE | MODE=1
    prog[1] = I_CSRRW(5'd0, CSR_MTVEC, 5'd3);
    prog[CASE_WORD + 0] = I_CSRRSI(5'd0, CSR_MSTATUS, 5'd8);
    prog[CASE_WORD + 1] = I_LUI   (5'd4, 20'h00080);            // mie[19] -> cause 19
    prog[CASE_WORD + 2] = I_CSRRW (5'd0, CSR_MIE, 5'd4);
    start_case("mtvec vectored - an interrupt enters at BASE + 4*cause");
    $display("   step 1: mtvec <- 0x%08h, i.e. BASE = 0x%08h with MODE = 1",
             HANDLER | 32'd1, HANDLER);
    $display("   step 2: take interrupt cause 19 (PIC vector 3)");
    $display("   step 3: the handler entry must be 0x%08h + 4*19 = 0x%08h",
             HANDLER, HANDLER + 32'd76);
    run_irq_case(4'd3);
    expect_irq_trap_at(4'd3, HANDLER + 32'd76);

    prog_init;
    prog[0] = I_ADDI (5'd3, 5'd0, HANDLER[11:0] | 12'd1);       // BASE | MODE=1
    prog[1] = I_CSRRW(5'd0, CSR_MTVEC, 5'd3);
    prog[CASE_WORD] = ECALL;
    start_case("mtvec vectored - an exception still enters at BASE");
    $display("   step 1: mtvec <- 0x%08h (BASE with MODE = 1)", HANDLER | 32'd1);
    $display("   step 2: take a synchronous trap (ECALL, cause 11)");
    $display("   step 3: vectoring applies to interrupts only, so the handler");
    $display("           entry must be BASE = 0x%08h, NOT BASE + 44", HANDLER);
    expect_trap(32'd11, 32'h0000_0008, 32'h0000_0000, HANDLER);

    // =====================================================================
    // Nesting: which trap level an MRET is returning from
    //
    // MRET is one instruction for two different returns. Returning from an
    // interrupt handler owes the PIC an EOI; returning from a synchronous
    // exception owes it nothing. A core that tracks "an interrupt is in
    // progress" as a single flag cannot tell the two apart, and both cases
    // below are where that shows.
    // =====================================================================

    // --- a synchronous exception taken inside an interrupt handler -------
    //
    // Vectored mtvec, BASE = 0x80. Interrupt vector 0 is cause 16, so the
    // interrupt handler entry is BASE + 64 = 0xC0; a synchronous exception
    // still enters at BASE = 0x80.
    //
    //   0xC0  ECALL                 the interrupt handler faults
    //   0x80  mepc += 4; MRET       the exception handler returns past it
    //   0xC4  SW marker             back in the interrupt handler
    //   0xC8  MRET                  the interrupt handler returns
    //
    // The exception's MRET must send no EOI: its interrupt is still being
    // handled. The count is therefore sampled at the marker store, which the
    // core only reaches after that MRET has retired, and it has to be 0 there.
    prog_init;
    prog[0]  = I_ADDI (5'd3, 5'd0, HANDLER[11:0] | 12'd1);   // BASE | MODE=1
    prog[1]  = I_CSRRW(5'd0, CSR_MTVEC, 5'd3);
    prog[2]  = I_LUI  (5'd3, 20'h00010);                     // mie bit 16 = vec 0
    prog[3]  = I_CSRRW(5'd0, CSR_MIE, 5'd3);
    prog[4]  = I_LUI  (5'd5, MARK_ADDR[31:12]);              // x5 = marker base
    prog[5]  = I_CSRRSI(5'd0, CSR_MSTATUS, 5'd8);            // mstatus.MIE = 1
    prog[6]  = I_JAL  (5'd0, 21'd0);                         // spin until the irq
    prog[32] = I_CSRRS(5'd4, CSR_MEPC, 5'd0);                // 0x80: exception handler
    prog[33] = I_ADDI (5'd4, 5'd4, 12'd4);                   //   mepc += 4
    prog[34] = I_CSRRW(5'd0, CSR_MEPC, 5'd4);
    prog[35] = MRET;                                         //   return past the ECALL
    prog[48] = ECALL;                                        // 0xC0: interrupt handler
    prog[49] = I_SW   (5'd0, 5'd5, 12'd0);                   // 0xC4: marker store
    prog[50] = MRET;                                         // 0xC8: return from the irq

    start_case("nesting - an exception inside an interrupt handler sends no EOI");
    $display("   step 1: vectored mtvec, interrupt vector 0 enters at 0x%08h",
             HANDLER + 32'd64);
    $display("   step 2: the interrupt handler executes ECALL, so a synchronous");
    $display("           trap opens on top of an interrupt that is still open");
    $display("   step 3: the exception's MRET must send no EOI - the interrupt");
    $display("           has not returned yet and its source must stay in service");
    run_irq_case(4'd0);
    while (!marker_seen) @(posedge clk);
    check(32'd0, eoi_at_marker[31:0],
          "  no EOI had been sent when the exception's MRET had retired");
    check(32'd1, {31'b0, cpu_in_trap},
          "  cpu_in_trap still set: the interrupt level is still open");
    cpu_irq = 1'b0;
    repeat (40) @(posedge clk);
    check(32'd1, eoi_cnt[31:0],  "  the interrupt handler's MRET sent the one EOI");
    check(32'd1, ack_cnt[31:0],  "  exactly one claim was made");
    check(32'd0, {31'b0, cpu_in_trap}, "  cpu_in_trap released on the last MRET");

    // --- two nested interrupt handlers -----------------------------------
    //
    //   0xC0  JAL h0        vector 0 entry
    //   0xC4  JAL h1        vector 1 entry
    //   0x100 h0: mstatus.MIE = 1; NOP x4; SW marker; MRET
    //   0x120 h1: MRET
    //
    // h0 re-enables interrupts and is preempted by vector 1. Two claims are
    // made, so two EOIs have to come back: one per handler return.
    prog_init;
    prog[0]  = I_ADDI (5'd3, 5'd0, HANDLER[11:0] | 12'd1);
    prog[1]  = I_CSRRW(5'd0, CSR_MTVEC, 5'd3);
    prog[2]  = I_LUI  (5'd3, 20'h00030);                     // mie bits 16 and 17
    prog[3]  = I_CSRRW(5'd0, CSR_MIE, 5'd3);
    prog[4]  = I_LUI  (5'd5, MARK_ADDR[31:12]);              // x5 = marker base
    prog[5]  = I_CSRRSI(5'd0, CSR_MSTATUS, 5'd8);
    prog[6]  = I_JAL  (5'd0, 21'd0);
    prog[48] = I_JAL  (5'd0, 21'd64);                        // 0xC0 -> 0x100
    prog[49] = I_JAL  (5'd0, 21'd92);                        // 0xC4 -> 0x120
    prog[64] = I_CSRRSI(5'd0, CSR_MSTATUS, 5'd8);            // 0x100: h0 re-enables MIE
    prog[65] = NOP;                                          //   preemption window
    prog[66] = NOP;
    prog[67] = NOP;
    prog[68] = NOP;
    prog[69] = I_SW   (5'd0, 5'd5, 12'd0);                   //   marker: h1 has returned
    prog[70] = MRET;
    prog[72] = MRET;                                         // 0x120: h1 returns at once

    start_case("nesting - each nested interrupt handler returns its own EOI");
    $display("   step 1: vector 0 is taken and its handler re-enables mstatus.MIE");
    $display("   step 2: vector 1 preempts it, so two claims are outstanding");
    $display("   step 3: both MRETs must send an EOI, one per open level");
    run_irq_case(4'd0);
    while (ack_cnt != 1) @(posedge clk);
    cpu_irq = 1'b0;
    repeat (6) @(posedge clk);
    cpu_irq_vec = 4'd1;                                      // preempt
    cpu_irq     = 1'b1;
    while (ack_cnt != 2) @(posedge clk);
    cpu_irq = 1'b0;
    while (!marker_seen) @(posedge clk);
    check(32'd1, eoi_at_marker[31:0],
          "  the inner handler's MRET sent exactly one EOI");
    repeat (40) @(posedge clk);
    check(32'd2, ack_cnt[31:0], "  two claims were made");
    check(32'd2, eoi_cnt[31:0], "  two EOIs came back, one per level");
    check(32'd0, {31'b0, cpu_in_trap}, "  cpu_in_trap released only at the end");

    // ---- done ----
    repeat (10) @(posedge clk);
    $display("\n========================================");
    if (errors == 0)
        $display("== TRAP CAUSE TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== TRAP CAUSE TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

// ---------------------------------------------------------------------------
// interrupt helpers, declared after the main block for readability
// ---------------------------------------------------------------------------

// Wait until the program has finished enabling interrupts, then raise the
// request. Waiting on the architectural state rather than on a cycle count
// keeps the case independent of how many cycles the prologue takes.
task run_irq_case(input [3:0] vec);
    begin
        while (!(dut.mie_global === 1'b1 && dut.irq_enable !== 16'h0000)) @(posedge clk);
        repeat (3) @(posedge clk);
        cpu_irq_vec = vec;
        cpu_irq     = 1'b1;
    end
endtask

task expect_irq_trap_at(input [3:0] vec, input [31:0] exp_handler);
    integer timeout;
    reg [31:0] the_mepc;
    begin
        timeout = 0;
        while ((cpu_in_trap !== 1'b1) && (timeout < 2000)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (cpu_in_trap !== 1'b1) begin
            $display("FAIL:   the interrupt was never taken (%0d cycles)", timeout);
            errors = errors + 1;
        end else begin
            the_mepc = dut.csr_file_inst.mepc_q;
            check({1'b1, 26'b0, 1'b1, vec}, dut.csr_file_inst.mcause_q,
                  "  mcause = interrupt flag + 16 + vector");
            check(32'h0000_0000, dut.csr_file_inst.mtval_q,
                  "  mtval = 0 for an interrupt (no faulting address)");
            // mepc must be the instruction to RESUME at, so it has to be a real
            // instruction boundary inside the program body rather than an
            // arbitrary address.
            if ((the_mepc[1:0] == 2'b00) && (the_mepc >= 32'h0000_0008) &&
                (the_mepc < HANDLER))
                $display("PASS:   mepc = 0x%08h, an instruction boundary in the program body",
                         the_mepc);
            else begin
                $display("FAIL:   mepc = 0x%08h is not an instruction boundary in the body",
                         the_mepc);
                errors = errors + 1;
            end
            // cpu_irq_ack is registered one cycle behind cpu_in_trap, so it is
            // counted after the pipeline has settled on the handler rather than
            // at the instant the trap is observed.
            repeat (20) @(posedge clk);
            check(32'd1, ack_cnt, "  cpu_irq_ack pulsed exactly once");
            check(exp_handler, dut.ifdx_pc_q, "  handler entry address");
        end
    end
endtask

task expect_irq_trap(input [3:0] vec, input [31:0] exp_handler);
    begin
        expect_irq_trap_at(vec, exp_handler);
    end
endtask

// watchdog
initial begin
    #2000000;
    $display("FAIL: tb_traps timeout");
    $finish;
end

endmodule
