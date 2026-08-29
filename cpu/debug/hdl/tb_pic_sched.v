// PIC scheduling corner cases (hdl/pic.v).
//
// tb_pic covers each brief feature once on its natural, well-behaved path. The
// four cases here are the ones where two things happen at once, or where a
// programmable field is set to something other than its default, and each was a
// real defect before it was a test:
//
//   1  the CPU mask takes part in the resolution. A source the core has masked
//      in mie must not be selected, or the resolver parks on it and every less
//      urgent source starves behind it. It stays pending, so it is offered the
//      moment the mask lifts.
//   2  pending_o reports what is pending, not what was selected, so mip can
//      show sources queued behind the winner and sources the mask holds back.
//   3  a rising edge that lands in the same cycle as the claim survives it.
//      They are two separate events and the second one still needs servicing.
//   4  "bump one band more urgent" follows the urgency order BAND_CONFIG
//      defines. Under a reordered BAND_CONFIG the numerically lower band can be
//      the less urgent one, and a bump that went to band-1 would demote the
//      source it was supposed to rescue.
//   5  the software-trigger key has to be written, not merely present on the
//      bus: on a byte write the unstrobed lanes carry whatever the master left
//      there, so a value-only check can be satisfied by accident.
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; ModelSim flow (compile.do, run 7 of regress.do).

`timescale 1ns/1ps

module tb_pic_sched;

// ---- register map (byte offsets) ----
localparam CFG0 = 32'h00, SWT0 = 32'h40, STA0 = 32'h80;
localparam BAND_CONFIG = 32'hC0, ESCALATION = 32'hD4,
           INT_ENABLE  = 32'hD8;
localparam RESP_OKAY = 2'b00;

// ---- clock / reset ----
reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

// ---- DUT source / CPU pins ----
reg  [15:0] irq_src;
reg  [15:0] cpu_mask;
reg         cpu_irq_ack, cpu_irq_eoi;
wire        cpu_irq;
wire [3:0]  cpu_irq_vec;
wire [15:0] pending;

// ---- AXI4-Lite master side ----
reg  [31:0] awaddr, wdata, araddr;
reg  [3:0]  wstrb;
reg         awvalid, wvalid, bready, arvalid, rready;
wire        awready, wready, bvalid, arready, rvalid;
wire [1:0]  bresp, rresp;
wire [31:0] rdata;

integer errors = 0;
reg [31:0] rd;
`include "tb_check.vh"
`include "tb_axil_master.vh"

pic dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .irq_src_i(irq_src),
    .cpu_mask_i(cpu_mask),
    .cpu_irq_o(cpu_irq), .cpu_irq_vec_o(cpu_irq_vec), .pending_o(pending),
    .cpu_irq_ack_i(cpu_irq_ack), .cpu_irq_eoi_i(cpu_irq_eoi),
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(3'b0), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(3'b0), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready)
);

// ---------------------------------------------------------------------------
// handshake helpers
// ---------------------------------------------------------------------------

// wait until `ev` is the offered source, up to `lim` cycles
task expect_offer(input [3:0] ev, input integer lim, input [511:0] msg);
    integer to;
    begin
        to = 0;
        while (!(cpu_irq === 1'b1 && cpu_irq_vec === ev) && to < lim) begin
            @(posedge clk); to = to + 1;
        end
        if (cpu_irq === 1'b1 && cpu_irq_vec === ev)
            $display("PASS: %0s", msg);
        else begin
            $display("FAIL: %0s (cpu_irq=%b vec=%0d after %0d cycles)",
                     msg, cpu_irq, cpu_irq_vec, to);
            errors = errors + 1;
        end
    end
endtask

// `ev` must not be offered at any point in the next `lim` cycles
task expect_never(input [3:0] ev, input integer lim, input [511:0] msg);
    integer to;
    reg     seen;
    begin
        seen = 1'b0;
        for (to = 0; to < lim; to = to + 1) begin
            @(posedge clk);
            if (cpu_irq === 1'b1 && cpu_irq_vec === ev) seen = 1'b1;
        end
        if (!seen) $display("PASS: %0s", msg);
        else begin
            $display("FAIL: %0s (it was offered)", msg);
            errors = errors + 1;
        end
    end
endtask

task pulse_ack;
    begin
        @(posedge clk) #1; cpu_irq_ack = 1'b1;
        @(posedge clk) #1; cpu_irq_ack = 1'b0;
    end
endtask

task pulse_eoi;
    begin
        @(posedge clk) #1; cpu_irq_eoi = 1'b1;
        @(posedge clk) #1; cpu_irq_eoi = 1'b0;
    end
endtask

// bring the PIC back to reset between the independent cases
task reset_dut;
    begin
        rst_n = 1'b0;
        irq_src = 16'b0; cpu_mask = 16'hFFFF;
        cpu_irq_ack = 1'b0; cpu_irq_eoi = 1'b0;
        axil_idle;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (2) @(posedge clk);
    end
endtask

// ---------------------------------------------------------------------------
initial begin
    $display("=====================================================");
    $display("== PIC SCHEDULING CORNER CASES ==");
    $display("=====================================================");

    // -----------------------------------------------------------------------
    // 1 + 2: a CPU-masked source must not block the ones behind it
    //
    // src2 and src9 are both enabled and both asserted. Their keys differ only
    // by index, so src2 (the lower index) outranks src9 and is the natural
    // winner. The core masks src2 and only src2. A resolver that ignores the
    // mask keeps offering src2, the core never claims it, and src9 waits
    // forever; the offer has to be src9 instead. src2 still has to appear in
    // pending_o, because mip reports what is pending and software has to be
    // able to see it.
    // -----------------------------------------------------------------------
    $display("\n-- 1: a masked source does not starve the sources behind it --");
    reset_dut;
    axil_write(CFG0 + 4*2, 32'h0000_0000, RESP_OKAY);   // src2: level, band 0
    axil_write(CFG0 + 4*9, 32'h0000_0000, RESP_OKAY);   // src9: level, band 0
    axil_write(INT_ENABLE, 32'h0000_0204, RESP_OKAY);   // enable src2 + src9

    cpu_mask = 16'hFFFF & ~16'h0004;                    // mie masks src2 only
    #1 irq_src[2] = 1'b1;
    irq_src[9] = 1'b1;

    expect_offer(4'd9, 20, "the unmasked source behind the masked one is offered");
    expect_never(4'd2, 20, "the masked source is never offered");

    check(32'h0000_0204, {16'b0, pending},
          "pending_o shows both, masked included");

    // lifting the mask has to hand the higher-priority source straight over
    #1 cpu_mask = 16'hFFFF;
    expect_offer(4'd2, 20, "unmasking offers it on the next resolution");

    // -----------------------------------------------------------------------
    // 3: an edge that arrives in the claim cycle is not swallowed
    //
    // src3 is edge-triggered. One edge latches and is offered. The claim lands
    // in the same cycle as a second, distinct edge: the first is on its way to
    // the handler, the second still has to be serviced, so the latch must stay
    // set and the source must be offered again once the handler returns.
    // -----------------------------------------------------------------------
    $display("\n-- 3: a rising edge in the claim cycle survives the claim --");
    reset_dut;
    axil_write(CFG0 + 4*3, 32'h0000_0001, RESP_OKAY);   // src3: edge-triggered
    axil_write(INT_ENABLE, 32'h0000_0008, RESP_OKAY);

    @(posedge clk) #1 irq_src[3] = 1'b1;                // first edge
    @(posedge clk) #1 irq_src[3] = 1'b0;
    expect_offer(4'd3, 20, "the first edge is latched and offered");

    // claim and a fresh rising edge on the same clock edge
    @(posedge clk) #1;
    cpu_irq_ack = 1'b1;
    irq_src[3]  = 1'b1;                                 // 0 -> 1 this cycle
    @(posedge clk) #1;
    cpu_irq_ack = 1'b0;
    irq_src[3]  = 1'b0;

    pulse_eoi;                                          // handler returns
    expect_offer(4'd3, 20, "the edge that arrived with the claim is still pending");

    // -----------------------------------------------------------------------
    // 4: bump follows the urgency order, not the band number
    //
    // BAND_CONFIG is reordered so band 0 is the LEAST urgent (0) and band 3 the
    // next one up (1). src1 and src2 both sit in band 0, so src1 wins on index.
    // src2 has a deadline and escalates by bump. Bumping to band-1 would clamp
    // at band 0 and change nothing; bumping one step up the urgency order moves
    // src2 to band 3, which outranks band 0, and the offer flips to src2.
    // -----------------------------------------------------------------------
    $display("\n-- 4: bump escalation under a reordered BAND_CONFIG --");
    reset_dut;
    // urgency: band0=0, band1=3, band2=2, band3=1
    axil_write(BAND_CONFIG, 32'h0000_006C, RESP_OKAY);
    axil_write(ESCALATION,  32'h0000_0010, RESP_OKAY);  // MODE=bump, single
    axil_write(CFG0 + 4*1,  32'h0000_0000, RESP_OKAY);  // src1: band 0, no deadline
    axil_write(CFG0 + 4*2,  32'h000A_0000, RESP_OKAY);  // src2: band 0, deadline 10
    axil_write(INT_ENABLE,  32'h0000_0006, RESP_OKAY);

    #1 irq_src[1] = 1'b1;
    irq_src[2] = 1'b1;

    expect_offer(4'd1, 20, "before the deadline the lower index wins the band");
    expect_offer(4'd2, 40, "after the bump the escalated source outranks it");

    axil_read(STA0 + 4*2, RESP_OKAY);
    check(32'd1, {31'b0, rd[2]}, "SRC2_STATUS.ESC records the escalation");

    // -----------------------------------------------------------------------
    // 5: the software-trigger key must actually be written
    //
    // A byte write to lane 0 with the key value sitting on the unstrobed upper
    // lanes is not a keyed write: those lanes were never written. Only the
    // write that strobes the key lanes arms the channel.
    // -----------------------------------------------------------------------
    $display("\n-- 5: the software-trigger key has to be strobed --");
    reset_dut;
    axil_write(CFG0 + 4*0, 32'h0000_0000, RESP_OKAY);
    axil_write(INT_ENABLE, 32'h0000_0001, RESP_OKAY);

    // lane 0 only; the key is on the bus but not written
    axil_write_strb(SWT0 + 4*0, 32'hA5A5_0001, 4'b0001, RESP_OKAY);
    expect_never(4'd0, 10, "an unstrobed key does not arm the channel");

    // the whole word, key lanes included
    axil_write(SWT0 + 4*0, 32'hA5A5_0001, RESP_OKAY);
    expect_offer(4'd0, 20, "a strobed key arms the channel");

    // -----------------------------------------------------------------------
    $display("\n=====================================================");
    if (errors == 0) $display("== PIC SCHEDULING TESTBENCH: ALL TESTS PASSED ==");
    else             $display("== PIC SCHEDULING TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("=====================================================");
    $finish;
end

initial begin
    #200000;
    $display("FAIL: timeout - tb_pic_sched never reached the end");
    $finish;
end

endmodule
