// AXI4-Lite wiring macros: one ~20-signal bundle per port, so a port is
// declared or connected in one line instead of twenty. Token-pasting (``)
// builds the names: `p` is a wire prefix, `px` a module's port prefix
// (dbus_axi, s_axi, m, s0, s1).
//
// Since every port now carries a direction suffix, a bundle macro has to know
// which SIDE of the link it is wiring: the same channel is an output on a
// master port and an input on a slave port. Hence the _MST / _SLV pairs. The
// wire names themselves are unsuffixed - a wire has no direction - so only the
// port side of each connection changes between the two.
//
//   AXIL_WIRES / AXIL_RD_WIRES  declare a bundle of wires
//   AXIL_MST / AXIL_SLV         full port, prefixed names, with AxPROT
//   AXIL_MST_RD                 read-only master port (AR/R only)
//   AXIL_NP_MST / AXIL_NP_SLV   prefixed names without AxPROT (the arb2 sides)
//   AXIL_BARE_SLV              bare awaddr-style slave ports (the mem model)
//   AXIL_BARE_MON              bare ports, all inputs (the passive monitor)
//   AXIL_BARE_RD_SLV +
//     AXIL_BARE_WR_TIEOFF      a mem model used read-only (the imem hookup)
//
// Shared by the testbenches; the RTL never sees these.
`ifndef AXI_LITE_MACROS_VH
`define AXI_LITE_MACROS_VH

`define AXIL_WIRES(p) \
  wire [31:0] p``_awaddr, p``_wdata, p``_araddr, p``_rdata; \
  wire [2:0]  p``_awprot, p``_arprot; \
  wire [3:0]  p``_wstrb; \
  wire        p``_awvalid, p``_awready, p``_wvalid, p``_wready, p``_bvalid, p``_bready; \
  wire        p``_arvalid, p``_arready, p``_rvalid, p``_rready; \
  wire [1:0]  p``_bresp, p``_rresp

`define AXIL_RD_WIRES(p) \
  wire [31:0] p``_araddr, p``_rdata; \
  wire [2:0]  p``_arprot; \
  wire        p``_arvalid, p``_arready, p``_rvalid, p``_rready; \
  wire [1:0]  p``_rresp

// --- full port, master side: address/data/valid out, ready/response in -------
`define AXIL_MST(px, w) \
  .px``_awaddr_o(w``_awaddr), .px``_awprot_o(w``_awprot), .px``_awvalid_o(w``_awvalid), .px``_awready_i(w``_awready), \
  .px``_wdata_o(w``_wdata), .px``_wstrb_o(w``_wstrb), .px``_wvalid_o(w``_wvalid), .px``_wready_i(w``_wready), \
  .px``_bresp_i(w``_bresp), .px``_bvalid_i(w``_bvalid), .px``_bready_o(w``_bready), \
  .px``_araddr_o(w``_araddr), .px``_arprot_o(w``_arprot), .px``_arvalid_o(w``_arvalid), .px``_arready_i(w``_arready), \
  .px``_rdata_i(w``_rdata), .px``_rresp_i(w``_rresp), .px``_rvalid_i(w``_rvalid), .px``_rready_o(w``_rready)

// --- full port, slave side: the mirror of the above --------------------------
`define AXIL_SLV(px, w) \
  .px``_awaddr_i(w``_awaddr), .px``_awprot_i(w``_awprot), .px``_awvalid_i(w``_awvalid), .px``_awready_o(w``_awready), \
  .px``_wdata_i(w``_wdata), .px``_wstrb_i(w``_wstrb), .px``_wvalid_i(w``_wvalid), .px``_wready_o(w``_wready), \
  .px``_bresp_o(w``_bresp), .px``_bvalid_o(w``_bvalid), .px``_bready_i(w``_bready), \
  .px``_araddr_i(w``_araddr), .px``_arprot_i(w``_arprot), .px``_arvalid_i(w``_arvalid), .px``_arready_o(w``_arready), \
  .px``_rdata_o(w``_rdata), .px``_rresp_o(w``_rresp), .px``_rvalid_o(w``_rvalid), .px``_rready_i(w``_rready)

// --- read-only master port (instruction fetch) -------------------------------
`define AXIL_MST_RD(px, w) \
  .px``_araddr_o(w``_araddr), .px``_arprot_o(w``_arprot), .px``_arvalid_o(w``_arvalid), .px``_arready_i(w``_arready), \
  .px``_rdata_i(w``_rdata), .px``_rresp_i(w``_rresp), .px``_rvalid_i(w``_rvalid), .px``_rready_o(w``_rready)

// --- prefixed ports without AxPROT (the arb2 m0/m1 and s sides) --------------
`define AXIL_NP_SLV(px, w) \
  .px``_awaddr_i(w``_awaddr), .px``_awvalid_i(w``_awvalid), .px``_awready_o(w``_awready), \
  .px``_wdata_i(w``_wdata), .px``_wstrb_i(w``_wstrb), .px``_wvalid_i(w``_wvalid), .px``_wready_o(w``_wready), \
  .px``_bresp_o(w``_bresp), .px``_bvalid_o(w``_bvalid), .px``_bready_i(w``_bready), \
  .px``_araddr_i(w``_araddr), .px``_arvalid_i(w``_arvalid), .px``_arready_o(w``_arready), \
  .px``_rdata_o(w``_rdata), .px``_rresp_o(w``_rresp), .px``_rvalid_o(w``_rvalid), .px``_rready_i(w``_rready)

`define AXIL_NP_MST(px, w) \
  .px``_awaddr_o(w``_awaddr), .px``_awvalid_o(w``_awvalid), .px``_awready_i(w``_awready), \
  .px``_wdata_o(w``_wdata), .px``_wstrb_o(w``_wstrb), .px``_wvalid_o(w``_wvalid), .px``_wready_i(w``_wready), \
  .px``_bresp_i(w``_bresp), .px``_bvalid_i(w``_bvalid), .px``_bready_o(w``_bready), \
  .px``_araddr_o(w``_araddr), .px``_arvalid_o(w``_arvalid), .px``_arready_i(w``_arready), \
  .px``_rdata_i(w``_rdata), .px``_rresp_i(w``_rresp), .px``_rvalid_i(w``_rvalid), .px``_rready_o(w``_rready)

// --- bare ports (no prefix): the behavioural memory, a slave -----------------
`define AXIL_BARE_SLV(w) \
  .awaddr_i(w``_awaddr), .awvalid_i(w``_awvalid), .awready_o(w``_awready), \
  .wdata_i(w``_wdata), .wstrb_i(w``_wstrb), .wvalid_i(w``_wvalid), .wready_o(w``_wready), \
  .bresp_o(w``_bresp), .bvalid_o(w``_bvalid), .bready_i(w``_bready), \
  .araddr_i(w``_araddr), .arvalid_i(w``_arvalid), .arready_o(w``_arready), \
  .rdata_o(w``_rdata), .rresp_o(w``_rresp), .rvalid_o(w``_rvalid), .rready_i(w``_rready)

// --- bare ports: the passive monitor, which only ever observes ---------------
`define AXIL_BARE_MON(w) \
  .awaddr_i(w``_awaddr), .awvalid_i(w``_awvalid), .awready_i(w``_awready), \
  .wdata_i(w``_wdata), .wstrb_i(w``_wstrb), .wvalid_i(w``_wvalid), .wready_i(w``_wready), \
  .bresp_i(w``_bresp), .bvalid_i(w``_bvalid), .bready_i(w``_bready), \
  .araddr_i(w``_araddr), .arvalid_i(w``_arvalid), .arready_i(w``_arready), \
  .rdata_i(w``_rdata), .rresp_i(w``_rresp), .rvalid_i(w``_rvalid), .rready_i(w``_rready)

// --- a memory model used read-only: AR/R wired, write side tied off ----------
`define AXIL_BARE_RD_SLV(w) \
  .araddr_i(w``_araddr), .arvalid_i(w``_arvalid), .arready_o(w``_arready), \
  .rdata_o(w``_rdata), .rresp_o(w``_rresp), .rvalid_o(w``_rvalid), .rready_i(w``_rready)

`define AXIL_BARE_WR_TIEOFF \
  .awaddr_i(32'b0), .awvalid_i(1'b0), .awready_o(), \
  .wdata_i(32'b0), .wstrb_i(4'b0), .wvalid_i(1'b0), .wready_o(), \
  .bresp_o(), .bvalid_o(), .bready_i(1'b0)

`endif
