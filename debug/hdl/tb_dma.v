`timescale 1ns / 1ps
module tb_dma;
    localparam ADDR_CH0_DESC_ADDR   = 8'h00;
    localparam ADDR_CH0_CONTROL     = 8'h04;
    localparam ADDR_CH0_BW_CAP      = 8'h08;
    localparam ADDR_CH0_STATUS      = 8'h0C;
    localparam ADDR_CH1_DESC_ADDR   = 8'h10;
    localparam ADDR_CH1_CONTROL     = 8'h14;
    localparam ADDR_CH1_BW_CAP      = 8'h18;
    localparam ADDR_CH1_STATUS      = 8'h1C;
    localparam ADDR_CH2_DESC_ADDR   = 8'h20;
    localparam ADDR_CH2_CONTROL     = 8'h24;
    localparam ADDR_CH2_BW_CAP      = 8'h28;
    localparam ADDR_CH2_STATUS      = 8'h2C;
    localparam ADDR_CH3_DESC_ADDR   = 8'h30;
    localparam ADDR_CH3_CONTROL     = 8'h34;
    localparam ADDR_CH3_BW_CAP      = 8'h38;
    localparam ADDR_CH3_STATUS      = 8'h3C;
    localparam ADDR_INT_STATUS      = 8'h40;
    localparam ADDR_INT_ENABLE      = 8'h44;
    localparam ADDR_SCHED_POLICY    = 8'h48;

    localparam [31:0] v0 = 32'hA1A1A1A1;
    localparam [31:0] v1 = 32'hB2B2B2B2;
    localparam [31:0] v2 = 32'hC3C3C3C3;
    localparam [31:0] v3 = 32'hD4D4D4D4;
    localparam [31:0] v4 = 32'hE5E5E5E5;
    localparam [31:0] v5 = 32'hDEADBEEF;
    localparam [31:0] v6 = 32'h07070707;
    localparam [31:0] v7 = 32'h08080808;

    reg         clk;
    reg         rst_n;

    //=======Interfata AXI4-Lite=========
    //Citire
    reg  [31:0] s_axi_araddr;
    reg         s_axi_arvalid;
    reg         s_axi_rready;
    
    wire [31:0] s_axi_rdata;
    wire        s_axi_rvalid;
    wire        s_axi_arready;
    wire        s_axi_rresp;

    //Scriere
    reg  [31:0] s_axi_awaddr;//AW
    reg         s_axi_awvalid;
    reg  [31:0] s_axi_wdata;//W
    reg  [ 3:0] s_axi_wstrb;
    reg         s_axi_wvalid;
    reg         s_axi_bready;//B

    wire        s_axi_awready;
    wire        s_axi_wready;
    wire        s_axi_bvalid;
    wire [ 1:0] s_axi_bresp;
    //===================================

    //=======Interfata AXI4-Full=========
    wire [31:0] m_axi_araddr;
    wire [ 7:0] m_axi_arlen;   
    wire        m_axi_arvalid; 
    reg         m_axi_arready; 

    reg  [31:0] m_axi_rdata;
    reg  [ 1:0] m_axi_rresp;   // Raspuns (0 = OK)
    reg         m_axi_rlast;   // Ult cuv din burst
    reg         m_axi_rvalid;  // TB trimite data valida
    wire        m_axi_rready;  // DMA confirma ca a primit data

    wire [31:0] m_axi_awaddr;
    wire [ 7:0] m_axi_awlen;
    wire        m_axi_awvalid;
    reg         m_axi_awready;

    wire [31:0] m_axi_wdata;
    wire [ 3:0] m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    reg         m_axi_wready;

    reg  [ 1:0] m_axi_bresp;
    reg         m_axi_bvalid;
    wire        m_axi_bready;
    //===================================

    // Memorie simulata (SRAM) - 16 KB
    // AXI e byte-adressable, dar memoria e word-adressable, de ex
    // Adresa AXI 8 -> 8/4=2 -> ram_memory[2]
    reg [31:0] ram_memory [0:4095];

    //====Variabile citire din fisier====
    reg  [31:0] read_val;
    integer     fd;             // File descriptor
    integer     scan_result;    // Verifica daca s-a citit corect linia
    reg [8*8-1:0] cmd;      // String pentru comanda ("W", "R", "D") - max 8 caractere
    reg [31:0]  addr_arg;    // Argumentul 1 din fisier (Adresa sau Timp)
    reg [31:0]  data_arg;    // Argumentul 2 din fisier (Date)
    //===================================

    //====Variabile pentru citirea din RAM====
    reg [31:0] current_read_addr;
    reg [7:0]  burst_len;
    integer    beat;
    //========================================

    //====Variabile pentru scrierea in RAM====
    reg [31:0] current_write_addr;
    reg [7:0]  write_burst_len;
    integer    w_beat;
    integer    i;
    //=======================================

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    mc_dma_top dut_dma (
        .clk(clk),
        .rst_n(rst_n),

        //AXI4-Lite Citire
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_rready(s_axi_rready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rresp(s_axi_rresp),

        //AXI4-Lite Scriere 
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_awready(s_axi_awready),
        .s_axi_wready(s_axi_wready),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bresp(s_axi_bresp),

        //AXI4-Full Citire
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),

        //AXI4-Full Scriere
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    //======TASK-uri pentru citire si scriere AXI4-Lite========
    task axi_lite_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;

            fork
                begin
                    @(posedge clk);
                    while (s_axi_awready !== 1'b1)
                        @(posedge clk);
                    s_axi_awvalid <= 1'b0;
                end
                begin
                    @(posedge clk);
                    while (s_axi_wready !== 1'b1)
                        @(posedge clk);
                    s_axi_wvalid <= 1'b0;
                end
            join

            s_axi_bready <= 1'b1;
            
            @(posedge clk);
            while (s_axi_bvalid !== 1'b1)
                @(posedge clk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task axi_lite_read;
        input  [31:0] addr;
        output [31:0] data_out; 
        begin
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            
            @(posedge clk);
            while (s_axi_arready !== 1'b1)
                @(posedge clk);
            s_axi_arvalid <= 1'b0;

            s_axi_rready <= 1'b1;
            
            @(posedge clk);
            while (s_axi_rvalid !== 1'b1)
                @(posedge clk);
            
            data_out = s_axi_rdata; 
            s_axi_rready <= 1'b0;
        end
    endtask
    //======================================

    //===Task pentru scrierea directa in RAM (backdoor)===
    task backdoor_ram_write;
        input [31:0] byte_addr;
        input [31:0] data;
        begin
            ram_memory[byte_addr >> 2] = data;
        end
    endtask
    //======================================

    //=== TASK DE RESET PARAMETRIZABIL ===
    task apply_reset;
        input integer reset_cycles;
        begin
            $display("[%0t] INFO: Incepere secventa reset pentru %0d cicluri...", $time, reset_cycles);
            rst_n = 1'b0;
            repeat (reset_cycles) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);
            $display("[%0t] INFO: Reset Complet.", $time);
        end
    endtask
    //====================================

    //=== TASK PENTRU INITIALIZARE RAM ===
    task init_ram;
        input [31:0] v0;
        input [31:0] v1;
        input [31:0] v2;
        input [31:0] v3;
        input [31:0] v4;
        input [31:0] v5;
        input [31:0] v6;
        input [31:0] v7;
        integer k;

        begin
            for (i = 0; i < 4096; i = i + 1) begin
                ram_memory[i] = 32'h00000000;
            end
            $display("INFO: Memoria RAM a fost initializata cu 0.");

            // Datele sursa de la 0x1000
            backdoor_ram_write(32'h00001000, v0);
            backdoor_ram_write(32'h00001004, v1);
            backdoor_ram_write(32'h00001008, v2);
            backdoor_ram_write(32'h0000100C, v3);
            backdoor_ram_write(32'h00001010, v4);
            backdoor_ram_write(32'h00001014, v5);
            backdoor_ram_write(32'h00001018, v6);
            backdoor_ram_write(32'h0000101C, v7);

            // Descriptorul de la 0x0100 (sursa, destinatie, lungime, control)
            // desc_src
            backdoor_ram_write(32'h00000100, 32'h00001000); 

            // desc_dst 
            backdoor_ram_write(32'h00000104, 32'h00002000); 

            // desc_len 
            backdoor_ram_write(32'h00000108, 32'h00000020); 

            // desc_ctrl 
            backdoor_ram_write(32'h0000010C, 32'h00000001);

            // padding-ul
            backdoor_ram_write(32'h00000110, 32'h00000000); 
            backdoor_ram_write(32'h00000114, 32'h00000000); 
            backdoor_ram_write(32'h00000118, 32'h00000000); 
            backdoor_ram_write(32'h0000011C, 32'h00000000); 

            $display("[%0t] INFO: Datele sursa si Descriptorul au fost incarcate.", $time);
        end
    endtask
    //====================================

    //======Citire din fisier, citire si scriere registrii, etc========
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        s_axi_arvalid <= 1'b0;
        s_axi_rready  <= 1'b0;
        s_axi_araddr  <= 32'h0;

        s_axi_awvalid <= 1'b0;
        s_axi_wvalid  <= 1'b0;
        s_axi_bready  <= 1'b0;
        s_axi_awaddr  <= 32'h0;
        s_axi_wdata   <= 32'h0;
        s_axi_wstrb   <= 4'h0;

        m_axi_arready <= 1'b0;
        m_axi_rvalid  <= 1'b0;
        m_axi_rlast   <= 1'b0;
        m_axi_rresp   <= 2'b00; // 00 == OK
        m_axi_rdata   <= 32'h0;

        m_axi_awready <= 1'b0;
        m_axi_wready  <= 1'b0;
        m_axi_bvalid  <= 1'b0;
        m_axi_bresp   <= 2'b00; // 00 == OK

        fork
            //Thread 1: AXI4-Full Read
            begin
                @(posedge clk);
                while(~rst_n)
                    @(posedge clk);

                forever begin
                    // FAZA 1: Asteptam o cerere de adresa (Handshake pe AR)
                    // Daca valid nu e 1 inca, asteptam fronturi de ceas
                    // inainte era (~m_axi_awvalid), dar asta nu trateaza corect X (starea initiala, 
                    // inainte ca reset-ul sa se propage)
                    @(posedge clk);
                    while (m_axi_arvalid !== 1'b1) begin
                        @(posedge clk);
                    end

                    // Salvam adresa de start si cate cuvinte vrea (burst)
                    current_read_addr = m_axi_araddr;
                    burst_len = m_axi_arlen; 

                    // Confirmam ca am preluat cererea (arready = 1 pt un ciclu)
                    m_axi_arready <= 1'b1;
                    @(posedge clk);
                    m_axi_arready <= 1'b0;

                    // FAZA 2: Trimitem datele inapoi (Handshake pe R)
                    for (beat = 0; beat <= burst_len; beat = beat + 1) begin
                        // Extragem cuvantul din RAM.
                        m_axi_rdata  <= ram_memory[current_read_addr >> 2];
                        m_axi_rvalid <= 1'b1;

                        if (beat == burst_len)
                            m_axi_rlast <= 1'b1;
                        else
                            m_axi_rlast <= 1'b0;

                        // Asteptam DMA-ul sa spuna ca primeste datele
                        // FIX: idem, "!== 1'b1" in loc de "~m_axi_rready"
                        @(posedge clk);
                        while (m_axi_rready !== 1'b1) begin
                            @(posedge clk);
                        end

                        current_read_addr = current_read_addr + 4;
                    end

                    m_axi_rvalid <= 1'b0;
                    m_axi_rlast  <= 1'b0;
                end
            end

            //Thread 2: AXI4-Full Write
            begin
                forever begin
                    // FAZA 1: Handshake AW
                    // Ridicam awready inca de pe acum pt ca suntem gata de o noua tranzactie
                    m_axi_awready <= 1'b1; 

                    @(posedge clk);
                    // Daca valid nu e 1 inca, asteptam fronturi de ceas
                    // inainte era (~m_axi_awvalid), dar asta nu trateaza corect X (starea initiala, 
                    // inainte ca reset-ul sa se propage)
                    while (m_axi_awvalid !== 1'b1) begin
                        @(posedge clk);
                    end

                    // Cand am iesit din while, valid este 1. Salvam adresa.
                    current_write_addr = m_axi_awaddr;
                    write_burst_len = m_axi_awlen;

                     // Asteptam frontul de ceas ca sa se incheie transferul (awvalid & awready sunt 1)
                    m_axi_awready <= 1'b0;

                    // FAZA 2: Primim datele
                    m_axi_wready <= 1'b1; 
                    for (w_beat = 0; w_beat <= write_burst_len; w_beat = w_beat + 1) begin

                         // FIX: idem, "!== 1'b1" in loc de "== 1'b0"
                        @(posedge clk);
                        while (m_axi_wvalid !== 1'b1) begin
                            @(posedge clk);
                        end

                        // Salvam in memorie datele
                        ram_memory[current_write_addr >> 2] = m_axi_wdata;
                        current_write_addr = current_write_addr + 4;
                    end
                    m_axi_wready <= 1'b0;

                    // FAZA 3: Handshake B (Succes)
                    m_axi_bvalid <= 1'b1;
                    // FIX: idem, "!== 1'b1" in loc de "== 1'b0"
                    @(posedge clk);
                    while (m_axi_bready !== 1'b1) begin
                        @(posedge clk);
                    end
                    m_axi_bvalid <= 1'b0;
                end
            end

            //Thread 3: Secventa principala de test
            begin
                init_ram(
                    v0, v1, v2, v3,
                    v4, v5, v6, v7
                );
                
                apply_reset(27); 

                fd = $fopen("/home/andrei/Documents/practica_siemens/DMA/debug/sim/test_full.txt", "r");
                if (fd == 0) begin
                    $display("ERR: Nu exista test_full.txt!");
                    $finish;
                end

                while (!$feof(fd)) begin
                    scan_result = $fscanf(fd, "%s %h %h\n", cmd, addr_arg, data_arg);
                    if (scan_result > 0) begin
                        case (cmd)
                            "W": begin
                                $display("[%0t] WRITE -> Addr: %h, Data: %h", $time, addr_arg, data_arg);
                                axi_lite_write(addr_arg, data_arg);
                            end

                            "R": begin
                                $display("[%0t] READ  -> Addr: %h", $time, addr_arg);
                                axi_lite_read(addr_arg, read_val);
                                $display("      Data citita: %h", read_val);
                            end

                            "D": begin
                                $display("[%0t] DELAY -> Astept %0d ns", $time, addr_arg);
                                #(addr_arg); 
                            end

                            default: begin
                                $display("[%0t] NECUNOSCUT: %s. Omit linia.", $time, cmd);
                            end
                        endcase
                    end
                end

                $fclose(fd);
                $display("S-a executat tot fisierul");

                // --- VERIFICARE AUTOMATA (BACKDOOR READ) ---
                $display("\n===========================================");
                $display("   VERIFICARE REZULTATE DMA (Dest: 0x2000) ");
                $display("===========================================");

                // Verificam vizual in consola ce s-a scris in primele 8 cuvinte
                for (i = 0; i < 8; i = i + 1) begin
                    $display("Adresa AXI: 0x%0h | Data RAM: 0x%h", 
                             32'h00002000 + (i*4), 
                             ram_memory[(32'h00002000 >> 2) + i]);
                end

                // Verificare tip self-checking (Automatizata)
                if (ram_memory[(32'h00002000 >> 2) + 0] === v0 &&
                    ram_memory[(32'h00002000 >> 2) + 7] === v7) begin
                    $display("\n>>> TEST PASSED! Datele au fost mutate corect la destinatie. <<<");
                end else begin
                    $display("\n>>> TEST FAILED! Datele de la destinatie nu corespund. <<<");
                end
                $display("===========================================\n");

            /*
                //Faza de scriere
                axi_lite_write(ADDR_CH0_BW_CAP, 32'hA5A5A5A5);
                $display("[%0t] Am scris valoarea.", $time);

                #20;

                //Faza de citire
                axi_lite_read(ADDR_CH0_BW_CAP, read_val);
                $display("[%0t] Am citit data: %h", $time, read_val);
            */
                #50;
                $finish;
            end
        join   
    end
    //========================================================
endmodule