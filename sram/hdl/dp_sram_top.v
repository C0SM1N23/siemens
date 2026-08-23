// =============================================================================
//
// word 0..7   -> register region (sram_regfile.v), 8 registers
// word 8..255 -> data region (dpram_array.v), with offset -8
//
// =============================================================================

module dp_sram_top #(
    parameter ADDR_W      = 10, // address width
    parameter REG_WORD_MAX = 7  // total number of registers - 1
) (
    input  wire               clk_i,
    input  wire               rst_n_i,   // reset active-low, asynchronous

    // Port A
    input  wire [ADDR_W-1:0]  a_awaddr_i,
    input  wire               a_awvalid_i,
    output wire               a_awready_o,
    input  wire [31:0]        a_wdata_i,
    input  wire [3:0]         a_wstrb_i,
    input  wire               a_wvalid_i,
    output wire               a_wready_o,
    output wire [1:0]         a_bresp_o,
    output wire               a_bvalid_o,
    input  wire               a_bready_i,
    input  wire [ADDR_W-1:0]  a_araddr_i,
    input  wire               a_arvalid_i,
    output wire               a_arready_o,
    output wire [31:0]        a_rdata_o,
    output wire [1:0]         a_rresp_o,
    output wire               a_rvalid_o,
    input  wire               a_rready_i,

    // Port B
    input  wire [ADDR_W-1:0]  b_awaddr_i,
    input  wire               b_awvalid_i,
    output wire               b_awready_o,
    input  wire [31:0]        b_wdata_i,
    input  wire [3:0]         b_wstrb_i,
    input  wire               b_wvalid_i,
    output wire               b_wready_o,
    output wire [1:0]         b_bresp_o,
    output wire               b_bvalid_o,
    input  wire               b_bready_i,
    input  wire [ADDR_W-1:0]  b_araddr_i,
    input  wire               b_arvalid_i,
    output wire               b_arready_o,
    output wire [31:0]        b_rdata_o,
    output wire [1:0]         b_rresp_o,
    output wire               b_rvalid_o,
    input  wire               b_rready_i,

    output wire                irq_o
);

    // Offset between the start of the local address space and the start
    // of the data region in the actual memory
    localparam [ADDR_W-1:0] MEM_BASE_OFFSET = (REG_WORD_MAX + 1) * 4;

    // Port A: axi4lite_slave_fsm
    wire [ADDR_W-1:0] a_mem_addr;
    wire              a_mem_write;
    wire [31:0]       a_mem_wdata;
    wire [3:0]        a_mem_wstrb;
    wire              a_mem_valid;
    wire              a_mem_error_final;
    wire [31:0]       a_mem_rdata_final;
    wire              a_stall;

    axi4lite_slave_fsm #(.ADDR_W(ADDR_W)) u_fsm_a (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .awaddr_i(a_awaddr_i), .awvalid_i(a_awvalid_i), .awready_o(a_awready_o),
        .wdata_i(a_wdata_i), .wstrb_i(a_wstrb_i), .wvalid_i(a_wvalid_i), .wready_o(a_wready_o),
        .bresp_o(a_bresp_o), .bvalid_o(a_bvalid_o), .bready_i(a_bready_i),
        .araddr_i(a_araddr_i), .arvalid_i(a_arvalid_i), .arready_o(a_arready_o),
        .rdata_o(a_rdata_o), .rresp_o(a_rresp_o), .rvalid_o(a_rvalid_o), .rready_i(a_rready_i),
        .mem_addr_o(a_mem_addr), .mem_write_o(a_mem_write),
        .mem_wdata_o(a_mem_wdata), .mem_wstrb_o(a_mem_wstrb), .mem_valid_o(a_mem_valid),
        .mem_error_i(a_mem_error_final), .mem_rdata_i(a_mem_rdata_final),
        .stall_i(a_stall)
    );

    // Port B: axi4lite_slave_fsm
    wire [ADDR_W-1:0] b_mem_addr;
    wire              b_mem_write;
    wire [31:0]       b_mem_wdata;
    wire [3:0]        b_mem_wstrb;
    wire              b_mem_valid;
    wire              b_mem_error_final;
    wire [31:0]       b_mem_rdata_final;
    wire              b_stall;

    axi4lite_slave_fsm #(.ADDR_W(ADDR_W)) u_fsm_b (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .awaddr_i(b_awaddr_i), .awvalid_i(b_awvalid_i), .awready_o(b_awready_o),
        .wdata_i(b_wdata_i), .wstrb_i(b_wstrb_i), .wvalid_i(b_wvalid_i), .wready_o(b_wready_o),
        .bresp_o(b_bresp_o), .bvalid_o(b_bvalid_o), .bready_i(b_bready_i),
        .araddr_i(b_araddr_i), .arvalid_i(b_arvalid_i), .arready_o(b_arready_o),
        .rdata_o(b_rdata_o), .rresp_o(b_rresp_o), .rvalid_o(b_rvalid_o), .rready_i(b_rready_i),
        .mem_addr_o(b_mem_addr), .mem_write_o(b_mem_write),
        .mem_wdata_o(b_mem_wdata), .mem_wstrb_o(b_mem_wstrb), .mem_valid_o(b_mem_valid),
        .mem_error_i(b_mem_error_final), .mem_rdata_i(b_mem_rdata_final),
        .stall_i(b_stall)
    );

    // register vs memory for Port A
    wire [7:0] a_word_addr = a_mem_addr[9:2];
    wire       a_is_reg    = (a_word_addr <= REG_WORD_MAX);

    wire        a_reg_valid_w = a_mem_valid & a_is_reg;   // to regfile
    wire [2:0]  a_reg_addr_w  = a_word_addr[2:0];
    wire [31:0] a_reg_rdata_w;

    wire        a_mem_valid_bk = a_mem_valid & !a_is_reg; // collision_det does not receive register addresses
    wire        a_mem_write_bk = a_mem_write & !a_is_reg;
    wire [ADDR_W-1:0] a_mem_addr_bk = a_mem_addr - MEM_BASE_OFFSET;
    wire        a_mem_error_bk;
    wire [31:0] a_mem_rdata_bk;

    assign a_mem_error_final = a_is_reg ? 1'b0          : a_mem_error_bk;
    assign a_mem_rdata_final = a_is_reg ? a_reg_rdata_w : a_mem_rdata_bk;

    // register vs memory for Port B
    wire [7:0] b_word_addr = b_mem_addr[9:2];
    wire       b_is_reg    = (b_word_addr <= REG_WORD_MAX);

    wire        b_reg_valid_w = b_mem_valid & b_is_reg;
    wire [2:0]  b_reg_addr_w  = b_word_addr[2:0];
    wire [31:0] b_reg_rdata_w;

    wire        b_mem_valid_bk = b_mem_valid & !b_is_reg;
    wire        b_mem_write_bk = b_mem_write & !b_is_reg;
    wire [ADDR_W-1:0] b_mem_addr_bk = b_mem_addr - MEM_BASE_OFFSET;
    wire        b_mem_error_bk;
    wire [31:0] b_mem_rdata_bk;

    assign b_mem_error_final = b_is_reg ? 1'b0          : b_mem_error_bk;
    assign b_mem_rdata_final = b_is_reg ? b_reg_rdata_w : b_mem_rdata_bk;

    // collision_det.v -- only sees requests from the data region
    wire        a_write_grant, b_write_grant;
    wire        force_priority_w;
    wire [7:0]  collision_threshold_w;
    wire [7:0]  cooldown_cycles_w;
    wire        collision_event_w, cooldown_event_w;

    collision_det #(.ADDR_W(ADDR_W)) u_arbiter (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .a_mem_valid_i(a_mem_valid_bk), .a_mem_addr_i(a_mem_addr_bk), .a_mem_write_i(a_mem_write_bk),
        .b_mem_valid_i(b_mem_valid_bk), .b_mem_addr_i(b_mem_addr_bk), .b_mem_write_i(b_mem_write_bk),
        .force_priority_i(force_priority_w),
        .collision_threshold_i(collision_threshold_w),
        .cooldown_cycles_i(cooldown_cycles_w),
        .a_mem_error_o(a_mem_error_bk), .b_mem_error_o(b_mem_error_bk),
        .a_stall_o(a_stall), .b_stall_o(b_stall),
        .a_write_grant_o(a_write_grant), .b_write_grant_o(b_write_grant),
        .collision_event_o(collision_event_w), .cooldown_event_o(cooldown_event_w)
    );

    // mem_array.v -- only sees requests from the data region
    mem_array #(.ADDR_W(ADDR_W)) u_dpram (
        .clk_i(clk_i),
        .a_addr_i(a_mem_addr_bk), .a_wdata_i(a_mem_wdata), .a_wstrb_i(a_mem_wstrb),
        .a_write_grant_i(a_write_grant), .a_rdata_o(a_mem_rdata_bk),
        .b_addr_i(b_mem_addr_bk), .b_wdata_i(b_mem_wdata), .b_wstrb_i(b_mem_wstrb),
        .b_write_grant_i(b_write_grant), .b_rdata_o(b_mem_rdata_bk)
    );

    // sram_regfile.v -- only sees requests from the register region
    sram_regfile #(.REG_ADDR_W(3)) u_regfile (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .a_reg_valid_i(a_reg_valid_w), .a_reg_addr_i(a_reg_addr_w),
        .a_reg_write_i(a_mem_write), .a_reg_wdata_i(a_mem_wdata), .a_reg_rdata_o(a_reg_rdata_w),
        .b_reg_valid_i(b_reg_valid_w), .b_reg_addr_i(b_reg_addr_w),
        .b_reg_write_i(b_mem_write), .b_reg_wdata_i(b_mem_wdata), .b_reg_rdata_o(b_reg_rdata_w),
        .collision_event_i(collision_event_w), .cooldown_event_i(cooldown_event_w),
        .a_mem_valid_i(a_mem_valid_bk), .b_mem_valid_i(b_mem_valid_bk),
        .force_priority_o(force_priority_w),
        .collision_threshold_o(collision_threshold_w),
        .cooldown_cycles_o(cooldown_cycles_w),
        .irq_o(irq_o)
    );

endmodule
