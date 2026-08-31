// RV32I CPU, 3-stage pipeline, top level.
// REQ# = spec requirement, D# = intern design choice, both listed in the README
// (grep REQ or D<n> to jump around).
//
// The three stages:
// - S1 fetch      AXI4-Lite master on ibus (AR/R) + BTB/BHT predictor
// - S2 dec+exec   decode, regfile, ALU, branch, CSR, load/store on dbus (S2
//                 stalls the whole AXI round-trip). Traps, interrupts and
//                 mispredicts all resolve here, so traps stay precise.
// - S3 writeback  writes rd back to the regfile, otherwise a no-op
//
// REQ1: the 3-stage pipeline above.
// REQ2: two AXI4-Lite master ports, ibus (read only) and dbus (read+write).
// REQ3: one sync clock, async active-low reset, PIC lines cpu_irq_i / cpu_irq_vec_i
//       / cpu_irq_ack_o / cpu_irq_eoi_o (cpu_in_trap_o kept for observability/SVA).
// REQ4: interrupts sampled only under mstatus.MIE, at instruction boundaries.
//       cpu_irq_ack_o pulses one cycle at claim; cpu_irq_eoi_o pulses one cycle when
//       an interrupt handler returns (MRET), so the PIC pops its nesting stack.
//       The advanced-scheduling PIC drives a single request line plus a 4-bit
//       vector (id 0..15); the CPU gates it with mie[16+vec] and mstatus.MIE.
//
// D1: pipeline registers carry a valid bit, so valid=0 is always a safe bubble
//     and we don't lean on the NOP encoding. S3->S2 forwarding kills the
//     load-use stall, and the two ports are independent (1 outstanding each), so
//     fetch and load/store overlap.
// D2: S2 priority is interrupt > sync exception > mispredict, done as a plain
//     sequential check. The interrupt is tested before any data transaction, so
//     a preempted instruction reruns cleanly after MRET. Trap/MRET redirects skip
//     the predictor.
// D4: trap return address: exceptions point at the offending instruction,
//     interrupts at the instruction to resume from.
// D5: RESET_PC and HART_ID let us instantiate the core N times. HART_ID feeds
//     mhartid so software can tell instances apart (beyond spec). Single core =
//     both 0.
// D23: WFI wake logic lives here (the stall itself is hazard_unit's): wake on any
//     mie-enabled pending interrupt, ignoring mstatus.MIE, and a WFI-ending
//     interrupt records mepc = wfi+4 so MRET resumes past it.
// D28: reset policy. Every flop in the CPU and in its submodules is reset by the
//      single asynchronous, active-low rst_n_i, including the pipeline-register
//      payloads and the predictor arrays, which a valid bit would otherwise
//      cover. The rule is "no flop leaves reset holding X", so that (a) no bus
//      output or architectural read can ever return X, (b) a 2-state simulation
//      and a 4-state simulation agree from cycle 0, and (c) a waveform taken
//      immediately after reset is readable everywhere instead of only on the
//      control bits. Where the reset value is not simply zero it is the value
//      that makes the idle block behave: the canonical NOP for instruction
//      words, RESET_PC for program addresses, all-ones for mtimecmp (disarmed),
//      0x1B for the PIC's BAND_CONFIG and 8 for its NEST_MAX. Exactly one always
//      block drives each register, so a register's reset value and its update
//      rules are always found together.

`timescale 1ns/1ps

`include "defines.vh"

module cpu_top #(
    parameter RESET_PC   = 32'h0000_0000, // reset vector, until the memory map is settled
    parameter HART_ID    = 32'd0,         // mhartid value; lets 2..N cores share one SoC
    parameter BP_ENTRIES = 128,           // BTB/BHT entries, power of 2 (D9)
    parameter RAS_DEPTH  = 8              // return-address stack depth, 0 disables (D24)
)(
    input             clk_i,
    input             rst_n_i,             // async reset, active low

    // ibus_axi: AXI4-Lite master, read-only (instruction fetch)
    output     [31:0] ibus_axi_araddr_o,
    output     [2:0]  ibus_axi_arprot_o,
    output            ibus_axi_arvalid_o,
    input             ibus_axi_arready_i,
    input      [31:0] ibus_axi_rdata_i,
    input      [1:0]  ibus_axi_rresp_i,
    input             ibus_axi_rvalid_i,
    output            ibus_axi_rready_o,

    // dbus_axi: AXI4-Lite master, read+write (load/store)
    output     [31:0] dbus_axi_awaddr_o,
    output     [2:0]  dbus_axi_awprot_o,
    output            dbus_axi_awvalid_o,
    input             dbus_axi_awready_i,
    output     [31:0] dbus_axi_wdata_o,
    output     [3:0]  dbus_axi_wstrb_o,
    output            dbus_axi_wvalid_o,
    input             dbus_axi_wready_i,
    input      [1:0]  dbus_axi_bresp_i,
    input             dbus_axi_bvalid_i,
    output            dbus_axi_bready_o,
    output     [31:0] dbus_axi_araddr_o,
    output     [2:0]  dbus_axi_arprot_o,
    output            dbus_axi_arvalid_o,
    input             dbus_axi_arready_i,
    input      [31:0] dbus_axi_rdata_i,
    input      [1:0]  dbus_axi_rresp_i,
    input             dbus_axi_rvalid_i,
    output            dbus_axi_rready_o,

    // PIC interface (see D3): single request + 4-bit vector, claim/eoi pulses.
    // irq_pending_i is the PIC's full pending mask and feeds mip[31:16];
    // irq_mask_o is mie[31:16] going back the other way, so the PIC's resolver
    // never picks a source this core has masked off.
    input             cpu_irq_i,
    input      [3:0]  cpu_irq_vec_i,
    input      [15:0] irq_pending_i,
    output     [15:0] irq_mask_o,
    output reg        cpu_irq_ack_o,
    output reg        cpu_irq_eoi_o,
    output reg        cpu_in_trap_o
);

// pipeline regs (D1) and S2 results, declared up front because the
// predictor and CSR instances reference them before the S2 section
reg        ifdx_valid_q, ifdx_fault_q, ifdx_ptk_q;
reg [31:0] ifdx_pc_q, ifdx_instr_q, ifdx_ptg_q;

reg        dxwb_valid_q, dxwb_regwrite_q;
reg [4:0]  dxwb_rd_q;
reg [1:0]  dxwb_wbsel_q;
reg [31:0] dxwb_result_q, dxwb_mem_q, dxwb_pc4_q;

wire        ctl_taken_raw, mret_exec, mispredict;
wire        ras_push, ras_pop;      // RAS hints, resolved in S2 (D24)
wire [31:0] s2_pc4;                 // the one shared S2 PC+4 adder

// S1: fetch + predictor

wire        redirect;
wire [31:0] redirect_pc;
wire        s2_advance, if_dx_we, if_dx_bubble, dx_squash;

wire        f_valid, f_fault, f_ptk;
wire [31:0] f_instr, f_pc, f_ptg;

wire [31:0] bp_lookup_pc, bp_target;
wire        bp_taken;

fetch_unit #(.RESET_PC(RESET_PC)) fetch_unit_inst (
    .clk_i           (clk_i),
    .rst_n_i         (rst_n_i),
    .ibus_araddr_o   (ibus_axi_araddr_o),
    .ibus_arprot_o   (ibus_axi_arprot_o),
    .ibus_arvalid_o  (ibus_axi_arvalid_o),
    .ibus_arready_i  (ibus_axi_arready_i),
    .ibus_rdata_i    (ibus_axi_rdata_i),
    .ibus_rresp_i    (ibus_axi_rresp_i),
    .ibus_rvalid_i   (ibus_axi_rvalid_i),
    .ibus_rready_o   (ibus_axi_rready_o),
    .bp_lookup_pc_o  (bp_lookup_pc),
    .bp_pred_taken_i (bp_taken),
    .bp_pred_target_i(bp_target),
    .redirect_i      (redirect),
    .redirect_pc_i   (redirect_pc),
    .s2_ready_i      (s2_advance),
    .instr_valid_o   (f_valid),
    .instr_o         (f_instr),
    .instr_pc_o      (f_pc),
    .pred_taken_o    (f_ptk),
    .pred_target_o   (f_ptg),
    .fetch_fault_o   (f_fault)
);

wire        bp_update_en;
wire [31:0] actual_target;

branch_predictor #(.ENTRIES(BP_ENTRIES), .RAS_DEPTH(RAS_DEPTH)) branch_predictor_inst (
    .clk_i           (clk_i),
    .rst_n_i         (rst_n_i),
    .lookup_pc_i     (bp_lookup_pc),
    .pred_taken_o    (bp_taken),
    .pred_target_o   (bp_target),
    .update_en_i     (bp_update_en),
    .update_pc_i     (ifdx_pc_q),
    .update_taken_i  (ctl_taken_raw),
    .update_target_i (actual_target),
    .update_is_ret_i (ras_pop),
    .update_call_i   (bp_update_en && ras_push),
    .update_ret_i    (bp_update_en && ras_pop),
    .update_link_i   (s2_pc4)
);

// IF/DX valid: valid=0 turns whatever the payload holds into a safe bubble (D1)
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        ifdx_valid_q <= 1'b0;
    else if (if_dx_we)
        ifdx_valid_q <= ~if_dx_bubble;
end

// IF/DX instruction word: the payload bit whose reset is load-bearing. control.v
// decodes it combinationally, so an X here makes MemRead/MemWrite/illegal X from
// time 0. Those are masked by dec_live while valid=0, but on the first cycle
// valid rises the AND resolves to X for one delta before the decoder re-runs,
// and that X reaches ibus_arvalid / dbus_awvalid / dbus_wvalid / dbus_arvalid.
// Resetting to the canonical NOP keeps the decoder outputs defined at all times.
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        ifdx_instr_q <= 32'h0000_0013;              // addi x0, x0, 0
    else if (if_dx_we && !if_dx_bubble)
        ifdx_instr_q <= f_instr;
end

// Remaining IF/DX payload: only loaded on a real instruction, so bubbles and
// stalls leave the S2 datapath quiet. Functionally ifdx_valid_q gates all of it,
// but it is reset anyway (reset policy, D28): ifdx_pc_q feeds the S2 PC+4 adder,
// the branch target adder and the predictor update port combinationally, so an
// unreset value shows up as X on those nets in every waveform taken before the
// first instruction is delivered.
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        ifdx_pc_q    <= RESET_PC;
        ifdx_ptk_q   <= 1'b0;
        ifdx_ptg_q   <= RESET_PC;
        ifdx_fault_q <= 1'b0;
    end else if (if_dx_we && !if_dx_bubble) begin
        ifdx_pc_q    <= f_pc;
        ifdx_ptk_q   <= f_ptk;
        ifdx_ptg_q   <= f_ptg;
        ifdx_fault_q <= f_fault;
    end
end

// S2: decode + execute

wire [6:0]  opcode, funct7;
wire [4:0]  rd, rs1, rs2;
wire [2:0]  funct3;
wire [31:0] imm_out;

decode decode_inst (
    .instr_i  (ifdx_instr_q),
    .opcode_o (opcode),
    .rd_o     (rd),
    .funct3_o (funct3),
    .rs1_o    (rs1),
    .rs2_o    (rs2),
    .funct7_o (funct7)
);

imm_gen imm_gen_inst (
    .instr_i   (ifdx_instr_q),
    .imm_out_o (imm_out)
);

wire        RegWrite, ALUSrc, MemRead, MemWrite, Branch, Jump;
wire [3:0]  ALUOp;
wire [1:0]  MemtoReg;
wire        csr_instr, csr_imm, ctrl_mret, ctrl_ecall, ctrl_ebreak, ctrl_illegal;
wire        ctrl_wfi;
wire [1:0]  csr_op;

control control_inst (
    .opcode_i    (opcode),
    .funct3_i    (funct3),
    .funct7_i    (funct7),
    .rs1_i       (rs1),
    .rd_i        (rd),
    .imm12_i     (ifdx_instr_q[31:20]),
    .RegWrite_o  (RegWrite),
    .ALUSrc_o    (ALUSrc),
    .ALUOp_o     (ALUOp),
    .MemRead_o   (MemRead),
    .MemWrite_o  (MemWrite),
    .MemtoReg_o  (MemtoReg),
    .Branch_o    (Branch),
    .Jump_o      (Jump),
    .csr_instr_o (csr_instr),
    .csr_op_o    (csr_op),
    .csr_imm_o   (csr_imm),
    .mret_o      (ctrl_mret),
    .ecall_o     (ctrl_ecall),
    .ebreak_o    (ctrl_ebreak),
    .wfi_o       (ctrl_wfi),
    .illegal_o   (ctrl_illegal)
);

// regfile reads combinationally; the S3 value is bypassed when it targets a
// source reg, since the write only lands on the clock edge (D13)
wire [31:0] rs1_data, rs2_data, wb_data;
wire        fwd_rs1, fwd_rs2;

regfile regfile_inst (
    .clk_i      (clk_i),
    .rst_n_i    (rst_n_i),
    .rs1_addr_i (rs1),
    .rs2_addr_i (rs2),
    .rd_addr_i  (dxwb_rd_q),
    .rd_data_i  (wb_data),
    .RegWrite_i (dxwb_valid_q & dxwb_regwrite_q),
    .rs1_data_o (rs1_data),
    .rs2_data_o (rs2_data)
);

wire [31:0] rs1_v = fwd_rs1 ? wb_data : rs1_data;
wire [31:0] rs2_v = fwd_rs2 ? wb_data : rs2_data;

// interrupt check at the instruction boundary, before any data transaction
// goes out (D2, REQ4); lsu_active blocks it for the rest of the op
wire        lsu_busy, lsu_done, lsu_err, lsu_active;
wire        mie_global;
wire [15:0] irq_enable;

// The PIC offers one prioritised source. mie[31:16] is handed to the PIC so the
// resolver skips sources this core has masked; the check is repeated here on
// the offer because mie can change in the cycle between the two, and globally
// with MIE.
assign irq_mask_o = irq_enable;

wire irq_deliverable = cpu_irq_i && irq_enable[cpu_irq_vec_i];
wire irq_take = ifdx_valid_q && !lsu_active && mie_global && irq_deliverable;

// mip[31:16] (the machine external window) shows everything the PIC has
// pending, not just the source it chose to offer: mip reports what is waiting,
// and software reading it has to see the sources queued behind the winner.
wire [15:0] irq_lines = irq_pending_i;

// instruction actually executes: not preempted, and the fetch was clean
wire dec_live = ifdx_valid_q && !irq_take && !ifdx_fault_q;

// WFI (D23): sleep until a locally-enabled interrupt is pending. mie gates the
// wake, mstatus.MIE deliberately doesn't (Priv. spec 3.3.3). While asleep S2 is
// frozen and S1 parks its fetch, so the ibus goes quiet. If MIE is set we get a
// normal irq_take (dec_live drops and releases the stall); if masked, the WFI
// just commits as a NOP and falls through.
wire wfi_wake = irq_deliverable;
wire wfi_wait = dec_live && ctrl_wfi && !wfi_wake;

// one shared PC+4 adder for S2: mispredict fall-through, JAL/JALR link and the
// WFI resume address are all the same number
assign s2_pc4 = ifdx_pc_q + 32'd4;

// ALU; AUIPC takes the PC as operand A
wire [31:0] alu_result;
wire [31:0] alu_opa = (ALUOp == `ALUOP_AUIPC) ? ifdx_pc_q : rs1_v;

alu_top alu_top_inst (
    .operand_a_i     (alu_opa),
    .operand_b_reg_i (rs2_v),
    .operand_b_imm_i (imm_out),
    .ALUSrc_i        (ALUSrc),
    .ALUOp_i         (ALUOp),
    .funct3_i        (funct3),
    .funct7_i        (funct7),
    .result_o        (alu_result)
);

// real direction + target of the control transfer
wire pc_src;

branch_unit branch_unit_inst (
    .pc_in_i         (ifdx_pc_q),
    .imm_out_i       (imm_out),
    .rs1_data_i      (rs1_v),
    .rs2_data_i      (rs2_v),
    .opcode_i        (opcode),
    .funct3_i        (funct3),
    .Branch_i        (Branch),
    .Jump_i          (Jump),
    .branch_target_o (actual_target),
    .pc_src_o        (pc_src)
);

assign ctl_taken_raw = dec_live && pc_src;   // pre-exception, feeds trap detect

// CSR: read in S2, write commits on the edge that closes S2
wire [31:0] csr_rdata, trap_vector, mepc_out;
wire        csr_illegal;
wire        csr_ren = dec_live && csr_instr;
// CSRRS/C with rs1=x0 (uimm=0) is a pure read, per RISC-V
wire        csr_wen = csr_ren && (csr_op == `CSROP_RW || rs1 != 5'b0);
wire [31:0] csr_wdata = csr_imm ? {27'b0, rs1} : rs1_v;

wire        exception;
wire [4:0]  exc_cause;
wire        trap_take = irq_take | exception;
wire [4:0]  trap_code = irq_take ? {1'b1, cpu_irq_vec_i} : exc_cause;  // irq: 16+vec

// mtval payload: exception_unit picks it with the cause; interrupts write 0
wire [31:0] exc_tval;
wire [31:0] trap_val = irq_take ? 32'b0 : exc_tval;

csr_file #(.HART_ID(HART_ID)) csr_file_inst (
    .clk_i         (clk_i),
    .rst_n_i       (rst_n_i),
    .csr_addr_i    (ifdx_instr_q[31:20]),
    .csr_wdata_i   (csr_wdata),
    .csr_op_i      (csr_op),
    .csr_ren_i     (csr_ren),
    .csr_wen_i     (csr_wen),
    .csr_rdata_o   (csr_rdata),
    .csr_illegal_o (csr_illegal),
    .trap_set_i    (trap_take & s2_advance),
    .trap_is_irq_i (irq_take),
    .trap_code_i   (trap_code),
    // an interrupt that wakes a WFI resumes past it (mepc = pc+4, Priv. 3.3.3);
    // everything else records the instruction itself
    .trap_pc_i     (irq_take && ctrl_wfi && !ifdx_fault_q ? s2_pc4 : ifdx_pc_q),
    .trap_val_i    (trap_val),
    .mret_i        (mret_exec),
    .irq_lines_i   (irq_lines),
    .irq_enable_o  (irq_enable),
    .mie_global_o  (mie_global),
    .trap_vector_o (trap_vector),
    .mepc_out_o    (mepc_out),
    .retire_i      (dxwb_valid_q),
    // performance events (D25); trap count reuses trap_set inside
    .ev_mispredict_i (mispredict && s2_advance),
    .ev_ibus_wait_i  (~ifdx_valid_q),
    .ev_dbus_stall_i (lsu_busy),
    .ev_wfi_sleep_i  (wfi_wait)
);

// LSU: only issue for a live, legal, aligned op. An illegal or misaligned
// access has to trap without touching the bus (D17)
wire        mem_misaligned;
wire [31:0] lsu_rdata;
wire        lsu_req = dec_live && (MemRead | MemWrite) &&
                      !ctrl_illegal && !mem_misaligned;

lsu lsu_inst (
    .clk_i          (clk_i),
    .rst_n_i        (rst_n_i),
    .req_i          (lsu_req),
    .we_i           (MemWrite),
    .funct3_i       (funct3),
    .addr_i         (alu_result),
    .st_data_i      (rs2_v),
    .busy_o         (lsu_busy),
    .done_o         (lsu_done),
    .err_o          (lsu_err),
    .active_o       (lsu_active),
    .ld_data_o      (lsu_rdata),
    .dbus_awaddr_o  (dbus_axi_awaddr_o),
    .dbus_awprot_o  (dbus_axi_awprot_o),
    .dbus_awvalid_o (dbus_axi_awvalid_o),
    .dbus_awready_i (dbus_axi_awready_i),
    .dbus_wdata_o   (dbus_axi_wdata_o),
    .dbus_wstrb_o   (dbus_axi_wstrb_o),
    .dbus_wvalid_o  (dbus_axi_wvalid_o),
    .dbus_wready_i  (dbus_axi_wready_i),
    .dbus_bresp_i   (dbus_axi_bresp_i),
    .dbus_bvalid_i  (dbus_axi_bvalid_i),
    .dbus_bready_o  (dbus_axi_bready_o),
    .dbus_araddr_o  (dbus_axi_araddr_o),
    .dbus_arprot_o  (dbus_axi_arprot_o),
    .dbus_arvalid_o (dbus_axi_arvalid_o),
    .dbus_arready_i (dbus_axi_arready_i),
    .dbus_rdata_i   (dbus_axi_rdata_i),
    .dbus_rresp_i   (dbus_axi_rresp_i),
    .dbus_rvalid_i  (dbus_axi_rvalid_i),
    .dbus_rready_o  (dbus_axi_rready_o)
);

exception_unit exception_unit_inst (
    .valid_i          (ifdx_valid_q && !irq_take),
    .fetch_fault_i    (ifdx_fault_q),
    .illegal_i        (ctrl_illegal | csr_illegal),
    .ecall_i          (ctrl_ecall),
    .ebreak_i         (ctrl_ebreak),
    .pc_i             (ifdx_pc_q),
    .instr_i          (ifdx_instr_q),
    .ctl_taken_i      (ctl_taken_raw),
    .ctl_target_i     (actual_target),
    .MemRead_i        (MemRead),
    .MemWrite_i       (MemWrite),
    .funct3_i         (funct3),
    .mem_addr_i       (alu_result),
    .mem_active_i     (lsu_active),
    .mem_done_i       (lsu_done),
    .mem_err_i        (lsu_err),
    .exception_o      (exception),
    .cause_o          (exc_cause),
    .tval_o           (exc_tval),
    .mem_misaligned_o (mem_misaligned)
);

// MRET and mispredict come after interrupt/exception in priority (D2)
assign mret_exec = dec_live && ctrl_mret;
wire ctl_taken  = ctl_taken_raw && !exception;
assign mispredict = dec_live && !exception && !ctrl_mret &&
                    ((ifdx_ptk_q != ctl_taken) ||
                     (ctl_taken && (ifdx_ptg_q != actual_target)));

// predictor learns every committed branch/jump at resolution (D11)
assign bp_update_en = dec_live && (Branch | Jump) && !exception && s2_advance;

// RAS hints (D24): rd/rs1 in {x1,x5} mark calls/returns, per the ISA's JALR hint
// table. Both link with rd==rs1 is push-only; both link with rd!=rs1 is
// pop-then-push (the predictor treats push+pop as replace-top). Learned at the
// BTB commit point, so RAS state is never speculative and survives traps (D11).
wire rd_link  = (rd  == 5'd1) || (rd  == 5'd5);
wire rs1_link = (rs1 == 5'd1) || (rs1 == 5'd5);
assign ras_push = Jump && rd_link;
assign ras_pop  = (opcode == `OPC_JALR) && rs1_link && !(rd_link && rd == rs1);

// redirect target: trap > MRET > corrected path after a mispredict
assign redirect_pc = trap_take ? trap_vector :
                     mret_exec ? mepc_out    :
                     ctl_taken ? actual_target : s2_pc4;

hazard_unit hazard_unit_inst (
    .fetch_valid_i  (f_valid),
    .lsu_busy_i     (lsu_busy),
    .wfi_wait_i     (wfi_wait),
    .trap_take_i    (trap_take),
    .mret_exec_i    (mret_exec),
    .mispredict_i   (mispredict),
    .rs1_i          (rs1),
    .rs2_i          (rs2),
    .wb_valid_i     (dxwb_valid_q),
    .wb_reg_write_i (dxwb_regwrite_q),
    .wb_rd_i        (dxwb_rd_q),
    .s2_advance_o   (s2_advance),
    .redirect_o     (redirect),
    .if_dx_we_o     (if_dx_we),
    .if_dx_bubble_o (if_dx_bubble),
    .dx_squash_o    (dx_squash),
    .fwd_rs1_o      (fwd_rs1),
    .fwd_rs2_o      (fwd_rs2)
);

// Open-trap stack: one bit per trap level currently open, 1 if that level was
// an interrupt (and so owes the PIC an EOI on return), 0 if it was a
// synchronous exception (and owes nothing). Pushed on every accepted trap,
// popped on every MRET.
//
// A single in-progress flag is not enough, because MRET is the same instruction
// for both kinds of return and both kinds of trap can be open at once:
//
//   - two nested interrupt handlers: the inner MRET would clear the flag, the
//     outer MRET would then send no EOI, and the outer level would sit on the
//     PIC's nesting stack forever with its source stuck active.
//   - a synchronous exception taken inside an interrupt handler: its MRET would
//     find the flag set and send an EOI, popping the interrupt out of the PIC
//     while its handler is still running.
//
// Both disappear once the return knows which kind of trap it is returning from,
// which is exactly one bit per level. TRAP_DEPTH matches the PIC's largest
// NEST_MAX, so no reachable interrupt nesting can overflow it.
localparam TRAP_DEPTH = 16;

reg  [TRAP_DEPTH-1:0] trap_kind_q;    // bit 0 = innermost open level
reg  [4:0]            trap_depth_q;   // 0..TRAP_DEPTH

wire trap_push = trap_take && s2_advance;
wire trap_pop  = mret_exec && s2_advance && (trap_depth_q != 5'd0);

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        trap_kind_q  <= {TRAP_DEPTH{1'b0}};
        trap_depth_q <= 5'd0;
    end else if (trap_push) begin
        trap_kind_q  <= {trap_kind_q[TRAP_DEPTH-2:0], irq_take};
        if (trap_depth_q != TRAP_DEPTH[4:0])
            trap_depth_q <= trap_depth_q + 5'd1;
    end else if (trap_pop) begin
        trap_kind_q  <= {1'b0, trap_kind_q[TRAP_DEPTH-1:1]};
        trap_depth_q <= trap_depth_q - 5'd1;
    end
end

// the level this MRET is returning from was an interrupt
wire mret_from_irq = trap_pop && trap_kind_q[0];

// claim pulses one cycle at acceptance (REQ4)
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        cpu_irq_ack_o <= 1'b0;
    else
        cpu_irq_ack_o <= irq_take && s2_advance;
end

// eoi pulses one cycle when an interrupt handler returns (REQ4). An MRET that
// returns from a synchronous exception sends nothing, even if an interrupt
// handler is open underneath it.
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        cpu_irq_eoi_o <= 1'b0;
    else
        cpu_irq_eoi_o <= mret_from_irq;
end

// cpu_in_trap_o is "some trap level is still open", so a nested trap inside a
// handler really does keep it up: it drops only on the MRET that closes the
// last level (REQ4).
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        cpu_in_trap_o <= 1'b0;
    else if (trap_push)
        cpu_in_trap_o <= 1'b1;
    else if (trap_pop)
        cpu_in_trap_o <= (trap_depth_q > 5'd1);
end

// DX/WB valid, with trap squash: the offending instruction never commits (D3).
// While S2 stalls, S3 gets bubbles so nothing commits twice.
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        dxwb_valid_q <= 1'b0;
    else if (s2_advance)
        dxwb_valid_q <= ifdx_valid_q && !dx_squash;
    else
        dxwb_valid_q <= 1'b0;
end

// DX/WB payload, captured only when a real instruction leaves S2. Bubbles leave
// these ~130 flops alone, and everything downstream is gated by dxwb_valid_q, so
// a reset is not needed for correctness; it is applied anyway (reset policy,
// D28) so that wb_data -- which the writeback mux drives combinationally, and
// which the S3->S2 forwarding path muxes into the ALU operands -- is defined
// from time zero rather than X until the first instruction retires.
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        dxwb_rd_q       <= 5'd0;
        dxwb_regwrite_q <= 1'b0;
        dxwb_wbsel_q    <= `WB_ALU;
        dxwb_result_q   <= 32'd0;
        dxwb_mem_q      <= 32'd0;
        dxwb_pc4_q      <= 32'd0;
    end else if (s2_advance && ifdx_valid_q) begin
        dxwb_rd_q       <= rd;
        dxwb_regwrite_q <= RegWrite && !ifdx_fault_q;
        dxwb_wbsel_q    <= MemtoReg;
        dxwb_result_q   <= csr_instr ? csr_rdata : alu_result;
        dxwb_mem_q      <= lsu_rdata;
        dxwb_pc4_q      <= s2_pc4;
    end
end

// S3: writeback
writeback_mux writeback_mux_inst (
    .alu_result_i (dxwb_result_q),
    .mem_data_i   (dxwb_mem_q),
    .pc_plus4_i   (dxwb_pc4_q),
    .MemtoReg_i   (dxwb_wbsel_q),
    .wb_data_o    (wb_data)
);

endmodule
