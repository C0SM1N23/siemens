// ===========================================================================
// tb_alu - block-level verification of the arithmetic path
//          (hdl/alu_top.v + hdl/alu.v)
// ===========================================================================
//
// OBJECTIVE
//   The system bench proves that each instruction class executes and that the
//   program's expected results appear in the register file. It does not prove
//   that each ALU operation is correct at the values where arithmetic goes
//   wrong: the sign boundary, the shift-amount boundary, and the pairs that
//   separate a signed comparison from an unsigned one. Those operands do not
//   occur in a hand-written directed program, and the functional-coverage
//   layer bins instruction classes, not operand values.
//
//   This bench drives alu_top directly, so it covers both halves of the path
//   in one place: the decode from {ALUOp, funct3, funct7, ALUSrc} to the
//   concrete operation, and the operation itself.
//
// SCOPE
//   1  operand select: ALUSrc_i picks the register or the immediate
//   2  the ALUOp decode, exhaustive over the encodings RV32I can produce:
//      every funct3 with both funct7 values and both ALUSrc values under
//      ALUOP_FUNCT (32 combinations), plus ALUOP_ADD, ALUOP_LUI, ALUOP_AUIPC
//      and an unused ALUOp, which must fall back to ADD
//   3  ADD and SUB at the sign boundary, including wraparound
//   4  SLL, SRL and SRA over every shift amount 0..31 (exhaustive), plus the
//      [4:0] masking of a shift amount above 31
//   5  SLT and SLTU on the pairs that distinguish them, in both directions
//   6  AND, OR and XOR over a full 4x4 matrix of boundary patterns
//   7  LUI's pass-through and AUIPC's addition
//
// WHAT IS AND IS NOT EXHAUSTIVE
//   Exhaustive: the ALUOp/funct3/funct7/ALUSrc decode space that alu_top can
//   see (36 cases), every shift amount for all three shift operations (96
//   cases), and the boundary-pattern matrix for the three bitwise operations
//   (48 cases). Selected: the arithmetic and comparison operands, chosen as
//   boundary values - 0, 1, -1, INT_MIN (0x8000_0000), INT_MAX
//   (0x7FFF_FFFF) - plus one arbitrary pattern pair. The 2^64 operand space
//   is not swept and no random stimulus is used; this is directed
//   boundary-value testing, not exhaustive verification of the datapath.
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow.
// ===========================================================================

`timescale 1ns/1ps

`include "defines.vh"

module tb_alu;

// ---- boundary patterns used throughout ----
localparam [31:0] ZERO   = 32'h0000_0000;
localparam [31:0] ONE    = 32'h0000_0001;
localparam [31:0] MINUS1 = 32'hFFFF_FFFF;
localparam [31:0] INTMIN = 32'h8000_0000;
localparam [31:0] INTMAX = 32'h7FFF_FFFF;
localparam [31:0] PAT_A  = 32'hAAAA_AAAA;
localparam [31:0] PAT_5  = 32'h5555_5555;

localparam [6:0] F7_0 = 7'b0000000;   // the "normal" funct7
localparam [6:0] F7_1 = 7'b0100000;   // the SUB / SRA variant

// ---- DUT ports ----
reg  [31:0] opa, opb_reg, opb_imm;
reg         alusrc;
reg  [3:0]  aluop;
reg  [2:0]  funct3;
reg  [6:0]  funct7;
wire [31:0] result;

integer errors = 0;
integer i, k;
reg [31:0] expect_v;
reg [31:0] pa, pb;
`include "tb_check.vh"

alu_top dut (
    .operand_a_i     (opa),
    .operand_b_reg_i (opb_reg),
    .operand_b_imm_i (opb_imm),
    .ALUSrc_i        (alusrc),
    .ALUOp_i         (aluop),
    .funct3_i        (funct3),
    .funct7_i        (funct7),
    .result_o        (result)
);

// One evaluation of the combinational block: drive the whole input set, let
// it settle, compare. Operand B is supplied on the register port and ALUSrc
// is left at 0 unless a case is specifically about the operand mux.
task eval(input [3:0] op, input [2:0] f3, input [6:0] f7,
          input [31:0] a, input [31:0] b,
          input [31:0] expected, input [511:0] name);
    begin
        aluop   = op;
        funct3  = f3;
        funct7  = f7;
        opa     = a;
        opb_reg = b;
        opb_imm = 32'hDEAD_BEEF;   // must not be selected while ALUSrc is 0
        alusrc  = 1'b0;
        #1;
        check(expected, result, name);
    end
endtask

// the same, quietly: used inside the exhaustive loops, where one PASS line
// per iteration would bury the log. A mismatch still prints and counts.
task eval_q(input [3:0] op, input [2:0] f3, input [6:0] f7,
            input [31:0] a, input [31:0] b,
            input [31:0] expected, input [511:0] name);
    begin
        aluop   = op;
        funct3  = f3;
        funct7  = f7;
        opa     = a;
        opb_reg = b;
        opb_imm = 32'hDEAD_BEEF;
        alusrc  = 1'b0;
        #1;
        if (expected !== result) begin
            $display("FAIL: %0s -> expected 0x%08h, got 0x%08h",
                     name, expected, result);
            errors = errors + 1;
        end
    end
endtask

initial begin
    opa = 0; opb_reg = 0; opb_imm = 0; alusrc = 0;
    aluop = `ALUOP_ADD; funct3 = 3'b000; funct7 = F7_0;

    $display("\n=== tb_alu: arithmetic path block verification ===");

    // ================================================================
    $display("\n[1] operand select: ALUSrc_i chooses register or immediate");
    // ================================================================
    aluop = `ALUOP_ADD; funct3 = 3'b000; funct7 = F7_0;
    opa = 32'h0000_1000; opb_reg = 32'h0000_0020; opb_imm = 32'h0000_0300;

    alusrc = 1'b0; #1;
    check(32'h0000_1020, result, "  ALUSrc=0 takes the register operand");
    alusrc = 1'b1; #1;
    check(32'h0000_1300, result, "  ALUSrc=1 takes the immediate");
    alusrc = 1'b0;

    // ================================================================
    $display("\n[2] the ALUOp decode, exhaustive over what RV32I can present");
    // ================================================================
    // Operands chosen so that every operation produces a different answer:
    // A = 0x0000_0011, B = 0x0000_0003. ADD=0x14 SUB=0x0E AND=0x01 OR=0x13
    // XOR=0x12 SLL=0x88 SRL=0x02 SRA=0x02 SLT=0 SLTU=0.
    pa = 32'h0000_0011;
    pb = 32'h0000_0003;

    // ALUOP_FUNCT with ALUSrc = 0 (R-type): funct7 selects SUB and SRA
    eval(`ALUOP_FUNCT, 3'b000, F7_0, pa, pb, 32'h0000_0014, "  R-type f3=000 f7=0 -> ADD");
    eval(`ALUOP_FUNCT, 3'b000, F7_1, pa, pb, 32'h0000_000E, "  R-type f3=000 f7=1 -> SUB");
    eval(`ALUOP_FUNCT, 3'b001, F7_0, pa, pb, 32'h0000_0088, "  R-type f3=001 f7=0 -> SLL");
    eval(`ALUOP_FUNCT, 3'b001, F7_1, pa, pb, 32'h0000_0088, "  R-type f3=001 f7=1 -> SLL");
    eval(`ALUOP_FUNCT, 3'b010, F7_0, pa, pb, 32'h0000_0000, "  R-type f3=010 f7=0 -> SLT");
    eval(`ALUOP_FUNCT, 3'b010, F7_1, pa, pb, 32'h0000_0000, "  R-type f3=010 f7=1 -> SLT");
    eval(`ALUOP_FUNCT, 3'b011, F7_0, pa, pb, 32'h0000_0000, "  R-type f3=011 f7=0 -> SLTU");
    eval(`ALUOP_FUNCT, 3'b011, F7_1, pa, pb, 32'h0000_0000, "  R-type f3=011 f7=1 -> SLTU");
    eval(`ALUOP_FUNCT, 3'b100, F7_0, pa, pb, 32'h0000_0012, "  R-type f3=100 f7=0 -> XOR");
    eval(`ALUOP_FUNCT, 3'b100, F7_1, pa, pb, 32'h0000_0012, "  R-type f3=100 f7=1 -> XOR");
    eval(`ALUOP_FUNCT, 3'b101, F7_0, pa, pb, 32'h0000_0002, "  R-type f3=101 f7=0 -> SRL");
    eval(`ALUOP_FUNCT, 3'b101, F7_1, pa, pb, 32'h0000_0002, "  R-type f3=101 f7=1 -> SRA");
    eval(`ALUOP_FUNCT, 3'b110, F7_0, pa, pb, 32'h0000_0013, "  R-type f3=110 f7=0 -> OR");
    eval(`ALUOP_FUNCT, 3'b110, F7_1, pa, pb, 32'h0000_0013, "  R-type f3=110 f7=1 -> OR");
    eval(`ALUOP_FUNCT, 3'b111, F7_0, pa, pb, 32'h0000_0001, "  R-type f3=111 f7=0 -> AND");
    eval(`ALUOP_FUNCT, 3'b111, F7_1, pa, pb, 32'h0000_0001, "  R-type f3=111 f7=1 -> AND");

    // ALUOP_FUNCT with ALUSrc = 1 (I-type). The one asymmetry in the whole
    // decode lives here: ADDI has no SUB form, so funct7 = 0100000 with
    // funct3 = 000 must still be an addition. Bits [31:25] of an I-type are
    // part of the immediate, so they can legitimately hold that pattern.
    for (i = 0; i < 8; i = i + 1) begin
        for (k = 0; k < 2; k = k + 1) begin
            aluop   = `ALUOP_FUNCT;
            funct3  = i[2:0];
            funct7  = k ? F7_1 : F7_0;
            opa     = pa;
            opb_reg = 32'hDEAD_BEEF;   // must not be selected
            opb_imm = pb;
            alusrc  = 1'b1;
            #1;
            case (i[2:0])
                3'b000: expect_v = 32'h0000_0014;                        // always ADD
                3'b001: expect_v = 32'h0000_0088;
                3'b010: expect_v = 32'h0000_0000;
                3'b011: expect_v = 32'h0000_0000;
                3'b100: expect_v = 32'h0000_0012;
                3'b101: expect_v = 32'h0000_0002;
                3'b110: expect_v = 32'h0000_0013;
                default: expect_v = 32'h0000_0001;
            endcase
            if (expect_v !== result) begin
                $display("FAIL:   I-type f3=%03b f7=%b -> expected 0x%08h, got 0x%08h",
                         i[2:0], funct7, expect_v, result);
                errors = errors + 1;
            end
        end
    end
    alusrc = 1'b0;
    $display("PASS:   all 16 I-type funct3/funct7 combinations decode correctly");
    eval(`ALUOP_FUNCT, 3'b000, F7_1, pa, pb, 32'h0000_000E,
         "  and the R-type SUB is still a SUB (the asymmetry is real)");

    // the three non-FUNCT ALUOp values, plus one that control.v never emits
    eval(`ALUOP_ADD,   3'b111, F7_1, pa, pb, 32'h0000_0014,
         "  ALUOP_ADD ignores funct3/funct7 (address arithmetic)");
    eval(`ALUOP_LUI,   3'b111, F7_1, pa, pb, 32'h0000_0003,
         "  ALUOP_LUI passes operand B through");
    eval(`ALUOP_AUIPC, 3'b111, F7_1, pa, pb, 32'h0000_0014,
         "  ALUOP_AUIPC adds (operand A is the PC)");
    eval(4'b1111,      3'b111, F7_1, pa, pb, 32'h0000_0014,
         "  an unused ALUOp falls back to ADD, not to X");

    // ================================================================
    $display("\n[3] ADD and SUB at the sign boundary");
    // ================================================================
    eval(`ALUOP_FUNCT, 3'b000, F7_0, ZERO,   ZERO,   ZERO,
         "  0 + 0");
    eval(`ALUOP_FUNCT, 3'b000, F7_0, INTMAX, ONE,    INTMIN,
         "  INT_MAX + 1 wraps to INT_MIN");
    eval(`ALUOP_FUNCT, 3'b000, F7_0, MINUS1, ONE,    ZERO,
         "  -1 + 1 = 0, carry out discarded");
    eval(`ALUOP_FUNCT, 3'b000, F7_0, MINUS1, MINUS1, 32'hFFFF_FFFE,
         "  -1 + -1 = -2");
    eval(`ALUOP_FUNCT, 3'b000, F7_0, INTMIN, INTMIN, ZERO,
         "  INT_MIN + INT_MIN = 0");

    eval(`ALUOP_FUNCT, 3'b000, F7_1, ZERO,   ONE,    MINUS1,
         "  0 - 1 borrows to -1");
    eval(`ALUOP_FUNCT, 3'b000, F7_1, INTMIN, ONE,    INTMAX,
         "  INT_MIN - 1 wraps to INT_MAX");
    eval(`ALUOP_FUNCT, 3'b000, F7_1, PAT_A,  PAT_A,  ZERO,
         "  x - x = 0");
    eval(`ALUOP_FUNCT, 3'b000, F7_1, ZERO,   INTMIN, INTMIN,
         "  0 - INT_MIN is INT_MIN (it has no positive counterpart)");

    // ================================================================
    $display("\n[4] shifts: every amount 0..31, then the [4:0] masking");
    // ================================================================
    // exhaustive over the shift amount for all three operations. The pattern
    // has both halves set so a lost or duplicated bit is visible.
    for (i = 0; i < 32; i = i + 1)
        eval_q(`ALUOP_FUNCT, 3'b001, F7_0, PAT_A, i,
               PAT_A << i, "SLL");
    $display("PASS:   SLL correct for all 32 shift amounts");

    for (i = 0; i < 32; i = i + 1)
        eval_q(`ALUOP_FUNCT, 3'b101, F7_0, PAT_A, i,
               PAT_A >> i, "SRL");
    $display("PASS:   SRL correct for all 32 shift amounts (zero fill)");

    for (i = 0; i < 32; i = i + 1)
        eval_q(`ALUOP_FUNCT, 3'b101, F7_1, PAT_A, i,
               $signed(PAT_A) >>> i, "SRA");
    $display("PASS:   SRA correct for all 32 shift amounts (sign fill)");

    // SRA differs from SRL only when the operand is negative, and the two
    // must agree when it is positive - the check that the sign is really
    // being propagated rather than a constant 1 being shifted in
    eval(`ALUOP_FUNCT, 3'b101, F7_1, INTMIN, 32'd31, MINUS1,
         "  SRA of INT_MIN by 31 is all ones");
    eval(`ALUOP_FUNCT, 3'b101, F7_0, INTMIN, 32'd31, ONE,
         "  SRL of the same value by 31 is 1");
    eval(`ALUOP_FUNCT, 3'b101, F7_1, INTMAX, 32'd31, ZERO,
         "  SRA of a positive value by 31 is 0");

    // only the low five bits of operand B are a shift amount
    eval(`ALUOP_FUNCT, 3'b001, F7_0, ONE, 32'h0000_0020, ONE,
         "  SLL by 32 masks to a shift of 0");
    eval(`ALUOP_FUNCT, 3'b001, F7_0, ONE, 32'h0000_0021, 32'h0000_0002,
         "  SLL by 33 masks to a shift of 1");
    eval(`ALUOP_FUNCT, 3'b101, F7_0, INTMIN, 32'hFFFF_FFE0, INTMIN,
         "  SRL by 0xFFFFFFE0 masks to a shift of 0");

    // ================================================================
    $display("\n[5] SLT and SLTU: the pairs that separate them");
    // ================================================================
    eval(`ALUOP_FUNCT, 3'b010, F7_0, MINUS1, ONE,    ONE,
         "  SLT:  -1 < 1 is true");
    eval(`ALUOP_FUNCT, 3'b011, F7_0, MINUS1, ONE,    ZERO,
         "  SLTU: 0xFFFFFFFF < 1 is false");
    eval(`ALUOP_FUNCT, 3'b010, F7_0, ONE,    MINUS1, ZERO,
         "  SLT:  1 < -1 is false");
    eval(`ALUOP_FUNCT, 3'b011, F7_0, ONE,    MINUS1, ONE,
         "  SLTU: 1 < 0xFFFFFFFF is true");
    eval(`ALUOP_FUNCT, 3'b010, F7_0, INTMIN, INTMAX, ONE,
         "  SLT:  INT_MIN < INT_MAX is true");
    eval(`ALUOP_FUNCT, 3'b011, F7_0, INTMIN, INTMAX, ZERO,
         "  SLTU: the same words compare the other way unsigned");
    eval(`ALUOP_FUNCT, 3'b010, F7_0, PAT_A,  PAT_A,  ZERO,
         "  SLT:  equal operands are not less than");
    eval(`ALUOP_FUNCT, 3'b011, F7_0, PAT_A,  PAT_A,  ZERO,
         "  SLTU: equal operands are not less than");
    eval(`ALUOP_FUNCT, 3'b010, F7_0, ZERO,   ZERO,   ZERO,
         "  SLT:  0 < 0 is false");
    eval(`ALUOP_FUNCT, 3'b011, F7_0, ZERO,   ONE,    ONE,
         "  SLTU: 0 < 1 is true");

    // ================================================================
    $display("\n[6] AND, OR, XOR over the boundary-pattern matrix");
    // ================================================================
    // 4 x 4 patterns x 3 operations; the identities (x & 0 = 0, x | -1 = -1,
    // x ^ x = 0) are all inside this matrix
    for (i = 0; i < 4; i = i + 1) begin
        case (i)
            0: pa = ZERO;
            1: pa = MINUS1;
            2: pa = PAT_A;
            default: pa = PAT_5;
        endcase
        for (k = 0; k < 4; k = k + 1) begin
            case (k)
                0: pb = ZERO;
                1: pb = MINUS1;
                2: pb = PAT_A;
                default: pb = PAT_5;
            endcase
            eval_q(`ALUOP_FUNCT, 3'b111, F7_0, pa, pb, pa & pb, "AND");
            eval_q(`ALUOP_FUNCT, 3'b110, F7_0, pa, pb, pa | pb, "OR");
            eval_q(`ALUOP_FUNCT, 3'b100, F7_0, pa, pb, pa ^ pb, "XOR");
        end
    end
    $display("PASS:   AND/OR/XOR correct over all 16 boundary-pattern pairs");

    // ================================================================
    $display("\n[7] LUI and AUIPC");
    // ================================================================
    eval(`ALUOP_LUI,   3'b000, F7_0, 32'hFFFF_FFFF, 32'h1234_5000, 32'h1234_5000,
         "  LUI passes B through and ignores A entirely");
    eval(`ALUOP_LUI,   3'b000, F7_0, ZERO,          ZERO,          ZERO,
         "  LUI of zero");
    eval(`ALUOP_AUIPC, 3'b000, F7_0, 32'h0000_1000, 32'h0002_0000, 32'h0002_1000,
         "  AUIPC adds the immediate to the PC");
    eval(`ALUOP_AUIPC, 3'b000, F7_0, 32'h0000_0004, 32'hFFFF_F000, 32'hFFFF_F004,
         "  AUIPC with a negative immediate");

    // ---- done ----
    #10;
    $display("\n========================================");
    if (errors == 0)
        $display("== ALU TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== ALU TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

endmodule
