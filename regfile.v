// =============================================================================
//
// Banca de registre control/status a DP-SRAM: INT_STATUS, INT_ENABLE,
// FORCE_PRIORITY, BANDWIDTH_A, BANDWIDTH_B, COLLISION_THRESHOLD, COOLDOWN_CYCLES,
// Genereaza semnalul irq
// Port A castiga la scriere pe acelasi registru
// Conversie in top lvl
//
// =============================================================================

module regfile #(
    parameter REG_ADDR_W   = 3,
    parameter WINDOW_CYCLES = 1024
) (
    input  wire                    clk,
    input  wire                    rst_n,

    //Port  A
    input  wire                    a_reg_valid,  // Port A are o cerere activa?
    input  wire [REG_ADDR_W-1:0]   a_reg_addr,   // adresa de la Port A
    input  wire                     a_reg_write, // scrie/citeste
    input  wire [31:0]             a_reg_wdata,  
    output wire [31:0]             a_reg_rdata,  

    //Port B
    input  wire                    b_reg_valid,  // Port B are o cerere activa?
    input  wire [REG_ADDR_W-1:0]   b_reg_addr,   // adresa de la Port B
    input  wire                     b_reg_write, // scrie/citeste
    input  wire [31:0]             b_reg_wdata,
    output wire [31:0]             b_reg_rdata,

    //axi4lite_slave_fsm.v
    input  wire                    a_mem_valid,
    input  wire                    b_mem_valid,

    //collision_arbiter.v
    input  wire                    collision_event,  //coliziune reala
    input  wire                    cooldown_event,  //intram in cooldown
    output wire                    force_priority,         
    output wire [7:0]              collision_threshold,    
    output wire [7:0]              cooldown_cycles,        

    output wire                    irq           //catre PIC
);
    //indecsi
    localparam ADDR_INT_STATUS         = 0;
    localparam ADDR_INT_ENABLE         = 1;
    localparam ADDR_FORCE_PRIO         = 2;
    localparam ADDR_BANDWIDTH_A        = 3;
    localparam ADDR_BANDWIDTH_B        = 4;
    localparam ADDR_COLLISION_THRESHOLD = 5;
    localparam ADDR_COOLDOWN_CYCLES     = 6;


    localparam WIN_W = 10;

    
    wire a_writes = a_reg_valid & a_reg_write;
    wire b_writes = b_reg_valid & b_reg_write;
    wire write_conflict = a_writes & b_writes & (a_reg_addr == b_reg_addr);

    wire a_write_effective = a_writes;                  // Port A castiga mereu
    wire b_write_effective = b_writes & ~write_conflict; // Port B blocat la conflict

    //Registri
    reg [31:0] int_status_reg;   // INT_STATUS R/W1C
    reg [31:0] int_enable_reg;   // INT_ENABLE R/W
    reg        force_priority_reg; // FORCE_PRIORITY R/W 1b
    reg [7:0]  collision_threshold_reg; // COLLISION_THRESHOLD  R/W
    reg [7:0]  cooldown_cycles_reg;     // COOLDOWN_CYCLES  R/W
    reg [WIN_W-1:0] window_cnt;    // numara ciclurile
    reg [WIN_W-1:0] a_active_cnt;  // cicluri active Port A
    reg [WIN_W-1:0] b_active_cnt;  // cicluri active Port B
    reg [31:0] bandwidth_a_reg;    // BANDWIDTH_A RO
    reg [31:0] bandwidth_b_reg;    // BANDWIDTH_B RO

    wire window_done = (window_cnt == WINDOW_CYCLES-1);

  
    // int_status_reg (W1C)
    always @(posedge clk or negedge rst_n)
        if (~rst_n) 
            int_status_reg <= 32'd0;
        else begin
            if (collision_event)
                int_status_reg[0] <= 1'b1; // coliziune
            else if ((a_write_effective && a_reg_addr==ADDR_INT_STATUS && a_reg_wdata[0]) || (b_write_effective && b_reg_addr==ADDR_INT_STATUS && b_reg_wdata[0]))
                int_status_reg[0] <= 1'b0; // clear

            if (cooldown_event)
                int_status_reg[1] <= 1'b1; // cooldown
            else if ((a_write_effective && a_reg_addr==ADDR_INT_STATUS && a_reg_wdata[1]) || (b_write_effective && b_reg_addr==ADDR_INT_STATUS && b_reg_wdata[1]))
                int_status_reg[1] <= 1'b0; // clear
        end

   
    // int_enable_reg (R/W)
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            int_enable_reg <= 32'd0;
        else if (a_write_effective && a_reg_addr==ADDR_INT_ENABLE)
            int_enable_reg <= a_reg_wdata;
        else if (b_write_effective && b_reg_addr==ADDR_INT_ENABLE)
            int_enable_reg <= b_reg_wdata;


   
    // force_priority_reg (R/W)
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            force_priority_reg <= 1'b0;
        else if (a_write_effective && a_reg_addr==ADDR_FORCE_PRIO)
            force_priority_reg <= a_reg_wdata[0];
        else if (b_write_effective && b_reg_addr==ADDR_FORCE_PRIO)
            force_priority_reg <= b_reg_wdata[0];


  
    // collision_threshold_reg (R/W)
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            collision_threshold_reg <= 8'd4;
        else if (a_write_effective && a_reg_addr==ADDR_COLLISION_THRESHOLD)
            collision_threshold_reg <= a_reg_wdata[7:0];
        else if (b_write_effective && b_reg_addr==ADDR_COLLISION_THRESHOLD)
            collision_threshold_reg <= b_reg_wdata[7:0];


    // cooldown_cycles_reg (R/W)
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            cooldown_cycles_reg <= 8'd4;
        else if (a_write_effective && a_reg_addr==ADDR_COOLDOWN_CYCLES)
            cooldown_cycles_reg <= a_reg_wdata[7:0];
        else if (b_write_effective && b_reg_addr==ADDR_COOLDOWN_CYCLES)
            cooldown_cycles_reg <= b_reg_wdata[7:0];


    // window_cnt 
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            window_cnt <= {WIN_W{1'b0}}; 
        else if (window_done)
            window_cnt <= {WIN_W{1'b0}};
        else
            window_cnt <= window_cnt + 1'b1;


    // a_active_cnt
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            a_active_cnt <= {WIN_W{1'b0}};
        else if (window_done)
            a_active_cnt <= a_mem_valid ? {{WIN_W-1{1'b0}}, 1'b1} : {WIN_W{1'b0}}; 
        else if (a_mem_valid)
            a_active_cnt <= a_active_cnt + 1'b1;


    // b_active_cnt
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            b_active_cnt <= {WIN_W{1'b0}};
        else if (window_done)
            b_active_cnt <= b_mem_valid ? {{WIN_W-1{1'b0}}, 1'b1} : {WIN_W{1'b0}};
        else if (b_mem_valid)
            b_active_cnt <= b_active_cnt + 1'b1;


    // bandwidth_a_reg (RO)
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            bandwidth_a_reg <= 32'd0;
        else if (window_done)
            bandwidth_a_reg <= {{(32-WIN_W){1'b0}}, a_active_cnt}; // extinde la 32b pentru citire pe bus


    // bandwidth_b_reg (RO)
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            bandwidth_b_reg <= 32'd0;
        else if (window_done)
            bandwidth_b_reg <= {{(32-WIN_W){1'b0}}, b_active_cnt};


    // citiri
    assign a_reg_rdata = (a_reg_addr==ADDR_INT_STATUS)         ? int_status_reg :
                          (a_reg_addr==ADDR_INT_ENABLE)         ? int_enable_reg :
                          (a_reg_addr==ADDR_FORCE_PRIO)         ? {31'd0, force_priority_reg} :
                          (a_reg_addr==ADDR_BANDWIDTH_A)        ? bandwidth_a_reg :
                          (a_reg_addr==ADDR_BANDWIDTH_B)        ? bandwidth_b_reg :
                          (a_reg_addr==ADDR_COLLISION_THRESHOLD)? {24'd0, collision_threshold_reg} :
                          (a_reg_addr==ADDR_COOLDOWN_CYCLES)    ? {24'd0, cooldown_cycles_reg} :
                          32'd0;

    assign b_reg_rdata = (b_reg_addr==ADDR_INT_STATUS)         ? int_status_reg :
                          (b_reg_addr==ADDR_INT_ENABLE)         ? int_enable_reg :
                          (b_reg_addr==ADDR_FORCE_PRIO)         ? {31'd0, force_priority_reg} :
                          (b_reg_addr==ADDR_BANDWIDTH_A)        ? bandwidth_a_reg :
                          (b_reg_addr==ADDR_BANDWIDTH_B)        ? bandwidth_b_reg :
                          (b_reg_addr==ADDR_COLLISION_THRESHOLD)? {24'd0, collision_threshold_reg} :
                          (b_reg_addr==ADDR_COOLDOWN_CYCLES)    ? {24'd0, cooldown_cycles_reg} :
                          32'd0;

   // iesiri
    assign force_priority      = force_priority_reg;
    assign collision_threshold = collision_threshold_reg;
    assign cooldown_cycles     = cooldown_cycles_reg;
    assign irq = |(int_status_reg & int_enable_reg);

endmodule
