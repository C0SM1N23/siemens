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

    reg         clk;
    reg         rst_n;

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

    reg  [31:0] read_val;
    integer fd;             // File descriptor (ID-ul fisierului)
    integer scan_result;    // Verifica daca s-a citit corect linia
    reg [8*8-1:0] cmd;      // String pentru comanda ("W", "R", "D") - max 8 caractere
    reg [31:0] addr_arg;    // Argumentul 1 din fisier (Adresa sau Timp)
    reg [31:0] data_arg;    // Argumentul 2 din fisier (Date)

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    mc_dma_top u_dma (
        .clk(clk),
        .rst_n(rst_n),
        //Citire
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_rready(s_axi_rready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rresp(s_axi_rresp),
        //Scriere
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_awready(s_axi_awready),
        .s_axi_wready(s_axi_wready),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bresp(s_axi_bresp)
    );

    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            
            s_axi_wdata   = data;
            s_axi_wstrb   = 4'hF;
            s_axi_wvalid  = 1'b1;

            fork
                begin
                    while(~s_axi_awready) 
                        @(posedge clk);
                    @(posedge clk);
                    s_axi_awvalid = 1'b0;
                end
                begin
                    while(~s_axi_wready) 
                        @(posedge clk);
                    @(posedge clk);
                    s_axi_wvalid = 1'b0;
                end
            join

            s_axi_bready = 1'b1;
            while(~s_axi_bvalid) 
                @(posedge clk);
            @(posedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task axi_read;
        input  [31:0] addr;
        output [31:0] data_out; 
        begin
            s_axi_araddr = addr;
            s_axi_arvalid = 1'b1;
            while(~s_axi_arready) 
                @(posedge clk);
            @(posedge clk);
            s_axi_arvalid = 1'b0;

            s_axi_rready = 1'b1;
            while(~s_axi_rvalid) 
                @(posedge clk);
            data_out = s_axi_rdata; 
            @(posedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        s_axi_arvalid = 1'b0;
        s_axi_rready = 1'b0;
        s_axi_araddr = 32'h0;

        s_axi_awvalid = 1'b0;
        s_axi_wvalid  = 1'b0;
        s_axi_bready  = 1'b0;
        s_axi_awaddr  = 32'h0;
        s_axi_wdata   = 32'h0;
        s_axi_wstrb   = 4'h0;
            
        #161;
        rst_n = 1'b1;
        #27;

        fd = $fopen("/home/andrei/Documents/practica_siemens/DMA/debug/sim/test.txt", "r");
        if (fd == 0) begin
            $display("ERR: Nu exista test.txt!");
            $finish;
        end

        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%s %h %h\n", cmd, addr_arg, data_arg);
            if (scan_result > 0) begin
                case (cmd)
                    "W": begin
                        $display("[%0t] WRITE -> Addr: %h, Data: %h", $time, addr_arg, data_arg);
                        axi_write(addr_arg, data_arg);
                    end
                    
                    "R": begin
                        $display("[%0t] READ  -> Addr: %h", $time, addr_arg);
                        axi_read(addr_arg, read_val);
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

    /*
        //Faza de scriere
        axi_write(ADDR_CH0_BW_CAP, 32'hA5A5A5A5);
        $display("[%0t] Am scris valoarea.", $time);

        #20;

        //Faza de citire
        axi_read(ADDR_CH0_BW_CAP, read_val);
        $display("[%0t] Am citit data: %h", $time, read_val);
    */
        #50;
        $finish;
    end
endmodule