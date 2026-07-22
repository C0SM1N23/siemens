// Programmable Interrupt Controller with Advanced Scheduling (PIC).
//
// Implements the "Programmable Interrupt Controller with Advanced Scheduling"
// feature brief: 16 hardware sources + 16 software channels (32 logical
// sources) feeding one priority-resolution pipeline that drives a single
// prioritised request to the CPU. Verilog-2005 (IEEE 1364-2005), AXI4-Lite
// slave per ARM IHI0022E, behavioural RTL, no vendor IP.
//
// The brief is a draft that delegates the "non-standard design challenges" to
// the intern; the choices below (Dn) are the feature spec, mirrored in
// README.md / ARCHITECTURE.md.
//
// SOURCES (brief "Interrupt Sources")
//   - 16 hardware lines irq_src[15:0], each level- or edge-triggered per
//     SRCx_CONFIG.TRIG.
//   - 16 software channels, one per slot, set by a keyed SRCx_SW_TRIG write.
//     A software request merges into the same slot, so once in the pipeline it
//     is indistinguishable from a hardware request.
//   - Slot request:  req = (level ? irq_src : edge_latch | sw) & INT_ENABLE.
//
// PRIORITY BANDS (D-BAND) — "Custom Priority Grouping"
//   - 4 bands. BAND_CONFIG gives each band a 2-bit urgency (higher = more
//     urgent), so software reorders bands without touching per-source config.
//     Default band 0 highest .. band 3 lowest.
//   - Each source has a 2-bit band + 4-bit intra-band priority. Effective key
//     = {band_urgency, intra_priority, ~index}: band dominates, then intra,
//     then lowest index wins the final tie (deterministic, no starvation for a
//     fully-specified config).
//   - Reconfiguring a source's band while it is active cannot corrupt nesting:
//     the key is snapshotted onto the stack at claim (D-NEST), so the active
//     threshold is stable; new pending evaluations use the new band at once.
//
// PREEMPTION + NESTING (D-NEST) — "Interrupt Preemption with Nesting"
//   - Hardware nesting stack (depth 0..NEST_MAX, NEST_MAX in [1,16]) holds the
//     key+id of every in-service source. Only a source strictly more urgent
//     than the top-of-stack key is offered, so a higher one preempts a lower
//     one. cpu_irq_ack pushes (claim); cpu_irq_eoi pops (return).
//   - The depth limit is enforced by masking offers at depth==NEST_MAX, so the
//     CPU never claims past the limit. A preemption blocked by the limit sets
//     INT_STATUS.OVF / NEST_STATUS.OVF (visible, non-destructive).
//
// SPURIOUS (D-SPUR) — "Spurious Interrupt Detection and Handling"
//   - Detected at claim: if the offered source's request has deasserted by the
//     time cpu_irq_ack lands, the claim is spurious. A source still asserted at
//     claim (cleared later, in-handler) is legitimate, not spurious.
//   - Response: SRCx_STATUS.SPUR + sticky SPURIOUS_LOG[x] (R/W1C) +
//     INT_STATUS.SPUR. The claim is still accounted on the stack so ack/eoi
//     stay balanced (a vectored CPU has already committed to the handler);
//     software reads the flag and early-outs.
//
// DEADLINE ESCALATION (D-DDL) — "Deadline-Aware Priority Escalation"
//   - Each source has a 16-bit deadline (cycles, 0 = disabled). A per-source
//     counter runs while the slot is a pending request awaiting service. On
//     reaching the deadline the effective band escalates per ESCALATION_CFG
//     (jump to a target band, or bump one band more urgent) and SRCx_STATUS.ESC
//     / INT_STATUS.ESC are set. With multi-escalation the counter re-arms and
//     can escalate again. On claim / return to idle band and counter reset.
//
// SOFTWARE TRIGGERS (D-SW) — "Software-Triggered Interrupts"
//   - SRCx_SW_TRIG: write bit0=1 with key 0xA5A5 in [31:16] to set the channel
//     (the key guards against an accidental single-bit trigger); write bit0=0
//     to clear. A software request also auto-clears on claim, so it is consumed
//     like an edge source. A software trigger on a slot that already has a
//     hardware request just keeps the slot pending. Software requests take
//     deadlines / escalation like any other source.
//
// CPU HANDSHAKE
//   cpu_irq      registered level request (off the source timing path, D-LAT).
//   cpu_irq_vec  id (0..15) of the source presented in cpu_irq.
//   cpu_irq_ack  claim pulse: CPU entered the handler for cpu_irq_vec.
//   cpu_irq_eoi  end-of-interrupt pulse: innermost handler is returning (the
//                completion signal the brief's nesting section requires; the
//                CPU raises it on an interrupt-returning MRET).
//
// AXI4-Lite (D-AXI): the shared axi_lite_slave owns the handshake; this module
// is the register file. Unmapped words, and writes to read-only words, SLVERR.
// Byte strobes are honoured on writes.

module pic (
    input             clk,
    input             rst_n,

    // 16 hardware interrupt source lines, level- or edge-triggered per source
    input      [15:0] irq_src,

    // CPU side
    output reg        cpu_irq,        // level-sensitive request to the CPU
    output reg [3:0]  cpu_irq_vec,    // id of the highest-priority active source
    input             cpu_irq_ack,    // claim pulse (enter handler)
    input             cpu_irq_eoi,    // end-of-interrupt pulse (return)

    // AXI4-Lite slave: configuration and status
    input      [31:0] s_axi_awaddr,
    input      [2:0]  s_axi_awprot,
    input             s_axi_awvalid,
    output            s_axi_awready,
    input      [31:0] s_axi_wdata,
    input      [3:0]  s_axi_wstrb,
    input             s_axi_wvalid,
    output            s_axi_wready,
    output     [1:0]  s_axi_bresp,
    output            s_axi_bvalid,
    input             s_axi_bready,
    input      [31:0] s_axi_araddr,
    input      [2:0]  s_axi_arprot,
    input             s_axi_arvalid,
    output            s_axi_arready,
    output     [31:0] s_axi_rdata,
    output     [1:0]  s_axi_rresp,
    output            s_axi_rvalid,
    input             s_axi_rready
);

// ---------------------------------------------------------------------------
// Parameters and register map (word offset = byte addr[7:2])
// ---------------------------------------------------------------------------
localparam NSRC     = 16;   // logical source slots
localparam MAXNEST  = 16;   // physical nesting-stack depth

localparam W_CFG_BASE  = 6'd0;    // SRCx_CONFIG   0x00..0x3C (16 words, R/W)
localparam W_SWT_BASE  = 6'd16;   // SRCx_SW_TRIG  0x40..0x7C (16 words, R/W)
localparam W_STA_BASE  = 6'd32;   // SRCx_STATUS   0x80..0xBC (16 words, RO)
localparam W_BAND      = 6'd48;   // BAND_CONFIG    0xC0  R/W
localparam W_NEST_ST   = 6'd49;   // NEST_STATUS    0xC4  RO
localparam W_NEST_MAX  = 6'd50;   // NEST_MAX       0xC8  R/W
localparam W_ACT_VEC   = 6'd51;   // ACTIVE_VEC     0xCC  RO
localparam W_SPUR_LOG  = 6'd52;   // SPURIOUS_LOG   0xD0  R/W1C
localparam W_ESC_CFG   = 6'd53;   // ESCALATION_CFG 0xD4  R/W
localparam W_INT_EN    = 6'd54;   // INT_ENABLE     0xD8  R/W
localparam W_INT_ST    = 6'd55;   // INT_STATUS     0xDC  R/W1C
localparam W_LAST      = 6'd55;   // last mapped word

localparam SW_KEY = 16'hA5A5;     // software-trigger arming key (D-SW)

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
reg  [31:0] src_config [0:NSRC-1];  // {DEADLINE[31:16], INTRA[7:4], BAND[2:1], TRIG[0]}
reg  [15:0] sw_pend;                // software-injected request per slot (D-SW)
reg  [15:0] int_enable;             // INT_ENABLE: per-source master enable
reg  [7:0]  band_cfg;               // BAND_CONFIG: 2-bit urgency per band
reg  [4:0]  nest_max;               // NEST_MAX: depth limit [1,16]
reg  [8:0]  esc_cfg;                // ESCALATION_CFG {MULTI[8], MODE[4], TARGET[1:0]}
reg  [15:0] spurious_log;           // SPURIOUS_LOG: sticky per-source (R/W1C)
reg  [2:0]  int_status;             // INT_STATUS {OVF[2], ESC[1], SPUR[0]} (R/W1C)

reg  [15:0] irq_src_q;              // sampled sources, for edge detection
reg  [15:0] edge_pend;              // latched edge requests
reg  [15:0] active;                 // in-service (on the nesting stack)
reg  [15:0] escalated;              // deadline missed, priority escalated (D-DDL)
reg  [15:0] spurious;               // current claim of this slot was spurious
reg  [1:0]  eff_band  [0:NSRC-1];   // effective band incl. escalation
reg  [15:0] ddl_cnt   [0:NSRC-1];   // deadline elapsed-time counters

reg  [3:0]  stack_id  [0:MAXNEST-1];
reg  [9:0]  stack_key [0:MAXNEST-1];
reg  [4:0]  depth;                  // 0..MAXNEST
reg  [3:0]  cpu_irq_vec_d;          // vector as presented last cycle (claim aligns to it)

// ESCALATION_CFG fields
wire [1:0]  esc_target = esc_cfg[1:0];
wire        esc_bump   = esc_cfg[4];   // 0 = jump to target, 1 = one band more urgent
wire        esc_multi  = esc_cfg[8];   // escalate more than once

// nesting-stack top
wire        has_active = (depth != 5'd0);
wire [3:0]  top_idx    = depth[3:0] - 4'd1;   // valid only when has_active
wire [9:0]  top_key    = stack_key[top_idx];

// per-source config fields
wire        cfg_trig  [0:NSRC-1];
wire [1:0]  cfg_band  [0:NSRC-1];
wire [3:0]  cfg_intra [0:NSRC-1];
wire [15:0] cfg_ddl   [0:NSRC-1];

wire [15:0] req;                    // enabled request per slot
wire [9:0]  key       [0:NSRC-1];   // effective priority key, higher = more urgent
wire [15:0] escalate_v;             // per-source escalation pulse

// band-urgency lookup (band_cfg passed in so the assign stays sensitive to it)
function [1:0] band_urg;
    input [1:0] b;
    input [7:0] bc;
    case (b)
        2'd0:    band_urg = bc[1:0];
        2'd1:    band_urg = bc[3:2];
        2'd2:    band_urg = bc[5:4];
        default: band_urg = bc[7:6];
    endcase
endfunction

// ---------------------------------------------------------------------------
// Claim / end-of-interrupt (needs depth, nest_max, cpu handshake, req)
// ---------------------------------------------------------------------------
// cpu_irq_ack is registered one cycle after the CPU sampled cpu_irq_vec, so the
// vector it acted on is the delayed copy; claiming that keeps the PIC's id in
// step with the CPU's latched mcause even if a higher source arrived meanwhile.
wire [3:0] claimed_id = cpu_irq_vec_d;
wire       claim_push = cpu_irq_ack && (depth < nest_max);   // offers masked at limit
wire       claim_spur = claim_push && !req[claimed_id];      // deasserted before ack
wire       eoi_pop    = cpu_irq_eoi && has_active;

// ---------------------------------------------------------------------------
// Per-source request, key, deadline / escalation
// ---------------------------------------------------------------------------
genvar s;
generate for (s = 0; s < NSRC; s = s + 1) begin : g_src
    assign cfg_trig[s]  = src_config[s][0];
    assign cfg_band[s]  = src_config[s][2:1];
    assign cfg_intra[s] = src_config[s][7:4];
    assign cfg_ddl[s]   = src_config[s][31:16];

    // request: raw level or a latched edge, OR the software channel, & enable
    wire hw_req   = cfg_trig[s] ? edge_pend[s] : irq_src[s];
    assign req[s] = (hw_req | sw_pend[s]) & int_enable[s];

    // effective priority key (lowest index wins the final tie => 15-s)
    wire [3:0] idxtb = 15 - s;
    assign key[s] = { band_urg(eff_band[s], band_cfg), cfg_intra[s], idxtb };

    wire claim_s = claim_push && (claimed_id == s[3:0]);

    // deadline counter: runs only while pending, awaiting service, with a
    // deadline configured (a deadline of 0 disables it and holds the count at 0)
    wire waiting  = req[s] && !active[s];
    wire counting = waiting && (cfg_ddl[s] != 16'd0);
    wire ddl_hit  = counting && (ddl_cnt[s] + 16'd1 >= cfg_ddl[s]);
    assign escalate_v[s] = ddl_hit && (!escalated[s] || esc_multi);

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)             edge_pend[s] <= 1'b0;
        else if (claim_s)       edge_pend[s] <= 1'b0;                 // consumed
        else if (cfg_trig[s] && irq_src[s] && !irq_src_q[s])
                                edge_pend[s] <= 1'b1;                 // rising edge
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)             ddl_cnt[s] <= 16'd0;
        else if (!counting)     ddl_cnt[s] <= 16'd0;                  // idle / no deadline
        else if (escalate_v[s]) ddl_cnt[s] <= 16'd0;                  // re-arm window
        else if (!ddl_hit)      ddl_cnt[s] <= ddl_cnt[s] + 16'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)             escalated[s] <= 1'b0;
        else if (!waiting)      escalated[s] <= 1'b0;
        else if (escalate_v[s]) escalated[s] <= 1'b1;
    end

    // effective band: reset to config when idle, jump/bump on a deadline miss,
    // otherwise track config while still unescalated. The escalate branch is
    // ordered before the unescalated-track branch so it wins on the miss cycle
    // (escalated[s] only rises next cycle).
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)              eff_band[s] <= 2'd0;
        else if (!waiting)       eff_band[s] <= cfg_band[s];   // idle: reset to config
        else if (escalate_v[s])                                // deadline miss
            eff_band[s] <= esc_bump ? (eff_band[s] == 2'd0 ? 2'd0 : eff_band[s] - 2'd1)
                                    : esc_target;
        else if (!escalated[s])  eff_band[s] <= cfg_band[s];   // pre-escalation: track config
    end
end endgenerate

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) irq_src_q <= 16'd0;
    else        irq_src_q <= irq_src;
end

// ---------------------------------------------------------------------------
// Priority resolver: most-urgent eligible source (combinational)
// ---------------------------------------------------------------------------
// eligible: pending (requesting, not in service) and, when something is already
// in service, strictly more urgent than the top of the nesting stack.
integer i;
reg  [9:0] res_key;
reg  [3:0] res_id;
reg        res_val;
always @(*) begin
    res_key = 10'd0;
    res_id  = 4'd0;
    res_val = 1'b0;
    for (i = 0; i < NSRC; i = i + 1) begin
        if (req[i] && !active[i] && (!has_active || key[i] > top_key)) begin
            if (!res_val || key[i] > res_key) begin
                res_key = key[i];
                res_id  = i[3:0];
                res_val = 1'b1;
            end
        end
    end
end

wire offer_val   = res_val && (depth < nest_max);
wire depth_block = res_val && (depth >= nest_max);   // preemption blocked at limit

// registered CPU request/vector (D-LAT: off the source timing path)
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        cpu_irq     <= 1'b0;
        cpu_irq_vec <= 4'd0;
    end else begin
        cpu_irq <= offer_val;
        if (offer_val) cpu_irq_vec <= res_id;   // hold last presented id when idle
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) cpu_irq_vec_d <= 4'd0;
    else        cpu_irq_vec_d <= cpu_irq_vec;
end

// ---------------------------------------------------------------------------
// Nesting stack, active mask, spurious flags (D-NEST / D-SPUR)
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)         depth <= 5'd0;
    else if (claim_push) depth <= depth + 5'd1;
    else if (eoi_pop)    depth <= depth - 5'd1;
end

always @(posedge clk) begin
    if (claim_push) begin
        stack_id [depth[3:0]] <= claimed_id;
        stack_key[depth[3:0]] <= key[claimed_id];
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) active <= 16'd0;
    else begin
        if (claim_push) active[claimed_id]        <= 1'b1;
        if (eoi_pop)    active[stack_id[top_idx]] <= 1'b0;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) spurious <= 16'd0;
    else begin
        if (claim_push && claim_spur) spurious[claimed_id]        <= 1'b1;
        if (eoi_pop)                  spurious[stack_id[top_idx]] <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// AXI4-Lite slave (D-AXI)
// ---------------------------------------------------------------------------
wire        reg_wr;
wire [5:0]  reg_waddr, reg_raddr;
wire [31:0] reg_wdata, reg_rdata;
wire [3:0]  reg_wstrb;

wire w_is_cfg = (reg_waddr < W_CFG_BASE + NSRC);                    // base is word 0
wire w_is_swt = (reg_waddr >= W_SWT_BASE) && (reg_waddr < W_SWT_BASE + NSRC);
wire wr_ok    = w_is_cfg | w_is_swt |
                (reg_waddr == W_BAND)     | (reg_waddr == W_NEST_MAX) |
                (reg_waddr == W_SPUR_LOG) | (reg_waddr == W_ESC_CFG)  |
                (reg_waddr == W_INT_EN)   | (reg_waddr == W_INT_ST);
wire rd_ok    = (reg_raddr <= W_LAST);

axi_lite_slave pic_slv (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .wr_en(reg_wr), .wr_addr(reg_waddr), .wr_data(reg_wdata), .wr_strb(reg_wstrb),
    .wr_ok(wr_ok),
    .rd_addr(reg_raddr), .rd_data(reg_rdata), .rd_ok(rd_ok)
);

// byte-strobe merge
function [31:0] wmerge;
    input [31:0] oldv;
    input [31:0] neww;
    input [3:0]  strb;
    begin
        wmerge = { strb[3] ? neww[31:24] : oldv[31:24],
                   strb[2] ? neww[23:16] : oldv[23:16],
                   strb[1] ? neww[15:8]  : oldv[15:8],
                   strb[0] ? neww[7:0]   : oldv[7:0] };
    end
endfunction

wire       wr_cfg   = reg_wr && w_is_cfg;
wire       wr_swt   = reg_wr && w_is_swt;
wire [3:0] cfg_widx = reg_waddr[3:0];
wire [3:0] swt_widx = reg_waddr[3:0];

// byte-strobe-merged next values for the narrow global registers
wire [31:0] band_merge  = wmerge({24'b0, band_cfg},   reg_wdata, reg_wstrb);
wire [31:0] esc_merge   = wmerge({23'b0, esc_cfg},    reg_wdata, reg_wstrb);
wire [31:0] inten_merge = wmerge({16'b0, int_enable}, reg_wdata, reg_wstrb);

// SRCx_CONFIG
integer c;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (c = 0; c < NSRC; c = c + 1) src_config[c] <= 32'd0;
    end else if (wr_cfg)
        src_config[cfg_widx] <= wmerge(src_config[cfg_widx], reg_wdata, reg_wstrb);
end

// SRCx_SW_TRIG (D-SW): keyed set, plain clear, auto-clear on claim
wire swt_key_ok = (reg_wdata[31:16] == SW_KEY);
wire swt_set    = wr_swt && reg_wstrb[0] &&  reg_wdata[0] && swt_key_ok;
wire swt_clr    = wr_swt && reg_wstrb[0] && !reg_wdata[0];
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) sw_pend <= 16'd0;
    else begin
        if (claim_push) sw_pend[claimed_id] <= 1'b0;   // consumed on claim
        if (swt_set)      sw_pend[swt_widx] <= 1'b1;
        else if (swt_clr) sw_pend[swt_widx] <= 1'b0;
    end
end

// BAND_CONFIG
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) band_cfg <= 8'h1B;         // band0=3 (most urgent) .. band3=0
    else if (reg_wr && reg_waddr == W_BAND)
        band_cfg <= band_merge[7:0];
end

// NEST_MAX (clamp to [1, MAXNEST])
wire [4:0] nest_max_wr = reg_wdata[4:0];
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) nest_max <= 5'd8;
    else if (reg_wr && reg_waddr == W_NEST_MAX && reg_wstrb[0]) begin
        if (nest_max_wr == 5'd0)             nest_max <= 5'd1;
        else if (nest_max_wr > MAXNEST[4:0]) nest_max <= MAXNEST[4:0];
        else                                 nest_max <= nest_max_wr;
    end
end

// ESCALATION_CFG
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) esc_cfg <= 9'd0;           // jump to band 0, single escalation
    else if (reg_wr && reg_waddr == W_ESC_CFG)
        esc_cfg <= esc_merge[8:0];
end

// INT_ENABLE
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) int_enable <= 16'd0;
    else if (reg_wr && reg_waddr == W_INT_EN)
        int_enable <= inten_merge[15:0];
end

// SPURIOUS_LOG (R/W1C): hardware sets on a spurious claim, software writes 1 to
// clear. A hardware set wins over a same-cycle W1C clear of the same bit.
wire [15:0] spur_w1c = (reg_wr && reg_waddr == W_SPUR_LOG)
                       ? { (reg_wstrb[1] ? reg_wdata[15:8] : 8'b0),
                           (reg_wstrb[0] ? reg_wdata[7:0]  : 8'b0) } : 16'b0;
wire [15:0] spur_set = (claim_push && claim_spur) ? (16'b1 << claimed_id) : 16'b0;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) spurious_log <= 16'd0;
    else        spurious_log <= (spurious_log & ~spur_w1c) | spur_set;
end

// INT_STATUS (R/W1C): sticky global event flags {OVF, ESC, SPUR}; a hardware set
// wins over a same-cycle W1C clear.
wire      int_st_wr  = reg_wr && reg_waddr == W_INT_ST && reg_wstrb[0];
wire [2:0] int_st_w1c = int_st_wr ? reg_wdata[2:0] : 3'b0;
wire [2:0] int_st_set = { depth_block, (|escalate_v), (claim_push && claim_spur) };
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) int_status <= 3'd0;
    else        int_status <= (int_status & ~int_st_w1c) | int_st_set;
end

// ---------------------------------------------------------------------------
// Read mux (combinational; the slave registers it on the AR handshake)
// ---------------------------------------------------------------------------
reg  [31:0] rmux;
wire [3:0]  rd_idx = reg_raddr[3:0];
always @(*) begin
    if (reg_raddr < W_CFG_BASE + NSRC)              // SRCx_CONFIG
        rmux = src_config[rd_idx];
    else if (reg_raddr < W_SWT_BASE + NSRC)         // SRCx_SW_TRIG
        rmux = {31'b0, sw_pend[rd_idx]};
    else if (reg_raddr < W_STA_BASE + NSRC)         // SRCx_STATUS (RO)
        rmux = { ddl_cnt[rd_idx],                   // [31:16] elapsed time
                 8'b0, 2'b0, eff_band[rd_idx],      // [7:6]=0 [5:4]=eff band
                 spurious[rd_idx], escalated[rd_idx],
                 active[rd_idx], req[rd_idx] };      // [3]spur [2]esc [1]active [0]pending
    else begin
        case (reg_raddr)
            W_BAND:     rmux = {24'b0, band_cfg};
            W_NEST_ST:  rmux = {15'b0, int_status[2],                       // [16] overflow seen
                                4'b0, (has_active ? stack_id[top_idx] : 4'd0), // [11:8] top id
                                3'b0, depth};                              // [4:0] depth
            W_NEST_MAX: rmux = {27'b0, nest_max};
            W_ACT_VEC:  rmux = {23'b0, has_active,                         // [8] valid
                                4'b0, (has_active ? stack_id[top_idx] : 4'd0)};
            W_SPUR_LOG: rmux = {16'b0, spurious_log};
            W_ESC_CFG:  rmux = {23'b0, esc_cfg};
            W_INT_EN:   rmux = {16'b0, int_enable};
            W_INT_ST:   rmux = {29'b0, int_status};
            default:    rmux = 32'd0;
        endcase
    end
end
assign reg_rdata = rmux;

endmodule
