// Pipeline control: advance, stall, flush and S3-to-S2 forwarding.
// LSU activity and WFI stall S2. Trap/MRET/mispredict redirects discard younger work.
// While S2 stalls, S3 receives bubbles so an instruction cannot write back twice.

module rv32i_hazard_unit (
    // pipeline state
    input fetch_valid_i,  // S1 offers an instruction this cycle
    input lsu_busy_i,     // data AXI op still in flight in S2
    input wfi_wait_i,     // WFI in S2, no wake condition yet (D23)

    // redirect_o requests resolved in S2
    input trap_take_i,  // sync exception or accepted interrupt
    input mret_exec_i,
    input mispredict_i,

    // S3 -> S2 forwarding detect
    input [4:0] rs1_i,
    input [4:0] rs2_i,
    input       wb_valid_i,
    input       wb_reg_write_i,
    input [4:0] wb_rd_i,

    // per-stage commands
    output s2_advance_o,    // S2 finishes its instruction this cycle
    output redirect_o,      // fetch changes path; S1 content dropped
    output if_dx_we_o,      // IF/DX loads (new instruction or bubble)
    output if_dx_bubble_o,  // what it loads is a bubble
    output dx_squash_o,     // S2 instruction must not commit to S3
    output fwd_rs1_o,
    output fwd_rs2_o
);

    assign s2_advance_o   = ~lsu_busy_i & ~wfi_wait_i;
    assign redirect_o     = (trap_take_i | mret_exec_i | mispredict_i) & s2_advance_o;
    assign if_dx_we_o     = s2_advance_o;
    assign if_dx_bubble_o = redirect_o | ~fetch_valid_i;
    assign dx_squash_o    = trap_take_i;

    // bypass when the S3 instruction writes a register S2 is reading (x0 excluded)
    assign fwd_rs1_o      = wb_valid_i & wb_reg_write_i & (wb_rd_i != 5'd0) & (wb_rd_i == rs1_i);
    assign fwd_rs2_o      = wb_valid_i & wb_reg_write_i & (wb_rd_i != 5'd0) & (wb_rd_i == rs2_i);

endmodule
