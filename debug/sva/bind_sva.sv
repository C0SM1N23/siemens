// Functional-coverage bind for the CPU block flow.
//
// The assertion binds live in bind_core_sva.sv, which the SoC flow compiles as
// well. This file is only the coverage instance: its bins are calibrated for
// cpu/debug/sim/program_axi.s, so it belongs to the run that executes that
// program and nowhere else.

`timescale 1ns/1ps

// functional coverage
bind cpu_top cpu_func_cov func_cov_i (
    .clk_i         (clk_i),
    .rst_n_i       (rst_n_i),
    .valid_i       (ifdx_valid_q),
    .instr_i       (ifdx_instr_q),
    .pred_taken_i  (ifdx_ptk_q),
    .s2_advance_i  (s2_advance),
    .trap_take_i   (trap_take),
    .trap_code_i   (trap_code),
    .irq_take_i    (irq_take),
    .mispredict_i  (mispredict),
    .branch_i      (Branch),
    .jump_i        (Jump),
    .ctl_taken_i   (ctl_taken),
    .csr_instr_i   (csr_instr),
    .csr_op_i      (csr_op),
    .csr_imm_i     (csr_imm),
    .csr_wen_i     (csr_wen),
    .mret_exec_i   (mret_exec),
    .fwd_rs1_i     (fwd_rs1),
    .fwd_rs2_i     (fwd_rs2),
    .lsu_active_i  (lsu_active),
    .ctrl_wfi_i    (ctrl_wfi),
    .wfi_wait_i    (wfi_wait),
    .ras_push_i    (ras_push),
    .ras_pop_i     (ras_pop),
    .cpu_irq_i     (cpu_irq_i),
    .cpu_irq_vec_i (cpu_irq_vec_i),
    .cpu_irq_ack_i (cpu_irq_ack_o),
    .ib_arvalid_i  (ibus_axi_arvalid_o),
    .ib_arready_i  (ibus_axi_arready_i),
    .ib_rvalid_i   (ibus_axi_rvalid_i),
    .ib_rready_i   (ibus_axi_rready_o),
    .ib_rresp_i    (ibus_axi_rresp_i),
    .db_arvalid_i  (dbus_axi_arvalid_o),
    .db_arready_i  (dbus_axi_arready_i),
    .db_rvalid_i   (dbus_axi_rvalid_i),
    .db_rready_i   (dbus_axi_rready_o),
    .db_rresp_i    (dbus_axi_rresp_i),
    .db_bvalid_i   (dbus_axi_bvalid_i),
    .db_bready_i   (dbus_axi_bready_o),
    .db_bresp_i    (dbus_axi_bresp_i)
);
