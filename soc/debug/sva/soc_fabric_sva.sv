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

`timescale 1ns / 1ps

// axi_lite_dec: address decode and response routing
module soc_axi_lite_dec_sva #(
    parameter NAME = "dec",
    parameter integer N = 2
) (
    input clk_i,
    input rst_n_i,

    input [N-1:0] aw_hit_i,
    input [N-1:0] ar_hit_i,
    input         aw_none_i,
    input         ar_none_i,
    input [N-1:0] wr_sel_q_i,
    input [N-1:0] rd_sel_q_i,
    input         wr_err_q_i,
    input         rd_err_q_i,

    // "a request is accepted and its response is still owed", one per channel
    input         wr_addr_valid_q_i,
    input         wr_data_valid_q_i,
    input         rd_addr_valid_q_i,

    input        m_awvalid_i,
    input        m_awready_i,
    input        m_wvalid_i,
    input        m_wready_i,
    input        m_arvalid_i,
    input        m_arready_i,
    input        m_bvalid_i,
    input [ 1:0] m_bresp_i,
    input        m_bready_i,
    input        m_rvalid_i,
    input [31:0] m_rdata_i,
    input [ 1:0] m_rresp_i,
    input        m_rready_i,

    input [N-1:0] s_awvalid_i,
    input [N-1:0] s_arvalid_i,
    input [N-1:0] s_rvalid_i,
    input [N-1:0] s_bvalid_i
);

    wire aw_hs = m_awvalid_i && m_awready_i;
    wire w_hs = m_wvalid_i && m_wready_i;
    wire ar_hs = m_arvalid_i && m_arready_i;

    localparam [1:0] RESP_DECERR = 2'b11;

    // The address map must not overlap. If two windows ever matched at once the
    // hit vector would stop being a one-hot select and two slaves' responses would
    // be ORed together - silently, and only for the addresses that overlap. This
    // is the property that makes the whole decoder sound, and it is checked here
    // rather than left as a comment on soc_addr_map.vh.
    aw_windows_disjoint :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) $onehot0(aw_hit_i))
    else
        $error(
            "[%0s] write address matched %0d windows at once - the map overlaps",
            NAME,
            $countones(
                aw_hit_i
            )
        );

    ar_windows_disjoint :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) $onehot0(ar_hit_i))
    else
        $error(
            "[%0s] read address matched %0d windows at once - the map overlaps",
            NAME,
            $countones(
                ar_hit_i
            )
        );

    // A hit and "no window matched" are exclusive by construction; if they ever
    // coexist the DECERR responder and a real slave would both answer.
    aw_hit_or_none :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) !(aw_none_i && |aw_hit_i))
    else $error("[%0s] address decoded to a slave and to the error responder", NAME);

    ar_hit_or_none :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) !(ar_none_i && |ar_hit_i))
    else $error("[%0s] address decoded to a slave and to the error responder", NAME);

    // A response must be routed somewhere definite: exactly one latched slave, or
    // the error responder. Both-or-neither means the response mux is picking up
    // stale or ambiguous state.
    r_routed_once :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) m_rvalid_i |-> ($onehot(
        rd_sel_q_i
    ) ^ rd_err_q_i))
    else $error("[%0s] RVALID with no single routing target", NAME);

    b_routed_once :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) m_bvalid_i |-> ($onehot(
        wr_sel_q_i
    ) ^ wr_err_q_i))
    else $error("[%0s] BVALID with no single routing target", NAME);

    // Unmapped accesses return DECERR. Mapped slaves may also return DECERR;
    // their response must pass through unchanged.
    r_unmapped_returns_decerr :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_rvalid_i && rd_err_q_i |-> m_rresp_i == RESP_DECERR)
    else $error("[%0s] unmapped read did not return DECERR", NAME);

    b_unmapped_returns_decerr :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_bvalid_i && wr_err_q_i |-> m_bresp_i == RESP_DECERR)
    else $error("[%0s] unmapped write did not return DECERR", NAME);

    // Nothing reaches a slave that the master did not ask for.
    aw_no_phantom :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) |s_awvalid_i |-> m_awvalid_i)
    else $error("[%0s] AWVALID driven at a slave with no master request", NAME);

    ar_no_phantom :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) |s_arvalid_i |-> m_arvalid_i)
    else $error("[%0s] ARVALID driven at a slave with no master request", NAME);

    // ...and only ever at one of them.
    aw_single_target :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) $onehot0(s_awvalid_i))
    else $error("[%0s] AWVALID driven at more than one slave", NAME);

    ar_single_target :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) $onehot0(s_arvalid_i))
    else $error("[%0s] ARVALID driven at more than one slave", NAME);

    // The decoder holds one route per channel and nothing else. Accepting a
    // second request while the first response is still owed would overwrite
    // that route: the pending response would start coming from the new slave,
    // and the master - which has not taken it yet - would be handed an answer
    // to a question it did not ask. There is no second place to put a route, so
    // "refuse the request" is the only correct answer, and this is where it is
    // stated.
    ar_needs_free_route :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) ar_hs |-> !rd_addr_valid_q_i)
    else $error("[%0s] a read was accepted while another read's response was owed", NAME);

    aw_needs_free_route :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) aw_hs |-> !wr_addr_valid_q_i)
    else $error("[%0s] a write address was accepted while a write was still owed", NAME);

    w_needs_free_route :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) w_hs |-> !wr_data_valid_q_i)
    else $error("[%0s] a second write data beat was accepted for one address", NAME);

    // ...and the same refusal on the slave side, so a blocked request is not
    // quietly forwarded to a slave that would then answer out of turn.
    ar_not_forwarded_when_busy :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) |s_arvalid_i |-> !rd_addr_valid_q_i)
    else $error("[%0s] ARVALID reached a slave while a read response was owed", NAME);

    aw_not_forwarded_when_busy :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) |s_awvalid_i |-> !wr_addr_valid_q_i)
    else $error("[%0s] AWVALID reached a slave while a write response was owed", NAME);

    // A response that has been offered and not taken must not move - neither
    // its payload nor the route it came from.
    r_payload_stable :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) m_rvalid_i && !m_rready_i |=>
        m_rvalid_i && $stable(m_rdata_i) && $stable(m_rresp_i))
    else $error("[%0s] the read response changed before the master took it", NAME);

    b_payload_stable :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) m_bvalid_i && !m_bready_i |=>
        m_bvalid_i && $stable(m_bresp_i))
    else $error("[%0s] the write response changed before the master took it", NAME);

    r_route_stable :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) m_rvalid_i && !m_rready_i |=>
        $stable(rd_sel_q_i) && $stable(rd_err_q_i))
    else $error("[%0s] the read route changed under an unread response", NAME);

    // A response is only ever offered for a request that was accepted, and it
    // comes from the slave the route points at - not merely from some slave.
    r_needs_outstanding :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) m_rvalid_i |-> rd_addr_valid_q_i)
    else $error("[%0s] RVALID with no accepted read behind it", NAME);

    b_needs_outstanding :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_bvalid_i |-> wr_addr_valid_q_i && wr_data_valid_q_i)
    else $error("[%0s] BVALID before the write's address and data were accepted", NAME);

    r_from_selected_slave :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_rvalid_i && !rd_err_q_i |-> |(rd_sel_q_i & s_rvalid_i))
    else $error("[%0s] the read response came from a slave that was not selected", NAME);

    b_from_selected_slave :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    m_bvalid_i && !wr_err_q_i |-> |(wr_sel_q_i & s_bvalid_i))
    else $error("[%0s] the write response came from a slave that was not selected", NAME);

    cov_decerr_read :
    cover property (@(posedge clk_i) disable iff (!rst_n_i) m_rvalid_i && rd_err_q_i);
    cov_decerr_write :
    cover property (@(posedge clk_i) disable iff (!rst_n_i) m_bvalid_i && wr_err_q_i);
    // the corner the ordering rules exist for: a request offered while a
    // response to the previous one is still sitting unread on the master port
    cov_read_deferred :
    cover property (@(posedge clk_i) disable iff (!rst_n_i)
    m_arvalid_i && rd_addr_valid_q_i && m_rvalid_i && !m_rready_i);
    cov_read_deferred_elsewhere :
    cover property (@(posedge clk_i) disable iff (!rst_n_i)
    m_arvalid_i && rd_addr_valid_q_i && !(|(ar_hit_i & rd_sel_q_i)));

endmodule

// axi_lite_arb: round-robin grant for a shared slave
module soc_axi_lite_arb_sva #(
    parameter NAME = "arb",
    parameter integer M = 2
) (
    input clk_i,
    input rst_n_i,

    input [M-1:0] gnt_i,
    input [M-1:0] req_i,
    input [M-1:0] sel_i,
    input         release_gnt_i,
    input         write_grant_q_i,

    // what this grant has already handed to the slave
    input         aw_taken_q_i,
    input         w_taken_q_i,
    input         ar_taken_q_i,

    input [M-1:0] m_awready_i,
    input [M-1:0] m_wready_i,
    input [M-1:0] m_arready_i,
    input [M-1:0] m_bvalid_i,
    input [M-1:0] m_rvalid_i,

    input s_awvalid_i,
    input s_awready_i,
    input s_wvalid_i,
    input s_wready_i,
    input s_arvalid_i,
    input s_arready_i,
    input s_bvalid_i,
    input s_bready_i,
    input s_rvalid_i,
    input s_rready_i
);

    wire s_aw_hs = s_awvalid_i && s_awready_i;
    wire s_w_hs = s_wvalid_i && s_wready_i;
    wire s_ar_hs = s_arvalid_i && s_arready_i;
    wire s_b_hs = s_bvalid_i && s_bready_i;
    wire s_r_hs = s_rvalid_i && s_rready_i;

    // The whole point of an arbiter: never two masters at once.
    gnt_exclusive :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) $onehot0(gnt_i))
    else $error("[%0s] %0d masters granted at the same time", NAME, $countones(gnt_i));

    // A grant is only ever taken by a master that was asking for it.
    gnt_from_request :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) |gnt_i && !$past(
        |gnt_i
    ) |-> |($past(
        req_i
    ) & gnt_i))
    else $error("[%0s] granted a master that was not requesting", NAME);

    // A grant is held for exactly one transaction: it may only change on the
    // response beat that ends it. Without this an arbiter can hand the slave to
    // the next master mid-transaction and split a write from its response.
    gnt_held_until_response :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) |gnt_i && !release_gnt_i |=> $stable(
        gnt_i
    ))
    else $error("[%0s] grant changed before the transaction completed", NAME);

    // Nothing reaches the shared slave unless somebody holds the grant.
    no_traffic_without_grant :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    (s_awvalid_i || s_wvalid_i || s_arvalid_i) |-> |gnt_i)
    else $error("[%0s] traffic reached the slave with no grant outstanding", NAME);

    // A parked master must see nothing at all: no READY, no response. This is what
    // makes waiting for a grant indistinguishable from a slow slave, which is what
    // keeps the parked master protocol-legal while it waits.
    parked_masters_see_nothing :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    ((m_awready_i | m_wready_i | m_arready_i | m_bvalid_i | m_rvalid_i) & ~gnt_i) == {M{1'b0}})
    else $error("[%0s] a master without the grant saw a READY or a response", NAME);

    // A grant is one transaction, so the slave gets one address and one data
    // beat out of it. A second one would leave the slave holding two writes at
    // once - and, because the grant's routing is a single register, the second
    // write's response would be delivered to whoever holds the grant when it
    // arrives rather than to whoever issued it.
    aw_once_per_grant :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) s_aw_hs |-> !aw_taken_q_i)
    else $error("[%0s] a second write address was forwarded inside one grant", NAME);

    w_once_per_grant :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) s_w_hs |-> !w_taken_q_i)
    else $error("[%0s] a second write data beat was forwarded inside one grant", NAME);

    ar_once_per_grant :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) s_ar_hs |-> !ar_taken_q_i)
    else $error("[%0s] a second read address was forwarded inside one grant", NAME);

    // A grant owns one direction, so the response that ends it must be the one
    // that direction was granted for.
    b_only_under_write_grant :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) s_b_hs |-> write_grant_q_i && |gnt_i)
    else $error("[%0s] a write response was taken without a write grant", NAME);

    r_only_under_read_grant :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) s_r_hs |-> !write_grant_q_i && |gnt_i)
    else $error("[%0s] a read response was taken without a read grant", NAME);

    // The slave is only ever answered for something it was actually given.
    b_needs_address_and_data :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    s_bvalid_i && write_grant_q_i && |gnt_i |-> aw_taken_q_i && w_taken_q_i)
    else $error("[%0s] BVALID before this grant's address and data were forwarded", NAME);

    // Coverage: the states that only occur under real contention. If these never
    // hit, the arbiter was never exercised, whatever the tests reported.
    cov_contended :
    cover property (@(posedge clk_i) disable iff (!rst_n_i) $countones(req_i) > 1);
    cov_grant_switch :
    cover property (@(posedge clk_i) disable iff (!rst_n_i) |gnt_i && !$past(
        |gnt_i
    ) && $past(
        sel_i, 2
    ) != gnt_i);
    cov_parked_while_busy :
    cover property (@(posedge clk_i) disable iff (!rst_n_i) |gnt_i && |(req_i & ~gnt_i));
    // a grant held open across an idle slave, with its address already forwarded
    cov_grant_held_after_address :
    cover property (@(posedge clk_i) disable iff (!rst_n_i)
    |gnt_i && write_grant_q_i && aw_taken_q_i && s_awready_i);

endmodule

// axi_full2lite: burst splitting
module soc_axi_full2lite_sva #(
    parameter NAME = "bridge"
) (
    input clk_i,
    input rst_n_i,

    input [ 1:0] r_state_i,
    input [ 7:0] r_len_i,
    input [ 7:0] r_beat_i,
    input [31:0] r_addr_i,
    input        r_fixed_i,

    input [ 1:0] w_state_i,
    input [ 7:0] w_len_i,
    input [ 7:0] w_beat_i,
    input [31:0] w_addr_i,
    input        w_fixed_i,
    input [ 1:0] w_resp_i,

    input       s_arvalid_i,
    input       s_arready_i,
    input       ar_supported_i,
    input       s_awvalid_i,
    input       s_awready_i,
    input       aw_supported_i,
    input       s_wvalid_i,
    input       s_wready_i,
    input       s_wlast_i,
    input       s_rvalid_i,
    input       s_rready_i,
    input       s_rlast_i,
    input       s_bvalid_i,
    input [1:0] s_bresp_i,

    input       m_arvalid_i,
    input       m_awvalid_i,
    input       m_bvalid_i,
    input       m_bready_i,
    input [1:0] m_bresp_i
);

    wire s_ar_hs = s_arvalid_i && s_arready_i;
    wire s_aw_hs = s_awvalid_i && s_awready_i;
    wire s_w_hs = s_wvalid_i && s_wready_i;

    localparam [1:0] R_IDLE = 2'd0, R_RUN = 2'd1, R_ERR = 2'd2;
    localparam [1:0] W_IDLE = 2'd0, W_RUN = 2'd1, W_ERR = 2'd2, W_RESP = 2'd3;
    localparam [1:0] RESP_OKAY = 2'b00;

    wire r_beat_hs = s_rvalid_i && s_rready_i;

    // The beat counter is the bridge's whole correctness argument: it decides how
    // many Lite transactions a burst becomes and where RLAST goes.
    r_beat_bounded :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    r_state_i != R_IDLE |-> r_beat_i <= r_len_i)
    else $error("[%0s] read beat %0d past the burst length %0d", NAME, r_beat_i, r_len_i);

    w_beat_bounded :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_state_i == W_RUN || w_state_i == W_ERR |-> w_beat_i <= w_len_i)
    else $error("[%0s] write beat %0d past the burst length %0d", NAME, w_beat_i, w_len_i);

    rlast_tracks_counter :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    s_rvalid_i |-> (s_rlast_i == (r_beat_i == r_len_i)))
    else $error("[%0s] RLAST does not match the beat counter", NAME);

    // An INCR burst advances exactly one 32-bit word per beat; a FIXED one does
    // not advance at all. A bridge that got this wrong would scatter a transfer
    // across memory while every individual transaction stayed protocol-legal.
    r_addr_step :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    r_state_i == R_RUN && r_beat_hs && r_beat_i != r_len_i
    |=> r_addr_i == ($past(
        r_addr_i
    ) + ($past(
        r_fixed_i
    ) ? 32'd0 : 32'd4)))
    else $error("[%0s] read address stepped wrongly between beats", NAME);

    // Nothing is issued on the Lite side while the bridge is idle, or while it is
    // refusing an unsupported burst - "issues nothing on the lite side" is the
    // promise the SLVERR path makes.
    no_lite_read_when_idle :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) m_arvalid_i |-> r_state_i == R_RUN)
    else $error("[%0s] Lite AR issued outside a running read burst", NAME);

    no_lite_write_when_idle :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) m_awvalid_i |-> w_state_i == W_RUN)
    else $error("[%0s] Lite AW issued outside a running write burst", NAME);

    // The burst's response is the worst response any of its beats got. Once it is
    // an error it must stay one until the burst is answered, or a failed transfer
    // reports success.
    bresp_sticky :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_state_i == W_RUN && w_resp_i != RESP_OKAY |=>
        (w_state_i == W_IDLE) || (w_resp_i != RESP_OKAY))
    else $error("[%0s] an error response was lost inside a burst", NAME);

    bresp_captures_beat_error :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    w_state_i == W_RUN && m_bvalid_i && m_bready_i && m_bresp_i != RESP_OKAY
    |=> w_resp_i != RESP_OKAY)
    else $error("[%0s] a beat returned an error the burst response ignored", NAME);

    // The full-side write response only appears once, at the end.
    bvalid_only_in_resp :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) s_bvalid_i |-> w_state_i == W_RESP)
    else $error("[%0s] BVALID outside the response state", NAME);

    // A burst is taken on only when the bridge has somewhere to put it: it keeps
    // one burst per direction and nothing more.
    ar_only_when_idle :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) s_ar_hs |-> r_state_i == R_IDLE)
    else $error("[%0s] a read burst was accepted while one was still running", NAME);

    aw_only_when_idle :
    assert property (@(posedge clk_i) disable iff (!rst_n_i) s_aw_hs |-> w_state_i == W_IDLE)
    else $error("[%0s] a write burst was accepted while one was still running", NAME);

    // The supported profile is decided once, at the address handshake, and the
    // bridge's next state is that decision. A burst outside the profile has to
    // reach the error path - if it reached the running path instead, it would be
    // translated as if it were supported and the master would be told OKAY.
    unsupported_read_goes_to_err :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    s_ar_hs && !ar_supported_i |=> r_state_i == R_ERR)
    else $error("[%0s] a read outside the supported profile was not refused", NAME);

    unsupported_write_goes_to_err :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    s_aw_hs && !aw_supported_i |=> w_state_i == W_ERR)
    else $error("[%0s] a write outside the supported profile was not refused", NAME);

    supported_read_runs :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    s_ar_hs && ar_supported_i |=> r_state_i == R_RUN)
    else $error("[%0s] a supported read burst did not start", NAME);

    // A burst ends where its length said it would. The full-side WLAST and the
    // bridge's own beat counter are two independent statements of how long the
    // transfer is; if they disagree the bridge is about to answer a burst with
    // the wrong number of beats - too few, and the master waits forever for the
    // rest; too many, and the extra beats are written somewhere nobody asked.
    wlast_matches_counter :
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
    s_w_hs && (w_state_i == W_RUN || w_state_i == W_ERR)
    |-> (s_wlast_i == (w_beat_i == w_len_i)))
    else
        $error(
            "[%0s] WLAST=%0b on beat %0d of a burst of length %0d",
            NAME,
            s_wlast_i,
            w_beat_i,
            w_len_i
        );

    cov_read_rejected :
    cover property (@(posedge clk_i) disable iff (!rst_n_i) r_state_i == R_ERR);
    cov_write_rejected :
    cover property (@(posedge clk_i) disable iff (!rst_n_i) w_state_i == W_ERR);
    cov_fixed_burst :
    cover property (@(posedge clk_i) disable iff (!rst_n_i)
    (r_state_i == R_RUN && r_fixed_i) || (w_state_i == W_RUN && w_fixed_i));
    cov_burst_error :
    cover property (@(posedge clk_i) disable iff (!rst_n_i) s_bvalid_i && s_bresp_i != RESP_OKAY);

endmodule
