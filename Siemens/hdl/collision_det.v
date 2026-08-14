// =============================================================================

// Decide ce se intampla cand avem coliziuni pe cele 2 porturi
// Aplica stall cand avem prea multe coliziuni
// Coliziuni reale = R+W si W+W
// Coliziunile se rezolva pe loc(combinational) nu mai avem nevoie de stare
//am adaugat semnale pentru cooldown si collision event pentru a putea fi folosite in regfile

// =============================================================================

module collision_det #(
    parameter ADDR_W = 10 // latime adresa
) (
    // Ceas si reset
    input  wire              clk,
    input  wire              rst_n,

    // Cererea Port A
    input  wire               a_mem_valid, // Port A are cerere activa
    input  wire [ADDR_W-1:0]  a_mem_addr,  // adresa ceruta
    input  wire                a_mem_write,// scrie sau citeste

    // Cererea Port B
    input  wire               b_mem_valid, // Port B are cerere activa
    input  wire [ADDR_W-1:0]  b_mem_addr,  // adresa ceruta
    input  wire                b_mem_write,// scrie sau citeste

    // Din regfile
    input  wire                force_priority, // 0 = Port A si 1 = Port B castiga
    input  wire [7:0]         collision_threshold_i, // prag pana intra in stall
    input  wire [7:0]         cooldown_cycles_i, // cat sta in stall
    output wire                collision_event, // a fost coliziune
    output wire                cooldown_event,   // am intrat in cooldown

    // Catre axi4lite_slave_fsm.v
    output wire                a_mem_error, // 1 = SLVERR Port A
    output wire                b_mem_error, // 1 = SLVERR Port B
    output wire                a_stall,
    output wire                b_stall,

    // Catre dpram_array.v
    output wire                a_write_grant, // A primeste scrierea
    output wire                b_write_grant // B primeste scrierea
    
);

   //clasificare coliziuni
    wire addr_match = a_mem_valid & b_mem_valid & (a_mem_addr == b_mem_addr);
    wire is_rd_rd   = addr_match & ~a_mem_write & ~b_mem_write;
    wire is_rd_wr   = addr_match & (a_mem_write ^ b_mem_write);
    wire is_wr_wr   = addr_match & a_mem_write & b_mem_write;

    wire real_conflict = is_rd_wr | is_wr_wr;

    wire a_loses = (is_rd_wr & ~a_mem_write) | (is_wr_wr & force_priority);
    wire b_loses = (is_rd_wr & ~b_mem_write) | (is_wr_wr & ~force_priority);

    assign a_mem_error = a_loses; // Port A primeste SLVERR
    assign b_mem_error = b_loses; // Port B primeste SLVERR

    assign a_write_grant = a_mem_write & ~(is_wr_wr & a_loses);
    assign b_write_grant = b_mem_write & ~(is_wr_wr & b_loses);

    //stari fsm
    localparam S_ACTIVE   = 1'b0; 
    localparam S_COOLDOWN = 1'b1; // stall activ pe A si pe B

    reg       arb_state;      
    reg       next_arb_state;
    reg [7:0] collision_cnt;
    reg [7:0] cooldown_cnt;

    wire threshold_hit = (arb_state == S_ACTIVE) && real_conflict && (collision_cnt + 8'd1 == collision_threshold_i);
    wire cooldown_done = (cooldown_cnt + 8'd1 == cooldown_cycles_i);

    assign collision_event = real_conflict;
    assign cooldown_event  = threshold_hit;
    assign a_stall = (arb_state == S_COOLDOWN);
    assign b_stall = (arb_state == S_COOLDOWN);

//logica de tranzitie
    always @(*)
        case (arb_state)
            S_ACTIVE:   next_arb_state = threshold_hit ? S_COOLDOWN : S_ACTIVE;
            S_COOLDOWN: next_arb_state = cooldown_done ? S_ACTIVE   : S_COOLDOWN;
            default:    next_arb_state = S_ACTIVE;
        endcase

    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            arb_state <= S_ACTIVE;
        else
            arb_state <= next_arb_state;

 //numaram coliziunile
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            collision_cnt <= 8'd0;
        else if (arb_state == S_ACTIVE && real_conflict) begin
            if (threshold_hit)
                collision_cnt <= 8'd0;
            else
                collision_cnt <= collision_cnt + 8'd1;
        end
        else
            collision_cnt <= collision_cnt;

//numarator cooldown
    always @(posedge clk or negedge rst_n) 
        if (~rst_n)
            cooldown_cnt <= 8'd0;
        else if (arb_state == S_COOLDOWN)
            cooldown_cnt <= cooldown_done ? 8'd0 : cooldown_cnt + 8'd1;
        else
            cooldown_cnt <= 8'd0;

endmodule