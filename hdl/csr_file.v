// M-mode CSR file.
// REQ# = spec requirement, D# = design choice, both tracked in the README.
//
// REQ9: the 7 required CSRs at their addresses: mstatus 0x300, mie 0x304,
//       mtvec 0x305, mscratch 0x340, mepc 0x341, mcause 0x342, mip 0x344 (mip is
//       read-only, driven by the PIC). Only the live fields exist, the rest read
//       0/WPRI: mstatus MIE(3)/MPIE(7), MPP(12:11) hardwired to 2'b11; mtvec
//       BASE[31:2] + MODE[1:0]; mepc[1:0] forced to 0.
// D3:  the 8 PIC channels map to mie/mip bits 16..23 (external-interrupt causes
//      16..23), i.e. the interrupt half of the supported-cause set.
// D5:  read-only mhartid (0xF14) from HART_ID, plus read-only mcycle/minstret as
//      verification aids.
// D25: read-only mhpmcounter3..7 at the standard addresses, wired to the events
//      software needs to tune the SoC (pairs with the DP-SRAM BANDWIDTH_A/B and
//      DMA throttling): 3 mispredicts, 4 fetch-starved cycles, 5 dbus stall
//      cycles, 6 traps taken, 7 WFI sleep cycles. Higher hpm addresses stay
//      unimplemented and trap illegal (D15).
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
    input      [4:0]  trap_code,     // cause code (0..23)
    input      [31:0] trap_pc,       // -> mepc
    input      [31:0] trap_val,      // -> mtval (fault address, or instruction on illegal)
    input             mret,

    // interrupt side
    input      [7:0]  irq_lines,     // cpu_irq -> mip[23:16]
    output     [7:0]  irq_enable,    // mie[23:16]
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
localparam MHARTID  = 12'hF14;

reg        mstatus_mie_q, mstatus_mpie_q;
reg [7:0]  mie_q;
reg [31:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q, mcycle_q, minstret_q;
reg [31:0] mhpm3_q, mhpm4_q, mhpm5_q, mhpm6_q, mhpm7_q;

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
        MIE:      csr_rdata = {8'b0, mie_q, 16'b0};
        MTVEC:    csr_rdata = mtvec_q;
        MSCRATCH: csr_rdata = mscratch_q;
        MEPC:     csr_rdata = mepc_q;
        MCAUSE:   csr_rdata = mcause_q;
        MTVAL:    csr_rdata = mtval_q;
        MIP:      begin csr_rdata = {8'b0, irq_lines, 16'b0}; addr_ro = 1; end
        MVENDID:  begin csr_rdata = 32'b0; addr_ro = 1; end
        MARCHID:  begin csr_rdata = 32'b0; addr_ro = 1; end
        MIMPID:   begin csr_rdata = 32'b0; addr_ro = 1; end
        MCYCLE:   begin csr_rdata = mcycle_q;   addr_ro = 1; end
        MINSTRET: begin csr_rdata = minstret_q; addr_ro = 1; end
        MHPMC3:   begin csr_rdata = mhpm3_q;    addr_ro = 1; end
        MHPMC4:   begin csr_rdata = mhpm4_q;    addr_ro = 1; end
        MHPMC5:   begin csr_rdata = mhpm5_q;    addr_ro = 1; end
        MHPMC6:   begin csr_rdata = mhpm6_q;    addr_ro = 1; end
        MHPMC7:   begin csr_rdata = mhpm7_q;    addr_ro = 1; end
        MHARTID:  begin csr_rdata = HART_ID;    addr_ro = 1; end
        default:  begin csr_rdata = 32'b0; addr_ok = 0; end
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

wire [31:0] mstatus_nv = csr_new_val(mstatus_rd, csr_wdata, csr_op);
wire [31:0] mie_nv     = csr_new_val({8'b0, mie_q, 16'b0}, csr_wdata, csr_op);
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
        mie_q <= 8'b0;
    else if (wr_mie)
        mie_q <= mie_nv[23:16];
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

// free-running cycle counter
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mcycle_q <= 32'b0;
    else
        mcycle_q <= mcycle_q + 1;
end

// retired-instruction counter
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        minstret_q <= 32'b0;
    else if (retire)
        minstret_q <= minstret_q + 1;
end

// hardware performance counters (D25): one per event, same shape as
// mcycle/minstret (free-running, read-only, reset to 0)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm3_q <= 32'b0;
    else if (ev_mispredict)
        mhpm3_q <= mhpm3_q + 1;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm4_q <= 32'b0;
    else if (ev_ibus_wait)
        mhpm4_q <= mhpm4_q + 1;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm5_q <= 32'b0;
    else if (ev_dbus_stall)
        mhpm5_q <= mhpm5_q + 1;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm6_q <= 32'b0;
    else if (trap_set)
        mhpm6_q <= mhpm6_q + 1;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mhpm7_q <= 32'b0;
    else if (ev_wfi_sleep)
        mhpm7_q <= mhpm7_q + 1;
end

endmodule
