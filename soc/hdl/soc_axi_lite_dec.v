// AXI4-Lite decoder: one master, N disjoint address windows and a DECERR responder.
// One outstanding transaction per direction. W waits until AW supplies its route.
// B/R use the accepted address selection; the next AR may overlap a completing R.
// BASE/MASK pack slave 0 in the least-significant word. Responses pass through.

module soc_axi_lite_dec #(
    parameter integer            N    = 2,  // number of slave ports
    parameter         [N*32-1:0] BASE = 0,  // window base per slave, packed
    parameter         [N*32-1:0] MASK = 0   // window mask per slave, packed
) (
    input clk_i,
    input rst_n_i,

    // master side
    input  [31:0] m_awaddr_i,
    input  [ 2:0] m_awprot_i,
    input         m_awvalid_i,
    output        m_awready_o,
    input  [31:0] m_wdata_i,
    input  [ 3:0] m_wstrb_i,
    input         m_wvalid_i,
    output        m_wready_o,
    output [ 1:0] m_bresp_o,
    output        m_bvalid_o,
    input         m_bready_i,
    input  [31:0] m_araddr_i,
    input  [ 2:0] m_arprot_i,
    input         m_arvalid_i,
    output        m_arready_o,
    output [31:0] m_rdata_o,
    output [ 1:0] m_rresp_o,
    output        m_rvalid_o,
    input         m_rready_i,

    // slave side, packed: slave i occupies bits [i*W +: W]
    output [N*32-1:0] s_awaddr_o,
    output [ N*3-1:0] s_awprot_o,
    output [   N-1:0] s_awvalid_o,
    input  [   N-1:0] s_awready_i,
    output [N*32-1:0] s_wdata_o,
    output [ N*4-1:0] s_wstrb_o,
    output [   N-1:0] s_wvalid_o,
    input  [   N-1:0] s_wready_i,
    input  [ N*2-1:0] s_bresp_i,
    input  [   N-1:0] s_bvalid_i,
    output [   N-1:0] s_bready_o,
    output [N*32-1:0] s_araddr_o,
    output [ N*3-1:0] s_arprot_o,
    output [   N-1:0] s_arvalid_o,
    input  [   N-1:0] s_arready_i,
    input  [N*32-1:0] s_rdata_i,
    input  [ N*2-1:0] s_rresp_i,
    input  [   N-1:0] s_rvalid_i,
    output [   N-1:0] s_rready_o
);

    localparam [1:0] RESP_DECERR = 2'b11;

    // ---------------------------------------------------------------------------
    // window compare
    // ---------------------------------------------------------------------------
    wire [N-1:0] aw_hit;
    wire [N-1:0] ar_hit;

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_window
            // pulled onto nets rather than part-selecting the parameter inline:
            // clearer in a waveform and portable across front-ends
            wire [31:0] base_w = BASE[i*32+:32];
            wire [31:0] mask_w = MASK[i*32+:32];

            assign aw_hit[i] = m_awvalid_i && ((m_awaddr_i & mask_w) == (base_w & mask_w));
            assign ar_hit[i] = m_arvalid_i && ((m_araddr_i & mask_w) == (base_w & mask_w));
        end
    endgenerate

    // address on the wire but inside no window -> the error responder
    wire aw_none = m_awvalid_i && ~|aw_hit;
    wire ar_none = m_arvalid_i && ~|ar_hit;

    // ---------------------------------------------------------------------------
    // latched select, held from the address handshake until the response completes
    // ---------------------------------------------------------------------------
    reg [N-1:0] wr_sel_q, rd_sel_q;
    reg wr_err_q, rd_err_q;
    reg wr_addr_valid_q;
    reg wr_data_valid_q;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_addr_valid_q <= 1'b0;
        else if (m_bvalid_o && m_bready_i) wr_addr_valid_q <= 1'b0;
        else if (m_awvalid_i && m_awready_o) wr_addr_valid_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_data_valid_q <= 1'b0;
        else if (m_bvalid_o && m_bready_i) wr_data_valid_q <= 1'b0;
        else if (m_wvalid_i && m_wready_o) wr_data_valid_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) wr_sel_q <= {N{1'b0}};
        else if (m_awvalid_i && m_awready_o) wr_sel_q <= aw_hit;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) wr_err_q <= 1'b0;
        else if (m_awvalid_i && m_awready_o) wr_err_q <= aw_none;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) rd_sel_q <= {N{1'b0}};
        else if (m_arvalid_i && m_arready_o) rd_sel_q <= ar_hit;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) rd_err_q <= 1'b0;
        else if (m_arvalid_i && m_arready_o) rd_err_q <= ar_none;
    end

    // W waits for an offered or accepted AW. A completed write leaves no route.
    wire [N-1:0] wr_sel = wr_addr_valid_q ? wr_sel_q : aw_hit;
    wire         wr_err = wr_addr_valid_q ? wr_err_q : aw_none;

    // ---------------------------------------------------------------------------
    // DECERR responder for unmapped addresses
    // ---------------------------------------------------------------------------
    reg err_awdone, err_wdone, err_bvalid;
    reg  err_rvalid;

    wire err_awready = aw_none & ~err_awdone & ~err_bvalid;
    wire err_wready = wr_err & ~err_wdone & ~err_bvalid;
    wire err_arready = ar_none & ~err_rvalid;

    wire err_aw_hs = m_awvalid_i & err_awready;
    wire err_w_hs = m_wvalid_i & err_wready;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) err_awdone <= 1'b0;
        else if (err_bvalid) begin
            if (m_bready_i) err_awdone <= 1'b0;
        end else err_awdone <= err_awdone | err_aw_hs;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) err_wdone <= 1'b0;
        else if (err_bvalid) begin
            if (m_bready_i) err_wdone <= 1'b0;
        end else err_wdone <= err_wdone | err_w_hs;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) err_bvalid <= 1'b0;
        else if (err_bvalid) begin
            if (m_bready_i) err_bvalid <= 1'b0;
        end else begin
            if ((err_awdone | err_aw_hs) && (err_wdone | err_w_hs)) err_bvalid <= 1'b1;
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) err_rvalid <= 1'b0;
        else if (err_rvalid && m_rready_i) err_rvalid <= 1'b0;
        else if (m_arvalid_i && err_arready) err_rvalid <= 1'b1;
    end

    // ---------------------------------------------------------------------------
    // one-hot response muxes
    // ---------------------------------------------------------------------------
    reg [ 1:0] bresp_mux;
    reg [ 1:0] rresp_mux;
    reg [31:0] rdata_mux;

    always @(*) begin : update_bresp_mux
        integer k;
        bresp_mux = 2'b00;
        for (k = 0; k < N; k = k + 1) if (wr_sel_q[k]) bresp_mux = s_bresp_i[k*2+:2];
    end

    always @(*) begin : update_rresp_mux
        integer k;
        rresp_mux = 2'b00;
        for (k = 0; k < N; k = k + 1) if (rd_sel_q[k]) rresp_mux = s_rresp_i[k*2+:2];
    end

    always @(*) begin : update_rdata_mux
        integer k;
        rdata_mux = 32'h0;
        for (k = 0; k < N; k = k + 1) if (rd_sel_q[k]) rdata_mux = s_rdata_i[k*32+:32];
    end

    // ---------------------------------------------------------------------------
    // master-side outputs
    // ---------------------------------------------------------------------------
    assign m_awready_o = !wr_addr_valid_q && (aw_none ? err_awready : |(aw_hit & s_awready_i));
    assign m_wready_o  = !wr_data_valid_q && (wr_err ? err_wready : |(wr_sel & s_wready_i));
    assign m_bvalid_o  = wr_addr_valid_q && (wr_err_q ? err_bvalid : |(wr_sel_q & s_bvalid_i));
    assign m_bresp_o   = wr_err_q ? RESP_DECERR : bresp_mux;

    assign m_arready_o = ar_none ? err_arready : |(ar_hit & s_arready_i);
    assign m_rvalid_o  = rd_err_q ? err_rvalid : |(rd_sel_q & s_rvalid_i);
    assign m_rresp_o   = rd_err_q ? RESP_DECERR : rresp_mux;
    assign m_rdata_o   = rd_err_q ? 32'h0 : rdata_mux;

    // ---------------------------------------------------------------------------
    // slave-side outputs: payload broadcast, VALID/READY qualified by the select
    // ---------------------------------------------------------------------------
    generate
        for (i = 0; i < N; i = i + 1) begin : g_fanout
            assign s_awaddr_o[i*32+:32] = m_awaddr_i;
            assign s_awprot_o[i*3+:3]   = m_awprot_i;
            assign s_awvalid_o[i]       = m_awvalid_i & aw_hit[i] & ~wr_addr_valid_q;

            assign s_wdata_o[i*32+:32]  = m_wdata_i;
            assign s_wstrb_o[i*4+:4]    = m_wstrb_i;
            assign s_wvalid_o[i]        = m_wvalid_i & wr_sel[i] & ~wr_data_valid_q;

            assign s_bready_o[i]        = m_bready_i & wr_sel_q[i] & wr_addr_valid_q;

            assign s_araddr_o[i*32+:32] = m_araddr_i;
            assign s_arprot_o[i*3+:3]   = m_arprot_i;
            assign s_arvalid_o[i]       = m_arvalid_i & ar_hit[i];

            assign s_rready_o[i]        = m_rready_i & rd_sel_q[i];
        end
    endgenerate

endmodule
