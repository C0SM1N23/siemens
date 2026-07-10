// Functional coverage — bound into cpu_top, verification only.
//
// Turns the manual coverage argument in VERIFICATION.md into measured bins:
// every scenario the test plan claims to exercise gets a counter, sampled on
// the cycle the scenario actually happens at the S2 boundary (commit, trap
// entry, branch resolution) or on the bus handshake. At the end of the run a
// [FCOV] table prints every bin with its count and a hit/MISS verdict plus a
// summary percentage — a MISS line is a test-plan hole, not a failure.
//
// Sampling points:
// - commit      = a real instruction leaves S2 for writeback
//                 (s2_advance && ifdx_valid && !trap_take)
// - trap entry  = trap_take && s2_advance, binned by mcause code
// - resolution  = predictor outcome at a committed branch/jump
// - bus beats   = response handshakes on ibus/dbus, binned by RRESP/BRESP
//
// Implemented with plain counters (portable: Verilator, Questa, and — minus
// the SVA files — even ModelSim ASE could host this one). Bound from
// bind_sva.sv — no RTL is touched.

module cpu_func_cov (
    input        clk,
    input        rst_n,

    // S2 instruction + control (cpu_top internals, wired up by the bind)
    input        valid,          // ifdx_valid_q
    input [31:0] instr,          // ifdx_instr_q
    input        pred_taken,     // ifdx_ptk_q
    input        s2_advance,
    input        trap_take,
    input [4:0]  trap_code,
    input        irq_take,
    input        mispredict,
    input        branch,
    input        jump,
    input        ctl_taken,
    input        csr_instr,
    input [1:0]  csr_op,
    input        csr_imm,
    input        csr_wen,
    input        mret_exec,
    input        fwd_rs1,
    input        fwd_rs2,
    input        lsu_active,
    input        ctrl_wfi,       // WFI in S2 (D23)
    input        wfi_wait,       // WFI sleeping this cycle
    input        ras_push,       // committed call (D24)
    input        ras_pop,        // committed return

    // PIC interface
    input [7:0]  cpu_irq,
    input [7:0]  cpu_irq_ack,

    // bus response beats
    input        ib_arvalid,
    input        ib_arready,
    input        ib_rvalid,
    input        ib_rready,
    input [1:0]  ib_rresp,
    input        db_arvalid,
    input        db_arready,
    input        db_rvalid,
    input        db_rready,
    input [1:0]  db_rresp,
    input        db_bvalid,
    input        db_bready,
    input [1:0]  db_bresp
);

wire [6:0] opcode = instr[6:0];
wire [2:0] funct3 = instr[14:12];

wire commit  = s2_advance && valid && !trap_take;
wire ib_r_hs = ib_rvalid && ib_rready;
wire db_r_hs = db_rvalid && db_rready;
wire db_b_hs = db_bvalid && db_bready;

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
integer br_cnt  [0:7][0:1];   // branch funct3 x {not-taken, taken}
integer bp_cnt  [0:3];        // predictor {pred, actual} at resolution
integer bp_tgt_wrong;         // right direction, wrong BTB target
integer trap_cnt[0:31];       // trap entries by mcause code (16+ = irq)
integer csr_cnt [0:7];        // {imm, op}: CSRRW/S/C and immediate forms
integer csr_ro;               // CSRRS/C with rs1=x0: pure read, no write
integer fwd_cnt [0:2];        // forwarding: rs1 only / rs2 only / both
integer ev_mret, ev_mispredict, ev_irq_in_stall, ev_multi_pending;
integer wfi_commit, wfi_sleep, wfi_preempt;      // D23
integer ras_pushes, ras_pops, ret_pred_ok, ret_pred_bad;  // D24
integer ack_cnt [0:7];        // PIC acks per channel
integer ib_ok, ib_err, ib_bp;
integer db_rd_ok, db_rd_slverr, db_rd_decerr, db_rd_bp;
integer db_wr_ok, db_wr_slverr, db_wr_decerr;

integer i, j;
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
    ev_mret = 0; ev_mispredict = 0; ev_irq_in_stall = 0; ev_multi_pending = 0;
    wfi_commit = 0; wfi_sleep = 0; wfi_preempt = 0;
    ras_pushes = 0; ras_pops = 0; ret_pred_ok = 0; ret_pred_bad = 0;
    ib_ok = 0; ib_err = 0; ib_bp = 0;
    db_rd_ok = 0; db_rd_slverr = 0; db_rd_decerr = 0; db_rd_bp = 0;
    db_wr_ok = 0; db_wr_slverr = 0; db_wr_decerr = 0;
end

// committed instructions: class, size, branch outcome, CSR form, forwarding
always @(posedge clk) begin
    if (rst_n && commit) begin
        if (cls_idx(opcode) >= 0)
            cls_cnt[cls_idx(opcode)] <= cls_cnt[cls_idx(opcode)] + 1;
        if (opcode == 7'b0000011) ld_cnt[funct3] <= ld_cnt[funct3] + 1;
        if (opcode == 7'b0100011) st_cnt[funct3] <= st_cnt[funct3] + 1;
        if (opcode == 7'b1100011)
            br_cnt[funct3][ctl_taken] <= br_cnt[funct3][ctl_taken] + 1;
        if (branch || jump)
            bp_cnt[{pred_taken, ctl_taken}] <= bp_cnt[{pred_taken, ctl_taken}] + 1;
        if (csr_instr) begin
            csr_cnt[{csr_imm, csr_op}] <= csr_cnt[{csr_imm, csr_op}] + 1;
            if (!csr_wen) csr_ro <= csr_ro + 1;
        end
        if (fwd_rs1 && !fwd_rs2) fwd_cnt[0] <= fwd_cnt[0] + 1;
        if (!fwd_rs1 && fwd_rs2) fwd_cnt[1] <= fwd_cnt[1] + 1;
        if (fwd_rs1 && fwd_rs2)  fwd_cnt[2] <= fwd_cnt[2] + 1;
    end
end

// trap entries, binned by cause; irq channels land on codes 16..23 (D3)
always @(posedge clk) begin
    if (rst_n && trap_take && s2_advance)
        trap_cnt[trap_code] <= trap_cnt[trap_code] + 1;
end

// resolution events that are not commits
always @(posedge clk) begin
    if (rst_n && s2_advance) begin
        if (mret_exec)   ev_mret <= ev_mret + 1;
        if (mispredict)  ev_mispredict <= ev_mispredict + 1;
        if (mispredict && pred_taken && ctl_taken)
            bp_tgt_wrong <= bp_tgt_wrong + 1;
        if (irq_take && ctrl_wfi) wfi_preempt <= wfi_preempt + 1;
    end
end

// WFI (D23) and RAS (D24) scenarios
always @(posedge clk) begin
    if (rst_n) begin
        if (wfi_wait) wfi_sleep <= wfi_sleep + 1;
        if (commit && ctrl_wfi) wfi_commit <= wfi_commit + 1;
        if (commit && ras_push) ras_pushes <= ras_pushes + 1;
        if (commit && ras_pop) begin
            ras_pops <= ras_pops + 1;
            if (mispredict) ret_pred_bad <= ret_pred_bad + 1;
            else            ret_pred_ok  <= ret_pred_ok  + 1;
        end
    end
end

// interrupt scenarios (cycle counts, not instruction counts)
always @(posedge clk) begin
    if (rst_n) begin
        if (|cpu_irq && lsu_active)
            ev_irq_in_stall <= ev_irq_in_stall + 1;
        if (|(cpu_irq & (cpu_irq - 8'h01)))
            ev_multi_pending <= ev_multi_pending + 1;
        for (i = 0; i < 8; i = i + 1)
            if (cpu_irq_ack[i]) ack_cnt[i] <= ack_cnt[i] + 1;
    end
end

// bus response beats and backpressure
always @(posedge clk) begin
    if (rst_n) begin
        if (ib_r_hs) begin
            if (ib_rresp[1]) ib_err <= ib_err + 1;
            else             ib_ok  <= ib_ok  + 1;
        end
        if (ib_arvalid && !ib_arready) ib_bp <= ib_bp + 1;
        if (db_r_hs) begin
            case (db_rresp)
                2'b10:   db_rd_slverr <= db_rd_slverr + 1;
                2'b11:   db_rd_decerr <= db_rd_decerr + 1;
                default: db_rd_ok     <= db_rd_ok     + 1;
            endcase
        end
        if (db_arvalid && !db_arready) db_rd_bp <= db_rd_bp + 1;
        if (db_b_hs) begin
            case (db_bresp)
                2'b10:   db_wr_slverr <= db_wr_slverr + 1;
                2'b11:   db_wr_decerr <= db_wr_decerr + 1;
                default: db_wr_ok     <= db_wr_ok     + 1;
            endcase
        end
    end
end

// --- report ---

integer hit_n, tot_n;

function void rep(input string name, input integer cnt);
    begin
        tot_n = tot_n + 1;
        if (cnt > 0) hit_n = hit_n + 1;
        $display("[FCOV] %0s : %0d %0s", name, cnt, cnt > 0 ? "hit" : "MISS");
    end
endfunction

final begin
    hit_n = 0; tot_n = 0;
    $display("[FCOV] ---- functional coverage report ----");

    rep("class LUI",     cls_cnt[C_LUI]);
    rep("class AUIPC",   cls_cnt[C_AUIPC]);
    rep("class JAL",     cls_cnt[C_JAL]);
    rep("class JALR",    cls_cnt[C_JALR]);
    rep("class BRANCH",  cls_cnt[C_BR]);
    rep("class LOAD",    cls_cnt[C_LD]);
    rep("class STORE",   cls_cnt[C_ST]);
    rep("class OP-IMM",  cls_cnt[C_OPI]);
    rep("class OP",      cls_cnt[C_OP]);
    rep("class FENCE",   cls_cnt[C_FEN]);
    rep("class SYSTEM",  cls_cnt[C_SYS]);

    rep("load LB",  ld_cnt[3'b000]);
    rep("load LH",  ld_cnt[3'b001]);
    rep("load LW",  ld_cnt[3'b010]);
    rep("load LBU", ld_cnt[3'b100]);
    rep("load LHU", ld_cnt[3'b101]);
    rep("store SB", st_cnt[3'b000]);
    rep("store SH", st_cnt[3'b001]);
    rep("store SW", st_cnt[3'b010]);

    rep("branch BEQ  not-taken", br_cnt[3'b000][0]);
    rep("branch BEQ  taken",     br_cnt[3'b000][1]);
    rep("branch BNE  not-taken", br_cnt[3'b001][0]);
    rep("branch BNE  taken",     br_cnt[3'b001][1]);
    rep("branch BLT  not-taken", br_cnt[3'b100][0]);
    rep("branch BLT  taken",     br_cnt[3'b100][1]);
    rep("branch BGE  not-taken", br_cnt[3'b101][0]);
    rep("branch BGE  taken",     br_cnt[3'b101][1]);
    rep("branch BLTU not-taken", br_cnt[3'b110][0]);
    rep("branch BLTU taken",     br_cnt[3'b110][1]);
    rep("branch BGEU not-taken", br_cnt[3'b111][0]);
    rep("branch BGEU taken",     br_cnt[3'b111][1]);

    rep("predict NT actual NT (correct)",    bp_cnt[2'b00]);
    rep("predict NT actual T  (mispredict)", bp_cnt[2'b01]);
    rep("predict T  actual NT (mispredict)", bp_cnt[2'b10]);
    rep("predict T  actual T",               bp_cnt[2'b11]);
    rep("predict T, right dir, wrong target", bp_tgt_wrong);

    rep("trap instr misaligned (0)",  trap_cnt[0]);
    rep("trap instr fault (1)",       trap_cnt[1]);
    rep("trap illegal (2)",           trap_cnt[2]);
    rep("trap EBREAK (3)",            trap_cnt[3]);
    rep("trap load misaligned (4)",   trap_cnt[4]);
    rep("trap load fault (5)",        trap_cnt[5]);
    rep("trap store misaligned (6)",  trap_cnt[6]);
    rep("trap store fault (7)",       trap_cnt[7]);
    rep("trap ECALL (11)",            trap_cnt[11]);
    for (j = 0; j < 8; j = j + 1)
        rep($sformatf("trap irq channel %0d (%0d)", j, 16 + j), trap_cnt[16 + j]);

    rep("CSRRW",       csr_cnt[3'b001]);
    rep("CSRRS",       csr_cnt[3'b010]);
    rep("CSRRC",       csr_cnt[3'b011]);
    rep("CSRRWI",      csr_cnt[3'b101]);
    rep("CSRRSI",      csr_cnt[3'b110]);
    rep("CSRRCI",      csr_cnt[3'b111]);
    rep("CSR pure read (rs1=x0)", csr_ro);

    rep("forward S3->S2 rs1 only", fwd_cnt[0]);
    rep("forward S3->S2 rs2 only", fwd_cnt[1]);
    rep("forward S3->S2 both",     fwd_cnt[2]);

    rep("MRET executed",              ev_mret);
    rep("mispredict redirects",       ev_mispredict);
    rep("irq pending during a stall", ev_irq_in_stall);
    rep("multiple irqs pending",      ev_multi_pending);

    rep("WFI committed (masked wake)", wfi_commit);
    rep("WFI sleep cycles",            wfi_sleep);
    rep("WFI preempted by irq",        wfi_preempt);
    rep("RAS push (committed call)",   ras_pushes);
    rep("RAS pop (committed return)",  ras_pops);
    rep("return predicted correctly",  ret_pred_ok);
    rep("return mispredicted",         ret_pred_bad);
    for (j = 0; j < 8; j = j + 1)
        rep($sformatf("PIC ack channel %0d", j), ack_cnt[j]);

    rep("ibus fetch OKAY",         ib_ok);
    rep("ibus fetch error resp",   ib_err);
    rep("ibus AR backpressure",    ib_bp);
    rep("dbus read OKAY",          db_rd_ok);
    rep("dbus read SLVERR",        db_rd_slverr);
    rep("dbus read DECERR",        db_rd_decerr);
    rep("dbus AR backpressure",    db_rd_bp);
    rep("dbus write OKAY",         db_wr_ok);
    rep("dbus write SLVERR",       db_wr_slverr);
    rep("dbus write DECERR",       db_wr_decerr);

    $display("[FCOV] ---- %0d/%0d bins hit (%0d%%) ----",
             hit_n, tot_n, (hit_n * 100) / tot_n);
end

endmodule
