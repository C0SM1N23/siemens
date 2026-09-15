// Behavioral AXI4-Lite slave with internal memory: testbench only, stands in for
// interconnect + slave in one.
//
// Address in [BASE, BASE + WORDS*4) -> OKAY (WSTRB lanes), anything else DECERR.
//
// Knobs: READ_LAT/WRITE_LAT are wait cycles before RVALID/BVALID (exercise the
// multi-cycle AXI stalls); STALL_PROB > 0 is seeded random backpressure (READYs
// drop at the given rate, responses pick up 0..3 extra waits) to shake out
// timing assumptions a fixed latency wouldn't hit; same SEED = same run.

`timescale 1ns / 1ps

module axi_lite_mem_model #(
    parameter WORDS      = 1024,
    parameter BASE       = 32'h0000_0000,
    parameter INIT_FILE  = "",
    parameter READ_LAT   = 0,              // extra cycles AR -> RVALID
    parameter WRITE_LAT  = 0,              // extra cycles AW+W -> BVALID
    parameter STALL_PROB = 0,              // % chance per cycle to hold a READY low
    parameter SEED       = 1
) (
    input clk_i,
    input rst_n_i,

    input      [31:0] awaddr_i,
    input             awvalid_i,
    output            awready_o,
    input      [31:0] wdata_i,
    input      [ 3:0] wstrb_i,
    input             wvalid_i,
    output            wready_o,
    output reg [ 1:0] bresp_o,
    output reg        bvalid_o,
    input             bready_i,

    input      [31:0] araddr_i,
    input             arvalid_i,
    output            arready_o,
    output reg [31:0] rdata_o,
    output reg [ 1:0] rresp_o,
    output reg        rvalid_o,
    input             rready_i
);

    reg [31:0] mem[0:WORDS-1];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    // Tested as an unsigned offset from BASE rather than as a pair of compares:
    // with BASE = 0 the lower bound (addr >= BASE) is constant-true, and an address
    // below BASE simply wraps the subtraction to a huge value that fails the span.
    localparam [31:0] SPAN = WORDS * 4;

    function in_range;
        input [31:0] addr;
        reg [31:0] off;
        begin
            off      = addr - BASE;
            in_range = (off < SPAN);
        end
    endfunction

    // random backpressure (deterministic per SEED). rseed is seeded in an initial
    // block because $random needs it before the first edge; the stall flops are
    // reset so the model, like the RTL, holds no X out of reset.
    integer rseed;
    wire ar_stall, aw_stall, w_stall;
    initial rseed = SEED;

    function do_stall;
        input dummy;
        do_stall = (STALL_PROB > 0) && (($random(rseed) & 32'h7FFFFFFF) % 100 < STALL_PROB);
    endfunction

    function integer rand_wait;
        input integer base_wait;
        rand_wait = base_wait + ((STALL_PROB > 0) ? (($random(rseed) & 32'h7FFFFFFF) % 4) : 0);
    endfunction

    function [2:0] next_stalls;
        input dummy;
        reg ar, aw, w;
        begin
            ar          = do_stall(0);
            aw          = do_stall(0);
            w           = do_stall(0);
            next_stalls = {ar, aw, w};
        end
    endfunction
    reg [2:0] stalls;
    assign ar_stall = stalls[2];
    assign aw_stall = stalls[1];
    assign w_stall  = stalls[0];
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) stalls <= 3'b0;
        else stalls <= next_stalls(0);
    end

    // read channel. With READ_LAT=0 and no backpressure this is a true latency-1
    // memory: a new AR is accepted in the same cycle the R beat drains, data one
    // cycle later, the case the CPU's back-to-back fetch claim is stated for
    // (1 instr/cycle). Any latency/stall setting falls back to the
    // one-at-a-time path.
    reg rd_busy;
    reg [31:0] rd_addr;
    integer rd_wait;

    wire ar_hs = arvalid_i && arready_o;
    wire r_hs = rvalid_o && rready_i;
    wire fast_read = READ_LAT == 0 && STALL_PROB == 0;
    wire read_reply = (ar_hs && fast_read) || (!ar_hs && rd_busy && !rvalid_o && rd_wait <= 0);
    wire [31:0] reply_addr = ar_hs ? araddr_i : rd_addr;
    assign arready_o = (!rd_busy || r_hs) && !ar_stall;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rd_busy <= 0;
        else if (ar_hs) rd_busy <= 1;
        else if (r_hs) rd_busy <= 0;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rvalid_o <= 0;
        else if (read_reply) rvalid_o <= 1;
        else if (r_hs) rvalid_o <= 0;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rresp_o <= 0;
        else if (read_reply) rresp_o <= in_range(reply_addr) ? 2'b00 : 2'b11;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rdata_o <= 0;
        else if (read_reply)
            rdata_o <= in_range(reply_addr) ? mem[(reply_addr-BASE)>>2] : 32'hDEC0_DEC0;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rd_wait <= 0;
        else if (ar_hs) rd_wait <= rand_wait(READ_LAT);
        else if (rd_busy && !rvalid_o && rd_wait > 0) rd_wait <= rd_wait - 1;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) rd_addr <= 0;
        else if (ar_hs) rd_addr <= araddr_i;
    end

    // Write collection, delay, byte update and response.
    reg aw_got, w_got;
    reg [31:0] wr_addr, wr_data;
    reg     [3:0] wr_strb;
    integer       wr_wait;
    wire          aw_hs = awvalid_i && awready_o;
    wire          w_hs = wvalid_i && wready_o;
    wire          b_hs = bvalid_o && bready_i;
    wire          write_reply = aw_got && w_got && !bvalid_o && wr_wait <= 0;
    assign awready_o = !aw_got && !bvalid_o && !aw_stall;
    assign wready_o  = !w_got && !bvalid_o && !w_stall;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) aw_got <= 0;
        else if (b_hs) aw_got <= 0;
        else if (aw_hs) aw_got <= 1;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) w_got <= 0;
        else if (b_hs) w_got <= 0;
        else if (w_hs) w_got <= 1;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) bvalid_o <= 0;
        else if (b_hs) bvalid_o <= 0;
        else if (write_reply) bvalid_o <= 1;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) bresp_o <= 0;
        else if (write_reply) bresp_o <= in_range(wr_addr) ? 2'b00 : 2'b11;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_wait <= 0;
        else if (aw_hs) wr_wait <= rand_wait(WRITE_LAT);
        else if (aw_got && w_got && !bvalid_o && wr_wait > 0) wr_wait <= wr_wait - 1;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_addr <= 0;
        else if (aw_hs) wr_addr <= awaddr_i;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_data <= 0;
        else if (w_hs) wr_data <= wdata_i;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_strb <= 0;
        else if (w_hs) wr_strb <= wstrb_i;
    end
    always @(posedge clk_i) begin
        if (rst_n_i && write_reply && in_range(wr_addr)) begin
            if (wr_strb[0]) mem[(wr_addr-BASE)>>2][7:0] <= wr_data[7:0];
            if (wr_strb[1]) mem[(wr_addr-BASE)>>2][15:8] <= wr_data[15:8];
            if (wr_strb[2]) mem[(wr_addr-BASE)>>2][23:16] <= wr_data[23:16];
            if (wr_strb[3]) mem[(wr_addr-BASE)>>2][31:24] <= wr_data[31:24];
        end
    end
endmodule
