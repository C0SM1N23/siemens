// Behavioral AXI4-Lite slave with internal memory — testbench only, not
// part of the CPU. Stands in for interconnect + slave in one.
//
// Behavior:
// - address in [BASE, BASE + WORDS*4) -> OKAY, memory access (WSTRB lanes)
// - anything else                     -> DECERR (unmapped address)
//
// Knobs, and why they exist:
// - READ_LAT / WRITE_LAT: wait cycles before RVALID / BVALID — exercises
//   the pipeline's multi-cycle AXI stalls
// - STALL_PROB > 0: seeded random backpressure — READYs drop out with the
//   given percentage and responses pick up 0..3 extra wait cycles, which
//   shakes out timing assumptions no fixed latency would hit
// - same SEED = same run, so a failure always reproduces

module axi_lite_mem_model #(
    parameter WORDS      = 1024,
    parameter BASE       = 32'h0000_0000,
    parameter INIT_FILE  = "",
    parameter READ_LAT   = 0,     // extra cycles AR -> RVALID
    parameter WRITE_LAT  = 0,     // extra cycles AW+W -> BVALID
    parameter STALL_PROB = 0,     // % chance per cycle to hold a READY low
    parameter SEED       = 1
)(
    input             clk,
    input             rst_n,

    input      [31:0] awaddr,
    input             awvalid,
    output            awready,
    input      [31:0] wdata,
    input      [3:0]  wstrb,
    input             wvalid,
    output            wready,
    output reg [1:0]  bresp,
    output reg        bvalid,
    input             bready,

    input      [31:0] araddr,
    input             arvalid,
    output            arready,
    output reg [31:0] rdata,
    output reg [1:0]  rresp,
    output reg        rvalid,
    input             rready
);

reg [31:0] mem [0:WORDS-1];

initial begin
    if (INIT_FILE != "")
        $readmemh(INIT_FILE, mem);
end

function in_range;
    input [31:0] addr;
    in_range = (addr >= BASE) && (addr < BASE + WORDS*4);
endfunction

// random backpressure (deterministic per SEED)
integer rseed;
reg ar_stall, aw_stall, w_stall;
initial begin
    rseed = SEED;
    ar_stall = 0; aw_stall = 0; w_stall = 0;
end

function do_stall;
    input dummy;
    do_stall = (STALL_PROB > 0) && (($random(rseed) & 32'h7FFFFFFF) % 100 < STALL_PROB);
endfunction

function integer rand_wait;
    input integer base_wait;
    rand_wait = base_wait + ((STALL_PROB > 0) ? (($random(rseed) & 32'h7FFFFFFF) % 4) : 0);
endfunction

always @(posedge clk) begin
    ar_stall <= do_stall(0);
    aw_stall <= do_stall(0);
    w_stall  <= do_stall(0);
end

// read channel. With READ_LAT=0 and no backpressure this is a true latency-1
// memory: a new AR is accepted in the same cycle the R beat drains, data one
// cycle later — the case the CPU's back-to-back fetch claim is stated for
// (1 instr/cycle). Any latency/stall setting falls back to the
// one-at-a-time path.
reg        rd_busy;
reg [31:0] rd_addr;
integer    rd_wait;

task read_resp;
    input [31:0] a;
    begin
        if (in_range(a)) begin
            rdata <= mem[(a - BASE) >> 2];
            rresp <= 2'b00;                               // OKAY
        end else begin
            rdata <= 32'hDEC0_DEC0;
            rresp <= 2'b11;                               // DECERR
        end
    end
endtask

assign arready = (!rd_busy || (rvalid && rready)) && !ar_stall;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        rd_busy <= 0; rvalid <= 0; rresp <= 2'b00; rdata <= 32'b0; rd_wait <= 0;
    end else begin
        if (arvalid && arready) begin
            rd_busy <= 1;
            rd_addr <= araddr;
            rd_wait <= rand_wait(READ_LAT);
            if (READ_LAT == 0 && STALL_PROB == 0) begin
                read_resp(araddr);                        // data next cycle
                rvalid <= 1;
            end else if (rvalid && rready)
                rvalid <= 0;                              // new txn waits its turn
        end else begin
            if (rvalid && rready) begin
                rvalid  <= 0;
                rd_busy <= 0;
            end
            if (rd_busy && !rvalid) begin
                if (rd_wait > 0)
                    rd_wait <= rd_wait - 1;
                else begin
                    rvalid <= 1;
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

assign awready = !aw_got && !bvalid && !aw_stall;
assign wready  = !w_got  && !bvalid && !w_stall;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        aw_got <= 0; w_got <= 0; bvalid <= 0; bresp <= 2'b00; wr_wait <= 0;
    end else begin
        if (awvalid && awready) begin
            aw_got  <= 1;
            wr_addr <= awaddr;
            wr_wait <= rand_wait(WRITE_LAT);
        end
        if (wvalid && wready) begin
            w_got   <= 1;
            wr_data <= wdata;
            wr_strb <= wstrb;
        end
        if (aw_got && w_got && !bvalid) begin
            if (wr_wait > 0)
                wr_wait <= wr_wait - 1;
            else begin
                bvalid <= 1;
                if (in_range(wr_addr)) begin
                    bresp <= 2'b00;
                    if (wr_strb[0]) mem[(wr_addr-BASE)>>2][7:0]   <= wr_data[7:0];
                    if (wr_strb[1]) mem[(wr_addr-BASE)>>2][15:8]  <= wr_data[15:8];
                    if (wr_strb[2]) mem[(wr_addr-BASE)>>2][23:16] <= wr_data[23:16];
                    if (wr_strb[3]) mem[(wr_addr-BASE)>>2][31:24] <= wr_data[31:24];
                end else
                    bresp <= 2'b11;                       // DECERR
            end
        end
        if (bvalid && bready) begin
            bvalid <= 0;
            aw_got <= 0;
            w_got  <= 0;
        end
    end
end

endmodule
