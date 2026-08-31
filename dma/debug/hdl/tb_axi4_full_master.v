`timescale 1ns / 1ps

module tb_axi4_full_master;

    // --- Semnale de Ceas și Reset ---
    reg clk;
    reg rst_n;

    // --- Interfața de Cereri (de la Priority Arbiter) ---
    reg          master_req_valid;
    reg  [31:0]  master_req_addr;
    reg  [7:0]   master_req_len;
    reg          master_req_is_write;
    wire         master_req_ready;

    // --- Interfața AXI4-Full (Master spre System) ---
    wire [31:0]  m_axi_awaddr;
    wire [7:0]   m_axi_awlen;
    wire [2:0]   m_axi_awsize;
    wire [1:0]   m_axi_awburst;
    wire         m_axi_awvalid;
    reg          m_axi_awready;

    wire [31:0]  m_axi_wdata;
    wire [3:0]   m_axi_wstrb;
    wire         m_axi_wlast;
    wire         m_axi_wvalid;
    reg          m_axi_wready;

    reg  [1:0]   m_axi_bresp;
    reg          m_axi_bvalid;
    wire         m_axi_bready;

    wire [31:0]  m_axi_araddr;
    wire [7:0]   m_axi_arlen;
    wire [2:0]   m_axi_arsize;
    wire [1:0]   m_axi_arburst;
    wire         m_axi_arvalid;
    reg          m_axi_arready;

    reg  [31:0]  m_axi_rdata;
    reg  [1:0]   m_axi_rresp;
    reg          m_axi_rlast;
    reg          m_axi_rvalid;
    reg [1:0] master_req_ch_id;
    
    wire         m_axi_rready;

    // --- Interfața Scatter-Gather (spre Canale) ---
    wire [31:0]  fetch_data_out;
    wire         fetch_data_valid;

    // --- Instanțierea DUT (Device Under Test) ---
    axi4_full_master dut (
        .clk(clk),
        .rst_n(rst_n),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .master_req_valid(master_req_valid), .master_req_addr(master_req_addr), .master_req_len(master_req_len), .master_req_is_write(master_req_is_write), .master_req_ready(master_req_ready),
        .fetch_data_out(fetch_data_out), .fetch_data_valid(fetch_data_valid), .master_req_ch_id(master_req_ch_id)
    );

    // --- Generare Ceas (100 MHz) ---
    always #5 clk = ~clk;

    
    // TASK 1: Lansare Cerere de la Arbitru
    
    task issue_master_req;
        input [31:0] addr;
        input [7:0]  len;
        input        is_write;
        begin
            // Așteptăm ca FSM-ul să fie în IDLE (ready = 1)
            while (master_req_ready == 1'b0) @(posedge clk);
            
            @(posedge clk); #1;
            master_req_ch_id = 2'd0;
            master_req_valid = 1'b1;
            master_req_addr = addr;
            master_req_len = len;
            master_req_is_write = is_write;
            
            // FSM-ul prinde comanda pe următorul front și cade 'ready'
            @(posedge clk); #1;
            master_req_valid = 1'b0;
        end
    endtask

    
    // TASK 2: Simulare Memorie pentru CITIRE (Read)
    
    task mock_axi_slave_read;
        input [7:0] len;
        integer i;
        begin
            // 1. Faza de Adresă (AR)
            wait(m_axi_arvalid == 1'b1);
            @(posedge clk); #1;
            m_axi_arready = 1'b1;
            @(posedge clk); #1;
            m_axi_arready = 1'b0;

            // 2. Faza de Date (R)
            for (i = 0; i <= len; i = i + 1) begin
                m_axi_rvalid = 1'b1;
                m_axi_rdata  = 32'hAA000000 + i; // Date generate sintetic (AA000000, AA000001...)
                m_axi_rlast  = (i == len) ? 1'b1 : 1'b0;
                m_axi_rresp  = 2'b00; // OKAY
                
                // Handshake AXI
                @(posedge clk);
                while (m_axi_rready == 1'b0) @(posedge clk);
                #1; 
            end
            m_axi_rvalid = 1'b0;
            m_axi_rlast  = 1'b0;
        end
    endtask

    
    // TASK 3: Simulare Memorie pentru SCRIERE (Write)
    
    task mock_axi_slave_write;
        input [7:0] len;
        integer i;
        begin
            // 1. Faza de Adresă (AW)
            wait(m_axi_awvalid == 1'b1);
            @(posedge clk); #1;
            m_axi_awready = 1'b1;
            @(posedge clk); #1;
            m_axi_awready = 1'b0;

            // 2. Faza de Date (W)
            for (i = 0; i <= len; i = i + 1) begin
                m_axi_wready = 1'b1;
                
                // Handshake AXI
                @(posedge clk);
                while (m_axi_wvalid == 1'b0) @(posedge clk);
                #1;
                $display("[TIME %0t] Memoria Slave a scris data: %h, wlast: %b", $time, m_axi_wdata, m_axi_wlast);
            end
            m_axi_wready = 1'b0;

            // 3. Faza de Răspuns (B)
            @(posedge clk); #1;
            m_axi_bvalid = 1'b1;
            m_axi_bresp  = 2'b00;
            
            @(posedge clk);
            while (m_axi_bready == 1'b0) @(posedge clk);
            #1;
            m_axi_bvalid = 1'b0;
        end
    endtask

    
    // SECVENȚA DE TESTARE PRINCIPALĂ
    
    initial begin
        // 1. Inițializare sigură a semnalelor pentru a preveni stările 'X'
        clk = 0; rst_n = 0;
        master_req_ch_id = 2'd0;
        master_req_valid = 0; master_req_addr = 0; master_req_len = 0; master_req_is_write = 0;
        m_axi_awready = 0; m_axi_wready = 0; m_axi_bvalid = 0; m_axi_bresp = 0;
        m_axi_arready = 0; m_axi_rvalid = 0; m_axi_rdata = 0; m_axi_rlast = 0; m_axi_rresp = 0;

        #20;
        rst_n = 1; // Ieșire din Reset
        #30;

        
        // TEST 1: Burst de CITIRE (Simulare Fetch Descriptor)
        
        $display("\n--- INCEPERE TEST 1: AXI READ BURST (Len = 3) ---");
        // Folosim fork...join pentru ca lansarea comenzii și răspunsul 
        // slave-ului să se execute concurent, exact ca într-un sistem real.
        fork
            issue_master_req(32'h1000, 8'd3, 1'b0); // Master primește cerere de citire (4 cuvinte)
            mock_axi_slave_read(8'd3);              // Slave-ul monitorizează magistrala și răspunde
        join
        
        #50;

        
        // TEST 2: Burst de SCRIERE (Simulare Writeback Date)
        
        $display("\n--- INCEPERE TEST 2: AXI WRITE BURST (Len = 3) ---");
        // Modulul tău ar trebui acum să scoată din data_fifo datele citite anterior!
        fork
            issue_master_req(32'h2000, 8'd3, 1'b1); // Master primește cerere de scriere
            mock_axi_slave_write(8'd3);             // Slave-ul așteaptă datele și confirmă
        join

        #100;
        $display("\n--- TOATE TESTELE AU TRECUT CU SUCCES ---");
        $finish;
    end

    // Timeout de siguranță (prevenție block infinit)
    initial begin
        #3000;
        $display("\n[EROARE] Timeout atins! Un handshake AXI a eșuat.");
        $finish;
    end

endmodule