`timescale 1ns / 1ps

module tb_axi4_lite_slave_advanced;

    // --- Semnale de Ceas și Reset ---
    reg clk;
    reg rst_n;

    // --- Interfața AXI4-Lite ---
    reg  [31:0] s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    reg  [31:0] s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // --- Semnale Hardware către/dinspre DMA ---
    wire [31:0] ch0_desc_addr, ch0_control, ch0_bw_cap;
    reg  [31:0] ch0_status_in;
    wire [31:0] ch1_desc_addr, ch1_control, ch1_bw_cap;
    reg  [31:0] ch1_status_in;
    wire [31:0] int_enable;

    // Variabilă internă pentru citiri
    reg [31:0] read_data_capture;

    // --- Instanțierea Modulului DUT ---
    axi4_lite_slave dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),

        .ch0_desc_addr(ch0_desc_addr),
        .ch0_control(ch0_control),
        .ch0_bw_cap(ch0_bw_cap),
        .ch0_status_in(ch0_status_in),
        
        .ch1_desc_addr(ch1_desc_addr),
        .ch1_control(ch1_control),
        .ch1_bw_cap(ch1_bw_cap),
        .ch1_status_in(ch1_status_in),
        
        .int_enable(int_enable)
        // Am mapat doar 2 canale pentru concizie, poți adăuga restul
    );

    // --- Generare Ceas (100 MHz) ---
    always #5 clk = ~clk;

    // ==========================================
    // TASK: Scriere AXI4-Lite (CORECTAT)
    // ==========================================
    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            #1; // Delay pentru a evita race conditions
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1;
            s_axi_wdata   = data;
            s_axi_wstrb   = 4'hF;
            s_axi_wvalid  = 1;
            s_axi_bready  = 1;

            // Așteaptă acceptarea adresei și a datelor
            wait(s_axi_awready && s_axi_wready);
            @(posedge clk);
            #1; // Lăsăm RTL-ul să citească semnalele de '1' înainte să le tăiem!
            s_axi_awvalid = 0;
            s_axi_wvalid  = 0;

            // Așteaptă răspunsul de la slave
            wait(s_axi_bvalid);
            @(posedge clk);
            #1;
            s_axi_bready  = 0;
            
            if (s_axi_bresp == 2'b00)
                $display("[TIME %0t] SUCCES: Am scris %h la adresa %h", $time, data, addr);
            else
                $display("[TIME %0t] EROARE: Scriere eșuată la adresa %h (RESP: %b)", $time, addr, s_axi_bresp);
        end
    endtask

    // ==========================================
    // TASK: Citire AXI4-Lite (CORECTAT)
    // ==========================================
    task axi_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            #1;
            s_axi_araddr  = addr;
            s_axi_arvalid = 1;
            s_axi_rready  = 1;

            // Așteaptă acceptarea adresei
            wait(s_axi_arready);
            @(posedge clk);
            #1;
            s_axi_arvalid = 0;

            // Așteaptă datele valide
            wait(s_axi_rvalid);
            data = s_axi_rdata;
            @(posedge clk);
            #1;
            s_axi_rready  = 0;
            
            if (s_axi_rresp == 2'b00)
                $display("[TIME %0t] SUCCES: Am citit %h de la adresa %h", $time, data, addr);
            else
                $display("[TIME %0t] EROARE: Citire eșuată la adresa %h (RESP: %b)", $time, addr, s_axi_rresp);
        end
    endtask
    // ==========================================
    // SECVENȚA DE TESTARE
    // ==========================================
    initial begin
        // 1. Inițializare semnale
        clk = 0;
        rst_n = 0;
        s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_araddr = 0; s_axi_arvalid = 0; s_axi_rready = 0;
        ch0_status_in = 32'h0; ch1_status_in = 32'h0;
        read_data_capture = 0;

        // 2. Ieșire din Reset
        #20;
        rst_n = 1;
        #20;
        $display("--- INCEPERE SIMULARE ---");

        // --- TEST 1: Configurare Simplă (Scriere și Citire Descriptor Canal 0) ---
        $display("\n[TEST 1] Scriere si verificare ch0_desc_addr (Adresa 0x00)");
        axi_write(32'h0000_0000, 32'hDEADBEEF);
        axi_read(32'h0000_0000, read_data_capture);
        if (read_data_capture !== 32'hDEADBEEF) $error("Test 1 a esuat!");

        // --- TEST 2: Comportament canal independent (Canal 1) ---
        $display("\n[TEST 2] Configurare independenta ch1_control (Adresa presupusa 0x14)");
        // *Presupunem* că ch1_control e la 0x14 în harta ta de memorie. 
        // Ajustează adresa dacă harta diferă.
        axi_write(32'h0000_0014, 32'h00000001); // Setăm bitul de ENABLE
        axi_read(32'h0000_0014, read_data_capture);

        // --- TEST 3: Verificare Registre Read-Only ---
        $display("\n[TEST 3] Verificare comportament Read-Only pentru ch0_status_in");
        ch0_status_in = 32'hCAFEBABE; // Hardware-ul raportează acest status
        // Încercăm să scriem din software peste el (la adresa de status, presupusă 0x08)
        axi_write(32'h0000_0008, 32'h00000000); 
        axi_read(32'h0000_0008, read_data_capture);
        if (read_data_capture === 32'hCAFEBABE) 
            $display("-> Corect: Valoarea a ramas CAFEBABE, scrierea software a fost ignorata.");
        else 
            $error("Test 3 a esuat: S-a rescris un registru Read-Only!");

        // --- TEST 4: Mecanismul Write-1-to-Clear (W1C) pentru Întreruperi ---
        // Presupunând că registrul INT_STATUS este la 0x40
        $display("\n[TEST 4] Testare mecanism W1C pe INT_STATUS (Adresa 0x40)");
        // 1. Citește starea curentă (ar trebui să aibă setat bitul de la simularea ta hardware)
        axi_read(32'h0000_0040, read_data_capture);
        // 2. Scrie '1' doar pe bitul 2 pentru a-l curăța (ex. valoarea 0x04)
        axi_write(32'h0000_0040, 32'h0000_0004);
        // 3. Verifică dacă a fost curățat
        axi_read(32'h0000_0040, read_data_capture);
        
        // --- TEST 5: Acces la o adresă invalidă (Opțional, depinde de implementarea ta) ---
        $display("\n[TEST 5] Testare adresa nemapata (0xFFFFFFFF)");
        axi_write(32'hFFFF_FFFF, 32'h12345678);
        // Aici ar trebui ca s_axi_bresp să fie 2'b10 (SLVERR) dacă slave-ul e complet strict AXI.

        #50;
        $display("\n--- FINALIZARE SIMULARE ---");
        $finish;
    end

endmodule