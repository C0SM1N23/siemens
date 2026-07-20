`timescale 1ns / 1ps

module tb_dma_channel;

    // --- Semnale de Ceas și Reset ---
    reg clk;
    reg rst_n;

    // --- Intrări de Configurare (dinspre AXI-Lite Slave) ---
    reg  [31:0] desc_addr_in;
    reg  [31:0] control_in;
    reg  [31:0] bw_cap_in;
    
    // --- Ieșiri de Status și Întreruperi ---
    wire [31:0] status_out;
    wire        irq_out;

    // --- Interfața cu Priority Arbiter ---
    wire        req_valid;
    wire [31:0] req_addr;
    wire [7:0]  req_len;
    wire        req_is_write;
    reg         arb_gnt;

    // --- Interfața de Feedback de la Master ---
    reg         burst_done;
    reg         axi_error;
    reg  [31:0] fetch_data_in;
    reg         fetch_data_valid;

    // --- Instanțierea DUT (Device Under Test) ---
    dma_channel dut (
        .clk(clk),
        .rst_n(rst_n),
        .desc_addr_in(desc_addr_in),
        .control_in(control_in),
        .bw_cap_in(bw_cap_in),
        .status_out(status_out),
        .irq_out(irq_out),
        .req_valid(req_valid),
        .req_addr(req_addr),
        .req_len(req_len),
        .req_is_write(req_is_write),
        .arb_gnt(arb_gnt),
        .burst_done(burst_done),
        .axi_error(axi_error),
        .fetch_data_in(fetch_data_in),
        .fetch_data_valid(fetch_data_valid)
    );

    // --- Generare Ceas (100 MHz) ---
    always #5 clk = ~clk;

    // ==========================================
    // TASK: Simularea aducerii Descriptorului (Fetch Phase)
    // ==========================================
    task simulate_descriptor_fetch;
        input [31:0] t_src;
        input [31:0] t_dst;
        input [31:0] t_len;
        input [31:0] t_ctrl;
        begin
            // 1. Așteptăm ca modulul să ceară magistrala pentru Fetch
            wait(req_valid == 1'b1);
            @(posedge clk); #1;
            
            $display("[TIME %0t] Arbiter acorda magistrala pentru FETCH la adresa %h", $time, req_addr);
            arb_gnt = 1'b1;
            @(posedge clk); #1;
            arb_gnt = 1'b0; // Retragem grant-ul

            // 2. Livrăm cele 4 cuvinte ale descriptorului
            // Cuvantul 0: SRC
            fetch_data_in = t_src; fetch_data_valid = 1'b1; @(posedge clk); #1;
            // Cuvantul 1: DST
            fetch_data_in = t_dst; fetch_data_valid = 1'b1; @(posedge clk); #1;
            // Cuvantul 2: LEN
            fetch_data_in = t_len; fetch_data_valid = 1'b1; @(posedge clk); #1;
            // Cuvantul 3: CTRL
            fetch_data_in = t_ctrl; fetch_data_valid = 1'b1; @(posedge clk); #1;
            
            fetch_data_valid = 1'b0;
            
            // 3. Semnalizăm finalizarea burst-ului de fetch
            burst_done = 1'b1;
            @(posedge clk); #1;
            burst_done = 1'b0;
            $display("[TIME %0t] Fetch complet. SRC=%h, DST=%h, LEN=%0d, CTRL=%h", $time, t_src, t_dst, t_len, t_ctrl);
        end
    endtask

    // ==========================================
    // TASK: Simularea unui Burst de Date (Active Phase)
    // ==========================================
    task simulate_data_burst;
        begin
            // Așteptăm ca modulul să aibă destule token-uri și să ridice request-ul
            wait(req_valid == 1'b1);
            @(posedge clk); #1;
            
            $display("[TIME %0t] Arbiter acorda magistrala pentru %s la adresa %h", 
                     $time, (req_is_write ? "SCRIERE" : "CITIRE"), req_addr);
            
            arb_gnt = 1'b1;
            @(posedge clk); #1;
            arb_gnt = 1'b0;

            // Simulăm timpul de transfer pe AXI (ex: 8 cicluri de ceas pentru un burst)
            repeat(8) @(posedge clk);
            #1;

            // Semnalizăm Master-ului că burst-ul s-a terminat
            burst_done = 1'b1;
            @(posedge clk); #1;
            burst_done = 1'b0;
        end
    endtask

    // ==========================================
    // SECVENȚA DE TESTARE
    // ==========================================
    initial begin
        // 1. Inițializare Semnale
        clk = 0;
        rst_n = 0;
        desc_addr_in = 0; control_in = 0; bw_cap_in = 0;
        arb_gnt = 0; burst_done = 0; axi_error = 0;
        fetch_data_in = 0; fetch_data_valid = 0;

        // 2. Ieșire din Reset
        #20;
        rst_n = 1;
        #20;
        $display("--- INCEPERE SIMULARE CANAL DMA ---");

        // --- TEST 1: Transfer Complet (1 Singur Burst de 32 bytes) ---
        $display("\n[TEST 1] Initiere transfer de 32 octeti (8 cuvinte)");
        // Configurăm Token Bucket: Refill Rate = 10, Max Tokens = 100
        bw_cap_in = {16'd100, 16'd10}; 
        desc_addr_in = 32'h0000_1000; // Adresa de unde aducem descriptorul
        
        // Activăm canalul (bitul 0 din control_in este ENABLE)
        control_in = 32'h0000_0001;
        
        // Pas 1: Așteptăm FETCH-ul Descriptorului
        // Simulăm descriptorul: SRC=0xAAAA_0000, DST=0xBBBB_0000, LEN=32 bytes, CTRL=1 (EOF)
        simulate_descriptor_fetch(32'hAAAA_0000, 32'hBBBB_0000, 32'd32, 32'h0000_0001);

        // Pas 2: Simulăm Faza de Citire (Sursă -> FIFO intern ipotetic)
        simulate_data_burst();
        
        // Pas 3: Simulăm Faza de Scriere (FIFO intern ipotetic -> Destinație)
        simulate_data_burst();

        // Pas 4: Așteptăm ca FSM-ul să ajungă în starea DONE și să ridice IRQ
        wait(status_out[2:0] == 3'd4); // STATE_DONE = 3'd4
        $display("[TIME %0t] Canalul a ajuns in starea DONE. IRQ_OUT = %b", $time, irq_out);
        
        if (irq_out == 1'b1)
            $display("-> TEST 1 PASSED: Intreruperea a fost generata corect.");
        else
            $display("-> TEST 1 FAILED: Intreruperea lipseste.");

        // Dezactivăm canalul pentru a șterge starea (Clear state)
        @(posedge clk); #1;
        control_in = 32'h0000_0000;
        wait(status_out[2:0] == 3'd0); // Așteptăm să revină în IDLE
        $display("[TIME %0t] Canalul a revenit in IDLE.", $time);

        #100;
        $display("\n--- FINALIZARE SIMULARE ---");
        $finish;
    end

    // Timeout de siguranță (pentru a evita blocarea în wait-uri)
    initial begin
        #5000;
        $display("\n[EROARE TIMEOUT] Simularea a durat prea mult. Poate o conditie de WAIT a esuat.");
        $finish;
    end

endmodule