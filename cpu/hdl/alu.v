`timescale 1ns/1ps

`include "defines.vh"

module alu (
    input      [31:0] operand_a_i,
    input      [31:0] operand_b_i,
    input      [3:0]  alu_ctrl_i,

    output reg [31:0] result_o
);

always @(*) begin
    case (alu_ctrl_i)
        `ALU_ADD:   result_o = operand_a_i + operand_b_i;
        `ALU_SUB:   result_o = operand_a_i - operand_b_i;
        `ALU_AND:   result_o = operand_a_i & operand_b_i;
        `ALU_OR:    result_o = operand_a_i | operand_b_i;
        `ALU_XOR:   result_o = operand_a_i ^ operand_b_i;
        `ALU_SLL:   result_o = operand_a_i << operand_b_i[4:0];
        `ALU_SRL:   result_o = operand_a_i >> operand_b_i[4:0];
        `ALU_SRA:   result_o = $signed(operand_a_i) >>> operand_b_i[4:0];
        `ALU_SLT:   result_o = ($signed(operand_a_i) < $signed(operand_b_i)) ? 32'b1 : 32'b0;
        `ALU_SLTU:  result_o = (operand_a_i < operand_b_i) ? 32'b1 : 32'b0;
        `ALU_PASSB: result_o = operand_b_i;                                 // LUI (pass imm)
        default:    result_o = 32'b0;
    endcase
end

endmodule
