// Synchronous exception detect in S2, kept precise.
// D# = design choice, tracked in the README.
//
// D3: the supported mcause set, resolved at the end of S2 so the offending
//     instruction never reaches writeback. A priority chain picks one cause
//     (they're mutually exclusive over an instruction's life anyway):
//       0    instruction address misaligned (taken branch/jump, target[1]=1)
//       1    instruction access fault (ibus SLVERR/DECERR, carried via IF/DX)
//       2    illegal instruction
//       3    breakpoint
//      11    env call (M-mode)
//       4/6  load/store addr misaligned
//       5/7  load/store access fault
//     (external-interrupt causes 16..31 live in csr_file, also D3.)
// D17: load/store misalignment is checked before the access, so a misaligned op
//      (cause 4/6) never issues an AXI transaction.
// D18: a bus error maps to an access fault: fetch to cause 1, load to 5, store
//      to 7.
//
// Interrupts don't come through here: cpu_top evaluates them before execution
// and delivers valid_i=0 for a preempted instruction.

`timescale 1ns/1ps

`include "defines.vh"

module exception_unit (
    input             valid_i,          // real, non-preempted instruction in S2
    input             fetch_fault_i,    // AXI error on this instruction's fetch
    input             illegal_i,        // decoder or CSR access is illegal
    input             ecall_i,
    input             ebreak_i,

    // mtval sources (picked by the same chain that picks the cause)
    input      [31:0] pc_i,             // S2 instruction address
    input      [31:0] instr_i,          // raw S2 instruction word

    // resolved control transfer (branch/jump)
    input             ctl_taken_i,      // real direction = taken
    input      [31:0] ctl_target_i,     // real target

    // memory access (load/store)
    input             MemRead_i,
    input             MemWrite_i,
    input      [2:0]  funct3_i,
    input      [31:0] mem_addr_i,       // ALU result, only meaningful pre-issue
    input             mem_active_i,     // dbus transaction already issued
    input             mem_done_i,       // dbus response landed this cycle
    input             mem_err_i,        // response was SLVERR/DECERR

    output            exception_o,
    output reg [4:0]  cause_o,
    output reg [31:0] tval_o,           // mtval payload for the picked cause
    output            mem_misaligned_o  // blocks the AXI issue (D17)
);

// alignment by size: LH/SH need addr[0]=0, LW/SW need addr[1:0]=00.
// Only checked pre-issue; once the op is out, the address was already good
// (and the ALU result may drift during the stall since S3 bubbles out).
wire misal = (funct3_i[1:0] == 2'b01 && mem_addr_i[0]) ||
             (funct3_i[1:0] == 2'b10 && mem_addr_i[1:0] != 2'b00);

wire ld_misal    = MemRead_i  && misal && !mem_active_i;
wire st_misal    = MemWrite_i && misal && !mem_active_i;
wire instr_misal = ctl_taken_i && ctl_target_i[1];
wire ld_fault    = MemRead_i  && mem_done_i && mem_err_i;
wire st_fault    = MemWrite_i && mem_done_i && mem_err_i;

assign mem_misaligned_o = ld_misal | st_misal;

// one priority chain decides the hit, the cause and the mtval payload, so the
// cause list exists in exactly one place. mtval: the PC for fetch faults or a
// breakpoint, the instruction on an illegal one, the target/address on misalign
// and access faults, 0 for an environment call
reg exc;
always @(*) begin
    exc = 1'b1;
    if      (fetch_fault_i) begin cause_o = `CAUSE_IFAULT;      tval_o = pc_i;         end
    else if (illegal_i)     begin cause_o = `CAUSE_ILLEGAL;     tval_o = instr_i;      end
    else if (ebreak_i)      begin cause_o = `CAUSE_BREAK;       tval_o = pc_i;         end
    else if (ecall_i)       begin cause_o = `CAUSE_ECALL_M;     tval_o = 32'b0;        end
    else if (instr_misal)   begin cause_o = `CAUSE_IMISALIGN;   tval_o = ctl_target_i; end
    else if (ld_misal)      begin cause_o = `CAUSE_LD_MISALIGN; tval_o = mem_addr_i;   end
    else if (st_misal)      begin cause_o = `CAUSE_ST_MISALIGN; tval_o = mem_addr_i;   end
    else if (ld_fault)      begin cause_o = `CAUSE_LD_FAULT;    tval_o = mem_addr_i;   end
    else if (st_fault)      begin cause_o = `CAUSE_ST_FAULT;    tval_o = mem_addr_i;   end
    else begin
        exc     = 1'b0;
        cause_o = 5'd0;
        tval_o  = 32'b0;
    end
end

assign exception_o = valid_i & exc;

endmodule
