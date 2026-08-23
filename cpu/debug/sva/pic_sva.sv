// PIC invariants (SVA) — bound into pic, verification only.
//
// The advanced-scheduling PIC resolves priority across 32 logical sources and
// drives one request + vector, with a nesting stack behind cpu_irq_ack_i/eoi.
// These properties pin down the safety contract:
//  - D-LAT : cpu_irq_i / cpu_irq_vec_i are the registered (offer_val_i, res_id_i) pair
//  - D-BAND: the offered source is eligible (a pending request, not in service)
//            and, under nesting, strictly more urgent than the in-service top
//  - D-NEST: depth_i stays within [0, NEST_MAX], moves only by claim/eoi, and the
//            depth_i limit masks further offers (enforcing the bound)
//
// Bound from bind_sva.sv — no RTL is touched.

`timescale 1ns/1ps

module pic_sva #(
    parameter MAXNEST = 16
) (
    input        clk_i,
    input        rst_n_i,

    // ports
    input [15:0] irq_src_i,
    input        cpu_irq_i,
    input [3:0]  cpu_irq_vec_i,
    input        cpu_irq_ack_i,
    input        cpu_irq_eoi_i,

    // internals (wired up by the bind)
    input        offer_val_i,
    input [3:0]  res_id_i,
    input [9:0]  res_key_i,
    input [15:0] req_i,
    input [15:0] active_i,
    input [4:0]  depth_i,
    input [4:0]  nest_max_i,
    input        has_active_i,
    input [9:0]  top_key_i,
    input        claim_push_i,
    input        eoi_pop_i
);

// --- D-LAT: cpu_irq_i / cpu_irq_vec_i are the registered offer -------------------
// shadow sampled on the same edge from the same inputs, so a testbench that
// moves irq_src_i right after the edge cannot race the compare against $past.
reg       exp_irq;
reg [3:0] exp_vec;
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        exp_irq <= 1'b0;
        exp_vec <= 4'd0;
    end else begin
        exp_irq <= offer_val_i;
        if (offer_val_i) exp_vec <= res_id_i;
    end
end

irq_is_registered_offer: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    cpu_irq_i == exp_irq)
    else $error("[pic] cpu_irq_i != registered offer");

vec_is_registered_offer: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    cpu_irq_i |-> cpu_irq_vec_i == exp_vec)
    else $error("[pic] cpu_irq_vec_i != registered offered id");

// --- D-BAND: the offered source is eligible and wins the priority race -------
offer_is_pending: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    offer_val_i |-> (req_i[res_id_i] && !active_i[res_id_i]))
    else $error("[pic] offered source is not a pending request");

preemption_is_strict: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    (offer_val_i && has_active_i) |-> (res_key_i > top_key_i))
    else $error("[pic] offered a source not strictly above the in-service top");

// --- D-NEST: nesting-stack bounds and motion ---------------------------------
max_within_hw: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    nest_max_i <= MAXNEST)
    else $error("[pic] NEST_MAX exceeds the physical stack");

depth_within_max: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    depth_i <= nest_max_i)
    else $error("[pic] nesting depth_i exceeded NEST_MAX");

claim_eoi_exclusive: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    !(claim_push_i && eoi_pop_i))
    else $error("[pic] simultaneous claim and eoi");

depth_moves_by_claim_eoi: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    depth_i == ($past(depth_i) + {4'd0, $past(claim_push_i)} - {4'd0, $past(eoi_pop_i)}))
    else $error("[pic] depth_i changed without a claim/eoi");

limit_masks_offers: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    (depth_i >= nest_max_i) |-> !offer_val_i)
    else $error("[pic] offered a source at the depth_i limit");

eoi_no_underflow: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    (cpu_irq_eoi_i && !has_active_i) |=> (depth_i == $past(depth_i)))
    else $error("[pic] eoi underflowed the nesting stack");

endmodule
