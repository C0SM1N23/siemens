// Testbench inputs change 1 ns after posedge; handshakes sample at posedge.
// Constrained-random traffic through the real fabric, against a scoreboard.
//
//   master A (Lite) --> decoder A --+--> arbiter --> shared RAM (random stalls)
//                                   '--> slave SA (errors by address)
//   master B (Full) --> bridge --> decoder B --+--> arbiter
//                                              '--> slave SB (errors by address)
//   Each decoder answers DECERR outside its two windows.
//
// Master A runs a writer and a reader at the same time: AW and W in either order
// or together, random gaps, random BREADY/RREADY delays. Master B runs a burst
// writer and a burst reader at the same time: 1 to 16 beats, INCR or FIXED,
// bursts the bridge must refuse (WRAP, narrow, unaligned), and bursts that run
// off the end of a window. The shared RAM holds its READYs low on 30% of cycles
// and answers one cycle late; the two error slaves stall and answer late at random.
//
// Every response is predicted from the address map and the slaves' error rule,
// every read beat's data from a shadow copy of each memory. The two masters own
// disjoint halves of the shared RAM and never read a word they are still
// writing, so the prediction does not depend on arbitration order. At the end
// the memories must equal their shadows, and each kind of response must have
// occurred on each master.

`timescale 1ns / 1ps

// A slave that answers SLVERR when address bit ERR_BIT is set, with random
// READY and response delays. One transaction outstanding per direction.
module fr_err_slave #(
    parameter integer ERR_BIT = 6,
    parameter integer SEED    = 1
) (
    input clk_i,
    input rst_n_i,
    input [31:0] awaddr_i, input awvalid_i, output awready_o,
    input [31:0] wdata_i, input [3:0] wstrb_i, input wvalid_i, output wready_o,
    output reg [1:0] bresp_o, output reg bvalid_o, input bready_i,
    input [31:0] araddr_i, input arvalid_i, output arready_o,
    output reg [31:0] rdata_o, output reg [1:0] rresp_o, output reg rvalid_o, input rready_i
);
    reg [31:0] mem[0:255];
    integer seed = SEED, i;
    reg aw_q, w_q, stall_aw, stall_w, stall_ar;
    reg [31:0] awaddr_q, wdata_q;
    reg [3:0] wstrb_q;
    reg [2:0] bdelay, rdelay;
    reg rpend;
    reg [31:0] araddr_q;
    initial for (i = 0; i < 256; i = i + 1) mem[i] = 32'h0;

    assign awready_o = !aw_q && !bvalid_o && !stall_aw;
    assign wready_o  = !w_q && !bvalid_o && !stall_w;
    assign arready_o = !rpend && !rvalid_o && !stall_ar;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) {stall_aw, stall_w, stall_ar} <= 3'b0;
        else begin
            stall_aw <= ($random(seed) & 3) == 0;
            stall_w  <= ($random(seed) & 3) == 0;
            stall_ar <= ($random(seed) & 3) == 0;
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            aw_q <= 1'b0; w_q <= 1'b0; bvalid_o <= 1'b0; bresp_o <= 2'b00; bdelay <= 3'd0;
        end else begin
            if (awvalid_i && awready_o) begin aw_q <= 1'b1; awaddr_q <= awaddr_i; end
            if (wvalid_i && wready_o) begin w_q <= 1'b1; wdata_q <= wdata_i; wstrb_q <= wstrb_i; end
            if (aw_q && w_q && !bvalid_o) begin
                if (bdelay == 3'd0) bdelay <= 1 + ($random(seed) & 3);
                else if (bdelay == 3'd1) begin
                    bvalid_o <= 1'b1;
                    bresp_o  <= awaddr_q[ERR_BIT] ? 2'b10 : 2'b00;
                    if (!awaddr_q[ERR_BIT]) begin
                        if (wstrb_q[0]) mem[awaddr_q[9:2]][7:0]   <= wdata_q[7:0];
                        if (wstrb_q[1]) mem[awaddr_q[9:2]][15:8]  <= wdata_q[15:8];
                        if (wstrb_q[2]) mem[awaddr_q[9:2]][23:16] <= wdata_q[23:16];
                        if (wstrb_q[3]) mem[awaddr_q[9:2]][31:24] <= wdata_q[31:24];
                    end
                    aw_q <= 1'b0; w_q <= 1'b0; bdelay <= 3'd0;
                end else bdelay <= bdelay - 3'd1;
            end
            if (bvalid_o && bready_i) bvalid_o <= 1'b0;
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            rpend <= 1'b0; rvalid_o <= 1'b0; rresp_o <= 2'b00; rdata_o <= 32'h0; rdelay <= 3'd0;
        end else begin
            if (arvalid_i && arready_o) begin
                rpend <= 1'b1; araddr_q <= araddr_i; rdelay <= ($random(seed) & 3);
            end else if (rpend && !rvalid_o) begin
                if (rdelay == 3'd0) begin
                    rvalid_o <= 1'b1;
                    rresp_o  <= araddr_q[ERR_BIT] ? 2'b10 : 2'b00;
                    rdata_o  <= araddr_q[ERR_BIT] ? {16'hE0E0, araddr_q[15:0]} : mem[araddr_q[9:2]];
                    rpend    <= 1'b0;
                end else rdelay <= rdelay - 3'd1;
            end
            if (rvalid_o && rready_i) rvalid_o <= 1'b0;
        end
    end
endmodule

module soc_tb_fabric_random;

    integer errors;
    `include "tb_check.vh"

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    localparam [31:0] RAM_BASE = 32'h0000_0000, RAM_MASK = 32'hFFFF_F000;  // 4 KiB, shared
    localparam [31:0] SA_BASE = 32'h1000_0000, SB_BASE = 32'h2000_0000, SX_MASK = 32'hFFFF_FC00;
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10, DECERR = 2'b11;

    integer seed, ntx;

    // ---- master A (Lite) --------------------------------------------------------
    reg [31:0] a_awaddr = 0, a_wdata = 0, a_araddr = 0;
    reg [3:0] a_wstrb = 0;
    reg a_awvalid = 0, a_wvalid = 0, a_bready = 0, a_arvalid = 0, a_rready = 0;
    wire a_awready, a_wready, a_bvalid, a_arready, a_rvalid;
    wire [1:0] a_bresp, a_rresp;
    wire [31:0] a_rdata;

    // ---- master B (Full) --------------------------------------------------------
    reg [31:0] b_awaddr = 0, b_wdata = 0, b_araddr = 0;
    reg [7:0] b_awlen = 0, b_arlen = 0;
    reg [2:0] b_awsize = 2, b_arsize = 2;
    reg [1:0] b_awburst = 1, b_arburst = 1;
    reg [3:0] b_wstrb = 0;
    reg b_awvalid = 0, b_wvalid = 0, b_wlast = 0, b_bready = 0, b_arvalid = 0, b_rready = 0;
    wire b_awready, b_wready, b_bvalid, b_arready, b_rvalid, b_rlast;
    wire [1:0] b_bresp, b_rresp;
    wire [31:0] b_rdata;

    // bridge Lite side
    wire [31:0] bl_awaddr, bl_wdata, bl_araddr, bl_rdata;
    wire [2:0] bl_awprot, bl_arprot;
    wire [3:0] bl_wstrb;
    wire bl_awvalid, bl_awready, bl_wvalid, bl_wready, bl_bvalid, bl_bready;
    wire bl_arvalid, bl_arready, bl_rvalid, bl_rready;
    wire [1:0] bl_bresp, bl_rresp;

    // decoders, two slaves each: 0 = shared RAM (via the arbiter), 1 = own slave
    wire [63:0] da_awaddr, da_wdata, da_araddr, da_rdata, dx_awaddr, dx_wdata, dx_araddr, dx_rdata;
    wire [5:0] da_awprot, da_arprot, dx_awprot, dx_arprot;
    wire [7:0] da_wstrb, dx_wstrb;
    wire [3:0] da_bresp, da_rresp, dx_bresp, dx_rresp;
    wire [1:0] da_awvalid, da_awready, da_wvalid, da_wready, da_bvalid, da_bready;
    wire [1:0] da_arvalid, da_arready, da_rvalid, da_rready;
    wire [1:0] dx_awvalid, dx_awready, dx_wvalid, dx_wready, dx_bvalid, dx_bready;
    wire [1:0] dx_arvalid, dx_arready, dx_rvalid, dx_rready;

    // arbiter to shared RAM
    wire [31:0] r_awaddr, r_wdata, r_araddr, r_rdata;
    wire [2:0] r_awprot, r_arprot;
    wire [3:0] r_wstrb;
    wire [1:0] r_bresp, r_rresp;
    wire r_awvalid, r_awready, r_wvalid, r_wready, r_bvalid, r_bready;
    wire r_arvalid, r_arready, r_rvalid, r_rready;

    soc_axi_lite_dec #(
        .N(2), .BASE({SA_BASE, RAM_BASE}), .MASK({SX_MASK, RAM_MASK})
    ) dec_a (
        .clk_i(clk), .rst_n_i(rst_n),
        .m_awaddr_i(a_awaddr), .m_awprot_i(3'b0), .m_awvalid_i(a_awvalid), .m_awready_o(a_awready),
        .m_wdata_i(a_wdata), .m_wstrb_i(a_wstrb), .m_wvalid_i(a_wvalid), .m_wready_o(a_wready),
        .m_bresp_o(a_bresp), .m_bvalid_o(a_bvalid), .m_bready_i(a_bready),
        .m_araddr_i(a_araddr), .m_arprot_i(3'b0), .m_arvalid_i(a_arvalid), .m_arready_o(a_arready),
        .m_rdata_o(a_rdata), .m_rresp_o(a_rresp), .m_rvalid_o(a_rvalid), .m_rready_i(a_rready),
        .s_awaddr_o(da_awaddr), .s_awprot_o(da_awprot), .s_awvalid_o(da_awvalid), .s_awready_i(da_awready),
        .s_wdata_o(da_wdata), .s_wstrb_o(da_wstrb), .s_wvalid_o(da_wvalid), .s_wready_i(da_wready),
        .s_bresp_i(da_bresp), .s_bvalid_i(da_bvalid), .s_bready_o(da_bready),
        .s_araddr_o(da_araddr), .s_arprot_o(da_arprot), .s_arvalid_o(da_arvalid), .s_arready_i(da_arready),
        .s_rdata_i(da_rdata), .s_rresp_i(da_rresp), .s_rvalid_i(da_rvalid), .s_rready_o(da_rready)
    );

    soc_axi_full2lite bridge (
        .clk_i(clk), .rst_n_i(rst_n),
        .s_awaddr_i(b_awaddr), .s_awlen_i(b_awlen), .s_awsize_i(b_awsize), .s_awburst_i(b_awburst),
        .s_awvalid_i(b_awvalid), .s_awready_o(b_awready),
        .s_wdata_i(b_wdata), .s_wstrb_i(b_wstrb), .s_wlast_i(b_wlast), .s_wvalid_i(b_wvalid), .s_wready_o(b_wready),
        .s_bresp_o(b_bresp), .s_bvalid_o(b_bvalid), .s_bready_i(b_bready),
        .s_araddr_i(b_araddr), .s_arlen_i(b_arlen), .s_arsize_i(b_arsize), .s_arburst_i(b_arburst),
        .s_arvalid_i(b_arvalid), .s_arready_o(b_arready),
        .s_rdata_o(b_rdata), .s_rresp_o(b_rresp), .s_rlast_o(b_rlast), .s_rvalid_o(b_rvalid), .s_rready_i(b_rready),
        .m_awaddr_o(bl_awaddr), .m_awprot_o(bl_awprot), .m_awvalid_o(bl_awvalid), .m_awready_i(bl_awready),
        .m_wdata_o(bl_wdata), .m_wstrb_o(bl_wstrb), .m_wvalid_o(bl_wvalid), .m_wready_i(bl_wready),
        .m_bresp_i(bl_bresp), .m_bvalid_i(bl_bvalid), .m_bready_o(bl_bready),
        .m_araddr_o(bl_araddr), .m_arprot_o(bl_arprot), .m_arvalid_o(bl_arvalid), .m_arready_i(bl_arready),
        .m_rdata_i(bl_rdata), .m_rresp_i(bl_rresp), .m_rvalid_i(bl_rvalid), .m_rready_o(bl_rready)
    );

    soc_axi_lite_dec #(
        .N(2), .BASE({SB_BASE, RAM_BASE}), .MASK({SX_MASK, RAM_MASK})
    ) dec_b (
        .clk_i(clk), .rst_n_i(rst_n),
        .m_awaddr_i(bl_awaddr), .m_awprot_i(bl_awprot), .m_awvalid_i(bl_awvalid), .m_awready_o(bl_awready),
        .m_wdata_i(bl_wdata), .m_wstrb_i(bl_wstrb), .m_wvalid_i(bl_wvalid), .m_wready_o(bl_wready),
        .m_bresp_o(bl_bresp), .m_bvalid_o(bl_bvalid), .m_bready_i(bl_bready),
        .m_araddr_i(bl_araddr), .m_arprot_i(bl_arprot), .m_arvalid_i(bl_arvalid), .m_arready_o(bl_arready),
        .m_rdata_o(bl_rdata), .m_rresp_o(bl_rresp), .m_rvalid_o(bl_rvalid), .m_rready_i(bl_rready),
        .s_awaddr_o(dx_awaddr), .s_awprot_o(dx_awprot), .s_awvalid_o(dx_awvalid), .s_awready_i(dx_awready),
        .s_wdata_o(dx_wdata), .s_wstrb_o(dx_wstrb), .s_wvalid_o(dx_wvalid), .s_wready_i(dx_wready),
        .s_bresp_i(dx_bresp), .s_bvalid_i(dx_bvalid), .s_bready_o(dx_bready),
        .s_araddr_o(dx_araddr), .s_arprot_o(dx_arprot), .s_arvalid_o(dx_arvalid), .s_arready_i(dx_arready),
        .s_rdata_i(dx_rdata), .s_rresp_i(dx_rresp), .s_rvalid_i(dx_rvalid), .s_rready_o(dx_rready)
    );

    soc_axi_lite_arb #(.M(2)) arb (
        .clk_i(clk), .rst_n_i(rst_n),
        .m_awaddr_i({dx_awaddr[31:0], da_awaddr[31:0]}), .m_awprot_i({dx_awprot[2:0], da_awprot[2:0]}),
        .m_awvalid_i({dx_awvalid[0], da_awvalid[0]}), .m_awready_o({dx_awready[0], da_awready[0]}),
        .m_wdata_i({dx_wdata[31:0], da_wdata[31:0]}), .m_wstrb_i({dx_wstrb[3:0], da_wstrb[3:0]}),
        .m_wvalid_i({dx_wvalid[0], da_wvalid[0]}), .m_wready_o({dx_wready[0], da_wready[0]}),
        .m_bresp_o({dx_bresp[1:0], da_bresp[1:0]}), .m_bvalid_o({dx_bvalid[0], da_bvalid[0]}),
        .m_bready_i({dx_bready[0], da_bready[0]}),
        .m_araddr_i({dx_araddr[31:0], da_araddr[31:0]}), .m_arprot_i({dx_arprot[2:0], da_arprot[2:0]}),
        .m_arvalid_i({dx_arvalid[0], da_arvalid[0]}), .m_arready_o({dx_arready[0], da_arready[0]}),
        .m_rdata_o({dx_rdata[31:0], da_rdata[31:0]}), .m_rresp_o({dx_rresp[1:0], da_rresp[1:0]}),
        .m_rvalid_o({dx_rvalid[0], da_rvalid[0]}), .m_rready_i({dx_rready[0], da_rready[0]}),
        .s_awaddr_o(r_awaddr), .s_awprot_o(r_awprot), .s_awvalid_o(r_awvalid), .s_awready_i(r_awready),
        .s_wdata_o(r_wdata), .s_wstrb_o(r_wstrb), .s_wvalid_o(r_wvalid), .s_wready_i(r_wready),
        .s_bresp_i(r_bresp), .s_bvalid_i(r_bvalid), .s_bready_o(r_bready),
        .s_araddr_o(r_araddr), .s_arprot_o(r_arprot), .s_arvalid_o(r_arvalid), .s_arready_i(r_arready),
        .s_rdata_i(r_rdata), .s_rresp_i(r_rresp), .s_rvalid_i(r_rvalid), .s_rready_o(r_rready)
    );

    soc_axi_lite_ram #(
        .WORDS(1024), .READ_LAT(1), .WRITE_LAT(1), .STALL_PROB(30), .SEED(17)
    ) ram (
        .clk_i(clk), .rst_n_i(rst_n),
        .s_awaddr_i(r_awaddr), .s_awprot_i(r_awprot), .s_awvalid_i(r_awvalid), .s_awready_o(r_awready),
        .s_wdata_i(r_wdata), .s_wstrb_i(r_wstrb), .s_wvalid_i(r_wvalid), .s_wready_o(r_wready),
        .s_bresp_o(r_bresp), .s_bvalid_o(r_bvalid), .s_bready_i(r_bready),
        .s_araddr_i(r_araddr), .s_arprot_i(r_arprot), .s_arvalid_i(r_arvalid), .s_arready_o(r_arready),
        .s_rdata_o(r_rdata), .s_rresp_o(r_rresp), .s_rvalid_o(r_rvalid), .s_rready_i(r_rready)
    );

    fr_err_slave #(.ERR_BIT(6), .SEED(23)) sa (
        .clk_i(clk), .rst_n_i(rst_n),
        .awaddr_i(da_awaddr[63:32]), .awvalid_i(da_awvalid[1]), .awready_o(da_awready[1]),
        .wdata_i(da_wdata[63:32]), .wstrb_i(da_wstrb[7:4]), .wvalid_i(da_wvalid[1]), .wready_o(da_wready[1]),
        .bresp_o(da_bresp[3:2]), .bvalid_o(da_bvalid[1]), .bready_i(da_bready[1]),
        .araddr_i(da_araddr[63:32]), .arvalid_i(da_arvalid[1]), .arready_o(da_arready[1]),
        .rdata_o(da_rdata[63:32]), .rresp_o(da_rresp[3:2]), .rvalid_o(da_rvalid[1]), .rready_i(da_rready[1])
    );

    fr_err_slave #(.ERR_BIT(7), .SEED(29)) sb (
        .clk_i(clk), .rst_n_i(rst_n),
        .awaddr_i(dx_awaddr[63:32]), .awvalid_i(dx_awvalid[1]), .awready_o(dx_awready[1]),
        .wdata_i(dx_wdata[63:32]), .wstrb_i(dx_wstrb[7:4]), .wvalid_i(dx_wvalid[1]), .wready_o(dx_wready[1]),
        .bresp_o(dx_bresp[3:2]), .bvalid_o(dx_bvalid[1]), .bready_i(dx_bready[1]),
        .araddr_i(dx_araddr[63:32]), .arvalid_i(dx_arvalid[1]), .arready_o(dx_arready[1]),
        .rdata_o(dx_rdata[63:32]), .rresp_o(dx_rresp[3:2]), .rvalid_o(dx_rvalid[1]), .rready_i(dx_rready[1])
    );

    // ---- scoreboard ---------------------------------------------------------------
    reg [31:0] sh_ram[0:1023];
    reg [31:0] sh_sa[0:255];
    reg [31:0] sh_sb[0:255];

    function [1:0] map_a;  // 0 = RAM, 1 = SA, 3 = unmapped
        input [31:0] a;
        map_a = ((a & RAM_MASK) == RAM_BASE) ? 2'd0 : ((a & SX_MASK) == SA_BASE) ? 2'd1 : 2'd3;
    endfunction
    function [1:0] map_b;  // 0 = RAM, 2 = SB, 3 = unmapped
        input [31:0] a;
        map_b = ((a & RAM_MASK) == RAM_BASE) ? 2'd0 : ((a & SX_MASK) == SB_BASE) ? 2'd2 : 2'd3;
    endfunction
    function [1:0] resp_of;
        input [1:0] where;
        input [31:0] a;
        case (where)
            2'd0: resp_of = OKAY;
            2'd1: resp_of = a[6] ? SLVERR : OKAY;
            2'd2: resp_of = a[7] ? SLVERR : OKAY;
            default: resp_of = DECERR;
        endcase
    endfunction
    function [31:0] data_of;  // what a read of this address must return
        input [1:0] where;
        input [31:0] a;
        begin
            case (where)
                2'd0: data_of = sh_ram[a[11:2]];
                2'd1: data_of = a[6] ? {16'hE0E0, a[15:0]} : sh_sa[a[9:2]];
                2'd2: data_of = a[7] ? {16'hE0E0, a[15:0]} : sh_sb[a[9:2]];
                default: data_of = 32'h0;
            endcase
        end
    endfunction
    function [31:0] merged;
        input [31:0] old, new_data;
        input [3:0] strb;
        merged = {strb[3] ? new_data[31:24] : old[31:24], strb[2] ? new_data[23:16] : old[23:16],
                  strb[1] ? new_data[15:8] : old[15:8], strb[0] ? new_data[7:0] : old[7:0]};
    endfunction
    task write_shadow;
        input [1:0] where;
        input [31:0] a, d;
        input [3:0] s;
        begin
            if (resp_of(where, a) == OKAY) begin
                if (where == 2'd0) sh_ram[a[11:2]] = merged(sh_ram[a[11:2]], d, s);
                if (where == 2'd1) sh_sa[a[9:2]] = merged(sh_sa[a[9:2]], d, s);
                if (where == 2'd2) sh_sb[a[9:2]] = merged(sh_sb[a[9:2]], d, s);
            end
        end
    endtask

    // category counters: each master must see each kind of response
    integer a_rd[0:3], a_wr[0:3], b_rbeat[0:3], b_burst[0:3], refused, fixed_bursts, mixed_bursts, contended;
    integer i;
    reg a_wbusy = 0, a_rbusy = 0;
    reg [31:0] a_waddr_busy, a_raddr_busy;
    reg b_wbusy = 0, b_rbusy = 0;
    reg [31:0] b_wlo, b_whi, b_rlo, b_rhi;
    reg a_wdone = 0, a_rdone = 0, b_wdone = 0, b_rdone = 0;

    always @(posedge clk) if (rst_n && arb.req == 2'b11) contended = contended + 1;

    function [31:0] rnd;
        input integer n;
        rnd = ($random(seed) & 32'h7FFF_FFFF) % n;
    endfunction

    function [31:0] a_address;  // master A: its half of the RAM, SA, or nothing
        input integer pick;
        case (pick % 10)
            0, 1, 2, 3, 4: a_address = RAM_BASE + {rnd(512), 2'b00};
            5, 6, 7:       a_address = SA_BASE + {rnd(256), 2'b00};
            default:       a_address = 32'h3000_0000 + {rnd(1024), 2'b00};
        endcase
    endfunction

    // ---- master A writer ---------------------------------------------------------
    initial begin : a_writer
        integer n, w, cyc, aw_at, w_at;
        reg [31:0] addr, data;
        reg [3:0] strb;
        reg aw_done, w_done;
        wait (rst_n);
        for (n = 0; n < ntx; n = n + 1) begin
            addr = a_address(rnd(10));
            while (a_rbusy && addr[31:2] == a_raddr_busy[31:2]) addr = a_address(rnd(10));
            data = $random(seed);
            strb = rnd(5) == 0 ? rnd(16) : 4'hF;
            a_waddr_busy = addr;
            a_wbusy = 1'b1;
            repeat (rnd(3)) @(posedge clk);
            // AW and W together, or either one up to two cycles ahead; neither
            // waits for the other's READY, as AXI requires of a master
            aw_at = rnd(3) == 0 ? rnd(3) : 0;
            w_at  = aw_at == 0 && rnd(2) ? rnd(3) : 0;
            a_awaddr = addr; a_wdata = data; a_wstrb = strb;
            aw_done = 0; w_done = 0; cyc = 0;
            #1;
            a_awvalid = (aw_at == 0);
            a_wvalid  = (w_at == 0);
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (a_awvalid && a_awready) aw_done = 1;
                if (a_wvalid && a_wready) w_done = 1;
                cyc = cyc + 1;
                #1;
                a_awvalid = !aw_done && cyc >= aw_at;
                a_wvalid  = !w_done && cyc >= w_at;
            end
            w = rnd(4);
            repeat (w) @(posedge clk);
            #1 a_bready = 1;
            @(posedge clk);
            while (!a_bvalid) @(posedge clk);
            if (a_bresp !== resp_of(map_a(addr), addr)) begin
                errors = errors + 1;
                $display("FAIL: A write 0x%08h answered %0d, expected %0d", addr, a_bresp, resp_of(map_a(addr), addr));
            end
            a_wr[a_bresp] = a_wr[a_bresp] + 1;
            write_shadow(map_a(addr), addr, data, strb);
            #1 a_bready = 0;
            a_wbusy = 1'b0;
        end
        a_wdone = 1;
    end

    // ---- master A reader ---------------------------------------------------------
    initial begin : a_reader
        integer n;
        reg [31:0] addr;
        wait (rst_n);
        for (n = 0; n < ntx; n = n + 1) begin
            addr = a_address(rnd(10));
            while (a_wbusy && addr[31:2] == a_waddr_busy[31:2]) addr = a_address(rnd(10));
            a_raddr_busy = addr;
            a_rbusy = 1'b1;
            repeat (rnd(3)) @(posedge clk);
            #1 a_araddr = addr; a_arvalid = 1;
            @(posedge clk);
            while (!a_arready) @(posedge clk);
            #1 a_arvalid = 0;
            repeat (rnd(4)) @(posedge clk);
            #1 a_rready = 1;
            @(posedge clk);
            while (!a_rvalid) @(posedge clk);
            if (a_rresp !== resp_of(map_a(addr), addr) || a_rdata !== data_of(map_a(addr), addr)) begin
                errors = errors + 1;
                $display("FAIL: A read 0x%08h answered %0d/0x%08h, expected %0d/0x%08h", addr, a_rresp,
                         a_rdata, resp_of(map_a(addr), addr), data_of(map_a(addr), addr));
            end
            a_rd[a_rresp] = a_rd[a_rresp] + 1;
            #1 a_rready = 0;
            a_rbusy = 1'b0;
        end
        a_rdone = 1;
    end

    // ---- master B: burst shapes -------------------------------------------------------
    // Returns {refused, fixed, len[7:0], addr} packed as a 42-bit value.
    function [41:0] b_burst_shape;
        input integer pick;
        reg [31:0] base;
        reg [7:0] len;
        reg fixed, refuse;
        begin
            len = rnd(16);
            fixed = (pick % 10) == 7;
            refuse = (pick % 10) == 9;  // one burst in ten breaks the profile
            case (pick % 5)
                0, 1: base = RAM_BASE + 32'h800 + {rnd(512 - 16), 2'b00};    // B's half of the RAM
                2:    base = SB_BASE + {rnd(256 - 16), 2'b00};
                3:    base = RAM_BASE + 32'hFFC - {rnd(8), 2'b00};           // runs off the RAM window
                default: base = SB_BASE + 32'h3FC - {rnd(8), 2'b00};        // runs off the SB window
            endcase
            if (pick % 23 == 11) base = 32'h4000_0000 + {rnd(64), 2'b00};    // unmapped throughout
            b_burst_shape = {refuse, fixed, len, base};
        end
    endfunction

    // ---- master B writer ---------------------------------------------------------
    initial begin : b_writer
        integer n, k, pick, kind;
        reg [41:0] shape;
        reg [31:0] addr, beat_addr, data;
        reg [7:0] len;
        reg fixed, refuse;
        reg [1:0] worst, expect_b;
        reg [3:0] strb;
        wait (rst_n);
        for (n = 0; n < ntx / 4; n = n + 1) begin
            pick  = rnd(1000);
            shape = b_burst_shape(pick);
            {refuse, fixed, len, addr} = shape;
            while (b_rbusy && addr < b_rhi + 64 && addr + 4 * (len + 1) + 64 > b_rlo) @(posedge clk);
            b_wlo = addr;
            b_whi = addr + 4 * (len + 1);
            b_wbusy = 1'b1;
            repeat (rnd(3)) @(posedge clk);
            kind = rnd(3);  // how a refused burst breaks the profile
            #1;
            b_awaddr  = refuse && kind == 0 ? addr + 2 : addr;
            b_awlen   = len;
            b_awsize  = refuse && kind == 1 ? 3'd1 : 3'd2;
            b_awburst = refuse && kind == 2 ? 2'd2 : (fixed ? 2'd0 : 2'd1);
            b_awvalid = 1;
            @(posedge clk);
            while (!b_awready) @(posedge clk);
            #1 b_awvalid = 0;
            worst = OKAY;
            for (k = 0; k <= len; k = k + 1) begin
                beat_addr = fixed ? addr : addr + 4 * k;
                data = $random(seed);
                strb = rnd(6) == 0 ? rnd(16) : 4'hF;
                repeat (rnd(3)) @(posedge clk);
                #1 b_wdata = data; b_wstrb = strb; b_wlast = (k == len); b_wvalid = 1;
                @(posedge clk);
                while (!b_wready) @(posedge clk);
                #1 b_wvalid = 0; b_wlast = 0;
                if (!refuse) begin
                    if (resp_of(map_b(beat_addr), beat_addr) > worst) worst = resp_of(map_b(beat_addr), beat_addr);
                    write_shadow(map_b(beat_addr), beat_addr, data, strb);
                end
            end
            expect_b = refuse ? SLVERR : worst;
            repeat (rnd(4)) @(posedge clk);
            #1 b_bready = 1;
            @(posedge clk);
            while (!b_bvalid) @(posedge clk);
            if (b_bresp !== expect_b) begin
                errors = errors + 1;
                $display("FAIL: B write burst at 0x%08h (len %0d) answered %0d, expected %0d", addr, len + 1,
                         b_bresp, expect_b);
            end
            b_burst[b_bresp] = b_burst[b_bresp] + 1;
            if (refuse) refused = refused + 1;
            if (fixed) fixed_bursts = fixed_bursts + 1;
            #1 b_bready = 0;
            b_wbusy = 1'b0;
        end
        b_wdone = 1;
    end

    // ---- master B reader ---------------------------------------------------------
    initial begin : b_reader
        integer n, k, pick, kind;
        reg [41:0] shape;
        reg [31:0] addr, beat_addr;
        reg [7:0] len;
        reg fixed, refuse, saw_ok, saw_err;
        reg [1:0] exp_r;
        reg [31:0] exp_d;
        wait (rst_n);
        for (n = 0; n < ntx / 4; n = n + 1) begin
            pick  = rnd(1000);
            shape = b_burst_shape(pick);
            {refuse, fixed, len, addr} = shape;
            // never read what the concurrent writer may still be writing
            while (b_wbusy && addr < b_whi + 64 && addr + 4 * (len + 1) + 64 > b_wlo) @(posedge clk);
            b_rlo = addr;
            b_rhi = addr + 4 * (len + 1);
            b_rbusy = 1'b1;
            repeat (rnd(3)) @(posedge clk);
            kind = rnd(3);
            #1;
            b_araddr  = refuse && kind == 0 ? addr + 2 : addr;
            b_arlen   = len;
            b_arsize  = refuse && kind == 1 ? 3'd1 : 3'd2;
            b_arburst = refuse && kind == 2 ? 2'd2 : (fixed ? 2'd0 : 2'd1);
            b_arvalid = 1;
            @(posedge clk);
            while (!b_arready) @(posedge clk);
            #1 b_arvalid = 0;
            saw_ok = 0; saw_err = 0;
            for (k = 0; k <= len; k = k + 1) begin
                beat_addr = fixed ? addr : addr + 4 * k;
                repeat (rnd(3)) @(posedge clk);
                #1 b_rready = 1;
                @(posedge clk);
                while (!b_rvalid) @(posedge clk);
                exp_r = refuse ? SLVERR : resp_of(map_b(beat_addr), beat_addr);
                exp_d = refuse ? 32'h0 : data_of(map_b(beat_addr), beat_addr);
                if (b_rresp !== exp_r || b_rdata !== exp_d || b_rlast !== (k == len)) begin
                    errors = errors + 1;
                    $display("FAIL: B read beat %0d at 0x%08h: %0d/0x%08h/last %0d, expected %0d/0x%08h/%0d",
                             k, beat_addr, b_rresp, b_rdata, b_rlast, exp_r, exp_d, k == len);
                end
                b_rbeat[b_rresp] = b_rbeat[b_rresp] + 1;
                if (b_rresp == OKAY) saw_ok = 1; else saw_err = 1;
                #1 b_rready = 0;
            end
            if (saw_ok && saw_err) mixed_bursts = mixed_bursts + 1;
            if (refuse) refused = refused + 1;
            b_rbusy = 1'b0;
        end
        b_rdone = 1;
    end

    integer timeout;
    initial begin
        errors = 0;
        refused = 0; fixed_bursts = 0; mixed_bursts = 0; contended = 0;
        for (i = 0; i < 4; i = i + 1) begin a_rd[i] = 0; a_wr[i] = 0; b_rbeat[i] = 0; b_burst[i] = 0; end
        for (i = 0; i < 1024; i = i + 1) sh_ram[i] = 32'h0;
        for (i = 0; i < 256; i = i + 1) begin sh_sa[i] = 32'h0; sh_sb[i] = 32'h0; end
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("txns=%d", ntx)) ntx = 400;
        $display("\n== Fabric under random traffic: seed %0d, %0d transactions per Lite process ==", seed, ntx);
        repeat (4) @(posedge clk);
        #1 rst_n = 1;
        timeout = 0;
        while (!(a_wdone && a_rdone && b_wdone && b_rdone) && timeout < 2000000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!(a_wdone && a_rdone && b_wdone && b_rdone)) begin
            errors = errors + 1;
            $display("FAIL: traffic did not complete (%0d cycles)", timeout);
        end
        repeat (10) @(posedge clk);
        for (i = 0; i < 1024; i = i + 1)
            if (ram.mem[i] !== sh_ram[i]) begin
                errors = errors + 1;
                $display("FAIL: RAM word %0d = 0x%08h, expected 0x%08h", i, ram.mem[i], sh_ram[i]);
            end
        for (i = 0; i < 256; i = i + 1)
            if (sa.mem[i] !== sh_sa[i] || sb.mem[i] !== sh_sb[i]) begin
                errors = errors + 1;
                $display("FAIL: error-slave word %0d differs from its shadow", i);
            end
        $display("   A reads  OKAY/SLVERR/DECERR : %0d/%0d/%0d", a_rd[0], a_rd[2], a_rd[3]);
        $display("   A writes OKAY/SLVERR/DECERR : %0d/%0d/%0d", a_wr[0], a_wr[2], a_wr[3]);
        $display("   B read beats OKAY/SLVERR/DECERR : %0d/%0d/%0d", b_rbeat[0], b_rbeat[2], b_rbeat[3]);
        $display("   B write bursts OKAY/SLVERR/DECERR : %0d/%0d/%0d", b_burst[0], b_burst[2], b_burst[3]);
        $display("   refused %0d, FIXED %0d, mixed-response read bursts %0d, contended cycles %0d",
                 refused, fixed_bursts, mixed_bursts, contended);
        check(1, a_rd[0] > 0 && a_rd[2] > 0 && a_rd[3] > 0, "A saw every read response");
        check(1, a_wr[0] > 0 && a_wr[2] > 0 && a_wr[3] > 0, "A saw every write response");
        check(1, b_rbeat[0] > 0 && b_rbeat[2] > 0 && b_rbeat[3] > 0, "B saw every read response");
        check(1, b_burst[0] > 0 && b_burst[2] > 0 && b_burst[3] > 0, "B saw every write response");
        check(1, refused > 0 && fixed_bursts > 0 && mixed_bursts > 0 && contended > 0,
              "refused, FIXED, mixed and contended traffic all occurred");
        if (errors == 0) $display("== FABRIC RANDOM TESTBENCH: ALL TESTS PASSED ==");
        else $display("== FABRIC RANDOM TESTBENCH: %0d FAILURE(S) ==", errors);
        finish_test;
    end

endmodule
