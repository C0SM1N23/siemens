// Bind file for the SoC - attaches the checkers to the RTL without touching
// it. Compile last, after the RTL and the sva modules.
//
// Binding by module, not by instance, is deliberate: every decoder in the
// design gets a checker whether there are three of them or thirty, and a
// decoder added later is covered the moment it is instantiated. The parameter
// is forwarded from the target (`#(.N(N))`), so one bind covers instances of
// different widths.
//
// The CPU block's own bind file (cpu/debug/sva/bind_sva.sv) already covers
// cpu_top's two ports and the PIC and timer slave ports, and it is reused here
// unchanged. What this file adds is everything the CPU block never saw: the
// fabric's internal decisions, the DMA's AXI4-Full port, the burst bridge, and
// the slave ports of the memories and the SRAM.

`timescale 1ns/1ps

// ===========================================================================
// protocol on the fabric ports the CPU block's bind file does not reach
// ===========================================================================

// the burst bridge's AXI4-Lite master side: what the DMA looks like to the
// fabric once its bursts have been split
bind axi_full2lite axi_lite_sva #(
    .NAME("dma_lite"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) lite_port_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  (m_awaddr_o),
    .awvalid_i (m_awvalid_o),
    .awready_i (m_awready_i),
    .wdata_i   (m_wdata_o),
    .wstrb_i   (m_wstrb_o),
    .wvalid_i  (m_wvalid_o),
    .wready_i  (m_wready_i),
    .bresp_i   (m_bresp_i),
    .bvalid_i  (m_bvalid_i),
    .bready_i  (m_bready_o),
    .araddr_i  (m_araddr_o),
    .arvalid_i (m_arvalid_o),
    .arready_i (m_arready_i),
    .rdata_i   (m_rdata_i),
    .rresp_i   (m_rresp_i),
    .rvalid_i  (m_rvalid_i),
    .rready_i  (m_rready_o)
);

// the arbiter's slave side: the single stream the shared memory actually sees
bind axi_lite_arb axi_lite_sva #(
    .NAME("arb_out"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) arb_out_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  (s_awaddr_o),
    .awvalid_i (s_awvalid_o[0]),
    .awready_i (s_awready_i),
    .wdata_i   (s_wdata_o),
    .wstrb_i   (s_wstrb_o),
    .wvalid_i  (s_wvalid_o[0]),
    .wready_i  (s_wready_i),
    .bresp_i   (s_bresp_i),
    .bvalid_i  (s_bvalid_i),
    .bready_i  (s_bready_o[0]),
    .araddr_i  (s_araddr_o),
    .arvalid_i (s_arvalid_o[0]),
    .arready_i (s_arready_i),
    .rdata_i   (s_rdata_i),
    .rresp_i   (s_rresp_i),
    .rvalid_i  (s_rvalid_i),
    .rready_i  (s_rready_o[0])
);

// both memories: one bind, two instances (IMEM and DMEM)
bind axi_lite_ram axi_lite_sva #(
    .NAME("ram_s"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) ram_port_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  (s_awaddr_i),
    .awvalid_i (s_awvalid_i),
    .awready_i (s_awready_o),
    .wdata_i   (s_wdata_i),
    .wstrb_i   (s_wstrb_i),
    .wvalid_i  (s_wvalid_i),
    .wready_i  (s_wready_o),
    .bresp_i   (s_bresp_o),
    .bvalid_i  (s_bvalid_o),
    .bready_i  (s_bready_i),
    .araddr_i  (s_araddr_i),
    .arvalid_i (s_arvalid_i),
    .arready_i (s_arready_o),
    .rdata_i   (s_rdata_o),
    .rresp_i   (s_rresp_o),
    .rvalid_i  (s_rvalid_o),
    .rready_i  (s_rready_i)
);

// the DMA's AXI4-Lite register slave
bind mc_dma_top axi_lite_sva #(
    .NAME("dma_regs"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) dma_regs_sva_i (
    .clk_i     (clk),
    .rst_n_i   (rst_n),
    .awaddr_i  (s_axi_awaddr),
    .awvalid_i (s_axi_awvalid),
    .awready_i (s_axi_awready),
    .wdata_i   (s_axi_wdata),
    .wstrb_i   (s_axi_wstrb),
    .wvalid_i  (s_axi_wvalid),
    .wready_i  (s_axi_wready),
    .bresp_i   (s_axi_bresp),
    .bvalid_i  (s_axi_bvalid),
    .bready_i  (s_axi_bready),
    .araddr_i  (s_axi_araddr),
    .arvalid_i (s_axi_arvalid),
    .arready_i (s_axi_arready),
    .rdata_i   (s_axi_rdata),
    .rresp_i   (s_axi_rresp),
    .rvalid_i  (s_axi_rvalid),
    .rready_i  (s_axi_rready)
);

// the dual-port SRAM, one checker per port. Its addresses are 10 bits wide -
// the window size - so they are zero-extended to the checker's 32.
bind dp_sram_top axi_lite_sva #(
    .NAME("sram_a"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) sram_a_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  ({22'b0, a_awaddr_i}),
    .awvalid_i (a_awvalid_i),
    .awready_i (a_awready_o),
    .wdata_i   (a_wdata_i),
    .wstrb_i   (a_wstrb_i),
    .wvalid_i  (a_wvalid_i),
    .wready_i  (a_wready_o),
    .bresp_i   (a_bresp_o),
    .bvalid_i  (a_bvalid_o),
    .bready_i  (a_bready_i),
    .araddr_i  ({22'b0, a_araddr_i}),
    .arvalid_i (a_arvalid_i),
    .arready_i (a_arready_o),
    .rdata_i   (a_rdata_o),
    .rresp_i   (a_rresp_o),
    .rvalid_i  (a_rvalid_o),
    .rready_i  (a_rready_i)
);

bind dp_sram_top axi_lite_sva #(
    .NAME("sram_b"), .HAS_WRITE(1), .CHECK_ALIGN(0)
) sram_b_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  ({22'b0, b_awaddr_i}),
    .awvalid_i (b_awvalid_i),
    .awready_i (b_awready_o),
    .wdata_i   (b_wdata_i),
    .wstrb_i   (b_wstrb_i),
    .wvalid_i  (b_wvalid_i),
    .wready_i  (b_wready_o),
    .bresp_i   (b_bresp_o),
    .bvalid_i  (b_bvalid_o),
    .bready_i  (b_bready_i),
    .araddr_i  ({22'b0, b_araddr_i}),
    .arvalid_i (b_arvalid_i),
    .arready_i (b_arready_o),
    .rdata_i   (b_rdata_o),
    .rresp_i   (b_rresp_o),
    .rvalid_i  (b_rvalid_o),
    .rready_i  (b_rready_i)
);

// ===========================================================================
// AXI4-Full on the DMA's master port, watched from the bridge's slave side
// ===========================================================================
// Protocol only. The subset assertions are off here because tb_full2lite
// drives an unsupported burst on purpose; they are asserted on the DMA's own
// port below, which is where they are a statement about the design.
bind axi_full2lite axi_full_sva #(
    .NAME("dma_full"), .CHECK_SUBSET(0)
) full_port_sva_i (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .awaddr_i  (s_awaddr_i),
    .awlen_i   (s_awlen_i),
    .awsize_i  (s_awsize_i),
    .awburst_i (s_awburst_i),
    .awvalid_i (s_awvalid_i),
    .awready_i (s_awready_o),
    .wdata_i   (s_wdata_i),
    .wstrb_i   (s_wstrb_i),
    .wlast_i   (s_wlast_i),
    .wvalid_i  (s_wvalid_i),
    .wready_i  (s_wready_o),
    .bresp_i   (s_bresp_o),
    .bvalid_i  (s_bvalid_o),
    .bready_i  (s_bready_i),
    .araddr_i  (s_araddr_i),
    .arlen_i   (s_arlen_i),
    .arsize_i  (s_arsize_i),
    .arburst_i (s_arburst_i),
    .arvalid_i (s_arvalid_i),
    .arready_i (s_arready_o),
    .rdata_i   (s_rdata_o),
    .rresp_i   (s_rresp_o),
    .rlast_i   (s_rlast_o),
    .rvalid_i  (s_rvalid_o),
    .rready_i  (s_rready_i)
);

// ===========================================================================
// the fabric's own decisions
// ===========================================================================
bind axi_lite_dec axi_lite_dec_sva #(
    .NAME("dec"), .N(N)
) dec_sva_i (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .aw_hit_i    (aw_hit),
    .ar_hit_i    (ar_hit),
    .aw_none_i   (aw_none),
    .ar_none_i   (ar_none),
    .wr_sel_q_i  (wr_sel_q),
    .rd_sel_q_i  (rd_sel_q),
    .wr_err_q_i  (wr_err_q),
    .rd_err_q_i  (rd_err_q),
    .m_awvalid_i (m_awvalid_i),
    .m_awready_i (m_awready_o),
    .m_arvalid_i (m_arvalid_i),
    .m_arready_i (m_arready_o),
    .m_bvalid_i  (m_bvalid_o),
    .m_bresp_i   (m_bresp_o),
    .m_rvalid_i  (m_rvalid_o),
    .m_rresp_i   (m_rresp_o),
    .s_awvalid_i (s_awvalid_o),
    .s_arvalid_i (s_arvalid_o)
);

bind axi_lite_arb axi_lite_arb_sva #(
    .NAME("arb"), .M(M)
) arb_sva_i (
    .clk_i         (clk_i),
    .rst_n_i       (rst_n_i),
    .gnt_i         (gnt),
    .req_i         (req),
    .sel_i         (sel),
    .release_gnt_i (release_gnt),
    .m_awready_i   (m_awready_o),
    .m_wready_i    (m_wready_o),
    .m_arready_i   (m_arready_o),
    .m_bvalid_i    (m_bvalid_o),
    .m_rvalid_i    (m_rvalid_o),
    .s_awvalid_i   (s_awvalid_o[0]),
    .s_wvalid_i    (s_wvalid_o[0]),
    .s_arvalid_i   (s_arvalid_o[0])
);

bind axi_full2lite axi_full2lite_sva #(
    .NAME("bridge")
) bridge_sva_i (
    .clk_i      (clk_i),
    .rst_n_i    (rst_n_i),
    .r_state_i  (r_state),
    .r_len_i    (r_len),
    .r_beat_i   (r_beat),
    .r_addr_i   (r_addr),
    .r_fixed_i  (r_fixed),
    .w_state_i  (w_state),
    .w_len_i    (w_len),
    .w_beat_i   (w_beat),
    .w_addr_i   (w_addr),
    .w_fixed_i  (w_fixed),
    .w_resp_i   (w_resp),
    .s_rvalid_i (s_rvalid_o),
    .s_rready_i (s_rready_i),
    .s_rlast_i  (s_rlast_o),
    .s_bvalid_i (s_bvalid_o),
    .s_bresp_i  (s_bresp_o),
    .m_arvalid_i(m_arvalid_o),
    .m_awvalid_i(m_awvalid_o),
    .m_bvalid_i (m_bvalid_i),
    .m_bready_i (m_bready_o),
    .m_bresp_i  (m_bresp_i)
);

// The DMA's master port, checked against the subset the fabric supports. This
// bind only exists where mc_dma_top does, so it never sees the bridge's own
// bench. The protocol assertions duplicate the ones above on the same wires -
// harmless, and it keeps one checker instead of two.
bind mc_dma_top axi_full_sva #(
    .NAME("dma_master"), .CHECK_SUBSET(1)
) dma_master_sva_i (
    .clk_i     (clk),
    .rst_n_i   (rst_n),
    .awaddr_i  (m_axi_awaddr),
    .awlen_i   (m_axi_awlen),
    .awsize_i  (m_axi_awsize),
    .awburst_i (m_axi_awburst),
    .awvalid_i (m_axi_awvalid),
    .awready_i (m_axi_awready),
    .wdata_i   (m_axi_wdata),
    .wstrb_i   (m_axi_wstrb),
    .wlast_i   (m_axi_wlast),
    .wvalid_i  (m_axi_wvalid),
    .wready_i  (m_axi_wready),
    .bresp_i   (m_axi_bresp),
    .bvalid_i  (m_axi_bvalid),
    .bready_i  (m_axi_bready),
    .araddr_i  (m_axi_araddr),
    .arlen_i   (m_axi_arlen),
    .arsize_i  (m_axi_arsize),
    .arburst_i (m_axi_arburst),
    .arvalid_i (m_axi_arvalid),
    .arready_i (m_axi_arready),
    .rdata_i   (m_axi_rdata),
    .rresp_i   (m_axi_rresp),
    .rlast_i   (m_axi_rlast),
    .rvalid_i  (m_axi_rvalid),
    .rready_i  (m_axi_rready)
);
