module imm_gen (
    input      [31:0] instr,
    output reg [31:0] imm_out
);

// imediat dupa tipul instructiunii (I/S/B/U/J)
always @(*) begin
    case (instr[6:0])
        // I-type
        7'b0000011,                                                   // loads
        7'b0010011,                                                   // ADDI/XORI/ORI/...
        7'b1100111:                                                   // JALR
            imm_out = {{20{instr[31]}}, instr[31:20]};

        // S-type (stores)
        7'b0100011:
            imm_out = {{20{instr[31]}}, instr[31:25], instr[11:7]};

        // B-type (branches)
        7'b1100011:
            imm_out = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

        // U-type (LUI / AUIPC)
        7'b0110111,
        7'b0010111:
            imm_out = {instr[31:12], 12'b0};

        // J-type (JAL)
        7'b1101111:
            imm_out = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

        default: imm_out = 32'b0;
    endcase
end

endmodule
