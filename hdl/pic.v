// Programmable interrupt controller (PIC).
// REQ# = spec requirement, D# = design choice; both are tracked in the README.
//
// Why this module exists:
// - every peripheral brief routes its interrupt line "to the system
//   interrupt controller" (DMA irq[3:0], DP-SRAM irq)
// - the CPU brief fixes a complete interface *to* that controller
// - but no brief specifies the PIC itself or assigns building it
// This module fills that gap. The CPU-side handshake is fixed by the CPU
// brief (REQ4); everything internal is a design choice:
//
// - D19
//   Level-sensitive aggregator, no latching. A source raises its line and
//   holds it until its own INT_STATUS is cleared (that is how the DMA and
//   DP-SRAM interrupt outputs behave), so the PIC just combines the lines:
//
//     pending = source & enable & ~in_service
//
//   cpu_irq / cpu_irq_id are registered from the same pending vector —
//   keeps the pair consistent at the CPU and off the peripherals' timing
//   paths, at the cost of one cycle of interrupt latency.
//
// - D20
//   Fixed priority, channel 0 highest. cpu_irq_id = lowest-index pending
//   channel; the DMA channels (0..3) outrank the DP-SRAM (4).
//
// - D21
//   In-service suppression. The acked channel is masked from cpu_irq_ack
//   until cpu_in_trap deasserts (MRET). A handler that re-enables
//   mstatus.MIE cannot be re-entered by the interrupt it is serving — the
//   level line is still high until the handler clears the peripheral.
//   Sized for non-nested handlers (the CPU enters a trap with MIE=0 and
//   cpu_in_trap is a single bit).
//
// - D22
//   AXI4-Lite slave for software control, word registers at BASE+:
//   - 0x0 IRQ_ENABLE   R/W  [7:0]
//   - 0x4 IRQ_PENDING  RO   (= cpu_irq)
//   - 0x8 IRQ_RAW      RO   (source lines)
//   - 0xC IRQ_ACTIVE   RO   (in-service mask)
//   Anything else — and any write to a read-only register — answers
//   SLVERR, which the CPU turns into a precise access fault.
//   One transaction at a time per direction; the ≤1-outstanding CPU never
//   exceeds that.
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
    output reg        s_axi_bvalid,
    input             s_axi_bready,
    input      [31:0] s_axi_araddr,
    input      [2:0]  s_axi_arprot,
    input             s_axi_arvalid,
    output            s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output     [1:0]  s_axi_rresp,
    output reg        s_axi_rvalid,
    input             s_axi_rready
);

// register offsets (word address bits [7:2])
localparam OFF_ENABLE  = 6'd0;
localparam OFF_PENDING = 6'd1;
localparam OFF_RAW     = 6'd2;
localparam OFF_ACTIVE  = 6'd3;

localparam RESP_OKAY   = 2'b00;
localparam RESP_SLVERR = 2'b10;

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
// Write: collect AW and W independently (the channels are allowed to complete
// in either order), apply + respond once both are in, hold B until BREADY.

reg       aw_got_q, w_got_q;
reg [5:0] awoff_q;
reg [7:0] wbyte0_q;
reg       wstrb0_q;

wire aw_hs     = s_axi_awvalid && s_axi_awready;
wire w_hs      = s_axi_wvalid  && s_axi_wready;
wire wr_commit = aw_got_q && w_got_q && !s_axi_bvalid;
wire wr_ok     = (awoff_q == OFF_ENABLE);

assign s_axi_awready = !aw_got_q && !s_axi_bvalid;
assign s_axi_wready  = !w_got_q  && !s_axi_bvalid;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        aw_got_q <= 1'b0;
    else if (aw_hs)
        aw_got_q <= 1'b1;
    else if (wr_commit)
        aw_got_q <= 1'b0;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        w_got_q <= 1'b0;
    else if (w_hs)
        w_got_q <= 1'b1;
    else if (wr_commit)
        w_got_q <= 1'b0;
end

// command payload — consumed only under the got/valid bits above, no reset
always @(posedge clk) begin
    if (aw_hs)
        awoff_q <= s_axi_awaddr[7:2];
end

always @(posedge clk) begin
    if (w_hs) begin
        wbyte0_q <= s_axi_wdata[7:0];
        wstrb0_q <= s_axi_wstrb[0];
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        s_axi_bvalid <= 1'b0;
    else if (wr_commit)
        s_axi_bvalid <= 1'b1;
    else if (s_axi_bready)
        s_axi_bvalid <= 1'b0;
end

reg bresp_err_q;
always @(posedge clk) begin
    if (wr_commit)
        bresp_err_q <= !wr_ok;
end
assign s_axi_bresp = bresp_err_q ? RESP_SLVERR : RESP_OKAY;

// the one writable register; a write with byte lane 0 off changes nothing
// but still answers OKAY (partial-strobe writes are legal AXI)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        enable_q <= 8'b0;
    else if (wr_commit && wr_ok && wstrb0_q)
        enable_q <= wbyte0_q;
end

// Read: accept AR whenever no response is pending, answer next cycle.

wire ar_hs = s_axi_arvalid && s_axi_arready;

assign s_axi_arready = !s_axi_rvalid;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        s_axi_rvalid <= 1'b0;
    else if (ar_hs)
        s_axi_rvalid <= 1'b1;
    else if (s_axi_rready)
        s_axi_rvalid <= 1'b0;
end

reg rresp_err_q;
always @(posedge clk) begin
    if (ar_hs)
        rresp_err_q <= (s_axi_araddr[7:2] > OFF_ACTIVE);
end
assign s_axi_rresp = rresp_err_q ? RESP_SLVERR : RESP_OKAY;

always @(posedge clk) begin
    if (ar_hs) begin
        case (s_axi_araddr[7:2])
            OFF_ENABLE:  s_axi_rdata <= {24'b0, enable_q};
            OFF_PENDING: s_axi_rdata <= {24'b0, cpu_irq};
            OFF_RAW:     s_axi_rdata <= {24'b0, irq_src};
            OFF_ACTIVE:  s_axi_rdata <= {24'b0, in_service_q};
            default:     s_axi_rdata <= 32'b0;
        endcase
    end
end

endmodule
