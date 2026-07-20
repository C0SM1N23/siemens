module axi4_full_master (
    input               clk,
    input               rst_n,

    // Transfer Port: AXI4-Full Master Interface
    // Write Address Channel
    output reg  [31:0]  m_axi_awaddr,
    output reg  [7:0]   m_axi_awlen,
    output reg  [2:0]   m_axi_awsize,
    output reg  [1:0]   m_axi_awburst,
    output reg          m_axi_awvalid,
    input               m_axi_awready,
    
    // Write Data Channel
    output reg  [31:0]  m_axi_wdata,
    output reg  [3:0]   m_axi_wstrb,
    output reg          m_axi_wlast,
    output reg          m_axi_wvalid,
    input               m_axi_wready,
    
    // Write Response Channel
    input       [1:0]   m_axi_bresp,
    input               m_axi_bvalid,
    output reg          m_axi_bready,
    
    // Read Address Channel
    output reg  [31:0]  m_axi_araddr,
    output reg  [7:0]   m_axi_arlen,
    output reg  [2:0]   m_axi_arsize,
    output reg  [1:0]   m_axi_arburst,
    output reg          m_axi_arvalid,
    input               m_axi_arready,
    
    // Read Data Channel
    input       [31:0]  m_axi_rdata,
    input       [1:0]   m_axi_rresp,
    input               m_axi_rlast,
    input               m_axi_rvalid,
    output reg          m_axi_rready,

    // Interface from Priority Arbiter
    input               master_req_valid,
    input       [31:0]  master_req_addr,
    input       [7:0]   master_req_len,
    input               master_req_is_write,
    // FIX BUG 2: identitatea canalului caruia ii apartine cererea curenta
    input       [1:0]   master_req_ch_id,
    output reg          master_req_ready,

    // Scatter-Gather Loop (Master to Channels)
    output reg  [31:0]  fetch_data_out,
    output reg          fetch_data_valid
);

    // FSM State encoding
    localparam STATE_IDLE       = 3'd0;
    localparam STATE_READ_ADDR  = 3'd1;
    localparam STATE_READ_DATA  = 3'd2;
    localparam STATE_WRITE_ADDR = 3'd3;
    localparam STATE_WRITE_DATA = 3'd4;
    localparam STATE_WRITE_RESP = 3'd5;

    reg [2:0] state;
    reg [7:0] burst_cnt;

    // FIX BUG 2: data_fifo devine un buffer PER-CANAL (4 canale x 8 cuvinte)
    // in loc de un singur buffer global partajat intre toate canalele.
    // In varianta originala, un singur data_fifo[0:7] era folosit pentru
    // orice transfer, indiferent de canal. Cum arbitrul (Round-Robin) poate
    // intercala liber READ-ul unui canal cu READ-ul altui canal INAINTE ca
    // primul canal sa apuce sa faca WRITE-ul corespunzator, al doilea READ
    // suprascria datele primului canal in bufferul comun -> canalul 1 ajungea
    // sa scrie datele canalului 2 la destinatia lui. Izolarea pe canal
    // elimina complet aceasta coruptie, indiferent de ordinea de intercalare
    // aleasa de arbitru.
    reg [31:0] data_fifo [0:3][0:7];

    // Retine carui canal ii apartine tranzactia curenta, capturat exact cand
    // cererea este acceptata din STATE_IDLE.
    reg [1:0] active_ch_id;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            active_ch_id <= 2'd0;
        else if (state == STATE_IDLE && master_req_valid)
            active_ch_id <= master_req_ch_id;
    end

    // 1. Master State Machine
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            state <= STATE_IDLE;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (master_req_valid) begin
                        if (master_req_is_write)
                            state <= STATE_WRITE_ADDR;
                        else
                            state <= STATE_READ_ADDR;
                    end
                end
                
                STATE_READ_ADDR: begin
                    if (m_axi_arready && m_axi_arvalid)
                        state <= STATE_READ_DATA;
                end
                
                STATE_READ_DATA: begin
                    if (m_axi_rvalid && m_axi_rready && m_axi_rlast)
                        state <= STATE_IDLE;
                end
                
                STATE_WRITE_ADDR: begin
                    if (m_axi_awready && m_axi_awvalid)
                        state <= STATE_WRITE_DATA;
                end
                
                STATE_WRITE_DATA: begin
                    if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                        state <= STATE_WRITE_RESP;
                end
                
                STATE_WRITE_RESP: begin
                    if (m_axi_bvalid && m_axi_bready)
                        state <= STATE_IDLE;
                end
                
                default:
                    state <= STATE_IDLE;
            endcase
        end
    end

    // 2. Burst Counter
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            burst_cnt <= 8'h0;
        else if (state == STATE_IDLE)
            burst_cnt <= 8'h0;
        else if (state == STATE_READ_DATA && m_axi_rvalid && m_axi_rready)
            burst_cnt <= burst_cnt + 1'b1;
        else if (state == STATE_WRITE_DATA && m_axi_wvalid && m_axi_wready)
            burst_cnt <= burst_cnt + 1'b1;
    end

    // 3. Arbiter Ready Signal
    // Tells the arbiter we are free to take a new command
    // ==== FIX 2: Semnal combinațional dependent doar de stare ====
    always @(*) begin
        if (state == STATE_IDLE)
            master_req_ready = 1'b1;
        else
            master_req_ready = 1'b0;
    end

    // 4. Read Address Channel (AR)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_arvalid <= 1'b0;
        else if (state == STATE_IDLE && master_req_valid && ~master_req_is_write)
            m_axi_arvalid <= 1'b1;
        else if (m_axi_arready && m_axi_arvalid)
            m_axi_arvalid <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_araddr <= 32'h0;
        else if (state == STATE_IDLE && master_req_valid)
            m_axi_araddr <= master_req_addr;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_arlen <= 8'h0;
        else if (state == STATE_IDLE && master_req_valid)
            m_axi_arlen <= master_req_len;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_arsize <= 3'b010; // 4 bytes per beat
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_arburst <= 2'b01; // INCR burst type
    end

    // 5. Read Data Channel (R)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_rready <= 1'b0;
        else if (state == STATE_READ_DATA)
            m_axi_rready <= 1'b1;
        else
            m_axi_rready <= 1'b0;
    end

    // Forward read data to the Scatter-Gather loop
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            fetch_data_valid <= 1'b0;
        else if (state == STATE_READ_DATA && m_axi_rvalid && m_axi_rready)
            fetch_data_valid <= 1'b1;
        else
            fetch_data_valid <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            fetch_data_out <= 32'h0;
        else if (state == STATE_READ_DATA && m_axi_rvalid)
            fetch_data_out <= m_axi_rdata;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            data_fifo[active_ch_id][burst_cnt[2:0]] <= 32'h0;
        // FIX BUG 1 (latura de citire): "&& m_axi_rready" adaugat astfel
        // incat capturarea sa fie sincronizata exact cu avansul lui
        // burst_cnt (care avanseaza doar pe rvalid && rready).
        // FIX BUG 2: indexare pe active_ch_id, nu pe un buffer global.
        else if (state == STATE_READ_DATA && m_axi_rvalid && m_axi_rready)
            data_fifo[active_ch_id][burst_cnt[2:0]] <= m_axi_rdata;
    end

    // 6. Write Address Channel (AW)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_awvalid <= 1'b0;
        else if (state == STATE_IDLE && master_req_valid && master_req_is_write)
            m_axi_awvalid <= 1'b1;
        else if (m_axi_awready && m_axi_awvalid)
            m_axi_awvalid <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_awaddr <= 32'h0;
        else if (state == STATE_IDLE && master_req_valid)
            m_axi_awaddr <= master_req_addr;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_awlen <= 8'h0;
        else if (state == STATE_IDLE && master_req_valid)
            m_axi_awlen <= master_req_len;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_awsize <= 3'b010; 
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_awburst <= 2'b01; 
    end

    // 7. Write Data Channel (W)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_wvalid <= 1'b0;
        else if (state == STATE_WRITE_DATA)
            m_axi_wvalid <= 1'b1;
        else
            m_axi_wvalid <= 1'b0;
    end

    // FIX BUG 1 (latura de scriere): m_axi_wdata este COMBINATIONAL, la fel
    // ca m_axi_wlast (vezi "CORECTIE" mai jos), nu inregistrat. In varianta
    // originala, un registru selecta data_fifo[burst_cnt] folosind valoarea
    // PRE-CLOCK-EDGE a lui burst_cnt, in acelasi bloc always in care
    // burst_cnt se incrementa tot pe baza valorii pre-edge. Efectul: primul
    // beat era prezentat corect, dar wdata ramanea "in urma" cu un ciclu fata
    // de burst_cnt real, ducand la duplicarea primului cuvant si pierderea
    // ultimului cuvant din fiecare burst de scriere.
    // FIX BUG 2: indexare pe active_ch_id, nu pe un buffer global.
    always @(*) begin
        m_axi_wdata = data_fifo[active_ch_id][burst_cnt[2:0]];
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_wstrb <= 4'h0;
        else if (state == STATE_WRITE_DATA)
            m_axi_wstrb <= 4'hF;
    end

    // CORECȚIE: m_axi_wlast devine 1 imediat ce burst_cnt a ajuns la awlen,
    // în ACELAȘI ciclu de ceas cu ultima dată validă.
    always @(*) begin
        if (state == STATE_WRITE_DATA && burst_cnt == m_axi_awlen)
            m_axi_wlast = 1'b1;
        else
            m_axi_wlast = 1'b0;
    end

    // 8. Write Response Channel (B)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_bready <= 1'b0;
        else if (state == STATE_WRITE_RESP)
            m_axi_bready <= 1'b1;
        else
            m_axi_bready <= 1'b0;
    end

endmodule