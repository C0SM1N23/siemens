`timescale 1ns/1ps

`include "defines.vh"

module branch_unit (
    input      [31:0] pc_in_i,
    input      [31:0] imm_out_i,
    input      [31:0] rs1_data_i,
    input      [31:0] rs2_data_i,
    input      [6:0]  opcode_i,           // JAL vs JALR
    input      [2:0]  funct3_i,           // branch condition
    input             Branch_i,
    input             Jump_i,

    output     [31:0] branch_target_o,
    output            pc_src_o            // 1 = PC takes branch_target_o
);

// JAL/branch: PC+imm. JALR: (rs1+imm) with bit 0 forced to 0 (RV32I §2.5)
assign branch_target_o = (opcode_i == `OPC_JALR)
                       ? ((rs1_data_i + imm_out_i) & ~32'h1)
                       : (pc_in_i + imm_out_i);

wire eq  = (rs1_data_i == rs2_data_i);
wire lt  = ($signed(rs1_data_i) < $signed(rs2_data_i));
wire ltu = (rs1_data_i < rs2_data_i);

reg branch_taken;

always @(*) begin
    case (funct3_i)
        3'b000:  branch_taken = eq;      // BEQ
        3'b001:  branch_taken = ~eq;     // BNE
        3'b100:  branch_taken = lt;      // BLT
        3'b101:  branch_taken = ~lt;     // BGE
        3'b110:  branch_taken = ltu;     // BLTU
        3'b111:  branch_taken = ~ltu;    // BGEU
        default: branch_taken = 1'b0;
    endcase
end

assign pc_src_o = Jump_i | (Branch_i & branch_taken);

endmodule
