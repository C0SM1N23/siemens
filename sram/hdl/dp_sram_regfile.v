// =============================================================================
//
// DP-SRAM control/status register bank: INT_STATUS, INT_ENABLE,
// FORCE_PRIORITY, BANDWIDTH_A, BANDWIDTH_B, COLLISION_THRESHOLD, COOLDOWN_CYCLES,
// Generates the irq signal
// Port A wins on simultaneous write to the same register
// Address conversion is done at top level
//
// =============================================================================

module dp_sram_regfile #(
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
    input  wire [3:0]              a_reg_wstrb_i,  // byte lane enable from Port A
    output wire [31:0]             a_reg_rdata_o,  
    output wire                    a_reg_error_o,  // 1 = SLVERR for Port A's current write (always 0 -- A never loses)

    //Port B
    input  wire                    b_reg_valid_i,  // does Port B have an active request?
    input  wire [REG_ADDR_W-1:0]   b_reg_addr_i,   // address from Port B
    input  wire                     b_reg_write_i, // write/read
    input  wire [31:0]             b_reg_wdata_i,
    input  wire [3:0]              b_reg_wstrb_i,  // byte lane enable from Port B
    output wire [31:0]             b_reg_rdata_o,
    output wire                    b_reg_error_o,  // 1 = SLVERR for Port B's current write (blocked by write_conflict)

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

    // edge detector: a_write_effective/b_write_effective can stay high for
    // several cycles if BREADY is delayed (still in WR_RESP) -- without this,
    // a slow master could re-apply the same write every cycle, which is
    // wrong for W1C (INT_STATUS) even if harmless for plain R/W registers
    reg a_write_effective_prev;
    reg b_write_effective_prev;

    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i) a_write_effective_prev <= 1'b0;
        else          a_write_effective_prev <= a_write_effective;

    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i) b_write_effective_prev <= 1'b0;
        else          b_write_effective_prev <= b_write_effective;

    wire a_write_pulse = a_write_effective & ~a_write_effective_prev; // 1 cycle only, on the rising edge
    wire b_write_pulse = b_write_effective & ~b_write_effective_prev;

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
    // NOTE: the cycle where window_cnt reaches WINDOW_CYCLES-1 always resets
    // a_active_cnt/b_active_cnt for the NEW window instead of incrementing
    // the OLD one -- so only WINDOW_CYCLES-1 (not WINDOW_CYCLES) of the
    // window's cycles ever get counted. Max BANDWIDTH_A/B is WINDOW_CYCLES-1,
    // even under 100% continuous activity. Documented, not fixed (by request).

  
    // int_status_reg (W1C)
    always @(posedge clk_i or negedge rst_n_i)
        if (~rst_n_i) 
            int_status_reg <= 32'd0;
        else begin
            if (collision_event_i)
                int_status_reg[0] <= 1'b1; // collision
            else if ((a_write_pulse && a_reg_addr_i==ADDR_INT_STATUS && a_reg_wstrb_i[0] && a_reg_wdata_i[0]) || (b_write_pulse && b_reg_addr_i==ADDR_INT_STATUS && b_reg_wstrb_i[0] && b_reg_wdata_i[0]))
                int_status_reg[0] <= 1'b0; // clear

            if (cooldown_event_i)
                int_status_reg[1] <= 1'b1; // cooldown
            else if ((a_write_pulse && a_reg_addr_i==ADDR_INT_STATUS && a_reg_wstrb_i[0] && a_reg_wdata_i[1]) || (b_write_pulse && b_reg_addr_i==ADDR_INT_STATUS && b_reg_wstrb_i[0] && b_reg_wdata_i[1]))
                int_status_reg[1] <= 1'b0; // clear
        end

   
    // registers that are modified only through bus writes
    // (int_enable, force_priority, collision_threshold, cooldown_cycles)
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            int_enable_reg          <= 32'd0;
            force_priority_reg      <= 1'b0;
            collision_threshold_reg <= 8'd4;
            cooldown_cycles_reg     <= 8'd4;
        end
        else begin
            // write Port A
            if (a_write_pulse) begin
                case (a_reg_addr_i)
                    ADDR_INT_ENABLE: begin
                        if (a_reg_wstrb_i[0]) int_enable_reg[7:0]   <= a_reg_wdata_i[7:0];
                        if (a_reg_wstrb_i[1]) int_enable_reg[15:8]  <= a_reg_wdata_i[15:8];
                        if (a_reg_wstrb_i[2]) int_enable_reg[23:16] <= a_reg_wdata_i[23:16];
                        if (a_reg_wstrb_i[3]) int_enable_reg[31:24] <= a_reg_wdata_i[31:24];
                    end
                    ADDR_FORCE_PRIO:
                        if (a_reg_wstrb_i[0]) force_priority_reg <= a_reg_wdata_i[0];
                    ADDR_COLLISION_THRESHOLD:
                        if (a_reg_wstrb_i[0]) collision_threshold_reg <= a_reg_wdata_i[7:0];
                    ADDR_COOLDOWN_CYCLES:
                        if (a_reg_wstrb_i[0]) cooldown_cycles_reg <= a_reg_wdata_i[7:0];
                    default:
                        ; // no action
                endcase
            end
            // write Port B
            if (b_write_pulse) begin
                case (b_reg_addr_i)
                    ADDR_INT_ENABLE: begin
                        if (b_reg_wstrb_i[0]) int_enable_reg[7:0]   <= b_reg_wdata_i[7:0];
                        if (b_reg_wstrb_i[1]) int_enable_reg[15:8]  <= b_reg_wdata_i[15:8];
                        if (b_reg_wstrb_i[2]) int_enable_reg[23:16] <= b_reg_wdata_i[23:16];
                        if (b_reg_wstrb_i[3]) int_enable_reg[31:24] <= b_reg_wdata_i[31:24];
                    end
                    ADDR_FORCE_PRIO:
                        if (b_reg_wstrb_i[0]) force_priority_reg <= b_reg_wdata_i[0];
                    ADDR_COLLISION_THRESHOLD:
                        if (b_reg_wstrb_i[0]) collision_threshold_reg <= b_reg_wdata_i[7:0];
                    ADDR_COOLDOWN_CYCLES:
                        if (b_reg_wstrb_i[0]) cooldown_cycles_reg <= b_reg_wdata_i[7:0];
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
    assign a_reg_error_o = 1'b0;          // A always wins, never blocked
    assign b_reg_error_o = write_conflict; // B loses exactly when write_conflict is true

endmodule
