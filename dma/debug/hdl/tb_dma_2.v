`timescale 1ns / 1ps
module tb_dma_2;
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

    // Memorie simulata (SRAM) - 32 KB
    // AXI e byte-adressable, dar memoria e word-adressable, de ex
    // Adresa AXI 8 -> 8/4=2 -> ram_memory[2]
    reg [31:0] ram_memory [0:8191];

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
        input integer delay; // Optional delay in clock cycles before sending WVALID
        begin
            fork
                begin
                    //@(posedge clk);
                    s_axi_awaddr  <= addr;
                    s_axi_awvalid <= 1'b1;
                    while (s_axi_awready !== 1'b1)
                        @(posedge clk);
                    s_axi_awvalid <= 1'b0;
                end
                begin
                    //@(posedge clk);
                    if (delay > 0)
                        repeat (delay)
                            @(posedge clk);
                    s_axi_wvalid  <= 1'b1;
                    s_axi_wdata   <= data;
                    s_axi_wstrb   <= 4'hF;
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
            
            //@(posedge clk);
            while (s_axi_arready !== 1'b1)
                @(posedge clk);
            s_axi_arvalid <= 1'b0;

            s_axi_rready <= 1'b1;
            
            //@(posedge clk);
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

    //=== TASK PENTRU PREGATIREA TRANSFERULUI IN RAM ===
    task setup_dma_transfer;
        input [31:0] desc_addr;
        input [31:0] src_addr;
        input [31:0] dst_addr;
        input [31:0] transf_len;
        input [31:0] pattern; // Un pattern de baza pentru date (ex: 32'hA1A1A1A1)
        integer k;
        begin
            // 1. Incarcam payload-ul sursa in RAM
            for (k = 0; k < (transf_len >> 2); k = k + 1) begin
                backdoor_ram_write(src_addr + (k * 4), pattern + k); 
            end

            // 2. Setam descriptorul in RAM
            backdoor_ram_write(desc_addr, src_addr);
            backdoor_ram_write(desc_addr + 4, dst_addr);
            backdoor_ram_write(desc_addr + 8, transf_len);
            backdoor_ram_write(desc_addr + 12, 32'h00000001); // CONTROL = bit 0 (last desc)
            
            $display("[%0t] INFO: RAM setat -> Desc: %h, Src: %h, Dst: %h", $time, desc_addr, src_addr, dst_addr);
        end
    endtask
    //====================================

    //=== TASK PENTRU PORNIREA UNUI CANAL ===
    task start_channel;
        input [31:0] base_reg_addr; // Ex: ADDR_CH0_DESC_ADDR
        input [31:0] desc_addr;
        input [31:0] bw_cap;
        begin
            // Scriem adresa descriptorului
            axi_lite_write(base_reg_addr, desc_addr, 0);
            
            // Setam latimea de banda (token bucket parameters)
            axi_lite_write(base_reg_addr + 8, bw_cap, 0); // Offset 8 pt BW_CAP
            
            // Dam Enable (bitul 0 din CONTROL)
            axi_lite_write(base_reg_addr + 4, 32'h00000001, 0); // Offset 4 pt CONTROL
            
            $display("[%0t] INFO: Canal lansat la adresa de baza %h", $time, base_reg_addr);
        end
    endtask
    //====================================

    //=== TASK PENTRU ASTEPTAREA FINALIZARII (POLLING) ===
    task wait_channel_done;
        input [31:0] status_reg_addr; // Ex: ADDR_CH0_STATUS
        reg   [31:0] st;
        begin
            st = 32'h0;
            // Extragem starea FSM din ultimii 3 biti. Asteptam valoarea 4 (STATE_DONE).
            while ((st & 3'b111) !== 3'd4) begin
                axi_lite_read(status_reg_addr, st);
                #(20); // Asteptam putin intre citiri pentru a nu aglomera bus-ul
            end
            $display("[%0t] INFO: Canalul cu STATUS reg %h a terminat (STATE_DONE)!", $time, status_reg_addr);
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
                // 1. Initializare si Reset
                for (i = 0; i < 8192; i = i + 1) ram_memory[i] = 32'h00000000;
                apply_reset(27); 

                // 2. Pregatim datele in RAM
                // CH0: Desc la 0x0100, muta 32 bytes de la 0x1000 la 0x2000
                setup_dma_transfer(32'h00000100, 32'h00001000, 32'h00002000, 32'h20, 32'hAAAA0000);
                
                // CH1: Desc la 0x0200, muta 32 bytes de la 0x3000 la 0x4000
                setup_dma_transfer(32'h00000200, 32'h00003000, 32'h00004000, 32'h20, 32'hBBBB0000);

                // CH2: Desc la 0x0300, muta 32 bytes de la 0x5000 la 0x6000
                setup_dma_transfer(32'h00000300, 32'h00005000, 32'h00006000, 32'h20, 32'hCCCC0000);

                // CH3: Desc la 0x0400, muta 32 bytes de la 0x6800 la 0x7000
                setup_dma_transfer(32'h00000400, 32'h00006800, 32'h00007000, 32'h20, 32'hDDDD0000);


                // 3. Setam Politica de Arbitrare (ex: 1 = Round Robin)
                axi_lite_write(ADDR_SCHED_POLICY, 32'h00000001, 0);

                // 4. Lansam TOATE cele 4 canale simultan
                $display("\n--- LANSARE 4 CANALE CONCURENTE ---");
                start_channel(ADDR_CH0_DESC_ADDR, 32'h00000100, 32'h00200008); 
                start_channel(ADDR_CH1_DESC_ADDR, 32'h00000200, 32'h00200008);
                start_channel(ADDR_CH2_DESC_ADDR, 32'h00000300, 32'h00200008);
                start_channel(ADDR_CH3_DESC_ADDR, 32'h00000400, 32'h00200008);

                // 5. Asteptam finalizarea tuturor
                wait_channel_done(ADDR_CH0_STATUS);
                wait_channel_done(ADDR_CH1_STATUS);
                wait_channel_done(ADDR_CH2_STATUS);
                wait_channel_done(ADDR_CH3_STATUS);
                
                // Opțional: Curățăm bitul de enable
                axi_lite_write(ADDR_CH0_CONTROL, 32'h0, 0);
                axi_lite_write(ADDR_CH1_CONTROL, 32'h0, 0);
                axi_lite_write(ADDR_CH2_CONTROL, 32'h0, 0);
                axi_lite_write(ADDR_CH3_CONTROL, 32'h0, 0);

                // --- VERIFICARE AUTOMATA (BACKDOOR READ) ---
                $display("\n===========================================");
                $display("   VERIFICARE REZULTATE 4 CANALE ");
                $display("===========================================");
                
                // Printam doar prima valoare din fiecare destinatie ca "sanity check" in consola
                $display("CH0 (Dest: 0x2000) -> Data: 0x%h", ram_memory[(32'h00002000 >> 2)]);
                $display("CH1 (Dest: 0x4000) -> Data: 0x%h", ram_memory[(32'h00004000 >> 2)]);
                $display("CH2 (Dest: 0x6000) -> Data: 0x%h", ram_memory[(32'h00006000 >> 2)]);
                $display("CH3 (Dest: 0x7000) -> Data: 0x%h", ram_memory[(32'h00007000 >> 2)]);

                // Verificare tip self-checking integrala
                if (ram_memory[(32'h00002000 >> 2)] === 32'hAAAA0000 &&
                    ram_memory[(32'h00004000 >> 2)] === 32'hBBBB0000 &&
                    ram_memory[(32'h00006000 >> 2)] === 32'hCCCC0000 &&
                    ram_memory[(32'h00007000 >> 2)] === 32'hDDDD0000) begin
                    $display("\n>>> TEST PASSED! Toate cele 4 canale au supravietuit arbitrajului. <<<");
                end else begin
                    $display("\n>>> TEST FAILED! S-au pierdut date in trafic. <<<");
                end
                $display("===========================================\n");

                #100;
                $finish;
            end
        join   
    end
    //========================================================
endmodule