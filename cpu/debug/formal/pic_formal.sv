// Formal harness for the PIC: invariants of the nesting stack, the depth limit,
// the software-trigger key and the offer, for every input sequence.
//
// Sources, the CPU mask and the register port are free; the register port only
// obeys AXI4-Lite (VALID holds with a stable payload until READY). The CPU obeys
// its side of the handshake: it claims only an offer it was shown the cycle
// before, never twice within three cycles (trap entry closes MIE), and never
// claims and ends in the same cycle.
//
// Proven by induction (PDR, the "prove" task): the stack never exceeds sixteen;
// NEST_MAX stays in 1..16; a claim at the depth limit and an EOI on an empty
// stack change nothing; a software request appears only through a keyed write
// with both key bytes and the command byte enabled; and only an enabled,
// unmasked, inactive source is ever offered. Checked for every sequence of 24
// cycles from reset (BMC, the "stack" task): the active sources are exactly as
// many as the open levels, and a spurious flag only marks an active source.
`default_nettype none
module pic_formal (
    input wire clk,
    input wire rst_n,

    input wire [15:0] irq_src,
    input wire [15:0] cpu_mask,
    input wire        ack,
    input wire        eoi,

    input wire [31:0] awaddr,
    input wire        awvalid,
    input wire [31:0] wdata,
    input wire [ 3:0] wstrb,
    input wire        wvalid,
    input wire        bready,
    input wire [31:0] araddr,
    input wire        arvalid,
    input wire        rready
);
    wire        cpu_irq, awready, wready, bvalid, arready, rvalid;
    wire [ 3:0] cpu_irq_vec;
    wire [15:0] pending;
    wire [ 1:0] bresp, rresp;
    wire [31:0] rdata;

    pic dut (
        .clk_i(clk), .rst_n_i(rst_n), .irq_src_i(irq_src), .cpu_mask_i(cpu_mask),
        .cpu_irq_o(cpu_irq), .cpu_irq_vec_o(cpu_irq_vec), .pending_o(pending),
        .cpu_irq_ack_i(ack), .cpu_irq_eoi_i(eoi),
        .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(3'b000), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
        .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
        .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
        .s_axi_araddr_i(araddr), .s_axi_arprot_i(3'b000), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
        .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready)
    );

    // Internal state, connected by pic.sby after flattening.
    wire [ 4:0] h_depth, h_nest_max;
    wire [15:0] h_active, h_spurious, h_sw_pend, h_eligible, h_req, h_int_enable;
    wire        h_reg_wr, h_offer_val;
    wire [ 5:0] h_reg_waddr;
    wire [31:0] h_reg_wdata;
    wire [ 3:0] h_reg_wstrb, h_res_id;

    reg f_past_valid = 1'b0, f_past_rst_n = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    always @(posedge clk) f_past_rst_n <= rst_n;
    initial assume (!rst_n);
    wire f_run = f_past_valid && f_past_rst_n && rst_n;

    // environment: AXI4-Lite master
    always @(*) if (!rst_n) assume (!awvalid && !wvalid && !arvalid);
    always @(posedge clk) if (f_run) begin
        if ($past(awvalid && !awready)) assume (awvalid && awaddr == $past(awaddr));
        if ($past(wvalid && !wready)) assume (wvalid && wdata == $past(wdata) && wstrb == $past(wstrb));
        if ($past(arvalid && !arready)) assume (arvalid && araddr == $past(araddr));
    end

    // environment: the CPU's side of the claim/EOI handshake
    reg ack_q1, ack_q2, irq_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) {ack_q1, ack_q2, irq_q} <= 3'b0; else {ack_q1, ack_q2, irq_q} <= {ack, ack_q1, cpu_irq};
    always @(*) begin
        if (!rst_n) assume (!ack && !eoi);
        if (ack) assume (irq_q && !ack_q1 && !ack_q2 && !eoi);
    end

    // properties
    always @(*) if (rst_n && f_past_valid) begin
        assert (h_depth <= 5'd16);
`ifdef STACK
        assert ($countones(h_active) == h_depth);
        assert ((h_spurious & ~h_active) == 16'b0);
`endif
        assert (h_nest_max >= 5'd1 && h_nest_max <= 5'd16);
        if (h_offer_val) assert (h_eligible[h_res_id] && h_depth < h_nest_max);
        assert ((h_eligible & ~(h_req & cpu_mask & ~h_active)) == 16'b0);
        assert ((h_req & ~h_int_enable) == 16'b0);
    end

    reg [4:0] p_depth, p_nest_max;
    reg       p_ack, p_eoi, p_keyed_any;
    reg [15:0] p_sw_pend, p_keyed;
    integer s;
    always @(posedge clk) begin
        p_depth    <= h_depth;
        p_nest_max <= h_nest_max;
        p_ack      <= ack;
        p_eoi      <= eoi;
        p_sw_pend  <= h_sw_pend;
        for (s = 0; s < 16; s = s + 1)
            p_keyed[s] <= h_reg_wr && h_reg_waddr == 6'd16 + s && h_reg_wdata[31:16] == 16'hA5A5
                          && h_reg_wstrb[3:2] == 2'b11 && h_reg_wstrb[0] && h_reg_wdata[0];
    end
    always @(*) if (f_run) begin
        if (p_ack && p_depth >= p_nest_max && !p_eoi) assert (h_depth == p_depth);  // claim refused
        if (p_eoi && p_depth == 5'd0 && !p_ack) assert (h_depth == 5'd0);           // empty EOI ignored
        assert ((h_sw_pend & ~p_sw_pend & ~p_keyed) == 16'b0);                     // only a keyed write sets
    end

    // reachability
    always @(posedge clk) if (f_run) begin
        cover (h_depth == 5'd4);
        cover (p_ack && p_depth >= p_nest_max);
        cover (h_spurious != 16'b0);
        cover ((h_sw_pend & ~p_sw_pend) != 16'b0);
    end
endmodule
`default_nettype wire
