// AXI4-Full to AXI4-Lite bridge: splits one burst into one AXI4-Lite
// transaction per beat.
//
// WHY THIS EXISTS
// The DMA is an AXI4-Full master: it issues INCR bursts of eight 32-bit beats
// (AWLEN/ARLEN = 7) and expects WLAST/RLAST and one write response per burst.
// Every slave in this SoC is AXI4-Lite, which has no bursts at all - one
// address, one data beat, one response. Something has to sit between them,
// and that something is this module. It is a slave on its full side and a
// master on its lite side.
//
// STRUCTURE
// Reads and writes are independent, as AXI keeps them, and each side handles
// one burst at a time - which is all the DMA's master ever has outstanding.
//
//   read   AR (len N) -> N+1 lite AR/R pairs -> N+1 full R beats, RLAST on the
//          last one. RRESP is passed through per beat, which AXI4 allows.
//
//   write  AW (len N) + N+1 W beats -> N+1 lite AW/W/B triples -> one full B.
//          BRESP is sticky: the burst's response is the worst response any
//          beat got, because AXI4 gives a burst exactly one write response and
//          losing an error inside it would let a failed transfer look clean.
//
// The read data path is a straight pass-through rather than a store-and-
// forward: the lite R beat drives the full R channel directly, and the full
// master's RREADY gates the lite RREADY. That keeps the bridge to one beat of
// latency instead of two, and it cannot reorder or drop data.
//
// SUPPORTED SUBSET
// INCR and FIXED bursts, 32-bit beats (xSIZE = 3'b010). A request outside that
// - a WRAP burst, or a narrow transfer - is not silently mistranslated: the
// bridge answers the whole burst with SLVERR and issues nothing on the lite
// side. Quietly turning an unsupported burst into the wrong addresses is how
// a bridge corrupts memory in a way nobody finds for a week.

`timescale 1ns/1ps

module axi_full2lite (
    input             clk_i,
    input             rst_n_i,

    // ---- AXI4-Full slave side (faces the DMA's master port) ----
    input      [31:0] s_awaddr_i,
    input      [7:0]  s_awlen_i,
    input      [2:0]  s_awsize_i,
    input      [1:0]  s_awburst_i,
    input             s_awvalid_i,
    output            s_awready_o,
    input      [31:0] s_wdata_i,
    input      [3:0]  s_wstrb_i,
    input             s_wlast_i,
    input             s_wvalid_i,
    output            s_wready_o,
    output     [1:0]  s_bresp_o,
    output            s_bvalid_o,
    input             s_bready_i,
    input      [31:0] s_araddr_i,
    input      [7:0]  s_arlen_i,
    input      [2:0]  s_arsize_i,
    input      [1:0]  s_arburst_i,
    input             s_arvalid_i,
    output            s_arready_o,
    output     [31:0] s_rdata_o,
    output     [1:0]  s_rresp_o,
    output            s_rlast_o,
    output            s_rvalid_o,
    input             s_rready_i,

    // ---- AXI4-Lite master side (faces the interconnect) ----
    output     [31:0] m_awaddr_o,
    output     [2:0]  m_awprot_o,
    output            m_awvalid_o,
    input             m_awready_i,
    output     [31:0] m_wdata_o,
    output     [3:0]  m_wstrb_o,
    output            m_wvalid_o,
    input             m_wready_i,
    input      [1:0]  m_bresp_i,
    input             m_bvalid_i,
    output            m_bready_o,
    output     [31:0] m_araddr_o,
    output     [2:0]  m_arprot_o,
    output            m_arvalid_o,
    input             m_arready_i,
    input      [31:0] m_rdata_i,
    input      [1:0]  m_rresp_i,
    input             m_rvalid_i,
    output            m_rready_o
);

localparam [1:0] BURST_FIXED = 2'b00;
localparam [1:0] BURST_INCR  = 2'b01;
localparam [2:0] SIZE_32     = 3'b010;
localparam [1:0] RESP_OKAY   = 2'b00;
localparam [1:0] RESP_SLVERR = 2'b10;

// AXI4-Lite has no protection encoding of its own to carry over; the SoC's
// slaves ignore PROT, so drive the "data, secure, unprivileged" constant.
localparam [2:0] PROT_DATA = 3'b000;

// ===========================================================================
// read channel
// ===========================================================================
localparam [1:0] R_IDLE = 2'd0,
                 R_RUN  = 2'd1,   // walking the beats on the lite side
                 R_ERR  = 2'd2;   // unsupported request: answer without a bus access

reg [1:0]  r_state;
reg [31:0] r_addr;      // address of the beat being fetched
reg [7:0]  r_len;       // AXI encoding: beats - 1
reg [7:0]  r_beat;      // beat index, 0 .. r_len
reg        r_fixed;     // FIXED burst: do not advance the address
reg        r_ar_sent;   // lite AR for this beat has been accepted

wire r_last = (r_beat == r_len);

wire ar_supported = (s_arburst_i == BURST_INCR || s_arburst_i == BURST_FIXED)
                    && (s_arsize_i == SIZE_32);

assign s_arready_o = (r_state == R_IDLE);

// lite AR: one per beat
assign m_araddr_o  = r_addr;
assign m_arprot_o  = PROT_DATA;
assign m_arvalid_o = (r_state == R_RUN) && !r_ar_sent;

// "the AR for this beat is accepted" - counting the handshake happening right
// now, not only the registered flag. A slave is allowed to return RVALID in
// the same cycle it takes ARREADY; every slave in this SoC needs at least one
// cycle, but a bridge that only works with slow slaves is a trap for the next
// person who attaches a faster one.
wire r_ar_ack = r_ar_sent || (m_arvalid_o && m_arready_i);

// lite R straight onto the full R channel
assign m_rready_o  = (r_state == R_RUN) && r_ar_ack && s_rready_i;

assign s_rdata_o   = (r_state == R_ERR) ? 32'h0        : m_rdata_i;
assign s_rresp_o   = (r_state == R_ERR) ? RESP_SLVERR  : m_rresp_i;
assign s_rvalid_o  = (r_state == R_ERR) ? 1'b1
                                        : ((r_state == R_RUN) && r_ar_ack && m_rvalid_i);
assign s_rlast_o   = r_last;

wire r_beat_done = s_rvalid_o && s_rready_i;

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        r_state   <= R_IDLE;
        r_addr    <= 32'h0;
        r_len     <= 8'h0;
        r_beat    <= 8'h0;
        r_fixed   <= 1'b0;
        r_ar_sent <= 1'b0;
    end else begin
        case (r_state)
            R_IDLE: begin
                if (s_arvalid_i && s_arready_o) begin
                    r_addr    <= s_araddr_i;
                    r_len     <= s_arlen_i;
                    r_beat    <= 8'h0;
                    r_fixed   <= (s_arburst_i == BURST_FIXED);
                    r_ar_sent <= 1'b0;
                    r_state   <= ar_supported ? R_RUN : R_ERR;
                end
            end

            R_RUN: begin
                if (m_arvalid_o && m_arready_i)
                    r_ar_sent <= 1'b1;

                if (r_beat_done) begin
                    r_ar_sent <= 1'b0;
                    if (r_last) begin
                        r_state <= R_IDLE;
                    end else begin
                        r_beat <= r_beat + 8'd1;
                        if (!r_fixed)
                            r_addr <= r_addr + 32'd4;
                    end
                end
            end

            R_ERR: begin
                // still owes the master len+1 beats, just with SLVERR on each
                if (r_beat_done) begin
                    if (r_last)
                        r_state <= R_IDLE;
                    else
                        r_beat <= r_beat + 8'd1;
                end
            end

            default: r_state <= R_IDLE;
        endcase
    end
end

// ===========================================================================
// write channel
// ===========================================================================
localparam [1:0] W_IDLE = 2'd0,
                 W_RUN  = 2'd1,   // walking the beats on the lite side
                 W_ERR  = 2'd2,   // unsupported request: swallow the beats
                 W_RESP = 2'd3;   // one full B for the whole burst

reg [1:0]  w_state;
reg [31:0] w_addr;
reg [7:0]  w_len;
reg [7:0]  w_beat;
reg        w_fixed;
reg        w_aw_sent;   // lite AW for this beat accepted
reg        w_w_sent;    // lite W  for this beat accepted
reg [1:0]  w_resp;      // sticky worst response over the burst

wire w_last = (w_beat == w_len);

wire aw_supported = (s_awburst_i == BURST_INCR || s_awburst_i == BURST_FIXED)
                    && (s_awsize_i == SIZE_32);

assign s_awready_o = (w_state == W_IDLE);

// lite AW: one per beat
assign m_awaddr_o  = w_addr;
assign m_awprot_o  = PROT_DATA;
assign m_awvalid_o = (w_state == W_RUN) && !w_aw_sent;

// the full W beat feeds the lite W beat directly
assign m_wdata_o   = s_wdata_i;
assign m_wstrb_o   = s_wstrb_i;
assign m_wvalid_o  = (w_state == W_RUN) && !w_w_sent && s_wvalid_i;
assign s_wready_o  = (w_state == W_ERR) ? 1'b1
                                        : ((w_state == W_RUN) && !w_w_sent && m_wready_i);

// same reasoning as r_ar_ack on the read side
wire w_aw_ack = w_aw_sent || (m_awvalid_o && m_awready_i);
wire w_w_ack  = w_w_sent  || (m_wvalid_o  && m_wready_i);

// lite B is consumed per beat and folded into w_resp
assign m_bready_o  = (w_state == W_RUN) && w_aw_ack && w_w_ack;

assign s_bresp_o   = w_resp;
assign s_bvalid_o  = (w_state == W_RESP);

wire w_data_hs  = s_wvalid_i && s_wready_o;                 // one full W beat taken
wire w_beat_ack = m_bvalid_i && m_bready_o;                 // lite write completed

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        w_state   <= W_IDLE;
        w_addr    <= 32'h0;
        w_len     <= 8'h0;
        w_beat    <= 8'h0;
        w_fixed   <= 1'b0;
        w_aw_sent <= 1'b0;
        w_w_sent  <= 1'b0;
        w_resp    <= RESP_OKAY;
    end else begin
        case (w_state)
            W_IDLE: begin
                if (s_awvalid_i && s_awready_o) begin
                    w_addr    <= s_awaddr_i;
                    w_len     <= s_awlen_i;
                    w_beat    <= 8'h0;
                    w_fixed   <= (s_awburst_i == BURST_FIXED);
                    w_aw_sent <= 1'b0;
                    w_w_sent  <= 1'b0;
                    w_resp    <= aw_supported ? RESP_OKAY : RESP_SLVERR;
                    w_state   <= aw_supported ? W_RUN : W_ERR;
                end
            end

            W_RUN: begin
                if (m_awvalid_o && m_awready_i)
                    w_aw_sent <= 1'b1;
                if (w_data_hs)
                    w_w_sent <= 1'b1;

                if (w_beat_ack) begin
                    // worst response wins: OKAY loses to SLVERR and DECERR
                    if (m_bresp_i != RESP_OKAY)
                        w_resp <= m_bresp_i;

                    w_aw_sent <= 1'b0;
                    w_w_sent  <= 1'b0;
                    if (w_last) begin
                        w_state <= W_RESP;
                    end else begin
                        w_beat <= w_beat + 8'd1;
                        if (!w_fixed)
                            w_addr <= w_addr + 32'd4;
                    end
                end
            end

            W_ERR: begin
                // consume the data beats so the master is not left hanging,
                // then answer the burst with the SLVERR already latched
                if (w_data_hs) begin
                    if (w_last)
                        w_state <= W_RESP;
                    else
                        w_beat <= w_beat + 8'd1;
                end
            end

            W_RESP: begin
                if (s_bready_i)
                    w_state <= W_IDLE;
            end

            default: w_state <= W_IDLE;
        endcase
    end
end

endmodule
