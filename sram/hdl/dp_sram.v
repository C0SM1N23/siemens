// =============================================================================
//
// word 0..7   -> register region (dp_sram_regfile.v), 8 registers
// word 8..255 -> data region (dp_sram_mem_array.v), rebased by -8 words (0x20 bytes)
//
// =============================================================================

module dp_sram #(
    parameter ADDR_W      = 10, // address width
    parameter REG_WORD_MAX = 7, // total number of registers - 1
    parameter WINDOW_CYCLES = 1024 // BANDWIDTH_A/B measurement window, in clock cycles (>= 2; counter widths are derived from it in dp_sram_regfile.v)
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

    // Port A: dp_sram_axi4lite_slave_fsm
    wire [ADDR_W-1:0] a_mem_addr;
    wire              a_mem_write;
    wire [31:0]       a_mem_wdata;
    wire [3:0]        a_mem_wstrb;
    wire              a_mem_valid;
    wire              a_mem_error;
    wire [31:0]       a_mem_rdata;
    wire              a_stall;

    dp_sram_axi4lite_slave_fsm #(.ADDR_W(ADDR_W)) fsm_a_inst (
        .clk_i       (clk_i),
        .rst_n_i     (rst_n_i),
        .awaddr_i    (a_awaddr_i),
        .awvalid_i   (a_awvalid_i),
        .awready_o   (a_awready_o),
        .wdata_i     (a_wdata_i),
        .wstrb_i     (a_wstrb_i),
        .wvalid_i    (a_wvalid_i),
        .wready_o    (a_wready_o),
        .bresp_o     (a_bresp_o),
        .bvalid_o    (a_bvalid_o),
        .bready_i    (a_bready_i),
        .araddr_i    (a_araddr_i),
        .arvalid_i   (a_arvalid_i),
        .arready_o   (a_arready_o),
        .rdata_o     (a_rdata_o),
        .rresp_o     (a_rresp_o),
        .rvalid_o    (a_rvalid_o),
        .rready_i    (a_rready_i),
        .mem_addr_o  (a_mem_addr),
        .mem_write_o (a_mem_write),
        .mem_wdata_o (a_mem_wdata),
        .mem_wstrb_o (a_mem_wstrb),
        .mem_valid_o (a_mem_valid),
        .mem_error_i (a_mem_error),
        .mem_rdata_i (a_mem_rdata),
        .stall_i     (a_stall)
    );

    // Port B: dp_sram_axi4lite_slave_fsm
    wire [ADDR_W-1:0] b_mem_addr;
    wire              b_mem_write;
    wire [31:0]       b_mem_wdata;
    wire [3:0]        b_mem_wstrb;
    wire              b_mem_valid;
    wire              b_mem_error;
    wire [31:0]       b_mem_rdata;
    wire              b_stall;

    dp_sram_axi4lite_slave_fsm #(.ADDR_W(ADDR_W)) fsm_b_inst (
        .clk_i       (clk_i),
        .rst_n_i     (rst_n_i),
        .awaddr_i    (b_awaddr_i),
        .awvalid_i   (b_awvalid_i),
        .awready_o   (b_awready_o),
        .wdata_i     (b_wdata_i),
        .wstrb_i     (b_wstrb_i),
        .wvalid_i    (b_wvalid_i),
        .wready_o    (b_wready_o),
        .bresp_o     (b_bresp_o),
        .bvalid_o    (b_bvalid_o),
        .bready_i    (b_bready_i),
        .araddr_i    (b_araddr_i),
        .arvalid_i   (b_arvalid_i),
        .arready_o   (b_arready_o),
        .rdata_o     (b_rdata_o),
        .rresp_o     (b_rresp_o),
        .rvalid_o    (b_rvalid_o),
        .rready_i    (b_rready_i),
        .mem_addr_o  (b_mem_addr),
        .mem_write_o (b_mem_write),
        .mem_wdata_o (b_mem_wdata),
        .mem_wstrb_o (b_mem_wstrb),
        .mem_valid_o (b_mem_valid),
        .mem_error_i (b_mem_error),
        .mem_rdata_i (b_mem_rdata),
        .stall_i     (b_stall)
    );

    // Address decode Port A: word 0..REG_WORD_MAX -> register file, the rest -> memory array
    wire [7:0] a_word_addr = a_mem_addr[9:2];
    wire       a_is_reg    = (a_word_addr <= REG_WORD_MAX);

    // Request/response towards dp_sram_regfile
    wire        a_reg_valid = a_mem_valid & a_is_reg;
    wire [2:0]  a_reg_addr  = a_word_addr[2:0];
    wire [31:0] a_reg_rdata;
    wire        a_reg_error;

    // Request/response towards dp_sram_collision_det + dp_sram_mem_array;
    // the address is rebased to the data region (register addresses never get here)
    wire        a_ram_valid = a_mem_valid & !a_is_reg;
    wire        a_ram_write = a_mem_write & !a_is_reg;
    wire [ADDR_W-1:0] a_ram_addr = a_mem_addr - MEM_BASE_OFFSET;
    wire        a_ram_error;
    wire [31:0] a_ram_rdata;

    // Response given back to the FSM, selected by the same decode bit
    assign a_mem_error = a_is_reg ? a_reg_error : a_ram_error;
    assign a_mem_rdata = a_is_reg ? a_reg_rdata : a_ram_rdata;

    // Address decode Port B: word 0..REG_WORD_MAX -> register file, the rest -> memory array
    wire [7:0] b_word_addr = b_mem_addr[9:2];
    wire       b_is_reg    = (b_word_addr <= REG_WORD_MAX);

    // Request/response towards dp_sram_regfile
    wire        b_reg_valid = b_mem_valid & b_is_reg;
    wire [2:0]  b_reg_addr  = b_word_addr[2:0];
    wire [31:0] b_reg_rdata;
    wire        b_reg_error;

    // Request/response towards dp_sram_collision_det + dp_sram_mem_array;
    // the address is rebased to the data region (register addresses never get here)
    wire        b_ram_valid = b_mem_valid & !b_is_reg;
    wire        b_ram_write = b_mem_write & !b_is_reg;
    wire [ADDR_W-1:0] b_ram_addr = b_mem_addr - MEM_BASE_OFFSET;
    wire        b_ram_error;
    wire [31:0] b_ram_rdata;

    // Response given back to the FSM, selected by the same decode bit
    assign b_mem_error = b_is_reg ? b_reg_error : b_ram_error;
    assign b_mem_rdata = b_is_reg ? b_reg_rdata : b_ram_rdata;

    // dp_sram_collision_det.v -- only sees requests from the data region
    wire        a_write_grant, b_write_grant;
    wire        force_priority;
    wire [7:0]  collision_threshold;
    wire [7:0]  cooldown_cycles;
    wire        collision_event, cooldown_event;

    dp_sram_collision_det #(.ADDR_W(ADDR_W)) collision_det_inst (
        .clk_i                 (clk_i),
        .rst_n_i               (rst_n_i),
        .a_mem_valid_i         (a_ram_valid),
        .a_mem_addr_i          (a_ram_addr),
        .a_mem_write_i         (a_ram_write),
        .b_mem_valid_i         (b_ram_valid),
        .b_mem_addr_i          (b_ram_addr),
        .b_mem_write_i         (b_ram_write),
        .force_priority_i      (force_priority),
        .collision_threshold_i (collision_threshold),
        .cooldown_cycles_i     (cooldown_cycles),
        .a_mem_error_o         (a_ram_error),
        .b_mem_error_o         (b_ram_error),
        .a_stall_o             (a_stall),
        .b_stall_o             (b_stall),
        .a_write_grant_o       (a_write_grant),
        .b_write_grant_o       (b_write_grant),
        .collision_event_o     (collision_event),
        .cooldown_event_o      (cooldown_event)
    );

    // dp_sram_mem_array.v -- only sees requests from the data region
    dp_sram_mem_array #(.ADDR_W(ADDR_W)) mem_array_inst (
        .clk_i           (clk_i),
        .a_addr_i        (a_ram_addr),
        .a_wdata_i       (a_mem_wdata),
        .a_wstrb_i       (a_mem_wstrb),
        .a_write_grant_i (a_write_grant),
        .a_rdata_o       (a_ram_rdata),
        .b_addr_i        (b_ram_addr),
        .b_wdata_i       (b_mem_wdata),
        .b_wstrb_i       (b_mem_wstrb),
        .b_write_grant_i (b_write_grant),
        .b_rdata_o       (b_ram_rdata)
    );

    // dp_sram_regfile.v -- only sees requests from the register region
    dp_sram_regfile #(.REG_ADDR_W(3), .WINDOW_CYCLES(WINDOW_CYCLES)) regfile_inst (
        .clk_i                 (clk_i),
        .rst_n_i               (rst_n_i),
        .a_reg_valid_i         (a_reg_valid),
        .a_reg_addr_i          (a_reg_addr),
        .a_reg_write_i         (a_mem_write),
        .a_reg_wdata_i         (a_mem_wdata),
        .a_reg_wstrb_i         (a_mem_wstrb),
        .a_reg_rdata_o         (a_reg_rdata),
        .a_reg_error_o         (a_reg_error),
        .b_reg_valid_i         (b_reg_valid),
        .b_reg_addr_i          (b_reg_addr),
        .b_reg_write_i         (b_mem_write),
        .b_reg_wdata_i         (b_mem_wdata),
        .b_reg_wstrb_i         (b_mem_wstrb),
        .b_reg_rdata_o         (b_reg_rdata),
        .b_reg_error_o         (b_reg_error),
        .collision_event_i     (collision_event),
        .cooldown_event_i      (cooldown_event),
        .a_mem_valid_i         (a_ram_valid),
        .b_mem_valid_i         (b_ram_valid),
        .force_priority_o      (force_priority),
        .collision_threshold_o (collision_threshold),
        .cooldown_cycles_o     (cooldown_cycles),
        .irq_o                 (irq_o)
    );

endmodule
