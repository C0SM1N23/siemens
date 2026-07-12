// Sync exception detect in S2 — precise traps.
// D# = design choice; tracked in the README.
//
// D3: the supported mcause set, resolved at the end of S2 so the offending
//     instruction never reaches writeback. A priority chain picks one cause
//     (they're mutually exclusive over an instruction's life anyway):
//       0    instr addr misaligned (taken branch/jump, target[1]=1)
//       1    instr access fault (ibus SLVERR/DECERR, carried via IF/DX)
//       2    illegal instruction
//       3    breakpoint
//      11    env call (M-mode)
//       4/6  load/store addr misaligned
//       5/7  load/store access fault
//     (external-interrupt causes 16..23 live in csr_file, also D3.)
// D17: load/store misalignment is checked before the access, so a misaligned op
//      (cause 4/6) never issues an AXI transaction.
// D18: a bus error becomes an access fault, not "illegal" — fetch to cause 1,
//      load to 5, store to 7.
//
// Interrupts don't come through here: cpu_top evaluates them before execution
// and delivers valid=0 for a preempted instruction.

`include "defines.vh"

module exception_unit (
    input             valid,          // real, non-preempted instruction in S2
    input             fetch_fault,    // AXI error on this instruction's fetch
    input             illegal,        // decoder / CSR access illegal
    input             ecall,
    input             ebreak,

    // resolved control transfer (branch/jump)
    input             ctl_taken,      // real direction = taken
    input      [31:0] ctl_target,     // real target

    // memory access (load/store)
    input             MemRead,
    input             MemWrite,
    input      [2:0]  funct3,
    input      [31:0] mem_addr,       // ALU result, only meaningful pre-issue
    input             mem_active,     // dbus transaction already issued
    input             mem_done,       // dbus response landed this cycle
    input             mem_err,        // response was SLVERR/DECERR

    output            exception,
    output reg [4:0]  cause,
    output            mem_misaligned  // blocks the AXI issue (D17)
);

// alignment by size: LH/SH need addr[0]=0, LW/SW need addr[1:0]=00.
// Only checked pre-issue; once the op is out, the address was already good
// (and the ALU result may drift during the stall since S3 bubbles out).
wire misal = (funct3[1:0] == 2'b01 && mem_addr[0]) ||
             (funct3[1:0] == 2'b10 && mem_addr[1:0] != 2'b00);

wire ld_misal    = MemRead  && misal && !mem_active;
wire st_misal    = MemWrite && misal && !mem_active;
wire instr_misal = ctl_taken && ctl_target[1];
wire ld_fault    = MemRead  && mem_done && mem_err;
wire st_fault    = MemWrite && mem_done && mem_err;

assign mem_misaligned = ld_misal | st_misal;

// one priority chain decides both the hit and the cause, so the cause list
// exists in exactly one place
reg exc;
always @(*) begin
    exc = 1'b1;
    if      (fetch_fault) cause = `CAUSE_IFAULT;
    else if (illegal)     cause = `CAUSE_ILLEGAL;
    else if (ebreak)      cause = `CAUSE_BREAK;
    else if (ecall)       cause = `CAUSE_ECALL_M;
    else if (instr_misal) cause = `CAUSE_IMISALIGN;
    else if (ld_misal)    cause = `CAUSE_LD_MISALIGN;
    else if (st_misal)    cause = `CAUSE_ST_MISALIGN;
    else if (ld_fault)    cause = `CAUSE_LD_FAULT;
    else if (st_fault)    cause = `CAUSE_ST_FAULT;
    else begin
        exc   = 1'b0;
        cause = 5'd0;
    end
end

assign exception = valid & exc;

endmodule
