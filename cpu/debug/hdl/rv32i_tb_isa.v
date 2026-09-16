// Architectural retirement trace against isa_reference.py.
`timescale 1ns / 1ps
module rv32i_tb_isa #(
    parameter READ_LAT   = 0,
    parameter STALL_PROB = 0
);
    localparam [31:0] IMEM_BASE = 32'h0;
    localparam [31:0] DMEM_BASE = 32'h2000;
    localparam IWORDS = 2048;
    `include "program_isa_count.vh"
    // clock / reset
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // CPU buses
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

    // interrupt pins, driven directly by the bench
    wire       cpu_irq = 1'b0;
    wire [3:0] cpu_irq_vec = 4'b0;
    wire cpu_irq_ack, cpu_irq_eoi, cpu_in_trap;

    integer        errors = 0;
    integer        i;
    reg     [95:0] expected    [0:ISA_STEPS-1];
    reg     [31:0] expected_mem[        0:255];
    `include "tb_check.vh"

rv32i_cpu_top #(
        .RESET_PC(IMEM_BASE)
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
        .cpu_irq_i         (cpu_irq),
        .cpu_irq_vec_i     (cpu_irq_vec),
        .irq_pending_i     (16'b0),
        .irq_mask_o        (),
        .cpu_irq_ack_o     (cpu_irq_ack),
        .cpu_irq_eoi_o     (cpu_irq_eoi),
        .cpu_in_trap_o     (cpu_in_trap)
    );

    // instruction memory: read-only from the CPU, written directly by the bench
    axi_lite_mem_model #(
        .WORDS     (IWORDS),
        .INIT_FILE ("program_isa.hex"),
        .BASE      (IMEM_BASE),
        .READ_LAT  (READ_LAT),
        .STALL_PROB(STALL_PROB),
        .SEED      (3)
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

    // data memory
    axi_lite_mem_model #(
        .WORDS     (256),
        .BASE      (DMEM_BASE),
        .READ_LAT  (READ_LAT),
        .STALL_PROB(STALL_PROB),
        .WRITE_LAT (1),
        .SEED      (5)
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

    // Load the independent trace and initialize the byte-addressed data memory.
    initial begin
        $readmemh("program_isa_trace.hex", expected);
        $readmemh("program_isa_mem.hex", expected_mem);
        for (i = 0; i < 256; i = i + 1) dmem.mem[i] = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
    end

    // Sample the architectural writeback before its active clock edge.
    integer step = 0;
    wire [31:0] actual_rd = (dut.dxwb_regwrite_q && dut.dxwb_rd_q != 0)
                      ? {27'b0, dut.dxwb_rd_q} : 32'b0;
    wire [31:0] actual_value = actual_rd != 0 ? dut.wb_data : 32'b0;
    always @(posedge clk) begin
        if (rst_n && dut.dxwb_valid_q && step < ISA_STEPS) step <= step + 1;
    end
    always @(posedge clk) begin
        if (rst_n && dut.dxwb_valid_q && step < ISA_STEPS) begin
            if ({dut.dxwb_pc4_q - 32'd4, actual_rd, actual_value} !== expected[step]) begin
                $display("FAIL: ISA step=%0d expected=%024h got=%08h_%08h_%08h", step,
                         expected[step], dut.dxwb_pc4_q - 32'd4, actual_rd, actual_value);
                errors = errors + 1;
            end
            if (step == ISA_STEPS - 1) begin
                for (i = 0; i < 256; i = i + 1)
                if (dmem.mem[i] !== expected_mem[i]) begin
                    $display("FAIL: ISA memory word=%0d expected=%08h got=%08h", i,
                             expected_mem[i], dmem.mem[i]);
                    errors = errors + 1;
                end
                if (errors != 0) $fatal(1, "ISA: %0d mismatches", errors);
                $display("== ISA TRACE: ALL TESTS PASSED (%0d instructions) ==", ISA_STEPS);
                finish_test;
            end
        end
    end

    initial begin
        #2000000;
        $fatal(1, "ISA timeout: step=%0d", step);
    end
endmodule
