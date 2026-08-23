// CPU pipeline invariants (SVA) — bound into cpu_top, verification only.
//
// Each assertion states one architectural promise from the README/ARCHITECTURE,
// so a passing regression proves the promise, not just the test program:
// - REQ4:  cpu_irq_ack_i is a one-cycle claim pulse; cpu_irq_eoi_i a one-cycle return pulse;
//          cpu_in_trap_i rises with the claim and holds to MRET
// - D2:    an interrupt is accepted only at an instruction boundary, never mid data transaction
// - D3:    a trapping instruction never commits (precise traps)
// - REQ10: x0 reads zero on both register-file ports
// - REQ11: WSTRB is one of the SB/SH/SW shapes — the DP-SRAM byte-lane contract
// - D12:   the dbus never carries a read and a write at once
//
// Bound from bind_sva.sv — no RTL is touched.

`timescale 1ns/1ps

module cpu_core_sva (
    input        clk_i,
    input        rst_n_i,

    // PIC interface (cpu_top ports)
    input        cpu_irq_ack_i,
    input        cpu_irq_eoi_i,
    input        cpu_in_trap_i,

    // S2 control (cpu_top internals, wired up by the bind)
    input        irq_take_i,
    input        trap_take_i,
    input        mret_exec_i,
    input        s2_advance_i,
    input        lsu_active_i,
    input        dxwb_valid_i,

    // register file read ports
    input [4:0]  rs1_i,
    input [4:0]  rs2_i,
    input [31:0] rs1_data_i,
    input [31:0] rs2_data_i,

    // dbus write shape
    input        dbus_awvalid_i,
    input        dbus_wvalid_i,
    input [3:0]  dbus_wstrb_i,
    input        dbus_arvalid_i,

    // WFI sleep (D23)
    input        wfi_wait_i,
    input        ib_arvalid_i,
    input        ib_arready_i
);

// --- interrupt interface shape (REQ4) ---

ack_pulse: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    cpu_irq_ack_i |=> !cpu_irq_ack_i)
    else $error("[core] cpu_irq_ack_i longer than one cycle");

ack_in_trap: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    cpu_irq_ack_i |-> cpu_in_trap_i)
    else $error("[core] ack without cpu_in_trap_i");

// eoi is a one-cycle pulse that only follows an interrupt-returning MRET
eoi_pulse: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    cpu_irq_eoi_i |=> !cpu_irq_eoi_i)
    else $error("[core] cpu_irq_eoi_i longer than one cycle");

eoi_after_mret: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    cpu_irq_eoi_i |-> $past(mret_exec_i && s2_advance_i))
    else $error("[core] cpu_irq_eoi_i without a returning MRET");

// --- interrupts only at instruction boundaries (D2, REQ4) ---

irq_at_boundary: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    irq_take_i |-> !lsu_active_i)
    else $error("[core] interrupt taken mid data transaction");

ack_not_in_stall: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    cpu_irq_ack_i |-> !lsu_active_i)
    else $error("[core] ack while a data transaction is active");

// --- trap entry / return sequencing (REQ4, D3) ---

trap_sets_in_trap: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    trap_take_i && s2_advance_i |=> cpu_in_trap_i)
    else $error("[core] trap entry did not raise cpu_in_trap_i");

mret_clears_in_trap: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    mret_exec_i && s2_advance_i && !trap_take_i |=> !cpu_in_trap_i)
    else $error("[core] MRET did not drop cpu_in_trap_i");

in_trap_holds: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    cpu_in_trap_i && !(mret_exec_i && s2_advance_i) |=> cpu_in_trap_i)
    else $error("[core] cpu_in_trap_i dropped without MRET");

trap_squashes_commit: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    trap_take_i && s2_advance_i |=> !dxwb_valid_i)
    else $error("[core] trapping instruction reached writeback");

// --- pipeline motion: a stalled S2 feeds S3 bubbles (REQ5, D1) ---

stall_bubbles_s3: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    !s2_advance_i |=> !dxwb_valid_i)
    else $error("[core] S3 got a valid instr while S2 was stalled");

// --- register file: x0 hardwired to zero (REQ10) ---

x0_reads_zero_rs1: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rs1_i == 5'b0 |-> rs1_data_i == 32'b0)
    else $error("[core] x0 read non-zero on rs1_i port");

x0_reads_zero_rs2: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    rs2_i == 5'b0 |-> rs2_data_i == 32'b0)
    else $error("[core] x0 read non-zero on rs2_i port");

// --- dbus usage: WSTRB shapes (REQ11) and one direction at a time (D12) ---

wstrb_shape: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    dbus_wvalid_i |-> dbus_wstrb_i inside
        {4'b0001, 4'b0010, 4'b0100, 4'b1000,   // SB, any lane
         4'b0011, 4'b1100,                     // SH, low/high half
         4'b1111})                             // SW
    else $error("[core] WSTRB not an SB/SH/SW lane pattern");

no_simultaneous_rw: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    !(dbus_arvalid_i && (dbus_awvalid_i || dbus_wvalid_i)))
    else $error("[core] dbus read and write issued together");

// --- WFI silence (D23): one sleep window may complete at most the one
// --- fetch that was already in flight; a *second* AR handshake means the
// --- core kept fetching while supposedly asleep

reg wfi_ar_seen_q;
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        wfi_ar_seen_q <= 1'b0;
    else if (!wfi_wait_i)
        wfi_ar_seen_q <= 1'b0;
    else if (ib_arvalid_i && ib_arready_i)
        wfi_ar_seen_q <= 1'b1;
end

wfi_ibus_quiet: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    wfi_wait_i && wfi_ar_seen_q |-> !(ib_arvalid_i && ib_arready_i))
    else $error("[core] new ibus fetch issued while WFI sleeping");

endmodule
