`timescale 1ns / 1ps

module tb_priority_arbiter;

    // --- Semnale de Ceas și Reset ---
    reg clk;
    reg rst_n;

    // --- Intrări Arbiter ---
    reg  [31:0] sched_policy;
    reg  [3:0]  ch_req;
    
    reg  [31:0] ch0_req_addr; reg [7:0] ch0_req_len; reg ch0_req_is_write;
    reg  [31:0] ch1_req_addr; reg [7:0] ch1_req_len; reg ch1_req_is_write;
    reg  [31:0] ch2_req_addr; reg [7:0] ch2_req_len; reg ch2_req_is_write;
    reg  [31:0] ch3_req_addr; reg [7:0] ch3_req_len; reg ch3_req_is_write;
    
    reg         master_req_ready;

    // --- Ieșiri Arbiter ---
    wire [3:0]  ch_gnt;
    wire        master_req_valid;
    wire [31:0] master_req_addr;
    wire [7:0]  master_req_len;
    wire        master_req_is_write;
    wire [1:0]  master_req_ch_id;

    // --- Instanțierea DUT (Device Under Test) ---
    priority_arbiter dut (
        .clk(clk),
        .rst_n(rst_n),
        .sched_policy(sched_policy),
        .ch_req(ch_req),
        .ch0_req_addr(ch0_req_addr), .ch0_req_len(ch0_req_len), .ch0_req_is_write(ch0_req_is_write),
        .ch1_req_addr(ch1_req_addr), .ch1_req_len(ch1_req_len), .ch1_req_is_write(ch1_req_is_write),
        .ch2_req_addr(ch2_req_addr), .ch2_req_len(ch2_req_len), .ch2_req_is_write(ch2_req_is_write),
        .ch3_req_addr(ch3_req_addr), .ch3_req_len(ch3_req_len), .ch3_req_is_write(ch3_req_is_write),
        .ch_gnt(ch_gnt),
        .master_req_valid(master_req_valid),
        .master_req_addr(master_req_addr),
        .master_req_len(master_req_len),
        .master_req_is_write(master_req_is_write),
        .master_req_ready(master_req_ready),
        .master_req_ch_id(master_req_ch_id)
    );

    // --- Generare Ceas (100 MHz) ---
    always #5 clk = ~clk;

    // ==========================================
    // TASK 1: Setare Cerere Canal
    // ==========================================
    task set_request;
        input [1:0]  ch_idx;
        input [31:0] addr;
        input [7:0]  len;
        input        is_write;
        begin
            @(posedge clk); #1;
            ch_req[ch_idx] = 1'b1;
            case(ch_idx)
                2'd0: begin ch0_req_addr = addr; ch0_req_len = len; ch0_req_is_write = is_write; end
                2'd1: begin ch1_req_addr = addr; ch1_req_len = len; ch1_req_is_write = is_write; end
                2'd2: begin ch2_req_addr = addr; ch2_req_len = len; ch2_req_is_write = is_write; end
                2'd3: begin ch3_req_addr = addr; ch3_req_len = len; ch3_req_is_write = is_write; end
            endcase
            $display("[TIME %0t] Canalul %0d a generat o cerere.", $time, ch_idx);
        end
    endtask

    // ==========================================
    // TASK 2: Stergere Cerere Canal
    // ==========================================
    task clear_request;
        input [1:0] ch_idx;
        begin
            @(posedge clk); #1;
            ch_req[ch_idx] = 1'b0;
        end
    endtask

    // ==========================================
    // TASK 3: Master Accepta & Verifica Castigatorul
    // ==========================================
    task accept_and_verify;
        input [3:0] expected_gnt;
        reg   [3:0] actual_gnt;
        begin
            // 1. Așteptăm ca arbitrul să trimită o cerere validă către Master
            wait(master_req_valid == 1'b1);
            @(posedge clk); #1;
            
            // 2. Master-ul acceptă cererea
            master_req_ready = 1'b1;
            @(posedge clk); #1;
            
            // 3. Captăm grant-ul și oprim acceptul
            actual_gnt = ch_gnt;
            master_req_ready = 1'b0;
            
            // 4. Verificare rezultat
            if (actual_gnt === expected_gnt)
                $display("[TIME %0t] SUCCES: Arbitrul a selectat corect castigatorul: %b", $time, actual_gnt);
            else
                $display("[TIME %0t] EROARE: Castigator asteptat %b, dar am primit %b", $time, expected_gnt, actual_gnt);
        end
    endtask

    // ==========================================
    // SECVENȚA DE TESTARE
    // ==========================================
    initial begin
        // Inițializare semnale
        clk = 0; rst_n = 0; sched_policy = 0;
        ch_req = 4'b0000; master_req_ready = 0;
        ch0_req_addr = 0; ch0_req_len = 0; ch0_req_is_write = 0;
        ch1_req_addr = 0; ch1_req_len = 0; ch1_req_is_write = 0;
        ch2_req_addr = 0; ch2_req_len = 0; ch2_req_is_write = 0;
        ch3_req_addr = 0; ch3_req_len = 0; ch3_req_is_write = 0;

        #20;
        rst_n = 1; // Ieșire din Reset
        #20;
        
        // ---------------------------------------------------------
        // TEST 1: Modul FIXED PRIORITY (Canalul 0 = Boss)
        // ---------------------------------------------------------
        $display("\n--- INCEPERE TEST 1: FIXED PRIORITY ---");
        sched_policy = 32'd0; // Setează Fixed Priority
        
        // Ridicăm cereri SIMULTANE pe canalele 0, 1 și 2
        set_request(0, 32'hAAAA0000, 8'h07, 1'b0);
        set_request(1, 32'hBBBB0000, 8'h0F, 1'b1);
        set_request(2, 32'hCCCC0000, 8'h03, 1'b0);
        
        // Prima acceptare ar trebui să meargă la CH 0 (prioritate maximă)
        accept_and_verify(4'b0001);
        clear_request(0); // CH 0 și-a terminat treaba
        
        // A doua acceptare ar trebui să meargă la CH 1
        accept_and_verify(4'b0010);
        clear_request(1); // CH 1 și-a terminat treaba
        
        // A treia acceptare ar trebui să meargă la CH 2
        accept_and_verify(4'b0100);
        clear_request(2);
        
        #50;

        // --- SECVENȚĂ DE RESET ÎNTRE TESTE ---
        $display("\n--- RESETARE MODUL PENTRU TESTUL 2 ---");
        rst_n = 0;
        #20;
        rst_n = 1;
        #20;
        
        // ---------------------------------------------------------
        // TEST 2: Modul ROUND ROBIN (Rotația Echitabilă)
        // ---------------------------------------------------------
        $display("\n--- INCEPERE TEST 2: ROUND ROBIN ---");
        sched_policy = 32'd1; // Setează Round Robin
        
        // Toate cele 4 canale cer magistrala SIMULTAN și NU se dau bătute
        set_request(0, 32'h00000000, 8'h01, 1'b0);
        set_request(1, 32'h11111111, 8'h01, 1'b0);
        set_request(2, 32'h22222222, 8'h01, 1'b0);
        set_request(3, 32'h33333333, 8'h01, 1'b0);
        
        // Ordinea CORECTĂ aposta reset: Canalul 0 a fost "ultimul", deci incepem cu 1
        accept_and_verify(4'b0010); // Așteptăm CH 1
        accept_and_verify(4'b0100); // Așteptăm CH 2
        accept_and_verify(4'b1000); // Așteptăm CH 3
        accept_and_verify(4'b0001); // Așteptăm CH 0
        
        // După ce toate au avut rândul, o ia de la capăt
        accept_and_verify(4'b0010); // CH 1 din nou
        
        // Curățăm tot
        clear_request(0); clear_request(1); clear_request(2); clear_request(3);

        #50;
        $display("\n--- TOATE TESTELE AU TRECUT CU SUCCES ---");
        $finish;
    end

    // Timeout de siguranță
    initial begin
        #2000;
        $display("\n[EROARE] Timeout atins!");
        $finish;
    end

endmodule