// Assertions on the SoC interconnect itself - verification only, bindable.
//
// axi_lite_sva and axi_full_sva check that every port on the fabric obeys the
// bus protocol. That is necessary but not sufficient: a decoder that routes a
// response to the wrong slave, or an arbiter that hands the memory to two
// masters at once, can still be perfectly protocol-legal on every individual
// port. These are the properties about the fabric's *internal decisions*, and
// they are the ones a directed test is least likely to catch, because they
// only go wrong in the timing corners.
//
// Three checkers, one per block, each bound to its module so every instance
// gets its own copy.

`timescale 1ns/1ps

// ===========================================================================
// axi_lite_dec: address decode and response routing
// ===========================================================================
module axi_lite_dec_sva #(
    parameter NAME = "dec",
    parameter integer N = 2
)(
    input             clk_i,
    input             rst_n_i,

    input [N-1:0]     aw_hit_i,
    input [N-1:0]     ar_hit_i,
    input             aw_none_i,
    input             ar_none_i,
    input [N-1:0]     wr_sel_q_i,
    input [N-1:0]     rd_sel_q_i,
    input             wr_err_q_i,
    input             rd_err_q_i,

    input             m_awvalid_i,
    input             m_awready_i,
    input             m_arvalid_i,
    input             m_arready_i,
    input             m_bvalid_i,
    input [1:0]       m_bresp_i,
    input             m_rvalid_i,
    input [1:0]       m_rresp_i,

    input [N-1:0]     s_awvalid_i,
    input [N-1:0]     s_arvalid_i
);

localparam [1:0] RESP_DECERR = 2'b11;

// The address map must not overlap. If two windows ever matched at once the
// hit vector would stop being a one-hot select and two slaves' responses would
// be ORed together - silently, and only for the addresses that overlap. This
// is the property that makes the whole decoder sound, and it is checked here
// rather than left as a comment on soc_addr_map.vh.
aw_windows_disjoint: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    $onehot0(aw_hit_i))
    else $error("[%0s] write address matched %0d windows at once - the map overlaps",
                NAME, $countones(aw_hit_i));

ar_windows_disjoint: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    $onehot0(ar_hit_i))
    else $error("[%0s] read address matched %0d windows at once - the map overlaps",
                NAME, $countones(ar_hit_i));

// A hit and "no window matched" are exclusive by construction; if they ever
// coexist the DECERR responder and a real slave would both answer.
aw_hit_or_none: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    !(aw_none_i && |aw_hit_i))
    else $error("[%0s] address decoded to a slave and to the error responder", NAME);

ar_hit_or_none: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    !(ar_none_i && |ar_hit_i))
    else $error("[%0s] address decoded to a slave and to the error responder", NAME);

// A response must be routed somewhere definite: exactly one latched slave, or
// the error responder. Both-or-neither means the response mux is picking up
// stale or ambiguous state.
r_routed_once: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_rvalid_i |-> ($onehot(rd_sel_q_i) ^ rd_err_q_i))
    else $error("[%0s] RVALID with no single routing target", NAME);

b_routed_once: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_bvalid_i |-> ($onehot(wr_sel_q_i) ^ wr_err_q_i))
    else $error("[%0s] BVALID with no single routing target", NAME);

// DECERR is the decoder's answer for "nothing is mapped here", so it must
// never come from a leg that actually decoded to a slave. A slave that wants
// to report an error uses SLVERR.
r_decerr_only_unmapped: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_rvalid_i && m_rresp_i == RESP_DECERR |-> rd_err_q_i)
    else $error("[%0s] DECERR returned for a mapped read", NAME);

b_decerr_only_unmapped: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_bvalid_i && m_bresp_i == RESP_DECERR |-> wr_err_q_i)
    else $error("[%0s] DECERR returned for a mapped write", NAME);

// Nothing reaches a slave that the master did not ask for.
aw_no_phantom: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    |s_awvalid_i |-> m_awvalid_i)
    else $error("[%0s] AWVALID driven at a slave with no master request", NAME);

ar_no_phantom: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    |s_arvalid_i |-> m_arvalid_i)
    else $error("[%0s] ARVALID driven at a slave with no master request", NAME);

// ...and only ever at one of them.
aw_single_target: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    $onehot0(s_awvalid_i))
    else $error("[%0s] AWVALID driven at more than one slave", NAME);

ar_single_target: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    $onehot0(s_arvalid_i))
    else $error("[%0s] ARVALID driven at more than one slave", NAME);

cov_decerr_read:  cover property (@(posedge clk_i) disable iff (!rst_n_i)
    m_rvalid_i && rd_err_q_i);
cov_decerr_write: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    m_bvalid_i && wr_err_q_i);

endmodule


// ===========================================================================
// axi_lite_arb: round-robin grant for a shared slave
// ===========================================================================
module axi_lite_arb_sva #(
    parameter NAME = "arb",
    parameter integer M = 2
)(
    input             clk_i,
    input             rst_n_i,

    input [M-1:0]     gnt_i,
    input [M-1:0]     req_i,
    input [M-1:0]     sel_i,
    input             release_gnt_i,

    input [M-1:0]     m_awready_i,
    input [M-1:0]     m_wready_i,
    input [M-1:0]     m_arready_i,
    input [M-1:0]     m_bvalid_i,
    input [M-1:0]     m_rvalid_i,

    input             s_awvalid_i,
    input             s_wvalid_i,
    input             s_arvalid_i
);

// The whole point of an arbiter: never two masters at once.
gnt_exclusive: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    $onehot0(gnt_i))
    else $error("[%0s] %0d masters granted at the same time",
                NAME, $countones(gnt_i));

// A grant is only ever taken by a master that was asking for it.
gnt_from_request: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    |gnt_i && !$past(|gnt_i) |-> |($past(req_i) & gnt_i))
    else $error("[%0s] granted a master that was not requesting", NAME);

// A grant is held for exactly one transaction: it may only change on the
// response beat that ends it. Without this an arbiter can hand the slave to
// the next master mid-transaction and split a write from its response.
gnt_held_until_response: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    |gnt_i && !release_gnt_i |=> $stable(gnt_i))
    else $error("[%0s] grant changed before the transaction completed", NAME);

// Nothing reaches the shared slave unless somebody holds the grant.
no_traffic_without_grant: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    (s_awvalid_i || s_wvalid_i || s_arvalid_i) |-> |gnt_i)
    else $error("[%0s] traffic reached the slave with no grant outstanding", NAME);

// A parked master must see nothing at all: no READY, no response. This is what
// makes waiting for a grant indistinguishable from a slow slave, which is what
// keeps the parked master protocol-legal while it waits.
parked_masters_see_nothing: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    ((m_awready_i | m_wready_i | m_arready_i | m_bvalid_i | m_rvalid_i) & ~gnt_i) == {M{1'b0}})
    else $error("[%0s] a master without the grant saw a READY or a response", NAME);

// Coverage: the states that only occur under real contention. If these never
// hit, the arbiter was never exercised, whatever the tests reported.
cov_contended: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    $countones(req_i) > 1);
cov_grant_switch: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    |gnt_i && !$past(|gnt_i) && $past(sel_i, 2) != gnt_i);
cov_parked_while_busy: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    |gnt_i && |(req_i & ~gnt_i));

endmodule


// ===========================================================================
// axi_full2lite: burst splitting
// ===========================================================================
module axi_full2lite_sva #(
    parameter NAME = "bridge"
)(
    input             clk_i,
    input             rst_n_i,

    input [1:0]       r_state_i,
    input [7:0]       r_len_i,
    input [7:0]       r_beat_i,
    input [31:0]      r_addr_i,
    input             r_fixed_i,

    input [1:0]       w_state_i,
    input [7:0]       w_len_i,
    input [7:0]       w_beat_i,
    input [31:0]      w_addr_i,
    input             w_fixed_i,
    input [1:0]       w_resp_i,

    input             s_rvalid_i,
    input             s_rready_i,
    input             s_rlast_i,
    input             s_bvalid_i,
    input [1:0]       s_bresp_i,

    input             m_arvalid_i,
    input             m_awvalid_i,
    input             m_bvalid_i,
    input             m_bready_i,
    input [1:0]       m_bresp_i
);

localparam [1:0] R_IDLE = 2'd0, R_RUN = 2'd1, R_ERR = 2'd2;
localparam [1:0] W_IDLE = 2'd0, W_RUN = 2'd1, W_ERR = 2'd2, W_RESP = 2'd3;
localparam [1:0] RESP_OKAY = 2'b00;

wire r_beat_hs = s_rvalid_i && s_rready_i;

// The beat counter is the bridge's whole correctness argument: it decides how
// many Lite transactions a burst becomes and where RLAST goes.
r_beat_bounded: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    r_state_i != R_IDLE |-> r_beat_i <= r_len_i)
    else $error("[%0s] read beat %0d past the burst length %0d",
                NAME, r_beat_i, r_len_i);

w_beat_bounded: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_state_i == W_RUN || w_state_i == W_ERR |-> w_beat_i <= w_len_i)
    else $error("[%0s] write beat %0d past the burst length %0d",
                NAME, w_beat_i, w_len_i);

rlast_tracks_counter: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    s_rvalid_i |-> (s_rlast_i == (r_beat_i == r_len_i)))
    else $error("[%0s] RLAST does not match the beat counter", NAME);

// An INCR burst advances exactly one 32-bit word per beat; a FIXED one does
// not advance at all. A bridge that got this wrong would scatter a transfer
// across memory while every individual transaction stayed protocol-legal.
r_addr_step: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    r_state_i == R_RUN && r_beat_hs && r_beat_i != r_len_i
    |=> r_addr_i == ($past(r_addr_i) + ($past(r_fixed_i) ? 32'd0 : 32'd4)))
    else $error("[%0s] read address stepped wrongly between beats", NAME);

// Nothing is issued on the Lite side while the bridge is idle, or while it is
// refusing an unsupported burst - "issues nothing on the lite side" is the
// promise the SLVERR path makes.
no_lite_read_when_idle: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_arvalid_i |-> r_state_i == R_RUN)
    else $error("[%0s] Lite AR issued outside a running read burst", NAME);

no_lite_write_when_idle: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_awvalid_i |-> w_state_i == W_RUN)
    else $error("[%0s] Lite AW issued outside a running write burst", NAME);

// The burst's response is the worst response any of its beats got. Once it is
// an error it must stay one until the burst is answered, or a failed transfer
// reports success.
bresp_sticky: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_state_i == W_RUN && w_resp_i != RESP_OKAY |=>
        (w_state_i == W_IDLE) || (w_resp_i != RESP_OKAY))
    else $error("[%0s] an error response was lost inside a burst", NAME);

bresp_captures_beat_error: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_state_i == W_RUN && m_bvalid_i && m_bready_i && m_bresp_i != RESP_OKAY
    |=> w_resp_i != RESP_OKAY)
    else $error("[%0s] a beat returned an error the burst response ignored", NAME);

// The full-side write response only appears once, at the end.
bvalid_only_in_resp: assert property (@(posedge clk_i) disable iff (!rst_n_i)
    s_bvalid_i |-> w_state_i == W_RESP)
    else $error("[%0s] BVALID outside the response state", NAME);

cov_read_rejected:  cover property (@(posedge clk_i) disable iff (!rst_n_i)
    r_state_i == R_ERR);
cov_write_rejected: cover property (@(posedge clk_i) disable iff (!rst_n_i)
    w_state_i == W_ERR);
cov_fixed_burst:    cover property (@(posedge clk_i) disable iff (!rst_n_i)
    (r_state_i == R_RUN && r_fixed_i) || (w_state_i == W_RUN && w_fixed_i));
cov_burst_error:    cover property (@(posedge clk_i) disable iff (!rst_n_i)
    s_bvalid_i && s_bresp_i != RESP_OKAY);

endmodule
