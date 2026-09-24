// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// A fixed AXI4-Lite master sequence, as a module rather than a task.
//
// It exists so that two different interconnects can be driven by *the same*
// stimulus by construction rather than by two copies of a bench that are
// supposed to match. One instance is tied to each implementation under
// comparison; both run this sequence, and what is compared afterwards is the
// record each one collected.
//
// The sequence is written around the case the comparison is for: a request
// offered while the response to the previous one is still sitting on the
// master port unread. A decoder with one route and no back-pressure re-points
// that route and answers from the wrong slave; one that refuses the request
// until the response is taken does not.
//
// Records are held in flat vectors rather than unpacked arrays so the bench can
// read them out of a port on either simulator.

module soc_lite_seq_master #(
    parameter [31:0] ADDR_A   = 32'h0000_0000,
    parameter [31:0] ADDR_B   = 32'h0000_1000,
    parameter integer MAX_REC = 16,
    // After the fixed sequence, this many random transactions drawn from
    // +pulp_seed=N. The draws depend only on the seed, never on timing, so two
    // instances with the same seed issue the same sequence.
    parameter integer RANDOM_TXNS = 0
) (
    input clk_i,
    input rst_n_i,
    input start_i,

    output reg done_o,

    output reg [31:0] awaddr_o,
    output reg        awvalid_o,
    input             awready_i,
    output reg [31:0] wdata_o,
    output reg [ 3:0] wstrb_o,
    output reg        wvalid_o,
    input             wready_i,
    input      [ 1:0] bresp_i,
    input             bvalid_i,
    output reg        bready_o,
    output reg [31:0] araddr_o,
    output reg        arvalid_o,
    input             arready_i,
    input      [31:0] rdata_i,
    input      [ 1:0] rresp_i,
    input             rvalid_i,
    output reg        rready_o,

    // what happened, in the order it happened
    output reg [           31:0] rec_count_o,
    output reg [  MAX_REC*2-1:0] rec_kind_o,  // 0 = read, 1 = write
    output reg [ MAX_REC*32-1:0] rec_data_o,
    output reg [  MAX_REC*2-1:0] rec_resp_o
);

    localparam [1:0] KIND_READ = 2'd0, KIND_WRITE = 2'd1;

    task record(input [1:0] kind, input [31:0] data, input [1:0] resp);
        begin
            rec_kind_o[rec_count_o*2+:2]  = kind;
            rec_data_o[rec_count_o*32+:32] = data;
            rec_resp_o[rec_count_o*2+:2]  = resp;
            rec_count_o                    = rec_count_o + 32'd1;
        end
    endtask

    // Address phase only: leave the response on the port for the caller to take.
    task issue_read(input [31:0] a);
        begin
            @(posedge clk_i);
            #1;
            araddr_o  = a;
            arvalid_o = 1'b1;
            @(posedge clk_i);
            while (!arready_i) @(posedge clk_i);
            #1;
            arvalid_o = 1'b0;
        end
    endtask

    task take_read;
        begin
            @(posedge clk_i);
            #1;
            rready_o = 1'b1;
            @(posedge clk_i);
            while (!rvalid_i) @(posedge clk_i);
            record(KIND_READ, rdata_i, rresp_i);
            #1;
            rready_o = 1'b0;
        end
    endtask

    task issue_write(input [31:0] a, input [31:0] d, input w_first, input integer skew);
        begin
            @(posedge clk_i);
            #1;
            awaddr_o = a;
            wdata_o  = d;
            wstrb_o  = 4'hF;
            if (w_first) wvalid_o = 1'b1;
            else awvalid_o = 1'b1;
            fork
                begin
                    repeat (skew) begin
                        @(posedge clk_i);
                        #1;
                    end
                    if (w_first) awvalid_o = 1'b1;
                    else wvalid_o = 1'b1;
                end
                begin
                    @(posedge clk_i);
                    while (!(awvalid_o && awready_i)) @(posedge clk_i);
                    #1;
                    awvalid_o = 1'b0;
                end
                begin
                    @(posedge clk_i);
                    while (!(wvalid_o && wready_i)) @(posedge clk_i);
                    #1;
                    wvalid_o = 1'b0;
                end
            join
        end
    endtask

    task take_write;
        begin
            @(posedge clk_i);
            #1;
            bready_o = 1'b1;
            @(posedge clk_i);
            while (!bvalid_i) @(posedge clk_i);
            record(KIND_WRITE, 32'h0, bresp_i);
            #1;
            bready_o = 1'b0;
        end
    endtask

    // +verbose traces where the sequence got to, which is what a comparison
    // that hangs needs first
    task step(input [511:0] name);
        if ($test$plusargs("verbose")) $display("[%0t] %m: %0s", $time, name);
    endtask

    initial begin
        done_o      = 1'b0;
        awaddr_o    = 32'h0;
        awvalid_o   = 1'b0;
        wdata_o     = 32'h0;
        wstrb_o     = 4'h0;
        wvalid_o    = 1'b0;
        bready_o    = 1'b0;
        araddr_o    = 32'h0;
        arvalid_o   = 1'b0;
        rready_o    = 1'b0;
        rec_count_o = 32'd0;
        rec_kind_o  = {MAX_REC * 2{1'b0}};
        rec_data_o  = {MAX_REC * 32{1'b0}};
        rec_resp_o  = {MAX_REC * 2{1'b0}};

        wait (rst_n_i === 1'b1);
        wait (start_i === 1'b1);
        repeat (2) @(posedge clk_i);

        // 1-2: plain reads of each slave, responses taken as they appear
        step("1: read A");
        issue_read(ADDR_A);
        take_read;
        step("2: read B");
        issue_read(ADDR_B);
        take_read;

        // 3: the case the comparison is for. The response to A is left on the
        //    port, a read of B is offered on top of it, and only then is A's
        //    response taken. A's data must still be A's.
        step("3: read A, then offer read B on top of it");
        issue_read(ADDR_A);
        repeat (4) begin
            @(posedge clk_i);
            #1;
        end
        @(posedge clk_i);
        #1;
        araddr_o  = ADDR_B;
        arvalid_o = 1'b1;
        repeat (4) begin
            @(posedge clk_i);
            #1;
        end
        take_read;
        @(posedge clk_i);
        while (!arready_i) @(posedge clk_i);
        #1;
        arvalid_o = 1'b0;
        take_read;

        // 4-5: writes, address first and data first
        step("4: write A, address first");
        issue_write(ADDR_A, 32'hA0A0_0001, 1'b0, 0);
        take_write;
        step("5: write B, data first");
        issue_write(ADDR_B, 32'hB0B0_0002, 1'b1, 3);
        take_write;

        // 6: a write offered while a read response is still unread. The write
        //    channel is independent, so the write may be accepted while the read
        //    response is still waiting - which is why the handshake watchers are
        //    started before the request is offered rather than after the read
        //    response is taken.
        step("6: read B, then offer write A on top of it");
        issue_read(ADDR_B);
        repeat (3) begin
            @(posedge clk_i);
            #1;
        end
        fork
            begin
                @(posedge clk_i);
                #1;
                awaddr_o  = ADDR_A;
                wdata_o   = 32'hC0C0_0003;
                wstrb_o   = 4'hF;
                awvalid_o = 1'b1;
                wvalid_o  = 1'b1;
            end
            begin
                @(posedge clk_i);
                while (!(awvalid_o && awready_i)) @(posedge clk_i);
                #1;
                awvalid_o = 1'b0;
            end
            begin
                @(posedge clk_i);
                while (!(wvalid_o && wready_i)) @(posedge clk_i);
                #1;
                wvalid_o = 1'b0;
            end
            begin
                repeat (3) begin
                    @(posedge clk_i);
                    #1;
                end
                take_read;
            end
        join
        take_write;

        // 7: read each slave once more, so a route left pointing at the wrong
        //    place by anything above shows up here
        step("7: read each slave once more");
        issue_read(ADDR_A);
        take_read;
        issue_read(ADDR_B);
        take_read;

        random_sequence;

        repeat (4) @(posedge clk_i);
        done_o = 1'b1;
    end

    // Random addresses anywhere in the two 4 KiB windows, random data, and the
    // same three shapes as above: a plain transaction, a read offered on top of
    // an unread read response, and a write offered on top of one.
    integer rseed;
    function [31:0] draw;
        input integer n;
        draw = ($random(rseed) & 32'h7FFF_FFFF) % n;
    endfunction
    function [31:0] draw_addr;
        input integer unused;
        draw_addr = (draw(2) ? ADDR_B : ADDR_A) + {draw(1024), 2'b00};
    endfunction

    task random_sequence;
        integer n, shape, gap;
        reg [31:0] a, b, d;
        reg w_first;
        integer skew;
        begin
            if (!$value$plusargs("pulp_seed=%d", rseed)) rseed = 1;
            for (n = 0; n < RANDOM_TXNS; n = n + 1) begin
                shape = draw(4);
                a = draw_addr(0);
                b = draw_addr(0);
                d = $random(rseed);
                w_first = draw(2);
                skew = draw(3);
                gap = 1 + draw(4);
                case (shape)
                    0: begin
                        issue_read(a);
                        take_read;
                    end
                    1: begin
                        issue_write(a, d, w_first, skew);
                        take_write;
                    end
                    2: begin  // a second read offered while the first response waits
                        issue_read(a);
                        repeat (gap) begin
                            @(posedge clk_i);
                            #1;
                        end
                        araddr_o  = b;
                        arvalid_o = 1'b1;
                        repeat (gap) begin
                            @(posedge clk_i);
                            #1;
                        end
                        take_read;
                        @(posedge clk_i);
                        while (!arready_i) @(posedge clk_i);
                        #1;
                        arvalid_o = 1'b0;
                        take_read;
                    end
                    default: begin  // a write offered while a read response waits
                        issue_read(a);
                        repeat (gap) begin
                            @(posedge clk_i);
                            #1;
                        end
                        fork
                            begin
                                awaddr_o  = b;
                                wdata_o   = d;
                                wstrb_o   = 4'hF;
                                awvalid_o = 1'b1;
                                wvalid_o  = 1'b1;
                            end
                            begin
                                @(posedge clk_i);
                                while (!(awvalid_o && awready_i)) @(posedge clk_i);
                                #1;
                                awvalid_o = 1'b0;
                            end
                            begin
                                @(posedge clk_i);
                                while (!(wvalid_o && wready_i)) @(posedge clk_i);
                                #1;
                                wvalid_o = 1'b0;
                            end
                            begin
                                repeat (gap) begin
                                    @(posedge clk_i);
                                    #1;
                                end
                                take_read;
                            end
                        join
                        take_write;
                    end
                endcase
            end
        end
    endtask

endmodule
