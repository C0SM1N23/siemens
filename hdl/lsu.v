// Load/store unit: drives AXI4-Lite transactions on dbus.
// REQ# = spec requirement, D# = design choice, both tracked in the README.
//
// Keeps S2 stalled for the whole round-trip, builds the SB/SH/SW WSTRB pattern,
// extracts the byte/half on loads with sign/zero extension, and turns AXI
// SLVERR/DECERR into access faults.
//
// REQ5:  S2 stays stalled for the whole data transaction; `busy` drops only once
//        the response handshake is done.
// REQ11: store byte enables match the DP-SRAM slave directly (no adapter).
//        WSTRB: SB = 0001<<addr[1:0] (byte replicated, WSTRB picks the live one);
//        SH = 0011<<addr[1:0] (addr[0]=0 for aligned halfwords); SW = 1111. Loads
//        pick the byte/half by addr[1:0], then sign/zero-extend by funct3.
// REQ12: SLVERR/DECERR raise an access fault in S2: load -> cause 5, store -> 7.
// D12:   one outstanding transaction; address and write data are latched at
//        request start, since forwarded operands are only valid in the first
//        cycle (S3 bubbles while S2 stalls) and AXI wants a stable payload.
//        Handshakes are tracked per channel, so moving to AXI4-Full later is an
//        extension rather than a rewrite.
//
// `req` is raised only for a legal, aligned, non-squashed op (misaligned traps
// earlier, so nothing issues here). The command latch has no reset: it's read
// only while a transaction is active, and each new one overwrites it first.

`timescale 1ns/1ps

module lsu (
    input             clk,
    input             rst_n,

    // command from S2, stable while busy
    input             req,          // valid memory op this cycle
    input             we,           // 1 = store, 0 = load
    input      [2:0]  funct3,       // size + sign extension
    input      [31:0] addr,         // byte address (ALU result)
    input      [31:0] st_data,      // rs2, forwarded

    output            busy,         // transaction not finished -> stall S2
    output            done,         // response accepted this cycle
    output            err,          // SLVERR / DECERR on the response
    output            active,       // transaction issued (blocks interrupts mid-op)
    output     [31:0] ld_data,      // extended load data, valid when done && !we

    // dbus AXI4-Lite master
    output     [31:0] dbus_awaddr,
    output     [2:0]  dbus_awprot,
    output            dbus_awvalid,
    input             dbus_awready,
    output     [31:0] dbus_wdata,
    output     [3:0]  dbus_wstrb,
    output            dbus_wvalid,
    input             dbus_wready,
    input      [1:0]  dbus_bresp,
    input             dbus_bvalid,
    output            dbus_bready,
    output     [31:0] dbus_araddr,
    output     [2:0]  dbus_arprot,
    output            dbus_arvalid,
    input             dbus_arready,
    input      [31:0] dbus_rdata,
    input      [1:0]  dbus_rresp,
    input             dbus_rvalid,
    output            dbus_rready
);

// data access, privileged (M-mode), non-secure
assign dbus_awprot = 3'b011;
assign dbus_arprot = 3'b011;

localparam S_IDLE = 2'd0,
           S_RD   = 2'd1,
           S_WR   = 2'd2;

reg [1:0]  state_q;
reg        ar_sent_q, aw_sent_q, w_sent_q;
reg [31:0] addr_q, wdata_q;
reg [3:0]  wstrb_q;

wire start = req && (state_q == S_IDLE);

// store lanes, combinational now, latched at start
reg [31:0] st_lanes;
reg [3:0]  st_strb;
always @(*) begin
    case (funct3[1:0])
        2'b00: begin st_lanes = {4{st_data[7:0]}};  st_strb = 4'b0001 << addr[1:0]; end // SB
        2'b01: begin st_lanes = {2{st_data[15:0]}}; st_strb = 4'b0011 << addr[1:0]; end // SH
        default: begin st_lanes = st_data;          st_strb = 4'b1111;              end // SW
    endcase
end

// start cycle drives the channels combinationally, after that from the regs
assign dbus_araddr  = start ? addr     : addr_q;
assign dbus_awaddr  = start ? addr     : addr_q;
assign dbus_wdata   = start ? st_lanes : wdata_q;
assign dbus_wstrb   = start ? st_strb  : wstrb_q;

assign dbus_arvalid = (start && !we) || (state_q == S_RD && !ar_sent_q);
assign dbus_awvalid = (start &&  we) || (state_q == S_WR && !aw_sent_q);
assign dbus_wvalid  = (start &&  we) || (state_q == S_WR && !w_sent_q);

// only accept the response once the address/data phases are done
assign dbus_rready  = (state_q == S_RD) && ar_sent_q;
assign dbus_bready  = (state_q == S_WR) && aw_sent_q && w_sent_q;

wire rd_done = dbus_rready && dbus_rvalid;
wire wr_done = dbus_bready && dbus_bvalid;

assign done   = rd_done | wr_done;
assign err    = rd_done ? dbus_rresp[1] : dbus_bresp[1];
assign active = (state_q != S_IDLE);
assign busy   = (start || active) && !done;

// load extract: one shifter serves both widths. A misaligned LH/LHU traps
// before the bus, so shifting by the byte offset leaves the half in [15:0].
wire [31:0] ld_shift = dbus_rdata >> {addr_q[1:0], 3'b000};
wire [7:0]  lbyte    = ld_shift[7:0];
wire [15:0] lhalf    = ld_shift[15:0];

reg [31:0] ld_ext;
always @(*) begin
    case (funct3)
        3'b000:  ld_ext = {{24{lbyte[7]}},  lbyte};  // LB
        3'b001:  ld_ext = {{16{lhalf[15]}}, lhalf};  // LH
        3'b100:  ld_ext = {24'b0, lbyte};            // LBU
        3'b101:  ld_ext = {16'b0, lhalf};            // LHU
        default: ld_ext = dbus_rdata;                // LW
    endcase
end
assign ld_data = ld_ext;

// FSM: idle -> RD/WR at start, back to idle when the response is accepted
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        state_q <= S_IDLE;
    else if (start)
        state_q <= we ? S_WR : S_RD;
    else if (done)
        state_q <= S_IDLE;
end

// one handshake tracker per channel. A handshake can land in the start cycle,
// so start captures it instead of clearing blindly; done rearms it.
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        ar_sent_q <= 1'b0;
    else if (start)
        ar_sent_q <= dbus_arvalid && dbus_arready;
    else if (done)
        ar_sent_q <= 1'b0;
    else if (dbus_arvalid && dbus_arready)
        ar_sent_q <= 1'b1;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        aw_sent_q <= 1'b0;
    else if (start)
        aw_sent_q <= dbus_awvalid && dbus_awready;
    else if (done)
        aw_sent_q <= 1'b0;
    else if (dbus_awvalid && dbus_awready)
        aw_sent_q <= 1'b1;
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        w_sent_q <= 1'b0;
    else if (start)
        w_sent_q <= dbus_wvalid && dbus_wready;
    else if (done)
        w_sent_q <= 1'b0;
    else if (dbus_wvalid && dbus_wready)
        w_sent_q <= 1'b1;
end

// command latch (no reset, see header)
always @(posedge clk) begin
    if (start) begin
        addr_q  <= addr;
        wdata_q <= st_lanes;
        wstrb_q <= st_strb;
    end
end

endmodule
