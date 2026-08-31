module axi4_full_master (
    input               clk,
    input               rst_n,

    // Transfer Port: AXI4-Full Master Interface
    // Write Address Channel
    output reg  [31:0]  m_axi_awaddr,
    output reg  [7:0]   m_axi_awlen,
    output      [2:0]   m_axi_awsize,
    output      [1:0]   m_axi_awburst,
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
    output      [2:0]   m_axi_arsize,
    output      [1:0]   m_axi_arburst,
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

    assign m_axi_arsize  = 3'b010; // 4 bytes per beat
    assign m_axi_arburst = 2'b01;  // INCR burst type
    assign m_axi_awsize  = 3'b010; 
    assign m_axi_awburst = 2'b01;

    reg [2:0] state;
    reg [7:0] burst_cnt;
    // data_fifo per-canal (4 canale x 8 cuvinte), nu un singur buffer global.
    // Un buffer global partajat intre canale corupe datele cand doua canale
    // sunt intercalate de arbitru (ex: Round-Robin) - vezi active_ch_id mai jos.
    reg [31:0] data_fifo [0:3][0:7];

    // Retine carui canal ii apartine tranzactia curenta
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

    // 5. Read Data Channel (R)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_rready <= 1'b0;
        else if (state == STATE_READ_DATA && ~(m_axi_rvalid && m_axi_rready && m_axi_rlast))
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

    integer c, w;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            for (c = 0; c < 4; c = c + 1)
                for (w = 0; w < 8; w = w + 1)
                    data_fifo[c][w] <= 32'h0;
        end else if (state == STATE_READ_DATA && m_axi_rvalid) begin
            data_fifo[active_ch_id][burst_cnt[2:0]] <= m_axi_rdata;
        end
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

    // 7. Write Data Channel (W)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            m_axi_wvalid <= 1'b0;
        else if (state == STATE_WRITE_DATA && ~(m_axi_wvalid && m_axi_wready && m_axi_wlast))
            m_axi_wvalid <= 1'b1;
        else
            m_axi_wvalid <= 1'b0;
    end

    // FIX: m_axi_wdata trebuie sa fie COMBINATIONAL, la fel ca m_axi_wlast
    // (vezi "CORECTIE" mai jos), nu inregistrat. In varianta originala,
    // m_axi_wdata era un registru care selecta data_fifo[burst_cnt] folosind
    // valoarea PRE-CLOCK-EDGE a lui burst_cnt, in acelasi ciclu in care
    // burst_cnt se incrementa tot pe baza valorii pre-edge. Efectul: primul
    // cuvant era duplicat, iar ultimul cuvant din fiecare burst de scriere
    // se pierdea (shift de o pozitie) - exact tiparul observat: 0x2000 si
    // 0x2004 aveau aceeasi valoare, iar 0x201C avea valoarea care ar fi
    // trebuit sa fie la 0x2018.
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
        else if (state == STATE_WRITE_RESP && ~(m_axi_bvalid && m_axi_bready))
            m_axi_bready <= 1'b1;
        else
            m_axi_bready <= 1'b0;
    end

endmodule