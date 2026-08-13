`timescale 1ns/1ps

`include "defines.vh"

module alu_top (
    input  [31:0] operand_a,        // rs1_data
    input  [31:0] operand_b_reg,    // rs2_data
    input  [31:0] operand_b_imm,    // imediat
    input         ALUSrc,           // 0=rs2, 1=imm
    input  [3:0]  ALUOp,             // cod op generic
    input  [2:0]  funct3,
    input  [6:0]  funct7,

    output [31:0] result
);

// operand 2
wire [31:0] operand_b = ALUSrc ? operand_b_imm : operand_b_reg;

// alu_ctrl din ALUOp + funct3/funct7
reg [3:0] alu_ctrl;

always @(*) begin
    case (ALUOp)
        `ALUOP_ADD:   alu_ctrl = `ALU_ADD;     // load/store/JAL/JALR
        `ALUOP_LUI:   alu_ctrl = `ALU_PASSB;
        `ALUOP_AUIPC: alu_ctrl = `ALU_ADD;     // PC+imm
        `ALUOP_FUNCT:                          // R sau I arit
            case (funct3)
                // SUB doar R-type; ADDI nu are SUB
                3'b000: alu_ctrl = (funct7 == 7'b0100000 && ~ALUSrc) ? `ALU_SUB : `ALU_ADD;
                3'b111: alu_ctrl = `ALU_AND;
                3'b110: alu_ctrl = `ALU_OR;
                3'b100: alu_ctrl = `ALU_XOR;
                3'b001: alu_ctrl = `ALU_SLL;
                3'b101: alu_ctrl = (funct7 == 7'b0100000) ? `ALU_SRA : `ALU_SRL;
                3'b010: alu_ctrl = `ALU_SLT;
                3'b011: alu_ctrl = `ALU_SLTU;
                default: alu_ctrl = `ALU_ADD;
            endcase
        default: alu_ctrl = `ALU_ADD;
    endcase
end

alu alu_inst (
    .operand_a (operand_a),
    .operand_b (operand_b),
    .alu_ctrl  (alu_ctrl),
    .result    (result)
);

endmodule
