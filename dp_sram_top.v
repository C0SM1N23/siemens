// =============================================================================

//   cuvant 0..7   -> regiunea de registre (regfile.v), 8 registre
//   cuvant 8..255 -> regiunea de date (dpram_array.v), cu offset -8

// =============================================================================

module dp_sram_top #(
    parameter ADDR_W      = 10, // latime adresa
    parameter REG_WORD_MAX = 7  // numar total registri-1
) (
    input  wire               clk,
    input  wire               rst_n,   // reset activ pe 0, asincron

    // Port A
    input  wire [ADDR_W-1:0]  a_awaddr,
    input  wire               a_awvalid,
    output wire               a_awready,
    input  wire [31:0]        a_wdata,
    input  wire [3:0]         a_wstrb,
    input  wire               a_wvalid,
    output wire               a_wready,
    output wire [1:0]         a_bresp,
    output wire               a_bvalid,
    input  wire               a_bready,
    input  wire [ADDR_W-1:0]  a_araddr,
    input  wire               a_arvalid,
    output wire               a_arready,
    output wire [31:0]        a_rdata,
    output wire [1:0]         a_rresp,
    output wire               a_rvalid,
    input  wire               a_rready,

    // Port B
    input  wire [ADDR_W-1:0]  b_awaddr,
    input  wire               b_awvalid,
    output wire               b_awready,
    input  wire [31:0]        b_wdata,
    input  wire [3:0]         b_wstrb,
    input  wire               b_wvalid,
    output wire               b_wready,
    output wire [1:0]         b_bresp,
    output wire               b_bvalid,
    input  wire               b_bready,
    input  wire [ADDR_W-1:0]  b_araddr,
    input  wire               b_arvalid,
    output wire               b_arready,
    output wire [31:0]        b_rdata,
    output wire [1:0]         b_rresp,
    output wire               b_rvalid,
    input  wire               b_rready,

    output wire                irq
);

    // Deplasarea intre inceputul spatiului local de adrese si inceputul regiunii de date din memoria efectiva
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
        .clk(clk), 
        .rst_n(rst_n),
        .awaddr(a_awaddr), 
        .awvalid(a_awvalid), 
        .awready(a_awready),
        .wdata(a_wdata), 
        .wstrb(a_wstrb), 
        .wvalid(a_wvalid), 
        .wready(a_wready),
        .bresp(a_bresp), 
        .bvalid(a_bvalid), 
        .bready(a_bready),
        .araddr(a_araddr), 
        .arvalid(a_arvalid), 
        .arready(a_arready),
        .rdata(a_rdata), 
        .rresp(a_rresp), 
        .rvalid(a_rvalid), 
        .rready(a_rready),
        .mem_addr(a_mem_addr), 
        .mem_write(a_mem_write),
        .mem_wdata(a_mem_wdata), 
        .mem_wstrb(a_mem_wstrb), 
        .mem_valid(a_mem_valid),
        .mem_error(a_mem_error_final), 
        .mem_rdata(a_mem_rdata_final),
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
        .clk(clk), 
        .rst_n(rst_n),
        .awaddr(b_awaddr), 
        .awvalid(b_awvalid), 
        .awready(b_awready),
        .wdata(b_wdata), 
        .wstrb(b_wstrb), 
        .wvalid(b_wvalid), 
        .wready(b_wready),
        .bresp(b_bresp), 
        .bvalid(b_bvalid), 
        .bready(b_bready),
        .araddr(b_araddr), 
        .arvalid(b_arvalid), 
        .arready(b_arready),
        .rdata(b_rdata), 
        .rresp(b_rresp), 
        .rvalid(b_rvalid), 
        .rready(b_rready),
        .mem_addr(b_mem_addr), 
        .mem_write(b_mem_write),
        .mem_wdata(b_mem_wdata), 
        .mem_wstrb(b_mem_wstrb), 
        .mem_valid(b_mem_valid),
        .mem_error(b_mem_error_final), 
        .mem_rdata(b_mem_rdata_final),
        .stall_i(b_stall)
    );

    
    //registr vs memorie pt Port A
    wire [7:0] a_word_addr = a_mem_addr[9:2];
    wire       a_is_reg    = (a_word_addr <= REG_WORD_MAX);
    wire        a_reg_valid_w = a_mem_valid & a_is_reg;      // catre regfile
    wire [2:0]  a_reg_addr_w  = a_word_addr[2:0];
    wire [31:0] a_reg_rdata_w;
    wire        a_mem_valid_bk = a_mem_valid & ~a_is_reg;
    wire        a_mem_write_bk = a_mem_write & ~a_is_reg;
    wire [ADDR_W-1:0] a_mem_addr_bk = a_mem_addr - MEM_BASE_OFFSET;
    wire        a_mem_error_bk;
    wire [31:0] a_mem_rdata_bk;

    assign a_mem_error_final = a_is_reg ? 1'b0          : a_mem_error_bk;
    assign a_mem_rdata_final = a_is_reg ? a_reg_rdata_w : a_mem_rdata_bk;

    //registru vs memorie pt Port B
    wire [7:0] b_word_addr = b_mem_addr[9:2];
    wire       b_is_reg    = (b_word_addr <= REG_WORD_MAX);
    wire        b_reg_valid_w = b_mem_valid & b_is_reg;
    wire [2:0]  b_reg_addr_w  = b_word_addr[2:0];
    wire [31:0] b_reg_rdata_w;
    wire        b_mem_valid_bk = b_mem_valid & ~b_is_reg;
    wire        b_mem_write_bk = b_mem_write & ~b_is_reg;
    wire [ADDR_W-1:0] b_mem_addr_bk = b_mem_addr - MEM_BASE_OFFSET;
    wire        b_mem_error_bk;
    wire [31:0] b_mem_rdata_bk;

    assign b_mem_error_final = b_is_reg ? 1'b0          : b_mem_error_bk;
    assign b_mem_rdata_final = b_is_reg ? b_reg_rdata_w : b_mem_rdata_bk;

    //collision_det nu primeste adrese de registri
    wire        a_write_grant, b_write_grant;
    wire        force_priority_w;
    wire [7:0]  collision_threshold_w;
    wire [7:0]  cooldown_cycles_w;
    wire        collision_event_w, cooldown_event_w;

    collision_det #(.ADDR_W(ADDR_W)) u_arbiter (
        .clk(clk), 
        .rst_n(rst_n),
        .a_mem_valid(a_mem_valid_bk), 
        .a_mem_addr(a_mem_addr_bk), 
        .a_mem_write(a_mem_write_bk),
        .b_mem_valid(b_mem_valid_bk), 
        .b_mem_addr(b_mem_addr_bk),
        .b_mem_write(b_mem_write_bk),
        .force_priority(force_priority_w),
        .collision_threshold_i(collision_threshold_w),
        .cooldown_cycles_i(cooldown_cycles_w),
        .a_mem_error(a_mem_error_bk), 
        .b_mem_error(b_mem_error_bk),
        .a_stall(a_stall), 
        .b_stall(b_stall),
        .a_write_grant(a_write_grant), 
        .b_write_grant(b_write_grant),
        .collision_event(collision_event_w), .cooldown_event(cooldown_event_w)
    );

    //mem_array.v -- vede doar cererile din regiunea de date
    mem_array #(.ADDR_W(ADDR_W)) u_dpram (
        .clk(clk),
        .a_addr(a_mem_addr_bk), 
        .a_wdata(a_mem_wdata), 
        .a_wstrb(a_mem_wstrb),
        .a_write_grant(a_write_grant), 
        .a_rdata(a_mem_rdata_bk),
        .b_addr(b_mem_addr_bk), 
        .b_wdata(b_mem_wdata), 
        .b_wstrb(b_mem_wstrb),
        .b_write_grant(b_write_grant), 
        .b_rdata(b_mem_rdata_bk)
    );

   //regfile.v -- vede doar cererile din regiunea de registre
    regfile #(.REG_ADDR_W(3)) u_regfile (
        .clk(clk), 
        .rst_n(rst_n),
        .a_reg_valid(a_reg_valid_w), 
        .a_reg_addr(a_reg_addr_w),
        .a_reg_write(a_mem_write), 
        .a_reg_wdata(a_mem_wdata), 
        .a_reg_rdata(a_reg_rdata_w),
        .b_reg_valid(b_reg_valid_w), 
        .b_reg_addr(b_reg_addr_w),
        .b_reg_write(b_mem_write), 
        .b_reg_wdata(b_mem_wdata),
        .b_reg_rdata(b_reg_rdata_w),
        .collision_event(collision_event_w), 
        .cooldown_event(cooldown_event_w),
        .a_mem_valid(a_mem_valid_bk), 
        .b_mem_valid(b_mem_valid_bk), 
        .force_priority(force_priority_w),
        .collision_threshold(collision_threshold_w),
        .cooldown_cycles(cooldown_cycles_w),
        .irq(irq)
    );

endmodule
