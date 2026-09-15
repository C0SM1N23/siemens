// AXI4-Full to AXI4-Lite bridge: one Lite transaction per burst beat.
// Independent read/write paths, one burst outstanding per direction.
// Supports FIXED/INCR with 32-bit beats; other size/burst encodings return SLVERR.
// Reads pass RRESP per beat. Write aggregation is a project policy: DECERR > SLVERR > OKAY.

module soc_axi_full2lite (
    input clk_i,
    input rst_n_i,

    // ---- AXI4-Full slave side (faces the DMA's master port) ----
    input  [31:0] s_awaddr_i,
    input  [ 7:0] s_awlen_i,
    input  [ 2:0] s_awsize_i,
    input  [ 1:0] s_awburst_i,
    input         s_awvalid_i,
    output        s_awready_o,
    input  [31:0] s_wdata_i,
    input  [ 3:0] s_wstrb_i,
    input         s_wlast_i,
    input         s_wvalid_i,
    output        s_wready_o,
    output [ 1:0] s_bresp_o,
    output        s_bvalid_o,
    input         s_bready_i,
    input  [31:0] s_araddr_i,
    input  [ 7:0] s_arlen_i,
    input  [ 2:0] s_arsize_i,
    input  [ 1:0] s_arburst_i,
    input         s_arvalid_i,
    output        s_arready_o,
    output [31:0] s_rdata_o,
    output [ 1:0] s_rresp_o,
    output        s_rlast_o,
    output        s_rvalid_o,
    input         s_rready_i,

    // ---- AXI4-Lite master side (faces the interconnect) ----
    output [31:0] m_awaddr_o,
    output [ 2:0] m_awprot_o,
    output        m_awvalid_o,
    input         m_awready_i,
    output [31:0] m_wdata_o,
    output [ 3:0] m_wstrb_o,
    output        m_wvalid_o,
    input         m_wready_i,
    input  [ 1:0] m_bresp_i,
    input         m_bvalid_i,
    output        m_bready_o,
    output [31:0] m_araddr_o,
    output [ 2:0] m_arprot_o,
    output        m_arvalid_o,
    input         m_arready_i,
    input  [31:0] m_rdata_i,
    input  [ 1:0] m_rresp_i,
    input         m_rvalid_i,
    output        m_rready_o
);

    localparam [1:0] BURST_FIXED = 2'b00;
    localparam [1:0] BURST_INCR = 2'b01;
    localparam [2:0] SIZE_32 = 3'b010;
    localparam [1:0] RESP_OKAY = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;

    // AXI4-Lite has no protection encoding of its own to carry over; the SoC's
    // slaves ignore PROT, so drive the "data, secure, unprivileged" constant.
    localparam [2:0] PROT_DATA = 3'b000;

    // ===========================================================================
    // read channel
    // ===========================================================================
    localparam [1:0] R_IDLE = 2'd0, R_RUN = 2'd1,  // walking the beats on the lite side
    R_ERR = 2'd2;  // unsupported request: answer without a bus access

    reg [1:0] r_state;
    reg [31:0] r_addr;  // address of the beat being fetched
    reg [7:0] r_len;  // AXI encoding: beats - 1
    reg [7:0] r_beat;  // beat index, 0 .. r_len
    reg r_fixed;  // FIXED burst: do not advance the address
    reg r_ar_sent;  // lite AR for this beat has been accepted

    wire r_last = (r_beat == r_len);

    wire ar_supported = (s_arburst_i == BURST_INCR || s_arburst_i == BURST_FIXED)
                    && (s_arsize_i == SIZE_32);

    assign s_arready_o = (r_state == R_IDLE);

    // lite AR: one per beat
    assign m_araddr_o  = r_addr;
    assign m_arprot_o  = PROT_DATA;
    assign m_arvalid_o = (r_state == R_RUN) && !r_ar_sent;

    // A response may follow an AR accepted in the same cycle.
    // Include the current handshake when qualifying RREADY.
    wire r_ar_ack = r_ar_sent || (m_arvalid_o && m_arready_i);

    // lite R straight onto the full R channel
    assign m_rready_o = (r_state == R_RUN) && r_ar_ack && s_rready_i;

    assign s_rdata_o  = (r_state == R_ERR) ? 32'h0 : m_rdata_i;
    assign s_rresp_o  = (r_state == R_ERR) ? RESP_SLVERR : m_rresp_i;
    assign s_rvalid_o = (r_state == R_ERR) ? 1'b1 : ((r_state == R_RUN) && r_ar_ack && m_rvalid_i);
    assign s_rlast_o  = r_last;

    wire r_beat_done = s_rvalid_o && s_rready_i;

    wire read_start = s_arvalid_i && s_arready_o;

    // Read state and burst payload.
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) r_state <= R_IDLE;
        else if (read_start) r_state <= ar_supported ? R_RUN : R_ERR;
        else if (r_beat_done && r_last) r_state <= R_IDLE;
        else if (r_state == 2'd3) r_state <= R_IDLE;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) r_addr <= 32'b0;
        else if (read_start) r_addr <= s_araddr_i;
        else if (r_state == R_RUN && r_beat_done && !r_last && !r_fixed) r_addr <= r_addr + 32'd4;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) r_len <= 8'b0;
        else if (read_start) r_len <= s_arlen_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) r_beat <= 8'b0;
        else if (read_start) r_beat <= 8'b0;
        else if (r_beat_done && !r_last) r_beat <= r_beat + 8'd1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) r_fixed <= 1'b0;
        else if (read_start) r_fixed <= s_arburst_i == BURST_FIXED;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) r_ar_sent <= 1'b0;
        else if (read_start || r_beat_done) r_ar_sent <= 1'b0;
        else if (m_arvalid_o && m_arready_i) r_ar_sent <= 1'b1;
    end

    // ===========================================================================
    // write channel
    // ===========================================================================
    localparam [1:0] W_IDLE = 2'd0, W_RUN = 2'd1,  // walking the beats on the lite side
    W_ERR = 2'd2,  // unsupported request: swallow the beats
    W_RESP = 2'd3;  // one full B for the whole burst

    reg [1:0] w_state;
    reg [31:0] w_addr;
    reg [7:0] w_len;
    reg [7:0] w_beat;
    reg w_fixed;
    reg w_aw_sent;  // lite AW for this beat accepted
    reg w_w_sent;  // lite W  for this beat accepted
    reg [1:0] w_resp;  // sticky worst response over the burst

    wire w_last = (w_beat == w_len);

    wire aw_supported = (s_awburst_i == BURST_INCR || s_awburst_i == BURST_FIXED)
                    && (s_awsize_i == SIZE_32);

    assign s_awready_o = (w_state == W_IDLE);

    // lite AW: one per beat
    assign m_awaddr_o = w_addr;
    assign m_awprot_o = PROT_DATA;
    assign m_awvalid_o = (w_state == W_RUN) && !w_aw_sent;

    // the full W beat feeds the lite W beat directly
    assign m_wdata_o = s_wdata_i;
    assign m_wstrb_o = s_wstrb_i;
    assign m_wvalid_o = (w_state == W_RUN) && !w_w_sent && s_wvalid_i;
    assign s_wready_o = (w_state == W_ERR) ? 1'b1 : ((w_state == W_RUN) && !w_w_sent && m_wready_i);

    // same reasoning as r_ar_ack on the read side
    wire w_aw_ack = w_aw_sent || (m_awvalid_o && m_awready_i);
    wire w_w_ack = w_w_sent || (m_wvalid_o && m_wready_i);

    // lite B is consumed per beat and folded into w_resp
    assign m_bready_o = (w_state == W_RUN) && w_aw_ack && w_w_ack;

    assign s_bresp_o  = w_resp;
    assign s_bvalid_o = (w_state == W_RESP);

    wire w_data_hs = s_wvalid_i && s_wready_o;  // one full W beat taken
    wire w_beat_ack = m_bvalid_i && m_bready_o;  // lite write completed

    wire write_start = s_awvalid_i && s_awready_o;
    wire write_advance = w_beat_ack || (w_state == W_ERR && w_data_hs);

    // Write state, address and beat tracking.
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_state <= W_IDLE;
        else if (write_start) w_state <= aw_supported ? W_RUN : W_ERR;
        else if (write_advance && w_last) w_state <= W_RESP;
        else if (w_state == W_RESP && s_bready_i) w_state <= W_IDLE;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_addr <= 32'b0;
        else if (write_start) w_addr <= s_awaddr_i;
        else if (w_beat_ack && !w_last && !w_fixed) w_addr <= w_addr + 32'd4;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_len <= 8'b0;
        else if (write_start) w_len <= s_awlen_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_beat <= 8'b0;
        else if (write_start) w_beat <= 8'b0;
        else if (write_advance && !w_last) w_beat <= w_beat + 8'd1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_fixed <= 1'b0;
        else if (write_start) w_fixed <= s_awburst_i == BURST_FIXED;
    end

    // AW and W can complete in either order. Each beat waits for both.
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_aw_sent <= 1'b0;
        else if (write_start || w_beat_ack) w_aw_sent <= 1'b0;
        else if (m_awvalid_o && m_awready_i) w_aw_sent <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_w_sent <= 1'b0;
        else if (write_start || w_beat_ack) w_w_sent <= 1'b0;
        else if (w_state == W_RUN && w_data_hs) w_w_sent <= 1'b1;
    end

    // Project response policy: DECERR > SLVERR > OKAY.
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_resp <= RESP_OKAY;
        else if (write_start) w_resp <= aw_supported ? RESP_OKAY : RESP_SLVERR;
        else if (w_beat_ack && m_bresp_i > w_resp) w_resp <= m_bresp_i;
    end

endmodule
