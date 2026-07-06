// Dual-core smoke test — the "2-3 cores in a bigger SoC" scenario in
// miniature.
//
// Setup:
// - two cpu_top instances (HART_ID 0 and 1), private instruction memories,
//   both running the same binary
// - one shared data memory behind a 2:1 arbiter
// - a protocol monitor on the arbitrated link
//
// What the test does:
// - the program splits on mhartid (each core takes a different path)
// - the cores complete a flag handshake through the shared memory
// - each core leaves its own result word; the TB checks both, plus the flags
//
// Why this proves scalability:
// - the core is instantiable — no shared state between instances
// - mhartid actually differentiates the software paths
// - two blocking AXI4-Lite masters make progress through one arbitrated
//   slave with no deadlock and no data corruption (the handshake is sound
//   because each core is in-order with blocking memory ops — sequentially
//   consistent — so no LR/SC is needed)

module tb_dual_core;

wire clk, rst_n;

ck_rst_tb #(.CK_SEMIPERIOD(5)) ck_rst_inst (
    .clk   (clk),
    .rst_n (rst_n)
);

// per-core ibus, dbus; shared slave-side bus
wire [31:0] ib_araddr  [0:1];
wire [2:0]  ib_arprot  [0:1];
wire        ib_arvalid [0:1], ib_arready [0:1], ib_rvalid [0:1], ib_rready [0:1];
wire [31:0] ib_rdata   [0:1];
wire [1:0]  ib_rresp   [0:1];

wire [31:0] db_awaddr [0:1], db_wdata [0:1], db_araddr [0:1], db_rdata [0:1];
wire [2:0]  db_awprot [0:1], db_arprot [0:1];
wire [3:0]  db_wstrb  [0:1];
wire        db_awvalid[0:1], db_awready[0:1], db_wvalid[0:1], db_wready[0:1];
wire        db_bvalid [0:1], db_bready [0:1], db_arvalid[0:1], db_arready[0:1];
wire        db_rvalid [0:1], db_rready [0:1];
wire [1:0]  db_bresp  [0:1], db_rresp  [0:1];

wire [31:0] s_awaddr, s_wdata, s_araddr, s_rdata;
wire [3:0]  s_wstrb;
wire        s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready;
wire        s_arvalid, s_arready, s_rvalid, s_rready;
wire [1:0]  s_bresp, s_rresp;

wire [7:0]  ack    [0:1];
wire        intrap [0:1];

genvar g;
generate
for (g = 0; g < 2; g = g + 1) begin : core
    cpu_top #(.HART_ID(g)) cpu (
        .clk              (clk),
        .rst_n            (rst_n),
        .ibus_axi_araddr  (ib_araddr[g]),
        .ibus_axi_arprot  (ib_arprot[g]),
        .ibus_axi_arvalid (ib_arvalid[g]),
        .ibus_axi_arready (ib_arready[g]),
        .ibus_axi_rdata   (ib_rdata[g]),
        .ibus_axi_rresp   (ib_rresp[g]),
        .ibus_axi_rvalid  (ib_rvalid[g]),
        .ibus_axi_rready  (ib_rready[g]),
        .dbus_axi_awaddr  (db_awaddr[g]),
        .dbus_axi_awprot  (db_awprot[g]),
        .dbus_axi_awvalid (db_awvalid[g]),
        .dbus_axi_awready (db_awready[g]),
        .dbus_axi_wdata   (db_wdata[g]),
        .dbus_axi_wstrb   (db_wstrb[g]),
        .dbus_axi_wvalid  (db_wvalid[g]),
        .dbus_axi_wready  (db_wready[g]),
        .dbus_axi_bresp   (db_bresp[g]),
        .dbus_axi_bvalid  (db_bvalid[g]),
        .dbus_axi_bready  (db_bready[g]),
        .dbus_axi_araddr  (db_araddr[g]),
        .dbus_axi_arprot  (db_arprot[g]),
        .dbus_axi_arvalid (db_arvalid[g]),
        .dbus_axi_arready (db_arready[g]),
        .dbus_axi_rdata   (db_rdata[g]),
        .dbus_axi_rresp   (db_rresp[g]),
        .dbus_axi_rvalid  (db_rvalid[g]),
        .dbus_axi_rready  (db_rready[g]),
        .cpu_irq          (8'b0),
        .cpu_irq_ack      (ack[g]),
        .cpu_irq_id       (3'b0),
        .cpu_in_trap      (intrap[g])
    );

    // private instruction memory, same binary in both
    axi_lite_mem_model #(
        .WORDS(256), .BASE(32'h0000_0000), .INIT_FILE("program_dual.hex"),
        .READ_LAT(0)
    ) imem (
        .clk(clk), .rst_n(rst_n),
        .awaddr(32'b0), .awvalid(1'b0), .awready(),
        .wdata(32'b0), .wstrb(4'b0), .wvalid(1'b0), .wready(),
        .bresp(), .bvalid(), .bready(1'b0),
        .araddr(ib_araddr[g]), .arvalid(ib_arvalid[g]), .arready(ib_arready[g]),
        .rdata(ib_rdata[g]), .rresp(ib_rresp[g]), .rvalid(ib_rvalid[g]),
        .rready(ib_rready[g])
    );
end
endgenerate

// both data buses share one memory through the arbiter
axi_lite_arb2 arb (
    .clk(clk), .rst_n(rst_n),
    .m0_awaddr(db_awaddr[0]), .m0_awvalid(db_awvalid[0]), .m0_awready(db_awready[0]),
    .m0_wdata(db_wdata[0]), .m0_wstrb(db_wstrb[0]), .m0_wvalid(db_wvalid[0]),
    .m0_wready(db_wready[0]), .m0_bresp(db_bresp[0]), .m0_bvalid(db_bvalid[0]),
    .m0_bready(db_bready[0]), .m0_araddr(db_araddr[0]), .m0_arvalid(db_arvalid[0]),
    .m0_arready(db_arready[0]), .m0_rdata(db_rdata[0]), .m0_rresp(db_rresp[0]),
    .m0_rvalid(db_rvalid[0]), .m0_rready(db_rready[0]),
    .m1_awaddr(db_awaddr[1]), .m1_awvalid(db_awvalid[1]), .m1_awready(db_awready[1]),
    .m1_wdata(db_wdata[1]), .m1_wstrb(db_wstrb[1]), .m1_wvalid(db_wvalid[1]),
    .m1_wready(db_wready[1]), .m1_bresp(db_bresp[1]), .m1_bvalid(db_bvalid[1]),
    .m1_bready(db_bready[1]), .m1_araddr(db_araddr[1]), .m1_arvalid(db_arvalid[1]),
    .m1_arready(db_arready[1]), .m1_rdata(db_rdata[1]), .m1_rresp(db_rresp[1]),
    .m1_rvalid(db_rvalid[1]), .m1_rready(db_rready[1]),
    .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
    .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid), .s_wready(s_wready),
    .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
    .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
    .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid), .s_rready(s_rready)
);

axi_lite_mem_model #(
    .WORDS(1024), .BASE(32'h0000_2000),
    .READ_LAT(1), .WRITE_LAT(1)
) dmem_inst (
    .clk(clk), .rst_n(rst_n),
    .awaddr(s_awaddr), .awvalid(s_awvalid), .awready(s_awready),
    .wdata(s_wdata), .wstrb(s_wstrb), .wvalid(s_wvalid), .wready(s_wready),
    .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
    .araddr(s_araddr), .arvalid(s_arvalid), .arready(s_arready),
    .rdata(s_rdata), .rresp(s_rresp), .rvalid(s_rvalid), .rready(s_rready)
);

// keep the arbitrated link protocol-clean too
wire [15:0] mon_err;
axi_lite_monitor #(.NAME("shared"), .HAS_WRITE(1)) mon (
    .clk(clk), .rst_n(rst_n),
    .awaddr(s_awaddr), .awvalid(s_awvalid), .awready(s_awready),
    .wdata(s_wdata), .wstrb(s_wstrb), .wvalid(s_wvalid), .wready(s_wready),
    .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
    .araddr(s_araddr), .arvalid(s_arvalid), .arready(s_arready),
    .rdata(s_rdata), .rresp(s_rresp), .rvalid(s_rvalid), .rready(s_rready),
    .err_cnt(mon_err), .rd_cnt(), .wr_cnt()
);

integer errors;

task check;
    input [31:0] expected;
    input [31:0] got;
    input [255:0] test_name;
    begin
        if (expected === got)
            $display("PASS: %0s = 0x%08h", test_name, got);
        else begin
            $display("FAIL: %0s -> expected 0x%08h, got 0x%08h",
                     test_name, expected, got);
            errors = errors + 1;
        end
    end
endtask

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
