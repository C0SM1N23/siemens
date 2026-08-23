`timescale 1ns / 1ps

// Testbench pentru mc_dma_top
//
// Scenariul 1 : Un singur canal (CH0) activ, politica Fixed Priority.
//               Se verifica un transfer descriptor -> read burst -> write burst
//               complet, semnalarea IRQ si corectitudinea datelor mutate.
//
// Scenariul 2 : Doua canale (CH1 si CH2) active simultan, politica Round-Robin.
//               Se verifica arbitrarea intre canale (fara deadlock/starvation)
//               si finalizarea corecta a ambelor transferuri.
//
// Modelul de memorie folosit ca slave pe interfata AXI4-Full este un model
// comportamental simplificat (un singur transfer outstanding, burst-uri INCR),
// suficient pentru a exercita FSM-urile din DUT (master, arbitru, canale).


module tb_mc_dma_top;

    // -------------------------------------------------------------------
    // Register map (trebuie sa corespunda cu axi4_lite_slave.v)
    // -------------------------------------------------------------------
    localparam ADDR_CH0_DESC_ADDR = 8'h00, ADDR_CH0_CONTROL = 8'h04, ADDR_CH0_BW_CAP = 8'h08, ADDR_CH0_STATUS = 8'h0C;
    localparam ADDR_CH1_DESC_ADDR = 8'h10, ADDR_CH1_CONTROL = 8'h14, ADDR_CH1_BW_CAP = 8'h18, ADDR_CH1_STATUS = 8'h1C;
    localparam ADDR_CH2_DESC_ADDR = 8'h20, ADDR_CH2_CONTROL = 8'h24, ADDR_CH2_BW_CAP = 8'h28, ADDR_CH2_STATUS = 8'h2C;
    localparam ADDR_CH3_DESC_ADDR = 8'h30, ADDR_CH3_CONTROL = 8'h34, ADDR_CH3_BW_CAP = 8'h38, ADDR_CH3_STATUS = 8'h3C;
    localparam ADDR_INT_STATUS    = 8'h40, ADDR_INT_ENABLE  = 8'h44, ADDR_SCHED_POLICY = 8'h48;

    localparam ST_IDLE = 3'd0, ST_FETCH = 3'd1, ST_ACTIVE = 3'd2,
               ST_SUSP = 3'd3, ST_DONE  = 3'd4, ST_ERROR  = 3'd5;

    localparam SCHED_FIXED = 32'd0, SCHED_RR = 32'd1;

    // Bandwidth cap generos astfel incat token bucket-ul sa nu limiteze testul
    // (refill_rate = 16'd200, max_tokens = 16'd2000)
    localparam [31:0] BW_CAP_OPEN = {16'd2000, 16'd200};

    integer errors = 0;

    // -------------------------------------------------------------------
    // Clock / Reset
    // -------------------------------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk; // 100 MHz

    // -------------------------------------------------------------------
    // AXI4-Lite (CPU -> DUT)
    // -------------------------------------------------------------------
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

    // -------------------------------------------------------------------
    // AXI4-Full (DUT -> Memorie)
    // -------------------------------------------------------------------
    wire [31:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awvalid;
    reg         m_axi_awready;
    wire [31:0] m_axi_wdata;
    wire [3:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    reg         m_axi_wready;
    reg  [1:0]  m_axi_bresp;
    reg         m_axi_bvalid;
    wire        m_axi_bready;
    wire [31:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    reg         m_axi_arready;
    reg  [31:0] m_axi_rdata;
    reg  [1:0]  m_axi_rresp;
    reg         m_axi_rlast;
    reg         m_axi_rvalid;
    wire        m_axi_rready;

    wire [3:0] irq;

    // -------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------
    mc_dma_top dut (
        .clk(clk), .rst_n(rst_n), .irq(irq),

        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),   .s_axi_wstrb(s_axi_wstrb),     .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),   .s_axi_bvalid(s_axi_bvalid),   .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),   .s_axi_rresp(s_axi_rresp),     .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),

        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    
    // Model comportamental de memorie (slave pe AXI4-Full)
    // Adresare pe cuvinte de 32b: index = addr[19:2]  (spatiu = 1 MB)
    
    reg [31:0] mem [0:(1<<18)-1];

    // ---- Canal de citire (AR/R) ----
    reg        rd_active;
    reg [31:0] rd_addr;
    reg [7:0]  rd_len;
    reg [7:0]  rd_beat;

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            rd_active     <= 1'b0;
            m_axi_arready <= 1'b0;
            m_axi_rvalid  <= 1'b0;
            m_axi_rlast   <= 1'b0;
            m_axi_rresp   <= 2'b00;
        end else begin
            m_axi_arready <= ~rd_active;

            if (~rd_active && m_axi_arvalid && m_axi_arready) begin
                rd_active    <= 1'b1;
                rd_addr      <= m_axi_araddr;
                rd_len       <= m_axi_arlen;
                rd_beat      <= 8'd0;
                m_axi_rvalid <= 1'b1;
                m_axi_rdata  <= mem[m_axi_araddr[19:2]];
                m_axi_rlast  <= (m_axi_arlen == 8'd0);
                m_axi_rresp  <= 2'b00;
            end else if (rd_active && m_axi_rvalid && m_axi_rready) begin
                if (m_axi_rlast) begin
                    m_axi_rvalid <= 1'b0;
                    rd_active    <= 1'b0;
                end else begin
                    rd_beat      <= rd_beat + 1'b1;
                    m_axi_rdata  <= mem[(rd_addr + ((rd_beat + 1) << 2)) >> 2];
                    m_axi_rlast  <= ((rd_beat + 1) == rd_len);
                end
            end
        end
    end

    // ---- Canal de scriere (AW/W/B) ----
    reg        wr_active;
    reg [31:0] wr_addr;
    reg [7:0]  wr_beat;

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            wr_active     <= 1'b0;
            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;
            m_axi_bvalid  <= 1'b0;
            m_axi_bresp   <= 2'b00;
        end else begin
            m_axi_awready <= ~wr_active;

            if (~wr_active && m_axi_awvalid && m_axi_awready) begin
                wr_active    <= 1'b1;
                wr_addr      <= m_axi_awaddr;
                wr_beat      <= 8'd0;
                m_axi_wready <= 1'b1;
            end else if (wr_active) begin
                m_axi_wready <= 1'b1;
                if (m_axi_wvalid && m_axi_wready) begin
                    mem[(wr_addr + (wr_beat << 2)) >> 2] <= m_axi_wdata;
                    if (m_axi_wlast) begin
                        wr_active    <= 1'b0;
                        m_axi_wready <= 1'b0;
                        m_axi_bvalid <= 1'b1;
                        m_axi_bresp  <= 2'b00;
                    end else begin
                        wr_beat <= wr_beat + 1'b1;
                    end
                end
            end

            if (m_axi_bvalid && m_axi_bready)
                m_axi_bvalid <= 1'b0;
        end
    end

    
    // Driver AXI4-Lite (simuleaza scrieri/citiri din partea CPU-ului)
    
    // NOTA: awready/wready (si arready) in axi4_lite_slave sunt semnale
    // inregistrate ce pulseaza un singur ciclu, iar wren/rden interne cer ca
    // valid sa fie ridicat in ACELASI ciclu cu ready. De aceea awvalid/wvalid
    // (respectiv arvalid) trebuie tinute ridicate pana se observa
    // bvalid/rvalid, nu coborate imediat ce se observa awready/wready/arready.
    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk); #1;
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            s_axi_wdata   = data;
            s_axi_wstrb   = 4'hF;
            s_axi_wvalid  = 1'b1;
            s_axi_bready  = 1'b1;

            @(posedge clk); #1;
            while (!s_axi_bvalid) begin
                @(posedge clk); #1;
            end
            s_axi_awvalid = 1'b0;
            s_axi_wvalid  = 1'b0;
            s_axi_bready  = 1'b0;
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk); #1;
            s_axi_araddr  = addr;
            s_axi_arvalid = 1'b1;
            s_axi_rready  = 1'b1;

            @(posedge clk); #1;
            while (!s_axi_rvalid) begin
                @(posedge clk); #1;
            end
            data = s_axi_rdata;
            s_axi_arvalid = 1'b0;
            s_axi_rready  = 1'b0;
        end
    endtask

    // Scrie direct in memoria "de sistem" (backdoor) - simuleaza CPU-ul care
    // a pregatit deja descriptorul si datele sursa in RAM inainte de a porni DMA-ul.
    task mem_poke;
        input [31:0] addr;
        input [31:0] data;
        begin
            mem[addr[19:2]] = data;
        end
    endtask

    task write_descriptor;
        input [31:0] desc_addr;
        input [31:0] src_addr;
        input [31:0] dst_addr;
        input [31:0] len_bytes;
        begin
            mem_poke(desc_addr + 32'h00, src_addr);
            mem_poke(desc_addr + 32'h04, dst_addr);
            mem_poke(desc_addr + 32'h08, len_bytes);
            mem_poke(desc_addr + 32'h0C, 32'h1); // ctrl[0] = 1 -> ultimul (si singurul) segment
        end
    endtask

    // Umple regiunea sursa cu un pattern usor de verificat
    task fill_source;
        input [31:0] src_addr;
        input [31:0] n_words;
        input [31:0] seed;
        integer i;
        begin
            for (i = 0; i < n_words; i = i + 1)
                mem_poke(src_addr + (i << 2), seed + i);
        end
    endtask

    // Compara sursa cu destinatia dupa transfer
    task check_data;
        input [31:0] src_addr;
        input [31:0] dst_addr;
        input [31:0] n_words;
        input [255:0] tag;
        integer i;
        reg [31:0] exp, got;
        begin
            for (i = 0; i < n_words; i = i + 1) begin
                exp = mem[(src_addr + (i << 2)) >> 2];
                got = mem[(dst_addr + (i << 2)) >> 2];
                if (exp !== got) begin
                    errors = errors + 1;
                    $display("[%0t] EROARE (%0s): word %0d  src=0x%08h dst=0x%08h  asteptat=0x%08h  citit=0x%08h",
                              $time, tag, i, src_addr + (i<<2), dst_addr + (i<<2), exp, got);
                end
            end
        end
    endtask

    // Asteapta ca un canal sa ajunga in STATE_DONE (citit prin AXI-Lite, offset STATUS)
    task wait_channel_done;
        input [7:0]  status_addr;
        input [31:0] timeout_cycles;
        input [255:0] tag;
        reg [31:0] st;
        integer cyc;
        begin
            cyc = 0;
            st  = 32'h0;
            while (st[2:0] != ST_DONE && st[2:0] != ST_ERROR && cyc < timeout_cycles) begin
                axil_read({24'h0, status_addr}, st);
                cyc = cyc + 1;
            end
            if (st[2:0] == ST_DONE)
                $display("[%0t] %0s: canal finalizat cu succes (STATE_DONE)", $time, tag);
            else begin
                errors = errors + 1;
                $display("[%0t] EROARE (%0s): canalul nu a ajuns in STATE_DONE (stare finala=%0d, timeout=%0b)",
                          $time, tag, st[2:0], (cyc >= timeout_cycles));
            end
        end
    endtask

    
    // Scenariul 1: transfer simplu pe un singur canal (CH0), Fixed Priority
    
    task scenario1_single_channel;
        localparam DESC_ADDR = 32'h0000_1000;
        localparam SRC_ADDR  = 32'h0000_2000;
        localparam DST_ADDR  = 32'h0000_3000;
        localparam LEN_BYTES = 32'd32; // 8 cuvinte -> exact un burst read + un burst write
        begin
            $display("\n===== Scenariul 1: Transfer simplu, un canal (CH0), Fixed Priority =====");

            fill_source(SRC_ADDR, 8, 32'hA000_0000);
            write_descriptor(DESC_ADDR, SRC_ADDR, DST_ADDR, LEN_BYTES);

            axil_write({24'h0, ADDR_SCHED_POLICY}, SCHED_FIXED);
            axil_write({24'h0, ADDR_CH0_BW_CAP},    BW_CAP_OPEN);
            axil_write({24'h0, ADDR_CH0_DESC_ADDR}, DESC_ADDR);
            axil_write({24'h0, ADDR_CH0_CONTROL},   32'h1); // enable=1

            wait_channel_done(ADDR_CH0_STATUS, 32'd2000, "CH0");
            check_data(SRC_ADDR, DST_ADDR, 8, "CH0");

            if (irq[0] !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] EROARE (CH0): irq[0] nu a fost semnalat", $time);
            end 
            else
                $display("[%0t] CH0: irq[0] semnalat corect", $time);

            // Curatare: dezactiveaza canalul si sterge interrupt-ul (W1C)
            axil_write({24'h0, ADDR_CH0_CONTROL}, 32'h0);
            axil_write({24'h0, ADDR_INT_STATUS},  32'h1);
        end
    endtask

    
    // Scenariul 2: doua canale simultane (CH1, CH2), Round-Robin
    
    task scenario2_round_robin;
        localparam DESC1_ADDR = 32'h0000_4000;
        localparam SRC1_ADDR  = 32'h0000_5000;
        localparam DST1_ADDR  = 32'h0000_6000;

        localparam DESC2_ADDR = 32'h0000_7000;
        localparam SRC2_ADDR  = 32'h0000_8000;
        localparam DST2_ADDR  = 32'h0000_9000;

        localparam LEN_BYTES  = 32'd32;
        begin
            $display("\n===== Scenariul 2: Arbitrare Round-Robin intre CH1 si CH2 (simultan) =====");

            fill_source(SRC1_ADDR, 8, 32'hB100_0000);
            fill_source(SRC2_ADDR, 8, 32'hB200_0000);
            write_descriptor(DESC1_ADDR, SRC1_ADDR, DST1_ADDR, LEN_BYTES);
            write_descriptor(DESC2_ADDR, SRC2_ADDR, DST2_ADDR, LEN_BYTES);

            axil_write({24'h0, ADDR_SCHED_POLICY}, SCHED_RR);
            axil_write({24'h0, ADDR_CH1_BW_CAP},    BW_CAP_OPEN);
            axil_write({24'h0, ADDR_CH2_BW_CAP},    BW_CAP_OPEN);
            axil_write({24'h0, ADDR_CH1_DESC_ADDR}, DESC1_ADDR);
            axil_write({24'h0, ADDR_CH2_DESC_ADDR}, DESC2_ADDR);

            // Pornim ambele canale in aceeasi fereastra de timp, pentru a forta
            // arbitrul sa decida intre doua cereri concurente
            axil_write({24'h0, ADDR_CH1_CONTROL}, 32'h1);
            axil_write({24'h0, ADDR_CH2_CONTROL}, 32'h1);

            wait_channel_done(ADDR_CH1_STATUS, 32'd2000, "CH1");
            wait_channel_done(ADDR_CH2_STATUS, 32'd2000, "CH2");

            check_data(SRC1_ADDR, DST1_ADDR, 8, "CH1");
            check_data(SRC2_ADDR, DST2_ADDR, 8, "CH2");

            if (irq[1] !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] EROARE (CH1): irq[1] nu a fost semnalat", $time);
            end
            if (irq[2] !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] EROARE (CH2): irq[2] nu a fost semnalat", $time);
            end
            if (irq[1] === 1'b1 && irq[2] === 1'b1)
                $display("[%0t] CH1 si CH2: ambele irq semnalate corect (arbitrare RR reusita)", $time);

            axil_write({24'h0, ADDR_CH1_CONTROL}, 32'h0);
            axil_write({24'h0, ADDR_CH2_CONTROL}, 32'h0);
            axil_write({24'h0, ADDR_INT_STATUS},  32'h6); // sterge bitii 1 si 2
        end
    endtask

    // Monitor optional: afiseaza fiecare acordare de grant catre master (util pt debug arbitrare)
    reg [3:0] ch_gnt_d;
    always @(posedge clk) begin
        ch_gnt_d <= dut.ch_gnt;
        if (dut.ch_gnt != 4'b0000 && dut.ch_gnt != ch_gnt_d)
            $display("[%0t] Arbitru: grant acordat canalului -> ch_gnt=%b (sched_policy=%0d)",
                      $time, dut.ch_gnt, dut.sched_policy);
    end

    
    // Secventa principala
    
    integer i;
    initial begin
        // Initializare semnale
        s_axi_awaddr = 0; s_axi_awvalid = 0;
        s_axi_wdata  = 0; s_axi_wstrb = 0; s_axi_wvalid = 0;
        s_axi_bready = 0;
        s_axi_araddr = 0; s_axi_arvalid = 0; s_axi_rready = 0;

        // Curata memoria folosita de test (evita valori X)
        for (i = 0; i < 20; i = i + 1)
            mem[32'h0000_1000 + (i << 2) >> 2] = 32'h0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        scenario1_single_channel;
        scenario2_round_robin;

        repeat (10) @(posedge clk);

        $display("\n=====================================================");
        if (errors == 0)
            $display("REZULTAT: TOATE TESTELE AU TRECUT (0 erori)");
        else
            $display("REZULTAT: %0d EROARE(I) DETECTATE", errors);
        $display("=====================================================\n");

        $finish;
    end

    // Watchdog global (siguranta impotriva blocarii simularii)
    initial begin
        #200000;
        $display("[%0t] EROARE: WATCHDOG GLOBAL - simularea nu s-a terminat la timp", $time);
        errors = errors + 1;
        $finish;
    end

    // Waveforms (optional, util pentru debug in GTKWave/ModelSim)
    initial begin
        $dumpfile("tb_mc_dma_top.vcd");
        $dumpvars(0, tb_mc_dma_top);
    end

endmodule
