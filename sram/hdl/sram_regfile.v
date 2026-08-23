// =============================================================================
//
// DP-SRAM control/status register bank: INT_STATUS, INT_ENABLE,
// FORCE_PRIORITY, BANDWIDTH_A, BANDWIDTH_B, COLLISION_THRESHOLD, COOLDOWN_CYCLES,
// Generates the irq signal
// Port A wins on simultaneous write to the same register
// Address conversion is done at top level
//
// Named sram_regfile, not regfile: the CPU block has a module called regfile
// (its 32 GPRs) and in the SoC both compile into the same library.
//
// =============================================================================

module sram_regfile #(
    parameter REG_ADDR_W   = 3,
    parameter WINDOW_CYCLES = 1024
) (
    input  wire                    clk_i,
    input  wire                    rst_n_i,

    //Port  A
    input  wire                    a_reg_valid_i,  // does Port A have an active request?
    input  wire [REG_ADDR_W-1:0]   a_reg_addr_i,   // address from Port A
    input  wire                     a_reg_write_i, // write/read
    input  wire [31:0]             a_reg_wdata_i,  
    output wire [31:0]             a_reg_rdata_o,  

    //Port B
    input  wire                    b_reg_valid_i,  // does Port B have an active request?
    input  wire [REG_ADDR_W-1:0]   b_reg_addr_i,   // address from Port B
    input  wire                     b_reg_write_i, // write/read
    input  wire [31:0]             b_reg_wdata_i,
    output wire [31:0]             b_reg_rdata_o,

    //axi4lite_slave_fsm.v
    input  wire                    a_mem_valid_i,
    input  wire                    b_mem_valid_i,

    //collision_arbiter.v
    input  wire                    collision_event_i,  //real collision
    input  wire                    cooldown_event_i,  //entering cooldown
    output wire                    force_priority_o,         
    output wire [7:0]              collision_threshold_o,    
    output wire [7:0]              cooldown_cycles_o,        

    output wire                    irq_o           //to PIC
);
    //indices
    localparam ADDR_INT_STATUS         = 0;
    localparam ADDR_INT_ENABLE         = 1;
    localparam ADDR_FORCE_PRIO         = 2;
    localparam ADDR_BANDWIDTH_A        = 3;
    localparam ADDR_BANDWIDTH_B        = 4;
    localparam ADDR_COLLISION_THRESHOLD = 5;
    localparam ADDR_COOLDOWN_CYCLES     = 6;


    localparam WIN_W = 10;

    
    wire a_writes = a_reg_valid_i & a_reg_write_i;
    wire b_writes = b_reg_valid_i & b_reg_write_i;
    wire write_conflict = a_writes & b_writes & (a_reg_addr_i == b_reg_addr_i);

    wire a_write_effective = a_writes;                  // Port A always wins
    wire b_write_effective = b_writes & ~write_conflict; // Port B blocked on conflict

    //Registers
    reg [31:0] int_status_reg;   // INT_STATUS R/W1C
    reg [31:0] int_enable_reg;   // INT_ENABLE R/W
    reg        force_priority_reg; // FORCE_PRIORITY R/W 1b
    reg [7:0]  collision_threshold_reg; // COLLISION_THRESHOLD  R/W
    reg [7:0]  cooldown_cycles_reg;     // COOLDOWN_CYCLES  R/W
    reg [WIN_W-1:0] window_cnt;    // counts the cycles
    reg [WIN_W-1:0] a_active_cnt;  // Port A active cycles
    reg [WIN_W-1:0] b_active_cnt;  // Port B active cycles
    reg [31:0] bandwidth_a_reg;    // BANDWIDTH_A RO
    reg [31:0] bandwidth_b_reg;    // BANDWIDTH_B RO

    wire window_done = (window_cnt == WINDOW_CYCLES-1);

  
    // int_status_reg (W1C)
    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i) 
            int_status_reg <= 32'd0;
        else begin
            if (collision_event_i)
                int_status_reg[0] <= 1'b1; // collision
            else if ((a_write_effective && a_reg_addr_i==ADDR_INT_STATUS && a_reg_wdata_i[0]) || (b_write_effective && b_reg_addr_i==ADDR_INT_STATUS && b_reg_wdata_i[0]))
                int_status_reg[0] <= 1'b0; // clear

            if (cooldown_event_i)
                int_status_reg[1] <= 1'b1; // cooldown
            else if ((a_write_effective && a_reg_addr_i==ADDR_INT_STATUS && a_reg_wdata_i[1]) || (b_write_effective && b_reg_addr_i==ADDR_INT_STATUS && b_reg_wdata_i[1]))
                int_status_reg[1] <= 1'b0; // clear
        end

   

    // registers that are modified only through bus writes.
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin

            int_enable_reg          <= 32'd0;
            force_priority_reg      <= 1'b0;
            collision_threshold_reg <= 8'd4;
            cooldown_cycles_reg     <= 8'd4;

        end
        else begin

            //write Port A
            if (a_write_effective) begin

                case (a_reg_addr_i)

                    ADDR_INT_ENABLE: int_enable_reg <= a_reg_wdata_i;

                    ADDR_FORCE_PRIO: force_priority_reg <= a_reg_wdata_i[0];

                    ADDR_COLLISION_THRESHOLD: collision_threshold_reg <= a_reg_wdata_i[7:0];

                    ADDR_COOLDOWN_CYCLES: cooldown_cycles_reg <= a_reg_wdata_i[7:0];
                    
                    default:
                        ; // no action

                endcase
            end

            //write Port B
            if (b_write_effective) begin

                case (b_reg_addr_i)

                    ADDR_INT_ENABLE: int_enable_reg <= b_reg_wdata_i;

                    ADDR_FORCE_PRIO: force_priority_reg <= b_reg_wdata_i[0];

                    ADDR_COLLISION_THRESHOLD: collision_threshold_reg <= b_reg_wdata_i[7:0];

                    ADDR_COOLDOWN_CYCLES: cooldown_cycles_reg <= b_reg_wdata_i[7:0];

                    default:
                        ; // no action

                endcase
            end
        end
    end


    // window_cnt 
    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i)
            window_cnt <= {WIN_W{1'b0}}; 
        else if (window_done)
            window_cnt <= {WIN_W{1'b0}};
        else
            window_cnt <= window_cnt + 1'b1;


    // a_active_cnt
    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i)
            a_active_cnt <= {WIN_W{1'b0}};
        else if (window_done)
            a_active_cnt <= a_mem_valid_i ? {{WIN_W-1{1'b0}}, 1'b1} : {WIN_W{1'b0}}; 
        else if (a_mem_valid_i)
            a_active_cnt <= a_active_cnt + 1'b1;


    // b_active_cnt
    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i)
            b_active_cnt <= {WIN_W{1'b0}};
        else if (window_done)
            b_active_cnt <= b_mem_valid_i ? {{WIN_W-1{1'b0}}, 1'b1} : {WIN_W{1'b0}};
        else if (b_mem_valid_i)
            b_active_cnt <= b_active_cnt + 1'b1;


    // bandwidth_a_reg (RO)
    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i)
            bandwidth_a_reg <= 32'd0;
        else if (window_done)
            bandwidth_a_reg <= {{(32-WIN_W){1'b0}}, a_active_cnt}; // extend to 32 bits for bus read


    // bandwidth_b_reg (RO)
    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i)
            bandwidth_b_reg <= 32'd0;
        else if (window_done)
            bandwidth_b_reg <= {{(32-WIN_W){1'b0}}, b_active_cnt};


    // reads
    assign a_reg_rdata_o = (a_reg_addr_i==ADDR_INT_STATUS)         ? int_status_reg :
                          (a_reg_addr_i==ADDR_INT_ENABLE)         ? int_enable_reg :
                          (a_reg_addr_i==ADDR_FORCE_PRIO)         ? {31'd0, force_priority_reg} :
                          (a_reg_addr_i==ADDR_BANDWIDTH_A)        ? bandwidth_a_reg :
                          (a_reg_addr_i==ADDR_BANDWIDTH_B)        ? bandwidth_b_reg :
                          (a_reg_addr_i==ADDR_COLLISION_THRESHOLD)? {24'd0, collision_threshold_reg} :
                          (a_reg_addr_i==ADDR_COOLDOWN_CYCLES)    ? {24'd0, cooldown_cycles_reg} :
                          32'd0;

    assign b_reg_rdata_o = (b_reg_addr_i==ADDR_INT_STATUS)         ? int_status_reg :
                          (b_reg_addr_i==ADDR_INT_ENABLE)         ? int_enable_reg :
                          (b_reg_addr_i==ADDR_FORCE_PRIO)         ? {31'd0, force_priority_reg} :
                          (b_reg_addr_i==ADDR_BANDWIDTH_A)        ? bandwidth_a_reg :
                          (b_reg_addr_i==ADDR_BANDWIDTH_B)        ? bandwidth_b_reg :
                          (b_reg_addr_i==ADDR_COLLISION_THRESHOLD)? {24'd0, collision_threshold_reg} :
                          (b_reg_addr_i==ADDR_COOLDOWN_CYCLES)    ? {24'd0, cooldown_cycles_reg} :
                          32'd0;

   // outputs
    assign force_priority_o      = force_priority_reg;
    assign collision_threshold_o = collision_threshold_reg;
    assign cooldown_cycles_o     = cooldown_cycles_reg;
    assign irq_o = |(int_status_reg & int_enable_reg);

endmodule
