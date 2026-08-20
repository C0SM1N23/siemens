// Load/store unit: drives AXI4-Lite transactions on dbus.
// REQ# = spec requirement, D# = design choice, both tracked in the README.
//
// Keeps S2 stalled for the whole round-trip, builds the SB/SH/SW WSTRB pattern,
// extracts the byte/half on loads with sign/zero extension, and turns AXI
// SLVERR/DECERR into access faults.
//
// REQ5:  S2 stays stalled for the whole data transaction; `busy` drops only once
//        the response handshake has completed.
// REQ11: store byte enables match the DP-SRAM slave directly (no adapter).
//        WSTRB: SB = 0001<<addr_i[1:0] (byte replicated, WSTRB picks the live one);
//        SH = 0011<<addr_i[1:0] (addr_i[0]=0 for aligned halfwords); SW = 1111. Loads
//        pick the byte/half by addr_i[1:0], then sign/zero-extend by funct3_i.
// REQ12: SLVERR/DECERR raise an access fault in S2: load -> cause 5, store -> 7.
// D12:   one outstanding transaction; address and write data are latched at
//        request start, since forwarded operands are only valid in the first
//        cycle (S3 bubbles while S2 stalls) and AXI wants a stable payload.
//        Handshakes are tracked per channel, so moving to AXI4-Full later is an
//        extension rather than a rewrite.
//
// `req` is raised only for a legal, aligned, non-squashed op (misaligned traps
// earlier, so nothing issues here).
//
// Reset: every flop in this module is reset by the asynchronous, active-low
// rst_n_i. The FSM state and the three handshake trackers need it. The command
// latch does not (it is read only while a transaction is in flight, and each new
// transaction overwrites it before the first read), but it is reset anyway, so
// that AWADDR / ARADDR / WDATA / WSTRB are driven with defined values from time
// zero instead of X while the LSU is idle.

`timescale 1ns/1ps

module lsu (
    input             clk_i,
    input             rst_n_i,

    // command from S2, stable while busy_o
    input             req_i,          // valid memory op this cycle
    input             we_i,           // 1 = store, 0 = load
    input      [2:0]  funct3_i,       // size + sign extension
    input      [31:0] addr_i,         // byte address (ALU result)
    input      [31:0] st_data_i,      // rs2, forwarded

    output            busy_o,         // transaction not finished -> stall S2
    output            done_o,         // response accepted this cycle
    output            err_o,          // SLVERR / DECERR on the response
    output            active_o,       // transaction issued (blocks interrupts mid-op)
    output     [31:0] ld_data_o,      // extended load data, valid on done_o with we_i low

    // dbus AXI4-Lite master
    output     [31:0] dbus_awaddr_o,
    output     [2:0]  dbus_awprot_o,
    output            dbus_awvalid_o,
    input             dbus_awready_i,
    output     [31:0] dbus_wdata_o,
    output     [3:0]  dbus_wstrb_o,
    output            dbus_wvalid_o,
    input             dbus_wready_i,
    input      [1:0]  dbus_bresp_i,
    input             dbus_bvalid_i,
    output            dbus_bready_o,
    output     [31:0] dbus_araddr_o,
    output     [2:0]  dbus_arprot_o,
    output            dbus_arvalid_o,
    input             dbus_arready_i,
    input      [31:0] dbus_rdata_i,
    input      [1:0]  dbus_rresp_i,
    input             dbus_rvalid_i,
    output            dbus_rready_o
);

// data access, privileged (M-mode), non-secure
assign dbus_awprot_o = 3'b011;
assign dbus_arprot_o = 3'b011;

localparam S_IDLE = 2'd0,
           S_RD   = 2'd1,
           S_WR   = 2'd2;

reg [1:0]  state_q;
reg        ar_sent_q, aw_sent_q, w_sent_q;
reg [31:0] addr_q, wdata_q;
reg [3:0]  wstrb_q;

wire start = req_i && (state_q == S_IDLE);

// store lanes, combinational now, latched at start
reg [31:0] st_lanes;
reg [3:0]  st_strb;
always @(*) begin
    case (funct3_i[1:0])
        2'b00: begin st_lanes = {4{st_data_i[7:0]}};  st_strb = 4'b0001 << addr_i[1:0]; end // SB
        2'b01: begin st_lanes = {2{st_data_i[15:0]}}; st_strb = 4'b0011 << addr_i[1:0]; end // SH
        default: begin st_lanes = st_data_i;          st_strb = 4'b1111;              end // SW
    endcase
end

// start cycle drives the channels combinationally, after that from the regs
assign dbus_araddr_o  = start ? addr_i     : addr_q;
assign dbus_awaddr_o  = start ? addr_i     : addr_q;
assign dbus_wdata_o   = start ? st_lanes : wdata_q;
assign dbus_wstrb_o   = start ? st_strb  : wstrb_q;

assign dbus_arvalid_o = (start && !we_i) || (state_q == S_RD && !ar_sent_q);
assign dbus_awvalid_o = (start &&  we_i) || (state_q == S_WR && !aw_sent_q);
assign dbus_wvalid_o  = (start &&  we_i) || (state_q == S_WR && !w_sent_q);

// only accept the response once the address/data phases have completed
assign dbus_rready_o  = (state_q == S_RD) && ar_sent_q;
assign dbus_bready_o  = (state_q == S_WR) && aw_sent_q && w_sent_q;

wire rd_done = dbus_rready_o && dbus_rvalid_i;
wire wr_done = dbus_bready_o && dbus_bvalid_i;

assign done_o   = rd_done | wr_done;
assign err_o    = rd_done ? dbus_rresp_i[1] : dbus_bresp_i[1];
assign active_o = (state_q != S_IDLE);
assign busy_o   = (start || active_o) && !done_o;

// load extract: one shifter serves both widths. A misaligned LH/LHU traps
// before the bus, so shifting by the byte offset leaves the half in [15:0].
wire [31:0] ld_shift = dbus_rdata_i >> {addr_q[1:0], 3'b000};
wire [7:0]  lbyte    = ld_shift[7:0];
wire [15:0] lhalf    = ld_shift[15:0];

reg [31:0] ld_ext;
always @(*) begin
    case (funct3_i)
        3'b000:  ld_ext = {{24{lbyte[7]}},  lbyte};  // LB
        3'b001:  ld_ext = {{16{lhalf[15]}}, lhalf};  // LH
        3'b100:  ld_ext = {24'b0, lbyte};            // LBU
        3'b101:  ld_ext = {16'b0, lhalf};            // LHU
        default: ld_ext = dbus_rdata_i;                // LW
    endcase
end
assign ld_data_o = ld_ext;

// FSM: idle -> RD/WR at start, back to idle when the response is accepted
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        state_q <= S_IDLE;
    else if (start)
        state_q <= we_i ? S_WR : S_RD;
    else if (done_o)
        state_q <= S_IDLE;
end

// one handshake tracker per channel. A handshake can land in the start cycle,
// so start captures it instead of clearing blindly; done_o re-arms it.
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        ar_sent_q <= 1'b0;
    else if (start)
        ar_sent_q <= dbus_arvalid_o && dbus_arready_i;
    else if (done_o)
        ar_sent_q <= 1'b0;
    else if (dbus_arvalid_o && dbus_arready_i)
        ar_sent_q <= 1'b1;
end

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        aw_sent_q <= 1'b0;
    else if (start)
        aw_sent_q <= dbus_awvalid_o && dbus_awready_i;
    else if (done_o)
        aw_sent_q <= 1'b0;
    else if (dbus_awvalid_o && dbus_awready_i)
        aw_sent_q <= 1'b1;
end

always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        w_sent_q <= 1'b0;
    else if (start)
        w_sent_q <= dbus_wvalid_o && dbus_wready_i;
    else if (done_o)
        w_sent_q <= 1'b0;
    else if (dbus_wvalid_o && dbus_wready_i)
        w_sent_q <= 1'b1;
end

// command latch (reset, see header)
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i) begin
        addr_q  <= 32'd0;
        wdata_q <= 32'd0;
        wstrb_q <= 4'd0;
    end else if (start) begin
        addr_q  <= addr_i;
        wdata_q <= st_lanes;
        wstrb_q <= st_strb;
    end
end

endmodule
