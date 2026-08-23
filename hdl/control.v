// RV32I control decoder.
// REQ# = spec requirement, D# = design choice, both tracked in the README.
//
// REQ7: control signals for every RV32I group.
//   - FENCE = NOP (single hart, in-order, nothing to fence)
//   - ECALL/EBREAK/CSR handled downstream (trap or CSR)
//   - SYSTEM is decoded strictly: ECALL/EBREAK/MRET/WFI and CSR* (including the
//     immediate forms), anything else is illegal_o
// D23: we only decode WFI here (Priv. spec 3.3.3); the sleep/wake logic lives in
//   cpu_top + hazard_unit, so a committed WFI leaves every line inactive (a NOP).
//
// Illegal detection feeds D3: an unknown opcode_i or a bad funct field sets
// illegal_o=1 and clears every other line, so an illegal_o op has no side effects
// and just traps in S2.

`timescale 1ns/1ps

`include "defines.vh"

module control (
    input      [6:0]  opcode_i,
    input      [2:0]  funct3_i,
    input      [6:0]  funct7_i,
    input      [4:0]  rs1_i,         // rs1_i/uimm field, checked in SYSTEM encodings
    input      [4:0]  rd_i,
    input      [11:0] imm12_i,       // instr[31:20], selects ECALL/EBREAK/MRET/WFI

    output reg        RegWrite_o,    // the instruction writes its rd register
    output reg        ALUSrc_o,      // 0=rs2, 1=imm
    output reg [3:0]  ALUOp_o,
    output reg        MemRead_o,
    output reg        MemWrite_o,
    output reg [1:0]  MemtoReg_o,    // WB_* select (CSR reads ride the WB_ALU slot)
    output reg        Branch_o,
    output reg        Jump_o,        // JAL/JALR
    output reg        csr_instr_o,   // CSR op (Zicsr)
    output reg [1:0]  csr_op_o,      // 01=RW, 10=RS, 11=RC
    output reg        csr_imm_o,     // immediate form, source = uimm5 from rs1_i field
    output reg        mret_o,
    output reg        ecall_o,
    output reg        ebreak_o,
    output reg        wfi_o,         // sleep until interrupt (D23)
    output reg        illegal_o
);

always @(*) begin
    // default: nothing (safe bubble)
    RegWrite_o  = 0; ALUSrc_o = 0; ALUOp_o = `ALUOP_ADD;
    MemRead_o   = 0; MemWrite_o = 0; MemtoReg_o = `WB_ALU;
    Branch_o    = 0; Jump_o = 0;
    csr_instr_o = 0; csr_op_o = 2'b00; csr_imm_o = 0;
    mret_o      = 0; ecall_o = 0; ebreak_o = 0; wfi_o = 0; illegal_o = 0;

    case (opcode_i)
        `OPC_OP: begin // R-type
            RegWrite_o = 1; ALUOp_o = `ALUOP_FUNCT;
            // funct7_i=0100000 only exists for SUB and SRA
            if (funct7_i == 7'b0100000) begin
                if (funct3_i != 3'b000 && funct3_i != 3'b101) illegal_o = 1;
            end else if (funct7_i != 7'b0000000)
                illegal_o = 1;
        end
        `OPC_OP_IMM: begin // I-type arithmetic
            RegWrite_o = 1; ALUSrc_o = 1; ALUOp_o = `ALUOP_FUNCT;
            // shifts carry shamt + a fixed funct7_i
            if (funct3_i == 3'b001 && funct7_i != 7'b0000000) illegal_o = 1;
            if (funct3_i == 3'b101 && funct7_i != 7'b0000000
                                 && funct7_i != 7'b0100000) illegal_o = 1;
        end
        `OPC_LOAD: begin // LB/LH/LW/LBU/LHU
            RegWrite_o = 1; ALUSrc_o = 1; MemRead_o = 1; MemtoReg_o = `WB_MEM;
            if (funct3_i == 3'b011 || funct3_i[2:1] == 2'b11) illegal_o = 1;
        end
        `OPC_STORE: begin // SB/SH/SW
            ALUSrc_o = 1; MemWrite_o = 1;
            if (funct3_i[2] || funct3_i == 3'b011) illegal_o = 1;
        end
        `OPC_BRANCH: begin // direction/target come from branch_unit, not the ALU
            Branch_o = 1;
            if (funct3_i == 3'b010 || funct3_i == 3'b011) illegal_o = 1;
        end
        `OPC_LUI: begin
            RegWrite_o = 1; ALUSrc_o = 1; ALUOp_o = `ALUOP_LUI;
        end
        `OPC_AUIPC: begin
            RegWrite_o = 1; ALUSrc_o = 1; ALUOp_o = `ALUOP_AUIPC;
        end
        `OPC_JAL: begin
            RegWrite_o = 1; ALUSrc_o = 1; Jump_o = 1; MemtoReg_o = `WB_PC4;
        end
        `OPC_JALR: begin
            RegWrite_o = 1; ALUSrc_o = 1; Jump_o = 1; MemtoReg_o = `WB_PC4;
            if (funct3_i != 3'b000) illegal_o = 1;
        end
        `OPC_FENCE: begin // FENCE = NOP: single hart, in-order
            if (funct3_i != 3'b000) illegal_o = 1;   // FENCE.I (Zifencei) not implemented
        end
        `OPC_SYSTEM: begin
            if (funct3_i == 3'b000) begin
                // exact encodings only, anything else is illegal_o
                if      (imm12_i == 12'h000 && rs1_i == 5'b0 && rd_i == 5'b0) ecall_o  = 1;
                else if (imm12_i == 12'h001 && rs1_i == 5'b0 && rd_i == 5'b0) ebreak_o = 1;
                else if (imm12_i == 12'h302 && rs1_i == 5'b0 && rd_i == 5'b0) mret_o   = 1;
                else if (imm12_i == 12'h105 && rs1_i == 5'b0 && rd_i == 5'b0) wfi_o    = 1;
                else illegal_o = 1;
            end else if (funct3_i[1:0] != 2'b00) begin
                // CSRRW/S/C (+I): rd gets the old CSR value, muxed into the
                // ALU-result slot at the end of S2 -> WB_ALU selects it
                RegWrite_o  = 1; MemtoReg_o = `WB_ALU;
                csr_instr_o = 1;
                csr_op_o    = funct3_i[1:0];
                csr_imm_o   = funct3_i[2];
            end else
                illegal_o = 1;   // funct3_i = 100 is reserved
        end
        default: illegal_o = 1;  // unknown opcode_i (covers instr[1:0] != 11 too)
    endcase
end

endmodule
