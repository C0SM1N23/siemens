// 2-master -> 1-slave AXI4-Lite arbiter, testbench model only.
//
// Stands in for the SoC interconnect so the dual-core TB can share one memory
// between two CPUs.
//
// Round-robin, one transaction locked at a time: grant on an AR / AW+W request,
// release on the R or B beat. The parked master just sees its READYs low, which
// AXI allows indefinitely, so no master is protocol-starved. Relies on the CPUs'
// own contract (1 outstanding, never read+write at once), which the protocol
// monitor checks separately.

module axi_lite_arb2 (
    input             clk,
    input             rst_n,

    // master 0 (slave-side ports facing CPU 0)
    input      [31:0] m0_awaddr,
    input             m0_awvalid,
    output            m0_awready,
    input      [31:0] m0_wdata,
    input      [3:0]  m0_wstrb,
    input             m0_wvalid,
    output            m0_wready,
    output     [1:0]  m0_bresp,
    output            m0_bvalid,
    input             m0_bready,
    input      [31:0] m0_araddr,
    input             m0_arvalid,
    output            m0_arready,
    output     [31:0] m0_rdata,
    output     [1:0]  m0_rresp,
    output            m0_rvalid,
    input             m0_rready,

    // master 1 (facing CPU 1)
    input      [31:0] m1_awaddr,
    input             m1_awvalid,
    output            m1_awready,
    input      [31:0] m1_wdata,
    input      [3:0]  m1_wstrb,
    input             m1_wvalid,
    output            m1_wready,
    output     [1:0]  m1_bresp,
    output            m1_bvalid,
    input             m1_bready,
    input      [31:0] m1_araddr,
    input             m1_arvalid,
    output            m1_arready,
    output     [31:0] m1_rdata,
    output     [1:0]  m1_rresp,
    output            m1_rvalid,
    input             m1_rready,

    // shared slave
    output     [31:0] s_awaddr,
    output            s_awvalid,
    input             s_awready,
    output     [31:0] s_wdata,
    output     [3:0]  s_wstrb,
    output            s_wvalid,
    input             s_wready,
    input      [1:0]  s_bresp,
    input             s_bvalid,
    output            s_bready,
    output     [31:0] s_araddr,
    output            s_arvalid,
    input             s_arready,
    input      [31:0] s_rdata,
    input      [1:0]  s_rresp,
    input             s_rvalid,
    output            s_rready
);

reg busy, grant, last, kind_rd;

wire req0 = m0_arvalid | m0_awvalid;
wire req1 = m1_arvalid | m1_awvalid;
// round-robin: whoever didn't go last wins a tie
wire pick = (req0 && req1) ? ~last : req1;

wire done = kind_rd ? (s_rvalid && s_rready) : (s_bvalid && s_bready);

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        busy <= 0; grant <= 0; last <= 0; kind_rd <= 0;
    end else if (!busy) begin
        if (req0 || req1) begin
            busy    <= 1;
            grant   <= pick;
            last    <= pick;
            kind_rd <= pick ? m1_arvalid : m0_arvalid;
        end
    end else if (done)
        busy <= 0;
end

// granted master drives the slave; the other one waits on low READYs
assign s_arvalid = busy && (grant ? m1_arvalid : m0_arvalid);
assign s_araddr  =          grant ? m1_araddr  : m0_araddr;
assign s_awvalid = busy && (grant ? m1_awvalid : m0_awvalid);
assign s_awaddr  =          grant ? m1_awaddr  : m0_awaddr;
assign s_wvalid  = busy && (grant ? m1_wvalid  : m0_wvalid);
assign s_wdata   =          grant ? m1_wdata   : m0_wdata;
assign s_wstrb   =          grant ? m1_wstrb   : m0_wstrb;
assign s_rready  = busy && (grant ? m1_rready  : m0_rready);
assign s_bready  = busy && (grant ? m1_bready  : m0_bready);

assign m0_arready = (busy && !grant) ? s_arready : 1'b0;
assign m0_awready = (busy && !grant) ? s_awready : 1'b0;
assign m0_wready  = (busy && !grant) ? s_wready  : 1'b0;
assign m0_rvalid  = (busy && !grant) ? s_rvalid  : 1'b0;
assign m0_bvalid  = (busy && !grant) ? s_bvalid  : 1'b0;
assign m0_rdata   = s_rdata;
assign m0_rresp   = s_rresp;
assign m0_bresp   = s_bresp;

assign m1_arready = (busy && grant) ? s_arready : 1'b0;
assign m1_awready = (busy && grant) ? s_awready : 1'b0;
assign m1_wready  = (busy && grant) ? s_wready  : 1'b0;
assign m1_rvalid  = (busy && grant) ? s_rvalid  : 1'b0;
assign m1_bvalid  = (busy && grant) ? s_bvalid  : 1'b0;
assign m1_rdata   = s_rdata;
assign m1_rresp   = s_rresp;
assign m1_bresp   = s_bresp;

endmodule
