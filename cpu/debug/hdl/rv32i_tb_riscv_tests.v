// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// riscv-tests (riscv-software-src/riscv-tests), physical environment "p".
//
// Each test is linked at address 0 by run_riscv_tests.sh and converted to one
// word per line. The instruction and data ports read two copies of the same
// image, so code and data share one address map as the tests expect. A test
// ends by storing to its tohost word: 1 means every case passed, any other odd
// value is (failing case << 1) | 1.
//
// Plusargs: +test=<name>  selects riscv_tests/<name>.hex
//           +tohost=<hex> address of the tohost word, taken from the ELF
`timescale 1ns / 1ps
module rv32i_tb_riscv_tests #(
    parameter READ_LAT   = 0,
    parameter STALL_PROB = 0
);
    localparam WORDS = 16384;  // 64 KiB covers text, tohost, data and bss

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [31:0] ib_araddr, ib_rdata;
    wire [2:0] ib_arprot;
    wire ib_arvalid, ib_arready, ib_rvalid, ib_rready;
    wire [1:0] ib_rresp;

    wire [31:0] db_awaddr, db_wdata, db_araddr, db_rdata;
    wire [2:0] db_awprot, db_arprot;
    wire [3:0] db_wstrb;
    wire db_awvalid, db_awready, db_wvalid, db_wready, db_bvalid, db_bready;
    wire db_arvalid, db_arready, db_rvalid, db_rready;
    wire [1:0] db_bresp, db_rresp;
    wire cpu_irq_ack, cpu_irq_eoi, cpu_in_trap;

    integer errors = 0;
    integer cycles = 0;
    reg [8*64-1:0] name;
    reg [31:0] tohost;
    `include "tb_check.vh"

    rv32i_cpu_top #(
        .RESET_PC(32'h0)
    ) dut (
        .clk_i             (clk),
        .rst_n_i           (rst_n),
        .ibus_axi_araddr_o (ib_araddr),
        .ibus_axi_arprot_o (ib_arprot),
        .ibus_axi_arvalid_o(ib_arvalid),
        .ibus_axi_arready_i(ib_arready),
        .ibus_axi_rdata_i  (ib_rdata),
        .ibus_axi_rresp_i  (ib_rresp),
        .ibus_axi_rvalid_i (ib_rvalid),
        .ibus_axi_rready_o (ib_rready),
        .dbus_axi_awaddr_o (db_awaddr),
        .dbus_axi_awprot_o (db_awprot),
        .dbus_axi_awvalid_o(db_awvalid),
        .dbus_axi_awready_i(db_awready),
        .dbus_axi_wdata_o  (db_wdata),
        .dbus_axi_wstrb_o  (db_wstrb),
        .dbus_axi_wvalid_o (db_wvalid),
        .dbus_axi_wready_i (db_wready),
        .dbus_axi_bresp_i  (db_bresp),
        .dbus_axi_bvalid_i (db_bvalid),
        .dbus_axi_bready_o (db_bready),
        .dbus_axi_araddr_o (db_araddr),
        .dbus_axi_arprot_o (db_arprot),
        .dbus_axi_arvalid_o(db_arvalid),
        .dbus_axi_arready_i(db_arready),
        .dbus_axi_rdata_i  (db_rdata),
        .dbus_axi_rresp_i  (db_rresp),
        .dbus_axi_rvalid_i (db_rvalid),
        .dbus_axi_rready_o (db_rready),
        .cpu_irq_i         (1'b0),
        .cpu_irq_vec_i     (4'b0),
        .irq_pending_i     (16'b0),
        .irq_mask_o        (),
        .cpu_irq_ack_o     (cpu_irq_ack),
        .cpu_irq_eoi_o     (cpu_irq_eoi),
        .cpu_in_trap_o     (cpu_in_trap)
    );

    axi_lite_mem_model #(
        .WORDS     (WORDS),
        .BASE      (32'h0),
        .READ_LAT  (READ_LAT),
        .STALL_PROB(STALL_PROB),
        .SEED      (7)
    ) imem (
        .clk_i    (clk),
        .rst_n_i  (rst_n),
        .awaddr_i (32'b0),
        .awvalid_i(1'b0),
        .awready_o(),
        .wdata_i  (32'b0),
        .wstrb_i  (4'b0),
        .wvalid_i (1'b0),
        .wready_o (),
        .bresp_o  (),
        .bvalid_o (),
        .bready_i (1'b0),
        .araddr_i (ib_araddr),
        .arvalid_i(ib_arvalid),
        .arready_o(ib_arready),
        .rdata_o  (ib_rdata),
        .rresp_o  (ib_rresp),
        .rvalid_o (ib_rvalid),
        .rready_i (ib_rready)
    );

    axi_lite_mem_model #(
        .WORDS     (WORDS),
        .BASE      (32'h0),
        .READ_LAT  (READ_LAT),
        .WRITE_LAT (1),
        .STALL_PROB(STALL_PROB),
        .SEED      (9)
    ) dmem (
        .clk_i    (clk),
        .rst_n_i  (rst_n),
        .awaddr_i (db_awaddr),
        .awvalid_i(db_awvalid),
        .awready_o(db_awready),
        .wdata_i  (db_wdata),
        .wstrb_i  (db_wstrb),
        .wvalid_i (db_wvalid),
        .wready_o (db_wready),
        .bresp_o  (db_bresp),
        .bvalid_o (db_bvalid),
        .bready_i (db_bready),
        .araddr_i (db_araddr),
        .arvalid_i(db_arvalid),
        .arready_o(db_arready),
        .rdata_o  (db_rdata),
        .rresp_o  (db_rresp),
        .rvalid_o (db_rvalid),
        .rready_i (db_rready)
    );

    initial begin
        if (!$value$plusargs("test=%s", name)) $fatal(1, "riscv-tests: +test=<name> is required");
        if (!$value$plusargs("tohost=%h", tohost)) $fatal(1, "riscv-tests: +tohost=<hex> is required");
        #1;  // after the memory models have initialised their arrays
        $readmemh({"riscv_tests/", name, ".hex"}, imem.mem);
        $readmemh({"riscv_tests/", name, ".hex"}, dmem.mem);
        repeat (4) begin
            @(posedge clk);
            #1;
        end
        rst_n = 1;
    end

    // The tohost word is written by the test's trap handler after ECALL.
    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;
            if (dmem.mem[tohost>>2] !== 32'b0) begin
                if (dmem.mem[tohost>>2] === 32'd1) begin
                    $display("== RISCV-TEST %0s: ALL TESTS PASSED (%0d cycles) ==", name, cycles);
                end else begin
                    $display("FAIL: riscv-test %0s case %0d (tohost=0x%08h)", name,
                             dmem.mem[tohost>>2] >> 1, dmem.mem[tohost>>2]);
                    errors = errors + 1;
                    $display("== RISCV-TEST %0s: 1 FAILURE(S) ==", name);
                end
                finish_test;
            end
            if (cycles > 200000) $fatal(1, "riscv-test %0s: no result after %0d cycles", name, cycles);
        end
    end
endmodule
