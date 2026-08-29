// Assertion binds shared by the CPU flow and the SoC flow.
//
// Split out of bind_sva.sv so the SoC regression runs the same CPU and PIC
// checkers the block regression does. Before the split the SoC flow compiled
// only axi_lite_sva and bound nothing from here, so cpu_core_sva and pic_sva
// were dark in every SoC run while soc_bind_sva.sv's header claimed otherwise.
//
// Only assertions live here. The functional-coverage bind stays in
// bind_sva.sv, because its gate is calibrated for the CPU block's own program
// and would report a miss against any other stimulus.
//
`timescale 1ns/1ps

bind cpu_top axi_lite_sva #(
    .NAME("ibus"), .HAS_WRITE(0), .CHECK_ALIGN(1)
) ibus_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  (32'b0),
    .awvalid_i (1'b0),
    .awready_i (1'b0),
    .wdata_i   (32'b0),
    .wstrb_i   (4'b0),
    .wvalid_i  (1'b0),
    .wready_i  (1'b0),
    .bresp_i   (2'b0),
    .bvalid_i  (1'b0),
    .bready_i  (1'b0),
    .araddr_i  (ibus_axi_araddr_o),
    .arvalid_i (ibus_axi_arvalid_o),
    .arready_i (ibus_axi_arready_i),
    .rdata_i   (ibus_axi_rdata_i),
    .rresp_i   (ibus_axi_rresp_i),
    .rvalid_i  (ibus_axi_rvalid_i),
    .rready_i  (ibus_axi_rready_o)
);

// AXI4-Lite protocol on the data port (byte addresses are legal here)
bind cpu_top axi_lite_sva #(
    .NAME("dbus"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) dbus_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  (dbus_axi_awaddr_o),
    .awvalid_i (dbus_axi_awvalid_o),
    .awready_i (dbus_axi_awready_i),
    .wdata_i   (dbus_axi_wdata_o),
    .wstrb_i   (dbus_axi_wstrb_o),
    .wvalid_i  (dbus_axi_wvalid_o),
    .wready_i  (dbus_axi_wready_i),
    .bresp_i   (dbus_axi_bresp_i),
    .bvalid_i  (dbus_axi_bvalid_i),
    .bready_i  (dbus_axi_bready_o),
    .araddr_i  (dbus_axi_araddr_o),
    .arvalid_i (dbus_axi_arvalid_o),
    .arready_i (dbus_axi_arready_i),
    .rdata_i   (dbus_axi_rdata_i),
    .rresp_i   (dbus_axi_rresp_i),
    .rvalid_i  (dbus_axi_rvalid_i),
    .rready_i  (dbus_axi_rready_o)
);

// AXI4-Lite protocol on the PIC's slave port (checks the PIC's slave side
// and, through it, whatever fabric leg drives it)
bind pic axi_lite_sva #(
    .NAME("pic_s"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) pic_port_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  (s_axi_awaddr_i),
    .awvalid_i (s_axi_awvalid_i),
    .awready_i (s_axi_awready_o),
    .wdata_i   (s_axi_wdata_i),
    .wstrb_i   (s_axi_wstrb_i),
    .wvalid_i  (s_axi_wvalid_i),
    .wready_i  (s_axi_wready_o),
    .bresp_i   (s_axi_bresp_o),
    .bvalid_i  (s_axi_bvalid_o),
    .bready_i  (s_axi_bready_i),
    .araddr_i  (s_axi_araddr_i),
    .arvalid_i (s_axi_arvalid_i),
    .arready_i (s_axi_arready_o),
    .rdata_i   (s_axi_rdata_o),
    .rresp_i   (s_axi_rresp_o),
    .rvalid_i  (s_axi_rvalid_o),
    .rready_i  (s_axi_rready_i)
);

// CPU pipeline invariants
bind cpu_top cpu_core_sva core_sva_i (
    .clk_i          (clk_i),
    .rst_n_i        (rst_n_i),
    .cpu_irq_ack_i  (cpu_irq_ack_o),
    .cpu_irq_eoi_i  (cpu_irq_eoi_o),
    .cpu_in_trap_i  (cpu_in_trap_o),
    .irq_take_i     (irq_take),
    .trap_take_i    (trap_take),
    .mret_exec_i    (mret_exec),
    .s2_advance_i   (s2_advance),
    .lsu_active_i   (lsu_active),
    .dxwb_valid_i   (dxwb_valid_q),
    .rs1_i          (rs1),
    .rs2_i          (rs2),
    .rs1_data_i     (rs1_data),
    .rs2_data_i     (rs2_data),
    .dbus_awvalid_i (dbus_axi_awvalid_o),
    .dbus_wvalid_i  (dbus_axi_wvalid_o),
    .dbus_wstrb_i   (dbus_axi_wstrb_o),
    .dbus_arvalid_i (dbus_axi_arvalid_o),
    .wfi_wait_i     (wfi_wait),
    .ib_arvalid_i   (ibus_axi_arvalid_o),
    .ib_arready_i   (ibus_axi_arready_i)
);

// AXI4-Lite protocol on the mtimer's slave port (D27)
bind mtimer axi_lite_sva #(
    .NAME("tmr_s"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) tmr_port_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  (s_axi_awaddr_i),
    .awvalid_i (s_axi_awvalid_i),
    .awready_i (s_axi_awready_o),
    .wdata_i   (s_axi_wdata_i),
    .wstrb_i   (s_axi_wstrb_i),
    .wvalid_i  (s_axi_wvalid_i),
    .wready_i  (s_axi_wready_o),
    .bresp_i   (s_axi_bresp_o),
    .bvalid_i  (s_axi_bvalid_o),
    .bready_i  (s_axi_bready_i),
    .araddr_i  (s_axi_araddr_i),
    .arvalid_i (s_axi_arvalid_i),
    .arready_i (s_axi_arready_o),
    .rdata_i   (s_axi_rdata_o),
    .rresp_i   (s_axi_rresp_o),
    .rvalid_i  (s_axi_rvalid_o),
    .rready_i  (s_axi_rready_i)
);

// PIC invariants
bind pic pic_sva pic_sva_i (
    .clk_i         (clk_i),
    .rst_n_i       (rst_n_i),
    .irq_src_i     (irq_src_i),
    .cpu_irq_i     (cpu_irq_o),
    .cpu_irq_vec_i (cpu_irq_vec_o),
    .cpu_irq_ack_i (cpu_irq_ack_i),
    .cpu_irq_eoi_i (cpu_irq_eoi_i),
    // internals
    .offer_val_i   (offer_val),
    .res_id_i      (res_id),
    .res_key_i     (res_key),
    .req_i         (req),
    .cpu_mask_i    (cpu_mask_i),
    .active_i      (active),
    .depth_i       (depth),
    .nest_max_i    (nest_max),
    .has_active_i  (has_active),
    .top_key_i     (top_key),
    .claim_push_i  (claim_push),
    .eoi_pop_i     (eoi_pop)
);

