`timescale 1ns/1ps

`include "defines.vh"

module imm_gen (
    input      [31:0] instr_i,
    output reg [31:0] imm_out_o
);

// immediate assembled according to the instruction format (I/S/B/U/J)
always @(*) begin
    case (instr_i[6:0])
        // I-type
        `OPC_LOAD,
        `OPC_OP_IMM,
        `OPC_JALR:
            imm_out_o = {{20{instr_i[31]}}, instr_i[31:20]};

        // S-type (stores)
        `OPC_STORE:
            imm_out_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};

        // B-type (branches)
        `OPC_BRANCH:
            imm_out_o = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};

        // U-type (LUI / AUIPC)
        `OPC_LUI,
        `OPC_AUIPC:
            imm_out_o = {instr_i[31:12], 12'b0};

        // J-type (JAL)
        `OPC_JAL:
            imm_out_o = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};

        default: imm_out_o = 32'b0;
    endcase
end

endmodule
