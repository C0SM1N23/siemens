// RV32I control decoder.
// REQ# = spec requirement, D# = design decision; both indexed in the README.
//
// Spec requirement met here:
//   REQ7  RV32I control signals for every instruction group; FENCE decodes as
//     a NOP (single hart, in-order, no reordering store buffer, so no real
//     barrier is needed); ECALL/EBREAK/CSR are trap- or CSR-handled downstream.
//     SYSTEM is decoded strictly: ECALL / EBREAK / MRET plus CSR* including the
//     immediate forms; any other SYSTEM encoding is illegal.
//
// Illegal-instruction detection feeds decision D3 (the supported trap causes):
// unknown opcodes or bad funct fields set illegal=1 and leave every other
// control signal inactive, so an illegal op has no side effects — it becomes an
// illegal-instruction trap in S2.

module control (
    input      [6:0]  opcode,
    input      [2:0]  funct3,
    input      [6:0]  funct7,
    input      [4:0]  rs1,         // rs1/uimm field, checked in SYSTEM encodings
    input      [4:0]  rd,
    input      [11:0] imm12,       // instr[31:20], selects ECALL/EBREAK/MRET

    output reg        RegWrite,    // writes rd
    output reg        ALUSrc,      // 0=rs2, 1=imm
    output reg [3:0]  ALUOp,
    output reg        MemRead,
    output reg        MemWrite,
    output reg [1:0]  MemtoReg,    // 00=ALU, 01=mem, 10=PC+4, 11=CSR
    output reg        Branch,
    output reg        Jump,        // JAL/JALR
    output reg        csr_instr,   // CSR op (Zicsr)
    output reg [1:0]  csr_op,      // 01=RW, 10=RS, 11=RC
    output reg        csr_imm,     // immediate form, source = uimm5 from rs1 field
    output reg        mret,
    output reg        ecall,
    output reg        ebreak,
    output reg        illegal
);

always @(*) begin
    // default: nothing (safe bubble)
    RegWrite  = 0; ALUSrc = 0; ALUOp = 4'b0000;
    MemRead   = 0; MemWrite = 0; MemtoReg = 2'b00;
    Branch    = 0; Jump = 0;
    csr_instr = 0; csr_op = 2'b00; csr_imm = 0;
    mret      = 0; ecall = 0; ebreak = 0; illegal = 0;

    case (opcode)
        7'b0110011: begin // R-type
            RegWrite = 1; ALUOp = 4'b0010;
            // funct7=0100000 only exists for SUB and SRA
            if (funct7 == 7'b0100000) begin
                if (funct3 != 3'b000 && funct3 != 3'b101) illegal = 1;
            end else if (funct7 != 7'b0000000)
                illegal = 1;
        end
        7'b0010011: begin // I-type arithmetic
            RegWrite = 1; ALUSrc = 1; ALUOp = 4'b0010;
            // shifts carry shamt + a fixed funct7
            if (funct3 == 3'b001 && funct7 != 7'b0000000) illegal = 1;
            if (funct3 == 3'b101 && funct7 != 7'b0000000
                                 && funct7 != 7'b0100000) illegal = 1;
        end
        7'b0000011: begin // LB/LH/LW/LBU/LHU
            RegWrite = 1; ALUSrc = 1; MemRead = 1; MemtoReg = 2'b01;
            if (funct3 == 3'b011 || funct3[2:1] == 2'b11) illegal = 1;
        end
        7'b0100011: begin // SB/SH/SW
            ALUSrc = 1; MemWrite = 1;
            if (funct3[2] || funct3 == 3'b011) illegal = 1;
        end
        7'b1100011: begin // branches
            ALUOp = 4'b0001; Branch = 1;
            if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1;
        end
        7'b0110111: begin // LUI
            RegWrite = 1; ALUSrc = 1; ALUOp = 4'b0011;
        end
        7'b0010111: begin // AUIPC
            RegWrite = 1; ALUSrc = 1; ALUOp = 4'b0100;
        end
        7'b1101111: begin // JAL
            RegWrite = 1; ALUSrc = 1; Jump = 1; MemtoReg = 2'b10;
        end
        7'b1100111: begin // JALR
            RegWrite = 1; ALUSrc = 1; Jump = 1; MemtoReg = 2'b10;
            if (funct3 != 3'b000) illegal = 1;
        end
        7'b0001111: begin // FENCE = NOP: single hart, in-order
            if (funct3 != 3'b000) illegal = 1;   // FENCE.I (Zifencei) not implemented
        end
        7'b1110011: begin // SYSTEM
            if (funct3 == 3'b000) begin
                // exact encodings only, anything else is illegal
                if      (imm12 == 12'h000 && rs1 == 5'b0 && rd == 5'b0) ecall  = 1;
                else if (imm12 == 12'h001 && rs1 == 5'b0 && rd == 5'b0) ebreak = 1;
                else if (imm12 == 12'h302 && rs1 == 5'b0 && rd == 5'b0) mret   = 1;
                else illegal = 1;
            end else if (funct3[1:0] != 2'b00) begin
                // CSRRW/S/C (+I): rd gets the old CSR value
                RegWrite  = 1; MemtoReg = 2'b11;
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
