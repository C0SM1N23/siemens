// Load/store unit — AXI4-Lite master on dbus.
// REQ# = spec requirement, D# = design decision; both indexed in the README.
//
// Spec requirements met here:
//   REQ5   S2 stalls for the whole data round-trip (busy stays up until the
//     R/B response is accepted).
//   REQ11  WSTRB byte-lane write enables for SB/SH/SW, matching what the
//     DP-SRAM slave expects, so stores/loads interoperate with no adapter:
//       SB  WSTRB = 0001 << addr[1:0], byte replicated across lanes
//       SH  WSTRB = 0011 << addr[1:0] (addr[0]=0 guaranteed), half replicated
//       SW  WSTRB = 1111
//     Loads select the byte/half by addr[1:0] and sign/zero-extend per funct3.
//   REQ12  SLVERR/DECERR on the response -> access fault in S2 (load 5/store 7).
//
// Design decision:
//   D12  one outstanding transaction. Address and write data latch at start —
//     the forwarded operands are only valid in the first cycle (S3 bubbles
//     while S2 stalls) and AXI needs them stable until the handshake anyway.
//     Per-channel handshake tracking keeps a later step to AXI4-Full additive
//     rather than a rewrite.
//
// req only asserts for a legal, aligned, non-squashed op (misalignment traps
// upstream with no transaction). err=1 on SLVERR/DECERR -> access fault (5/7).

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

// load extract: pick the lane by address, extend per funct3
wire [31:0] ld_shift = dbus_rdata >> {addr_q[1:0], 3'b000};
wire [7:0]  lbyte    = ld_shift[7:0];
wire [15:0] lhalf    = addr_q[1] ? dbus_rdata[31:16] : dbus_rdata[15:0];

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

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        state_q   <= S_IDLE;
        ar_sent_q <= 1'b0;
        aw_sent_q <= 1'b0;
        w_sent_q  <= 1'b0;
        addr_q    <= 32'b0;
        wdata_q   <= 32'b0;
        wstrb_q   <= 4'b0;
    end else begin
        if (start) begin
            state_q   <= we ? S_WR : S_RD;
            ar_sent_q <= dbus_arvalid && dbus_arready;
            aw_sent_q <= dbus_awvalid && dbus_awready;
            w_sent_q  <= dbus_wvalid  && dbus_wready;
            addr_q    <= addr;
            wdata_q   <= st_lanes;
            wstrb_q   <= st_strb;
        end else if (done) begin
            state_q   <= S_IDLE;
            ar_sent_q <= 1'b0;
            aw_sent_q <= 1'b0;
            w_sent_q  <= 1'b0;
        end else begin
            if (dbus_arvalid && dbus_arready) ar_sent_q <= 1'b1;
            if (dbus_awvalid && dbus_awready) aw_sent_q <= 1'b1;
            if (dbus_wvalid  && dbus_wready)  w_sent_q  <= 1'b1;
        end
    end
end

endmodule
