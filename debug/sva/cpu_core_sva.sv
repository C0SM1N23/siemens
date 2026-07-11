// CPU pipeline invariants (SVA) — bound into cpu_top, verification only.
//
// Each assertion states one architectural promise from the README/ARCHITECTURE,
// so a passing regression proves the promise, not just the test program:
// - REQ4:  cpu_irq_ack is a one-cycle one-hot pulse; cpu_in_trap rises with it, holds to MRET
// - D2:    an interrupt is accepted only at an instruction boundary, never mid data transaction
// - D3:    a trapping instruction never commits (precise traps)
// - REQ10: x0 reads zero on both register-file ports
// - REQ11: WSTRB is one of the SB/SH/SW shapes — the DP-SRAM byte-lane contract
// - D12:   the dbus never carries a read and a write at once
//
// Bound from bind_sva.sv — no RTL is touched.

module cpu_core_sva (
    input        clk,
    input        rst_n,

    // PIC interface (cpu_top ports)
    input [7:0]  cpu_irq_ack,
    input        cpu_in_trap,

    // S2 control (cpu_top internals, wired up by the bind)
    input        irq_take,
    input        trap_take,
    input        mret_exec,
    input        s2_advance,
    input        lsu_active,
    input        dxwb_valid,

    // register file read ports
    input [4:0]  rs1,
    input [4:0]  rs2,
    input [31:0] rs1_data,
    input [31:0] rs2_data,

    // dbus write shape
    input        dbus_awvalid,
    input        dbus_wvalid,
    input [3:0]  dbus_wstrb,
    input        dbus_arvalid,

    // WFI sleep (D23)
    input        wfi_wait,
    input        ib_arvalid,
    input        ib_arready
);

// --- interrupt interface shape (REQ4) ---

ack_onehot: assert property (@(posedge clk) disable iff (!rst_n)
    $onehot0(cpu_irq_ack))
    else $error("[core] cpu_irq_ack not one-hot");

ack_pulse: assert property (@(posedge clk) disable iff (!rst_n)
    |cpu_irq_ack |=> cpu_irq_ack == 8'b0)
    else $error("[core] cpu_irq_ack longer than one cycle");

ack_in_trap: assert property (@(posedge clk) disable iff (!rst_n)
    |cpu_irq_ack |-> cpu_in_trap)
    else $error("[core] ack without cpu_in_trap");

// --- interrupts only at instruction boundaries (D2, REQ4) ---

irq_at_boundary: assert property (@(posedge clk) disable iff (!rst_n)
    irq_take |-> !lsu_active)
    else $error("[core] interrupt taken mid data transaction");

ack_not_in_stall: assert property (@(posedge clk) disable iff (!rst_n)
    |cpu_irq_ack |-> !lsu_active)
    else $error("[core] ack while a data transaction is active");

// --- trap entry / return sequencing (REQ4, D3) ---

trap_sets_in_trap: assert property (@(posedge clk) disable iff (!rst_n)
    trap_take && s2_advance |=> cpu_in_trap)
    else $error("[core] trap entry did not raise cpu_in_trap");

mret_clears_in_trap: assert property (@(posedge clk) disable iff (!rst_n)
    mret_exec && s2_advance && !trap_take |=> !cpu_in_trap)
    else $error("[core] MRET did not drop cpu_in_trap");

in_trap_holds: assert property (@(posedge clk) disable iff (!rst_n)
    cpu_in_trap && !(mret_exec && s2_advance) |=> cpu_in_trap)
    else $error("[core] cpu_in_trap dropped without MRET");

trap_squashes_commit: assert property (@(posedge clk) disable iff (!rst_n)
    trap_take && s2_advance |=> !dxwb_valid)
    else $error("[core] trapping instruction reached writeback");

// --- pipeline motion: a stalled S2 feeds S3 bubbles (REQ5, D1) ---

stall_bubbles_s3: assert property (@(posedge clk) disable iff (!rst_n)
    !s2_advance |=> !dxwb_valid)
    else $error("[core] S3 got a valid instr while S2 was stalled");

// --- register file: x0 hardwired to zero (REQ10) ---

x0_reads_zero_rs1: assert property (@(posedge clk) disable iff (!rst_n)
    rs1 == 5'b0 |-> rs1_data == 32'b0)
    else $error("[core] x0 read non-zero on rs1 port");

x0_reads_zero_rs2: assert property (@(posedge clk) disable iff (!rst_n)
    rs2 == 5'b0 |-> rs2_data == 32'b0)
    else $error("[core] x0 read non-zero on rs2 port");

// --- dbus usage: WSTRB shapes (REQ11) and one direction at a time (D12) ---

wstrb_shape: assert property (@(posedge clk) disable iff (!rst_n)
    dbus_wvalid |-> dbus_wstrb inside
        {4'b0001, 4'b0010, 4'b0100, 4'b1000,   // SB, any lane
         4'b0011, 4'b1100,                     // SH, low/high half
         4'b1111})                             // SW
    else $error("[core] WSTRB not an SB/SH/SW lane pattern");

no_simultaneous_rw: assert property (@(posedge clk) disable iff (!rst_n)
    !(dbus_arvalid && (dbus_awvalid || dbus_wvalid)))
    else $error("[core] dbus read and write issued together");

// --- WFI silence (D23): one sleep window may complete at most the one
// --- fetch that was already in flight; a *second* AR handshake means the
// --- core kept fetching while supposedly asleep

reg wfi_ar_seen_q;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        wfi_ar_seen_q <= 1'b0;
    else if (!wfi_wait)
        wfi_ar_seen_q <= 1'b0;
    else if (ib_arvalid && ib_arready)
        wfi_ar_seen_q <= 1'b1;
end

wfi_ibus_quiet: assert property (@(posedge clk) disable iff (!rst_n)
    wfi_wait && wfi_ar_seen_q |-> !(ib_arvalid && ib_arready))
    else $error("[core] new ibus fetch issued while WFI sleeping");

endmodule
