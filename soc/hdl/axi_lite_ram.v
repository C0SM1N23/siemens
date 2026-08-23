// AXI4-Lite RAM slave: the SoC's instruction and data memories.
//
// Written the way an on-chip block RAM behaves - synchronous, byte enables,
// contents loaded from a hex image at time zero - so the SoC is a complete,
// self-contained design rather than something that only elaborates with a
// behavioural memory model bolted on in a testbench.
//
// The array is zeroed before the image is loaded. That is not cosmetic. The
// CPU reads memory it has not written (a load from a fresh stack slot, the
// DMA fetching a descriptor field the program never set) and an X returned on
// RDATA propagates straight into the register file, from there into an
// address, and the failure surfaces hundreds of cycles later somewhere
// unrelated. Starting from a defined zero keeps a failure where it happened.
//
// Reads and writes run as independent one-deep channels, which is how a
// true dual-port block RAM behaves and what lets a read and a write overlap.
// Each channel holds one transaction at a time - enough for every master in
// this SoC, all of which are one-outstanding.
//
// TIMING CONTROLS - VERIFICATION ONLY
// READ_LAT, WRITE_LAT, STALL_PROB and SEED exist so the regression can run the
// same SoC against a slow or stalling memory without touching the design. A
// fabric that only works when every slave answers in one cycle is a fabric
// that has not been tested, and these are the cheapest way to find out.
//
// They must stay at their defaults for synthesis, and at those defaults this
// module is exactly the RAM it was before they existed: STALL_PROB = 0 removes
// the backpressure generator from the elaborated design entirely (it is inside
// a generate), and with both latencies at 0 the wait counters are never
// loaded, so they fold away. Nothing on the functional path is conditional on
// them.
//
//   READ_LAT    extra cycles between the AR handshake and RVALID
//   WRITE_LAT   extra cycles between the write landing and BVALID
//   STALL_PROB  percent chance per cycle of holding a READY low
//   SEED        makes a STALL_PROB run repeatable

`timescale 1ns/1ps

module axi_lite_ram #(
    parameter integer WORDS      = 2048, // depth in 32-bit words
    parameter         INIT_FILE  = "",   // optional $readmemh image, "" = none
    parameter integer READ_LAT   = 0,    // verification only, see the header
    parameter integer WRITE_LAT  = 0,
    parameter integer STALL_PROB = 0,
    parameter integer SEED       = 1
)(
    input             clk_i,
    input             rst_n_i,

    input      [31:0] s_awaddr_i,
    input      [2:0]  s_awprot_i,
    input             s_awvalid_i,
    output            s_awready_o,
    input      [31:0] s_wdata_i,
    input      [3:0]  s_wstrb_i,
    input             s_wvalid_i,
    output            s_wready_o,
    output     [1:0]  s_bresp_o,
    output            s_bvalid_o,
    input             s_bready_i,
    input      [31:0] s_araddr_i,
    input      [2:0]  s_arprot_i,
    input             s_arvalid_i,
    output            s_arready_o,
    output     [31:0] s_rdata_o,
    output     [1:0]  s_rresp_o,
    output            s_rvalid_o,
    input             s_rready_i
);

localparam integer AW        = $clog2(WORDS);
localparam [1:0]   RESP_OKAY = 2'b00;

reg [31:0] mem [0:WORDS-1];

integer ii;
initial begin
    for (ii = 0; ii < WORDS; ii = ii + 1)
        mem[ii] = 32'h0000_0000;
    if (INIT_FILE != "")
        $readmemh(INIT_FILE, mem);
end

// ---------------------------------------------------------------------------
// backpressure generator (absent unless STALL_PROB > 0)
// ---------------------------------------------------------------------------
wire ar_stall, aw_stall, w_stall;

generate
if (STALL_PROB > 0) begin : g_backpressure
    integer rseed;
    reg     ar_stall_q, aw_stall_q, w_stall_q;

    initial rseed = SEED;

    // one draw per channel per cycle, so the three READYs stall independently
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            ar_stall_q <= 1'b0;
            aw_stall_q <= 1'b0;
            w_stall_q  <= 1'b0;
        end else begin
            ar_stall_q <= (($random(rseed) & 32'h7FFF_FFFF) % 100) < STALL_PROB;
            aw_stall_q <= (($random(rseed) & 32'h7FFF_FFFF) % 100) < STALL_PROB;
            w_stall_q  <= (($random(rseed) & 32'h7FFF_FFFF) % 100) < STALL_PROB;
        end
    end

    assign ar_stall = ar_stall_q;
    assign aw_stall = aw_stall_q;
    assign w_stall  = w_stall_q;
end else begin : g_no_backpressure
    assign ar_stall = 1'b0;
    assign aw_stall = 1'b0;
    assign w_stall  = 1'b0;
end
endgenerate

// ---------------------------------------------------------------------------
// write channel
// ---------------------------------------------------------------------------
reg        aw_q, w_q, bvalid_q;
reg [31:0] awaddr_q, wdata_q;
reg [3:0]  wstrb_q;

reg [15:0] wr_cnt_q;      // counts out WRITE_LAT before BVALID
reg        wr_wait_q;

assign s_awready_o = ~aw_q & ~bvalid_q & ~wr_wait_q & ~aw_stall;
assign s_wready_o  = ~w_q  & ~bvalid_q & ~wr_wait_q & ~w_stall;
assign s_bvalid_o  = bvalid_q;
assign s_bresp_o   = RESP_OKAY;   // every address in the window is backed by RAM

wire aw_hs = s_awvalid_i & s_awready_o;
wire w_hs  = s_wvalid_i  & s_wready_o;

// "both halves of the write are in hand", counting a handshake landing now:
// AW and W arriving together must complete in one cycle, not two
wire aw_ok = aw_q | aw_hs;
wire w_ok  = w_q  | w_hs;
wire do_write = aw_ok & w_ok & ~bvalid_q;

wire [31:0] wr_addr = aw_q ? awaddr_q : s_awaddr_i;
wire [31:0] wr_data = w_q  ? wdata_q  : s_wdata_i;
wire [3:0]  wr_strb = w_q  ? wstrb_q  : s_wstrb_i;
wire [AW-1:0] wr_idx = wr_addr[AW+1:2];

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        aw_q     <= 1'b0;
        w_q      <= 1'b0;
        awaddr_q <= 32'h0;
        wdata_q  <= 32'h0;
        wstrb_q  <= 4'h0;
    end else begin
        if (aw_hs) awaddr_q <= s_awaddr_i;
        if (w_hs)  begin wdata_q <= s_wdata_i; wstrb_q <= s_wstrb_i; end

        if (do_write) begin
            // consumed by the write issued this cycle
            aw_q <= 1'b0;
            w_q  <= 1'b0;
        end else begin
            if (aw_hs) aw_q <= 1'b1;
            if (w_hs)  w_q  <= 1'b1;
        end
    end
end

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        bvalid_q  <= 1'b0;
        wr_wait_q <= 1'b0;
        wr_cnt_q  <= 16'd0;
    end else if (bvalid_q) begin
        if (s_bready_i) bvalid_q <= 1'b0;
    end else if (wr_wait_q) begin
        if (wr_cnt_q <= 16'd1) begin
            wr_wait_q <= 1'b0;
            bvalid_q  <= 1'b1;
        end else begin
            wr_cnt_q <= wr_cnt_q - 16'd1;
        end
    end else if (do_write) begin
        if (WRITE_LAT == 0) begin
            bvalid_q <= 1'b1;
        end else begin
            wr_wait_q <= 1'b1;
            wr_cnt_q  <= WRITE_LAT[15:0];
        end
    end
end

always @(posedge clk_i) begin
    if (do_write) begin
        if (wr_strb[0]) mem[wr_idx][7:0]   <= wr_data[7:0];
        if (wr_strb[1]) mem[wr_idx][15:8]  <= wr_data[15:8];
        if (wr_strb[2]) mem[wr_idx][23:16] <= wr_data[23:16];
        if (wr_strb[3]) mem[wr_idx][31:24] <= wr_data[31:24];
    end
end

// ---------------------------------------------------------------------------
// read channel
// ---------------------------------------------------------------------------
reg        rvalid_q;
reg [31:0] rdata_q;

reg [15:0] rd_cnt_q;      // counts out READ_LAT before RVALID
reg        rd_wait_q;

assign s_arready_o = ~rvalid_q & ~rd_wait_q & ~ar_stall;
assign s_rvalid_o  = rvalid_q;
assign s_rdata_o   = rdata_q;
assign s_rresp_o   = RESP_OKAY;

wire ar_hs = s_arvalid_i & s_arready_o;
wire [AW-1:0] rd_idx = s_araddr_i[AW+1:2];

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        rvalid_q  <= 1'b0;
        rdata_q   <= 32'h0;
        rd_wait_q <= 1'b0;
        rd_cnt_q  <= 16'd0;
    end else if (ar_hs) begin
        // the data is captured at the handshake either way; only the moment it
        // is offered moves
        rdata_q <= mem[rd_idx];
        if (READ_LAT == 0) begin
            rvalid_q <= 1'b1;
        end else begin
            rd_wait_q <= 1'b1;
            rd_cnt_q  <= READ_LAT[15:0];
        end
    end else if (rd_wait_q) begin
        if (rd_cnt_q <= 16'd1) begin
            rd_wait_q <= 1'b0;
            rvalid_q  <= 1'b1;
        end else begin
            rd_cnt_q <= rd_cnt_q - 16'd1;
        end
    end else if (rvalid_q && s_rready_i) begin
        rvalid_q <= 1'b0;
    end
end

endmodule
