// M-mode CSRs, trap state and 64-bit counters.
// Software writes override counter increments and preserve the untouched half.
// minstret counts non-trapping S2 completions, in order with CSR accesses.
// Fixed HPM events: 1=mispredict, 2=fetch wait, 3=data stall, 4=trap, 5=WFI.
// mhpmevent3..7 report those IDs; writes are ignored (WARL).
// Unused HPM counters/selectors read zero. mcountinhibit is absent.
// mip is read-only by the Siemens brief; causes 16..31 are the project PIC mapping.
// Trap entry has priority over software writes; MRET restores MIE from MPIE.

`include "rv32i_defines.vh"

module rv32i_csr_file #(
    parameter HART_ID = 32'd0
) (
    input clk_i,
    input rst_n_i,

    // CSR access from S2
    input      [11:0] csr_addr_i,
    input      [31:0] csr_wdata_i,   // forwarded rs1 or zext(uimm5)
    input      [ 1:0] csr_op_i,      // CSROP_RW / _RS / _RC
    input             csr_ren_i,     // valid CSR instruction (address check)
    input             csr_wen_i,     // effective write requested
    output reg [31:0] csr_rdata_o,
    output            csr_illegal_o,

    // trap entry / return
    input        trap_set_i,
    input        trap_is_irq_i,
    input [ 4:0] trap_code_i,    // cause code (sync 0..11, irq 16..31)
    input [31:0] trap_pc_i,      // -> mepc
    input [31:0] trap_val_i,     // -> mtval (fault address, or instruction on illegal)
    input        mret_i,

    // interrupt side
    input  [15:0] irq_lines_i,   // pending one-hot -> mip[31:16]
    output [15:0] irq_enable_o,  // mie[31:16]
    output        mie_global_o,  // mstatus.MIE

    // architectural targets
    output [31:0] trap_vector_o,  // handler address for the current cause
    output [31:0] mepc_out_o,

    // counters
    input retire_i,         // non-trapping instruction completes S2
    input ev_mispredict_i,  // one pulse per mispredict redirect (D25)
    input ev_ibus_wait_i,   // level: S2 has no instruction
    input ev_dbus_stall_i,  // level: data AXI op in flight
    input ev_wfi_sleep_i    // level: WFI sleeping (D23)
);

    // CSR addresses (Privileged ISA v20211203)
    localparam MISA      = 12'h301;
    localparam MSTATUS   = 12'h300;
    localparam MIE       = 12'h304;
    localparam MTVEC     = 12'h305;
    localparam MSCRATCH  = 12'h340;
    localparam MEPC      = 12'h341;
    localparam MCAUSE    = 12'h342;
    localparam MTVAL     = 12'h343;
    localparam MIP       = 12'h344;
    localparam MVENDID   = 12'hF11;
    localparam MARCHID   = 12'hF12;
    localparam MIMPID    = 12'hF13;
    localparam MCYCLE    = 12'hB00;
    localparam MINSTRET  = 12'hB02;
    localparam MHPMC3    = 12'hB03;  // mispredicts        (D25)
    localparam MHPMC4    = 12'hB04;  // fetch-starved cycles
    localparam MHPMC5    = 12'hB05;  // dbus stall cycles
    localparam MHPMC6    = 12'hB06;  // traps taken
    localparam MHPMC7    = 12'hB07;  // WFI sleep cycles
    // upper halves: on RV32 every counter is architecturally 64-bit and is read
    // through a base/base+0x80 pair (Priv. spec 3.1.11)
    localparam MCYCLEH   = 12'hB80;
    localparam MINSTRETH = 12'hB82;
    localparam MHPMC3H   = 12'hB83;
    localparam MHPMC4H   = 12'hB84;
    localparam MHPMC5H   = 12'hB85;
    localparam MHPMC6H   = 12'hB86;
    localparam MHPMC7H   = 12'hB87;
    localparam MHARTID   = 12'hF14;

    reg mstatus_mie_q, mstatus_mpie_q;
    reg [15:0] mie_q;
    reg [31:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;
    reg [63:0] mcycle_q, minstret_q;
    reg [63:0] mhpm3_q, mhpm4_q, mhpm5_q, mhpm6_q, mhpm7_q;

    // mhpmcounter8..31 / their upper halves / mhpmevent8..31 exist but are
    // hardwired to zero: the spec allows an implementation to tie off counters it
    // does not provide, but they must still read as 0 instead of trapping, and a
    // write to them is ignored (WARL) rather than raising illegal.
    wire hpm_wired0 = ((csr_addr_i >= 12'hB08) && (csr_addr_i <= 12'hB1F))  // mhpmcounter8..31
    || ((csr_addr_i >= 12'hB88) && (csr_addr_i <= 12'hB9F))  // mhpmcounter8..31h
    || ((csr_addr_i >= 12'h328) && (csr_addr_i <= 12'h33F));  // mhpmevent8..31
    wire hpm_fixed_event = (csr_addr_i >= 12'h323) && (csr_addr_i <= 12'h327);

    wire [31:0] mstatus_rd = {19'b0, 2'b11, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};
    wire [31:0] misa_rd = 32'h4000_0100;  // MXL=32, extension I (RV32I)

    // combinational read + address check
    reg addr_ok;
    reg addr_ro;  // implemented but read-only
    always @(*) begin
        case (csr_addr_i)
            MSTATUS, MISA, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MTVAL, MIP,
            MVENDID, MARCHID, MIMPID, MHARTID,
            MCYCLE, MINSTRET, MHPMC3, MHPMC4, MHPMC5, MHPMC6, MHPMC7,
            MCYCLEH, MINSTRETH, MHPMC3H, MHPMC4H, MHPMC5H, MHPMC6H, MHPMC7H:
            addr_ok = 1'b1;
            default: addr_ok = hpm_wired0 || hpm_fixed_event;
        endcase
    end

    always @(*) begin
        case (csr_addr_i)
            MIP, MVENDID, MARCHID, MIMPID, MHARTID: addr_ro = 1'b1;
            default:                                addr_ro = 1'b0;
        endcase
    end

    always @(*) begin
        case (csr_addr_i)

            MSTATUS:   csr_rdata_o = mstatus_rd;
            MISA:      csr_rdata_o = misa_rd;
            MIE:       csr_rdata_o = {mie_q, 16'b0};
            MTVEC:     csr_rdata_o = mtvec_q;
            MSCRATCH:  csr_rdata_o = mscratch_q;
            MEPC:      csr_rdata_o = mepc_q;
            MCAUSE:    csr_rdata_o = mcause_q;
            MTVAL:     csr_rdata_o = mtval_q;
            MIP:       csr_rdata_o = {irq_lines_i, 16'b0};
            MVENDID:   csr_rdata_o = 32'b0;
            MARCHID:   csr_rdata_o = 32'b0;
            MIMPID:    csr_rdata_o = 32'b0;
            MCYCLE:    csr_rdata_o = mcycle_q[31:0];
            MINSTRET:  csr_rdata_o = minstret_q[31:0];
            MHPMC3:    csr_rdata_o = mhpm3_q[31:0];
            MHPMC4:    csr_rdata_o = mhpm4_q[31:0];
            MHPMC5:    csr_rdata_o = mhpm5_q[31:0];
            MHPMC6:    csr_rdata_o = mhpm6_q[31:0];
            MHPMC7:    csr_rdata_o = mhpm7_q[31:0];
            MCYCLEH:   csr_rdata_o = mcycle_q[63:32];
            MINSTRETH: csr_rdata_o = minstret_q[63:32];
            MHPMC3H:   csr_rdata_o = mhpm3_q[63:32];
            MHPMC4H:   csr_rdata_o = mhpm4_q[63:32];
            MHPMC5H:   csr_rdata_o = mhpm5_q[63:32];
            MHPMC6H:   csr_rdata_o = mhpm6_q[63:32];
            MHPMC7H:   csr_rdata_o = mhpm7_q[63:32];
            MHARTID:   csr_rdata_o = HART_ID;
            default:   csr_rdata_o = hpm_fixed_event ? {20'b0, csr_addr_i} - 32'h322 : 32'b0;
        endcase
    end

    assign csr_illegal_o = ((csr_ren_i | csr_wen_i) & ~addr_ok) | (csr_wen_i & addr_ro);

    assign irq_enable_o  = mie_q;
    assign mie_global_o  = mstatus_mie_q;
    assign mepc_out_o    = mepc_q;

    // vectored applies to interrupts only: BASE + 4*cause; exceptions go to BASE
    wire [31:0] tvec_base = {mtvec_q[31:2], 2'b00};
    assign trap_vector_o = (mtvec_q[1:0] == 2'b01 && trap_is_irq_i)
                     ? tvec_base + {25'b0, trap_code_i, 2'b00}
                     : tvec_base;

    // mtvec.MODE supports direct (0) and vectored (1). Reserved modes map to direct.
    function [31:0] mtvec_warl;
        input [31:0] v;
        mtvec_warl = {v[31:2], v[1] ? 2'b00 : v[1:0]};
    endfunction

    // new value per CSR op type
    function [31:0] csr_new_val;
        input [31:0] old_val;
        input [31:0] write_data;
        input [1:0] op;
        case (op)
            `CSROP_RW: csr_new_val = write_data;
            `CSROP_RS: csr_new_val = old_val | write_data;
            `CSROP_RC: csr_new_val = old_val & ~write_data;
            default:   csr_new_val = old_val;
        endcase
    endfunction

    // Explicit writes override the event update and preserve the other half.
    // CSRRS/CSRRC use the value before the writing instruction.
    function [63:0] cnt_next;
        input [63:0] cur;
        input ev;
        input wr_lo;
        input wr_hi;
        input [31:0] wdata;
        input [1:0] op;
        reg [63:0] inc;
        begin
            inc = cur + {63'b0, ev};
            if (wr_lo) cnt_next = {cur[63:32], csr_new_val(cur[31:0], wdata, op)};
            else if (wr_hi) cnt_next = {csr_new_val(cur[63:32], wdata, op), cur[31:0]};
            else cnt_next = inc;
        end
    endfunction

    wire [31:0] mstatus_nv = csr_new_val(mstatus_rd, csr_wdata_i, csr_op_i);
    wire [31:0] mie_nv = csr_new_val({mie_q, 16'b0}, csr_wdata_i, csr_op_i);
    wire [31:0] mepc_nv = csr_new_val(mepc_q, csr_wdata_i, csr_op_i);

    // committed software write. It never coincides with trap_set_i or mret_i: an
    // interrupt kills csr_wen_i, a CSR op's only exception is its own illegal access
    // (blocked here), and MRET is a different instruction. The trap arms below are
    // still checked first anyway, so hardware always wins over a software write.
    wire        csr_wr = csr_wen_i && !csr_illegal_o;

    wire        wr_mstatus = csr_wr && (csr_addr_i == MSTATUS);
    wire        wr_mie = csr_wr && (csr_addr_i == MIE);
    wire        wr_mtvec = csr_wr && (csr_addr_i == MTVEC);
    wire        wr_mscratch = csr_wr && (csr_addr_i == MSCRATCH);
    wire        wr_mepc = csr_wr && (csr_addr_i == MEPC);
    wire        wr_mcause = csr_wr && (csr_addr_i == MCAUSE);
    wire        wr_mtval = csr_wr && (csr_addr_i == MTVAL);

    // counter writes (M-mode may write every counter half; Priv. spec 3.1.11)
    wire        wr_cyc_lo = csr_wr && (csr_addr_i == MCYCLE);
    wire        wr_cyc_hi = csr_wr && (csr_addr_i == MCYCLEH);
    wire        wr_ins_lo = csr_wr && (csr_addr_i == MINSTRET);
    wire        wr_ins_hi = csr_wr && (csr_addr_i == MINSTRETH);
    wire        wr_h3_lo = csr_wr && (csr_addr_i == MHPMC3);
    wire        wr_h3_hi = csr_wr && (csr_addr_i == MHPMC3H);
    wire        wr_h4_lo = csr_wr && (csr_addr_i == MHPMC4);
    wire        wr_h4_hi = csr_wr && (csr_addr_i == MHPMC4H);
    wire        wr_h5_lo = csr_wr && (csr_addr_i == MHPMC5);
    wire        wr_h5_hi = csr_wr && (csr_addr_i == MHPMC5H);
    wire        wr_h6_lo = csr_wr && (csr_addr_i == MHPMC6);
    wire        wr_h6_hi = csr_wr && (csr_addr_i == MHPMC6H);
    wire        wr_h7_lo = csr_wr && (csr_addr_i == MHPMC7);
    wire        wr_h7_hi = csr_wr && (csr_addr_i == MHPMC7H);

    // mstatus.MIE/MPIE: the pair swaps on trap entry and swaps back on MRET
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mstatus_mie_q <= 1'b0;
        else if (trap_set_i) mstatus_mie_q <= 1'b0;
        else if (mret_i) mstatus_mie_q <= mstatus_mpie_q;
        else if (wr_mstatus) mstatus_mie_q <= mstatus_nv[3];
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mstatus_mpie_q <= 1'b0;
        else if (trap_set_i) mstatus_mpie_q <= mstatus_mie_q;
        else if (mret_i) mstatus_mpie_q <= 1'b1;
        else if (wr_mstatus) mstatus_mpie_q <= mstatus_nv[7];
    end

    // mepc: trap entry records the return address, bits [1:0] always 0
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mepc_q <= 32'b0;
        else if (trap_set_i) mepc_q <= {trap_pc_i[31:2], 2'b00};
        else if (wr_mepc) mepc_q <= {mepc_nv[31:2], 2'b00};
    end

    // mcause: interrupt flag in bit 31, code in the low bits
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mcause_q <= 32'b0;
        else if (trap_set_i) mcause_q <= {trap_is_irq_i, 26'b0, trap_code_i};
        else if (wr_mcause) mcause_q <= csr_new_val(mcause_q, csr_wdata_i, csr_op_i);
    end

    // mtval: trap entry records the fault address (or the instruction on illegal)
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mtval_q <= 32'b0;
        else if (trap_set_i) mtval_q <= trap_val_i;
        else if (wr_mtval) mtval_q <= csr_new_val(mtval_q, csr_wdata_i, csr_op_i);
    end

    // software-only CSRs
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mie_q <= 16'b0;
        else if (wr_mie) mie_q <= mie_nv[31:16];
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mtvec_q <= 32'b0;
        else if (wr_mtvec) mtvec_q <= mtvec_warl(csr_new_val(mtvec_q, csr_wdata_i, csr_op_i));
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mscratch_q <= 32'b0;
        else if (wr_mscratch) mscratch_q <= csr_new_val(mscratch_q, csr_wdata_i, csr_op_i);
    end

    // 64-bit counters. Every one has the same shape: increment on its event, or
    // take a software write on the addressed half (one always block per register).

    // free-running cycle counter
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mcycle_q <= 64'b0;
        else mcycle_q <= cnt_next(mcycle_q, 1'b1, wr_cyc_lo, wr_cyc_hi, csr_wdata_i, csr_op_i);
    end

    // retired-instruction counter
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) minstret_q <= 64'b0;
        else
            minstret_q <= cnt_next(
                minstret_q, retire_i, wr_ins_lo, wr_ins_hi, csr_wdata_i, csr_op_i
            );
    end

    // hardware performance counters (D25): one per event
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mhpm3_q <= 64'b0;
        else
            mhpm3_q <= cnt_next(
                mhpm3_q, ev_mispredict_i, wr_h3_lo, wr_h3_hi, csr_wdata_i, csr_op_i
            );
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mhpm4_q <= 64'b0;
        else
            mhpm4_q <= cnt_next(mhpm4_q, ev_ibus_wait_i, wr_h4_lo, wr_h4_hi, csr_wdata_i, csr_op_i);
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mhpm5_q <= 64'b0;
        else
            mhpm5_q <= cnt_next(
                mhpm5_q, ev_dbus_stall_i, wr_h5_lo, wr_h5_hi, csr_wdata_i, csr_op_i
            );
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mhpm6_q <= 64'b0;
        else mhpm6_q <= cnt_next(mhpm6_q, trap_set_i, wr_h6_lo, wr_h6_hi, csr_wdata_i, csr_op_i);
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mhpm7_q <= 64'b0;
        else
            mhpm7_q <= cnt_next(mhpm7_q, ev_wfi_sleep_i, wr_h7_lo, wr_h7_hi, csr_wdata_i, csr_op_i);
    end

endmodule
