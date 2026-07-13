// =============================================================================

// Decide ce se intampla cand avem coliziuni la cele 2 porturi
// Aplica stall cand avem prea multe coliziuni reale
// Coliziuni reale = R+W si W+W
// Colliziunile se rezolva pe loc(combinational) nu mai avem nevoie de stare

// =============================================================================

module collision_det #(
    parameter ADDR_W             = 10, // latime adresa
    parameter COLLISION_THRESHOLD = 4  // nr coliziuni
) (
    input  wire              clk,      // ceas
    input  wire              rst_n,    // reset sincron

    // Cererea Port A
    input  wire               a_mem_valid, // Port A are o cerere activa
    input  wire [ADDR_W-1:0]  a_mem_addr,  // adresa ceruta Port A
    input  wire                a_mem_write,// 1-scriere 0-citire

    // Cererea Port B
    input  wire               b_mem_valid,
    input  wire [ADDR_W-1:0]  b_mem_addr,
    input  wire                b_mem_write,

    input  wire                force_priority, // prioritate porturi 0-A 1-B
    output wire                a_mem_error, // SLVERR A
    output wire                b_mem_error, // SLVERR B
    output wire                a_stall,
    output wire                b_stall,
    output wire                a_write_grant, // Port A poate face scrierea
    output wire                b_write_grant, // Port B poate face scrierea
    output wire                collision_event, // avem coliziune
    output wire                cooldown_event   // avem cooldown
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

    assign a_write_grant = a_mem_write & ~(is_wr_wr & a_loses); // A poate scrie daca nu pierde W/W
    assign b_write_grant = b_mem_write & ~(is_wr_wr & b_loses); // B poate scrie daca nu pierde W/W

    //stari fsm
    localparam S_IDLE   = 1'b0; 
    localparam S_COOLDOWN = 1'b1; //stall activ si pe A si pe B

    localparam CNT_W      = 4; // contor coliziuni
    localparam COOLDOWN_W = 2; // latime contor cooldown

    reg                  state;
    reg                  next_state;
    reg [CNT_W-1:0]      collision_cnt;
    reg [COOLDOWN_W-1:0] cooldown_cnt;

    wire threshold_hit = (state == S_IDLE) && real_conflict && (collision_cnt == COLLISION_THRESHOLD-1); //ajungem la N
    wire cooldown_done = (cooldown_cnt == 2'd3);

    assign collision_event = real_conflict;  // semnal ca a acvut loc coliziune (pentru reg)
    assign cooldown_event  = threshold_hit;  // semnal ca a acvut loc cooldown (pentru reg)
    assign a_stall = (state == S_COOLDOWN);
    assign b_stall = (state == S_COOLDOWN);

    //logica de tranzitie
    always @(*)
        case (state)

            S_IDLE: next_state = threshold_hit ? S_COOLDOWN : S_IDLE;

            S_COOLDOWN: next_state = cooldown_done ? S_IDLE   : S_COOLDOWN;
            
            default: next_state = S_IDLE;

        endcase

    //trecem la starea urmatoare
    always @(posedge clk) begin
        if (~rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    //numaram coliziunile
    always @(posedge clk)
        if (~rst_n)
            collision_cnt <= {CNT_W{1'b0}};
        else if (state == S_IDLE && real_conflict) begin
            if (threshold_hit)
                collision_cnt <= {CNT_W{1'b0}};
            else
                collision_cnt <= collision_cnt + 1'b1;
        end

        else 
            collision_cnt <= collision_cnt;
    

    //numaram cooldownul
    always @(posedge clk)
        if (~rst_n)
            cooldown_cnt <= {COOLDOWN_W{1'b0}};
        else if (state == S_COOLDOWN)
            cooldown_cnt <= cooldown_done ? {COOLDOWN_W{1'b0}} : cooldown_cnt + 1'b1;
        else
            cooldown_cnt <= {COOLDOWN_W{1'b0}};


endmodule
