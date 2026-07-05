module alu_top (
    input  [31:0] operand_a,        // rs1_data
    input  [31:0] operand_b_reg,    // rs2_data
    input  [31:0] operand_b_imm,    // imediat
    input         ALUSrc,           // 0=rs2, 1=imm
    input  [3:0]  ALUOp,             // cod op generic
    input  [2:0]  funct3,
    input  [6:0]  funct7,

    output [31:0] result,
    output        zero
);

// operand 2
wire [31:0] operand_b = ALUSrc ? operand_b_imm : operand_b_reg;

// alu_ctrl din ALUOp + funct3/funct7
reg [3:0] alu_ctrl;

always @(*) begin
    case (ALUOp)
        4'b0000: alu_ctrl = 4'b0000;   // ADD (load/store/JAL/JALR)
        4'b0001: alu_ctrl = 4'b0001;   // SUB (branch)
        4'b0011: alu_ctrl = 4'b1010;   // LUI
        4'b0100: alu_ctrl = 4'b1011;   // AUIPC
        4'b0010:                       // R sau I arit
            case (funct3)
                // SUB doar R-type; ADDI nu are SUB
                3'b000: alu_ctrl = (funct7 == 7'b0100000 && ~ALUSrc) ? 4'b0001 : 4'b0000;
                3'b111: alu_ctrl = 4'b0010;   // AND/ANDI
                3'b110: alu_ctrl = 4'b0011;   // OR/ORI
                3'b100: alu_ctrl = 4'b0100;   // XOR/XORI
                3'b001: alu_ctrl = 4'b0101;   // SLL/SLLI
                3'b101: alu_ctrl = (funct7 == 7'b0100000) ? 4'b0111 : 4'b0110; // SRA(I) / SRL(I)
                3'b010: alu_ctrl = 4'b1000;   // SLT/SLTI
                3'b011: alu_ctrl = 4'b1001;   // SLTU/SLTIU
                default: alu_ctrl = 4'b0000;
            endcase
        default: alu_ctrl = 4'b0000;
    endcase
end

alu alu_inst (
    .operand_a (operand_a),
    .operand_b (operand_b),
    .alu_ctrl  (alu_ctrl),
    .result    (result),
    .zero      (zero)
);

endmodule
