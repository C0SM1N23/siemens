`timescale 1ns/1ps

`include "defines.vh"

module alu_top (
    input  [31:0] operand_a_i,        // rs1_data
    input  [31:0] operand_b_reg_i,    // rs2_data
    input  [31:0] operand_b_imm_i,    // immediate
    input         ALUSrc_i,           // 0=rs2, 1=imm
    input  [3:0]  ALUOp_i,            // generic operation class from control.v
    input  [2:0]  funct3_i,
    input  [6:0]  funct7_i,

    output [31:0] result_o
);

// second operand: register or immediate
wire [31:0] operand_b = ALUSrc_i ? operand_b_imm_i : operand_b_reg_i;

// alu_ctrl is refined from ALUOp_i plus funct3_i/funct7_i
reg [3:0] alu_ctrl;

always @(*) begin
    case (ALUOp_i)
        `ALUOP_ADD:   alu_ctrl = `ALU_ADD;     // load/store/JAL/JALR
        `ALUOP_LUI:   alu_ctrl = `ALU_PASSB;
        `ALUOP_AUIPC: alu_ctrl = `ALU_ADD;     // PC+imm
        `ALUOP_FUNCT:                          // R-type or I-type arithmetic
            case (funct3_i)
                // SUB exists only for R-type; ADDI has no SUB form
                3'b000: alu_ctrl = (funct7_i == 7'b0100000 && ~ALUSrc_i) ? `ALU_SUB : `ALU_ADD;
                3'b111: alu_ctrl = `ALU_AND;
                3'b110: alu_ctrl = `ALU_OR;
                3'b100: alu_ctrl = `ALU_XOR;
                3'b001: alu_ctrl = `ALU_SLL;
                3'b101: alu_ctrl = (funct7_i == 7'b0100000) ? `ALU_SRA : `ALU_SRL;
                3'b010: alu_ctrl = `ALU_SLT;
                3'b011: alu_ctrl = `ALU_SLTU;
                default: alu_ctrl = `ALU_ADD;
            endcase
        default: alu_ctrl = `ALU_ADD;
    endcase
end

alu alu_inst (
    .operand_a_i (operand_a_i),
    .operand_b_i (operand_b),
    .alu_ctrl_i  (alu_ctrl),
    .result_o    (result_o)
);

endmodule
