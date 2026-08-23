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

`timescale 1ns/1ps

module axi_lite_ram #(
    parameter integer WORDS     = 2048,  // depth in 32-bit words
    parameter         INIT_FILE = ""     // optional $readmemh image, "" = none
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
// write channel
// ---------------------------------------------------------------------------
reg        aw_q, w_q, bvalid_q;
reg [31:0] awaddr_q, wdata_q;
reg [3:0]  wstrb_q;

assign s_awready_o = ~aw_q & ~bvalid_q;
assign s_wready_o  = ~w_q  & ~bvalid_q;
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
    if (~rst_n_i)
        bvalid_q <= 1'b0;
    else if (bvalid_q && s_bready_i)
        bvalid_q <= 1'b0;
    else if (do_write)
        bvalid_q <= 1'b1;
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

assign s_arready_o = ~rvalid_q;
assign s_rvalid_o  = rvalid_q;
assign s_rdata_o   = rdata_q;
assign s_rresp_o   = RESP_OKAY;

wire ar_hs = s_arvalid_i & s_arready_o;
wire [AW-1:0] rd_idx = s_araddr_i[AW+1:2];

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        rvalid_q <= 1'b0;
        rdata_q  <= 32'h0;
    end else begin
        if (ar_hs) begin
            rdata_q  <= mem[rd_idx];
            rvalid_q <= 1'b1;
        end else if (rvalid_q && s_rready_i) begin
            rvalid_q <= 1'b0;
        end
    end
end

endmodule
