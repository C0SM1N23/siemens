// Behavioral AXI4-Lite memory with byte strobes, latency and backpressure controls.
// One buffered request per direction; responses remain valid until accepted.

module soc_axi_lite_ram #(
    parameter integer WORDS      = 2048,  // depth in 32-bit words
    parameter         INIT_FILE  = "",    // optional $readmemh image, "" = none
    parameter integer READ_LAT   = 0,     // verification only, see the header
    parameter integer WRITE_LAT  = 0,
    parameter integer STALL_PROB = 0,
    parameter integer SEED       = 1
) (
    input clk_i,
    input rst_n_i,

    input  [31:0] s_awaddr_i,
    input  [ 2:0] s_awprot_i,
    input         s_awvalid_i,
    output        s_awready_o,
    input  [31:0] s_wdata_i,
    input  [ 3:0] s_wstrb_i,
    input         s_wvalid_i,
    output        s_wready_o,
    output [ 1:0] s_bresp_o,
    output        s_bvalid_o,
    input         s_bready_i,
    input  [31:0] s_araddr_i,
    input  [ 2:0] s_arprot_i,
    input         s_arvalid_i,
    output        s_arready_o,
    output [31:0] s_rdata_o,
    output [ 1:0] s_rresp_o,
    output        s_rvalid_o,
    input         s_rready_i
);

    localparam integer       AW        = $clog2(WORDS);
    localparam         [1:0] RESP_OKAY = 2'b00;

    reg     [31:0] mem[0:WORDS-1];

    integer        ii;
    initial begin
        for (ii = 0; ii < WORDS; ii = ii + 1) mem[ii] = 32'h0000_0000;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    // backpressure generator (absent unless STALL_PROB > 0)
    wire ar_stall, aw_stall, w_stall;

    generate
        if (STALL_PROB > 0) begin : g_backpressure
            integer       rseed;
            reg     [2:0] stall_q;
            initial rseed = SEED;

            function [2:0] next_stalls;
                input unused;
                reg ar, aw, w;
                begin
                    ar          = (($random(rseed) & 32'h7FFF_FFFF) % 100) < STALL_PROB;
                    aw          = (($random(rseed) & 32'h7FFF_FFFF) % 100) < STALL_PROB;
                    w           = (($random(rseed) & 32'h7FFF_FFFF) % 100) < STALL_PROB;
                    next_stalls = {ar, aw, w};
                end
            endfunction

            always @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) stall_q <= 3'b0;
                else stall_q <= next_stalls(1'b0);
            end
            assign ar_stall = stall_q[2];
            assign aw_stall = stall_q[1];
            assign w_stall  = stall_q[0];
        end else begin : g_no_backpressure
            assign ar_stall = 1'b0;
            assign aw_stall = 1'b0;
            assign w_stall  = 1'b0;
        end
    endgenerate

    // write channel
    reg aw_q, w_q, bvalid_q;
    reg [31:0] awaddr_q, wdata_q;
    reg [ 3:0] wstrb_q;

    reg [15:0] wr_cnt_q;  // counts out WRITE_LAT before BVALID
    reg        wr_wait_q;

    assign s_awready_o = ~aw_q & ~bvalid_q & ~wr_wait_q & ~aw_stall;
    assign s_wready_o  = ~w_q & ~bvalid_q & ~wr_wait_q & ~w_stall;
    assign s_bvalid_o  = bvalid_q;
    assign s_bresp_o   = RESP_OKAY;  // every address in the window is backed by RAM

    wire          aw_hs = s_awvalid_i & s_awready_o;
    wire          w_hs = s_wvalid_i & s_wready_o;

    // "both halves of the write are in hand", counting a handshake landing now:
    // AW and W arriving together must complete in one cycle, not two
    wire          aw_ok = aw_q | aw_hs;
    wire          w_ok = w_q | w_hs;
    wire          do_write = aw_ok & w_ok & ~bvalid_q;

    wire [  31:0] wr_addr = aw_q ? awaddr_q : s_awaddr_i;
    wire [  31:0] wr_data = w_q ? wdata_q : s_wdata_i;
    wire [   3:0] wr_strb = w_q ? wstrb_q : s_wstrb_i;
    wire [AW-1:0] wr_idx = wr_addr[AW+1:2];

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) aw_q <= 1'b0;
        else if (do_write) aw_q <= 1'b0;
        else if (aw_hs) aw_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_q <= 1'b0;
        else if (do_write) w_q <= 1'b0;
        else if (w_hs) w_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) awaddr_q <= 32'b0;
        else if (aw_hs) awaddr_q <= s_awaddr_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wdata_q <= 32'b0;
        else if (w_hs) wdata_q <= s_wdata_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wstrb_q <= 4'b0;
        else if (w_hs) wstrb_q <= s_wstrb_i;
    end

    // The latency counter starts when AW and W have both arrived.
    wire write_ready = wr_wait_q && wr_cnt_q <= 16'd1;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) bvalid_q <= 1'b0;
        else if (bvalid_q && s_bready_i) bvalid_q <= 1'b0;
        else if (!bvalid_q && (write_ready || (do_write && WRITE_LAT == 0))) bvalid_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_wait_q <= 1'b0;
        else if (write_ready) wr_wait_q <= 1'b0;
        else if (do_write && WRITE_LAT != 0) wr_wait_q <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_cnt_q <= 16'b0;
        else if (do_write && WRITE_LAT != 0) wr_cnt_q <= WRITE_LAT[15:0];
        else if (wr_wait_q && wr_cnt_q > 16'd1) wr_cnt_q <= wr_cnt_q - 16'd1;
    end

    always @(posedge clk_i) begin
        if (do_write) begin
            if (wr_strb[0]) mem[wr_idx][7:0] <= wr_data[7:0];
            if (wr_strb[1]) mem[wr_idx][15:8] <= wr_data[15:8];
            if (wr_strb[2]) mem[wr_idx][23:16] <= wr_data[23:16];
            if (wr_strb[3]) mem[wr_idx][31:24] <= wr_data[31:24];
        end
    end

    // read channel
    reg        rvalid_q;
    reg [31:0] rdata_q;

    reg [15:0] rd_cnt_q;  // counts out READ_LAT before RVALID
    reg        rd_wait_q;

    assign s_arready_o = ~rvalid_q & ~rd_wait_q & ~ar_stall;
    assign s_rvalid_o  = rvalid_q;
    assign s_rdata_o   = rdata_q;
    assign s_rresp_o   = RESP_OKAY;

    wire          ar_hs = s_arvalid_i & s_arready_o;
    wire [AW-1:0] rd_idx = s_araddr_i[AW+1:2];

    wire          read_ready = rd_wait_q && rd_cnt_q <= 16'd1;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rvalid_q <= 1'b0;
        else if (ar_hs && READ_LAT == 0 || read_ready) rvalid_q <= 1'b1;
        else if (rvalid_q && s_rready_i) rvalid_q <= 1'b0;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rdata_q <= 32'b0;
        else if (ar_hs) rdata_q <= mem[rd_idx];
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rd_wait_q <= 1'b0;
        else if (ar_hs && READ_LAT != 0) rd_wait_q <= 1'b1;
        else if (read_ready) rd_wait_q <= 1'b0;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rd_cnt_q <= 16'b0;
        else if (ar_hs && READ_LAT != 0) rd_cnt_q <= READ_LAT[15:0];
        else if (rd_wait_q && rd_cnt_q > 16'd1) rd_cnt_q <= rd_cnt_q - 16'd1;
    end

endmodule
