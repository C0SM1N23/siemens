// RV32I CPU — 3-stage pipeline, top level.
// REQ# = spec requirement (implemented to spec), D# = intern design choice.
// Both families are indexed in the README; grep REQ or D<n> to navigate.
//
// The three stages:
// - S1 fetch      AXI4-Lite master on ibus (AR/R) + BTB/BHT branch predictor
// - S2 dec+exec   decode, regfile, ALU, branch, CSR; load/store on dbus with
//                 the pipeline stalled for the whole AXI round-trip; traps,
//                 interrupts and mispredicts all resolve here (precise traps)
// - S3 writeback  rd write into the regfile, no-op for everything else
//
// Spec coverage:
//
// - REQ1  the 3-stage pipeline above (Fetch / Decode+Execute / Writeback)
// - REQ2  two AXI4-Lite master ports — ibus (read only), dbus (read + write)
// - REQ3  top interface: one sync clock, async active-low reset, and the PIC
//         lines cpu_irq / cpu_irq_id / cpu_irq_ack / cpu_in_trap
// - REQ4  interrupts sampled only under mstatus.MIE, at instruction
//         boundaries; cpu_irq_ack pulses one cycle; cpu_in_trap held from
//         trap entry until MRET
//
// Design choices:
//
// - D1
//   Pipeline registers carry a valid bit — valid=0 is a guaranteed safe
//   bubble, independent of the NOP encoding.
//   (S3->S2 forwarding removes the load-use stall; the two ports are
//   independent, 1 outstanding each, so a fetch and a load/store can be
//   in flight at once.)
//
// - D2
//   S2 priority: interrupt > sync exception > mispredict, as a sequential
//   check. The interrupt is tested before the instruction issues any data
//   transaction, so a preempted instruction can safely rerun after MRET.
//   Trap/MRET redirects (mtvec/mepc) bypass the predictor.
//
// - D4
//   Trap return address: exceptions -> the offending instruction,
//   interrupts -> the instruction to resume at.
//
// - D5
//   RESET_PC and HART_ID parameters make the core instantiable N times —
//   HART_ID feeds mhartid so software can tell instances apart (beyond
//   spec). A single-core SoC leaves both at 0.

module cpu_top #(
    parameter RESET_PC = 32'h0000_0000,  // reset vector; pending the global memory map
    parameter HART_ID  = 32'd0           // mhartid value; lets 2..N cores share one SoC
)(
    input             clk,
    input             rst_n,             // async reset, active low

    // ibus_axi: AXI4-Lite master, read-only (instruction fetch)
    output     [31:0] ibus_axi_araddr,
    output     [2:0]  ibus_axi_arprot,
    output            ibus_axi_arvalid,
    input             ibus_axi_arready,
    input      [31:0] ibus_axi_rdata,
    input      [1:0]  ibus_axi_rresp,
    input             ibus_axi_rvalid,
    output            ibus_axi_rready,

    // dbus_axi: AXI4-Lite master, read+write (load/store)
    output     [31:0] dbus_axi_awaddr,
    output     [2:0]  dbus_axi_awprot,
    output            dbus_axi_awvalid,
    input             dbus_axi_awready,
    output     [31:0] dbus_axi_wdata,
    output     [3:0]  dbus_axi_wstrb,
    output            dbus_axi_wvalid,
    input             dbus_axi_wready,
    input      [1:0]  dbus_axi_bresp,
    input             dbus_axi_bvalid,
    output            dbus_axi_bready,
    output     [31:0] dbus_axi_araddr,
    output     [2:0]  dbus_axi_arprot,
    output            dbus_axi_arvalid,
    input             dbus_axi_arready,
    input      [31:0] dbus_axi_rdata,
    input      [1:0]  dbus_axi_rresp,
    input             dbus_axi_rvalid,
    output            dbus_axi_rready,

    // PIC interface (see D3)
    input      [7:0]  cpu_irq,
    output reg [7:0]  cpu_irq_ack,
    input      [2:0]  cpu_irq_id,
    output reg        cpu_in_trap
);

// pipeline regs (D1) and S2 results, declared up front because the
// predictor and CSR instances reference them before the S2 section
reg        ifdx_valid_q, ifdx_fault_q, ifdx_ptk_q;
reg [31:0] ifdx_pc_q, ifdx_instr_q, ifdx_ptg_q;

reg        dxwb_valid_q, dxwb_regwrite_q;
reg [4:0]  dxwb_rd_q;
reg [1:0]  dxwb_wbsel_q;
reg [31:0] dxwb_result_q, dxwb_mem_q, dxwb_pc4_q;

wire       ctl_taken_raw, mret_exec;

// S1: fetch + predictor

wire        redirect;
wire [31:0] redirect_pc;
wire        s2_advance, if_dx_we, if_dx_bubble, dx_squash;

wire        f_valid, f_fault, f_ptk;
wire [31:0] f_instr, f_pc, f_ptg;

wire [31:0] bp_lookup_pc, bp_target;
wire        bp_taken;

fetch_unit #(.RESET_PC(RESET_PC)) fetch_unit_inst (
    .clk           (clk),
    .rst_n         (rst_n),
    .ibus_araddr   (ibus_axi_araddr),
    .ibus_arprot   (ibus_axi_arprot),
    .ibus_arvalid  (ibus_axi_arvalid),
    .ibus_arready  (ibus_axi_arready),
    .ibus_rdata    (ibus_axi_rdata),
    .ibus_rresp    (ibus_axi_rresp),
    .ibus_rvalid   (ibus_axi_rvalid),
    .ibus_rready   (ibus_axi_rready),
    .bp_lookup_pc  (bp_lookup_pc),
    .bp_pred_taken (bp_taken),
    .bp_pred_target(bp_target),
    .redirect      (redirect),
    .redirect_pc   (redirect_pc),
    .s2_ready      (s2_advance),
    .instr_valid   (f_valid),
    .instr         (f_instr),
    .instr_pc      (f_pc),
    .pred_taken    (f_ptk),
    .pred_target   (f_ptg),
    .fetch_fault   (f_fault)
);

wire        bp_update_en;
wire [31:0] actual_target;

branch_predictor branch_predictor_inst (
    .clk           (clk),
    .rst_n         (rst_n),
    .lookup_pc     (bp_lookup_pc),
    .pred_taken    (bp_taken),
    .pred_target   (bp_target),
    .update_en     (bp_update_en),
    .update_pc     (ifdx_pc_q),
    .update_taken  (ctl_taken_raw),
    .update_target (actual_target)
);

// IF/DX valid — the only bit that needs a reset; valid=0 makes whatever the
// payload holds a safe bubble (D1)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        ifdx_valid_q <= 1'b0;
    else if (if_dx_we)
        ifdx_valid_q <= ~if_dx_bubble;
end

// IF/DX payload — loads only on a real instruction, so bubbles and stalls
// leave the whole S2 datapath quiet (no reset needed, valid gates it)
always @(posedge clk) begin
    if (if_dx_we && !if_dx_bubble) begin
        ifdx_pc_q    <= f_pc;
        ifdx_instr_q <= f_instr;
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
    .instr  (ifdx_instr_q),
    .opcode (opcode),
    .rd     (rd),
    .funct3 (funct3),
    .rs1    (rs1),
    .rs2    (rs2),
    .funct7 (funct7)
);

imm_gen imm_gen_inst (
    .instr   (ifdx_instr_q),
    .imm_out (imm_out)
);

wire        RegWrite, ALUSrc, MemRead, MemWrite, Branch, Jump;
wire [3:0]  ALUOp;
wire [1:0]  MemtoReg;
wire        csr_instr, csr_imm, ctrl_mret, ctrl_ecall, ctrl_ebreak, ctrl_illegal;
wire [1:0]  csr_op;

control control_inst (
    .opcode    (opcode),
    .funct3    (funct3),
    .funct7    (funct7),
    .rs1       (rs1),
    .rd        (rd),
    .imm12     (ifdx_instr_q[31:20]),
    .RegWrite  (RegWrite),
    .ALUSrc    (ALUSrc),
    .ALUOp     (ALUOp),
    .MemRead   (MemRead),
    .MemWrite  (MemWrite),
    .MemtoReg  (MemtoReg),
    .Branch    (Branch),
    .Jump      (Jump),
    .csr_instr (csr_instr),
    .csr_op    (csr_op),
    .csr_imm   (csr_imm),
    .mret      (ctrl_mret),
    .ecall     (ctrl_ecall),
    .ebreak    (ctrl_ebreak),
    .illegal   (ctrl_illegal)
);

// regfile reads combinationally; the S3 value is bypassed when it targets a
// source reg, since the write only lands on the clock edge (D13)
wire [31:0] rs1_data, rs2_data, wb_data;
wire        fwd_rs1, fwd_rs2;

regfile regfile_inst (
    .clk      (clk),
    .rst_n    (rst_n),
    .rs1_addr (rs1),
    .rs2_addr (rs2),
    .rd_addr  (dxwb_rd_q),
    .rd_data  (wb_data),
    .RegWrite (dxwb_valid_q & dxwb_regwrite_q),
    .rs1_data (rs1_data),
    .rs2_data (rs2_data)
);

wire [31:0] rs1_v = fwd_rs1 ? wb_data : rs1_data;
wire [31:0] rs2_v = fwd_rs2 ? wb_data : rs2_data;

// interrupt check at the instruction boundary, before any data transaction
// goes out (D2, REQ4); lsu_active blocks it for the rest of the op
wire        lsu_busy, lsu_done, lsu_err, lsu_active;
wire        mie_global;
wire [7:0]  irq_enable;

wire irq_take = ifdx_valid_q && !lsu_active && mie_global &&
                cpu_irq[cpu_irq_id] && irq_enable[cpu_irq_id];

// instruction actually executes: not preempted, and the fetch was clean
wire dec_live = ifdx_valid_q && !irq_take && !ifdx_fault_q;

// ALU; AUIPC takes the PC as operand A
wire [31:0] alu_result;
wire        alu_zero;
wire [31:0] alu_opa = (ALUOp == 4'b0100) ? ifdx_pc_q : rs1_v;

alu_top alu_top_inst (
    .operand_a     (alu_opa),
    .operand_b_reg (rs2_v),
    .operand_b_imm (imm_out),
    .ALUSrc        (ALUSrc),
    .ALUOp         (ALUOp),
    .funct3        (funct3),
    .funct7        (funct7),
    .result        (alu_result),
    .zero          (alu_zero)
);

// real direction + target of the control transfer
wire pc_src;

branch_unit branch_unit_inst (
    .pc_in         (ifdx_pc_q),
    .imm_out       (imm_out),
    .rs1_data      (rs1_v),
    .rs2_data      (rs2_v),
    .opcode        (opcode),
    .funct3        (funct3),
    .Branch        (Branch),
    .Jump          (Jump),
    .zero          (alu_zero),
    .branch_target (actual_target),
    .pc_src        (pc_src)
);

assign ctl_taken_raw = dec_live && pc_src;   // pre-exception, feeds trap detect

// CSR: read in S2, write commits on the edge that closes S2
wire [31:0] csr_rdata, trap_vector, mepc_out;
wire        csr_illegal;
wire        csr_ren = dec_live && csr_instr;
// CSRRS/C with rs1=x0 (uimm=0) is a pure read, per RISC-V
wire        csr_wen = csr_ren && (csr_op == 2'b01 || rs1 != 5'b0);
wire [31:0] csr_wdata = csr_imm ? {27'b0, rs1} : rs1_v;

wire        exception;
wire [4:0]  exc_cause;
wire        trap_take = irq_take | exception;
wire [4:0]  trap_code = irq_take ? {2'b10, cpu_irq_id} : exc_cause;  // irq: 16+id

csr_file #(.HART_ID(HART_ID)) csr_file_inst (
    .clk         (clk),
    .rst_n       (rst_n),
    .csr_addr    (ifdx_instr_q[31:20]),
    .csr_wdata   (csr_wdata),
    .csr_op      (csr_op),
    .csr_ren     (csr_ren),
    .csr_wen     (csr_wen),
    .csr_rdata   (csr_rdata),
    .csr_illegal (csr_illegal),
    .trap_set    (trap_take & s2_advance),
    .trap_is_irq (irq_take),
    .trap_code   (trap_code),
    .trap_pc     (ifdx_pc_q),
    .mret        (mret_exec),
    .irq_lines   (cpu_irq),
    .irq_enable  (irq_enable),
    .mie_global  (mie_global),
    .trap_vector (trap_vector),
    .mepc_out    (mepc_out),
    .retire      (dxwb_valid_q)
);

// LSU: issue only for a live, legal, aligned op — an illegal or misaligned
// access must trap without touching the bus (D17)
wire        mem_misaligned;
wire [31:0] lsu_rdata;
wire        lsu_req = dec_live && (MemRead | MemWrite) &&
                      !ctrl_illegal && !mem_misaligned;

lsu lsu_inst (
    .clk          (clk),
    .rst_n        (rst_n),
    .req          (lsu_req),
    .we           (MemWrite),
    .funct3       (funct3),
    .addr         (alu_result),
    .st_data      (rs2_v),
    .busy         (lsu_busy),
    .done         (lsu_done),
    .err          (lsu_err),
    .active       (lsu_active),
    .ld_data      (lsu_rdata),
    .dbus_awaddr  (dbus_axi_awaddr),
    .dbus_awprot  (dbus_axi_awprot),
    .dbus_awvalid (dbus_axi_awvalid),
    .dbus_awready (dbus_axi_awready),
    .dbus_wdata   (dbus_axi_wdata),
    .dbus_wstrb   (dbus_axi_wstrb),
    .dbus_wvalid  (dbus_axi_wvalid),
    .dbus_wready  (dbus_axi_wready),
    .dbus_bresp   (dbus_axi_bresp),
    .dbus_bvalid  (dbus_axi_bvalid),
    .dbus_bready  (dbus_axi_bready),
    .dbus_araddr  (dbus_axi_araddr),
    .dbus_arprot  (dbus_axi_arprot),
    .dbus_arvalid (dbus_axi_arvalid),
    .dbus_arready (dbus_axi_arready),
    .dbus_rdata   (dbus_axi_rdata),
    .dbus_rresp   (dbus_axi_rresp),
    .dbus_rvalid  (dbus_axi_rvalid),
    .dbus_rready  (dbus_axi_rready)
);

exception_unit exception_unit_inst (
    .valid          (ifdx_valid_q && !irq_take),
    .fetch_fault    (ifdx_fault_q),
    .illegal        (ctrl_illegal | csr_illegal),
    .ecall          (ctrl_ecall),
    .ebreak         (ctrl_ebreak),
    .ctl_taken      (ctl_taken_raw),
    .ctl_target     (actual_target),
    .MemRead        (MemRead),
    .MemWrite       (MemWrite),
    .funct3         (funct3),
    .mem_addr       (alu_result),
    .mem_active     (lsu_active),
    .mem_done       (lsu_done),
    .mem_err        (lsu_err),
    .exception      (exception),
    .cause          (exc_cause),
    .mem_misaligned (mem_misaligned)
);

// MRET and mispredict come after interrupt/exception in priority (D2)
assign mret_exec = dec_live && ctrl_mret;
wire ctl_taken  = ctl_taken_raw && !exception;
wire mispredict = dec_live && !exception && !ctrl_mret &&
                  ((ifdx_ptk_q != ctl_taken) ||
                   (ctl_taken && (ifdx_ptg_q != actual_target)));

// predictor learns every committed branch/jump at resolution (D11)
assign bp_update_en = dec_live && (Branch | Jump) && !exception && s2_advance;

// one shared PC+4 adder for S2: mispredict fall-through and the JAL/JALR
// link value are the same number
wire [31:0] s2_pc4 = ifdx_pc_q + 32'd4;

// redirect target: trap > MRET > corrected path after a mispredict
assign redirect_pc = trap_take ? trap_vector :
                     mret_exec ? mepc_out    :
                     ctl_taken ? actual_target : s2_pc4;

hazard_unit hazard_unit_inst (
    .fetch_valid  (f_valid),
    .lsu_busy     (lsu_busy),
    .trap_take    (trap_take),
    .mret_exec    (mret_exec),
    .mispredict   (mispredict),
    .rs1          (rs1),
    .rs2          (rs2),
    .wb_valid     (dxwb_valid_q),
    .wb_reg_write (dxwb_regwrite_q),
    .wb_rd        (dxwb_rd_q),
    .s2_advance   (s2_advance),
    .redirect     (redirect),
    .if_dx_we     (if_dx_we),
    .if_dx_bubble (if_dx_bubble),
    .dx_squash    (dx_squash),
    .fwd_rs1      (fwd_rs1),
    .fwd_rs2      (fwd_rs2)
);

// ack pulses one cycle at acceptance (REQ4)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        cpu_irq_ack <= 8'b0;
    else
        cpu_irq_ack <= (irq_take && s2_advance) ? (8'h01 << cpu_irq_id) : 8'b0;
end

// cpu_in_trap holds until MRET; a nested sync trap inside the handler keeps
// it asserted (REQ4)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        cpu_in_trap <= 1'b0;
    else if (trap_take && s2_advance)
        cpu_in_trap <= 1'b1;
    else if (mret_exec && s2_advance)
        cpu_in_trap <= 1'b0;
end

// DX/WB valid — trap squash: the offending instruction never commits (D3);
// while S2 stalls, S3 gets bubbles so nothing commits twice
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        dxwb_valid_q <= 1'b0;
    else if (s2_advance)
        dxwb_valid_q <= ifdx_valid_q && !dx_squash;
    else
        dxwb_valid_q <= 1'b0;
end

// DX/WB payload — captured only when a real instruction leaves S2. Bubbles
// don't touch these ~130 flops (everything downstream is gated by valid),
// which also means no reset is needed here.
always @(posedge clk) begin
    if (s2_advance && ifdx_valid_q) begin
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
    .alu_result (dxwb_result_q),
    .mem_data   (dxwb_mem_q),
    .pc_plus4   (dxwb_pc4_q),
    .csr_data   (dxwb_result_q),
    .MemtoReg   (dxwb_wbsel_q),
    .wb_data    (wb_data)
);

endmodule
