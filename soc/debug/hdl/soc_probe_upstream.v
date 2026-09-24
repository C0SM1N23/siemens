// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// Diagnostic observations for TO_MODIFY.md; excluded from the passing regression.
// Exercises upstream RTL through its ports without changing it.
`timescale 1ns / 1ps
module soc_probe_upstream;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;
    reg [31:0] control = 0;
    reg [31:0] bandwidth = 32'hFFFF0010;
    reg grant = 0, done = 0, fetch_valid = 0;
    reg     [31:0] fetch_data = 0;
    wire           request;
    wire    [ 7:0] request_len;
    wire    [31:0] status;
    integer        length;
    integer        word_index;
    integer        lengths        [0:5];
    reg     [ 7:0] fetch_len;

    mc_dma_channel dma (
        .clk_i             (clk),
        .rst_ni            (rst_n),
        .desc_addr_i       (32'h2000),
        .control_i         (control),
        .bw_cap_i          (bandwidth),
        .status_o          (status),
        .irq_o             (),
        .req_valid_o       (request),
        .req_addr_o        (),
        .req_len_o         (request_len),
        .req_is_write_o    (),
        .arb_gnt_i         (grant),
        .burst_done_i      (done),
        .axi_error_i       (1'b0),
        .fetch_data_i      (fetch_data),
        .fetch_data_valid_i(fetch_valid)
    );

    wire [31:0] bank_read;
    wire        bank_error;
    dp_sram_regfile #(
        .WINDOW_CYCLES(2048)
    ) bank (
        .clk_i                (clk),
        .rst_n_i              (rst_n),
        .a_reg_valid_i        (1'b1),
        .a_reg_addr_i         (3'd7),
        .a_reg_write_i        (1'b0),
        .a_reg_wdata_i        (32'b0),
        .a_reg_wstrb_i        (4'b0),
        .a_reg_rdata_o        (bank_read),
        .a_reg_error_o        (bank_error),
        .b_reg_valid_i        (1'b0),
        .b_reg_addr_i         (3'b0),
        .b_reg_write_i        (1'b0),
        .b_reg_wdata_i        (32'b0),
        .b_reg_wstrb_i        (4'b0),
        .b_reg_rdata_o        (),
        .b_reg_error_o        (),
        .a_mem_valid_i        (1'b1),
        .b_mem_valid_i        (1'b0),
        .collision_event_i    (1'b0),
        .cooldown_event_i     (1'b0),
        .force_priority_o     (),
        .collision_threshold_o(),
        .cooldown_cycles_o    (),
        .irq_o                ()
    );

    // Serve the channel's descriptor fetch: source 0x2100, destination 0x40000020,
    // the given length and control word, then four unused words.
    task serve_fetch;
        input [31:0] len;
        input [31:0] ctrl;
        begin
            wait (request);
            fetch_len = request_len;
            @(posedge clk);
            #1;
            grant = 1;
            @(posedge clk);
            #1;
            grant = 0;
            for (word_index = 0; word_index < 8; word_index = word_index + 1) begin
                fetch_valid = 1;
                case (word_index)
                    0:       fetch_data = 32'h2100;
                    1:       fetch_data = 32'h40000020;
                    2:       fetch_data = len;
                    3:       fetch_data = ctrl;
                    default: fetch_data = 0;
                endcase
                @(posedge clk);
                #1;
            end
            fetch_valid = 0;
            done        = 1;
            @(posedge clk);
            #1;
            done = 0;
        end
    endtask

    // Reset the channel, enable it and serve its descriptor fetch.
    task start_channel;
        input [31:0] len;
        input [31:0] ctrl;
        begin
            @(posedge clk);
            #1;
            rst_n   = 0;
            control = 0;
            repeat (3) begin
                @(posedge clk);
                #1;
            end
            rst_n   = 1;
            control = 1;
            serve_fetch(len, ctrl);
        end
    endtask

    // Wait for the channel's next request, grant it and complete its burst at once.
    task serve_burst;
        begin
            wait (request);
            @(posedge clk);
            #1;
            grant = 1;
            @(posedge clk);
            #1;
            grant = 0;
            done  = 1;
            @(posedge clk);
            #1;
            done = 0;
        end
    endtask

    initial begin
        lengths[0] = 0;
        lengths[1] = 1;
        lengths[2] = 2;
        lengths[3] = 3;
        lengths[4] = 5;
        lengths[5] = 22;
        for (length = 0; length < 6; length = length + 1) begin
            start_channel(lengths[length], 1);
            $display("OBSERVE DMA bytes=%0d ARLEN=%0d transfer_bytes=%0d", lengths[length],
                     request_len, (int'(request_len) + 1) * 4);
        end
        $display("OBSERVE DMA descriptor fetch ARLEN=%0d: %0d words read, 4 used", fetch_len,
                 int'(fetch_len) + 1);

        // Descriptor control word 0: the 32 bytes are copied, then the channel
        // stays ACTIVE and starts another block with the length at zero.
        start_channel(32, 0);
        serve_burst;  // read burst
        serve_burst;  // write burst
        $display("OBSERVE DMA control=0 bytes=32: state after the copy=%0d, next ARLEN=%0d at 0x%08h",
                 dma.state, request_len, dma.req_addr_o);
        serve_burst;  // 256-beat read
        serve_burst;  // 256-beat write
        $display("OBSERVE DMA control=0 bytes=32: after the next block state=%0d, write to 0x%08h, next ARLEN=%0d",
                 dma.state, dma.desc_dst - 32'd32, request_len);

        // Abort after the first 32 of 64 bytes, then resume: the channel fetches
        // the descriptor again and restarts from the first source word.
        start_channel(64, 1);
        serve_burst;  // read of bytes 0..31
        control = 32'h3;  // enable + abort, taken when the write burst completes
        serve_burst;  // write of bytes 0..31
        $display("OBSERVE DMA abort after 32 of 64 bytes: state=%0d", dma.state);
        control = 32'h5;  // enable + resume
        serve_fetch(64, 1);
        $display("OBSERVE DMA resume: descriptor fetched again, next read from 0x%08h", dma.req_addr_o);
        serve_burst;  // read
        $display("OBSERVE DMA resume: next write to 0x%08h", dma.req_addr_o);

        @(posedge clk);
        #1;
        rst_n     = 0;
        control   = 0;
        bandwidth = 32'hFFFF9C40;
        repeat (3) begin
            @(posedge clk);
            #1;
        end
        rst_n = 1;
        repeat (100) begin
            @(posedge clk);
            #1;
        end
        $display("OBSERVE DMA tokens after refill 1=%0d", dma.token_bucket);
        repeat (100) begin
            @(posedge clk);
            #1;
        end
        $display("OBSERVE DMA tokens after refill 2=%0d (saturating result: 65535)",
                 dma.token_bucket);
        repeat (4000) begin
            @(posedge clk);
            #1;
        end
        $display("OBSERVE SRAM window=2048 BANDWIDTH_A=%0d", bank.bandwidth_a_reg);
        $display("OBSERVE SRAM undefined word=7 read=%08h error=%b", bank_read, bank_error);
        $display("UPSTREAM PROBE COMPLETE");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "upstream probe timeout");
    end
endmodule
