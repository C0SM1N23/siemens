// 64-bit machine timer with AXI4-Lite registers.
// mtime increments once per clock; the comparison output is level-sensitive.
// Byte writes and register access rules are handled through axi_lite_slave.

module mtimer (
    input clk_i,
    input rst_n_i,

    // level interrupt to the system interrupt controller (PIC ch7 planned)
    output reg irq_o,

    // AXI4-Lite slave: software access
    input  [31:0] s_axi_awaddr_i,
    input  [ 2:0] s_axi_awprot_i,
    input         s_axi_awvalid_i,
    output        s_axi_awready_o,
    input  [31:0] s_axi_wdata_i,
    input  [ 3:0] s_axi_wstrb_i,
    input         s_axi_wvalid_i,
    output        s_axi_wready_o,
    output [ 1:0] s_axi_bresp_o,
    output        s_axi_bvalid_o,
    input         s_axi_bready_i,
    input  [31:0] s_axi_araddr_i,
    input  [ 2:0] s_axi_arprot_i,
    input         s_axi_arvalid_i,
    output        s_axi_arready_o,
    output [31:0] s_axi_rdata_o,
    output [ 1:0] s_axi_rresp_o,
    output        s_axi_rvalid_o,
    input         s_axi_rready_i
);

    // register offsets (word address bits [7:2])
    localparam OFF_TIME_LO = 6'd0;
    localparam OFF_TIME_HI = 6'd1;
    localparam OFF_CMP_LO  = 6'd2;
    localparam OFF_CMP_HI  = 6'd3;

    reg  [63:0] mtime_q;
    reg  [63:0] mtimecmp_q;  // reset all-ones = disarmed (D26)

    // --- AXI4-Lite slave (D27): shared handshake in axi_lite_slave; the mtimer
    // just describes its four registers (all writable; past CMP_HI SLVERR) ---
    wire        reg_wr;
    wire [5:0] reg_waddr, reg_raddr;
    wire [31:0] reg_wdata, reg_rdata;
    wire [3:0] reg_wstrb;

    axi_lite_slave tmr_slv (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),
        .s_axi_awaddr_i (s_axi_awaddr_i),
        .s_axi_awvalid_i(s_axi_awvalid_i),
        .s_axi_awready_o(s_axi_awready_o),
        .s_axi_wdata_i  (s_axi_wdata_i),
        .s_axi_wstrb_i  (s_axi_wstrb_i),
        .s_axi_wvalid_i (s_axi_wvalid_i),
        .s_axi_wready_o (s_axi_wready_o),
        .s_axi_bresp_o  (s_axi_bresp_o),
        .s_axi_bvalid_o (s_axi_bvalid_o),
        .s_axi_bready_i (s_axi_bready_i),
        .s_axi_araddr_i (s_axi_araddr_i),
        .s_axi_arvalid_i(s_axi_arvalid_i),
        .s_axi_arready_o(s_axi_arready_o),
        .s_axi_rdata_o  (s_axi_rdata_o),
        .s_axi_rresp_o  (s_axi_rresp_o),
        .s_axi_rvalid_o (s_axi_rvalid_o),
        .s_axi_rready_i (s_axi_rready_i),
        .wr_en_o        (reg_wr),
        .wr_addr_o      (reg_waddr),
        .wr_data_o      (reg_wdata),
        .wr_strb_o      (reg_wstrb),
        .wr_ok_i        (reg_waddr <= OFF_CMP_HI),
        .rd_addr_o      (reg_raddr),
        .rd_data_i      (reg_rdata),
        .rd_ok_i        (reg_raddr <= OFF_CMP_HI)
    );

    // byte-lane merge for register writes (WSTRB per AXI, like the DP-SRAM)
    function [31:0] lane_merge;
        input [31:0] old_val;
        input [31:0] new_val;
        input [3:0] strb;
        lane_merge = {
            strb[3] ? new_val[31:24] : old_val[31:24],
            strb[2] ? new_val[23:16] : old_val[23:16],
            strb[1] ? new_val[15:8] : old_val[15:8],
            strb[0] ? new_val[7:0] : old_val[7:0]
        };
    endfunction

    wire        wr_time_lo = reg_wr && (reg_waddr == OFF_TIME_LO);
    wire        wr_time_hi = reg_wr && (reg_waddr == OFF_TIME_HI);
    wire        wr_cmp_lo = reg_wr && (reg_waddr == OFF_CMP_LO);
    wire        wr_cmp_hi = reg_wr && (reg_waddr == OFF_CMP_HI);

    // mtime: free-running; a software write to a half beats the increment on
    // that half for that cycle (the other half still increments as a pair)
    wire [63:0] mtime_inc = mtime_q + 64'd1;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mtime_q <= 64'b0;
        else begin
            mtime_q[31:0] <= wr_time_lo ? lane_merge(
                mtime_inc[31:0], reg_wdata, reg_wstrb
            ) : mtime_inc[31:0];
            mtime_q[63:32] <= wr_time_hi ? lane_merge(
                mtime_inc[63:32], reg_wdata, reg_wstrb
            ) : mtime_inc[63:32];
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) mtimecmp_q <= {64{1'b1}};  // disarmed at reset (D26)
        else if (wr_cmp_lo) mtimecmp_q[31:0] <= lane_merge(mtimecmp_q[31:0], reg_wdata, reg_wstrb);
        else if (wr_cmp_hi)
            mtimecmp_q[63:32] <= lane_merge(mtimecmp_q[63:32], reg_wdata, reg_wstrb);
    end

    // level interrupt, registered off the compare (D26)
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) irq_o <= 1'b0;
        else irq_o <= (mtime_q >= mtimecmp_q);
    end

    // read mux: combinational, the slave registers it on the AR handshake
    reg [31:0] reg_rmux;
    always @(*) begin
        case (reg_raddr)
            OFF_TIME_LO: reg_rmux = mtime_q[31:0];
            OFF_TIME_HI: reg_rmux = mtime_q[63:32];
            OFF_CMP_LO:  reg_rmux = mtimecmp_q[31:0];
            OFF_CMP_HI:  reg_rmux = mtimecmp_q[63:32];
            default:     reg_rmux = 32'b0;
        endcase
    end
    assign reg_rdata = reg_rmux;

endmodule
