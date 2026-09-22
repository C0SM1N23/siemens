// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// Counter write priority, half preservation, carry and event identity.
`timescale 1ns / 1ps

`include "rv32i_defines.vh"

module rv32i_tb_counters;

    // CSR addresses
    localparam MSTATUS  = 12'h300, MISA     = 12'h301, MIE      = 12'h304,
           MTVEC    = 12'h305, MSCRATCH = 12'h340, MEPC     = 12'h341,
           MCAUSE   = 12'h342, MTVAL    = 12'h343, MIP      = 12'h344;
    localparam MVENDID = 12'hF11, MARCHID = 12'hF12, MIMPID = 12'hF13, MHARTID = 12'hF14;
    localparam MCYCLE = 12'hB00, MINSTRET = 12'hB02;
    localparam MHPMC3 = 12'hB03, MHPMC7 = 12'hB07;
    localparam MCYCLEH = 12'hB80, MINSTRETH = 12'hB82;
    localparam MHPMC3H = 12'hB83, MHPMC7H = 12'hB87;
    localparam MCOUNTINHIBIT = 12'h320;  // deliberately not implemented

    localparam [31:0] THIS_HART = 32'h0000_002A;  // a distinctive, non-zero id

    // clock / reset
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // DUT interface
    reg [11:0] csr_addr;
    reg [31:0] csr_wdata;
    reg [ 1:0] csr_op;
    reg csr_ren, csr_wen;
    wire [31:0] csr_rdata;
    wire        csr_illegal;

    reg trap_set, trap_is_irq, mret;
    reg [4:0] trap_code;
    reg [31:0] trap_pc, trap_val;
    reg  [15:0] irq_lines;
    wire [15:0] irq_enable;
    wire        mie_global;
    wire [31:0] trap_vector, mepc_out;
    reg retire, ev_mispredict, ev_ibus_wait, ev_dbus_stall, ev_wfi_sleep;

    integer        errors = 0;
    integer        i;
    reg     [11:0] counters   [0:6];
    reg     [31:0] rd;
    reg     [31:0] before_val;
    `include "tb_check.vh"

    rv32i_csr_file #(
        .HART_ID(THIS_HART)
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .csr_addr_i     (csr_addr),
        .csr_wdata_i    (csr_wdata),
        .csr_op_i       (csr_op),
        .csr_ren_i      (csr_ren),
        .csr_wen_i      (csr_wen),
        .csr_rdata_o    (csr_rdata),
        .csr_illegal_o  (csr_illegal),
        .trap_set_i     (trap_set),
        .trap_is_irq_i  (trap_is_irq),
        .trap_code_i    (trap_code),
        .trap_pc_i      (trap_pc),
        .trap_val_i     (trap_val),
        .mret_i         (mret),
        .irq_lines_i    (irq_lines),
        .irq_enable_o   (irq_enable),
        .mie_global_o   (mie_global),
        .trap_vector_o  (trap_vector),
        .mepc_out_o     (mepc_out),
        .retire_i       (retire),
        .ev_mispredict_i(ev_mispredict),
        .ev_ibus_wait_i (ev_ibus_wait),
        .ev_dbus_stall_i(ev_dbus_stall),
        .ev_wfi_sleep_i (ev_wfi_sleep)
    );

    // Bus-level CSR checks: expected values do not read internal counter state.
    task write_counter(input [11:0] address, input [31:0] data, input [1:0] operation);
        begin
            @(posedge clk);
            #1;
            csr_addr  = address;
            csr_wdata = data;
            csr_op    = operation;
            csr_ren   = 1;
            csr_wen   = 1;
            #1;
            check(0, {31'b0, csr_illegal}, "counter access legal");
            @(posedge clk);
            #1;
            csr_wen = 0;
        end
    endtask

    task check_counter(input [11:0] address, input [63:0] expected);
        begin
            csr_addr = address;
            #1;
            check(expected[31:0], csr_rdata, "counter low half");
            csr_addr = address + 12'h080;
            #1;
            check(expected[63:32], csr_rdata, "counter high half");
        end
    endtask

    initial begin
        csr_addr      = 0;
        csr_wdata     = 0;
        csr_op        = 0;
        csr_ren       = 0;
        csr_wen       = 0;
        trap_set      = 0;
        trap_is_irq   = 0;
        trap_code     = 0;
        trap_pc       = 0;
        trap_val      = 0;
        mret          = 0;
        irq_lines     = 0;
        retire        = 0;
        ev_mispredict = 0;
        ev_ibus_wait  = 0;
        ev_dbus_stall = 0;
        ev_wfi_sleep  = 0;
        counters[0]   = 12'hB00;
        counters[1]   = 12'hB02;
        counters[2]   = 12'hB03;
        counters[3]   = 12'hB04;
        counters[4]   = 12'hB05;
        counters[5]   = 12'hB06;
        counters[6]   = 12'hB07;
        repeat (3) begin
            @(posedge clk);
            #1;
        end
        rst_n         = 1;
        retire        = 1;
        ev_mispredict = 1;
        ev_ibus_wait  = 1;
        ev_dbus_stall = 1;
        ev_wfi_sleep  = 1;
        trap_set      = 1;
        for (i = 0; i < 7; i = i + 1) begin
            write_counter(counters[i] + 12'h080, 32'h12345678, 2'b01);
            write_counter(counters[i], 32'hFFFFFFFE, 2'b01);
            check_counter(counters[i], 64'h12345678_FFFFFFFE);
            // One free cycle separates two writes, so the low half is FFFFFFFF
            // on the edge that samples the next write. That low-half write must
            // suppress the carry into the untouched high half.
            write_counter(counters[i], 32'h0, 2'b01);
            check_counter(counters[i], 64'h12345678_00000000);
            write_counter(counters[i], 32'hFFFFFFFE, 2'b01);
            // An explicit high-half write must leave the low half unchanged.
            write_counter(counters[i] + 12'h080, 32'h23456780, 2'b01);
            check_counter(counters[i], 64'h23456780_FFFFFFFF);
            @(posedge clk);
            #1;
            check_counter(counters[i], 64'h23456781_00000000);
            // Set/clear operate on the old CSR value, without an implicit increment.
            write_counter(counters[i], 32'h10, 2'b10);
            // The launch cycle increments 0 to 1; CSRRS then sets bit 4.
            check_counter(counters[i], 64'h23456781_00000011);
            write_counter(counters[i], 32'h10, 2'b11);
            check_counter(counters[i], 64'h23456781_00000002);
            write_counter(counters[i], 32'h0, 2'b10);
            check_counter(counters[i], 64'h23456781_00000003);
        end
        // Event 0 means no event. Implemented fixed events have distinct nonzero IDs.
        trap_set = 0;
        for (i = 0; i < 5; i = i + 1) begin
            csr_addr = 12'h323 + i[11:0];
            #1;
            check(i + 1, csr_rdata, "fixed HPM event ID");
        end
        if (errors == 0) $display("== COUNTERS: ALL TESTS PASSED ==");
        finish_test;
    end
    initial begin
        #10000;
        $fatal(1, "counter test timeout");
    end
endmodule
