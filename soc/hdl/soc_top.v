// SoC top level: RV32I CPU + multi-channel DMA + dual-port SRAM, joined by an
// AXI4-Lite fabric.
//
//                        +----------- ibus (read only) --------> IMEM
//   cpu_top -------------+
//                        +-- dbus --> dec_d --+--> [arb] -----> DMEM
//                                             +--> DP-SRAM port A
//                                             +--> PIC
//                                             +--> machine timer
//                                             +--> DMA registers
//
//   mc_dma_top --(AXI4-Full)--> axi_full2lite --> dec_x --+--> [arb] --> DMEM
//                                                         +--> DP-SRAM port B
//
//   interrupts: DMA irq[3:0] -> PIC 0..3, SRAM irq -> PIC 4,
//               timer -> PIC 7, PIC -> CPU
//
// WHY THE DP-SRAM IS NOT ARBITRATED
// It has two independent AXI ports, so the CPU and the DMA each get one and
// reach the same 1 KB at the same address without ever queueing behind each
// other. That is the entire point of a dual-port memory, and it is also what
// makes the SRAM's own collision detector reachable in the assembled system:
// when both sides touch the same word in the same cycle the block resolves it,
// counts it, and can raise an interrupt. Putting an arbiter in front would
// have serialised the accesses and made that logic dead.
//
// Only DMEM has a single port, so only DMEM gets an arbiter.
//
// CLOCK AND RESET
// One clock, one asynchronous active-low reset, driven into all three blocks.
// The CPU and the SRAM name the pins clk_i/rst_n_i; the DMA names them
// clk/rst_n. The names differ because the DMA block was developed separately
// and renaming its ports would break its own testbenches - see INTEGRATION.md.

`timescale 1ns/1ps

`include "soc_addr_map.vh"

module soc_top #(
    parameter RESET_PC   = `SOC_IMEM_BASE,
    parameter IMEM_INIT  = "",           // $readmemh image for instruction memory
    parameter DMEM_INIT  = "",           // $readmemh image for data memory
    parameter BP_ENTRIES = 128,
    parameter RAS_DEPTH  = 8,

    // Memory timing, verification only - see the header of axi_lite_ram.v.
    // They are surfaced here so the regression can sweep bus timing with -G
    // without editing anything. All zero is the real hardware.
    parameter IMEM_READ_LAT   = 0,
    parameter IMEM_STALL_PROB = 0,
    parameter IMEM_SEED       = 1,
    parameter DMEM_READ_LAT   = 0,
    parameter DMEM_WRITE_LAT  = 0,
    parameter DMEM_STALL_PROB = 0,
    parameter DMEM_SEED       = 2
)(
    input         clk_i,
    input         rst_n_i,

    // observability for the bench; no functional role
    output        cpu_in_trap_o,
    output        cpu_irq_o,
    output [3:0]  dma_irq_o,
    output        sram_irq_o,
    output        tmr_irq_o
);

// ---------------------------------------------------------------------------
// slave index assignment on each decoder
// ---------------------------------------------------------------------------
localparam integer SD_DMEM = 0;   // CPU data bus decoder
localparam integer SD_SRAM = 1;
localparam integer SD_PIC  = 2;
localparam integer SD_TMR  = 3;
localparam integer SD_DMA  = 4;
localparam integer ND      = 5;

localparam integer SX_DMEM = 0;   // DMA decoder
localparam integer SX_SRAM = 1;
localparam integer NX      = 2;

// ---------------------------------------------------------------------------
// CPU
// ---------------------------------------------------------------------------
wire [31:0] ibus_araddr;
wire [2:0]  ibus_arprot;
wire        ibus_arvalid, ibus_arready;
wire [31:0] ibus_rdata;
wire [1:0]  ibus_rresp;
wire        ibus_rvalid, ibus_rready;

wire [31:0] dbus_awaddr;
wire [2:0]  dbus_awprot;
wire        dbus_awvalid, dbus_awready;
wire [31:0] dbus_wdata;
wire [3:0]  dbus_wstrb;
wire        dbus_wvalid, dbus_wready;
wire [1:0]  dbus_bresp;
wire        dbus_bvalid, dbus_bready;
wire [31:0] dbus_araddr;
wire [2:0]  dbus_arprot;
wire        dbus_arvalid, dbus_arready;
wire [31:0] dbus_rdata;
wire [1:0]  dbus_rresp;
wire        dbus_rvalid, dbus_rready;

wire        cpu_irq, cpu_irq_ack, cpu_irq_eoi;
wire [3:0]  cpu_irq_vec;

assign cpu_irq_o = cpu_irq;

cpu_top #(
    .RESET_PC   (RESET_PC),
    .HART_ID    (32'd0),
    .BP_ENTRIES (BP_ENTRIES),
    .RAS_DEPTH  (RAS_DEPTH)
) cpu_inst (
    .clk_i              (clk_i),
    .rst_n_i            (rst_n_i),

    .ibus_axi_araddr_o  (ibus_araddr),
    .ibus_axi_arprot_o  (ibus_arprot),
    .ibus_axi_arvalid_o (ibus_arvalid),
    .ibus_axi_arready_i (ibus_arready),
    .ibus_axi_rdata_i   (ibus_rdata),
    .ibus_axi_rresp_i   (ibus_rresp),
    .ibus_axi_rvalid_i  (ibus_rvalid),
    .ibus_axi_rready_o  (ibus_rready),

    .dbus_axi_awaddr_o  (dbus_awaddr),
    .dbus_axi_awprot_o  (dbus_awprot),
    .dbus_axi_awvalid_o (dbus_awvalid),
    .dbus_axi_awready_i (dbus_awready),
    .dbus_axi_wdata_o   (dbus_wdata),
    .dbus_axi_wstrb_o   (dbus_wstrb),
    .dbus_axi_wvalid_o  (dbus_wvalid),
    .dbus_axi_wready_i  (dbus_wready),
    .dbus_axi_bresp_i   (dbus_bresp),
    .dbus_axi_bvalid_i  (dbus_bvalid),
    .dbus_axi_bready_o  (dbus_bready),
    .dbus_axi_araddr_o  (dbus_araddr),
    .dbus_axi_arprot_o  (dbus_arprot),
    .dbus_axi_arvalid_o (dbus_arvalid),
    .dbus_axi_arready_i (dbus_arready),
    .dbus_axi_rdata_i   (dbus_rdata),
    .dbus_axi_rresp_i   (dbus_rresp),
    .dbus_axi_rvalid_i  (dbus_rvalid),
    .dbus_axi_rready_o  (dbus_rready),

    .cpu_irq_i          (cpu_irq),
    .cpu_irq_vec_i      (cpu_irq_vec),
    .cpu_irq_ack_o      (cpu_irq_ack),
    .cpu_irq_eoi_o      (cpu_irq_eoi),
    .cpu_in_trap_o      (cpu_in_trap_o)
);

// ---------------------------------------------------------------------------
// instruction path: ibus -> IMEM. A one-slave decoder, present so a fetch
// outside the IMEM window gets DECERR instead of no response at all.
// ---------------------------------------------------------------------------
wire [31:0] imem_araddr;
wire [2:0]  imem_arprot;
wire        imem_arvalid, imem_arready;
wire [31:0] imem_rdata;
wire [1:0]  imem_rresp;
wire        imem_rvalid, imem_rready;

axi_lite_dec #(
    .N    (1),
    .BASE (`SOC_IMEM_BASE),
    .MASK (`SOC_IMEM_MASK)
) dec_i (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    // the CPU's instruction port never writes; tie the write channel off
    .m_awaddr_i  (32'h0),
    .m_awprot_i  (3'b000),
    .m_awvalid_i (1'b0),
    .m_awready_o (),
    .m_wdata_i   (32'h0),
    .m_wstrb_i   (4'h0),
    .m_wvalid_i  (1'b0),
    .m_wready_o  (),
    .m_bresp_o   (),
    .m_bvalid_o  (),
    .m_bready_i  (1'b0),
    .m_araddr_i  (ibus_araddr),
    .m_arprot_i  (ibus_arprot),
    .m_arvalid_i (ibus_arvalid),
    .m_arready_o (ibus_arready),
    .m_rdata_o   (ibus_rdata),
    .m_rresp_o   (ibus_rresp),
    .m_rvalid_o  (ibus_rvalid),
    .m_rready_i  (ibus_rready),

    .s_awaddr_o  (),
    .s_awprot_o  (),
    .s_awvalid_o (),
    .s_awready_i (1'b0),
    .s_wdata_o   (),
    .s_wstrb_o   (),
    .s_wvalid_o  (),
    .s_wready_i  (1'b0),
    .s_bresp_i   (2'b00),
    .s_bvalid_i  (1'b0),
    .s_bready_o  (),
    .s_araddr_o  (imem_araddr),
    .s_arprot_o  (imem_arprot),
    .s_arvalid_o (imem_arvalid),
    .s_arready_i (imem_arready),
    .s_rdata_i   (imem_rdata),
    .s_rresp_i   (imem_rresp),
    .s_rvalid_i  (imem_rvalid),
    .s_rready_o  (imem_rready)
);

axi_lite_ram #(
    .WORDS      (`SOC_IMEM_WORDS),
    .INIT_FILE  (IMEM_INIT),
    .READ_LAT   (IMEM_READ_LAT),
    .STALL_PROB (IMEM_STALL_PROB),
    .SEED       (IMEM_SEED)
) imem_inst (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .s_awaddr_i  (32'h0),
    .s_awprot_i  (3'b000),
    .s_awvalid_i (1'b0),
    .s_awready_o (),
    .s_wdata_i   (32'h0),
    .s_wstrb_i   (4'h0),
    .s_wvalid_i  (1'b0),
    .s_wready_o  (),
    .s_bresp_o   (),
    .s_bvalid_o  (),
    .s_bready_i  (1'b0),
    .s_araddr_i  (imem_araddr),
    .s_arprot_i  (imem_arprot),
    .s_arvalid_i (imem_arvalid),
    .s_arready_o (imem_arready),
    .s_rdata_o   (imem_rdata),
    .s_rresp_o   (imem_rresp),
    .s_rvalid_o  (imem_rvalid),
    .s_rready_i  (imem_rready)
);

// ---------------------------------------------------------------------------
// DMA master -> AXI4-Lite
// ---------------------------------------------------------------------------
wire [31:0] dmam_awaddr;
wire [7:0]  dmam_awlen;
wire [2:0]  dmam_awsize;
wire [1:0]  dmam_awburst;
wire        dmam_awvalid, dmam_awready;
wire [31:0] dmam_wdata;
wire [3:0]  dmam_wstrb;
wire        dmam_wlast, dmam_wvalid, dmam_wready;
wire [1:0]  dmam_bresp;
wire        dmam_bvalid, dmam_bready;
wire [31:0] dmam_araddr;
wire [7:0]  dmam_arlen;
wire [2:0]  dmam_arsize;
wire [1:0]  dmam_arburst;
wire        dmam_arvalid, dmam_arready;
wire [31:0] dmam_rdata;
wire [1:0]  dmam_rresp;
wire        dmam_rlast, dmam_rvalid, dmam_rready;

wire [31:0] xl_awaddr;
wire [2:0]  xl_awprot;
wire        xl_awvalid, xl_awready;
wire [31:0] xl_wdata;
wire [3:0]  xl_wstrb;
wire        xl_wvalid, xl_wready;
wire [1:0]  xl_bresp;
wire        xl_bvalid, xl_bready;
wire [31:0] xl_araddr;
wire [2:0]  xl_arprot;
wire        xl_arvalid, xl_arready;
wire [31:0] xl_rdata;
wire [1:0]  xl_rresp;
wire        xl_rvalid, xl_rready;

axi_full2lite bridge_inst (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),

    .s_awaddr_i  (dmam_awaddr),
    .s_awlen_i   (dmam_awlen),
    .s_awsize_i  (dmam_awsize),
    .s_awburst_i (dmam_awburst),
    .s_awvalid_i (dmam_awvalid),
    .s_awready_o (dmam_awready),
    .s_wdata_i   (dmam_wdata),
    .s_wstrb_i   (dmam_wstrb),
    .s_wlast_i   (dmam_wlast),
    .s_wvalid_i  (dmam_wvalid),
    .s_wready_o  (dmam_wready),
    .s_bresp_o   (dmam_bresp),
    .s_bvalid_o  (dmam_bvalid),
    .s_bready_i  (dmam_bready),
    .s_araddr_i  (dmam_araddr),
    .s_arlen_i   (dmam_arlen),
    .s_arsize_i  (dmam_arsize),
    .s_arburst_i (dmam_arburst),
    .s_arvalid_i (dmam_arvalid),
    .s_arready_o (dmam_arready),
    .s_rdata_o   (dmam_rdata),
    .s_rresp_o   (dmam_rresp),
    .s_rlast_o   (dmam_rlast),
    .s_rvalid_o  (dmam_rvalid),
    .s_rready_i  (dmam_rready),

    .m_awaddr_o  (xl_awaddr),
    .m_awprot_o  (xl_awprot),
    .m_awvalid_o (xl_awvalid),
    .m_awready_i (xl_awready),
    .m_wdata_o   (xl_wdata),
    .m_wstrb_o   (xl_wstrb),
    .m_wvalid_o  (xl_wvalid),
    .m_wready_i  (xl_wready),
    .m_bresp_i   (xl_bresp),
    .m_bvalid_i  (xl_bvalid),
    .m_bready_o  (xl_bready),
    .m_araddr_o  (xl_araddr),
    .m_arprot_o  (xl_arprot),
    .m_arvalid_o (xl_arvalid),
    .m_arready_i (xl_arready),
    .m_rdata_i   (xl_rdata),
    .m_rresp_i   (xl_rresp),
    .m_rvalid_i  (xl_rvalid),
    .m_rready_o  (xl_rready)
);

// ---------------------------------------------------------------------------
// CPU data bus decoder: DMEM, SRAM port A, PIC, timer, DMA registers
// ---------------------------------------------------------------------------
wire [ND*32-1:0] d_awaddr, d_wdata, d_araddr, d_rdata;
wire [ND*3-1:0]  d_awprot, d_arprot;
wire [ND*4-1:0]  d_wstrb;
wire [ND*2-1:0]  d_bresp, d_rresp;
wire [ND-1:0]    d_awvalid, d_awready, d_wvalid, d_wready;
wire [ND-1:0]    d_bvalid, d_bready, d_arvalid, d_arready, d_rvalid, d_rready;

axi_lite_dec #(
    .N    (ND),
    .BASE ({`SOC_DMA_BASE, `SOC_TMR_BASE, `SOC_PIC_BASE, `SOC_SRAM_BASE, `SOC_DMEM_BASE}),
    .MASK ({`SOC_DMA_MASK, `SOC_TMR_MASK, `SOC_PIC_MASK, `SOC_SRAM_MASK, `SOC_DMEM_MASK})
) dec_d (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .m_awaddr_i  (dbus_awaddr),
    .m_awprot_i  (dbus_awprot),
    .m_awvalid_i (dbus_awvalid),
    .m_awready_o (dbus_awready),
    .m_wdata_i   (dbus_wdata),
    .m_wstrb_i   (dbus_wstrb),
    .m_wvalid_i  (dbus_wvalid),
    .m_wready_o  (dbus_wready),
    .m_bresp_o   (dbus_bresp),
    .m_bvalid_o  (dbus_bvalid),
    .m_bready_i  (dbus_bready),
    .m_araddr_i  (dbus_araddr),
    .m_arprot_i  (dbus_arprot),
    .m_arvalid_i (dbus_arvalid),
    .m_arready_o (dbus_arready),
    .m_rdata_o   (dbus_rdata),
    .m_rresp_o   (dbus_rresp),
    .m_rvalid_o  (dbus_rvalid),
    .m_rready_i  (dbus_rready),

    .s_awaddr_o  (d_awaddr),
    .s_awprot_o  (d_awprot),
    .s_awvalid_o (d_awvalid),
    .s_awready_i (d_awready),
    .s_wdata_o   (d_wdata),
    .s_wstrb_o   (d_wstrb),
    .s_wvalid_o  (d_wvalid),
    .s_wready_i  (d_wready),
    .s_bresp_i   (d_bresp),
    .s_bvalid_i  (d_bvalid),
    .s_bready_o  (d_bready),
    .s_araddr_o  (d_araddr),
    .s_arprot_o  (d_arprot),
    .s_arvalid_o (d_arvalid),
    .s_arready_i (d_arready),
    .s_rdata_i   (d_rdata),
    .s_rresp_i   (d_rresp),
    .s_rvalid_i  (d_rvalid),
    .s_rready_o  (d_rready)
);

// ---------------------------------------------------------------------------
// DMA decoder: DMEM, SRAM port B
// ---------------------------------------------------------------------------
wire [NX*32-1:0] x_awaddr, x_wdata, x_araddr, x_rdata;
wire [NX*3-1:0]  x_awprot, x_arprot;
wire [NX*4-1:0]  x_wstrb;
wire [NX*2-1:0]  x_bresp, x_rresp;
wire [NX-1:0]    x_awvalid, x_awready, x_wvalid, x_wready;
wire [NX-1:0]    x_bvalid, x_bready, x_arvalid, x_arready, x_rvalid, x_rready;

axi_lite_dec #(
    .N    (NX),
    .BASE ({`SOC_SRAM_BASE, `SOC_DMEM_BASE}),
    .MASK ({`SOC_SRAM_MASK, `SOC_DMEM_MASK})
) dec_x (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .m_awaddr_i  (xl_awaddr),
    .m_awprot_i  (xl_awprot),
    .m_awvalid_i (xl_awvalid),
    .m_awready_o (xl_awready),
    .m_wdata_i   (xl_wdata),
    .m_wstrb_i   (xl_wstrb),
    .m_wvalid_i  (xl_wvalid),
    .m_wready_o  (xl_wready),
    .m_bresp_o   (xl_bresp),
    .m_bvalid_o  (xl_bvalid),
    .m_bready_i  (xl_bready),
    .m_araddr_i  (xl_araddr),
    .m_arprot_i  (xl_arprot),
    .m_arvalid_i (xl_arvalid),
    .m_arready_o (xl_arready),
    .m_rdata_o   (xl_rdata),
    .m_rresp_o   (xl_rresp),
    .m_rvalid_o  (xl_rvalid),
    .m_rready_i  (xl_rready),

    .s_awaddr_o  (x_awaddr),
    .s_awprot_o  (x_awprot),
    .s_awvalid_o (x_awvalid),
    .s_awready_i (x_awready),
    .s_wdata_o   (x_wdata),
    .s_wstrb_o   (x_wstrb),
    .s_wvalid_o  (x_wvalid),
    .s_wready_i  (x_wready),
    .s_bresp_i   (x_bresp),
    .s_bvalid_i  (x_bvalid),
    .s_bready_o  (x_bready),
    .s_araddr_o  (x_araddr),
    .s_arprot_o  (x_arprot),
    .s_arvalid_o (x_arvalid),
    .s_arready_i (x_arready),
    .s_rdata_i   (x_rdata),
    .s_rresp_i   (x_rresp),
    .s_rvalid_i  (x_rvalid),
    .s_rready_o  (x_rready)
);

// ---------------------------------------------------------------------------
// DMEM arbiter: master 0 = CPU data bus, master 1 = DMA
// ---------------------------------------------------------------------------
wire [31:0] dmem_awaddr, dmem_wdata, dmem_araddr, dmem_rdata;
wire [2:0]  dmem_awprot, dmem_arprot;
wire [3:0]  dmem_wstrb;
wire [1:0]  dmem_bresp, dmem_rresp;
wire        dmem_awvalid, dmem_awready, dmem_wvalid, dmem_wready;
wire        dmem_bvalid, dmem_bready, dmem_arvalid, dmem_arready;
wire        dmem_rvalid, dmem_rready;

axi_lite_arb #(.M(2)) arb_dmem (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),

    .m_awaddr_i  ({x_awaddr [SX_DMEM*32 +: 32], d_awaddr [SD_DMEM*32 +: 32]}),
    .m_awprot_i  ({x_awprot [SX_DMEM*3  +: 3],  d_awprot [SD_DMEM*3  +: 3]}),
    .m_awvalid_i ({x_awvalid[SX_DMEM],          d_awvalid[SD_DMEM]}),
    .m_awready_o ({x_awready[SX_DMEM],          d_awready[SD_DMEM]}),
    .m_wdata_i   ({x_wdata  [SX_DMEM*32 +: 32], d_wdata  [SD_DMEM*32 +: 32]}),
    .m_wstrb_i   ({x_wstrb  [SX_DMEM*4  +: 4],  d_wstrb  [SD_DMEM*4  +: 4]}),
    .m_wvalid_i  ({x_wvalid [SX_DMEM],          d_wvalid [SD_DMEM]}),
    .m_wready_o  ({x_wready [SX_DMEM],          d_wready [SD_DMEM]}),
    .m_bresp_o   ({x_bresp  [SX_DMEM*2  +: 2],  d_bresp  [SD_DMEM*2  +: 2]}),
    .m_bvalid_o  ({x_bvalid [SX_DMEM],          d_bvalid [SD_DMEM]}),
    .m_bready_i  ({x_bready [SX_DMEM],          d_bready [SD_DMEM]}),
    .m_araddr_i  ({x_araddr [SX_DMEM*32 +: 32], d_araddr [SD_DMEM*32 +: 32]}),
    .m_arprot_i  ({x_arprot [SX_DMEM*3  +: 3],  d_arprot [SD_DMEM*3  +: 3]}),
    .m_arvalid_i ({x_arvalid[SX_DMEM],          d_arvalid[SD_DMEM]}),
    .m_arready_o ({x_arready[SX_DMEM],          d_arready[SD_DMEM]}),
    .m_rdata_o   ({x_rdata  [SX_DMEM*32 +: 32], d_rdata  [SD_DMEM*32 +: 32]}),
    .m_rresp_o   ({x_rresp  [SX_DMEM*2  +: 2],  d_rresp  [SD_DMEM*2  +: 2]}),
    .m_rvalid_o  ({x_rvalid [SX_DMEM],          d_rvalid [SD_DMEM]}),
    .m_rready_i  ({x_rready [SX_DMEM],          d_rready [SD_DMEM]}),

    .s_awaddr_o  (dmem_awaddr),
    .s_awprot_o  (dmem_awprot),
    .s_awvalid_o (dmem_awvalid),
    .s_awready_i (dmem_awready),
    .s_wdata_o   (dmem_wdata),
    .s_wstrb_o   (dmem_wstrb),
    .s_wvalid_o  (dmem_wvalid),
    .s_wready_i  (dmem_wready),
    .s_bresp_i   (dmem_bresp),
    .s_bvalid_i  (dmem_bvalid),
    .s_bready_o  (dmem_bready),
    .s_araddr_o  (dmem_araddr),
    .s_arprot_o  (dmem_arprot),
    .s_arvalid_o (dmem_arvalid),
    .s_arready_i (dmem_arready),
    .s_rdata_i   (dmem_rdata),
    .s_rresp_i   (dmem_rresp),
    .s_rvalid_i  (dmem_rvalid),
    .s_rready_o  (dmem_rready)
);

axi_lite_ram #(
    .WORDS      (`SOC_DMEM_WORDS),
    .INIT_FILE  (DMEM_INIT),
    .READ_LAT   (DMEM_READ_LAT),
    .WRITE_LAT  (DMEM_WRITE_LAT),
    .STALL_PROB (DMEM_STALL_PROB),
    .SEED       (DMEM_SEED)
) dmem_inst (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .s_awaddr_i  (dmem_awaddr),
    .s_awprot_i  (dmem_awprot),
    .s_awvalid_i (dmem_awvalid),
    .s_awready_o (dmem_awready),
    .s_wdata_i   (dmem_wdata),
    .s_wstrb_i   (dmem_wstrb),
    .s_wvalid_i  (dmem_wvalid),
    .s_wready_o  (dmem_wready),
    .s_bresp_o   (dmem_bresp),
    .s_bvalid_o  (dmem_bvalid),
    .s_bready_i  (dmem_bready),
    .s_araddr_i  (dmem_araddr),
    .s_arprot_i  (dmem_arprot),
    .s_arvalid_i (dmem_arvalid),
    .s_arready_o (dmem_arready),
    .s_rdata_o   (dmem_rdata),
    .s_rresp_o   (dmem_rresp),
    .s_rvalid_o  (dmem_rvalid),
    .s_rready_i  (dmem_rready)
);

// ---------------------------------------------------------------------------
// dual-port SRAM: port A from the CPU, port B from the DMA, same window.
// Its ports are 10 bits wide, which is exactly the window size, so the low
// bits of the system address are the block-local address unchanged.
// ---------------------------------------------------------------------------
wire sram_irq;
assign sram_irq_o = sram_irq;

dp_sram_top #(
    .ADDR_W       (10),
    .REG_WORD_MAX (7)
) sram_inst (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),

    .a_awaddr_i  (d_awaddr [SD_SRAM*32 +: 10]),
    .a_awvalid_i (d_awvalid[SD_SRAM]),
    .a_awready_o (d_awready[SD_SRAM]),
    .a_wdata_i   (d_wdata  [SD_SRAM*32 +: 32]),
    .a_wstrb_i   (d_wstrb  [SD_SRAM*4  +: 4]),
    .a_wvalid_i  (d_wvalid [SD_SRAM]),
    .a_wready_o  (d_wready [SD_SRAM]),
    .a_bresp_o   (d_bresp  [SD_SRAM*2  +: 2]),
    .a_bvalid_o  (d_bvalid [SD_SRAM]),
    .a_bready_i  (d_bready [SD_SRAM]),
    .a_araddr_i  (d_araddr [SD_SRAM*32 +: 10]),
    .a_arvalid_i (d_arvalid[SD_SRAM]),
    .a_arready_o (d_arready[SD_SRAM]),
    .a_rdata_o   (d_rdata  [SD_SRAM*32 +: 32]),
    .a_rresp_o   (d_rresp  [SD_SRAM*2  +: 2]),
    .a_rvalid_o  (d_rvalid [SD_SRAM]),
    .a_rready_i  (d_rready [SD_SRAM]),

    .b_awaddr_i  (x_awaddr [SX_SRAM*32 +: 10]),
    .b_awvalid_i (x_awvalid[SX_SRAM]),
    .b_awready_o (x_awready[SX_SRAM]),
    .b_wdata_i   (x_wdata  [SX_SRAM*32 +: 32]),
    .b_wstrb_i   (x_wstrb  [SX_SRAM*4  +: 4]),
    .b_wvalid_i  (x_wvalid [SX_SRAM]),
    .b_wready_o  (x_wready [SX_SRAM]),
    .b_bresp_o   (x_bresp  [SX_SRAM*2  +: 2]),
    .b_bvalid_o  (x_bvalid [SX_SRAM]),
    .b_bready_i  (x_bready [SX_SRAM]),
    .b_araddr_i  (x_araddr [SX_SRAM*32 +: 10]),
    .b_arvalid_i (x_arvalid[SX_SRAM]),
    .b_arready_o (x_arready[SX_SRAM]),
    .b_rdata_o   (x_rdata  [SX_SRAM*32 +: 32]),
    .b_rresp_o   (x_rresp  [SX_SRAM*2  +: 2]),
    .b_rvalid_o  (x_rvalid [SX_SRAM]),
    .b_rready_i  (x_rready [SX_SRAM]),

    .irq_o       (sram_irq)
);

// ---------------------------------------------------------------------------
// DMA: AXI4-Lite register slave on the CPU bus, AXI4-Full master on the fabric
// ---------------------------------------------------------------------------
wire [3:0] dma_irq;
assign dma_irq_o = dma_irq;

mc_dma_top dma_inst (
    .clk           (clk_i),
    .rst_n         (rst_n_i),
    .irq           (dma_irq),

    .s_axi_awaddr  (d_awaddr [SD_DMA*32 +: 32]),
    .s_axi_awvalid (d_awvalid[SD_DMA]),
    .s_axi_awready (d_awready[SD_DMA]),
    .s_axi_wdata   (d_wdata  [SD_DMA*32 +: 32]),
    .s_axi_wstrb   (d_wstrb  [SD_DMA*4  +: 4]),
    .s_axi_wvalid  (d_wvalid [SD_DMA]),
    .s_axi_wready  (d_wready [SD_DMA]),
    .s_axi_bresp   (d_bresp  [SD_DMA*2  +: 2]),
    .s_axi_bvalid  (d_bvalid [SD_DMA]),
    .s_axi_bready  (d_bready [SD_DMA]),
    .s_axi_araddr  (d_araddr [SD_DMA*32 +: 32]),
    .s_axi_arvalid (d_arvalid[SD_DMA]),
    .s_axi_arready (d_arready[SD_DMA]),
    .s_axi_rdata   (d_rdata  [SD_DMA*32 +: 32]),
    .s_axi_rresp   (d_rresp  [SD_DMA*2  +: 2]),
    .s_axi_rvalid  (d_rvalid [SD_DMA]),
    .s_axi_rready  (d_rready [SD_DMA]),

    .m_axi_awaddr  (dmam_awaddr),
    .m_axi_awlen   (dmam_awlen),
    .m_axi_awsize  (dmam_awsize),
    .m_axi_awburst (dmam_awburst),
    .m_axi_awvalid (dmam_awvalid),
    .m_axi_awready (dmam_awready),
    .m_axi_wdata   (dmam_wdata),
    .m_axi_wstrb   (dmam_wstrb),
    .m_axi_wlast   (dmam_wlast),
    .m_axi_wvalid  (dmam_wvalid),
    .m_axi_wready  (dmam_wready),
    .m_axi_bresp   (dmam_bresp),
    .m_axi_bvalid  (dmam_bvalid),
    .m_axi_bready  (dmam_bready),
    .m_axi_araddr  (dmam_araddr),
    .m_axi_arlen   (dmam_arlen),
    .m_axi_arsize  (dmam_arsize),
    .m_axi_arburst (dmam_arburst),
    .m_axi_arvalid (dmam_arvalid),
    .m_axi_arready (dmam_arready),
    .m_axi_rdata   (dmam_rdata),
    .m_axi_rresp   (dmam_rresp),
    .m_axi_rlast   (dmam_rlast),
    .m_axi_rvalid  (dmam_rvalid),
    .m_axi_rready  (dmam_rready)
);

// ---------------------------------------------------------------------------
// interrupt controller and machine timer
// ---------------------------------------------------------------------------
wire tmr_irq;
assign tmr_irq_o = tmr_irq;

wire [15:0] pic_src;
assign pic_src[3:0]  = dma_irq;      // DMA channels 0..3
assign pic_src[4]    = sram_irq;     // DP-SRAM collision / cooldown
assign pic_src[6:5]  = 2'b00;        // unused
assign pic_src[7]    = tmr_irq;      // machine timer
assign pic_src[15:8] = 8'h00;        // unused

pic pic_inst (
    .clk_i           (clk_i),
    .rst_n_i         (rst_n_i),
    .irq_src_i       (pic_src),
    .cpu_irq_o       (cpu_irq),
    .cpu_irq_vec_o   (cpu_irq_vec),
    .cpu_irq_ack_i   (cpu_irq_ack),
    .cpu_irq_eoi_i   (cpu_irq_eoi),

    .s_axi_awaddr_i  (d_awaddr [SD_PIC*32 +: 32]),
    .s_axi_awprot_i  (d_awprot [SD_PIC*3  +: 3]),
    .s_axi_awvalid_i (d_awvalid[SD_PIC]),
    .s_axi_awready_o (d_awready[SD_PIC]),
    .s_axi_wdata_i   (d_wdata  [SD_PIC*32 +: 32]),
    .s_axi_wstrb_i   (d_wstrb  [SD_PIC*4  +: 4]),
    .s_axi_wvalid_i  (d_wvalid [SD_PIC]),
    .s_axi_wready_o  (d_wready [SD_PIC]),
    .s_axi_bresp_o   (d_bresp  [SD_PIC*2  +: 2]),
    .s_axi_bvalid_o  (d_bvalid [SD_PIC]),
    .s_axi_bready_i  (d_bready [SD_PIC]),
    .s_axi_araddr_i  (d_araddr [SD_PIC*32 +: 32]),
    .s_axi_arprot_i  (d_arprot [SD_PIC*3  +: 3]),
    .s_axi_arvalid_i (d_arvalid[SD_PIC]),
    .s_axi_arready_o (d_arready[SD_PIC]),
    .s_axi_rdata_o   (d_rdata  [SD_PIC*32 +: 32]),
    .s_axi_rresp_o   (d_rresp  [SD_PIC*2  +: 2]),
    .s_axi_rvalid_o  (d_rvalid [SD_PIC]),
    .s_axi_rready_i  (d_rready [SD_PIC])
);

mtimer mtimer_inst (
    .clk_i           (clk_i),
    .rst_n_i         (rst_n_i),
    .irq_o           (tmr_irq),

    .s_axi_awaddr_i  (d_awaddr [SD_TMR*32 +: 32]),
    .s_axi_awprot_i  (d_awprot [SD_TMR*3  +: 3]),
    .s_axi_awvalid_i (d_awvalid[SD_TMR]),
    .s_axi_awready_o (d_awready[SD_TMR]),
    .s_axi_wdata_i   (d_wdata  [SD_TMR*32 +: 32]),
    .s_axi_wstrb_i   (d_wstrb  [SD_TMR*4  +: 4]),
    .s_axi_wvalid_i  (d_wvalid [SD_TMR]),
    .s_axi_wready_o  (d_wready [SD_TMR]),
    .s_axi_bresp_o   (d_bresp  [SD_TMR*2  +: 2]),
    .s_axi_bvalid_o  (d_bvalid [SD_TMR]),
    .s_axi_bready_i  (d_bready [SD_TMR]),
    .s_axi_araddr_i  (d_araddr [SD_TMR*32 +: 32]),
    .s_axi_arprot_i  (d_arprot [SD_TMR*3  +: 3]),
    .s_axi_arvalid_i (d_arvalid[SD_TMR]),
    .s_axi_arready_o (d_arready[SD_TMR]),
    .s_axi_rdata_o   (d_rdata  [SD_TMR*32 +: 32]),
    .s_axi_rresp_o   (d_rresp  [SD_TMR*2  +: 2]),
    .s_axi_rvalid_o  (d_rvalid [SD_TMR]),
    .s_axi_rready_i  (d_rready [SD_TMR])
);

endmodule
