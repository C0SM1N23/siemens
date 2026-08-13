// PIC invariants (SVA) — bound into pic, verification only.
//
// The advanced-scheduling PIC resolves priority across 32 logical sources and
// drives one request + vector, with a nesting stack behind cpu_irq_ack/eoi.
// These properties pin down the safety contract:
//  - D-LAT : cpu_irq / cpu_irq_vec are the registered (offer_val, res_id) pair
//  - D-BAND: the offered source is eligible (a pending request, not in service)
//            and, under nesting, strictly more urgent than the in-service top
//  - D-NEST: depth stays within [0, NEST_MAX], moves only by claim/eoi, and the
//            depth limit masks further offers (enforcing the bound)
//
// Bound from bind_sva.sv — no RTL is touched.

`timescale 1ns/1ps

module pic_sva #(
    parameter MAXNEST = 16
) (
    input        clk,
    input        rst_n,

    // ports
    input [15:0] irq_src,
    input        cpu_irq,
    input [3:0]  cpu_irq_vec,
    input        cpu_irq_ack,
    input        cpu_irq_eoi,

    // internals (wired up by the bind)
    input        offer_val,
    input [3:0]  res_id,
    input [9:0]  res_key,
    input [15:0] req,
    input [15:0] active,
    input [4:0]  depth,
    input [4:0]  nest_max,
    input        has_active,
    input [9:0]  top_key,
    input        claim_push,
    input        eoi_pop
);

// --- D-LAT: cpu_irq / cpu_irq_vec are the registered offer -------------------
// shadow sampled on the same edge from the same inputs, so a testbench that
// moves irq_src right after the edge cannot race the compare against $past.
reg       exp_irq;
reg [3:0] exp_vec;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        exp_irq <= 1'b0;
        exp_vec <= 4'd0;
    end else begin
        exp_irq <= offer_val;
        if (offer_val) exp_vec <= res_id;
    end
end

irq_is_registered_offer: assert property (@(posedge clk) disable iff (!rst_n)
    cpu_irq == exp_irq)
    else $error("[pic] cpu_irq != registered offer");

vec_is_registered_offer: assert property (@(posedge clk) disable iff (!rst_n)
    cpu_irq |-> cpu_irq_vec == exp_vec)
    else $error("[pic] cpu_irq_vec != registered offered id");

// --- D-BAND: the offered source is eligible and wins the priority race -------
offer_is_pending: assert property (@(posedge clk) disable iff (!rst_n)
    offer_val |-> (req[res_id] && !active[res_id]))
    else $error("[pic] offered source is not a pending request");

preemption_is_strict: assert property (@(posedge clk) disable iff (!rst_n)
    (offer_val && has_active) |-> (res_key > top_key))
    else $error("[pic] offered a source not strictly above the in-service top");

// --- D-NEST: nesting-stack bounds and motion ---------------------------------
max_within_hw: assert property (@(posedge clk) disable iff (!rst_n)
    nest_max <= MAXNEST)
    else $error("[pic] NEST_MAX exceeds the physical stack");

depth_within_max: assert property (@(posedge clk) disable iff (!rst_n)
    depth <= nest_max)
    else $error("[pic] nesting depth exceeded NEST_MAX");

claim_eoi_exclusive: assert property (@(posedge clk) disable iff (!rst_n)
    !(claim_push && eoi_pop))
    else $error("[pic] simultaneous claim and eoi");

depth_moves_by_claim_eoi: assert property (@(posedge clk) disable iff (!rst_n)
    depth == ($past(depth) + {4'd0, $past(claim_push)} - {4'd0, $past(eoi_pop)}))
    else $error("[pic] depth changed without a claim/eoi");

limit_masks_offers: assert property (@(posedge clk) disable iff (!rst_n)
    (depth >= nest_max) |-> !offer_val)
    else $error("[pic] offered a source at the depth limit");

eoi_no_underflow: assert property (@(posedge clk) disable iff (!rst_n)
    (cpu_irq_eoi && !has_active) |=> (depth == $past(depth)))
    else $error("[pic] eoi underflowed the nesting stack");

endmodule
