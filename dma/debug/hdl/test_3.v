`timescale 1ns / 1ps
module test_3;
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
    wire [3:0]  irq; // <--- ADAUGAT pentru a putea monitoriza intrareruperile

    //=======Interfata AXI4-Lite=========
    reg  [31:0] s_axi_araddr;
    reg         s_axi_arvalid;
    reg         s_axi_rready;
    wire [31:0] s_axi_rdata;
    wire        s_axi_rvalid;
    wire        s_axi_arready;
    wire        s_axi_rresp;

    reg  [31:0] s_axi_awaddr;
    reg         s_axi_awvalid;
    reg  [31:0] s_axi_wdata;
    reg  [ 3:0] s_axi_wstrb;
    reg         s_axi_wvalid;
    reg         s_axi_bready;
    wire        s_axi_awready;
    wire        s_axi_wready;
    wire        s_axi_bvalid;
    wire [ 1:0] s_axi_bresp;

    //=======Interfata AXI4-Full=========
    wire [31:0] m_axi_araddr;
    wire [ 7:0] m_axi_arlen;   
    wire        m_axi_arvalid; 
    reg         m_axi_arready; 
    reg  [31:0] m_axi_rdata;
    reg  [ 1:0] m_axi_rresp;   
    reg         m_axi_rlast;   
    reg         m_axi_rvalid;  
    wire        m_axi_rready;  

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

    // Memorie simulata (SRAM) - 32 KB
    reg [31:0] ram_memory [0:8191];

    //====Variabile citire din fisier====
    reg  [31:0] read_val;
    integer     fd;             
    integer     scan_result;    
    reg [8*8-1:0] cmd;      
    reg [31:0]  addr_arg;    
    reg [31:0]  data_arg;    

    //====Variabile pentru citirea/scrierea in RAM====
    reg [31:0] current_read_addr;
    reg [7:0]  burst_len;
    integer    beat;
    reg [31:0] current_write_addr;
    reg [7:0]  write_burst_len;
    integer    w_beat;
    integer    i;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    mc_dma_top dut_dma (
        .clk(clk),
        .rst_n(rst_n),
        .irq(irq), // <--- CONECTAT portul de intreruperi

        //AXI4-Lite Citire
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_rready(s_axi_rready), .s_axi_rdata(s_axi_rdata), .s_axi_rvalid(s_axi_rvalid), .s_axi_arready(s_axi_arready), .s_axi_rresp(s_axi_rresp),
        //AXI4-Lite Scriere 
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_bready(s_axi_bready), .s_axi_awready(s_axi_awready), .s_axi_wready(s_axi_wready), .s_axi_bvalid(s_axi_bvalid), .s_axi_bresp(s_axi_bresp),
        //AXI4-Full Citire
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        //AXI4-Full Scriere
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    //======TASK-uri AXI4-Lite========
    task axi_lite_write;
        input [31:0] addr;
        input [31:0] data;
        input integer delay; 
        begin
            fork
                begin
                    s_axi_awaddr  <= addr;
                    s_axi_awvalid <= 1'b1;
                    while (s_axi_awready !== 1'b1) @(posedge clk);
                    s_axi_awvalid <= 1'b0;
                end
                begin
                    if (delay > 0) repeat (delay) @(posedge clk);
                    s_axi_wvalid  <= 1'b1;
                    s_axi_wdata   <= data;
                    s_axi_wstrb   <= 4'hF;
                    while (s_axi_wready !== 1'b1) @(posedge clk);
                    s_axi_wvalid <= 1'b0;
                end
            join
            s_axi_bready <= 1'b1;
            @(posedge clk);
            while (s_axi_bvalid !== 1'b1) @(posedge clk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task axi_lite_read;
        input  [31:0] addr;
        output [31:0] data_out; 
        begin
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            while (s_axi_arready !== 1'b1) @(posedge clk);
            s_axi_arvalid <= 1'b0;
            s_axi_rready <= 1'b1;
            while (s_axi_rvalid !== 1'b1) @(posedge clk);
            data_out = s_axi_rdata; 
            s_axi_rready <= 1'b0;
        end
    endtask

    //======TASK-uri Utilitare========
    task backdoor_ram_write;
        input [31:0] byte_addr;
        input [31:0] data;
        begin
            ram_memory[byte_addr >> 2] = data;
        end
    endtask

    task apply_reset;
        input integer reset_cycles;
        begin
            $display("[%0t] INFO: Incepere secventa reset...", $time);
            rst_n = 1'b0;
            repeat (reset_cycles) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);
            $display("[%0t] INFO: Reset Complet.", $time);
        end
    endtask

    task setup_dma_transfer;
        input [31:0] desc_addr;
        input [31:0] src_addr;
        input [31:0] dst_addr;
        input [31:0] transf_len;
        input [31:0] pattern;
        integer k;
        begin
            for (k = 0; k < (transf_len >> 2); k = k + 1) begin
                backdoor_ram_write(src_addr + (k * 4), pattern + k); 
            end
            backdoor_ram_write(desc_addr, src_addr);
            backdoor_ram_write(desc_addr + 4, dst_addr);
            backdoor_ram_write(desc_addr + 8, transf_len);
            backdoor_ram_write(desc_addr + 12, 32'h00000001); // CONTROL = bit 0 (last desc)
        end
    endtask

    task start_channel;
        input [31:0] base_reg_addr; 
        input [31:0] desc_addr;
        input [31:0] bw_cap;
        begin
            axi_lite_write(base_reg_addr, desc_addr, 0);
            axi_lite_write(base_reg_addr + 8, bw_cap, 0); 
            axi_lite_write(base_reg_addr + 4, 32'h00000001, 0); 
        end
    endtask

    task wait_channel_done;
        input [31:0] status_reg_addr; 
        reg   [31:0] st;
        begin
            st = 32'h0;
            while ((st & 3'b111) !== 3'd4 && (st & 3'b111) !== 3'd5) begin
                axi_lite_read(status_reg_addr, st);
                #(20); 
            end
            if ((st & 3'b111) === 3'd5) $display("[%0t] WARNING: Canalul %h a raportat ERROR!", $time, status_reg_addr);
        end
    endtask

    //======Blocul Initial Principal========
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        s_axi_arvalid <= 1'b0; s_axi_rready <= 1'b0; s_axi_araddr <= 32'h0;
        s_axi_awvalid <= 1'b0; s_axi_wvalid <= 1'b0; s_axi_bready <= 1'b0;
        s_axi_awaddr  <= 32'h0; s_axi_wdata <= 32'h0; s_axi_wstrb <= 4'h0;

        m_axi_arready <= 1'b0; m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0;
        m_axi_rresp <= 2'b00; m_axi_rdata <= 32'h0;
        m_axi_awready <= 1'b0; m_axi_wready <= 1'b0;
        m_axi_bvalid <= 1'b0; m_axi_bresp <= 2'b00;

        fork
            // Thread 1: AXI4-Full Read Responder
            begin
                while(~rst_n) @(posedge clk);
                forever begin
                    @(posedge clk);
                    while (m_axi_arvalid !== 1'b1) @(posedge clk);

                    current_read_addr = m_axi_araddr;
                    burst_len = m_axi_arlen; 

                    m_axi_arready <= 1'b1;
                    @(posedge clk);
                    m_axi_arready <= 1'b0;

                    for (beat = 0; beat <= burst_len; beat = beat + 1) begin
                        m_axi_rdata  <= ram_memory[current_read_addr >> 2];
                        m_axi_rvalid <= 1'b1;
                        m_axi_rlast  <= (beat == burst_len) ? 1'b1 : 1'b0;

                        @(posedge clk);
                        while (m_axi_rready !== 1'b1) @(posedge clk);
                        current_read_addr = current_read_addr + 4;
                    end
                    m_axi_rvalid <= 1'b0;
                    m_axi_rlast  <= 1'b0;
                end
            end

            // Thread 2: AXI4-Full Write Responder
            begin
                forever begin
                    m_axi_awready <= 1'b1; 
                    @(posedge clk);
                    while (m_axi_awvalid !== 1'b1) @(posedge clk);
                    current_write_addr = m_axi_awaddr;
                    write_burst_len = m_axi_awlen;
                    m_axi_awready <= 1'b0;

                    m_axi_wready <= 1'b1; 
                    for (w_beat = 0; w_beat <= write_burst_len; w_beat = w_beat + 1) begin
                        @(posedge clk);
                        while (m_axi_wvalid !== 1'b1) @(posedge clk);
                        ram_memory[current_write_addr >> 2] = m_axi_wdata;
                        current_write_addr = current_write_addr + 4;
                    end
                    m_axi_wready <= 1'b0;

                    m_axi_bvalid <= 1'b1;
                    @(posedge clk);
                    while (m_axi_bready !== 1'b1) @(posedge clk);
                    m_axi_bvalid <= 1'b0;
                end
            end

            // Thread 3: Secventa de Teste Specifice (Feature Testing)
            begin
                for (i = 0; i < 8192; i = i + 1) ram_memory[i] = 32'h00000000;
                apply_reset(27); 

                 // ==========================================================
                // T03: IRQ Write-1-To-Clear (W1C) Test
                // ==========================================================
                $display("\n--- [T03] RUNNING: IRQ W1C Behavior ---");
                axi_lite_write(ADDR_INT_ENABLE, 32'h0000000F, 0); // Demascam
                setup_dma_transfer(32'h0200, 32'h3000, 32'h4000, 32'h20, 32'hB2B2B2B2);
                start_channel(ADDR_CH0_DESC_ADDR, 32'h0200, 32'h00200008); 
                wait_channel_done(ADDR_CH0_STATUS);
                
                #50;
                // Citim registrul pentru a confirma latch-ul intreruperii
                axi_lite_read(ADDR_INT_STATUS, read_val);
                if (read_val[0] === 1'b1 && irq[0] === 1'b1) begin
                    $display("          IRQ is HIGH. Writing 1 to INT_STATUS to clear...");
                    axi_lite_write(ADDR_INT_STATUS, 32'h00000001, 0); // Stergem bitul 0 (W1C)
                    #50;
                    if (irq[0] === 1'b0) $display(">>> [T03] PASSED (IRQ Cleared via W1C)");
                    else $display(">>> [T03] FAILED (IRQ remained HIGH)");
                end else begin
                    $display(">>> [T03] FAILED (IRQ was not latched in INT_STATUS)");
                end
                
                axi_lite_write(ADDR_CH0_CONTROL, 32'h0, 0); // Reset CH0 FSM
                
                #100;
                $finish;
            end
        join   
    end
endmodule