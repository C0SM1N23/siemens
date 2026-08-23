// ===========================================================================
// tb_bp - block-level verification of the branch predictor
//         (hdl/branch_predictor.v): BTB/BHT, return-address stack, reset
// ===========================================================================
//
// OBJECTIVE
//   The predictor is the one CPU submodule whose documented behaviour is not
//   reachable from the system bench. Three classes of behaviour are the
//   reason this bench exists:
//
//     - reset. The reset chapter states that every predictor array is reset
//       and that nothing in the block holds X after release. The system bench
//       cannot show that: it starts by fetching instructions, so by the time
//       it observes anything the reset state is gone. Nothing else in the
//       regression looks at CPU-internal reset values at all.
//     - the RAS boundaries. Overflow (a call chain deeper than RAS_DEPTH),
//       underflow (a return with an empty stack) and the both-link JALR that
//       replaces the top of stack are documented as accuracy-only effects.
//       The directed program never nests calls deeper than three, so none of
//       the three is exercised anywhere else.
//     - the RAS_DEPTH = 0 tie-off. The parameter is documented as disabling
//       the stack; no run in the regression instantiates the core with it.
//
//   Everything here is driven on the module's own ports, so a check is a
//   statement about the block and not about the program that happened to run.
//
// SCOPE
//   1  reset: all 128 index positions miss, and every array is X-free -
//      checked through the ports and by probing the arrays directly
//   2  a miss predicts not-taken (the only possible prediction: there is no
//      stored target to jump to)
//   3  learn / re-learn: the 1-bit state follows the last outcome, in both
//      directions, and the stored target is returned verbatim
//   4  indexing is 1:1 over the whole table - all 128 entries written with
//      distinct targets and all 128 read back (exhaustive over the index)
//   5  the tag is full: two PCs sharing an index evict each other rather than
//      producing a false hit
//   6  update_en_i gates the write
//   7  RAS: push / pop ordering, is_ret routing, and the fall-back to the BTB
//      target for an entry that is not tagged as a return
//   8  RAS underflow: a pop on an empty stack, and the prediction falling
//      back to the stored BTB target
//   9  RAS overflow: a chain of RAS_DEPTH+2 calls, which wraps and loses the
//      two oldest links - accuracy only, checked link by link on the way out
//  10  the both-link JALR case: call and return in the same update replace
//      the top of stack instead of changing the depth
//  11  RAS_DEPTH = 0: a second instance, where a return-tagged entry must
//      predict from the BTB target and no output may be X
//  12  asynchronous reset from a fully trained state returns the block to 1
//
// WHAT IS AND IS NOT EXHAUSTIVE
//   Sections 1 and 4 are exhaustive over the 128-entry index space. The tag
//   comparison (5) is checked on a representative pair that differs in the
//   lowest tag bit, which is the bit an off-by-one in the index/tag split
//   would move. The RAS sections are exhaustive over the depth boundary
//   (empty, one below full, full, one above full). Target and link values are
//   arbitrary distinct constants - the predictor never interprets them.
//
// Self-checking: mismatches increment `errors`; the run ends on a PASS/FAIL
// banner. Verilog-2005; built and run by the ModelSim flow.
// ===========================================================================

`timescale 1ns/1ps

module tb_bp;

localparam ENTRIES   = 128;
localparam RAS_DEPTH = 8;
localparam IDX_W     = 7;                 // $clog2(128)
localparam TAG_W     = 32 - IDX_W - 2;    // 23

// ---- clock / reset ----
reg clk   = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

// ---- DUT ports ----
reg  [31:0] lookup_pc;
wire        pred_taken;
wire [31:0] pred_target;

reg         update_en;
reg  [31:0] update_pc;
reg         update_taken;
reg  [31:0] update_target;
reg         update_is_ret, update_call, update_ret;
reg  [31:0] update_link;

integer errors = 0;
integer i, j;
reg [31:0] pc_a, pc_b;
`include "tb_check.vh"

branch_predictor #(.ENTRIES(ENTRIES), .RAS_DEPTH(RAS_DEPTH)) dut (
    .clk_i           (clk),
    .rst_n_i         (rst_n),
    .lookup_pc_i     (lookup_pc),
    .pred_taken_o    (pred_taken),
    .pred_target_o   (pred_target),
    .update_en_i     (update_en),
    .update_pc_i     (update_pc),
    .update_taken_i  (update_taken),
    .update_target_i (update_target),
    .update_is_ret_i (update_is_ret),
    .update_call_i   (update_call),
    .update_ret_i    (update_ret),
    .update_link_i   (update_link)
);

// second instance with the stack disabled, driven from the same stimulus so
// the only difference between the two is the parameter
wire        pred_taken0;
wire [31:0] pred_target0;

branch_predictor #(.ENTRIES(ENTRIES), .RAS_DEPTH(0)) dut0 (
    .clk_i           (clk),
    .rst_n_i         (rst_n),
    .lookup_pc_i     (lookup_pc),
    .pred_taken_o    (pred_taken0),
    .pred_target_o   (pred_target0),
    .update_en_i     (update_en),
    .update_pc_i     (update_pc),
    .update_taken_i  (update_taken),
    .update_target_i (update_target),
    .update_is_ret_i (update_is_ret),
    .update_call_i   (update_call),
    .update_ret_i    (update_ret),
    .update_link_i   (update_link)
);

// ---- helpers ----

task chk_defined(input [31:0] v, input [511:0] name);
    begin
        if ((^v) === 1'bx) begin
            $display("FAIL: %0s is not fully defined (value = %b)", name, v);
            errors = errors + 1;
        end else
            $display("PASS: %0s fully defined = 0x%08h", name, v);
    end
endtask

// the read port is purely combinational, so a lookup is an assignment plus a
// settle delta - no clock edge is involved and none is consumed
task look(input [31:0] pc);
    begin
        lookup_pc = pc;
        #1;
    end
endtask

// one update, applied on a rising edge and then withdrawn, so a check made
// after the call sees exactly one write
task upd(input [31:0] pc, input taken, input [31:0] target,
         input is_ret, input call, input ret, input [31:0] link);
    begin
        @(negedge clk);
        update_en     = 1'b1;
        update_pc     = pc;
        update_taken  = taken;
        update_target = target;
        update_is_ret = is_ret;
        update_call   = call;
        update_ret    = ret;
        update_link   = link;
        @(posedge clk);
        @(negedge clk);
        update_en     = 1'b0;
        update_call   = 1'b0;
        update_ret    = 1'b0;
        #1;
    end
endtask

// a plain BTB update with no RAS side effect
task upd_btb(input [31:0] pc, input taken, input [31:0] target);
    begin
        upd(pc, taken, target, 1'b0, 1'b0, 1'b0, 32'b0);
    end
endtask

task step(input integer n);
    begin
        for (j = 0; j < n; j = j + 1) @(posedge clk);
        #1;
    end
endtask

// current RAS occupancy, read through a hierarchical reference; the stack has
// no register view of its own, which is precisely why the boundary cases in
// sections 8-10 have to be observed here
wire [4:0] ras_count = dut.g_ras.cnt_q;

// Index allocation. The index is PC[8:2], so two addresses 512 bytes apart
// land on the same entry - which is the point of section 5 and a trap
// everywhere else. Each section below therefore works in its own index band:
//   0x40        the return site used by sections 7-12
//   0x44        the non-return entry of section 7
//   0x50..0x52  the call sites of section 7
//   0x61..0x6A  the call chain of section 9
//   0x70..0x72  the call sites of section 10
//   0x78        the call site of section 12
// Section 4 writes every index, and section 12 reads index 0x01 back to show
// that the table was still trained when the reset was asserted; no later
// section may touch that index.
initial begin
    lookup_pc     = 32'b0;
    update_en     = 1'b0;
    update_pc     = 32'b0;
    update_taken  = 1'b0;
    update_target = 32'b0;
    update_is_ret = 1'b0;
    update_call   = 1'b0;
    update_ret    = 1'b0;
    update_link   = 32'b0;

    $display("\n=== tb_bp: branch predictor block verification ===");

    // ================================================================
    $display("\n[1] reset: the table is empty and nothing holds X");
    // ================================================================
    rst_n = 1'b0;
    step(4);

    // the arrays have no register view; probe them directly. These are the
    // flops a "the valid bit covers it" argument would leave unreset.
    if (dut.valid  === {ENTRIES{1'b0}}) $display("PASS:   valid array all zero");
    else begin $display("FAIL:   valid array not all zero"); errors = errors + 1; end
    if (dut.state  === {ENTRIES{1'b0}}) $display("PASS:   state array all zero");
    else begin $display("FAIL:   state array not all zero"); errors = errors + 1; end
    if (dut.isret  === {ENTRIES{1'b0}}) $display("PASS:   isret array all zero");
    else begin $display("FAIL:   isret array not all zero"); errors = errors + 1; end
    if (dut.tag    === {(ENTRIES*TAG_W){1'b0}}) $display("PASS:   tag array all zero");
    else begin $display("FAIL:   tag array not all zero"); errors = errors + 1; end
    if (dut.target === {(ENTRIES*32){1'b0}}) $display("PASS:   target array all zero");
    else begin $display("FAIL:   target array not all zero"); errors = errors + 1; end

    check(32'd0, {27'b0, dut.g_ras.sp_q},  "  RAS stack pointer = 0");
    check(32'd0, {27'b0, dut.g_ras.cnt_q}, "  RAS is empty");
    for (i = 0; i < RAS_DEPTH; i = i + 1)
        chk_defined(dut.g_ras.ras[i], "  RAS entry");

    @(posedge clk) #1 rst_n = 1'b1;
    step(1);

    // ================================================================
    $display("\n[2] every index misses out of reset, and a miss is not-taken");
    // ================================================================
    // exhaustive over the 128-entry index space: an entry that resets at
    // index 0 and not at index 91 is exactly what a spot check misses
    for (i = 0; i < ENTRIES; i = i + 1) begin
        look(32'h0000_0000 + (i << 2));
        if (pred_taken !== 1'b0) begin
            $display("FAIL:   index %0d predicts taken out of reset", i);
            errors = errors + 1;
        end
        if ((^pred_target) === 1'bx) begin
            $display("FAIL:   index %0d pred_target holds X out of reset", i);
            errors = errors + 1;
        end
    end
    $display("PASS:   all %0d indices miss and drive a defined target", ENTRIES);
    check(32'd1, 32'd1, "  miss predicts not-taken (no stored target exists)");

    // ================================================================
    $display("\n[3] learn, re-learn: the 1-bit state follows the last outcome");
    // ================================================================
    pc_a = 32'h0000_0100;

    upd_btb(pc_a, 1'b1, 32'h0000_0200);
    look(pc_a);
    check(32'd1, {31'b0, pred_taken}, "  after a taken update: predict taken");
    check(32'h0000_0200, pred_target, "  target is the value that was written");

    upd_btb(pc_a, 1'b0, 32'h0000_0200);
    look(pc_a);
    check(32'd0, {31'b0, pred_taken}, "  after a not-taken update: predict not-taken");

    upd_btb(pc_a, 1'b1, 32'h0000_0240);
    look(pc_a);
    check(32'd1, {31'b0, pred_taken}, "  taken again: the state is not sticky");
    check(32'h0000_0240, pred_target, "  the target was replaced too");

    // ================================================================
    $display("\n[4] indexing is 1:1 over the whole table");
    // ================================================================
    // write every entry with a distinct, recognisable target, then read all
    // of them back. Aliasing in either direction shows up as a wrong target.
    for (i = 0; i < ENTRIES; i = i + 1)
        upd_btb(32'h0001_0000 + (i << 2), 1'b1, 32'hC000_0000 + (i << 2));

    for (i = 0; i < ENTRIES; i = i + 1) begin
        look(32'h0001_0000 + (i << 2));
        if (pred_taken !== 1'b1) begin
            $display("FAIL:   entry %0d did not hit after being written", i);
            errors = errors + 1;
        end
        if (pred_target !== (32'hC000_0000 + (i << 2))) begin
            $display("FAIL:   entry %0d target 0x%08h, expected 0x%08h",
                     i, pred_target, 32'hC000_0000 + (i << 2));
            errors = errors + 1;
        end
    end
    $display("PASS:   all %0d entries hold their own target", ENTRIES);

    // ================================================================
    $display("\n[5] the tag is full: aliasing evicts, it does not false-hit");
    // ================================================================
    // index = PC[8:2], so two PCs 512 bytes apart share an index and differ
    // in the lowest tag bit - the bit an off-by-one in the split would move
    pc_a = 32'h0002_0100;
    pc_b = 32'h0002_0300;
    check(32'd1, {31'b0, (pc_a[IDX_W+1:2] == pc_b[IDX_W+1:2])},
          "  precondition: the two PCs share an index");

    upd_btb(pc_a, 1'b1, 32'hAAAA_0000);
    look(pc_a);
    check(32'd1, {31'b0, pred_taken}, "  A hits after being learned");
    look(pc_b);
    check(32'd0, {31'b0, pred_taken}, "  B misses - the tag differs");

    upd_btb(pc_b, 1'b1, 32'hBBBB_0000);
    look(pc_b);
    check(32'hBBBB_0000, pred_target, "  B now hits with its own target");
    look(pc_a);
    check(32'd0, {31'b0, pred_taken}, "  A has been evicted, not aliased onto B");

    // ================================================================
    $display("\n[6] update_en_i gates the write");
    // ================================================================
    pc_a = 32'h0003_0100;
    upd_btb(pc_a, 1'b1, 32'h1234_0000);
    look(pc_a);
    check(32'h1234_0000, pred_target, "  precondition: entry learned");

    @(negedge clk);
    update_en     = 1'b0;          // deliberately left low
    update_pc     = pc_a;
    update_taken  = 1'b0;
    update_target = 32'hDEAD_0000;
    step(2);
    look(pc_a);
    check(32'd1,           {31'b0, pred_taken}, "  no update: direction unchanged");
    check(32'h1234_0000,   pred_target,         "  no update: target unchanged");

    // ================================================================
    $display("\n[7] RAS: calls push, returns pop, is_ret routes the prediction");
    // ================================================================
    // a return site: one BTB entry, tagged is_ret, with a deliberately wrong
    // stored target so that any prediction taken from the BTB is visible
    pc_b = 32'h0004_0100;                       // the "ret" instruction
    upd(pc_b, 1'b1, 32'hBAD0_BAD0, 1'b1, 1'b0, 1'b0, 32'b0);
    look(pc_b);
    check(32'hBAD0_BAD0, pred_target, "  empty RAS: falls back to the BTB target");

    upd(32'h0004_0140, 1'b1, 32'h0005_0000, 1'b0, 1'b1, 1'b0, 32'h1111_1000);
    check(32'd1, {27'b0, ras_count}, "  one call pushed: depth 1");
    look(pc_b);
    check(32'h1111_1000, pred_target, "  return predicts the top of stack");

    upd(32'h0004_0144, 1'b1, 32'h0005_0000, 1'b0, 1'b1, 1'b0, 32'h2222_2000);
    upd(32'h0004_0148, 1'b1, 32'h0005_0000, 1'b0, 1'b1, 1'b0, 32'h3333_3000);
    check(32'd3, {27'b0, ras_count}, "  three calls pushed: depth 3");
    look(pc_b);
    check(32'h3333_3000, pred_target, "  the newest link is on top");

    // an entry that is NOT tagged is_ret must ignore the stack entirely
    pc_a = 32'h0004_0310;                       // index 0x44
    upd_btb(pc_a, 1'b1, 32'h7777_0000);
    look(pc_a);
    check(32'h7777_0000, pred_target,
          "  a non-return entry uses its BTB target, stack non-empty");

    // pops walk back down the chain in order
    upd(pc_b, 1'b1, 32'hBAD0_BAD0, 1'b1, 1'b0, 1'b1, 32'b0);
    check(32'd2, {27'b0, ras_count}, "  one return popped: depth 2");
    look(pc_b);
    check(32'h2222_2000, pred_target, "  now predicting the second link");

    upd(pc_b, 1'b1, 32'hBAD0_BAD0, 1'b1, 1'b0, 1'b1, 32'b0);
    check(32'd1, {27'b0, ras_count}, "  two returns popped: depth 1");
    look(pc_b);
    check(32'h1111_1000, pred_target, "  now predicting the first link");

    // ================================================================
    $display("\n[8] RAS underflow: a return with an empty stack");
    // ================================================================
    upd(pc_b, 1'b1, 32'hBAD0_BAD0, 1'b1, 1'b0, 1'b1, 32'b0);
    check(32'd0, {27'b0, ras_count}, "  the stack is now empty");
    look(pc_b);
    check(32'hBAD0_BAD0, pred_target,
          "  empty: the prediction falls back to the BTB target");

    // one pop too many: the depth must not go negative or wrap up
    upd(pc_b, 1'b1, 32'hBAD0_BAD0, 1'b1, 1'b0, 1'b1, 32'b0);
    check(32'd0, {27'b0, ras_count}, "  a pop on an empty stack changes nothing");
    look(pc_b);
    check(32'hBAD0_BAD0, pred_target, "  still the BTB target, still not X");
    chk_defined(pred_target, "  pred_target after underflow");

    // ================================================================
    $display("\n[9] RAS overflow: RAS_DEPTH+2 calls wrap and lose the oldest");
    // ================================================================
    // links are 0xE0000000 + n so that the identity of every entry that comes
    // back out is unambiguous
    for (i = 1; i <= RAS_DEPTH + 2; i = i + 1) begin
        upd(32'h0006_0180 + (i << 2), 1'b1, 32'h0007_0000,
            1'b0, 1'b1, 1'b0, 32'hE000_0000 + i);
        if (i <= RAS_DEPTH) begin
            if (ras_count !== i[4:0]) begin
                $display("FAIL:   after %0d pushes the depth is %0d", i, ras_count);
                errors = errors + 1;
            end
        end else begin
            if (ras_count !== RAS_DEPTH[4:0]) begin
                $display("FAIL:   after %0d pushes the depth is %0d, expected %0d",
                         i, ras_count, RAS_DEPTH);
                errors = errors + 1;
            end
        end
    end
    $display("PASS:   depth counts up to %0d and then saturates", RAS_DEPTH);
    look(pc_b);
    check(32'hE000_000A, pred_target, "  the newest link (10) is on top");

    // walking the stack out: the RAS_DEPTH most recent links come back in
    // reverse order, and the two oldest are gone - an accuracy loss, not a
    // correctness one, since branch_unit always supplies the real target
    for (i = RAS_DEPTH + 2; i > 2; i = i - 1) begin
        look(pc_b);
        if (pred_target !== (32'hE000_0000 + i)) begin
            $display("FAIL:   expected link %0d on top, got 0x%08h", i, pred_target);
            errors = errors + 1;
        end
        upd(pc_b, 1'b1, 32'hBAD0_BAD0, 1'b1, 1'b0, 1'b1, 32'b0);
    end
    $display("PASS:   links %0d down to 3 popped in order", RAS_DEPTH + 2);
    check(32'd0, {27'b0, ras_count}, "  the stack is empty after 8 pops");
    look(pc_b);
    check(32'hBAD0_BAD0, pred_target,
          "  links 1 and 2 were overwritten by the wrap, as documented");

    // ================================================================
    $display("\n[10] both-link JALR: call and return together replace the top");
    // ================================================================
    // with an empty stack, push_only wins, so the pair behaves as a push
    upd(32'h0008_01C0, 1'b1, 32'h0009_0000, 1'b0, 1'b1, 1'b1, 32'h4444_4000);
    check(32'd1, {27'b0, ras_count}, "  empty stack: the pair pushes");
    look(pc_b);
    check(32'h4444_4000, pred_target, "  and the link is on top");

    upd(32'h0008_01C4, 1'b1, 32'h0009_0000, 1'b0, 1'b1, 1'b0, 32'h5555_5000);
    check(32'd2, {27'b0, ras_count}, "  precondition: depth 2");

    upd(32'h0008_01C8, 1'b1, 32'h0009_0000, 1'b0, 1'b1, 1'b1, 32'h6666_6000);
    check(32'd2, {27'b0, ras_count}, "  non-empty stack: the depth is unchanged");
    look(pc_b);
    check(32'h6666_6000, pred_target, "  the top entry was replaced");

    upd(pc_b, 1'b1, 32'hBAD0_BAD0, 1'b1, 1'b0, 1'b1, 32'b0);
    look(pc_b);
    check(32'h4444_4000, pred_target,
          "  under it, the entry the replace did not touch");

    // ================================================================
    $display("\n[11] RAS_DEPTH = 0: the stack is tied off, not merely empty");
    // ================================================================
    // dut0 has seen exactly the same stimulus as dut throughout, so the only
    // thing that can explain a difference is the parameter
    look(pc_b);
    check(32'hBAD0_BAD0, pred_target0,
          "  a return-tagged entry predicts from the BTB target");
    chk_defined(pred_target0, "  pred_target with the stack disabled");
    check(32'd1, {31'b0, pred_taken0}, "  the direction bit still works");

    look(32'h0004_0310);
    check(32'h7777_0000, pred_target0, "  a normal entry is unaffected");

    // ================================================================
    $display("\n[12] asynchronous reset from a fully trained state");
    // ================================================================
    look(32'h0001_0004);
    check(32'd1, {31'b0, pred_taken}, "  precondition: the table is trained");
    upd(32'h000A_01E0, 1'b1, 32'h000B_0000, 1'b0, 1'b1, 1'b0, 32'h9999_9000);
    check(32'd2, {27'b0, ras_count}, "  precondition: the stack is not empty");

    #3 rst_n = 1'b0;      // off a clock edge, so a synchronous reset would miss it
    #4;
    look(32'h0001_0004);
    check(32'd0, {31'b0, pred_taken}, "  the prediction drops before the next edge");

    step(2);
    @(posedge clk) #1 rst_n = 1'b1;
    step(1);

    for (i = 0; i < ENTRIES; i = i + 1) begin
        look(32'h0001_0000 + (i << 2));
        if (pred_taken !== 1'b0) begin
            $display("FAIL:   index %0d survived the reset", i);
            errors = errors + 1;
        end
    end
    $display("PASS:   all %0d entries invalid again after reset", ENTRIES);
    check(32'd0, {27'b0, ras_count}, "  the stack is empty again");
    check(32'd0, {27'b0, dut.g_ras.sp_q}, "  the stack pointer is back to 0");
    if (dut.target === {(ENTRIES*32){1'b0}}) $display("PASS:   target array cleared");
    else begin $display("FAIL:   target array not cleared"); errors = errors + 1; end

    // ---- done ----
    step(2);
    $display("\n========================================");
    if (errors == 0)
        $display("== BRANCH PREDICTOR TESTBENCH: ALL TESTS PASSED ==");
    else
        $display("== BRANCH PREDICTOR TESTBENCH: %0d FAILURE(S) ==", errors);
    $display("========================================");
    $finish;
end

// watchdog
initial begin
    #500000;
    $display("FAIL: tb_bp timeout");
    $finish;
end

endmodule
