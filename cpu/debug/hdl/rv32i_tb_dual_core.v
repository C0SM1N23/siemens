// Dual-core smoke test: the "2-3 cores in a bigger SoC" scenario in miniature.
//
// Setup: two cpu_top instances (HART_ID 0 and 1) with private instruction
// memories running the same binary, one shared data memory behind a 2:1 arbiter,
// and a protocol monitor on the arbitrated link.
//
// The program splits on mhartid (each core takes a different path), the cores
// complete a flag handshake through the shared memory, and each leaves its own
// result word; the TB checks both plus the flags.
//
// Why this proves scalability: the core is instantiable with no shared state,
// mhartid differentiates the software paths, and two blocking AXI4-Lite masters
// make progress through one arbitrated slave with no deadlock or corruption.
// Each core is in-order with blocking memory ops (sequentially consistent), so
// no LR/SC is needed.

// AXI4-Lite wiring macros, shared with tb_cpu_axi
`timescale 1ns/1ps

`include "axi_lite_macros.vh"

module tb_dual_core;

wire clk, rst_n;

ck_rst_tb #(.CK_SEMIPERIOD(5)) ck_rst_inst (
    .clk_o   (clk),
    .rst_n_o (rst_n)
);

// per-core ibus/dbus bundles; s = the shared bus behind the arbiter
`AXIL_RD_WIRES(ib0);
`AXIL_RD_WIRES(ib1);
`AXIL_WIRES(db0);
`AXIL_WIRES(db1);
`AXIL_WIRES(s);

wire        ack    [0:1];
wire        eoi    [0:1];
wire        intrap [0:1];

// no PIC in the dual-core bench: the interrupt inputs are tied off
cpu_top #(.HART_ID(0)) cpu0 (
    .clk_i         (clk),
    .rst_n_i       (rst_n),
    `AXIL_MST_RD(ibus_axi, ib0),
    `AXIL_MST(dbus_axi, db0),
    .cpu_irq_i     (1'b0),
    .cpu_irq_vec_i (4'b0),
    .irq_pending_i (16'b0),
    .irq_mask_o    (),
    .cpu_irq_ack_o (ack[0]),
    .cpu_irq_eoi_o (eoi[0]),
    .cpu_in_trap_o (intrap[0])
);

cpu_top #(.HART_ID(1)) cpu1 (
    .clk_i         (clk),
    .rst_n_i       (rst_n),
    `AXIL_MST_RD(ibus_axi, ib1),
    `AXIL_MST(dbus_axi, db1),
    .cpu_irq_i     (1'b0),
    .cpu_irq_vec_i (4'b0),
    .irq_pending_i (16'b0),
    .irq_mask_o    (),
    .cpu_irq_ack_o (ack[1]),
    .cpu_irq_eoi_o (eoi[1]),
    .cpu_in_trap_o (intrap[1])
);

// private instruction memories, same binary in both
axi_lite_mem_model #(
    .WORDS(256), .BASE(32'h0000_0000), .INIT_FILE("program_dual.hex"),
    .READ_LAT(0)
) imem0 (
    .clk_i(clk), .rst_n_i(rst_n),
    `AXIL_BARE_WR_TIEOFF,
    `AXIL_BARE_RD_SLV(ib0)
);

axi_lite_mem_model #(
    .WORDS(256), .BASE(32'h0000_0000), .INIT_FILE("program_dual.hex"),
    .READ_LAT(0)
) imem1 (
    .clk_i(clk), .rst_n_i(rst_n),
    `AXIL_BARE_WR_TIEOFF,
    `AXIL_BARE_RD_SLV(ib1)
);

// both data buses share one memory through the arbiter
axi_lite_arb2 arb (
    .clk_i(clk), .rst_n_i(rst_n),
    `AXIL_NP_SLV(m0, db0),
    `AXIL_NP_SLV(m1, db1),
    `AXIL_NP_MST(s, s)
);

axi_lite_mem_model #(
    .WORDS(1024), .BASE(32'h0000_2000),
    .READ_LAT(1), .WRITE_LAT(1)
) dmem_inst (
    .clk_i(clk), .rst_n_i(rst_n), `AXIL_BARE_SLV(s)
);

// keep the arbitrated link protocol-clean too
wire [15:0] mon_err;
axi_lite_monitor #(.NAME("shared"), .HAS_WRITE(1)) mon (
    .clk_i(clk), .rst_n_i(rst_n), `AXIL_BARE_MON(s),
    .err_cnt_o(mon_err), .rd_cnt_o(), .wr_cnt_o()
);

integer errors;
`include "tb_check.vh"

integer i, tmo;

initial begin
    errors = 0;

    for (i = 0; i < 1024; i = i + 1)
        dmem_inst.mem[i] = 32'b0;

    wait (rst_n === 1'b1);

    // run until both harts posted their results, or timeout
    tmo = 0;
    while (!(dmem_inst.mem[2] === 32'd111 && dmem_inst.mem[3] === 32'd222)
           && tmo < 20000) begin
        @(posedge clk);
        tmo = tmo + 1;
    end
    repeat (5) @(posedge clk);

    if (tmo >= 20000) begin
        $display("FAIL: timeout - harts never completed the handshake");
        errors = errors + 1;
    end

    check(32'h000000A0, dmem_inst.mem[0], "flag A (hart0 -> hart1)");
    check(32'h000000B1, dmem_inst.mem[1], "flag B (hart1 -> hart0)");
    check(32'd111,      dmem_inst.mem[2], "hart0 result");
    check(32'd222,      dmem_inst.mem[3], "hart1 result");
    check(32'd0,        {16'b0, mon_err}, "shared bus protocol clean");

    if (errors == 0)
        $display("== DUAL-CORE TEST PASSED ==");
    else
        $display("== %0d DUAL-CORE TESTS FAILED ==", errors);
    $finish;
end

endmodule
