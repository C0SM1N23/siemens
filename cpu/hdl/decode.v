`timescale 1ns/1ps

module decode (
    input  [31:0] instr_i,
    output [6:0]  opcode_o,
    output [4:0]  rd_o,
    output [2:0]  funct3_o,
    output [4:0]  rs1_o,
    output [4:0]  rs2_o,
    output [6:0]  funct7_o
);

// RV32I instruction fields
assign opcode_o = instr_i[6:0];
assign rd_o     = instr_i[11:7];
assign funct3_o = instr_i[14:12];
assign rs1_o    = instr_i[19:15];
assign rs2_o    = instr_i[24:20];
assign funct7_o = instr_i[31:25];

endmodule
