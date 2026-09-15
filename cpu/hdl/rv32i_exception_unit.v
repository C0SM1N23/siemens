// Synchronous S2 exceptions, resolved in priority order.
// Misaligned data accesses trap before the bus starts; access faults wait for the response.
// The trapping instruction is squashed before architectural writeback.

`include "rv32i_defines.vh"

module rv32i_exception_unit (
    input valid_i,        // real, non-preempted instruction in S2
    input fetch_fault_i,  // AXI error on this instruction's fetch
    input illegal_i,      // decoder or CSR access is illegal
    input ecall_i,
    input ebreak_i,

    // mtval sources (picked by the same chain that picks the cause)
    input [31:0] pc_i,    // S2 instruction address
    input [31:0] instr_i, // raw S2 instruction word

    // resolved control transfer (branch/jump)
    input        ctl_taken_i,  // real direction = taken
    input [31:0] ctl_target_i, // real target

    // memory access (load/store)
    input        MemRead_i,
    input        MemWrite_i,
    input [ 2:0] funct3_i,
    input [31:0] mem_addr_i,    // ALU result, only meaningful pre-issue
    input        mem_active_i,  // dbus transaction already issued
    input        mem_done_i,    // dbus response landed this cycle
    input        mem_err_i,     // response was SLVERR/DECERR

    output            exception_o,
    output reg [ 4:0] cause_o,
    output reg [31:0] tval_o,           // mtval payload for the picked cause
    output            mem_misaligned_o  // blocks the AXI issue (D17)
);

    // alignment by size: LH/SH need addr[0]=0, LW/SW need addr[1:0]=00.
    // Only checked pre-issue; once the op is out, the address was already good
    // (and the ALU result may drift during the stall since S3 bubbles out).
    wire misal = (funct3_i[1:0] == 2'b01 && mem_addr_i[0]) ||
             (funct3_i[1:0] == 2'b10 && mem_addr_i[1:0] != 2'b00);

    wire ld_misal = MemRead_i && misal && !mem_active_i;
    wire st_misal = MemWrite_i && misal && !mem_active_i;
    wire instr_misal = ctl_taken_i && ctl_target_i[1];
    wire ld_fault = MemRead_i && mem_done_i && mem_err_i;
    wire st_fault = MemWrite_i && mem_done_i && mem_err_i;

    assign mem_misaligned_o = ld_misal | st_misal;

    // one priority chain decides the hit, the cause and the mtval payload, so the
    // cause list exists in exactly one place. mtval: the PC for fetch faults or a
    // breakpoint, the instruction on an illegal one, the target/address on misalign
    // and access faults, 0 for an environment call
    wire exc = fetch_fault_i || illegal_i || ebreak_i || ecall_i || instr_misal ||
           ld_misal || st_misal || ld_fault || st_fault;

    always @(*) begin
        if (fetch_fault_i) cause_o = `CAUSE_IFAULT;
        else if (illegal_i) cause_o = `CAUSE_ILLEGAL;
        else if (ebreak_i) cause_o = `CAUSE_BREAK;
        else if (ecall_i) cause_o = `CAUSE_ECALL_M;
        else if (instr_misal) cause_o = `CAUSE_IMISALIGN;
        else if (ld_misal) cause_o = `CAUSE_LD_MISALIGN;
        else if (st_misal) cause_o = `CAUSE_ST_MISALIGN;
        else if (ld_fault) cause_o = `CAUSE_LD_FAULT;
        else if (st_fault) cause_o = `CAUSE_ST_FAULT;
        else cause_o = 5'd0;
    end

    always @(*) begin
        tval_o = 32'b0;
        if (exc)
            case (cause_o)
                `CAUSE_IFAULT, `CAUSE_BREAK: tval_o = pc_i;
                `CAUSE_ILLEGAL: tval_o = instr_i;
                `CAUSE_IMISALIGN: tval_o = ctl_target_i;
                `CAUSE_LD_MISALIGN, `CAUSE_ST_MISALIGN, `CAUSE_LD_FAULT, `CAUSE_ST_FAULT:
                tval_o = mem_addr_i;
                default: tval_o = 32'b0;
            endcase
    end

    assign exception_o = valid_i & exc;
endmodule
