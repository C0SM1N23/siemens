// M-mode CSR file.
// REQ# = spec requirement, D# = design choice; both are tracked in the README.
//
// Spec coverage:
//
// - REQ9
//   The 7 required CSRs at their addresses: mstatus 0x300, mie 0x304,
//   mtvec 0x305, mscratch 0x340, mepc 0x341, mcause 0x342, mip 0x344 —
//   with mip read-only, driven by the PIC lines.
//   Live fields only, the rest read 0/WPRI:
//   - mstatus: MIE(3), MPIE(7); MPP(12:11) hardwired 2'b11 (M-mode)
//   - mtvec:   BASE[31:2] + MODE[1:0]
//   - mepc:    bits [1:0] forced to 0
//
// Design choices:
//
// - D3
//   The 8 PIC channels map to mie/mip bits 16..23 (external-interrupt
//   causes 16..23) — the interrupt half of the supported-cause set.
//
// - D5
//   Read-only mhartid (0xF14) from the HART_ID parameter (multi-core).
//   Read-only mcycle/minstret counters kept as verification aids.
//
// - D15
//   Any access to an unimplemented CSR, or an effective write to a
//   read-only one, raises illegal instruction in S2 (not a bus DECERR —
//   CSRs are internal). csr_wen already drops the "CSRRS/C with x0/uimm=0
//   = pure read" case, so those don't trap.
//
// - D16
//   Vectored mtvec: interrupts -> BASE + 4*cause, exceptions -> BASE.
//   Direct mode sends everything to BASE.
//
// Notes:
//
// - Trap entry / MRET are sequenced by cpu_top:
//   - trap_set commits mepc / mcause / MPIE<-MIE / MIE<-0 atomically
//   - mret does MIE<-MPIE, MPIE<-1
// - trap_set wins over a same-cycle software write — the trapping
//   instruction never commits its own write.

module csr_file #(
    parameter HART_ID = 32'd0
)(
    input             clk,
    input             rst_n,

    // CSR access from S2
    input      [11:0] csr_addr,
    input      [31:0] csr_wdata,     // forwarded rs1 or zext(uimm5)
    input      [1:0]  csr_op,        // 01=RW, 10=RS, 11=RC
    input             csr_ren,       // valid CSR instruction (address check)
    input             csr_wen,       // effective write requested
    output reg [31:0] csr_rdata,
    output            csr_illegal,

    // trap entry / return
    input             trap_set,
    input             trap_is_irq,
    input      [4:0]  trap_code,     // cause code (0..23)
    input      [31:0] trap_pc,       // -> mepc
    input             mret,

    // interrupt side
    input      [7:0]  irq_lines,     // cpu_irq -> mip[23:16]
    output     [7:0]  irq_enable,    // mie[23:16]
    output            mie_global,    // mstatus.MIE

    // architectural targets
    output     [31:0] trap_vector,   // handler address for the current cause
    output     [31:0] mepc_out,

    // counters
    input             retire         // instruction committed in S3
);

// CSR addresses (Privileged ISA v20211203)
localparam MSTATUS  = 12'h300;
localparam MIE      = 12'h304;
localparam MTVEC    = 12'h305;
localparam MSCRATCH = 12'h340;
localparam MEPC     = 12'h341;
localparam MCAUSE   = 12'h342;
localparam MIP      = 12'h344;
localparam MCYCLE   = 12'hB00;
localparam MINSTRET = 12'hB02;
localparam MHARTID  = 12'hF14;

reg        mstatus_mie_q, mstatus_mpie_q;
reg [7:0]  mie_q;
reg [31:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mcycle_q, minstret_q;

wire [31:0] mstatus_rd = {19'b0, 2'b11, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};

// combinational read + address check
reg addr_ok;
reg addr_ro;    // implemented but read-only
always @(*) begin
    addr_ok = 1; addr_ro = 0;
    case (csr_addr)
        MSTATUS:  csr_rdata = mstatus_rd;
        MIE:      csr_rdata = {8'b0, mie_q, 16'b0};
        MTVEC:    csr_rdata = mtvec_q;
        MSCRATCH: csr_rdata = mscratch_q;
        MEPC:     csr_rdata = mepc_q;
        MCAUSE:   csr_rdata = mcause_q;
        MIP:      begin csr_rdata = {8'b0, irq_lines, 16'b0}; addr_ro = 1; end
        MCYCLE:   begin csr_rdata = mcycle_q;   addr_ro = 1; end
        MINSTRET: begin csr_rdata = minstret_q; addr_ro = 1; end
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
        2'b01:   csr_new_val = write_data;            // CSRRW
        2'b10:   csr_new_val = old_val |  write_data; // CSRRS
        2'b11:   csr_new_val = old_val & ~write_data; // CSRRC
        default: csr_new_val = old_val;
    endcase
endfunction

wire [31:0] mstatus_nv = csr_new_val(mstatus_rd, csr_wdata, csr_op);
wire [31:0] mie_nv     = csr_new_val({8'b0, mie_q, 16'b0}, csr_wdata, csr_op);
wire [31:0] mepc_nv    = csr_new_val(mepc_q, csr_wdata, csr_op);

// committed software write. Note it can never coincide with trap_set or mret:
// an interrupt kills csr_wen (dec_live drops), the only exception a CSR op can
// raise is its own illegal access (blocked right here), and MRET is a
// different instruction entirely. The trap arms below still come first so
// each register reads as "hardware beats software".
wire csr_wr = csr_wen && !csr_illegal;

wire wr_mstatus  = csr_wr && (csr_addr == MSTATUS);
wire wr_mie      = csr_wr && (csr_addr == MIE);
wire wr_mtvec    = csr_wr && (csr_addr == MTVEC);
wire wr_mscratch = csr_wr && (csr_addr == MSCRATCH);
wire wr_mepc     = csr_wr && (csr_addr == MEPC);
wire wr_mcause   = csr_wr && (csr_addr == MCAUSE);

// mstatus.MIE/MPIE — the pair swaps on trap entry and swaps back on MRET
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

// mepc — trap entry records the return address, bits [1:0] always 0
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mepc_q <= 32'b0;
    else if (trap_set)
        mepc_q <= {trap_pc[31:2], 2'b00};
    else if (wr_mepc)
        mepc_q <= {mepc_nv[31:2], 2'b00};
end

// mcause — interrupt flag in bit 31, code in the low bits
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mcause_q <= 32'b0;
    else if (trap_set)
        mcause_q <= {trap_is_irq, 26'b0, trap_code};
    else if (wr_mcause)
        mcause_q <= csr_new_val(mcause_q, csr_wdata, csr_op);
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

endmodule
