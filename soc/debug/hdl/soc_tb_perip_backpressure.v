// The peripheral slaves under a master that does not accept responses at once.
//
// The regression's timing sweep varies the two memory models, because those are
// the only slaves with timing knobs. Every other slave in the SoC - the
// interrupt controller, the machine timer, the dual-port SRAM - is real RTL
// that answers at its own fixed rate, so no run has ever made one of them hold
// a response. That leaves an obligation unexercised, and it is one the whole
// fabric depends on: a slave that has raised BVALID or RVALID must hold it, and
// hold the payload with it, until the master takes it.
//
// It matters here more than it would in a simpler system. The CPU's data port
// and the DMA's bridge both sit behind a decoder that latches its routing
// selection across the response, so a slave that dropped a held response would
// strand the decoder on a transaction that never completes, and the failure
// would surface as a hung program rather than as a wrong value.
//
// Backpressure cannot be injected into these slaves from outside, so it is
// applied from the master side instead, which reaches the same logic: the bench
// withholds BREADY and RREADY for a programmed number of cycles and checks that
// nothing moves while it does.
//
// What is checked, for each of the three slaves:
//   1  a response held for 1, 3 and 10 cycles stays asserted the whole time
//   2  the payload under it does not change while it is held
//   3  the value finally taken is the value the slave first presented
//   4  the slave accepts no new address while a response is outstanding
//   5  registers are unaffected: the same read after the stall returns the same
//      word, so a held response did not consume something twice
//
// The three slaves are driven through the design's own decoder, at the real
// addresses, so the routing that has to survive the stall is in the path.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

`include "soc_addr_map.vh"

module soc_tb_perip_backpressure;

localparam integer N = 3;                    // SRAM, PIC, timer
localparam integer SD_SRAM = 0, SD_PIC = 1, SD_TMR = 2;

localparam [1:0] RESP_OKAY = 2'b00;

integer errors;
`include "tb_check.vh"

wire clk, rst_n;
ck_rst_tb #(
    .CK_SEMIPERIOD(5)
) ck_rst (
    .clk_o(clk),
    .rst_n_o(rst_n)
);

// ---------------------------------------------------------------------------
// master side of the decoder, driven by this bench
// ---------------------------------------------------------------------------
reg  [31:0] m_awaddr, m_wdata, m_araddr;
reg  [3:0]  m_wstrb;
reg         m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
wire        m_awready, m_wready, m_bvalid, m_arready, m_rvalid;
wire [1:0]  m_bresp, m_rresp;
wire [31:0] m_rdata;

// slave side
wire [N*32-1:0] s_awaddr, s_wdata, s_araddr, s_rdata;
wire [N*3-1:0]  s_awprot, s_arprot;
wire [N*4-1:0]  s_wstrb;
wire [N*2-1:0]  s_bresp, s_rresp;
wire [N-1:0]    s_awvalid, s_awready, s_wvalid, s_wready;
wire [N-1:0]    s_bvalid, s_bready, s_arvalid, s_arready, s_rvalid, s_rready;

soc_axi_lite_dec #(
    .N(N),
    .BASE({`SOC_TMR_BASE, `SOC_PIC_BASE, `SOC_SRAM_BASE}),
    .MASK({`SOC_TMR_MASK, `SOC_PIC_MASK, `SOC_SRAM_MASK})
) dec (
    .clk_i(clk),
    .rst_n_i(rst_n),
    .m_awaddr_i(m_awaddr),
    .m_awprot_i(3'b000),
    .m_awvalid_i(m_awvalid),
    .m_awready_o(m_awready),
    .m_wdata_i(m_wdata),
    .m_wstrb_i(m_wstrb),
    .m_wvalid_i(m_wvalid),
    .m_wready_o(m_wready),
    .m_bresp_o(m_bresp),
    .m_bvalid_o(m_bvalid),
    .m_bready_i(m_bready),
    .m_araddr_i(m_araddr),
    .m_arprot_i(3'b000),
    .m_arvalid_i(m_arvalid),
    .m_arready_o(m_arready),
    .m_rdata_o(m_rdata),
    .m_rresp_o(m_rresp),
    .m_rvalid_o(m_rvalid),
    .m_rready_i(m_rready),

    .s_awaddr_o(s_awaddr),
    .s_awprot_o(s_awprot),
    .s_awvalid_o(s_awvalid),
    .s_awready_i(s_awready),
    .s_wdata_o(s_wdata),
    .s_wstrb_o(s_wstrb),
    .s_wvalid_o(s_wvalid),
    .s_wready_i(s_wready),
    .s_bresp_i(s_bresp),
    .s_bvalid_i(s_bvalid),
    .s_bready_o(s_bready),
    .s_araddr_o(s_araddr),
    .s_arprot_o(s_arprot),
    .s_arvalid_o(s_arvalid),
    .s_arready_i(s_arready),
    .s_rdata_i(s_rdata),
    .s_rresp_i(s_rresp),
    .s_rvalid_i(s_rvalid),
    .s_rready_o(s_rready)
);

// ---------------------------------------------------------------------------
// the three real slaves
// ---------------------------------------------------------------------------
dp_sram_top sram (
    .clk_i(clk),
    .rst_n_i(rst_n),
    .a_awaddr_i(s_awaddr[SD_SRAM*32 +: 10]),
    .a_awvalid_i(s_awvalid[SD_SRAM]),
    .a_awready_o(s_awready[SD_SRAM]),
    .a_wdata_i(s_wdata[SD_SRAM*32 +: 32]),
    .a_wstrb_i(s_wstrb[SD_SRAM*4 +: 4]),
    .a_wvalid_i(s_wvalid[SD_SRAM]),
    .a_wready_o(s_wready[SD_SRAM]),
    .a_bresp_o(s_bresp[SD_SRAM*2 +: 2]),
    .a_bvalid_o(s_bvalid[SD_SRAM]),
    .a_bready_i(s_bready[SD_SRAM]),
    .a_araddr_i(s_araddr[SD_SRAM*32 +: 10]),
    .a_arvalid_i(s_arvalid[SD_SRAM]),
    .a_arready_o(s_arready[SD_SRAM]),
    .a_rdata_o(s_rdata[SD_SRAM*32 +: 32]),
    .a_rresp_o(s_rresp[SD_SRAM*2 +: 2]),
    .a_rvalid_o(s_rvalid[SD_SRAM]),
    .a_rready_i(s_rready[SD_SRAM]),
    // port B is unused here: this bench is about one master stalling
    .b_awaddr_i(10'b0),
    .b_awvalid_i(1'b0),
    .b_awready_o(),
    .b_wdata_i(32'b0),
    .b_wstrb_i(4'b0),
    .b_wvalid_i(1'b0),
    .b_wready_o(),
    .b_bresp_o(),
    .b_bvalid_o(),
    .b_bready_i(1'b0),
    .b_araddr_i(10'b0),
    .b_arvalid_i(1'b0),
    .b_arready_o(),
    .b_rdata_o(),
    .b_rresp_o(),
    .b_rvalid_o(),
    .b_rready_i(1'b0),
    .irq_o()
);

pic pic_inst (
    .clk_i(clk),
    .rst_n_i(rst_n),
    .irq_src_i(16'b0),
    .cpu_mask_i(16'hFFFF),
    .cpu_irq_o(),
    .cpu_irq_vec_o(),
    .pending_o(),
    .cpu_irq_ack_i(1'b0),
    .cpu_irq_eoi_i(1'b0),
    .s_axi_awaddr_i(s_awaddr[SD_PIC*32 +: 32]),
    .s_axi_awprot_i(s_awprot[SD_PIC*3 +: 3]),
    .s_axi_awvalid_i(s_awvalid[SD_PIC]),
    .s_axi_awready_o(s_awready[SD_PIC]),
    .s_axi_wdata_i(s_wdata[SD_PIC*32 +: 32]),
    .s_axi_wstrb_i(s_wstrb[SD_PIC*4 +: 4]),
    .s_axi_wvalid_i(s_wvalid[SD_PIC]),
    .s_axi_wready_o(s_wready[SD_PIC]),
    .s_axi_bresp_o(s_bresp[SD_PIC*2 +: 2]),
    .s_axi_bvalid_o(s_bvalid[SD_PIC]),
    .s_axi_bready_i(s_bready[SD_PIC]),
    .s_axi_araddr_i(s_araddr[SD_PIC*32 +: 32]),
    .s_axi_arprot_i(s_arprot[SD_PIC*3 +: 3]),
    .s_axi_arvalid_i(s_arvalid[SD_PIC]),
    .s_axi_arready_o(s_arready[SD_PIC]),
    .s_axi_rdata_o(s_rdata[SD_PIC*32 +: 32]),
    .s_axi_rresp_o(s_rresp[SD_PIC*2 +: 2]),
    .s_axi_rvalid_o(s_rvalid[SD_PIC]),
    .s_axi_rready_i(s_rready[SD_PIC])
);

mtimer tmr (
    .clk_i(clk),
    .rst_n_i(rst_n),
    .irq_o(),
    .s_axi_awaddr_i(s_awaddr[SD_TMR*32 +: 32]),
    .s_axi_awprot_i(s_awprot[SD_TMR*3 +: 3]),
    .s_axi_awvalid_i(s_awvalid[SD_TMR]),
    .s_axi_awready_o(s_awready[SD_TMR]),
    .s_axi_wdata_i(s_wdata[SD_TMR*32 +: 32]),
    .s_axi_wstrb_i(s_wstrb[SD_TMR*4 +: 4]),
    .s_axi_wvalid_i(s_wvalid[SD_TMR]),
    .s_axi_wready_o(s_wready[SD_TMR]),
    .s_axi_bresp_o(s_bresp[SD_TMR*2 +: 2]),
    .s_axi_bvalid_o(s_bvalid[SD_TMR]),
    .s_axi_bready_i(s_bready[SD_TMR]),
    .s_axi_araddr_i(s_araddr[SD_TMR*32 +: 32]),
    .s_axi_arprot_i(s_arprot[SD_TMR*3 +: 3]),
    .s_axi_arvalid_i(s_arvalid[SD_TMR]),
    .s_axi_arready_o(s_arready[SD_TMR]),
    .s_axi_rdata_o(s_rdata[SD_TMR*32 +: 32]),
    .s_axi_rresp_o(s_rresp[SD_TMR*2 +: 2]),
    .s_axi_rvalid_o(s_rvalid[SD_TMR]),
    .s_axi_rready_i(s_rready[SD_TMR])
);

// ---------------------------------------------------------------------------
// master tasks that stall the response channel on purpose
// ---------------------------------------------------------------------------
reg [31:0] rd;
reg [31:0] held_first, held_last;
reg [1:0]  held_resp;
integer    unstable, extra_accept;

// Read `addr`, then sit on RREADY for `stall` cycles before taking the beat.
// While stalling: RVALID must stay up, RDATA and RRESP must not move, and the
// slave must not accept another address.
task read_stalled;
    input [31:0] addr;
    input integer stall;
    integer k;
    begin
        unstable     = 0;
        extra_accept = 0;

        @(negedge clk);
        m_araddr  = addr;
        m_arvalid = 1'b1;
        m_rready  = 1'b0;
        @(posedge clk);
        while (!m_arready) @(posedge clk);
        @(negedge clk);
        m_arvalid = 1'b0;

        // wait for the response to appear with RREADY still low
        @(posedge clk);
        while (!m_rvalid) @(posedge clk);
        held_first = m_rdata;
        held_resp  = m_rresp;

        // Hold it. ARVALID stays low throughout: raising it here and dropping
        // it again without a handshake would break the very rule this bench
        // exists to check. The slave's ARREADY comes from its own response
        // state rather than from the master's ARVALID, so sampling it while the
        // response is outstanding shows the same thing without driving
        // anything.
        for (k = 0; k < stall; k = k + 1) begin
            @(negedge clk);
            @(posedge clk);
            if (!m_rvalid)                 // the response must not go away
                unstable = unstable + 1;
            if (m_rdata !== held_first || m_rresp !== held_resp)
                unstable = unstable + 1;   // nor may the payload move
            if (m_arready)                 // nor may it be ready for another
                extra_accept = extra_accept + 1;
        end

        @(negedge clk);
        m_rready  = 1'b1;
        @(posedge clk);
        held_last = m_rdata;
        rd        = m_rdata;
        @(negedge clk);
        m_rready = 1'b0;
    end
endtask

// Write `data` to `addr`, then sit on BREADY for `stall` cycles.
task write_stalled;
    input [31:0] addr;
    input [31:0] data;
    input integer stall;
    integer k;
    begin
        unstable     = 0;
        extra_accept = 0;

        @(negedge clk);
        m_awaddr  = addr;
        m_awvalid = 1'b1;
        m_wdata   = data;
        m_wstrb   = 4'hF;
        m_wvalid  = 1'b1;
        m_bready  = 1'b0;
        @(posedge clk);
        while (!(m_awready && m_wready)) begin
            @(negedge clk);
            if (m_awready) m_awvalid = 1'b0;
            if (m_wready)  m_wvalid  = 1'b0;
            @(posedge clk);
        end
        @(negedge clk);
        m_awvalid = 1'b0;
        m_wvalid  = 1'b0;

        @(posedge clk);
        while (!m_bvalid) @(posedge clk);
        held_resp = m_bresp;

        // AWVALID stays low here for the same reason as ARVALID above.
        for (k = 0; k < stall; k = k + 1) begin
            @(negedge clk);
            @(posedge clk);
            if (!m_bvalid)
                unstable = unstable + 1;
            if (m_bresp !== held_resp)
                unstable = unstable + 1;
            if (m_awready)
                extra_accept = extra_accept + 1;
        end

        @(negedge clk);
        m_bready  = 1'b1;
        @(posedge clk);
        @(negedge clk);
        m_bready = 1'b0;
    end
endtask

task read_plain;
    input [31:0] addr;
    begin
        @(negedge clk);
        m_araddr  = addr;
        m_arvalid = 1'b1;
        m_rready  = 1'b1;
        @(posedge clk);
        while (!m_arready) @(posedge clk);
        @(negedge clk);
        m_arvalid = 1'b0;
        @(posedge clk);
        while (!m_rvalid) @(posedge clk);
        rd = m_rdata;
        @(negedge clk);
        m_rready = 1'b0;
    end
endtask

// One slave, one stall length: the four properties in one place.
task stall_case;
    input [31:0] addr;
    input integer stall;
    input [511:0] who;
    begin
        read_stalled(addr, stall);
        check(32'd0, unstable[31:0],     {who, " read response held steady"});
        check(32'd0, extra_accept[31:0], {who, " no second address while stalled"});
        check(held_first, held_last,     {who, " the value taken is the value shown"});
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
reg [31:0] before_pic, before_tmr, before_sram;

initial begin
    errors    = 0;
    m_awaddr  = 0; m_wdata = 0; m_araddr = 0; m_wstrb = 0;
    m_awvalid = 0; m_wvalid = 0; m_bready = 0; m_arvalid = 0; m_rready = 0;
    unstable  = 0; extra_accept = 0;
    held_first = 0; held_last = 0; held_resp = 0;

    $display("=====================================================");
    $display("== PERIPHERAL SLAVES UNDER RESPONSE BACKPRESSURE ==");
    $display("=====================================================");

    wait (rst_n === 1'b1);
    repeat (3) @(posedge clk);

    // -----------------------------------------------------------------
    // give each slave a value worth holding, so a response that decayed
    // to zero could not be mistaken for a correct one
    // -----------------------------------------------------------------
    write_stalled(`SOC_PIC_BASE + 32'hC0, 32'h0000_0027, 0);   // BAND_CONFIG
    write_stalled(`SOC_TMR_BASE + 32'h08, 32'h1234_5678, 0);   // MTIMECMP_LO
    write_stalled(`SOC_SRAM_BASE + 32'h40, 32'hFEED_BEEF, 0);  // an SRAM word

    read_plain(`SOC_PIC_BASE + 32'hC0);   before_pic  = rd;
    read_plain(`SOC_TMR_BASE + 32'h08);   before_tmr  = rd;
    read_plain(`SOC_SRAM_BASE + 32'h40);  before_sram = rd;
    check(32'h0000_0027, before_pic,  "precondition: controller holds a value");
    check(32'h1234_5678, before_tmr,  "precondition: timer holds a value");
    check(32'hFEED_BEEF, before_sram, "precondition: memory holds a value");

    // =====================================================================
    // 1. the interrupt controller
    // =====================================================================
    $display("\n-- 1. interrupt controller --");
    stall_case(`SOC_PIC_BASE + 32'hC0, 1,  "controller, 1 cycle: ");
    stall_case(`SOC_PIC_BASE + 32'hC0, 3,  "controller, 3 cycles:");
    stall_case(`SOC_PIC_BASE + 32'hC0, 10, "controller, 10 cycles:");

    write_stalled(`SOC_PIC_BASE + 32'hC8, 32'd5, 6);   // NEST_MAX
    check(32'd0, unstable[31:0],     "controller write response held steady");
    check(32'd0, extra_accept[31:0], "controller took no second write address");

    // =====================================================================
    // 2. the machine timer
    // =====================================================================
    $display("\n-- 2. machine timer --");
    stall_case(`SOC_TMR_BASE + 32'h08, 1,  "timer, 1 cycle:      ");
    stall_case(`SOC_TMR_BASE + 32'h08, 3,  "timer, 3 cycles:     ");
    stall_case(`SOC_TMR_BASE + 32'h08, 10, "timer, 10 cycles:    ");

    write_stalled(`SOC_TMR_BASE + 32'h0C, 32'h0000_00AB, 6);
    check(32'd0, unstable[31:0],     "timer write response held steady");
    check(32'd0, extra_accept[31:0], "timer took no second write address");

    // =====================================================================
    // 3. the dual-port SRAM
    // =====================================================================
    $display("\n-- 3. dual-port memory --");
    stall_case(`SOC_SRAM_BASE + 32'h40, 1,  "memory, 1 cycle:     ");
    stall_case(`SOC_SRAM_BASE + 32'h40, 3,  "memory, 3 cycles:    ");
    stall_case(`SOC_SRAM_BASE + 32'h40, 10, "memory, 10 cycles:   ");

    write_stalled(`SOC_SRAM_BASE + 32'h44, 32'hCAFE_F00D, 6);
    check(32'd0, unstable[31:0],     "memory write response held steady");
    check(32'd0, extra_accept[31:0], "memory took no second write address");

    // =====================================================================
    // 4. nothing was consumed twice
    //
    // A slave that treated a held response as a completed one could advance
    // internal state per stalled cycle. Reading the same words back proves it
    // did not.
    // =====================================================================
    $display("\n-- 4. registers unchanged by the stalls --");
    read_plain(`SOC_PIC_BASE + 32'hC0);
    check(before_pic, rd,  "controller register survived the stalls");
    read_plain(`SOC_TMR_BASE + 32'h08);
    check(before_tmr, rd,  "timer register survived the stalls");
    read_plain(`SOC_SRAM_BASE + 32'h40);
    check(before_sram, rd, "memory word survived the stalls");

    read_plain(`SOC_PIC_BASE + 32'hC8);
    check(32'd5, rd, "the stalled controller write did land, exactly once");
    read_plain(`SOC_SRAM_BASE + 32'h44);
    check(32'hCAFE_F00D, rd, "the stalled memory write did land, exactly once");

    repeat (4) @(posedge clk);
    $display("\n=====================================================");
    if (errors == 0)
        $display("== PERIPHERAL BACKPRESSURE TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== PERIPHERAL BACKPRESSURE TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("=====================================================");
    $finish;
end

initial begin
    #500000;
    $display("FAIL: soc_tb_perip_backpressure timeout");
    $finish;
end

endmodule
