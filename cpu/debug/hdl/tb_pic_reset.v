// ===========================================================================
// tb_pic_reset - reset verification for the PIC (hdl/pic.v)
// ===========================================================================
//
// OBJECTIVE
//   Prove the reset contract of the block, which the design documentation
//   states as: every flop in the PIC is reset by the asynchronous active-low
//   rst_n; no flop leaves reset holding X; every readable register returns its
//   documented reset value on the very first access; and the block leaves reset
//   fully disarmed, so nothing can reach the CPU until software opts in.
//
//   This is separated from the feature bench (tb_pic.v) on purpose. A reset
//   defect is a "first cycle after power-up" defect, and a bench that spends
//   its first hundred cycles configuring the block cannot see one.
//
// WHAT IS CHECKED, AND WHY EACH CHECK EARNS ITS PLACE
//   1  While rst_n is low, the AXI4-Lite slave port is legal and X-free.
//      BVALID/RVALID must be low (IHI0022E A3.1.2), and BRESP/RRESP/RDATA must
//      not be X. An X on a response code is indistinguishable from a real
//      protocol violation to a monitor, and it propagates into whatever the
//      CPU does with the response.
//   2  Every mapped register reads its documented reset value, one register at
//      a time, all 16 instances of each per-source register included. A per-
//      source register that resets correctly at index 0 and not at index 11 is
//      exactly the defect a "spot check index 0" test misses.
//   3  The CPU-side outputs (cpu_irq, cpu_irq_vec) are inactive and defined.
//   4  Internal state that is NOT visible through a register - the nesting
//      stack arrays - is X-free. These are the flops a "the valid bit covers
//      it" argument would normally leave unreset, so they are the ones worth
//      probing directly.
//   5  Reset is asynchronous and dominant: the block is driven into a fully
//      configured, nested state, rst_n is then dropped BETWEEN clock edges, and
//      every register must be back at its reset value. This is the check that
//      distinguishes a real reset from a simulation-only initial value.
//   6  The block is disarmed after reset: a source line held high produces no
//      request, because INT_ENABLE reset to 0.
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow.
// ===========================================================================

`timescale 1ns/1ps

module tb_pic_reset;

// ---- register map (byte offsets) ----
localparam CFG0 = 32'h00, SWT0 = 32'h40, STA0 = 32'h80;
localparam BAND_CONFIG   = 32'hC0, NEST_STATUS  = 32'hC4, NEST_MAX_R = 32'hC8,
           ACTIVE_VEC    = 32'hCC, SPURIOUS_LOG = 32'hD0, ESCALATION = 32'hD4,
           INT_ENABLE    = 32'hD8, INT_STATUS   = 32'hDC;
localparam RESP_OKAY = 2'b00;
localparam SW_KEY    = 16'hA5A5;

// ---- documented reset values ----
localparam [31:0] RST_CFG   = 32'h0000_0000;
localparam [31:0] RST_SWT   = 32'h0000_0000;
localparam [31:0] RST_STA   = 32'h0000_0000;
localparam [31:0] RST_BAND  = 32'h0000_001B;   // band0=3 (most urgent) .. band3=0
localparam [31:0] RST_NESTS = 32'h0000_0000;
localparam [31:0] RST_NMAX  = 32'h0000_0008;
localparam [31:0] RST_AVEC  = 32'h0000_0000;
localparam [31:0] RST_SPUR  = 32'h0000_0000;
localparam [31:0] RST_ESC   = 32'h0000_0000;
localparam [31:0] RST_INTEN = 32'h0000_0000;
localparam [31:0] RST_INTST = 32'h0000_0000;

// ---- clock / reset ----
reg clk   = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

// ---- DUT source / CPU pins ----
reg  [15:0] irq_src;
reg         cpu_irq_ack, cpu_irq_eoi;
wire        cpu_irq;
wire [3:0]  cpu_irq_vec;

// ---- AXI4-Lite master side ----
reg  [31:0] awaddr, wdata, araddr;
reg  [3:0]  wstrb;
reg         awvalid, wvalid, bready, arvalid, rready;
wire        awready, wready, bvalid, arready, rvalid;
wire [1:0]  bresp, rresp;
wire [31:0] rdata;

integer errors = 0;
integer i;
reg [31:0] rd;
`include "tb_check.vh"
`include "tb_axil_master.vh"

wire [15:0] pic_pending;
pic dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .irq_src_i(irq_src),
    .cpu_mask_i(16'hFFFF),          // no CPU-side mask in the standalone bench
    .cpu_irq_o(cpu_irq), .cpu_irq_vec_o(cpu_irq_vec), .pending_o(pic_pending),
    .cpu_irq_ack_i(cpu_irq_ack), .cpu_irq_eoi_i(cpu_irq_eoi),
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(3'b0), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(3'b0), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready)
);

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// A value that contains any X or Z reduces to X under the reduction-XOR
// operator. Checking this explicitly matters because `check` uses === and would
// report an undefined value as a wrong value rather than as an undefined one.
task chk_defined(input [31:0] v, input [511:0] name);
    begin
        if ((^v) === 1'bx) begin
            $display("FAIL: %0s is not fully defined (value = %b)", name, v);
            errors = errors + 1;
        end else
            $display("PASS: %0s fully defined = 0x%08h", name, v);
    end
endtask

// per-source register address helpers
function [31:0] CFG; input [31:0] k; CFG = CFG0 + (k << 2); endfunction
function [31:0] SWT; input [31:0] k; SWT = SWT0 + (k << 2); endfunction
function [31:0] STA; input [31:0] k; STA = STA0 + (k << 2); endfunction

// Read back the complete register map and compare against the reset values.
// Used twice: once out of power-on reset, once out of a mid-operation reset.
task check_full_reset_map(input [511:0] tag);
    begin
        $display("  reading back all 56 mapped registers (%0s)", tag);
        for (i = 0; i < 16; i = i + 1) begin
            axil_read(CFG(i), RESP_OKAY); check(RST_CFG, rd, "  SRCx_CONFIG   reset value");
            axil_read(SWT(i), RESP_OKAY); check(RST_SWT, rd, "  SRCx_SW_TRIG  reset value");
            axil_read(STA(i), RESP_OKAY); check(RST_STA, rd, "  SRCx_STATUS   reset value");
        end
        axil_read_chk(BAND_CONFIG,  RST_BAND,  "  BAND_CONFIG    reset = 0x1B");
        axil_read_chk(NEST_STATUS,  RST_NESTS, "  NEST_STATUS    reset = 0");
        axil_read_chk(NEST_MAX_R,   RST_NMAX,  "  NEST_MAX       reset = 8");
        axil_read_chk(ACTIVE_VEC,   RST_AVEC,  "  ACTIVE_VEC     reset = 0");
        axil_read_chk(SPURIOUS_LOG, RST_SPUR,  "  SPURIOUS_LOG   reset = 0");
        axil_read_chk(ESCALATION,   RST_ESC,   "  ESCALATION_CFG reset = 0");
        axil_read_chk(INT_ENABLE,   RST_INTEN, "  INT_ENABLE     reset = 0");
        axil_read_chk(INT_STATUS,   RST_INTST, "  INT_STATUS     reset = 0");
    end
endtask

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------
initial begin
    $display("\n===========================================================");
    $display("tb_pic_reset : reset verification for hdl/pic.v");
    $display("===========================================================");

    irq_src = 16'b0; cpu_irq_ack = 1'b0; cpu_irq_eoi = 1'b0;
    axil_idle;
    rst_n = 1'b0;

    // ===== 1. bus and CPU outputs while reset is asserted ==================
    $display("\n-- 1. slave port and CPU outputs while rst_n is LOW --");
    $display("   step 1: hold rst_n = 0 for 4 clock cycles");
    axil_step(4);
    $display("   step 2: sample the slave outputs mid-reset");
    check(32'd0, {31'b0, bvalid},   "  BVALID low during reset (IHI0022E A3.1.2)");
    check(32'd0, {31'b0, rvalid},   "  RVALID low during reset (IHI0022E A3.1.2)");
    chk_defined({30'b0, bresp},  "BRESP during reset");
    chk_defined({30'b0, rresp},  "RRESP during reset");
    chk_defined(rdata,           "RDATA during reset");
    check(32'd0, {30'b0, bresp}, "  BRESP reads OKAY during reset");
    check(32'd0, {30'b0, rresp}, "  RRESP reads OKAY during reset");
    check(32'd0, rdata,          "  RDATA is 0 during reset");
    $display("   step 3: sample the CPU-side outputs mid-reset");
    check(32'd0, {31'b0, cpu_irq},      "  cpu_irq low during reset");
    check(32'd0, {28'b0, cpu_irq_vec},  "  cpu_irq_vec = 0 during reset");

    // ===== 2. release reset, read the whole map ============================
    $display("\n-- 2. every mapped register reads its documented reset value --");
    $display("   step 1: release rst_n between clock edges");
    @(posedge clk) #1 rst_n = 1'b1;
    axil_step(2);
    $display("   step 2: read all 16 SRCx_CONFIG, 16 SRCx_SW_TRIG, 16 SRCx_STATUS");
    $display("           and the 8 global registers, comparing each to its reset value");
    check_full_reset_map("power-on reset");

    // ===== 3. CPU-side outputs after reset =================================
    $display("\n-- 3. CPU-side outputs after reset --");
    check(32'd0, {31'b0, cpu_irq},     "  cpu_irq inactive after reset");
    check(32'd0, {28'b0, cpu_irq_vec}, "  cpu_irq_vec = 0 after reset");
    chk_defined({31'b0, cpu_irq},      "cpu_irq after reset");
    chk_defined({28'b0, cpu_irq_vec},  "cpu_irq_vec after reset");

    // ===== 4. internal state not visible through a register ================
    // The nesting stack is the state a "the valid bit covers it" argument would
    // normally leave unreset. NEST_STATUS.TOP_ID and ACTIVE_VEC.ID read it, so
    // an unreset stack would put X on a register read after the first claim.
    $display("\n-- 4. nesting-stack arrays are X-free after reset --");
    $display("   step 1: probe all 16 stack entries directly (hierarchical read)");
    for (i = 0; i < 16; i = i + 1) begin
        chk_defined({28'b0, dut.stack_id[i]},  "stack_id entry after reset");
        chk_defined({22'b0, dut.stack_key[i]}, "stack_key entry after reset");
    end
    check(32'd0, {27'b0, dut.depth}, "  nesting depth = 0 after reset");

    // ===== 5. asynchronous reset from a fully-loaded state =================
    // Everything below is set to a NON-reset value first, so a register that is
    // simply never written cannot pass this check by accident.
    $display("\n-- 5. asynchronous reset from a fully configured, nested state --");
    $display("   step 1: program every global register away from its reset value");
    axil_write(BAND_CONFIG,  32'h0000_0027, RESP_OKAY);   // reorder the bands
    axil_write(NEST_MAX_R,   32'd4,         RESP_OKAY);   // depth limit 4
    axil_write(ESCALATION,   32'h0000_0110, RESP_OKAY);   // bump mode + multi
    axil_write(INT_ENABLE,   32'h0000_FFFF, RESP_OKAY);   // all sources enabled
    $display("   step 2: program all 16 SRCx_CONFIG and set all 16 software channels");
    for (i = 0; i < 16; i = i + 1) begin
        // deadline 0x20, intra = index, band 3, level-triggered
        axil_write(CFG(i), {16'h0020, 8'h00, i[3:0], 4'h6}, RESP_OKAY);
        axil_write(SWT(i), {SW_KEY, 16'h0001}, RESP_OKAY);
    end
    $display("   step 3: raise two source lines and claim two levels of nesting");
    irq_src[2] = 1'b1; irq_src[9] = 1'b1;
    axil_step(4);
    @(posedge clk) #1 cpu_irq_ack = 1'b1; @(posedge clk) #1 cpu_irq_ack = 1'b0;
    axil_step(3);
    @(posedge clk) #1 cpu_irq_ack = 1'b1; @(posedge clk) #1 cpu_irq_ack = 1'b0;
    axil_step(6);
    $display("   step 4: confirm the block really is in a non-reset state first");
    axil_read(NEST_STATUS, RESP_OKAY);
    if ((rd & 32'h1F) == 32'd0) begin
        $display("FAIL: precondition - expected a non-zero nesting depth before reset");
        errors = errors + 1;
    end else
        $display("PASS: precondition - depth = %0d, block is loaded", rd & 32'h1F);
    axil_read(BAND_CONFIG, RESP_OKAY);
    check(32'h0000_0027, rd, "  precondition - BAND_CONFIG holds the written value");

    $display("   step 5: assert rst_n asynchronously, off a clock edge");
    #3 rst_n = 1'b0;                  // deliberately not aligned to posedge clk
    #7;
    check(32'd0, {31'b0, cpu_irq}, "  cpu_irq drops asynchronously with rst_n");
    $display("   step 6: hold reset 3 cycles, then release it between edges");
    axil_step(3);
    @(posedge clk) #1 rst_n = 1'b1;
    irq_src = 16'b0;
    axil_step(2);
    $display("   step 7: read the whole register map again - every value must be back");
    check_full_reset_map("asynchronous mid-operation reset");
    for (i = 0; i < 16; i = i + 1) begin
        chk_defined({28'b0, dut.stack_id[i]},  "stack_id entry after re-reset");
        chk_defined({22'b0, dut.stack_key[i]}, "stack_key entry after re-reset");
    end
    check(32'd0, {27'b0, dut.depth}, "  nesting depth back to 0 after re-reset");

    // ===== 6. the block is disarmed out of reset ===========================
    // INT_ENABLE resetting to 0 is what makes this true, and it is the property
    // the integration relies on: a peripheral that already drives its line at
    // power-up must not produce an interrupt before software is ready for it.
    $display("\n-- 6. the block is disarmed out of reset --");
    $display("   step 1: hold source 4 high with no configuration written at all");
    irq_src[4] = 1'b1;
    axil_step(8);
    $display("   step 2: cpu_irq must stay low, because INT_ENABLE reset to 0");
    check(32'd0, {31'b0, cpu_irq}, "  no request from a source that is not enabled");
    axil_read(STA(4), RESP_OKAY);
    check(32'd0, rd & 32'h1, "  SRC4_STATUS.PEND stays 0 while the source is masked");
    $display("   step 3: enable source 4 - the same line must now be seen");
    $display("           (this proves step 2 was masking, not a dead source line)");
    axil_write(INT_ENABLE, 32'h0000_0010, RESP_OKAY);
    axil_step(4);
    check(32'd1, {31'b0, cpu_irq}, "  request appears once software enables it");
    irq_src[4] = 1'b0;

    // ---- done ----
    axil_step(4);
    $display("\n========================================");
    if (errors == 0)
        $display("== PIC RESET TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== PIC RESET TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

// watchdog
initial begin
    #500000;
    $display("FAIL: tb_pic_reset timeout");
    $finish;
end

endmodule
