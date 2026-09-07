// The SoC address map, checked against the decoder that implements it
// (soc/hdl/axi_lite_dec.v driven from soc/hdl/soc_addr_map.vh).
//
// The property under test is the one the map's own header claims: every
// window is exactly the size of the block behind it, so an address that lands
// inside the window but past the end of that block cannot alias back onto it.
//
// This is worth its own bench because the failure is silent. The peripherals
// decode a byte offset and no more - the PIC and the machine timer take
// addr[7:2] in axi_lite_slave.v, the DMA takes addr[7:0] in its own slave - so
// a window wider than 256 B leaves the block repeated over and over above
// itself. An access to PIC_BASE+0x100 would then reach SRC0_CONFIG and answer
// OKAY: software would corrupt a live interrupt configuration and get a
// successful response for it. Nothing in a system-level run notices, because a
// working program never issues that address.
//
// Each slave port here is a stub that answers OKAY, so the only way a check can
// see DECERR is if the decoder refused to route the address at all. The bench
// drives the master side of the CPU data bus decoder with the real BASE/MASK
// parameters from soc_addr_map.vh.
//
// Verilog-2005; run by the ModelSim flow (compile.do, run 10 of regress.do)
// and by the SoC lint/SVA flow.

`timescale 1ns/1ps
`include "soc_addr_map.vh"

module tb_addr_map;

localparam integer N = 5;                       // DMEM, SRAM, PIC, TMR, DMA
localparam integer SD_DMEM = 0, SD_SRAM = 1, SD_PIC = 2, SD_TMR = 3, SD_DMA = 4;

localparam [1:0] RESP_OKAY = 2'b00, RESP_DECERR = 2'b11;

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

integer errors = 0;
reg [31:0] rd;
`include "tb_check.vh"

// ---- master side ----
reg  [31:0] m_awaddr, m_wdata, m_araddr;
reg  [3:0]  m_wstrb;
reg         m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
wire        m_awready, m_wready, m_bvalid, m_arready, m_rvalid;
wire [1:0]  m_bresp, m_rresp;
wire [31:0] m_rdata;

// ---- slave side ----
wire [N*32-1:0] s_awaddr, s_wdata, s_araddr;
wire [N*3-1:0]  s_awprot, s_arprot;
wire [N*4-1:0]  s_wstrb;
wire [N-1:0]    s_awvalid, s_wvalid, s_bready, s_arvalid, s_rready;

// slave-stub state, declared before the instance that reads it
reg [N-1:0]    s_bvalid_q, s_rvalid_q;
reg [N*32-1:0] s_rdata_q;

axi_lite_dec #(
    .N    (N),
    .BASE ({`SOC_DMA_BASE, `SOC_TMR_BASE, `SOC_PIC_BASE, `SOC_SRAM_BASE, `SOC_DMEM_BASE}),
    .MASK ({`SOC_DMA_MASK, `SOC_TMR_MASK, `SOC_PIC_MASK, `SOC_SRAM_MASK, `SOC_DMEM_MASK})
) dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .m_awaddr_i(m_awaddr), .m_awprot_i(3'b0), .m_awvalid_i(m_awvalid), .m_awready_o(m_awready),
    .m_wdata_i(m_wdata), .m_wstrb_i(m_wstrb), .m_wvalid_i(m_wvalid), .m_wready_o(m_wready),
    .m_bresp_o(m_bresp), .m_bvalid_o(m_bvalid), .m_bready_i(m_bready),
    .m_araddr_i(m_araddr), .m_arprot_i(3'b0), .m_arvalid_i(m_arvalid), .m_arready_o(m_arready),
    .m_rdata_o(m_rdata), .m_rresp_o(m_rresp), .m_rvalid_o(m_rvalid), .m_rready_i(m_rready),
    .s_awaddr_o(s_awaddr), .s_awprot_o(s_awprot), .s_awvalid_o(s_awvalid), .s_awready_i({N{1'b1}}),
    .s_wdata_o(s_wdata), .s_wstrb_o(s_wstrb), .s_wvalid_o(s_wvalid), .s_wready_i({N{1'b1}}),
    .s_bresp_i({N{RESP_OKAY}}), .s_bvalid_i(s_bvalid_q), .s_bready_o(s_bready),
    .s_araddr_o(s_araddr), .s_arprot_o(s_arprot), .s_arvalid_o(s_arvalid), .s_arready_i({N{1'b1}}),
    .s_rdata_i(s_rdata_q), .s_rresp_i({N{RESP_OKAY}}), .s_rvalid_i(s_rvalid_q), .s_rready_o(s_rready)
);

// ---------------------------------------------------------------------------
// Slave stubs. Each answers OKAY one cycle after its address handshake and
// returns its own index as read data, so a check can tell WHICH slave was
// reached, not merely that something answered.
// ---------------------------------------------------------------------------
genvar g;
generate for (g = 0; g < N; g = g + 1) begin : g_slv
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            s_bvalid_q[g] <= 1'b0;
            s_rvalid_q[g] <= 1'b0;
            s_rdata_q[g*32 +: 32] <= 32'd0;
        end else begin
            if (s_awvalid[g] && s_wvalid[g])       s_bvalid_q[g] <= 1'b1;
            else if (s_bready[g])                  s_bvalid_q[g] <= 1'b0;

            if (s_arvalid[g]) begin
                s_rvalid_q[g] <= 1'b1;
                s_rdata_q[g*32 +: 32] <= 32'h5000_0000 + g;   // this slave's tag
            end else if (s_rready[g])              s_rvalid_q[g] <= 1'b0;
        end
    end
end endgenerate

// ---------------------------------------------------------------------------
// bus access
// ---------------------------------------------------------------------------
reg [1:0] rresp_got, bresp_got;   // last response, checked by the tasks below

task do_read(input [31:0] a);
    integer to;
    begin
        @(posedge clk) #1;
        m_araddr = a; m_arvalid = 1'b1; m_rready = 1'b1;
        to = 0;
        while (!(m_arvalid && m_arready) && to < 50) begin @(posedge clk); to = to + 1; end
        #1 m_arvalid = 1'b0;
        to = 0;
        while (!m_rvalid && to < 50) begin @(posedge clk); to = to + 1; end
        #1 rd = m_rdata;
        rresp_got = m_rresp;
        @(posedge clk) #1 m_rready = 1'b0;
    end
endtask

task do_write(input [31:0] a);
    integer to;
    begin
        @(posedge clk) #1;
        m_awaddr = a; m_awvalid = 1'b1;
        m_wdata = 32'hA5A5_A5A5; m_wstrb = 4'hF; m_wvalid = 1'b1; m_bready = 1'b1;
        to = 0;
        while (!(m_awvalid && m_awready) && to < 50) begin @(posedge clk); to = to + 1; end
        #1 m_awvalid = 1'b0; m_wvalid = 1'b0;
        to = 0;
        while (!m_bvalid && to < 50) begin @(posedge clk); to = to + 1; end
        #1 bresp_got = m_bresp;
        @(posedge clk) #1 m_bready = 1'b0;
    end
endtask


// an address that must reach slave `slv`
task expect_hit(input [31:0] a, input integer slv, input [511:0] name);
    begin
        do_read(a);
        if (rresp_got === RESP_OKAY && rd === (32'h5000_0000 + slv))
            $display("PASS: %0s (0x%08h -> slave %0d)", name, a, slv);
        else begin
            $display("FAIL: %0s (0x%08h -> rresp=%b data=0x%08h, wanted slave %0d)",
                     name, a, rresp_got, rd, slv);
            errors = errors + 1;
        end
    end
endtask

// an address that must reach nothing, on both channels
task expect_decerr(input [31:0] a, input [511:0] name);
    begin
        do_read(a);
        if (rresp_got === RESP_DECERR)
            $display("PASS: %0s, read (0x%08h)", name, a);
        else begin
            $display("FAIL: %0s, read (0x%08h -> rresp=%b data=0x%08h)",
                     name, a, rresp_got, rd);
            errors = errors + 1;
        end
        do_write(a);
        if (bresp_got === RESP_DECERR)
            $display("PASS: %0s, write (0x%08h)", name, a);
        else begin
            $display("FAIL: %0s, write (0x%08h -> bresp=%b)", name, a, bresp_got);
            errors = errors + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
initial begin
    m_awaddr = 0; m_wdata = 0; m_araddr = 0; m_wstrb = 0;
    m_awvalid = 0; m_wvalid = 0; m_bready = 0; m_arvalid = 0; m_rready = 0;
    rresp_got = 2'b00; bresp_got = 2'b00;

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("=====================================================");
    $display("== SOC ADDRESS MAP: WINDOWS AND ALIASING ==");
    $display("=====================================================");

    $display("\n-- every window routes to its own block --");
    expect_hit(`SOC_DMEM_BASE,                 SD_DMEM, "DMEM base");
    expect_hit(`SOC_DMEM_BASE + 32'h1FFC,      SD_DMEM, "DMEM last word");
    expect_hit(`SOC_SRAM_BASE,                 SD_SRAM, "SRAM base");
    expect_hit(`SOC_SRAM_BASE + 32'h3FC,       SD_SRAM, "SRAM last word");
    expect_hit(`SOC_PIC_BASE,                  SD_PIC,  "PIC base");
    expect_hit(`SOC_PIC_BASE  + 32'hFC,        SD_PIC,  "PIC last register");
    expect_hit(`SOC_TMR_BASE,                  SD_TMR,  "machine timer base");
    expect_hit(`SOC_TMR_BASE  + 32'hFC,        SD_TMR,  "machine timer last register");
    expect_hit(`SOC_DMA_BASE,                  SD_DMA,  "DMA base");
    expect_hit(`SOC_DMA_BASE  + 32'hFC,        SD_DMA,  "DMA last register");

    $display("\n-- one byte past a block is not that block again --");
    $display("   The peripherals decode 8 address bits. Anything above that");
    $display("   repeats their register file unless the window stops first.");
    expect_decerr(`SOC_PIC_BASE  + 32'h100,  "PIC + 0x100 is not SRC0_CONFIG");
    expect_decerr(`SOC_PIC_BASE  + 32'h1D8,  "PIC + 0x1D8 is not INT_ENABLE");
    expect_decerr(`SOC_TMR_BASE  + 32'h100,  "timer + 0x100 is not MTIME_LO");
    expect_decerr(`SOC_TMR_BASE  + 32'h108,  "timer + 0x108 is not MTIMECMP_LO");
    expect_decerr(`SOC_DMA_BASE  + 32'h100,  "DMA + 0x100 is not CH0_DESC");
    expect_decerr(`SOC_SRAM_BASE + 32'h400,  "SRAM + 0x400 is not its register bank");
    expect_decerr(`SOC_DMEM_BASE + 32'h2000, "DMEM + 8 KB is not DMEM word 0");

    $display("\n-- the gaps between windows stay unmapped --");
    expect_decerr(32'h2000_0000, "the gap below the peripherals");
    expect_decerr(32'h3000_8000, "halfway between the PIC and the timer");
    expect_decerr(32'h3003_0000, "above the last peripheral");
    expect_decerr(32'h5000_0000, "far outside every window");

    $display("\n=====================================================");
    if (errors == 0) $display("== SOC ADDRESS MAP TESTBENCH: ALL TESTS PASSED ==");
    else             $display("== SOC ADDRESS MAP TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("=====================================================");
    $finish;
end

initial begin
    #500000;
    $display("FAIL: timeout - tb_addr_map never reached the end");
    $finish;
end

endmodule
