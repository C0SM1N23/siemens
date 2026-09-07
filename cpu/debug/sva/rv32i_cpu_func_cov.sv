// Functional coverage — bound into cpu_top, verification only.
//
// Turns the manual coverage argument in VERIFICATION.md into measured bins:
// every scenario the test plan claims gets a counter, sampled the cycle it
// happens (at the S2 boundary or on a bus handshake). At end of run a [FCOV]
// table prints each bin's count + hit/MISS verdict and a summary percentage —
// a MISS is a test-plan hole, not a failure.
//
// Sampling points:
// - commit     = a real instruction leaves S2 (s2_advance_i && ifdx_valid && !trap_take_i)
// - trap entry = trap_take_i && s2_advance_i, binned by mcause
// - resolution = predictor outcome at a committed branch_i/jump_i
// - bus beats  = response handshakes on ibus/dbus, binned by RRESP/BRESP
//
// Plain counters (portable to Verilator, Questa, even ModelSim ASE minus the
// SVA files). Bound from bind_sva.sv — no RTL is touched.

`timescale 1ns/1ps

module cpu_func_cov (
    input        clk_i,
    input        rst_n_i,

    // S2 instruction + control (cpu_top internals, wired up by the bind)
    input        valid_i,          // ifdx_valid_q
    input [31:0] instr_i,          // ifdx_instr_q
    input        pred_taken_i,     // ifdx_ptk_q
    input        s2_advance_i,
    input        trap_take_i,
    input [4:0]  trap_code_i,
    input        irq_take_i,
    input        mispredict_i,
    input        branch_i,
    input        jump_i,
    input        ctl_taken_i,
    input        csr_instr_i,
    input [1:0]  csr_op_i,
    input        csr_imm_i,
    input        csr_wen_i,
    input        mret_exec_i,
    input        fwd_rs1_i,
    input        fwd_rs2_i,
    input        lsu_active_i,
    input        ctrl_wfi_i,       // WFI in S2 (D23)
    input        wfi_wait_i,       // WFI sleeping this cycle
    input        ras_push_i,       // committed call (D24)
    input        ras_pop_i,        // committed return

    // PIC interface
    input        cpu_irq_i,
    input [3:0]  cpu_irq_vec_i,
    input        cpu_irq_ack_i,

    // bus response beats
    input        ib_arvalid_i,
    input        ib_arready_i,
    input        ib_rvalid_i,
    input        ib_rready_i,
    input [1:0]  ib_rresp_i,
    input        db_arvalid_i,
    input        db_arready_i,
    input        db_rvalid_i,
    input        db_rready_i,
    input [1:0]  db_rresp_i,
    input        db_bvalid_i,
    input        db_bready_i,
    input [1:0]  db_bresp_i
);

wire [6:0] opcode = instr_i[6:0];
wire [2:0] funct3 = instr_i[14:12];

wire commit  = s2_advance_i && valid_i && !trap_take_i;
wire ib_r_hs = ib_rvalid_i && ib_rready_i;
wire db_r_hs = db_rvalid_i && db_rready_i;
wire db_b_hs = db_bvalid_i && db_bready_i;

// instruction class index (RV32I major opcodes)
localparam C_LUI = 0, C_AUIPC = 1, C_JAL  = 2, C_JALR  = 3, C_BR  = 4,
           C_LD  = 5, C_ST    = 6, C_OPI  = 7, C_OP    = 8, C_FEN = 9,
           C_SYS = 10;

function integer cls_idx;
    input [6:0] op;
    case (op)
        7'b0110111: cls_idx = C_LUI;
        7'b0010111: cls_idx = C_AUIPC;
        7'b1101111: cls_idx = C_JAL;
        7'b1100111: cls_idx = C_JALR;
        7'b1100011: cls_idx = C_BR;
        7'b0000011: cls_idx = C_LD;
        7'b0100011: cls_idx = C_ST;
        7'b0010011: cls_idx = C_OPI;
        7'b0110011: cls_idx = C_OP;
        7'b0001111: cls_idx = C_FEN;
        7'b1110011: cls_idx = C_SYS;
        default:    cls_idx = -1;
    endcase
endfunction

// --- counters, grouped by sampling point ---

integer cls_cnt [0:10];       // committed instruction classes
integer ld_cnt  [0:7];        // load sizes (funct3: LB LH LW LBU LHU)
integer st_cnt  [0:7];        // store sizes (funct3: SB SH SW)
integer br_cnt  [0:7][0:1];   // branch_i funct3 x {not-taken, taken}
integer bp_cnt  [0:3];        // predictor {pred, actual} at resolution
integer bp_tgt_wrong;         // right direction, wrong BTB target
integer trap_cnt[0:31];       // trap entries by mcause code (16+ = irq)
integer csr_cnt [0:7];        // {imm, op}: CSRRW/S/C and immediate forms
integer csr_ro;               // CSRRS/C with rs1=x0: pure read, no write
integer fwd_cnt [0:2];        // forwarding: rs1 only / rs2 only / both
integer ev_mret, ev_mispredict, ev_irq_in_stall, ev_irq_taken;
integer wfi_commit, wfi_sleep, wfi_preempt;      // D23
integer ras_pushes, ras_pops, ret_pred_ok, ret_pred_bad;  // D24
integer ack_cnt [0:7];        // PIC acks per channel
integer ib_ok, ib_err, ib_bp;
integer db_rd_ok, db_rd_slverr, db_rd_decerr, db_rd_bp;
integer db_wr_ok, db_wr_slverr, db_wr_decerr;

integer i, j;
integer cls_i;
initial begin
    for (i = 0; i < 11; i = i + 1) cls_cnt[i] = 0;
    for (i = 0; i < 8;  i = i + 1) begin
        ld_cnt[i] = 0; st_cnt[i] = 0; ack_cnt[i] = 0;
        br_cnt[i][0] = 0; br_cnt[i][1] = 0;
    end
    for (i = 0; i < 4;  i = i + 1) bp_cnt[i]   = 0;
    for (i = 0; i < 32; i = i + 1) trap_cnt[i] = 0;
    for (i = 0; i < 8;  i = i + 1) csr_cnt[i]  = 0;
    for (i = 0; i < 3;  i = i + 1) fwd_cnt[i]  = 0;
    bp_tgt_wrong = 0; csr_ro = 0;
    ev_mret = 0; ev_mispredict = 0; ev_irq_in_stall = 0; ev_irq_taken = 0;
    wfi_commit = 0; wfi_sleep = 0; wfi_preempt = 0;
    ras_pushes = 0; ras_pops = 0; ret_pred_ok = 0; ret_pred_bad = 0;
    ib_ok = 0; ib_err = 0; ib_bp = 0;
    db_rd_ok = 0; db_rd_slverr = 0; db_rd_decerr = 0; db_rd_bp = 0;
    db_wr_ok = 0; db_wr_slverr = 0; db_wr_decerr = 0;
end

// committed instructions: class, size, branch_i outcome, CSR form, forwarding
always @(posedge clk_i) begin
    if (rst_n_i && commit) begin
        cls_i = cls_idx(opcode);
        if (cls_i >= 0)
            cls_cnt[cls_i] <= cls_cnt[cls_i] + 1;
        if (opcode == 7'b0000011) ld_cnt[funct3] <= ld_cnt[funct3] + 1;
        if (opcode == 7'b0100011) st_cnt[funct3] <= st_cnt[funct3] + 1;
        if (opcode == 7'b1100011)
            br_cnt[funct3][ctl_taken_i] <= br_cnt[funct3][ctl_taken_i] + 1;
        if (branch_i || jump_i)
            bp_cnt[{pred_taken_i, ctl_taken_i}] <= bp_cnt[{pred_taken_i, ctl_taken_i}] + 1;
        if (csr_instr_i) begin
            csr_cnt[{csr_imm_i, csr_op_i}] <= csr_cnt[{csr_imm_i, csr_op_i}] + 1;
            if (!csr_wen_i) csr_ro <= csr_ro + 1;
        end
        if (fwd_rs1_i && !fwd_rs2_i) fwd_cnt[0] <= fwd_cnt[0] + 1;
        if (!fwd_rs1_i && fwd_rs2_i) fwd_cnt[1] <= fwd_cnt[1] + 1;
        if (fwd_rs1_i && fwd_rs2_i)  fwd_cnt[2] <= fwd_cnt[2] + 1;
    end
end

// trap entries, binned by cause; irq sources land on codes 16..31 (D3);
// the test program exercises sources 0..7 (codes 16..23)
always @(posedge clk_i) begin
    if (rst_n_i && trap_take_i && s2_advance_i)
        trap_cnt[trap_code_i] <= trap_cnt[trap_code_i] + 1;
end

// resolution events that are not commits
always @(posedge clk_i) begin
    if (rst_n_i && s2_advance_i) begin
        if (mret_exec_i)   ev_mret <= ev_mret + 1;
        if (mispredict_i)  ev_mispredict <= ev_mispredict + 1;
        if (mispredict_i && pred_taken_i && ctl_taken_i)
            bp_tgt_wrong <= bp_tgt_wrong + 1;
        if (irq_take_i && ctrl_wfi_i) wfi_preempt <= wfi_preempt + 1;
    end
end

// WFI (D23) and RAS (D24) scenarios
always @(posedge clk_i) begin
    if (rst_n_i) begin
        if (wfi_wait_i) wfi_sleep <= wfi_sleep + 1;
        if (commit && ctrl_wfi_i) wfi_commit <= wfi_commit + 1;
        if (commit && ras_push_i) ras_pushes <= ras_pushes + 1;
        if (commit && ras_pop_i) begin
            ras_pops <= ras_pops + 1;
            if (mispredict_i) ret_pred_bad <= ret_pred_bad + 1;
            else            ret_pred_ok  <= ret_pred_ok  + 1;
        end
    end
end

// interrupt scenarios (cycle counts, not instruction counts)
always @(posedge clk_i) begin
    if (rst_n_i) begin
        if (cpu_irq_i && lsu_active_i)
            ev_irq_in_stall <= ev_irq_in_stall + 1;
        // the PIC now resolves priority and offers one prioritised source, so the
        // channel is read from cpu_irq_vec_i at the (single) claim pulse
        if (cpu_irq_ack_i) begin
            ev_irq_taken <= ev_irq_taken + 1;
            if (cpu_irq_vec_i < 4'd8) ack_cnt[cpu_irq_vec_i[2:0]] <= ack_cnt[cpu_irq_vec_i[2:0]] + 1;
        end
    end
end

// bus response beats and backpressure
always @(posedge clk_i) begin
    if (rst_n_i) begin
        if (ib_r_hs) begin
            if (ib_rresp_i[1]) ib_err <= ib_err + 1;
            else             ib_ok  <= ib_ok  + 1;
        end
        if (ib_arvalid_i && !ib_arready_i) ib_bp <= ib_bp + 1;
        if (db_r_hs) begin
            case (db_rresp_i)
                2'b10:   db_rd_slverr <= db_rd_slverr + 1;
                2'b11:   db_rd_decerr <= db_rd_decerr + 1;
                default: db_rd_ok     <= db_rd_ok     + 1;
            endcase
        end
        if (db_arvalid_i && !db_arready_i) db_rd_bp <= db_rd_bp + 1;
        if (db_b_hs) begin
            case (db_bresp_i)
                2'b10:   db_wr_slverr <= db_wr_slverr + 1;
                2'b11:   db_wr_decerr <= db_wr_decerr + 1;
                default: db_wr_ok     <= db_wr_ok     + 1;
            endcase
        end
    end
end

// --- report + coverage gate ---
//
// Each bin is tagged required (REQ) or optional (OPT). A required bin that
// stays 0 fails the gate — that is a coverage regression, checked as hard as a
// scoreboard miss. The optional bins are the ones the default run legitimately
// leaves untouched: the masked ch5 negatives (must never fire), the two AR
// backpressure bins (only the regress random-READY configs hit them), and the
// right-direction-wrong-target mispredict_i (the RAS covers those targets).

localparam bit REQ = 1'b1, OPT = 1'b0;

integer hit_n, tot_n, gate_fail;

function void rep(input string name, input integer cnt, input bit req);
    begin
        tot_n = tot_n + 1;
        if (cnt > 0)
            hit_n = hit_n + 1;
        else if (req)
            gate_fail = gate_fail + 1;
        $display("[FCOV] %0s : %0d %0s", name, cnt,
                 cnt > 0 ? "hit" : (req ? "MISS (required)" : "MISS (optional)"));
    end
endfunction

final begin
    hit_n = 0; tot_n = 0; gate_fail = 0;
    $display("[FCOV] ---- functional coverage report ----");

    rep("class LUI",     cls_cnt[C_LUI],   REQ);
    rep("class AUIPC",   cls_cnt[C_AUIPC], REQ);
    rep("class JAL",     cls_cnt[C_JAL],   REQ);
    rep("class JALR",    cls_cnt[C_JALR],  REQ);
    rep("class BRANCH",  cls_cnt[C_BR],    REQ);
    rep("class LOAD",    cls_cnt[C_LD],    REQ);
    rep("class STORE",   cls_cnt[C_ST],    REQ);
    rep("class OP-IMM",  cls_cnt[C_OPI],   REQ);
    rep("class OP",      cls_cnt[C_OP],    REQ);
    rep("class FENCE",   cls_cnt[C_FEN],   REQ);
    rep("class SYSTEM",  cls_cnt[C_SYS],   REQ);

    rep("load LB",  ld_cnt[3'b000], REQ);
    rep("load LH",  ld_cnt[3'b001], REQ);
    rep("load LW",  ld_cnt[3'b010], REQ);
    rep("load LBU", ld_cnt[3'b100], REQ);
    rep("load LHU", ld_cnt[3'b101], REQ);
    rep("store SB", st_cnt[3'b000], REQ);
    rep("store SH", st_cnt[3'b001], REQ);
    rep("store SW", st_cnt[3'b010], REQ);

    rep("branch_i BEQ  not-taken", br_cnt[3'b000][0], REQ);
    rep("branch_i BEQ  taken",     br_cnt[3'b000][1], REQ);
    rep("branch_i BNE  not-taken", br_cnt[3'b001][0], REQ);
    rep("branch_i BNE  taken",     br_cnt[3'b001][1], REQ);
    rep("branch_i BLT  not-taken", br_cnt[3'b100][0], REQ);
    rep("branch_i BLT  taken",     br_cnt[3'b100][1], REQ);
    rep("branch_i BGE  not-taken", br_cnt[3'b101][0], REQ);
    rep("branch_i BGE  taken",     br_cnt[3'b101][1], REQ);
    rep("branch_i BLTU not-taken", br_cnt[3'b110][0], REQ);
    rep("branch_i BLTU taken",     br_cnt[3'b110][1], REQ);
    rep("branch_i BGEU not-taken", br_cnt[3'b111][0], REQ);
    rep("branch_i BGEU taken",     br_cnt[3'b111][1], REQ);

    rep("predict NT actual NT (correct)",    bp_cnt[2'b00], REQ);
    rep("predict NT actual T  (mispredict_i)", bp_cnt[2'b01], REQ);
    rep("predict T  actual NT (mispredict_i)", bp_cnt[2'b10], REQ);
    rep("predict T  actual T",               bp_cnt[2'b11], REQ);
    rep("predict T, right dir, wrong target", bp_tgt_wrong, OPT);

    rep("trap instr_i misaligned (0)",  trap_cnt[0],  REQ);
    rep("trap instr_i fault (1)",       trap_cnt[1],  REQ);
    rep("trap illegal (2)",           trap_cnt[2],  REQ);
    rep("trap EBREAK (3)",            trap_cnt[3],  REQ);
    rep("trap load misaligned (4)",   trap_cnt[4],  REQ);
    rep("trap load fault (5)",        trap_cnt[5],  REQ);
    rep("trap store misaligned (6)",  trap_cnt[6],  REQ);
    rep("trap store fault (7)",       trap_cnt[7],  REQ);
    rep("trap ECALL (11)",            trap_cnt[11], REQ);
    for (j = 0; j < 8; j = j + 1)   // ch5 is deliberately masked, so optional
        rep($sformatf("trap irq channel %0d (%0d)", j, 16 + j),
            trap_cnt[16 + j], (j == 5) ? OPT : REQ);

    rep("CSRRW",       csr_cnt[3'b001], REQ);
    rep("CSRRS",       csr_cnt[3'b010], REQ);
    rep("CSRRC",       csr_cnt[3'b011], REQ);
    rep("CSRRWI",      csr_cnt[3'b101], REQ);
    rep("CSRRSI",      csr_cnt[3'b110], REQ);
    rep("CSRRCI",      csr_cnt[3'b111], REQ);
    rep("CSR pure read (rs1=x0)", csr_ro, REQ);

    rep("forward S3->S2 rs1 only", fwd_cnt[0], REQ);
    rep("forward S3->S2 rs2 only", fwd_cnt[1], REQ);
    rep("forward S3->S2 both",     fwd_cnt[2], REQ);

    rep("MRET executed",              ev_mret,          REQ);
    rep("mispredict_i redirects",       ev_mispredict,    REQ);
    rep("irq pending during a stall", ev_irq_in_stall,  REQ);
    rep("interrupts taken (claims)",  ev_irq_taken,     REQ);

    rep("WFI committed (masked wake)", wfi_commit,   REQ);
    rep("WFI sleep cycles",            wfi_sleep,    REQ);
    rep("WFI preempted by irq",        wfi_preempt,  REQ);
    rep("RAS push (committed call)",   ras_pushes,   REQ);
    rep("RAS pop (committed return)",  ras_pops,     REQ);
    rep("return predicted correctly",  ret_pred_ok,  REQ);
    rep("return mispredicted",         ret_pred_bad, REQ);
    for (j = 0; j < 8; j = j + 1)   // ch5 masked -> never acked, so optional
        rep($sformatf("PIC ack channel %0d", j), ack_cnt[j], (j == 5) ? OPT : REQ);

    rep("ibus fetch OKAY",         ib_ok,        REQ);
    rep("ibus fetch error resp",   ib_err,       REQ);
    rep("ibus AR backpressure",    ib_bp,        OPT);
    rep("dbus read OKAY",          db_rd_ok,     REQ);
    rep("dbus read SLVERR",        db_rd_slverr, REQ);
    rep("dbus read DECERR",        db_rd_decerr, REQ);
    rep("dbus AR backpressure",    db_rd_bp,     OPT);
    rep("dbus write OKAY",         db_wr_ok,     REQ);
    rep("dbus write SLVERR",       db_wr_slverr, REQ);
    rep("dbus write DECERR",       db_wr_decerr, REQ);

    $display("[FCOV] ---- %0d/%0d bins hit (%0d%%) ----",
             hit_n, tot_n, (hit_n * 100) / tot_n);
    if (gate_fail == 0)
        $display("[FCOV] == COVERAGE GATE PASSED ==");
    else
        $display("[FCOV] == COVERAGE GATE FAILED: %0d required bin(s) missed ==",
                 gate_fail);
end

endmodule
