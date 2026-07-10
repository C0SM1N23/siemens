// PIC invariants (SVA) — bound into pic, verification only.
//
// The PIC's whole contract is one line of combinational logic plus two
// registers (D19-D21); these properties pin each piece down:
//
// - D19: cpu_irq / cpu_irq_id are registered from the same pending vector —
//   checked as the exact register transfer, so any inconsistency between
//   the pair the CPU sees is caught the cycle it happens
// - D20: the id is the lowest-numbered pending channel (fixed priority)
// - D21: an in-service channel stays out of cpu_irq until MRET releases it,
//   and MRET releases the whole in-service mask
//
// Bound from bind_sva.sv — no RTL is touched.

module pic_sva (
    input        clk,
    input        rst_n,

    input [7:0]  irq_src,
    input [7:0]  cpu_irq,
    input [2:0]  cpu_irq_id,
    input [7:0]  cpu_irq_ack,
    input        cpu_in_trap,

    // PIC internals (wired up by the bind)
    input [7:0]  enable_q,
    input [7:0]  in_service_q
);

// --- the register transfer itself (D19): one property covers gating by
// --- IRQ_ENABLE, in-service masking and the irq/id pair consistency

// shadow of the DUT's own register: sampled on the same edge from the same
// inputs, so a testbench that moves irq_src right after the edge (as
// tb_cpu_axi does) can never make the compare race against $past sampling
reg [7:0] exp_irq_q;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        exp_irq_q <= 8'b0;
    else
        exp_irq_q <= irq_src & enable_q & ~in_service_q;
end

irq_is_gated_pending: assert property (@(posedge clk) disable iff (!rst_n)
    cpu_irq == exp_irq_q)
    else $error("[pic] cpu_irq != registered pending vector");

// --- fixed priority, channel 0 highest (D20) ---

id_points_at_pending: assert property (@(posedge clk) disable iff (!rst_n)
    |cpu_irq |-> cpu_irq[cpu_irq_id])
    else $error("[pic] cpu_irq_id points at a clear cpu_irq bit");

id_is_lowest: assert property (@(posedge clk) disable iff (!rst_n)
    |cpu_irq |-> (cpu_irq & ((8'h01 << cpu_irq_id) - 8'h01)) == 8'b0)
    else $error("[pic] a lower channel than cpu_irq_id is pending");

// --- in-service suppression (D21) ---

// the ack lands in the in-service mask on the next edge
ack_sets_in_service: assert property (@(posedge clk) disable iff (!rst_n)
    |cpu_irq_ack |=> (in_service_q & $past(cpu_irq_ack)) == $past(cpu_irq_ack))
    else $error("[pic] acked channel missing from in-service mask");

// once in service for a full cycle, the channel is out of cpu_irq
// (one settling cycle: cpu_irq registers the pre-ack pending vector)
genvar ch;
generate for (ch = 0; ch < 8; ch = ch + 1) begin : g_suppress
    suppressed: assert property (@(posedge clk) disable iff (!rst_n)
        in_service_q[ch] && $past(in_service_q[ch]) |-> !cpu_irq[ch])
        else $error("[pic] in-service channel %0d re-offered to the CPU", ch);
end endgenerate

// MRET (cpu_in_trap low, no simultaneous ack) releases the whole mask
mret_releases: assert property (@(posedge clk) disable iff (!rst_n)
    !cpu_in_trap && cpu_irq_ack == 8'b0 |=> in_service_q == 8'b0)
    else $error("[pic] in-service mask survived MRET");

endmodule
