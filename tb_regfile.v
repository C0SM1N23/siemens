`timescale 1ns/1ps

module tb_regfile;

    // Fereastra de bandwidth redusa
    localparam WINDOW_CYCLES_TB = 16;

    reg         clk;
    reg         rst_n;

    reg         a_reg_valid;
    reg  [2:0]  a_reg_addr;
    reg         a_reg_write;
    reg  [31:0] a_reg_wdata;
    wire [31:0] a_reg_rdata;

    reg         b_reg_valid;
    reg  [2:0]  b_reg_addr;
    reg         b_reg_write;
    reg  [31:0] b_reg_wdata;
    wire [31:0] b_reg_rdata;

    reg         collision_event;
    reg         cooldown_event;

    reg         a_mem_valid;
    reg         b_mem_valid;

    wire        force_priority;
    wire [7:0]  collision_threshold;
    wire [7:0]  cooldown_cycles;
    wire        irq;

    regfile #(
        .REG_ADDR_W(3),
        .WINDOW_CYCLES(WINDOW_CYCLES_TB)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .a_reg_valid(a_reg_valid), .a_reg_addr(a_reg_addr), .a_reg_write(a_reg_write),
        .a_reg_wdata(a_reg_wdata), .a_reg_rdata(a_reg_rdata),
        .b_reg_valid(b_reg_valid), .b_reg_addr(b_reg_addr), .b_reg_write(b_reg_write),
        .b_reg_wdata(b_reg_wdata), .b_reg_rdata(b_reg_rdata),
        .collision_event(collision_event), .cooldown_event(cooldown_event),
        .a_mem_valid(a_mem_valid), .b_mem_valid(b_mem_valid),
        .force_priority(force_priority),
        .collision_threshold(collision_threshold),
        .cooldown_cycles(cooldown_cycles),
        .irq(irq)
    );

    always #5 clk = ~clk;

    integer pass_count;
    integer fail_count;
    integer line_num;

    
    function [2:0] reg_name_to_addr;
        input [8*16-1:0] name;
        begin
            if (name == "STATUS")        reg_name_to_addr = 3'd0;
            else if (name == "ENABLE")   reg_name_to_addr = 3'd1;
            else if (name == "PRIORITY") reg_name_to_addr = 3'd2;
            else if (name == "BWA")      reg_name_to_addr = 3'd3;
            else if (name == "BWB")      reg_name_to_addr = 3'd4;
            else if (name == "THRESH")   reg_name_to_addr = 3'd5;
            else if (name == "COOLD")    reg_name_to_addr = 3'd6;
            else begin
                $display("  EROARE linia %0d: nume de registru necunoscut '%s'", line_num, name);
                reg_name_to_addr = 3'd0;
            end
        end
    endfunction

    
    
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

    
    task report_check;
        input [31:0]      actual;
        input [31:0]      expected;
        input [8*40-1:0]  label;
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
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

   
    task do_write;
        input [8*16-1:0] port;
        input [8*16-1:0] reg_name;
        input [31:0]     value;
        reg   [2:0] addr;
        begin
            addr = reg_name_to_addr(reg_name);
            @(negedge clk);
            if (port == "A") begin
                a_reg_valid = 1'b1; a_reg_write = 1'b1; a_reg_addr = addr; a_reg_wdata = value;
            end else begin
                b_reg_valid = 1'b1; b_reg_write = 1'b1; b_reg_addr = addr; b_reg_wdata = value;
            end
            @(negedge clk);
            if (port == "A") begin
                a_reg_valid = 1'b0; a_reg_write = 1'b0;
            end else begin
                b_reg_valid = 1'b0; b_reg_write = 1'b0;
            end
        end
    endtask

    
    task do_read;
        input [8*16-1:0] port;
        input [8*16-1:0] reg_name;
        input [31:0]     expected;
        reg   [2:0]  addr;
        reg   [31:0] actual;
        begin
            addr = reg_name_to_addr(reg_name);
            @(negedge clk);
            if (port == "A") begin
                a_reg_valid = 1'b1; a_reg_write = 1'b0; a_reg_addr = addr;
            end else begin
                b_reg_valid = 1'b1; b_reg_write = 1'b0; b_reg_addr = addr;
            end
            #1; //astept un tact pentru valoare stabila
            actual = (port == "A") ? a_reg_rdata : b_reg_rdata;
            report_check(actual, expected, "READ");
            @(negedge clk);
            if (port == "A") a_reg_valid = 1'b0;
            else              b_reg_valid = 1'b0;
        end
    endtask


    task do_conflict;
        input [8*16-1:0] reg_name;
        input [31:0]     val_a;
        input [31:0]     val_b;
        reg   [2:0]  addr;
        reg   [31:0] actual;
        begin
            addr = reg_name_to_addr(reg_name);
            @(negedge clk);
            a_reg_valid = 1'b1; a_reg_write = 1'b1; a_reg_addr = addr; a_reg_wdata = val_a;
            b_reg_valid = 1'b1; b_reg_write = 1'b1; b_reg_addr = addr; b_reg_wdata = val_b;
            @(negedge clk);
            a_reg_valid = 1'b0; a_reg_write = 1'b0;
            b_reg_valid = 1'b0; b_reg_write = 1'b0;
            a_reg_valid = 1'b1; a_reg_addr = addr;
            #1;
            actual = a_reg_rdata;
            report_check(actual, val_a, "CONFLICT (Port A trebuie sa castige)");
            @(negedge clk);
            a_reg_valid = 1'b0;
        end
    endtask


    task do_event;
        input [8*16-1:0] kind;
        begin
            @(negedge clk);
            if (kind == "col")     collision_event = 1'b1;
            else if (kind == "cd") cooldown_event  = 1'b1;
            else $display("  EROARE linia %0d: tip de eveniment necunoscut '%s'", line_num, kind);
            @(negedge clk);
            collision_event = 1'b0;
            cooldown_event  = 1'b0;
        end
    endtask


    task do_activity;
        input [8*16-1:0] port;
        input [31:0]     cycles;
        integer i;
        begin
            for (i = 0; i < cycles; i = i + 1) begin
                @(negedge clk);
                if (port == "A") a_mem_valid = 1'b1;
                else              b_mem_valid = 1'b1;
            end
            @(negedge clk);
            a_mem_valid = 1'b0;
            b_mem_valid = 1'b0;
        end
    endtask


    task do_wait;
        input [31:0] cycles;
        integer i;
        begin
            for (i = 0; i < cycles; i = i + 1) @(posedge clk);
        end
    endtask


    task do_checkout;
        input [8*16-1:0] signal_name;
        input [31:0]     expected;
        reg   [31:0] actual;
        begin
            #1;
            if (signal_name == "irq")      actual = {31'd0, irq};
            else if (signal_name == "fp")  actual = {31'd0, force_priority};
            else if (signal_name == "th")  actual = {24'd0, collision_threshold};
            else if (signal_name == "cd")  actual = {24'd0, cooldown_cycles};
            else begin
                $display("  EROARE linia %0d: semnal necunoscut pentru CHECKOUT '%s'", line_num, signal_name);
                actual = 32'hFFFF_FFFF;
            end
            report_check(actual, expected, "CHECKOUT");
        end
    endtask


    // loop
    integer fd;
    integer fgets_ret;
    integer scan_count;
    reg [8*256-1:0] line;
    reg [8*16-1:0]  cmd;
    reg [8*16-1:0]  arg1;
    reg [8*16-1:0]  arg2;
    reg [8*16-1:0]  arg3;

    initial begin
        $dumpfile("tb_regfile.vcd");
        $dumpvars(0, tb_regfile);

        clk = 1'b0;
        rst_n = 1'b1;
        a_reg_valid = 1'b0; a_reg_addr = 3'd0; a_reg_write = 1'b0; a_reg_wdata = 32'd0;
        b_reg_valid = 1'b0; b_reg_addr = 3'd0; b_reg_write = 1'b0; b_reg_wdata = 32'd0;
        collision_event = 1'b0; cooldown_event = 1'b0;
        a_mem_valid = 1'b0; b_mem_valid = 1'b0;

        pass_count = 0;
        fail_count = 0;
        line_num   = 0;

        fd = $fopen("regfile_test_vectors.txt", "r");
        if (fd == 0) begin
            $display("EROARE: nu pot deschide regfile_test_vectors.txt");
            $finish;
        end

        while (!$feof(fd)) begin
            cmd = 0; arg1 = 0; arg2 = 0; arg3 = 0; line = 0;
            fgets_ret = $fgets(line, fd);
            if (fgets_ret > 0) begin
                line_num = line_num + 1;
                scan_count = $sscanf(line, "%s %s %s %s", cmd, arg1, arg2, arg3);

                if (scan_count < 1) begin
                    // linie goala
                end
                else if (cmd == "REM") begin
                    // comentariu
                end
                else if (cmd == "RESET") begin
                    do_reset;
                end
                else if (cmd == "WRITE") begin
                    do_write(arg1, arg2, str_to_hex(arg3));
                end
                else if (cmd == "READ") begin
                    do_read(arg1, arg2, str_to_hex(arg3));
                end
                else if (cmd == "CONFLICT") begin
                    do_conflict(arg1, str_to_hex(arg2), str_to_hex(arg3));
                end
                else if (cmd == "EVENT") begin
                    do_event(arg1);
                end
                else if (cmd == "ACTIVITY") begin
                    do_activity(arg1, str_to_dec(arg2));
                end
                else if (cmd == "WAIT") begin
                    do_wait(str_to_dec(arg1));
                end
                else if (cmd == "CHECKOUT") begin
                    do_checkout(arg1, str_to_hex(arg2));
                end
                else begin
                    $display("  EROARE linia %0d: comanda necunoscuta '%s'", line_num, cmd);
                end
            end
        end

        $fclose(fd);

        $display("=================================================");
        $display("Rezultate: %0d PASS, %0d FAIL din %0d verificari", pass_count, fail_count, pass_count + fail_count);
        $display("=================================================");
        if (fail_count == 0)
            $display("TOATE TESTELE AU TRECUT");
        else
            $display("EXISTA TESTE PICATE");

        $finish;
    end

endmodule
