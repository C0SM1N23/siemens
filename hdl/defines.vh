// Shared encodings — one name per bit pattern, so a value produced in one
// file and tested in another (control -> cpu_top, decode -> imm_gen) reads
// the same everywhere. Values only; no behavior lives here.
`ifndef CPU_DEFINES_VH
`define CPU_DEFINES_VH

// RV32I major opcodes (instr[6:0])
`define OPC_LUI     7'b0110111
`define OPC_AUIPC   7'b0010111
`define OPC_JAL     7'b1101111
`define OPC_JALR    7'b1100111
`define OPC_BRANCH  7'b1100011
`define OPC_LOAD    7'b0000011
`define OPC_STORE   7'b0100011
`define OPC_OP_IMM  7'b0010011
`define OPC_OP      7'b0110011
`define OPC_FENCE   7'b0001111
`define OPC_SYSTEM  7'b1110011

// ALUOp (control -> alu_top): what the ALU should compute this cycle
`define ALUOP_ADD    4'b0000   // address/link arithmetic (loads/stores/jumps)
`define ALUOP_FUNCT  4'b0010   // R/I arithmetic, exact op from funct3/funct7
`define ALUOP_LUI    4'b0011   // pass the immediate through
`define ALUOP_AUIPC  4'b0100   // PC + immediate (operand A is the PC)

// alu_ctrl (alu_top -> alu): the concrete operation
`define ALU_ADD    4'b0000
`define ALU_SUB    4'b0001
`define ALU_AND    4'b0010
`define ALU_OR     4'b0011
`define ALU_XOR    4'b0100
`define ALU_SLL    4'b0101
`define ALU_SRL    4'b0110
`define ALU_SRA    4'b0111
`define ALU_SLT    4'b1000
`define ALU_SLTU   4'b1001
`define ALU_PASSB  4'b1010

// MemtoReg (control -> writeback_mux): what lands in rd. The CSR read value
// is muxed into the ALU-result slot at the end of S2, so it selects WB_ALU.
`define WB_ALU  2'b00
`define WB_MEM  2'b01
`define WB_PC4  2'b10

// csr_op (funct3[1:0] of the CSR instruction forms)
`define CSROP_RW  2'b01
`define CSROP_RS  2'b10
`define CSROP_RC  2'b11

// synchronous mcause codes (D3); external interrupts are 16 + PIC channel
`define CAUSE_IMISALIGN   5'd0
`define CAUSE_IFAULT      5'd1
`define CAUSE_ILLEGAL     5'd2
`define CAUSE_BREAK       5'd3
`define CAUSE_LD_MISALIGN 5'd4
`define CAUSE_LD_FAULT    5'd5
`define CAUSE_ST_MISALIGN 5'd6
`define CAUSE_ST_FAULT    5'd7
`define CAUSE_ECALL_M     5'd11

`endif
