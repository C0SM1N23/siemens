// Reset must work before the next clock edge, including with the clock stopped.
`timescale 1ns / 1ps
`include "axi_lite_macros.vh"

module rv32i_tb_reset;
    reg clk = 0;
    reg clock_run = 1;
    reg rst_n = 0;
    always #5 if (clock_run) clk = ~clk;

    `AXIL_RD_WIRES(ib);
    `AXIL_WIRES(db);
    reg fetch_enable = 0;
    reg response_valid = 0;
    reg [31:0] instruction = 32'h00700093; // addi x1, x0, 7
    reg [31:0] response_data = 0;
    wire ack, eoi, in_trap;
    wire [15:0] mask;
    integer errors = 0;
    integer i;
    `include "tb_check.vh"

    rv32i_cpu_top #(
        .RESET_PC(32'h100)
    ) dut (
        .clk_i  (clk),
        .rst_n_i(rst_n),
        `AXIL_MST_RD(ibus_axi, ib),
        `AXIL_MST(dbus_axi, db),
        .cpu_irq_i    (1'b0),
        .cpu_irq_vec_i(4'b0),
        .irq_pending_i(16'b0),
        .irq_mask_o   (mask),
        .cpu_irq_ack_o(ack),
        .cpu_irq_eoi_o(eoi),
        .cpu_in_trap_o(in_trap)
    );

    assign ib_arready = fetch_enable && !response_valid;
    assign ib_rvalid = response_valid;
    assign ib_rdata = response_data;
    assign ib_rresp = 2'b00;
    assign db_awready = 0;
    assign db_wready = 0;
    assign db_bvalid = 0;
    assign db_bresp = 0;
    assign db_arready = 0;
    assign db_rvalid = 0;
    assign db_rdata = 0;
    assign db_rresp = 0;

    // Negative edge is required here only for the active-low asynchronous reset.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            response_valid <= 0;
            response_data <= 0;
        end else begin
            if (ib_rvalid && ib_rready) response_valid <= 0;
            if (ib_arvalid && ib_arready) begin
                response_valid <= 1;
                response_data <= instruction;
            end
        end
    end

    task check_reset;
        begin
            check(0, {26'b0, ib_arvalid, db_arvalid, db_awvalid, db_wvalid, ack, eoi},
                  "bus requests and interrupt pulses clear asynchronously");
            check(0, {29'b0, dut.ifdx_valid_q, dut.dxwb_valid_q, in_trap},
                  "pipeline and trap state clear asynchronously");
            check(32'h100, ib_araddr, "reset fetch address restored");
            check(0, {16'b0, mask}, "interrupt mask reset");
            for (i = 0; i < 32; i = i + 1)
                check(0, dut.regfile_inst.regs[i], "every GPR clears asynchronously");
        end
    endtask

    task pulse_reset(input stop_clock);
        begin
            @(posedge clk);
            #2;
            if (stop_clock) clock_run = 0;
            rst_n = 0;
            #1; // +3 ns: neither a rising nor a falling edge has happened.
            check_reset;
            #11;
            check_reset;
            rst_n = 1; // +14 ns, deliberately off the clock grid
            clock_run = 1;
        end
    endtask

    initial begin
        #23;
        rst_n = 1;
        wait (ib_arvalid);
        $display("-- reset with fetch address stalled --");
        pulse_reset(0);
        @(posedge clk);
        #1;
        fetch_enable = 1;
        wait (dut.regfile_inst.regs[1] == 7);
        $display("-- reset nonzero registers with clock stopped --");
        pulse_reset(1);
        @(posedge clk);
        #1;
        instruction = 32'h00002103; // lw x2, 0(x0)
        wait (db_arvalid);
        $display("-- reset with load address stalled --");
        @(posedge clk);
        #1;
        fetch_enable = 0;
        pulse_reset(0);
        @(posedge clk);
        #1;
        instruction = 32'h00700093;
        fetch_enable = 1;
        wait (dut.regfile_inst.regs[1] == 7);
        check(7, dut.regfile_inst.regs[1], "execution resumes after reset");
        if (errors == 0) $display("== CPU ASYNC RESET: ALL TESTS PASSED ==");
        finish_test;
    end
    initial begin
        #10000;
        $fatal(1, "FAIL: CPU reset timeout");
    end
endmodule
