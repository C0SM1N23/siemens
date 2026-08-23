// Behavioral AXI4-Lite slave with internal memory: testbench only, stands in for
// interconnect + slave in one.
//
// Address in [BASE, BASE + WORDS*4) -> OKAY (WSTRB lanes), anything else DECERR.
//
// Knobs: READ_LAT/WRITE_LAT are wait cycles before RVALID/BVALID (exercise the
// multi-cycle AXI stalls); STALL_PROB > 0 is seeded random backpressure (READYs
// drop at the given rate, responses pick up 0..3 extra waits) to shake out
// timing assumptions a fixed latency wouldn't hit; same SEED = same run.

`timescale 1ns/1ps

module axi_lite_mem_model #(
    parameter WORDS      = 1024,
    parameter BASE       = 32'h0000_0000,
    parameter INIT_FILE  = "",
    parameter READ_LAT   = 0,     // extra cycles AR -> RVALID
    parameter WRITE_LAT  = 0,     // extra cycles AW+W -> BVALID
    parameter STALL_PROB = 0,     // % chance per cycle to hold a READY low
    parameter SEED       = 1
)(
    input             clk_i,
    input             rst_n_i,

    input      [31:0] awaddr_i,
    input             awvalid_i,
    output            awready_o,
    input      [31:0] wdata_i,
    input      [3:0]  wstrb_i,
    input             wvalid_i,
    output            wready_o,
    output reg [1:0]  bresp_o,
    output reg        bvalid_o,
    input             bready_i,

    input      [31:0] araddr_i,
    input             arvalid_i,
    output            arready_o,
    output reg [31:0] rdata_o,
    output reg [1:0]  rresp_o,
    output reg        rvalid_o,
    input             rready_i
);

reg [31:0] mem [0:WORDS-1];

initial begin
    if (INIT_FILE != "")
        $readmemh(INIT_FILE, mem);
end

// Tested as an unsigned offset from BASE rather than as a pair of compares:
// with BASE = 0 the lower bound (addr >= BASE) is constant-true, and an address
// below BASE simply wraps the subtraction to a huge value that fails the span.
localparam [31:0] SPAN = WORDS*4;

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
reg ar_stall, aw_stall, w_stall;
initial rseed = SEED;

function do_stall;
    input dummy;
    do_stall = (STALL_PROB > 0) && (($random(rseed) & 32'h7FFFFFFF) % 100 < STALL_PROB);
endfunction

function integer rand_wait;
    input integer base_wait;
    rand_wait = base_wait + ((STALL_PROB > 0) ? (($random(rseed) & 32'h7FFFFFFF) % 4) : 0);
endfunction

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        ar_stall <= 1'b0;
        aw_stall <= 1'b0;
        w_stall  <= 1'b0;
    end else begin
        ar_stall <= do_stall(0);
        aw_stall <= do_stall(0);
        w_stall  <= do_stall(0);
    end
end

// read channel. With READ_LAT=0 and no backpressure this is a true latency-1
// memory: a new AR is accepted in the same cycle the R beat drains, data one
// cycle later, the case the CPU's back-to-back fetch claim is stated for
// (1 instr/cycle). Any latency/stall setting falls back to the
// one-at-a-time path.
reg        rd_busy;
reg [31:0] rd_addr;
integer    rd_wait;

task read_resp;
    input [31:0] a;
    begin
        if (in_range(a)) begin
            rdata_o <= mem[(a - BASE) >> 2];
            rresp_o <= 2'b00;                               // OKAY
        end else begin
            rdata_o <= 32'hDEC0_DEC0;
            rresp_o <= 2'b11;                               // DECERR
        end
    end
endtask

assign arready_o = (!rd_busy || (rvalid_o && rready_i)) && !ar_stall;

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        rd_busy <= 0; rvalid_o <= 0; rresp_o <= 2'b00; rdata_o <= 32'b0; rd_wait <= 0;
        rd_addr <= 32'b0;
    end else begin
        if (arvalid_i && arready_o) begin
            rd_busy <= 1;
            rd_addr <= araddr_i;
            rd_wait <= rand_wait(READ_LAT);
            if (READ_LAT == 0 && STALL_PROB == 0) begin
                read_resp(araddr_i);                        // data next cycle
                rvalid_o <= 1;
            end else if (rvalid_o && rready_i)
                rvalid_o <= 0;                              // new txn waits its turn
        end else begin
            if (rvalid_o && rready_i) begin
                rvalid_o  <= 0;
                rd_busy <= 0;
            end
            if (rd_busy && !rvalid_o) begin
                if (rd_wait > 0)
                    rd_wait <= rd_wait - 1;
                else begin
                    rvalid_o <= 1;
                    read_resp(rd_addr);
                end
            end
        end
    end
end

// write channel: AW and W captured independently, response after both
reg        aw_got, w_got;
reg [31:0] wr_addr, wr_data;
reg [3:0]  wr_strb;
integer    wr_wait;

assign awready_o = !aw_got && !bvalid_o && !aw_stall;
assign wready_o  = !w_got  && !bvalid_o && !w_stall;

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        aw_got <= 0; w_got <= 0; bvalid_o <= 0; bresp_o <= 2'b00; wr_wait <= 0;
        wr_addr <= 32'b0; wr_data <= 32'b0; wr_strb <= 4'b0;
    end else begin
        if (awvalid_i && awready_o) begin
            aw_got  <= 1;
            wr_addr <= awaddr_i;
            wr_wait <= rand_wait(WRITE_LAT);
        end
        if (wvalid_i && wready_o) begin
            w_got   <= 1;
            wr_data <= wdata_i;
            wr_strb <= wstrb_i;
        end
        if (aw_got && w_got && !bvalid_o) begin
            if (wr_wait > 0)
                wr_wait <= wr_wait - 1;
            else begin
                bvalid_o <= 1;
                if (in_range(wr_addr)) begin
                    bresp_o <= 2'b00;
                    if (wr_strb[0]) mem[(wr_addr-BASE)>>2][7:0]   <= wr_data[7:0];
                    if (wr_strb[1]) mem[(wr_addr-BASE)>>2][15:8]  <= wr_data[15:8];
                    if (wr_strb[2]) mem[(wr_addr-BASE)>>2][23:16] <= wr_data[23:16];
                    if (wr_strb[3]) mem[(wr_addr-BASE)>>2][31:24] <= wr_data[31:24];
                end else
                    bresp_o <= 2'b11;                       // DECERR
            end
        end
        if (bvalid_o && bready_i) begin
            bvalid_o <= 0;
            aw_got <= 0;
            w_got  <= 0;
        end
    end
end

endmodule
