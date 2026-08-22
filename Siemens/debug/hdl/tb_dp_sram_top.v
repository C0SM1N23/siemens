
`timescale 1ns/1ps

module tb_dp_sram_top;

    reg clk, rst_n;

    reg  [9:0]  a_awaddr;  
    reg a_awvalid; 
    wire a_awready;
    reg  [31:0] a_wdata;   
    reg [3:0] a_wstrb; 
    reg a_wvalid; 
    wire a_wready;
    wire [1:0]  a_bresp;   
    wire a_bvalid;
    reg a_bready;
    reg  [9:0]  a_araddr;
    reg a_arvalid;
    wire a_arready;
    wire [31:0] a_rdata;   
    wire [1:0] a_rresp; 
    wire a_rvalid; 
    reg a_rready;

    reg  [9:0]  b_awaddr;  
    reg b_awvalid; 
    wire b_awready;
    reg  [31:0] b_wdata;   
    reg [3:0] b_wstrb; 
    reg b_wvalid; 
    wire b_wready;
    wire [1:0]  b_bresp;   
    wire b_bvalid; 
    reg b_bready;
    reg  [9:0]  b_araddr;  
    reg b_arvalid; 
    wire b_arready;
    wire [31:0] b_rdata;  
    wire [1:0] b_rresp; 
    wire b_rvalid; 
    reg b_rready;

    wire irq;

    dp_sram_top dut (
        .clk_i(clk), 
        .rst_n_i(rst_n),
        .a_awaddr_i(a_awaddr), 
        .a_awvalid_i(a_awvalid), 
        .a_awready_o(a_awready),
        .a_wdata_i(a_wdata), 
        .a_wstrb_i(a_wstrb), 
        .a_wvalid_i(a_wvalid), 
        .a_wready_o(a_wready),
        .a_bresp_o(a_bresp), 
        .a_bvalid_o(a_bvalid), 
        .a_bready_i(a_bready),
        .a_araddr_i(a_araddr), 
        .a_arvalid_i(a_arvalid), 
        .a_arready_o(a_arready),
        .a_rdata_o(a_rdata), 
        .a_rresp_o(a_rresp), 
        .a_rvalid_o(a_rvalid), 
        .a_rready_i(a_rready),
        .b_awaddr_i(b_awaddr), 
        .b_awvalid_i(b_awvalid), 
        .b_awready_o(b_awready),
        .b_wdata_i(b_wdata), 
        .b_wstrb_i(b_wstrb), 
        .b_wvalid_i(b_wvalid), 
        .b_wready_o(b_wready),
        .b_bresp_o(b_bresp), 
        .b_bvalid_o(b_bvalid), 
        .b_bready_i(b_bready),
        .b_araddr_i(b_araddr), 
        .b_arvalid_i(b_arvalid), 
        .b_arready_o(b_arready),
        .b_rdata_o(b_rdata), 
        .b_rresp_o(b_rresp), 
        .b_rvalid_o(b_rvalid), 
        .b_rready_i(b_rready),
        .irq_o(irq)
    );

   //10ns period
    always #5 clk = ~clk;

    integer pass_count;
    integer fail_count;
    integer line_num;

    function [31:0] str_to_hex;
        input [8*16-1:0] s;
        reg   [31:0] v;
        reg   [31:0] n;
        begin
            v = 32'd0;
            n = $sscanf(s, "%h", v);
            str_to_hex = v;
        end
    endfunction

    function [31:0] str_to_dec;
        input [8*16-1:0] s;
        reg   [31:0] v;
        reg   [31:0] n;
        begin
            v = 32'd0;
            n = $sscanf(s, "%d", v);
            str_to_dec = v;
        end
    endfunction

    function [9:0] str_to_addr;
        input [8*16-1:0] s;
        reg   [31:0] v;
        begin
            v = str_to_hex(s);
            str_to_addr = v[9:0];
        end
    endfunction

    task report_check;
        input [31:0]      actual;
        input [31:0]      expected;
        input [8*48-1:0]  label;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("[PASS] linia %0d (%0s): asteptat=0x%08h, obtinut=0x%08h",
                          line_num, label, expected, actual);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] linia %0d (%0s): asteptat=0x%08h, obtinut=0x%08h",
                          line_num, label, expected, actual);
            end
        end
    endtask


    task do_reset;
        begin
            rst_n = 1'b0;
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);
            rst_n <= 1'b1;
        end
    endtask


    task do_write;
        input [8*16-1:0] port;
        input [9:0]      addr;
        input [31:0]     data;
        reg   [1:0] resp;
        begin
            if (port == "A") begin
                a_awvalid = 1'b1; a_awaddr = addr;
                a_wvalid  = 1'b1; a_wdata  = data; a_wstrb = 4'hF;
                a_bready  = 1'b1;
            end else begin
                b_awvalid = 1'b1; b_awaddr = addr;
                b_wvalid  = 1'b1; b_wdata  = data; b_wstrb = 4'hF;
                b_bready  = 1'b1;
            end

            @(posedge clk);
            if (port == "A") while (!a_awready) @(posedge clk);
            else              while (!b_awready) @(posedge clk);

            if (port == "A") begin a_awvalid <= 1'b0; a_wvalid <= 1'b0; end
            else              begin b_awvalid <= 1'b0; b_wvalid <= 1'b0; end

            @(posedge clk);
            if (port == "A") begin resp = a_bresp; a_bready <= 1'b0; end
            else              begin resp = b_bresp; b_bready <= 1'b0; end

            report_check({30'd0, resp}, {30'd0, 2'b00}, "WRITE: raspuns OKAY");
        end
    endtask


    task do_read;
        input [8*16-1:0] port;
        input [9:0]      addr;
        input [31:0]     expected;
        reg   [31:0] actual;
        reg   [1:0]  resp;
        begin
            if (port == "A") begin
                a_arvalid = 1'b1; a_araddr = addr; a_rready = 1'b1;
            end else begin
                b_arvalid = 1'b1; b_araddr = addr; b_rready = 1'b1;
            end

            @(posedge clk);
            if (port == "A") while (!a_arready) @(posedge clk);
            else              while (!b_arready) @(posedge clk);

            if (port == "A") a_arvalid <= 1'b0;
            else              b_arvalid <= 1'b0;

            @(posedge clk);
            if (port == "A") begin actual = a_rdata; resp = a_rresp; a_rready <= 1'b0; end
            else              begin actual = b_rdata; resp = b_rresp; b_rready <= 1'b0; end

            report_check({30'd0, resp}, {30'd0, 2'b00}, "READ: raspuns OKAY");
            report_check(actual, expected, "READ: date corecte");
        end
    endtask


    task do_wwconflict;
        input [9:0]      addr;
        input [31:0]     data_a;
        input [31:0]     data_b;
        input [8*16-1:0] winner;
        reg [1:0]  resp_a, resp_b;
        reg [31:0] readback;
        begin
            a_awvalid = 1'b1; a_awaddr = addr; a_wvalid = 1'b1; a_wdata = data_a; a_wstrb = 4'hF; a_bready = 1'b1;
            b_awvalid = 1'b1; b_awaddr = addr; b_wvalid = 1'b1; b_wdata = data_b; b_wstrb = 4'hF; b_bready = 1'b1;

            fork
                begin
                    @(posedge clk);
                    while (!a_awready) @(posedge clk);
                    a_awvalid <= 1'b0; a_wvalid <= 1'b0;
                end
                begin
                    @(posedge clk);
                    while (!b_awready) @(posedge clk);
                    b_awvalid <= 1'b0; b_wvalid <= 1'b0;
                end
            join

            @(posedge clk);
            resp_a = a_bresp; a_bready <= 1'b0;
            resp_b = b_bresp; b_bready <= 1'b0;

            if (winner == "A") begin
                report_check({30'd0, resp_a}, {30'd0, 2'b00}, "WWCONFLICT: A castigator -> OKAY");
                report_check({30'd0, resp_b}, {30'd0, 2'b10}, "WWCONFLICT: B pierzator -> SLVERR");
            end else begin
                report_check({30'd0, resp_b}, {30'd0, 2'b00}, "WWCONFLICT: B castigator -> OKAY");
                report_check({30'd0, resp_a}, {30'd0, 2'b10}, "WWCONFLICT: A pierzator -> SLVERR");
            end

            a_arvalid = 1'b1; a_araddr = addr; a_rready = 1'b1;
            @(posedge clk);
            while (!a_arready) @(posedge clk);
            a_arvalid <= 1'b0;
            @(posedge clk);
            readback = a_rdata;
            a_rready <= 1'b0;

            report_check(readback, (winner == "A") ? data_a : data_b, "WWCONFLICT: memoria are data castigatorului");
        end
    endtask


    task do_rwconflict;
        input [9:0]      addr;
        input [8*16-1:0] writer;
        input [31:0]     data;
        reg [1:0] resp_writer, resp_reader;
        begin
            if (writer == "A") begin
                a_awvalid = 1'b1; a_awaddr = addr; a_wvalid = 1'b1; a_wdata = data; a_wstrb = 4'hF; a_bready = 1'b1;
                b_arvalid = 1'b1; b_araddr = addr; b_rready = 1'b1;
            end else begin
                b_awvalid = 1'b1; b_awaddr = addr; b_wvalid = 1'b1; b_wdata = data; b_wstrb = 4'hF; b_bready = 1'b1;
                a_arvalid = 1'b1; a_araddr = addr; a_rready = 1'b1;
            end

            fork
                begin
                    @(posedge clk);
                    if (writer == "A") begin
                        while (!a_awready) @(posedge clk);
                        a_awvalid <= 1'b0; a_wvalid <= 1'b0;
                    end else begin
                        while (!b_awready) @(posedge clk);
                        b_awvalid <= 1'b0; b_wvalid <= 1'b0;
                    end
                end
                begin
                    @(posedge clk);
                    if (writer == "A") begin
                        while (!b_arready) @(posedge clk);
                        b_arvalid <= 1'b0;
                    end else begin
                        while (!a_arready) @(posedge clk);
                        a_arvalid <= 1'b0;
                    end
                end
            join

            @(posedge clk);
            if (writer == "A") begin
                resp_writer = a_bresp; a_bready <= 1'b0;
                resp_reader = b_rresp; b_rready <= 1'b0;
            end else begin
                resp_writer = b_bresp; b_bready <= 1'b0;
                resp_reader = a_rresp; a_rready <= 1'b0;
            end

            report_check({30'd0, resp_writer}, {30'd0, 2'b00}, "RWCONFLICT: scriitorul -> OKAY");
            report_check({30'd0, resp_reader}, {30'd0, 2'b10}, "RWCONFLICT: cititorul -> SLVERR");
        end
    endtask


    task do_wait;
        input [31:0] cycles;
        integer i;
        begin
            for (i = 0; i < cycles; i = i + 1) @(posedge clk);
        end
    endtask


    task do_checkirq;
        input [31:0] expected;
        reg   [31:0] actual;
        begin
            @(posedge clk);
            actual = {31'd0, irq};
            report_check(actual, expected, "CHECKIRQ");
        end
    endtask


    integer fd;
    integer fgets_ret;
    integer scan_count;
    reg [8*256-1:0] line;
    reg [8*16-1:0]  cmd;
    reg [8*16-1:0]  arg1;
    reg [8*16-1:0]  arg2;
    reg [8*16-1:0]  arg3;
    reg [8*16-1:0]  arg4;

    initial begin
        #100000;
        $display("EROARE: TIMEOUT -- simularea nu s-a terminat, probabil un while(!ready) blocat undeva mai sus");
        $finish;
    end

    initial begin
        $dumpfile("tb_dp_sram_top.vcd");
        $dumpvars(0, tb_dp_sram_top);

        clk = 1'b0;
        rst_n = 1'b1;
        a_awaddr=0; 
        a_awvalid=0; 
        a_wdata=0; 
        a_wstrb=0; 
        a_wvalid=0; 
        a_bready=0;
        a_araddr=0; 
        a_arvalid=0; 
        a_rready=0;

        b_awaddr=0; 
        b_awvalid=0;
        b_wdata=0; 
        b_wstrb=0; 
        b_wvalid=0; 
        b_bready=0;
        b_araddr=0; 
        b_arvalid=0; 
        b_rready=0;

        pass_count = 0;
        fail_count = 0;
        line_num   = 0;

        fd = $fopen("dp_sram_top_test_vectors.txt", "r");
        if (fd == 0) begin
            $display("EROARE: nu pot deschide dp_sram_top_test_vectors.txt");
            $finish;
        end

        while (!$feof(fd)) begin
            cmd = 0; arg1 = 0; arg2 = 0; arg3 = 0; arg4 = 0; line = 0;
            fgets_ret = $fgets(line, fd);
            if (fgets_ret > 0) begin
                line_num = line_num + 1;
                scan_count = $sscanf(line, "%s %s %s %s %s", cmd, arg1, arg2, arg3, arg4);

                if (scan_count < 1) begin
                    //empty line
                end
                else begin
                    @(posedge clk);
                    if (cmd == "REM") begin
                        // comment
                    end
                    else if (cmd == "RESET") begin
                        do_reset;
                    end
                    else if (cmd == "WRITE") begin
                        do_write(arg1, str_to_addr(arg2), str_to_hex(arg3));
                    end
                    else if (cmd == "READ") begin
                        do_read(arg1, str_to_addr(arg2), str_to_hex(arg3));
                    end
                    else if (cmd == "WWCONFLICT") begin
                        do_wwconflict(str_to_addr(arg1), str_to_hex(arg2), str_to_hex(arg3), arg4);
                    end
                    else if (cmd == "RWCONFLICT") begin
                        do_rwconflict(str_to_addr(arg1), arg2, str_to_hex(arg3));
                    end
                    else if (cmd == "WAIT") begin
                        do_wait(str_to_dec(arg1));
                    end
                    else if (cmd == "CHECKIRQ") begin
                        do_checkirq(str_to_dec(arg1));
                    end
                    else begin
                        $display("  EROARE linia %0d: comanda necunoscuta '%s'", line_num, cmd);
                    end
                end
            end
        end

        $fclose(fd);

        $display("Rezultate: %0d PASS, %0d FAIL din %0d verificari", pass_count, fail_count, pass_count + fail_count);
        if (fail_count == 0)
            $display("TOATE TESTELE AU TRECUT");
        else
            $display("EXISTA TESTE PICATE");

        $finish;
    end

endmodule
