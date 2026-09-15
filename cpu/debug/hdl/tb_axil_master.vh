// AXI4-Lite master driver tasks, shared by the block-level testbenches
// (pic_tb_feature, pic_tb_reset, pic_tb_ro, pic_tb_status, mtimer_tb_regs).
//
// Included inside a module body that has already declared the master-side
// signals with these exact names, plus `integer errors;`, `reg [31:0] rd;` and
// the `check` task from tb_check.vh:
//
//   reg  [31:0] awaddr, wdata, araddr;   reg [3:0] wstrb;
//   reg         awvalid, wvalid, bready, arvalid, rready;
//   wire        awready, wready, bvalid, arready, rvalid;
//   wire [1:0]  bresp, rresp;            wire [31:0] rdata;
//
// Deliberately no include guard: the tasks are module-scoped, so every bench
// needs its own textual copy even when several compile in one vlog call.
//
// The contract driven here is the one axi_lite_slave implements: at most one
// transaction per direction. AW and W are launched together and their
// handshakes are accepted in either order, which is what exercises the slave's
// independent AW/W collection. Stimulus changes at #1 after a posedge, so the
// driver never races the DUT's own clock edge.

integer axil_cycle = 0;
integer axil_read_cycle;
always @(posedge clk) axil_cycle <= axil_cycle + 1;

// Full write with explicit byte strobes. `exp` is the BRESP that must come back.
task axil_write_strb(input [31:0] a, input [31:0] d, input [3:0] strb, input [1:0] exp);
    reg aw_ok, w_ok;
    begin
        @(negedge clk);
        awaddr = a; awvalid = 1; wdata = d; wstrb = strb; wvalid = 1;
        bready = 0; aw_ok = 0; w_ok = 0;
        while (!aw_ok || !w_ok) begin
            @(posedge clk);
            if (awvalid && awready) aw_ok = 1;
            if (wvalid && wready) w_ok = 1;
            @(negedge clk);
            if (aw_ok) awvalid = 0;
            if (w_ok) wvalid = 0;
        end
        bready = 1;
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        check({30'b0, exp}, {30'b0, bresp}, "write response");
        @(negedge clk);
        bready = 0;
    end
endtask

// Word write (all four lanes), the common case.
task axil_write(input [31:0] a, input [31:0] d, input [1:0] exp);
    begin
        axil_write_strb(a, d, 4'hF, exp);
    end
endtask

// Read; the data lands in `rd`. `exp` is the RRESP that must come back.
task axil_read(input [31:0] a, input [1:0] exp);
    begin
        @(negedge clk);
        araddr = a; arvalid = 1; rready = 0;
        @(posedge clk);
        while (!arready) @(posedge clk);
        axil_read_cycle = axil_cycle;
        @(negedge clk);
        arvalid = 0; rready = 1;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        rd = rdata;
        check({30'b0, exp}, {30'b0, rresp}, "read response");
        @(negedge clk);
        rready = 0;
    end
endtask

// Read and compare in one step: the shape most register checks want.
task axil_read_chk(input [31:0] a, input [31:0] expect_data, input [511:0] name);
    begin
        axil_read(a, 2'b00);
        check(expect_data, rd, name);
    end
endtask

// Park every master-side signal. Call before releasing reset.
task axil_idle;
    begin
        awaddr = 32'b0; wdata = 32'b0; wstrb = 4'b0; araddr = 32'b0;
        awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0; arvalid = 1'b0; rready = 1'b0;
    end
endtask

// Advance n clock cycles.
task axil_step(input integer n);
    integer k;
    begin
        for (k = 0; k < n; k = k + 1) @(posedge clk);
    end
endtask
