module mc_dma_axi4_full_master (
    input               clk_i,
    input               rst_ni,

    // Transfer Port: AXI4-Full Master Interface
    // Write Address Channel
    output reg  [31:0]  m_axi_awaddr_o,
    output reg  [7:0]   m_axi_awlen_o,
    output      [2:0]   m_axi_awsize_o,
    output      [1:0]   m_axi_awburst_o,
    output reg          m_axi_awvalid_o,
    input               m_axi_awready_i,
    
    // Write Data Channel
    output reg  [31:0]  m_axi_wdata_o,
    output reg  [3:0]   m_axi_wstrb_o,
    output reg          m_axi_wlast_o,
    output reg          m_axi_wvalid_o,
    input               m_axi_wready_i,
    
    // Write Response Channel
    input       [1:0]   m_axi_bresp_i,
    input               m_axi_bvalid_i,
    output reg          m_axi_bready_o,
    
    // Read Address Channel
    output reg  [31:0]  m_axi_araddr_o,
    output reg  [7:0]   m_axi_arlen_o,
    output      [2:0]   m_axi_arsize_o,
    output      [1:0]   m_axi_arburst_o,
    output reg          m_axi_arvalid_o,
    input               m_axi_arready_i,
    
    // Read Data Channel
    input       [31:0]  m_axi_rdata_i,
    input       [1:0]   m_axi_rresp_i,
    input               m_axi_rlast_i,
    input               m_axi_rvalid_i,
    output reg          m_axi_rready_o,

    // Interface from Priority Arbiter
    input               master_req_valid_i,
    input       [31:0]  master_req_addr_i,
    input       [7:0]   master_req_len_i,
    input               master_req_is_write_i,
    input       [1:0]   master_req_ch_id_i,
    output reg          master_req_ready_o,

    // Scatter-Gather Loop (Master to Channels)
    output reg  [31:0]  fetch_data_o,
    output reg          fetch_data_valid_o
);

    // FSM State encoding
    localparam STATE_IDLE       = 3'd0;
    localparam STATE_READ_ADDR  = 3'd1;
    localparam STATE_READ_DATA  = 3'd2;
    localparam STATE_WRITE_ADDR = 3'd3;
    localparam STATE_WRITE_DATA = 3'd4;
    localparam STATE_WRITE_RESP = 3'd5;

    assign m_axi_arsize_o  = 3'b010; // 4 bytes per beat
    assign m_axi_arburst_o = 2'b01;  // INCR burst type
    assign m_axi_awsize_o  = 3'b010; 
    assign m_axi_awburst_o = 2'b01;

    reg [2:0] state;
    reg [7:0] burst_cnt;
    // data_fifo per-canal (4 canale x 8 cuvinte), nu un singur buffer global.
    // Un buffer global partajat intre canale corupe datele cand doua canale
    // sunt intercalate de arbitru (ex: Round-Robin) - vezi active_ch_id mai jos.
    reg [31:0] data_fifo [0:3][0:7];

    // Retine carui canal ii apartine tranzactia curenta
    reg [1:0] active_ch_id;
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            active_ch_id <= 2'd0;
        else if (state == STATE_IDLE && master_req_valid_i)
            active_ch_id <= master_req_ch_id_i;
    end

    // 1. Master State Machine
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state <= STATE_IDLE;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (master_req_valid_i) begin
                        if (master_req_is_write_i)
                            state <= STATE_WRITE_ADDR;
                        else
                            state <= STATE_READ_ADDR;
                    end
                end
                
                STATE_READ_ADDR: begin
                    if (m_axi_arready_i && m_axi_arvalid_o)
                        state <= STATE_READ_DATA;
                end
                
                STATE_READ_DATA: begin
                    if (m_axi_rvalid_i && m_axi_rready_o && m_axi_rlast_i)
                        state <= STATE_IDLE;
                end
                
                STATE_WRITE_ADDR: begin
                    if (m_axi_awready_i && m_axi_awvalid_o)
                        state <= STATE_WRITE_DATA;
                end
                
                STATE_WRITE_DATA: begin
                    if (m_axi_wvalid_o && m_axi_wready_i && m_axi_wlast_o)
                        state <= STATE_WRITE_RESP;
                end
                
                STATE_WRITE_RESP: begin
                    if (m_axi_bvalid_i && m_axi_bready_o)
                        state <= STATE_IDLE;
                end
                
                default:
                    state <= STATE_IDLE;
            endcase
        end
    end

    // 2. Burst Counter
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            burst_cnt <= 8'h0;
        else if (state == STATE_IDLE)
            burst_cnt <= 8'h0;
        else if (state == STATE_READ_DATA && m_axi_rvalid_i && m_axi_rready_o)
            burst_cnt <= burst_cnt + 1'b1;
        else if (state == STATE_WRITE_DATA && m_axi_wvalid_o && m_axi_wready_i)
            burst_cnt <= burst_cnt + 1'b1;
    end

    // 3. Arbiter Ready Signal
    // Tells the arbiter we are free to take a new command
    // ==== FIX 2: Semnal combinațional dependent doar de stare ====
    always @(*) begin
        if (state == STATE_IDLE)
            master_req_ready_o = 1'b1;
        else
            master_req_ready_o = 1'b0;
    end

    // 4. Read Address Channel (AR)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_arvalid_o <= 1'b0;
        else if (state == STATE_IDLE && master_req_valid_i && ~master_req_is_write_i)
            m_axi_arvalid_o <= 1'b1;
        else if (m_axi_arready_i && m_axi_arvalid_o)
            m_axi_arvalid_o <= 1'b0;
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_araddr_o <= 32'h0;
        else if (state == STATE_IDLE && master_req_valid_i)
            m_axi_araddr_o <= master_req_addr_i;
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_arlen_o <= 8'h0;
        else if (state == STATE_IDLE && master_req_valid_i)
            m_axi_arlen_o <= master_req_len_i;
    end

    // 5. Read Data Channel (R)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_rready_o <= 1'b0;
        else if (state == STATE_READ_DATA && ~(m_axi_rvalid_i && m_axi_rready_o && m_axi_rlast_i))
            m_axi_rready_o <= 1'b1;
        else
            m_axi_rready_o <= 1'b0;
    end

    // Forward read data to the Scatter-Gather loop
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            fetch_data_valid_o <= 1'b0;
        else if (state == STATE_READ_DATA && m_axi_rvalid_i && m_axi_rready_o)
            fetch_data_valid_o <= 1'b1;
        else
            fetch_data_valid_o <= 1'b0;
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            fetch_data_o <= 32'h0;
        else if (state == STATE_READ_DATA && m_axi_rvalid_i)
            fetch_data_o <= m_axi_rdata_i;
    end

    integer c, w;
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            for (c = 0; c < 4; c = c + 1)
                for (w = 0; w < 8; w = w + 1)
                    data_fifo[c][w] <= 32'h0;
        end else if (state == STATE_READ_DATA && m_axi_rvalid_i) begin
            data_fifo[active_ch_id][burst_cnt[2:0]] <= m_axi_rdata_i;
        end
    end

    // 6. Write Address Channel (AW)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_awvalid_o <= 1'b0;
        else if (state == STATE_IDLE && master_req_valid_i && master_req_is_write_i)
            m_axi_awvalid_o <= 1'b1;
        else if (m_axi_awready_i && m_axi_awvalid_o)
            m_axi_awvalid_o <= 1'b0;
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_awaddr_o <= 32'h0;
        else if (state == STATE_IDLE && master_req_valid_i)
            m_axi_awaddr_o <= master_req_addr_i;
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_awlen_o <= 8'h0;
        else if (state == STATE_IDLE && master_req_valid_i)
            m_axi_awlen_o <= master_req_len_i;
    end

    // 7. Write Data Channel (W)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_wvalid_o <= 1'b0;
        else if (state == STATE_WRITE_DATA && ~(m_axi_wvalid_o && m_axi_wready_i && m_axi_wlast_o))
            m_axi_wvalid_o <= 1'b1;
        else
            m_axi_wvalid_o <= 1'b0;
    end

    // FIX: m_axi_wdata_o trebuie sa fie COMBINATIONAL, la fel ca m_axi_wlast_o
    // (vezi "CORECTIE" mai jos), nu inregistrat. In varianta originala,
    // m_axi_wdata_o era un registru care selecta data_fifo[burst_cnt] folosind
    // valoarea PRE-CLOCK-EDGE a lui burst_cnt, in acelasi ciclu in care
    // burst_cnt se incrementa tot pe baza valorii pre-edge. Efectul: primul
    // cuvant era duplicat, iar ultimul cuvant din fiecare burst de scriere
    // se pierdea (shift de o pozitie) - exact tiparul observat: 0x2000 si
    // 0x2004 aveau aceeasi valoare, iar 0x201C avea valoarea care ar fi
    // trebuit sa fie la 0x2018.
    always @(*) begin
        m_axi_wdata_o = data_fifo[active_ch_id][burst_cnt[2:0]];
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_wstrb_o <= 4'h0;
        else if (state == STATE_WRITE_DATA)
            m_axi_wstrb_o <= 4'hF;
    end

    // CORECȚIE: m_axi_wlast_o devine 1 imediat ce burst_cnt a ajuns la awlen,
    // în ACELAȘI ciclu de ceas cu ultima dată validă.
    always @(*) begin
        if (state == STATE_WRITE_DATA && burst_cnt == m_axi_awlen_o)
            m_axi_wlast_o = 1'b1;
        else
            m_axi_wlast_o = 1'b0;
    end

    // 8. Write Response Channel (B)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            m_axi_bready_o <= 1'b0;
        else if (state == STATE_WRITE_RESP && ~(m_axi_bvalid_i && m_axi_bready_o))
            m_axi_bready_o <= 1'b1;
        else
            m_axi_bready_o <= 1'b0;
    end

endmodule