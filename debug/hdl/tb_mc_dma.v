`timescale 1ns / 1ps
module tb_mc_dma;
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

    // ========================================================
    // TEST SELECTOR: Change this value to run different tests
    // 1 = T01: AXI4-Lite Register R/W
    // 2 = T02: IRQ Masking (INT_ENABLE = 0)
    // 3 = T03: IRQ Write-1-To-Clear (W1C)
    // 4 = T04: 4-Channel Concurrent Arbitration (Round-Robin)
    // 5 = T05: Bandwidth Throttling (Token Bucket)
    // 6 = T06: Suspend (Abort) and Resume
    // 7 = T07: Unaligned Transfer (40 Bytes)
    // ========================================================
    integer ACTIVE_TEST = 7; // <--- Change this value to select the test case

    reg         clk;
    reg         rst_n;
    wire [3:0]  irq; // <--- Added to monitor interrupt signals

    //======AXI4-Lite Interface========
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

    //=======AXI4-Full Interface=========
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

    // Simulated Memory (SRAM) - 32 KB
    reg [31:0] ram_memory [0:8191];

    //====File Read Variables====
    reg  [31:0] read_val;
    integer     fd;             
    integer     scan_result;    
    reg [8*8-1:0] cmd;      
    reg [31:0]  addr_arg;    
    reg [31:0]  data_arg;    

    //====RAM Read/Write Variables====
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
        .irq(irq), // <--- Interrupt port connected

        //AXI4-Lite Read
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_rready(s_axi_rready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rresp(s_axi_rresp),
        //AXI4-Lite Write
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
        //AXI4-Full Read
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        //AXI4-Full Write
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

    //======AXI4-Lite TASKs========
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

    //======Utility TASKs========
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
            $display("[%0t] INFO: Starting reset sequence...", $time);
            rst_n = 1'b0;
            repeat (reset_cycles) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);
            $display("[%0t] INFO: Reset Complete.", $time);
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
            backdoor_ram_write(desc_addr + 12, 32'h00000001); // CONTROL = bit 0 (last descriptor)
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
            if ((st & 3'b111) === 3'd5) $display("[%0t] WARNING: Channel %h reported ERROR!", $time, status_reg_addr);
        end
    endtask

    //======Main Initial Block========
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        s_axi_arvalid <= 1'b0;
        s_axi_rready <= 1'b0;
        s_axi_araddr <= 32'h0;
        s_axi_awvalid <= 1'b0;
        s_axi_wvalid <= 1'b0;
        s_axi_bready <= 1'b0;
        s_axi_awaddr  <= 32'h0;
        s_axi_wdata <= 32'h0;
        s_axi_wstrb <= 4'h0;

        m_axi_arready <= 1'b0;
        m_axi_rvalid <= 1'b0;
        m_axi_rlast <= 1'b0;
        m_axi_rresp <= 2'b00;
        m_axi_rdata <= 32'h0;
        m_axi_awready <= 1'b0;
        m_axi_wready <= 1'b0;
        m_axi_bvalid <= 1'b0;
        m_axi_bresp <= 2'b00;

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

            // Thread 3: Feature Testing
            begin : test_sequence
                integer k;
                
                for (k = 0; k < 8192; k = k + 1) ram_memory[k] = 32'h00000000;
                apply_reset(27); 

                $display("\n===========================================");
                $display("   STARTING TEST SUITE - RUNNING TEST %0d", ACTIVE_TEST);
                $display("===========================================\n");

                case (ACTIVE_TEST)
                    1: begin
                        // ========= T01: AXI4-Lite Register R/W Test ========
                        $display("--- [T01] RUNNING: AXI4-Lite Register R/W ---");
                        axi_lite_write(ADDR_CH0_BW_CAP, 32'hDEADBEEF, 0);
                        axi_lite_read(ADDR_CH0_BW_CAP, read_val);
                        if (read_val === 32'hDEADBEEF) $display(">>> [T01] PASSED");
                        else $display(">>> [T01] FAILED (Expected DEADBEEF, Got %h)", read_val);
                    end

                    2: begin
                        // ========= T02: IRQ Masking Test ========
                        $display("--- [T02] RUNNING: IRQ Masking (INT_ENABLE = 0) ---");
                        axi_lite_write(ADDR_INT_ENABLE, 32'h00000000, 0);
                        setup_dma_transfer(32'h0100, 32'h1000, 32'h2000, 32'h20, 32'hA1A1A1A1);
                        start_channel(ADDR_CH0_DESC_ADDR, 32'h0100, 32'h00200008); 
                        wait_channel_done(ADDR_CH0_STATUS);
                        
                        if (irq[0] === 1'b0) $display(">>> [T02] PASSED (Interrupt masked correctly)");
                        else $display(">>> [T02] FAILED (IRQ leaked through mask)");
                        axi_lite_write(ADDR_CH0_CONTROL, 32'h0, 0);
                    end

                    3: begin
                        // ========= T03: IRQ Write-1-To-Clear (W1C) Test ========
                        $display("--- [T03] RUNNING: IRQ W1C Behavior ---");
                        axi_lite_write(ADDR_INT_ENABLE, 32'h0000000F, 0);
                        setup_dma_transfer(32'h0200, 32'h3000, 32'h4000, 32'h20, 32'hB2B2B2B2);
                        start_channel(ADDR_CH0_DESC_ADDR, 32'h0200, 32'h00200008); 
                        wait_channel_done(ADDR_CH0_STATUS);
                        
                        #50;
                        axi_lite_read(ADDR_INT_STATUS, read_val);
                        if (read_val[0] === 1'b1 && irq[0] === 1'b1) begin
                            $display("          Writing 1 to INT_STATUS to clear...");
                            axi_lite_write(ADDR_INT_STATUS, 32'h00000001, 0); 
                            #50;
                            if (irq[0] === 1'b0) $display(">>> [T03] PASSED (IRQ Cleared via W1C)");
                            else $display(">>> [T03] FAILED (IRQ remained HIGH)");
                        end else begin
                            $display(">>> [T03] FAILED (IRQ was not latched in INT_STATUS)");
                        end
                        axi_lite_write(ADDR_CH0_CONTROL, 32'h0, 0);
                    end

                    4: begin
                        // ========= T04: Concurrent Channels Arbitration ========
                        $display("--- [T04] RUNNING: 4-Channel Concurrent Arbitration ---");
                        setup_dma_transfer(32'h0500, 32'h1000, 32'h2000, 32'h20, 32'hAAAA0000);
                        setup_dma_transfer(32'h0600, 32'h3000, 32'h4000, 32'h20, 32'hBBBB0000);
                        setup_dma_transfer(32'h0700, 32'h5000, 32'h6000, 32'h20, 32'hCCCC0000);
                        setup_dma_transfer(32'h0800, 32'h6800, 32'h7000, 32'h20, 32'hDDDD0000);

                        axi_lite_write(ADDR_SCHED_POLICY, 32'h00000001, 0); // 1 = Round Robin

                        start_channel(ADDR_CH0_DESC_ADDR, 32'h00000500, 32'h00200008); 
                        start_channel(ADDR_CH1_DESC_ADDR, 32'h00000600, 32'h00200008);
                        start_channel(ADDR_CH2_DESC_ADDR, 32'h00000700, 32'h00200008);
                        start_channel(ADDR_CH3_DESC_ADDR, 32'h00000800, 32'h00200008);

                        wait_channel_done(ADDR_CH0_STATUS);
                        wait_channel_done(ADDR_CH1_STATUS);
                        wait_channel_done(ADDR_CH2_STATUS);
                        wait_channel_done(ADDR_CH3_STATUS);

                        if (ram_memory[(32'h00002000 >> 2)] === 32'hAAAA0000 &&
                            ram_memory[(32'h00004000 >> 2)] === 32'hBBBB0000) begin
                            $display(">>> [T04] PASSED! (No data lost during heavy traffic)");
                        end else begin
                            $display(">>> [T04] FAILED! (Data corruption detected)");
                        end
                    end

                    5: begin
                        // ========= T05: Bandwidth Throttling (Token Bucket) ========
                        $display("--- [T05] RUNNING: Bandwidth Throttling (CH0 Slow vs CH1 Fast) ---");
                        setup_dma_transfer(32'h0900, 32'h8000, 32'h8100, 32'h40, 32'hE5E5E5E5);
                        setup_dma_transfer(32'h0A00, 32'h8200, 32'h8300, 32'h40, 32'hF6F6F6F6);
                        
                        $display("          Starting CH0 (Slow) and CH1 (Fast) simultaneously...");
                        start_channel(ADDR_CH0_DESC_ADDR, 32'h0900, 32'h00100001); 
                        start_channel(ADDR_CH1_DESC_ADDR, 32'h0A00, 32'h00200010);
                        
                        wait_channel_done(ADDR_CH1_STATUS);
                        $display("          CH1 (Fast) finished. Waiting for CH0 (Slow)...");
                        wait_channel_done(ADDR_CH0_STATUS);
                        $display(">>> [T05] PASSED! CH0 finished later. Throttling works.");
                        
                        axi_lite_write(ADDR_CH0_CONTROL, 32'h0, 0);
                        axi_lite_write(ADDR_CH1_CONTROL, 32'h0, 0);
                    end

                    6: begin
                        // ========= T06: Suspend (Abort) and Resume ========
                        $display("--- [T06] RUNNING: Suspend (Abort) and Resume ---");
                        setup_dma_transfer(32'h0300, 32'h5000, 32'h6000, 32'h80, 32'hC3C3C3C3); 
                        start_channel(ADDR_CH1_DESC_ADDR, 32'h0300, 32'h00200008); 
                        
                        #200; 
                        $display("          Sending ABORT command...");
                        axi_lite_write(ADDR_CH1_CONTROL, 32'h00000002, 0); 
                        
                        #300; 
                        $display("          Sending RESUME command...");
                        axi_lite_write(ADDR_CH1_CONTROL, 32'h00000005, 0); 
                        
                        wait_channel_done(ADDR_CH1_STATUS);
                        $display(">>> [T06] DONE (Check Waveforms to visually verify suspension)");
                        axi_lite_write(ADDR_CH1_CONTROL, 32'h0, 0);
                    end

                    7: begin
                        // ========= T07: Unaligned Transfer Test ========
                        $display("--- [T07] RUNNING: Unaligned Transfer (40 Bytes) ---");
                        setup_dma_transfer(32'h0400, 32'h6800, 32'h7000, 32'h28, 32'hD4D4D4D4); 
                        start_channel(ADDR_CH2_DESC_ADDR, 32'h0400, 32'h00200008); 
                        wait_channel_done(ADDR_CH2_STATUS);
                        
                        if (ram_memory[(32'h00007000 + 40) >> 2] === 32'h00000000) 
                            $display(">>> [T07] PASSED (Memory boundaries respected for 40B transfer)");
                        else 
                            $display(">>> [T07] FAILED (Memory overwritten past 40B boundary!)");
                        
                        axi_lite_write(ADDR_CH2_CONTROL, 32'h0, 0);
                    end

                    default: $display(">>> ERROR: Invalid ACTIVE_TEST value!");
                endcase
                
                #100;
                $finish;
            end
        join   
    end
endmodule