`include "defines.vh"

module branch_unit (
    input      [31:0] pc_in,
    input      [31:0] imm_out,
    input      [31:0] rs1_data,
    input      [31:0] rs2_data,
    input      [6:0]  opcode,           // JAL vs JALR
    input      [2:0]  funct3,           // tip branch
    input             Branch,
    input             Jump,

    output     [31:0] branch_target,
    output            pc_src            // 1 = PC ia branch_target
);

// JAL/branch: PC+imm. JALR: (rs1+imm) cu bit 0 = 0 (RV32I §2.5)
assign branch_target = (opcode == `OPC_JALR)
                       ? ((rs1_data + imm_out) & ~32'h1)
                       : (pc_in + imm_out);

wire eq  = (rs1_data == rs2_data);
wire lt  = ($signed(rs1_data) < $signed(rs2_data));
wire ltu = (rs1_data < rs2_data);

reg branch_taken;

always @(*) begin
    case (funct3)
        3'b000:  branch_taken = eq;      // BEQ
        3'b001:  branch_taken = ~eq;     // BNE
        3'b100:  branch_taken = lt;      // BLT
        3'b101:  branch_taken = ~lt;     // BGE
        3'b110:  branch_taken = ltu;     // BLTU
        3'b111:  branch_taken = ~ltu;    // BGEU
        default: branch_taken = 1'b0;
    endcase
end

assign pc_src = Jump | (Branch & branch_taken);

endmodule
