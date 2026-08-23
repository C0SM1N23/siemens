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

`timescale 1ns/1ps

module axi_lite_arb2 (
    input             clk_i,
    input             rst_n_i,

    // master 0 (slave-side ports facing CPU 0)
    input      [31:0] m0_awaddr_i,
    input             m0_awvalid_i,
    output            m0_awready_o,
    input      [31:0] m0_wdata_i,
    input      [3:0]  m0_wstrb_i,
    input             m0_wvalid_i,
    output            m0_wready_o,
    output     [1:0]  m0_bresp_o,
    output            m0_bvalid_o,
    input             m0_bready_i,
    input      [31:0] m0_araddr_i,
    input             m0_arvalid_i,
    output            m0_arready_o,
    output     [31:0] m0_rdata_o,
    output     [1:0]  m0_rresp_o,
    output            m0_rvalid_o,
    input             m0_rready_i,

    // master 1 (facing CPU 1)
    input      [31:0] m1_awaddr_i,
    input             m1_awvalid_i,
    output            m1_awready_o,
    input      [31:0] m1_wdata_i,
    input      [3:0]  m1_wstrb_i,
    input             m1_wvalid_i,
    output            m1_wready_o,
    output     [1:0]  m1_bresp_o,
    output            m1_bvalid_o,
    input             m1_bready_i,
    input      [31:0] m1_araddr_i,
    input             m1_arvalid_i,
    output            m1_arready_o,
    output     [31:0] m1_rdata_o,
    output     [1:0]  m1_rresp_o,
    output            m1_rvalid_o,
    input             m1_rready_i,

    // shared slave
    output     [31:0] s_awaddr_o,
    output            s_awvalid_o,
    input             s_awready_i,
    output     [31:0] s_wdata_o,
    output     [3:0]  s_wstrb_o,
    output            s_wvalid_o,
    input             s_wready_i,
    input      [1:0]  s_bresp_i,
    input             s_bvalid_i,
    output            s_bready_o,
    output     [31:0] s_araddr_o,
    output            s_arvalid_o,
    input             s_arready_i,
    input      [31:0] s_rdata_i,
    input      [1:0]  s_rresp_i,
    input             s_rvalid_i,
    output            s_rready_o
);

reg busy, grant, last, kind_rd;

wire req0 = m0_arvalid_i | m0_awvalid_i;
wire req1 = m1_arvalid_i | m1_awvalid_i;
// round-robin: whoever didn't go last wins a tie
wire pick = (req0 && req1) ? ~last : req1;

wire done = kind_rd ? (s_rvalid_i && s_rready_o) : (s_bvalid_i && s_bready_o);

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        busy <= 0; grant <= 0; last <= 0; kind_rd <= 0;
    end else if (!busy) begin
        if (req0 || req1) begin
            busy    <= 1;
            grant   <= pick;
            last    <= pick;
            kind_rd <= pick ? m1_arvalid_i : m0_arvalid_i;
        end
    end else if (done)
        busy <= 0;
end

// granted master drives the slave; the other one waits on low READYs
assign s_arvalid_o = busy && (grant ? m1_arvalid_i : m0_arvalid_i);
assign s_araddr_o  =          grant ? m1_araddr_i  : m0_araddr_i;
assign s_awvalid_o = busy && (grant ? m1_awvalid_i : m0_awvalid_i);
assign s_awaddr_o  =          grant ? m1_awaddr_i  : m0_awaddr_i;
assign s_wvalid_o  = busy && (grant ? m1_wvalid_i  : m0_wvalid_i);
assign s_wdata_o   =          grant ? m1_wdata_i   : m0_wdata_i;
assign s_wstrb_o   =          grant ? m1_wstrb_i   : m0_wstrb_i;
assign s_rready_o  = busy && (grant ? m1_rready_i  : m0_rready_i);
assign s_bready_o  = busy && (grant ? m1_bready_i  : m0_bready_i);

assign m0_arready_o = (busy && !grant) ? s_arready_i : 1'b0;
assign m0_awready_o = (busy && !grant) ? s_awready_i : 1'b0;
assign m0_wready_o  = (busy && !grant) ? s_wready_i  : 1'b0;
assign m0_rvalid_o  = (busy && !grant) ? s_rvalid_i  : 1'b0;
assign m0_bvalid_o  = (busy && !grant) ? s_bvalid_i  : 1'b0;
assign m0_rdata_o   = s_rdata_i;
assign m0_rresp_o   = s_rresp_i;
assign m0_bresp_o   = s_bresp_i;

assign m1_arready_o = (busy && grant) ? s_arready_i : 1'b0;
assign m1_awready_o = (busy && grant) ? s_awready_i : 1'b0;
assign m1_wready_o  = (busy && grant) ? s_wready_i  : 1'b0;
assign m1_rvalid_o  = (busy && grant) ? s_rvalid_i  : 1'b0;
assign m1_bvalid_o  = (busy && grant) ? s_bvalid_i  : 1'b0;
assign m1_rdata_o   = s_rdata_i;
assign m1_rresp_o   = s_rresp_i;
assign m1_bresp_o   = s_bresp_i;

endmodule
