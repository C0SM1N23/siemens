// AXI4-Lite wiring macros: one ~20-signal bundle per port, so a port is
// declared/connected in one line instead of twenty. Token-pasting (``) builds
// the names: `p` is a wire prefix, `px` a module's port prefix (dbus_axi,
// s_axi, m, s0, s1). AXIL_M = full port, AXIL_M_RD = read-only (AR/R),
// AXIL_BARE = a model with bare `awaddr`-style ports (no prot), AXIL_NP =
// prefixed ports without prot (the arb2 m0/m1/s side), AXIL_BARE_RD +
// AXIL_BARE_WR_TIEOFF = a mem model used read-only (the imem hookup). Shared
// by both testbenches; the RTL never sees these.
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

`define AXIL_M(px, w) \
  .px``_awaddr(w``_awaddr), .px``_awprot(w``_awprot), .px``_awvalid(w``_awvalid), .px``_awready(w``_awready), \
  .px``_wdata(w``_wdata), .px``_wstrb(w``_wstrb), .px``_wvalid(w``_wvalid), .px``_wready(w``_wready), \
  .px``_bresp(w``_bresp), .px``_bvalid(w``_bvalid), .px``_bready(w``_bready), \
  .px``_araddr(w``_araddr), .px``_arprot(w``_arprot), .px``_arvalid(w``_arvalid), .px``_arready(w``_arready), \
  .px``_rdata(w``_rdata), .px``_rresp(w``_rresp), .px``_rvalid(w``_rvalid), .px``_rready(w``_rready)

`define AXIL_M_RD(px, w) \
  .px``_araddr(w``_araddr), .px``_arprot(w``_arprot), .px``_arvalid(w``_arvalid), .px``_arready(w``_arready), \
  .px``_rdata(w``_rdata), .px``_rresp(w``_rresp), .px``_rvalid(w``_rvalid), .px``_rready(w``_rready)

`define AXIL_BARE(w) \
  .awaddr(w``_awaddr), .awvalid(w``_awvalid), .awready(w``_awready), \
  .wdata(w``_wdata), .wstrb(w``_wstrb), .wvalid(w``_wvalid), .wready(w``_wready), \
  .bresp(w``_bresp), .bvalid(w``_bvalid), .bready(w``_bready), \
  .araddr(w``_araddr), .arvalid(w``_arvalid), .arready(w``_arready), \
  .rdata(w``_rdata), .rresp(w``_rresp), .rvalid(w``_rvalid), .rready(w``_rready)

// mem model as a read-only slave: AR/R to the bare-port wires, write side
// tied off (outputs left open, inputs quiet)
`define AXIL_BARE_RD(w) \
  .araddr(w``_araddr), .arvalid(w``_arvalid), .arready(w``_arready), \
  .rdata(w``_rdata), .rresp(w``_rresp), .rvalid(w``_rvalid), .rready(w``_rready)

`define AXIL_BARE_WR_TIEOFF \
  .awaddr(32'b0), .awvalid(1'b0), .awready(), \
  .wdata(32'b0), .wstrb(4'b0), .wvalid(1'b0), .wready(), \
  .bresp(), .bvalid(), .bready(1'b0)

`define AXIL_NP(px, w) \
  .px``_awaddr(w``_awaddr), .px``_awvalid(w``_awvalid), .px``_awready(w``_awready), \
  .px``_wdata(w``_wdata), .px``_wstrb(w``_wstrb), .px``_wvalid(w``_wvalid), .px``_wready(w``_wready), \
  .px``_bresp(w``_bresp), .px``_bvalid(w``_bvalid), .px``_bready(w``_bready), \
  .px``_araddr(w``_araddr), .px``_arvalid(w``_arvalid), .px``_arready(w``_arready), \
  .px``_rdata(w``_rdata), .px``_rresp(w``_rresp), .px``_rvalid(w``_rvalid), .px``_rready(w``_rready)

`endif
