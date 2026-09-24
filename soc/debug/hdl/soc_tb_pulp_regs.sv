// Transaction comparison: project PIC/timer AXI front-end versus PULP registers.
// Both expose four RW words and one RO word. Latency is intentionally independent.
`timescale 1ns / 1ps
`include "axi/typedef.svh"
module soc_tb_pulp_regs;
    `AXI_LITE_TYPEDEF_ALL(lt, logic [31:0], logic [31:0], logic [3:0])
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;
    lt_req_t req [2];
    lt_resp_t resp [2];
    reg [31:0] words [4];
    reg [31:0] expected [4];
    wire wr_en;
    wire [5:0] wr_addr, rd_addr;
    wire [31:0] wr_data;
    wire [3:0] wr_strb;
    integer errors = 0;
    integer cases = 0;
    integer k, order, strb, hold_cycles, a, lane;
    reg [31:0] data;
    `include "tb_check.vh"

    axi_lite_slave ours (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .s_axi_awaddr_i (req[0].aw.addr),
        .s_axi_awvalid_i(req[0].aw_valid),
        .s_axi_awready_o(resp[0].aw_ready),
        .s_axi_wdata_i  (req[0].w.data),
        .s_axi_wstrb_i  (req[0].w.strb),
        .s_axi_wvalid_i (req[0].w_valid),
        .s_axi_wready_o (resp[0].w_ready),
        .s_axi_bresp_o  (resp[0].b.resp),
        .s_axi_bvalid_o (resp[0].b_valid),
        .s_axi_bready_i (req[0].b_ready),
        .s_axi_araddr_i (req[0].ar.addr),
        .s_axi_arvalid_i(req[0].ar_valid),
        .s_axi_arready_o(resp[0].ar_ready),
        .s_axi_rdata_o  (resp[0].r.data),
        .s_axi_rresp_o  (resp[0].r.resp),
        .s_axi_rvalid_o (resp[0].r_valid),
        .s_axi_rready_i (req[0].r_ready),
        .wr_en_o        (wr_en),
        .wr_addr_o      (wr_addr),
        .wr_data_o      (wr_data),
        .wr_strb_o      (wr_strb),
        .wr_ok_i        (wr_addr < 4),
        .rd_addr_o      (rd_addr),
        .rd_data_i      (rd_addr < 4 ? words[rd_addr[1:0]] : rd_addr == 4 ? 32'h13579BDF : 32'b0),
        .rd_ok_i        (rd_addr <= 4)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (integer j = 0; j < 4; j++) words[j] <= 0;
        end else if (wr_en && wr_addr < 4) begin
            for (integer j = 0; j < 4; j++)
                if (wr_strb[j]) words[wr_addr[1:0]][j*8+:8] <= wr_data[j*8+:8];
        end
    end
    axi_lite_regs #(
        .RegNumBytes (20),
        .AxiAddrWidth(32),
        .AxiDataWidth(32),
        .AxiReadOnly (20'hF0000),
        .RegRstVal   ({32'h13579BDF, 128'b0}),
        .req_lite_t  (lt_req_t),
        .resp_lite_t (lt_resp_t)
    ) reference_regs (
        .clk_i      (clk),
        .rst_ni     (rst_n),
        .axi_req_i  (req[1]),
        .axi_resp_o (resp[1]),
        .wr_active_o(),
        .rd_active_o(),
        .reg_d_i    ('0),
        .reg_load_i ('0),
        .reg_q_o    ()
    );

    for (genvar g = 0; g < 2; g++) begin : monitors
        axi_lite_sva #(.NAME("pulp_regs_comparison")) protocol (
            .clk_i    (clk),
            .rst_n_i  (rst_n),
            .awaddr_i (req[g].aw.addr),
            .awvalid_i(req[g].aw_valid),
            .awready_i(resp[g].aw_ready),
            .wdata_i  (req[g].w.data),
            .wstrb_i  (req[g].w.strb),
            .wvalid_i (req[g].w_valid),
            .wready_i (resp[g].w_ready),
            .bresp_i  (resp[g].b.resp),
            .bvalid_i (resp[g].b_valid),
            .bready_i (req[g].b_ready),
            .araddr_i (req[g].ar.addr),
            .arvalid_i(req[g].ar_valid),
            .arready_i(resp[g].ar_ready),
            .rdata_i  (resp[g].r.data),
            .rresp_i  (resp[g].r.resp),
            .rvalid_i (resp[g].r_valid),
            .rready_i (req[g].r_ready)
        );
    end

    task automatic write_one(input integer side, input [31:0] addr, value,
                             input [3:0] strobe, input integer skew, stall,
                             input [1:0] response);
        reg [1:0] held;
        begin
            @(posedge clk);
            #1;
            req[side].aw.addr = addr;
            req[side].w.data = value;
            req[side].w.strb = strobe;
            fork
                begin
                    if (skew < 0) repeat (-skew) begin
                        @(posedge clk);
                        #1;
                    end
                    req[side].aw_valid = 1;
                    @(posedge clk);
                    while (!resp[side].aw_ready) @(posedge clk);
                    #1;
                    req[side].aw_valid = 0;
                end
                begin
                    if (skew > 0) repeat (skew) begin
                        @(posedge clk);
                        #1;
                    end
                    req[side].w_valid = 1;
                    @(posedge clk);
                    while (!resp[side].w_ready) @(posedge clk);
                    #1;
                    req[side].w_valid = 0;
                end
            join
            @(posedge clk);
            while (!resp[side].b_valid) @(posedge clk);
            held = resp[side].b.resp;
            repeat (stall) begin
                @(posedge clk);
                check(1, {31'b0, resp[side].b_valid}, "BVALID held during backpressure");
                check({30'b0, held}, {30'b0, resp[side].b.resp}, "BRESP stable");
            end
            #1;
            req[side].b_ready = 1;
            @(posedge clk);
            check({30'b0, response}, {30'b0, resp[side].b.resp}, "expected write response");
            #1;
            req[side].b_ready = 0;
        end
    endtask

    task automatic read_one(input integer side, input [31:0] addr, value,
                            input integer stall, input [1:0] response);
        begin
            @(posedge clk);
            #1;
            req[side].ar.addr = addr;
            req[side].ar_valid = 1;
            @(posedge clk);
            while (!resp[side].ar_ready) @(posedge clk);
            #1;
            req[side].ar_valid = 0;
            @(posedge clk);
            while (!resp[side].r_valid) @(posedge clk);
            repeat (stall) begin
                check(1, {31'b0, resp[side].r_valid}, "RVALID held during backpressure");
                check(value, resp[side].r.data, "RDATA stable and correct");
                check({30'b0, response}, {30'b0, resp[side].r.resp}, "RRESP stable and correct");
                @(posedge clk);
            end
            #1;
            req[side].r_ready = 1;
            @(posedge clk);
            check(value, resp[side].r.data, "expected read data");
            check({30'b0, response}, {30'b0, resp[side].r.resp}, "expected read response");
            #1;
            req[side].r_ready = 0;
        end
    endtask

    // Queue both response channels with READY low, so reset checks are non-vacuous.
    task automatic prime_reset(input integer side);
        begin
            @(posedge clk);
            #1;
            req[side].aw.addr = 0;
            req[side].w.data = 32'hDEADBEEF;
            req[side].w.strb = 4'hF;
            req[side].ar.addr = 0;
            req[side].aw_valid = 1;
            req[side].w_valid = 1;
            req[side].ar_valid = 1;
            fork
                begin
                    @(posedge clk);
                    while (!resp[side].aw_ready) @(posedge clk);
                    #1;
                    req[side].aw_valid = 0;
                end
                begin
                    @(posedge clk);
                    while (!resp[side].w_ready) @(posedge clk);
                    #1;
                    req[side].w_valid = 0;
                end
                begin
                    @(posedge clk);
                    while (!resp[side].ar_ready) @(posedge clk);
                    #1;
                    req[side].ar_valid = 0;
                end
            join
            @(posedge clk);
            while (!(resp[side].b_valid && resp[side].r_valid)) @(posedge clk);
            check(1, {31'b0, resp[side].b_valid}, "B response pending before reset");
            check(1, {31'b0, resp[side].r_valid}, "R response pending before reset");
        end
    endtask

    initial begin
        req[0] = '0;
        req[1] = '0;
        for (k = 0; k < 4; k++) expected[k] = 0;
        #23;
        rst_n = 1;
        for (order = -3; order <= 3; order += 3)
            for (hold_cycles = 0; hold_cycles <= 3; hold_cycles += 3)
                for (strb = 0; strb < 16; strb++) begin
                    a = strb % 4;
                    data = 32'hA5123400 ^ (32'(cases) * 32'h10203);
                    fork
                        write_one(0, 32'(a*4), data, 4'(strb), order, hold_cycles, 0);
                        write_one(1, 32'(a*4), data, 4'(strb), order, hold_cycles, 0);
                    join
                    for (lane = 0; lane < 4; lane++)
                        if (strb & (1 << lane)) expected[a][lane*8+:8] = data[lane*8+:8];
                    fork
                        read_one(0, 32'(a*4), expected[a], hold_cycles, 0);
                        read_one(1, 32'(a*4), expected[a], hold_cycles, 0);
                    join
                    cases++;
                end
        fork
            write_one(0, 16, '1, 15, -3, 3, 2);
            write_one(1, 16, '1, 15, -3, 3, 2);
        join
        fork
            read_one(0, 16, 32'h13579BDF, 3, 0);
            read_one(1, 16, 32'h13579BDF, 3, 0);
        join
        fork
            write_one(0, 28, '1, 15, 3, 3, 2);
            write_one(1, 28, '1, 15, 3, 3, 2);
        join
        fork
            read_one(0, 28, 0, 3, 2);
            // PULP returns its diagnostic word on SLVERR; ours returns zero.
            // Error payload is policy, while the response code must agree.
            read_one(1, 28, 32'hBA5E1E55, 3, 2);
        join
        fork
            prime_reset(0);
            prime_reset(1);
        join
        @(posedge clk);
        #2;
        rst_n = 0;
        #1;
        for (k = 0; k < 2; k++) begin
            check(0, {31'b0, resp[k].b_valid}, "reset clears BVALID before next edge");
            check(0, {31'b0, resp[k].r_valid}, "reset clears RVALID before next edge");
        end
        #11;
        rst_n = 1;
        fork
            read_one(0, 0, 0, 0, 0);
            read_one(1, 0, 0, 0, 0);
        join
        if (errors == 0) $display("== PULP REGISTERS: ALL TESTS PASSED (%0d strobe/order/stall cases + RO/unmapped/reset) ==", cases);
        finish_test;
    end
    initial begin
        #100000;
        $fatal(1, "FAIL: PULP register comparison timeout");
    end
endmodule
