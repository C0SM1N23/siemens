// Machine timer (mtimer) — CLINT-style mtime/mtimecmp.
// REQ# = spec requirement, D# = design choice; both are tracked in the README.
//
// Why this module exists:
// - no block brief includes a timer, yet the SoC cannot do preemptive
//   scheduling or watch a hung DMA transfer without one — the same kind of
//   unassigned gap the PIC filled (D19). The RISC-V machine timer is the
//   standard, minimal answer (Priv. spec 3.2.1: mtime/mtimecmp are
//   memory-mapped, not CSRs), and its interrupt gives the DMA abort
//   (CHx_CONTROL) a system-level use: a handler that aborts a stuck channel.
//
// - D26
//   64-bit free-running mtime, 64-bit mtimecmp; level interrupt
//   irq = (mtime >= mtimecmp), registered. mtimecmp resets to all-ones so
//   the timer is born disarmed. There is no INT_STATUS: per the RISC-V
//   scheme the compare *is* the status, and the handler clears the line by
//   moving mtimecmp — which matches the PIC's level-sensitive contract
//   (D19, "hold until software clears the source"). Arming order matters
//   and is free of false fires: write CMP_LO while CMP_HI still holds
//   all-ones, then write CMP_HI. 32-bit reads of a 64-bit counter tear;
//   software reads HI, LO, HI again and retries if HI moved (the standard
//   scheme — mtime is far from 2^32 in this SoC's lifetime anyway).
//   Planned hookup: irq -> PIC channel 7, the lowest priority (D20): a tick
//   must not outrank DMA/DP-SRAM service.
//
// - D27
//   AXI4-Lite slave, same machinery as the PIC's port (D22): AW and W
//   collected independently, one transaction per direction, response held
//   until accepted. Word registers at BASE+:
//   - 0x0 MTIME_LO    R/W   - 0x4 MTIME_HI    R/W
//   - 0x8 MTIMECMP_LO R/W   - 0xC MTIMECMP_HI R/W
//   Anything else answers SLVERR (precise access fault in the CPU). Writes
//   honor WSTRB per byte lane; a write to an mtime half beats the increment
//   on that half for that cycle.

module mtimer (
    input             clk,
    input             rst_n,

    // level interrupt to the system interrupt controller (PIC ch7 planned)
    output reg        irq,

    // AXI4-Lite slave: software access
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
localparam OFF_TIME_LO = 6'd0;
localparam OFF_TIME_HI = 6'd1;
localparam OFF_CMP_LO  = 6'd2;
localparam OFF_CMP_HI  = 6'd3;

localparam RESP_OKAY   = 2'b00;
localparam RESP_SLVERR = 2'b10;

reg [63:0] mtime_q;
reg [63:0] mtimecmp_q;      // reset all-ones = disarmed (D26)

// --- AXI4-Lite slave (D27), same shape as pic.v ---
// Write: collect AW and W independently, apply + respond once both are in.

reg        aw_got_q, w_got_q;
reg [5:0]  awoff_q;
reg [31:0] wdata_q;
reg [3:0]  wstrb_q;

wire aw_hs     = s_axi_awvalid && s_axi_awready;
wire w_hs      = s_axi_wvalid  && s_axi_wready;
wire wr_commit = aw_got_q && w_got_q && !s_axi_bvalid;
wire wr_ok     = (awoff_q <= OFF_CMP_HI);

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

// command payload — consumed only under the got bits above, no reset
always @(posedge clk) begin
    if (aw_hs)
        awoff_q <= s_axi_awaddr[7:2];
end

always @(posedge clk) begin
    if (w_hs) begin
        wdata_q <= s_axi_wdata;
        wstrb_q <= s_axi_wstrb;
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

// byte-lane merge for register writes (WSTRB per AXI, like the DP-SRAM)
function [31:0] lane_merge;
    input [31:0] old_val;
    input [31:0] new_val;
    input [3:0]  strb;
    lane_merge = {strb[3] ? new_val[31:24] : old_val[31:24],
                  strb[2] ? new_val[23:16] : old_val[23:16],
                  strb[1] ? new_val[15:8]  : old_val[15:8],
                  strb[0] ? new_val[7:0]   : old_val[7:0]};
endfunction

wire wr_time_lo = wr_commit && (awoff_q == OFF_TIME_LO);
wire wr_time_hi = wr_commit && (awoff_q == OFF_TIME_HI);
wire wr_cmp_lo  = wr_commit && (awoff_q == OFF_CMP_LO);
wire wr_cmp_hi  = wr_commit && (awoff_q == OFF_CMP_HI);

// mtime: free-running; a software write to a half beats the increment on
// that half for that cycle (the other half still increments as a pair)
wire [63:0] mtime_inc = mtime_q + 64'd1;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mtime_q <= 64'b0;
    else begin
        mtime_q[31:0]  <= wr_time_lo ? lane_merge(mtime_inc[31:0], wdata_q, wstrb_q)
                                     : mtime_inc[31:0];
        mtime_q[63:32] <= wr_time_hi ? lane_merge(mtime_inc[63:32], wdata_q, wstrb_q)
                                     : mtime_inc[63:32];
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        mtimecmp_q <= {64{1'b1}};                    // disarmed at reset (D26)
    else if (wr_cmp_lo)
        mtimecmp_q[31:0]  <= lane_merge(mtimecmp_q[31:0], wdata_q, wstrb_q);
    else if (wr_cmp_hi)
        mtimecmp_q[63:32] <= lane_merge(mtimecmp_q[63:32], wdata_q, wstrb_q);
end

// level interrupt, registered off the compare (D26)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        irq <= 1'b0;
    else
        irq <= (mtime_q >= mtimecmp_q);
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
        rresp_err_q <= (s_axi_araddr[7:2] > OFF_CMP_HI);
end
assign s_axi_rresp = rresp_err_q ? RESP_SLVERR : RESP_OKAY;

always @(posedge clk) begin
    if (ar_hs) begin
        case (s_axi_araddr[7:2])
            OFF_TIME_LO: s_axi_rdata <= mtime_q[31:0];
            OFF_TIME_HI: s_axi_rdata <= mtime_q[63:32];
            OFF_CMP_LO:  s_axi_rdata <= mtimecmp_q[31:0];
            OFF_CMP_HI:  s_axi_rdata <= mtimecmp_q[63:32];
            default:     s_axi_rdata <= 32'b0;
        endcase
    end
end

endmodule
