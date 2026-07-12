// Programmable interrupt controller (PIC).
// REQ# = spec requirement, D# = design choice; both tracked in the README.
//
// Every peripheral brief routes its irq line "to the system interrupt
// controller" (DMA irq[3:0], DP-SRAM irq) and the CPU brief fixes a complete
// interface to it, but no brief specifies the PIC or assigns building it. This
// module fills that gap: the CPU-side handshake is fixed by REQ4, everything
// internal is a design choice.
//
// D19: level-sensitive aggregator, no latching. A source holds its line until
//      its own INT_STATUS is cleared (how the DMA/DP-SRAM outputs behave), so
//      the PIC just combines the lines: pending = source & enable & ~in_service.
//      cpu_irq / cpu_irq_id are registered from the same pending vector, which
//      keeps the pair consistent and off the peripherals' timing paths, at one
//      cycle of interrupt latency.
// D20: fixed priority, channel 0 highest. cpu_irq_id = lowest-index pending
//      channel, so DMA (0..3) outranks DP-SRAM (4).
// D21: in-service suppression. The acked channel is masked from cpu_irq_ack
//      until cpu_in_trap drops (MRET), so a handler that re-enables mstatus.MIE
//      cannot be re-entered by the interrupt it serves (its level line is still
//      high). Sized for non-nested handlers (trap entry has MIE=0, cpu_in_trap
//      is one bit).
// D22: AXI4-Lite slave for software control, word registers at BASE+:
//        0x0 IRQ_ENABLE  R/W [7:0]      0x4 IRQ_PENDING RO (= cpu_irq)
//        0x8 IRQ_RAW     RO (sources)   0xC IRQ_ACTIVE  RO (in-service mask)
//      Anything else, and any write to a read-only register, answers SLVERR ->
//      precise access fault. One transaction per direction; the ≤1-outstanding
//      CPU never exceeds that.
//
// Expected SoC hookup: irq_src = {3'b0, sram_irq, dma_irq[3:0]}.

module pic (
    input             clk,
    input             rst_n,

    // peripheral request lines, level-sensitive
    input      [7:0]  irq_src,

    // CPU side (protocol fixed by the CPU brief)
    output reg [7:0]  cpu_irq,
    output reg [2:0]  cpu_irq_id,
    input      [7:0]  cpu_irq_ack,
    input             cpu_in_trap,

    // AXI4-Lite slave: software control/status
    input      [31:0] s_axi_awaddr,
    input      [2:0]  s_axi_awprot,
    input             s_axi_awvalid,
    output            s_axi_awready,
    input      [31:0] s_axi_wdata,
    input      [3:0]  s_axi_wstrb,
    input             s_axi_wvalid,
    output            s_axi_wready,
    output     [1:0]  s_axi_bresp,
    output            s_axi_bvalid,
    input             s_axi_bready,
    input      [31:0] s_axi_araddr,
    input      [2:0]  s_axi_arprot,
    input             s_axi_arvalid,
    output            s_axi_arready,
    output     [31:0] s_axi_rdata,
    output     [1:0]  s_axi_rresp,
    output            s_axi_rvalid,
    input             s_axi_rready
);

// register offsets (word address bits [7:2])
localparam OFF_ENABLE  = 6'd0;
localparam OFF_PENDING = 6'd1;
localparam OFF_RAW     = 6'd2;
localparam OFF_ACTIVE  = 6'd3;

reg [7:0] enable_q;         // IRQ_ENABLE
reg [7:0] in_service_q;     // channels acked and still being handled (D21)

// what the CPU is offered this cycle
wire [7:0] pending = irq_src & enable_q & ~in_service_q;

// lowest set bit wins (D20)
function [2:0] pri_enc;
    input [7:0] v;
    casez (v)
        8'bzzzzzzz1: pri_enc = 3'd0;
        8'bzzzzzz10: pri_enc = 3'd1;
        8'bzzzzz100: pri_enc = 3'd2;
        8'bzzzz1000: pri_enc = 3'd3;
        8'bzzz10000: pri_enc = 3'd4;
        8'bzz100000: pri_enc = 3'd5;
        8'bz1000000: pri_enc = 3'd6;
        8'b10000000: pri_enc = 3'd7;
        default:     pri_enc = 3'd0;
    endcase
endfunction

// cpu_irq and cpu_irq_id register the same pending vector on the same edge,
// so the id always points at a set bit of cpu_irq (D19)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        cpu_irq    <= 8'b0;
        cpu_irq_id <= 3'd0;
    end else begin
        cpu_irq    <= pending;
        cpu_irq_id <= pri_enc(pending);
    end
end

// ack marks the channel in service; MRET (cpu_in_trap low, no ack) releases
// it. Ack and cpu_in_trap rise on the same CPU edge, so the ack arm must win.
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        in_service_q <= 8'b0;
    else if (|cpu_irq_ack)
        in_service_q <= in_service_q | cpu_irq_ack;
    else if (!cpu_in_trap)
        in_service_q <= 8'b0;
end

// --- AXI4-Lite slave (D22) ---
// The handshake lives in the shared axi_lite_slave; the PIC just describes its
// four registers (only IRQ_ENABLE is writable; offsets past IRQ_ACTIVE SLVERR).
wire        reg_wr;
wire [5:0]  reg_waddr, reg_raddr;
wire [31:0] reg_wdata, reg_rdata;
wire [3:0]  reg_wstrb;

axi_lite_slave pic_slv (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .wr_en(reg_wr), .wr_addr(reg_waddr), .wr_data(reg_wdata), .wr_strb(reg_wstrb),
    .wr_ok(reg_waddr == OFF_ENABLE),
    .rd_addr(reg_raddr), .rd_data(reg_rdata), .rd_ok(reg_raddr <= OFF_ACTIVE)
);

// IRQ_ENABLE is the only writable register; a write with byte lane 0 off
// changes nothing but still answers OKAY (partial-strobe writes are legal AXI)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        enable_q <= 8'b0;
    else if (reg_wr && reg_waddr == OFF_ENABLE && reg_wstrb[0])
        enable_q <= reg_wdata[7:0];
end

// read mux — combinational; the slave registers it on the AR handshake
reg [31:0] reg_rmux;
always @(*) begin
    case (reg_raddr)
        OFF_ENABLE:  reg_rmux = {24'b0, enable_q};
        OFF_PENDING: reg_rmux = {24'b0, cpu_irq};
        OFF_RAW:     reg_rmux = {24'b0, irq_src};
        OFF_ACTIVE:  reg_rmux = {24'b0, in_service_q};
        default:     reg_rmux = 32'b0;
    endcase
end
assign reg_rdata = reg_rmux;

endmodule
