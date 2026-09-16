// Flat-signal wrapper around pulp-platform/axi's axi_lite_demux, so the same
// bench can drive it and soc_axi_lite_dec with identical stimulus.
//
// This file contains no third-party code. It converts between the packed
// vectors soc_axi_lite_dec uses and the request/response structs the upstream
// module takes, and it supplies the routing decision, which upstream expects as
// an input rather than deriving it from the address. The upstream sources are
// not vendored here; soc/debug/sim/run_pulp_compare.sh fetches them.
//
// Only compiled by that script - it is not in soc_rtl.f and no other flow
// depends on it.
`include "axi/typedef.svh"

module pulp_lite_demux_wrap #(
    parameter int unsigned N = 2,
    parameter int unsigned MaxTrans = 1
) (
    input  logic          clk_i,
    input  logic          rst_n_i,
    input  logic [31:0]   m_awaddr_i,
    input  logic          m_awvalid_i,
    output logic          m_awready_o,
    input  logic [31:0]   m_wdata_i,
    input  logic [3:0]    m_wstrb_i,
    input  logic          m_wvalid_i,
    output logic          m_wready_o,
    output logic [1:0]    m_bresp_o,
    output logic          m_bvalid_o,
    input  logic          m_bready_i,
    input  logic [31:0]   m_araddr_i,
    input  logic          m_arvalid_i,
    output logic          m_arready_o,
    output logic [31:0]   m_rdata_o,
    output logic [1:0]    m_rresp_o,
    output logic          m_rvalid_o,
    input  logic          m_rready_i,
    // the routing decision, supplied by the bench (pulp takes it as an input)
    input  logic [$clog2(N)-1:0] aw_select_i,
    input  logic [$clog2(N)-1:0] ar_select_i,
    // slave side, packed like soc_axi_lite_dec
    output logic [N*32-1:0] s_awaddr_o,
    output logic [N-1:0]    s_awvalid_o,
    input  logic [N-1:0]    s_awready_i,
    output logic [N*32-1:0] s_wdata_o,
    output logic [N*4-1:0]  s_wstrb_o,
    output logic [N-1:0]    s_wvalid_o,
    input  logic [N-1:0]    s_wready_i,
    input  logic [N*2-1:0]  s_bresp_i,
    input  logic [N-1:0]    s_bvalid_i,
    output logic [N-1:0]    s_bready_o,
    output logic [N*32-1:0] s_araddr_o,
    output logic [N-1:0]    s_arvalid_o,
    input  logic [N-1:0]    s_arready_i,
    input  logic [N*32-1:0] s_rdata_i,
    input  logic [N*2-1:0]  s_rresp_i,
    input  logic [N-1:0]    s_rvalid_i,
    output logic [N-1:0]    s_rready_o
);
    `AXI_LITE_TYPEDEF_ALL(lt, logic [31:0], logic [31:0], logic [3:0])

    lt_req_t  slv_req;
    lt_resp_t slv_resp;
    lt_req_t  [N-1:0] mst_reqs;
    lt_resp_t [N-1:0] mst_resps;

    always_comb begin
        slv_req = '0;
        slv_req.aw.addr  = m_awaddr_i;
        slv_req.aw_valid = m_awvalid_i;
        slv_req.w.data   = m_wdata_i;
        slv_req.w.strb   = m_wstrb_i;
        slv_req.w_valid  = m_wvalid_i;
        slv_req.b_ready  = m_bready_i;
        slv_req.ar.addr  = m_araddr_i;
        slv_req.ar_valid = m_arvalid_i;
        slv_req.r_ready  = m_rready_i;
    end

    assign m_awready_o = slv_resp.aw_ready;
    assign m_wready_o  = slv_resp.w_ready;
    assign m_bresp_o   = slv_resp.b.resp;
    assign m_bvalid_o  = slv_resp.b_valid;
    assign m_arready_o = slv_resp.ar_ready;
    assign m_rdata_o   = slv_resp.r.data;
    assign m_rresp_o   = slv_resp.r.resp;
    assign m_rvalid_o  = slv_resp.r_valid;

    for (genvar i = 0; i < N; i++) begin : g_flat
        assign s_awaddr_o[i*32+:32] = mst_reqs[i].aw.addr;
        assign s_awvalid_o[i]       = mst_reqs[i].aw_valid;
        assign s_wdata_o[i*32+:32]  = mst_reqs[i].w.data;
        assign s_wstrb_o[i*4+:4]    = mst_reqs[i].w.strb;
        assign s_wvalid_o[i]        = mst_reqs[i].w_valid;
        assign s_bready_o[i]        = mst_reqs[i].b_ready;
        assign s_araddr_o[i*32+:32] = mst_reqs[i].ar.addr;
        assign s_arvalid_o[i]       = mst_reqs[i].ar_valid;
        assign s_rready_o[i]        = mst_reqs[i].r_ready;

        always_comb begin
            mst_resps[i] = '0;
            mst_resps[i].aw_ready = s_awready_i[i];
            mst_resps[i].w_ready  = s_wready_i[i];
            mst_resps[i].b.resp   = s_bresp_i[i*2+:2];
            mst_resps[i].b_valid  = s_bvalid_i[i];
            mst_resps[i].ar_ready = s_arready_i[i];
            mst_resps[i].r.data   = s_rdata_i[i*32+:32];
            mst_resps[i].r.resp   = s_rresp_i[i*2+:2];
            mst_resps[i].r_valid  = s_rvalid_i[i];
        end
    end

    axi_lite_demux #(
        .aw_chan_t (lt_aw_chan_t),
        .w_chan_t  (lt_w_chan_t),
        .b_chan_t  (lt_b_chan_t),
        .ar_chan_t (lt_ar_chan_t),
        .r_chan_t  (lt_r_chan_t),
        .axi_req_t (lt_req_t),
        .axi_resp_t(lt_resp_t),
        .NoMstPorts(N),
        .MaxTrans  (MaxTrans),
        .SpillAw   (1'b0),
        .SpillAr   (1'b0)
    ) i_demux (
        .clk_i,
        .rst_ni         (rst_n_i),
        .slv_req_i      (slv_req),
        .slv_aw_select_i(aw_select_i),
        .slv_ar_select_i(ar_select_i),
        .slv_resp_o     (slv_resp),
        .mst_reqs_o     (mst_reqs),
        .mst_resps_i    (mst_resps)
    );
endmodule
