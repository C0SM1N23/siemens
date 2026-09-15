// RV32I control decoder: instruction class, data path selects and legality.
// FENCE is a no-op because accesses are ordered; FENCE.I is unsupported.
// SYSTEM accepts the six CSR forms and exact ECALL, EBREAK, MRET and WFI encodings.

`include "rv32i_defines.vh"

module rv32i_control (
    input [ 6:0] opcode_i,
    input [ 2:0] funct3_i,
    input [ 6:0] funct7_i,
    input [ 4:0] rs1_i,     // rs1_i/uimm field, checked in SYSTEM encodings
    input [ 4:0] rd_i,
    input [11:0] imm12_i,   // instr[31:20], selects ECALL/EBREAK/MRET/WFI

    output reg       RegWrite_o,   // the instruction writes its rd register
    output reg       ALUSrc_o,     // 0=rs2, 1=imm
    output reg [3:0] ALUOp_o,
    output           MemRead_o,
    output           MemWrite_o,
    output reg [1:0] MemtoReg_o,   // WB_* select (CSR reads ride the WB_ALU slot)
    output           Branch_o,
    output           Jump_o,       // JAL/JALR
    output           csr_instr_o,  // CSR op (Zicsr)
    output     [1:0] csr_op_o,     // 01=RW, 10=RS, 11=RC
    output           csr_imm_o,    // immediate form, source = uimm5 from rs1_i field
    output           mret_o,
    output           ecall_o,
    output           ebreak_o,
    output           wfi_o,        // sleep until interrupt (D23)
    output reg       illegal_o
);

    // Datapath enables. Illegal instructions are suppressed by CPU trap control.
    always @(*) begin
        case (opcode_i)
            `OPC_OP, `OPC_OP_IMM, `OPC_LOAD, `OPC_LUI, `OPC_AUIPC, `OPC_JAL, `OPC_JALR:
            RegWrite_o = 1'b1;
            `OPC_SYSTEM: RegWrite_o = (funct3_i[1:0] != 2'b00);
            default: RegWrite_o = 1'b0;
        endcase
    end

    always @(*) begin
        case (opcode_i)
            `OPC_OP_IMM, `OPC_LOAD, `OPC_STORE, `OPC_LUI, `OPC_AUIPC, `OPC_JAL, `OPC_JALR:
            ALUSrc_o = 1'b1;
            default: ALUSrc_o = 1'b0;
        endcase
    end

    always @(*) begin
        case (opcode_i)
            `OPC_OP, `OPC_OP_IMM: ALUOp_o = `ALUOP_FUNCT;
            `OPC_LUI:             ALUOp_o = `ALUOP_LUI;
            `OPC_AUIPC:           ALUOp_o = `ALUOP_AUIPC;
            default:              ALUOp_o = `ALUOP_ADD;
        endcase
    end

    always @(*) begin
        case (opcode_i)
            `OPC_LOAD:           MemtoReg_o = `WB_MEM;
            `OPC_JAL, `OPC_JALR: MemtoReg_o = `WB_PC4;
            default:             MemtoReg_o = `WB_ALU;
        endcase
    end

    assign MemRead_o  = (opcode_i == `OPC_LOAD);
    assign MemWrite_o = (opcode_i == `OPC_STORE);
    assign Branch_o   = (opcode_i == `OPC_BRANCH);
    assign Jump_o     = (opcode_i == `OPC_JAL || opcode_i == `OPC_JALR);

    // SYSTEM: exact privileged encodings and the six Zicsr instructions.
    wire system_op = (opcode_i == `OPC_SYSTEM);
    wire system_fixed = system_op && funct3_i == 0 && rs1_i == 0 && rd_i == 0;
    assign csr_instr_o = system_op && funct3_i[1:0] != 0;
    assign csr_op_o    = csr_instr_o ? funct3_i[1:0] : 2'b00;
    assign csr_imm_o   = csr_instr_o && funct3_i[2];
    assign ecall_o     = system_fixed && imm12_i == 12'h000;
    assign ebreak_o    = system_fixed && imm12_i == 12'h001;
    assign mret_o      = system_fixed && imm12_i == 12'h302;
    assign wfi_o       = system_fixed && imm12_i == 12'h105;

    // Encoding legality. FENCE.I and multiply/divide are not implemented.
    always @(*) begin
        illegal_o = 1'b0;
        case (opcode_i)
            `OPC_OP:
            if (funct7_i == 7'b0100000) illegal_o = funct3_i != 3'b000 && funct3_i != 3'b101;
            else illegal_o = funct7_i != 7'b0000000;
            `OPC_OP_IMM:
            case (funct3_i)
                3'b001:  illegal_o = funct7_i != 7'b0000000;
                3'b101:  illegal_o = funct7_i != 7'b0000000 && funct7_i != 7'b0100000;
                default: illegal_o = 1'b0;
            endcase
            `OPC_LOAD: illegal_o = funct3_i == 3'b011 || funct3_i[2:1] == 2'b11;
            `OPC_STORE: illegal_o = funct3_i[2] || funct3_i == 3'b011;
            `OPC_BRANCH: illegal_o = funct3_i == 3'b010 || funct3_i == 3'b011;
            `OPC_JALR, `OPC_FENCE: illegal_o = funct3_i != 0;
            `OPC_SYSTEM: illegal_o = !(csr_instr_o || ecall_o || ebreak_o || mret_o || wfi_o);
            `OPC_LUI, `OPC_AUIPC, `OPC_JAL: illegal_o = 1'b0;
            default: illegal_o = 1'b1;
        endcase
    end
endmodule
