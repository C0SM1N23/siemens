// M-mode CSR file.
// REQ# = spec requirement, D# = design choice, both tracked in the README.
//
// REQ9: the 7 required CSRs at their addresses: mstatus 0x300, mie 0x304,
//       mtvec 0x305, mscratch 0x340, mepc 0x341, mcause 0x342, mip 0x344 (mip is
//       read-only, driven by the PIC). Only the live fields exist, the rest read
//       0/WPRI: mstatus MIE(3)/MPIE(7), MPP(12:11) hardwired to 2'b11; mtvec
//       BASE[31:2] + MODE[1:0]; mepc[1:0] forced to 0.
// D3:  the 16 PIC sources map to mie/mip bits 16..31 (external-interrupt causes
//      16..31), i.e. the interrupt half of the supported-cause set. The PIC does
//      the priority resolution and drives one request + a 4-bit vector; cpu_top
//      turns that into a one-hot mip[16+vec] so software still masks per source.
// D5:  read-only mhartid (0xF14) from HART_ID, plus mcycle/minstret.
// D25: mhpmcounter3..7 at the standard addresses, wired to the events software
//      needs to tune the SoC (pairs with the DP-SRAM BANDWIDTH_A/B and DMA
//      throttling): 3 mispredicts, 4 fetch-starved cycles, 5 dbus stall cycles,
//      6 traps taken, 7 WFI sleep cycles. The events are fixed, so mhpmevent
//      is tied off (see below).
// Counters follow Priv. spec 3.1.11: each is architecturally 64-bit and on RV32
// is read through a base / base+0x80 pair (mcycleh 0xB80, minstreth 0xB82,
// mhpmcounter3h..7h 0xB83..0xB87), and M-mode may write either half. A write
// replaces the addressed half while the other half still takes the increment,
// so the event that lands in the same cycle as the write is not lost.
// mhpmcounter8..31, their upper halves, and mhpmevent3..31 are provided as
// hardwired zero: the spec lets an implementation tie off counters it does not
// have, but they must read 0 and ignore writes (WARL) rather than trap.
// mcountinhibit (0x320) is deliberately absent - the spec makes it optional and
// defines the not-implemented behaviour as "all counters run", which is this.
// D15: reading an unimplemented CSR, or writing a read-only one, raises illegal
//      in S2 (illegal, not DECERR, since CSRs are internal). csr_wen already
//      drops the "CSRRS/C with x0/uimm=0 = pure read" case, so those don't trap.
// D16: vectored mtvec sends interrupts to BASE+4*cause and exceptions to BASE;
//      direct mode sends everything to BASE.
//
// Trap entry and MRET are sequenced by cpu_top: trap_set commits mepc, mcause,
// MPIE<-MIE and MIE<-0 atomically, mret does MIE<-MPIE and MPIE<-1. trap_set
// wins over a same-cycle software write, so the trapping instruction never
// commits its own write.

`timescale 1ns/1ps

`include "defines.vh"

module csr_file #(
    parameter HART_ID = 32'd0
)(
    input             clk,
    input             rst_n,

    // CSR access from S2
    input      [11:0] csr_addr,
    input      [31:0] csr_wdata,     // forwarded rs1 or zext(uimm5)
    input      [1:0]  csr_op,        // CSROP_RW / _RS / _RC
    input             csr_ren,       // valid CSR instruction (address check)
    input             csr_wen,       // effective write requested
    output reg [31:0] csr_rdata,
    output            csr_illegal,

    // trap entry / return
    input             trap_set,
    input             trap_is_irq,
    input      [4:0]  trap_code,     // cause code (sync 0..11, irq 16..31)
    input      [31:0] trap_pc,       // -> mepc
    input      [31:0] trap_val,      // -> mtval (fault address, or instruction on illegal)
    input             mret,

    // interrupt side
    input      [15:0] irq_lines,     // pending one-hot -> mip[31:16]
    output     [15:0] irq_enable,    // mie[31:16]
    output            mie_global,    // mstatus.MIE

    // architectural targets
    output     [31:0] trap_vector,   // handler address for the current cause
    output     [31:0] mepc_out,

    // counters
    input             retire,        // instruction committed in S3
    input             ev_mispredict, // one pulse per mispredict redirect (D25)
    input             ev_ibus_wait,  // level: S2 has no instruction
    input             ev_dbus_stall, // level: data AXI op in flight
    input             ev_wfi_sleep   // level: WFI sleeping (D23)
);

// CSR addresses (Privileged ISA v20211203)
localparam MISA     = 12'h301;
localparam MSTATUS  = 12'h300;
localparam MIE      = 12'h304;
localparam MTVEC    = 12'h305;
localparam MSCRATCH = 12'h340;
localparam MEPC     = 12'h341;
localparam MCAUSE   = 12'h342;
localparam MTVAL    = 12'h343;
localparam MIP      = 12'h344;
localparam MVENDID  = 12'hF11;
localparam MARCHID  = 12'hF12;
localparam MIMPID   = 12'hF13;
localparam MCYCLE   = 12'hB00;
localparam MINSTRET = 12'hB02;
localparam MHPMC3   = 12'hB03;   // mispredicts        (D25)
localparam MHPMC4   = 12'hB04;   // fetch-starved cycles
localparam MHPMC5   = 12'hB05;   // dbus stall cycles
localparam MHPMC6   = 12'hB06;   // traps taken
localparam MHPMC7   = 12'hB07;   // WFI sleep cycles
// upper halves: on RV32 every counter is architecturally 64-bit and is read
// through a base/base+0x80 pair (Priv. spec 3.1.11)
localparam MCYCLEH   = 12'hB80;
localparam MINSTRETH = 12'hB82;
localparam MHPMC3H   = 12'hB83;
localparam MHPMC4H   = 12'hB84;
localparam MHPMC5H   = 12'hB85;
localparam MHPMC6H   = 12'hB86;
localparam MHPMC7H   = 12'hB87;
localparam MHARTID  = 12'hF14;

reg        mstatus_mie_q, mstatus_mpie_q;
reg [15:0] mie_q;
reg [31:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;
reg [63:0] mcycle_q, minstret_q;
reg [63:0] mhpm3_q, mhpm4_q, mhpm5_q, mhpm6_q, mhpm7_q;

// mhpmcounter8..31 / their upper halves / mhpmevent3..31 exist but are
// hardwired to zero: the spec allows an implementation to tie off counters it
// does not provide, but they must still read as 0 instead of trapping, and a
// write to them is ignored (WARL) rather than raising illegal.
wire hpm_wired0 = ((csr_addr >= 12'hB08) && (csr_addr <= 12'hB1F))   // mhpmcounter8..31
               || ((csr_addr >= 12'hB88) && (csr_addr <= 12'hB9F))   // mhpmcounter8..31h
               || ((csr_addr >= 12'h323) && (csr_addr <= 12'h33F));  // mhpmevent3..31

wire [31:0] mstatus_rd = {19'b0, 2'b11, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};
wire [31:0] misa_rd    = 32'h4000_0100;   // MXL=32, extension I (RV32I)

// combinational read + address check
reg addr_ok;
reg addr_ro;    // implemented but read-only
always @(*) begin
    addr_ok = 1; addr_ro = 0;
    case (csr_addr)
        MSTATUS:  csr_rdata = mstatus_rd;
        MISA:     csr_rdata = misa_rd;   // WARL, writes ignored
        MIE:      csr_rdata = {mie_q, 16'b0};
        MTVEC:    csr_rdata = mtvec_q;
        MSCRATCH: csr_rdata = mscratch_q;
        MEPC:     csr_rdata = mepc_q;
        MCAUSE:   csr_rdata = mcause_q;
        MTVAL:    csr_rdata = mtval_q;
        MIP:      begin csr_rdata = {irq_lines, 16'b0}; addr_ro = 1; end
        MVENDID:  begin csr_rdata = 32'b0; addr_ro = 1; end
        MARCHID:  begin csr_rdata = 32'b0; addr_ro = 1; end
        MIMPID:   begin csr_rdata = 32'b0; addr_ro = 1; end
        MCYCLE:    csr_rdata = mcycle_q[31:0];
        MINSTRET:  csr_rdata = minstret_q[31:0];
        MHPMC3:    csr_rdata = mhpm3_q[31:0];
        MHPMC4:    csr_rdata = mhpm4_q[31:0];
        MHPMC5:    csr_rdata = mhpm5_q[31:0];
        MHPMC6:    csr_rdata = mhpm6_q[31:0];
        MHPMC7:    csr_rdata = mhpm7_q[31:0];
        MCYCLEH:   csr_rdata = mcycle_q[63:32];
        MINSTRETH: csr_rdata = minstret_q[63:32];
        MHPMC3H:   csr_rdata = mhpm3_q[63:32];
        MHPMC4H:   csr_rdata = mhpm4_q[63:32];
        MHPMC5H:   csr_rdata = mhpm5_q[63:32];
        MHPMC6H:   csr_rdata = mhpm6_q[63:32];
        MHPMC7H:   csr_rdata = mhpm7_q[63:32];
        MHARTID:  begin csr_rdata = HART_ID;    addr_ro = 1; end
        default: begin
            csr_rdata = 32'b0;
            addr_ok   = hpm_wired0;   // tied-off hpm reads 0; anything else is illegal
        end
    endcase
end

assign csr_illegal = ((csr_ren | csr_wen) & ~addr_ok) | (csr_wen & addr_ro);

assign irq_enable = mie_q;
assign mie_global = mstatus_mie_q;
assign mepc_out   = mepc_q;

// vectored applies to interrupts only: BASE + 4*cause; exceptions go to BASE
wire [31:0] tvec_base = {mtvec_q[31:2], 2'b00};
assign trap_vector = (mtvec_q[1:0] == 2'b01 && trap_is_irq)
                     ? tvec_base + {25'b0, trap_code, 2'b00}
                     : tvec_base;

// new value per CSR op type
function [31:0] csr_new_val;
    input [31:0] old_val;
    input [31:0] write_data;
    input [1:0]  op;
    case (op)
        `CSROP_RW: csr_new_val = write_data;
        `CSROP_RS: csr_new_val = old_val |  write_data;
        `CSROP_RC: csr_new_val = old_val & ~write_data;
        default:   csr_new_val = old_val;
    endcase
endfunction

// One 64-bit counter step. The half being written takes the software value;
// the other half still takes the increment, so the event that happened in the
// same cycle as the write is never lost.
function [63:0] cnt_next;
    input [63:0] cur;
    input        ev;
    input        wr_lo;
    input        wr_hi;
    input [31:0] wdata;
    input [1:0]  op;
    reg   [63:0] inc;
    begin
        inc = cur + {63'b0, ev};
        if (wr_lo)
            cnt_next = { inc[63:32], csr_new_val(cur[31:0],  wdata, op) };
        else if (wr_hi)
            cnt_next = { csr_new_val(cur[63:32], wdata, op), inc[31:0] };
        else
            cnt_next = inc;
    end
endfunction

wire [31:0] mstatus_nv = csr_new_val(mstatus_rd, csr_wdata, csr_op);
wire [31:0] mie_nv     = csr_new_val({mie_q, 16'b0}, csr_wdata, csr_op);
wire [31:0] mepc_nv    = csr_new_val(mepc_q, csr_wdata, csr_op);

// committed software write. It never coincides with trap_set or mret: an
// interrupt kills csr_wen, a CSR op's only exception is its own illegal access
// (blocked here), and MRET is a different instruction. The trap arms below are
// still checked first anyway, so hardware always wins over a software write.
wire csr_wr = csr_wen && !csr_illegal;

wire wr_mstatus  = csr_wr && (csr_addr == MSTATUS);
wire wr_mie      = csr_wr && (csr_addr == MIE);
wire wr_mtvec    = csr_wr && (csr_addr == MTVEC);
wire wr_mscratch = csr_wr && (csr_addr == MSCRATCH);
wire wr_mepc     = csr_wr && (csr_addr == MEPC);
wire wr_mcause   = csr_wr && (csr_addr == MCAUSE);
wire wr_mtval    = csr_wr && (csr_addr == MTVAL);

// counter writes (M-mode may write every counter half; Priv. spec 3.1.11)
wire wr_cyc_lo   = csr_wr && (csr_addr == MCYCLE);
wire wr_cyc_hi   = csr_wr && (csr_addr == MCYCLEH);
wire wr_ins_lo   = csr_wr && (csr_addr == MINSTRET);
wire wr_ins_hi   = csr_wr && (csr_addr == MINSTRETH);
wire wr_h3_lo    = csr_wr && (csr_addr == MHPMC3);
wire wr_h3_hi    = csr_wr && (csr_addr == MHPMC3H);
wire wr_h4_lo    = csr_wr && (csr_addr == MHPMC4);
wire wr_h4_hi    = csr_wr && (csr_addr == MHPMC4H);
wire wr_h5_lo    = csr_wr && (csr_addr == MHPMC5);
wire wr_h5_hi    = csr_wr && (csr_addr == MHPMC5H);
wire wr_h6_lo    = csr_wr && (csr_addr == MHPMC6);
wire wr_h6_hi    = csr_wr && (csr_addr == MHPMC6H);
wire wr_h7_lo    = csr_wr && (csr_addr == MHPMC7);
wire wr_h7_hi    = csr_wr && (csr_addr == MHPMC7H);

// mstatus.MIE/MPIE: the pair swaps on trap entry and swaps back on MRET
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        mstatus_mie_q  <= 1'b0;      // interrupts off at boot
        mstatus_mpie_q <= 1'b0;
    end else if (trap_set) begin
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
    end else if (mret) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
    end else if (wr_mstatus) begin
        mstatus_mie_q  <= mstatus_nv[3];
        mstatus_mpie_q <= mstatus_nv[7];
    end
end

// mepc: trap entry records the return address, bits [1:0] always 0
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mepc_q <= 32'b0;
    else if (trap_set)
        mepc_q <= {trap_pc[31:2], 2'b00};
    else if (wr_mepc)
        mepc_q <= {mepc_nv[31:2], 2'b00};
end

// mcause: interrupt flag in bit 31, code in the low bits
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mcause_q <= 32'b0;
    else if (trap_set)
        mcause_q <= {trap_is_irq, 26'b0, trap_code};
    else if (wr_mcause)
        mcause_q <= csr_new_val(mcause_q, csr_wdata, csr_op);
end

// mtval: trap entry records the fault address (or the instruction on illegal)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mtval_q <= 32'b0;
    else if (trap_set)
        mtval_q <= trap_val;
    else if (wr_mtval)
        mtval_q <= csr_new_val(mtval_q, csr_wdata, csr_op);
end

// software-only CSRs
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mie_q <= 16'b0;
    else if (wr_mie)
        mie_q <= mie_nv[31:16];
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mtvec_q <= 32'b0;
    else if (wr_mtvec)
        mtvec_q <= csr_new_val(mtvec_q, csr_wdata, csr_op);
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mscratch_q <= 32'b0;
    else if (wr_mscratch)
        mscratch_q <= csr_new_val(mscratch_q, csr_wdata, csr_op);
end

// 64-bit counters. Every one has the same shape: increment on its event, or
// take a software write on the addressed half (one always block per register).

// free-running cycle counter
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mcycle_q <= 64'b0;
    else
        mcycle_q <= cnt_next(mcycle_q, 1'b1, wr_cyc_lo, wr_cyc_hi, csr_wdata, csr_op);
end

// retired-instruction counter
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        minstret_q <= 64'b0;
    else
        minstret_q <= cnt_next(minstret_q, retire, wr_ins_lo, wr_ins_hi, csr_wdata, csr_op);
end

// hardware performance counters (D25): one per event
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm3_q <= 64'b0;
    else
        mhpm3_q <= cnt_next(mhpm3_q, ev_mispredict, wr_h3_lo, wr_h3_hi, csr_wdata, csr_op);
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm4_q <= 64'b0;
    else
        mhpm4_q <= cnt_next(mhpm4_q, ev_ibus_wait, wr_h4_lo, wr_h4_hi, csr_wdata, csr_op);
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm5_q <= 64'b0;
    else
        mhpm5_q <= cnt_next(mhpm5_q, ev_dbus_stall, wr_h5_lo, wr_h5_hi, csr_wdata, csr_op);
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm6_q <= 64'b0;
    else
        mhpm6_q <= cnt_next(mhpm6_q, trap_set, wr_h6_lo, wr_h6_hi, csr_wdata, csr_op);
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm7_q <= 64'b0;
    else
        mhpm7_q <= cnt_next(mhpm7_q, ev_wfi_sleep, wr_h7_lo, wr_h7_hi, csr_wdata, csr_op);
end

endmodule
