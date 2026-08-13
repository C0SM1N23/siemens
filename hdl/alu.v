`timescale 1ns/1ps

`include "defines.vh"

module alu (
    input      [31:0] operand_a,
    input      [31:0] operand_b,
    input      [3:0]  alu_ctrl,

    output reg [31:0] result
);

always @(*) begin
    case (alu_ctrl)
        `ALU_ADD:   result = operand_a + operand_b;
        `ALU_SUB:   result = operand_a - operand_b;
        `ALU_AND:   result = operand_a & operand_b;
        `ALU_OR:    result = operand_a | operand_b;
        `ALU_XOR:   result = operand_a ^ operand_b;
        `ALU_SLL:   result = operand_a << operand_b[4:0];
        `ALU_SRL:   result = operand_a >> operand_b[4:0];
        `ALU_SRA:   result = $signed(operand_a) >>> operand_b[4:0];
        `ALU_SLT:   result = ($signed(operand_a) < $signed(operand_b)) ? 32'b1 : 32'b0;
        `ALU_SLTU:  result = (operand_a < operand_b) ? 32'b1 : 32'b0;
        `ALU_PASSB: result = operand_b;                                 // LUI (pass imm)
        default:    result = 32'b0;
    endcase
end

endmodule
