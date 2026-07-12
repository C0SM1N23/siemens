// RV32I control decoder.
// REQ# = spec requirement, D# = design choice; both tracked in the README.
//
// REQ7: control signals for every RV32I group.
//   - FENCE = NOP (single hart, in-order, nothing to fence)
//   - ECALL/EBREAK/CSR handled downstream (trap or CSR)
//   - SYSTEM decoded strictly: ECALL/EBREAK/MRET/WFI + CSR* (incl. immediate
//     forms); anything else is illegal
// D23: WFI decode only (Priv. spec 3.3.3); sleep/wake lives in cpu_top +
//   hazard_unit, so a committed WFI leaves every line inactive (a NOP).
//
// Illegal detection feeds D3: an unknown opcode or bad funct field sets
// illegal=1 and clears every other line, so an illegal op has no side effects
// and just traps in S2.

`include "defines.vh"

module control (
    input      [6:0]  opcode,
    input      [2:0]  funct3,
    input      [6:0]  funct7,
    input      [4:0]  rs1,         // rs1/uimm field, checked in SYSTEM encodings
    input      [4:0]  rd,
    input      [11:0] imm12,       // instr[31:20], selects ECALL/EBREAK/MRET/WFI

    output reg        RegWrite,    // writes rd
    output reg        ALUSrc,      // 0=rs2, 1=imm
    output reg [3:0]  ALUOp,
    output reg        MemRead,
    output reg        MemWrite,
    output reg [1:0]  MemtoReg,    // WB_* select (CSR reads ride the WB_ALU slot)
    output reg        Branch,
    output reg        Jump,        // JAL/JALR
    output reg        csr_instr,   // CSR op (Zicsr)
    output reg [1:0]  csr_op,      // 01=RW, 10=RS, 11=RC
    output reg        csr_imm,     // immediate form, source = uimm5 from rs1 field
    output reg        mret,
    output reg        ecall,
    output reg        ebreak,
    output reg        wfi,         // sleep until interrupt (D23)
    output reg        illegal
);

always @(*) begin
    // default: nothing (safe bubble)
    RegWrite  = 0; ALUSrc = 0; ALUOp = `ALUOP_ADD;
    MemRead   = 0; MemWrite = 0; MemtoReg = `WB_ALU;
    Branch    = 0; Jump = 0;
    csr_instr = 0; csr_op = 2'b00; csr_imm = 0;
    mret      = 0; ecall = 0; ebreak = 0; wfi = 0; illegal = 0;

    case (opcode)
        `OPC_OP: begin // R-type
            RegWrite = 1; ALUOp = `ALUOP_FUNCT;
            // funct7=0100000 only exists for SUB and SRA
            if (funct7 == 7'b0100000) begin
                if (funct3 != 3'b000 && funct3 != 3'b101) illegal = 1;
            end else if (funct7 != 7'b0000000)
                illegal = 1;
        end
        `OPC_OP_IMM: begin // I-type arithmetic
            RegWrite = 1; ALUSrc = 1; ALUOp = `ALUOP_FUNCT;
            // shifts carry shamt + a fixed funct7
            if (funct3 == 3'b001 && funct7 != 7'b0000000) illegal = 1;
            if (funct3 == 3'b101 && funct7 != 7'b0000000
                                 && funct7 != 7'b0100000) illegal = 1;
        end
        `OPC_LOAD: begin // LB/LH/LW/LBU/LHU
            RegWrite = 1; ALUSrc = 1; MemRead = 1; MemtoReg = `WB_MEM;
            if (funct3 == 3'b011 || funct3[2:1] == 2'b11) illegal = 1;
        end
        `OPC_STORE: begin // SB/SH/SW
            ALUSrc = 1; MemWrite = 1;
            if (funct3[2] || funct3 == 3'b011) illegal = 1;
        end
        `OPC_BRANCH: begin // direction/target come from branch_unit, not the ALU
            Branch = 1;
            if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1;
        end
        `OPC_LUI: begin
            RegWrite = 1; ALUSrc = 1; ALUOp = `ALUOP_LUI;
        end
        `OPC_AUIPC: begin
            RegWrite = 1; ALUSrc = 1; ALUOp = `ALUOP_AUIPC;
        end
        `OPC_JAL: begin
            RegWrite = 1; ALUSrc = 1; Jump = 1; MemtoReg = `WB_PC4;
        end
        `OPC_JALR: begin
            RegWrite = 1; ALUSrc = 1; Jump = 1; MemtoReg = `WB_PC4;
            if (funct3 != 3'b000) illegal = 1;
        end
        `OPC_FENCE: begin // FENCE = NOP: single hart, in-order
            if (funct3 != 3'b000) illegal = 1;   // FENCE.I (Zifencei) not implemented
        end
        `OPC_SYSTEM: begin
            if (funct3 == 3'b000) begin
                // exact encodings only, anything else is illegal
                if      (imm12 == 12'h000 && rs1 == 5'b0 && rd == 5'b0) ecall  = 1;
                else if (imm12 == 12'h001 && rs1 == 5'b0 && rd == 5'b0) ebreak = 1;
                else if (imm12 == 12'h302 && rs1 == 5'b0 && rd == 5'b0) mret   = 1;
                else if (imm12 == 12'h105 && rs1 == 5'b0 && rd == 5'b0) wfi    = 1;
                else illegal = 1;
            end else if (funct3[1:0] != 2'b00) begin
                // CSRRW/S/C (+I): rd gets the old CSR value, muxed into the
                // ALU-result slot at the end of S2 -> WB_ALU selects it
                RegWrite  = 1; MemtoReg = `WB_ALU;
                csr_instr = 1;
                csr_op    = funct3[1:0];
                csr_imm   = funct3[2];
            end else
                illegal = 1;   // funct3 = 100 is reserved
        end
        default: illegal = 1;  // unknown opcode (covers instr[1:0] != 11 too)
    endcase
end

endmodule
