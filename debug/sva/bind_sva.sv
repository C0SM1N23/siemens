// Bind file — attaches the SVA/coverage modules to the RTL without touching
// it. Compile this last (after the RTL and the sva modules). Every instance
// of cpu_top / pic in the design gets its own copy of the checkers, so the
// dual-core bench is covered for free if it is ever run through this flow.
//
// The port maps reference cpu_top/pic internal signals by name — that is the
// point of bind: the checkers see the design's own wires, the design never
// sees the checkers.

// AXI4-Lite protocol on the instruction port (read-only, PC is word-aligned)
`timescale 1ns/1ps

bind cpu_top axi_lite_sva #(
    .NAME("ibus"), .HAS_WRITE(0), .CHECK_ALIGN(1)
) ibus_sva_i (
    .clk     (clk),
    .rst_n   (rst_n),
    .awaddr  (32'b0),
    .awvalid (1'b0),
    .awready (1'b0),
    .wdata   (32'b0),
    .wstrb   (4'b0),
    .wvalid  (1'b0),
    .wready  (1'b0),
    .bresp   (2'b0),
    .bvalid  (1'b0),
    .bready  (1'b0),
    .araddr  (ibus_axi_araddr),
    .arvalid (ibus_axi_arvalid),
    .arready (ibus_axi_arready),
    .rdata   (ibus_axi_rdata),
    .rresp   (ibus_axi_rresp),
    .rvalid  (ibus_axi_rvalid),
    .rready  (ibus_axi_rready)
);

// AXI4-Lite protocol on the data port (byte addresses are legal here)
bind cpu_top axi_lite_sva #(
    .NAME("dbus"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) dbus_sva_i (
    .clk     (clk),
    .rst_n   (rst_n),
    .awaddr  (dbus_axi_awaddr),
    .awvalid (dbus_axi_awvalid),
    .awready (dbus_axi_awready),
    .wdata   (dbus_axi_wdata),
    .wstrb   (dbus_axi_wstrb),
    .wvalid  (dbus_axi_wvalid),
    .wready  (dbus_axi_wready),
    .bresp   (dbus_axi_bresp),
    .bvalid  (dbus_axi_bvalid),
    .bready  (dbus_axi_bready),
    .araddr  (dbus_axi_araddr),
    .arvalid (dbus_axi_arvalid),
    .arready (dbus_axi_arready),
    .rdata   (dbus_axi_rdata),
    .rresp   (dbus_axi_rresp),
    .rvalid  (dbus_axi_rvalid),
    .rready  (dbus_axi_rready)
);

// AXI4-Lite protocol on the PIC's slave port (checks the PIC's slave side
// and, through it, whatever fabric leg drives it)
bind pic axi_lite_sva #(
    .NAME("pic_s"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) pic_port_sva_i (
    .clk     (clk),
    .rst_n   (rst_n),
    .awaddr  (s_axi_awaddr),
    .awvalid (s_axi_awvalid),
    .awready (s_axi_awready),
    .wdata   (s_axi_wdata),
    .wstrb   (s_axi_wstrb),
    .wvalid  (s_axi_wvalid),
    .wready  (s_axi_wready),
    .bresp   (s_axi_bresp),
    .bvalid  (s_axi_bvalid),
    .bready  (s_axi_bready),
    .araddr  (s_axi_araddr),
    .arvalid (s_axi_arvalid),
    .arready (s_axi_arready),
    .rdata   (s_axi_rdata),
    .rresp   (s_axi_rresp),
    .rvalid  (s_axi_rvalid),
    .rready  (s_axi_rready)
);

// CPU pipeline invariants
bind cpu_top cpu_core_sva core_sva_i (
    .clk          (clk),
    .rst_n        (rst_n),
    .cpu_irq_ack  (cpu_irq_ack),
    .cpu_irq_eoi  (cpu_irq_eoi),
    .cpu_in_trap  (cpu_in_trap),
    .irq_take     (irq_take),
    .trap_take    (trap_take),
    .mret_exec    (mret_exec),
    .s2_advance   (s2_advance),
    .lsu_active   (lsu_active),
    .dxwb_valid   (dxwb_valid_q),
    .rs1          (rs1),
    .rs2          (rs2),
    .rs1_data     (rs1_data),
    .rs2_data     (rs2_data),
    .dbus_awvalid (dbus_axi_awvalid),
    .dbus_wvalid  (dbus_axi_wvalid),
    .dbus_wstrb   (dbus_axi_wstrb),
    .dbus_arvalid (dbus_axi_arvalid),
    .wfi_wait     (wfi_wait),
    .ib_arvalid   (ibus_axi_arvalid),
    .ib_arready   (ibus_axi_arready)
);

// AXI4-Lite protocol on the mtimer's slave port (D27)
bind mtimer axi_lite_sva #(
    .NAME("tmr_s"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) tmr_port_sva_i (
    .clk     (clk),
    .rst_n   (rst_n),
    .awaddr  (s_axi_awaddr),
    .awvalid (s_axi_awvalid),
    .awready (s_axi_awready),
    .wdata   (s_axi_wdata),
    .wstrb   (s_axi_wstrb),
    .wvalid  (s_axi_wvalid),
    .wready  (s_axi_wready),
    .bresp   (s_axi_bresp),
    .bvalid  (s_axi_bvalid),
    .bready  (s_axi_bready),
    .araddr  (s_axi_araddr),
    .arvalid (s_axi_arvalid),
    .arready (s_axi_arready),
    .rdata   (s_axi_rdata),
    .rresp   (s_axi_rresp),
    .rvalid  (s_axi_rvalid),
    .rready  (s_axi_rready)
);

// PIC invariants
bind pic pic_sva pic_sva_i (
    .clk         (clk),
    .rst_n       (rst_n),
    .irq_src     (irq_src),
    .cpu_irq     (cpu_irq),
    .cpu_irq_vec (cpu_irq_vec),
    .cpu_irq_ack (cpu_irq_ack),
    .cpu_irq_eoi (cpu_irq_eoi),
    // internals
    .offer_val   (offer_val),
    .res_id      (res_id),
    .res_key     (res_key),
    .req         (req),
    .active      (active),
    .depth       (depth),
    .nest_max    (nest_max),
    .has_active  (has_active),
    .top_key     (top_key),
    .claim_push  (claim_push),
    .eoi_pop     (eoi_pop)
);

// functional coverage
bind cpu_top cpu_func_cov func_cov_i (
    .clk         (clk),
    .rst_n       (rst_n),
    .valid       (ifdx_valid_q),
    .instr       (ifdx_instr_q),
    .pred_taken  (ifdx_ptk_q),
    .s2_advance  (s2_advance),
    .trap_take   (trap_take),
    .trap_code   (trap_code),
    .irq_take    (irq_take),
    .mispredict  (mispredict),
    .branch      (Branch),
    .jump        (Jump),
    .ctl_taken   (ctl_taken),
    .csr_instr   (csr_instr),
    .csr_op      (csr_op),
    .csr_imm     (csr_imm),
    .csr_wen     (csr_wen),
    .mret_exec   (mret_exec),
    .fwd_rs1     (fwd_rs1),
    .fwd_rs2     (fwd_rs2),
    .lsu_active  (lsu_active),
    .ctrl_wfi    (ctrl_wfi),
    .wfi_wait    (wfi_wait),
    .ras_push    (ras_push),
    .ras_pop     (ras_pop),
    .cpu_irq     (cpu_irq),
    .cpu_irq_vec (cpu_irq_vec),
    .cpu_irq_ack (cpu_irq_ack),
    .ib_arvalid  (ibus_axi_arvalid),
    .ib_arready  (ibus_axi_arready),
    .ib_rvalid   (ibus_axi_rvalid),
    .ib_rready   (ibus_axi_rready),
    .ib_rresp    (ibus_axi_rresp),
    .db_arvalid  (dbus_axi_arvalid),
    .db_arready  (dbus_axi_arready),
    .db_rvalid   (dbus_axi_rvalid),
    .db_rready   (dbus_axi_rready),
    .db_rresp    (dbus_axi_rresp),
    .db_bvalid   (dbus_axi_bvalid),
    .db_bready   (dbus_axi_bready),
    .db_bresp    (dbus_axi_bresp)
);
