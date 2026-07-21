// =============================================================================

// FSM AXI4-Lite slave, trebuie instantiat de 2 ori pentru cele 2 porturi top lvl
// Cate o tranzactie odata
// Semnalul de stall vine din modulul de arbitrare coliziuni si blocheaza tranzactiile (tine semnalele ready si valid la 0)
// Prioritate citire fata de scriere

// =============================================================================

module axi4lite_slave_fsm #(
    parameter ADDR_W = 10   // latime adresa
) (

    input  wire              clk,      // ceas
    input  wire              rst_n,    // reset sincron

    //Write Address
    input  wire [ADDR_W-1:0] awaddr,   // adresa de scriere
    input  wire               awvalid, // adresa data e valid
    output wire               awready, // poate accepta adresa

    //Write Data
    input  wire [31:0]        wdata,   // datele de scris
    input  wire [3:0]         wstrb,   // care byte
    input  wire                wvalid, // datele de scriere primite sunt valide
    output wire                wready, // pot accepta date

    //Write Response
    output wire [1:0]         bresp,   // OKAY/ SLVERR
    output wire                bvalid, // bresp e valid
    input  wire                bready, // raspunsul poate fi preluat

    //Read Address
    input  wire [ADDR_W-1:0]  araddr,  // adresa de citire
    input  wire                arvalid,// araddr e valid
    output wire                arready,// pot accepta araddr

    //Read Data
    output wire [31:0]        rdata,   // datele citite
    output wire [1:0]         rresp,   // OKAY/ SLVERR
    output wire                rvalid, // rdata/rresp sunt valide
    input  wire                rready, // master e gata sa preia datele

    //Backend (arbitru coliziuni si mem)
    output wire [ADDR_W-1:0]  mem_addr,  // adresa cererii pt backend
    output wire                mem_write, // 1-scriere 0-citire
    output wire [31:0]        mem_wdata, // date de scris pt backend
    output wire [3:0]         mem_wstrb, // care byte
    output wire                mem_valid, // 1-exista o cerere activa
    input  wire                mem_error, // 1-SLVERR 0-OKAY
    input  wire [31:0]        mem_rdata,  // date citite
    input  wire                stall_i    // semnalul de stall
);

    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;

    //stari fsm
    localparam [1:0] S_IDLE    = 2'd0;
    localparam [1:0] S_WR_RESP = 2'd1;
    localparam [1:0] S_RD_RESP = 2'd2;

    reg [1:0] state;     
    reg [1:0] next_state; 

    reg [ADDR_W-1:0] awaddr_reg; // registru adresa de scris
    reg [31:0]       wdata_reg;  // registru date de scris
    reg [3:0]        wstrb_reg;  // registru care byte
    reg [ADDR_W-1:0] araddr_reg; // registru adresa de citit
    reg aw_have;
    reg w_have;

    wire aw_done = aw_have || awready; // adresa disponibila
    wire w_done  = w_have  || wready;  // datele disponibile
    
    //logica de tranzitie
    always @(*)
        case (state)

            S_IDLE:
                if (stall_i)
                    next_state = S_IDLE;            
                else if (arvalid && ~aw_have && ~w_have)
                    next_state = S_RD_RESP;          // citire ceruta
                else if (aw_done && w_done)
                    next_state = S_WR_RESP;          // scriere ceruta
                else
                    next_state = S_IDLE;             

            S_WR_RESP: next_state = bready ? S_IDLE : S_WR_RESP;

            S_RD_RESP: next_state = rready ? S_IDLE : S_RD_RESP;
           
            default: next_state = S_IDLE;

        endcase


    //trecem la starea urmatoare
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            state <= S_IDLE;
        else
            state <= next_state;

    //adaugam valori in awaddr_reg
    always @(posedge clk or negedge rst_n)
        if (~rst_n )
            awaddr_reg <= {ADDR_W{1'b0}};
        else if (awready)
            awaddr_reg <= awaddr;

    //adaugam valori in wdata_reg
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            wdata_reg <= 32'd0;
        else if (wready)
            wdata_reg <= wdata;

    //adaugam valori in wstrb_reg
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            wstrb_reg <= 4'd0; 
        else if (wready)
            wstrb_reg <= wstrb;

    //adaugam valori in araddr_reg
    always @(posedge clk or negedge rst_n)
        if (~rst_n)
            araddr_reg <= {ADDR_W{1'b0}};
        else if (arready)
            araddr_reg <= araddr;


    always @(posedge clk or negedge rst_n)
    if (~rst_n)
        aw_have <= 1'b0;
    else if (state == S_WR_RESP && bready)
        aw_have <= 1'b0;   
    else if (awready)
        aw_have <= 1'b1;   

    always @(posedge clk or negedge rst_n)
    if (~rst_n)
        w_have <= 1'b0;
    else if (state == S_WR_RESP && bready)
        w_have <= 1'b0;
    else if (wready)
        w_have <= 1'b1;

    //semnale de handshake
    assign awready = (state == S_IDLE) && awvalid && ~aw_have && ~stall_i;
    assign wready  = (state == S_IDLE) && wvalid  && ~w_have  && ~stall_i;
    assign arready = (state == S_IDLE) && arvalid && ~aw_have && ~w_have && ~stall_i;
    assign bvalid  = (state == S_WR_RESP); 
    assign bresp   = mem_error ? RESP_SLVERR : RESP_OKAY;
    assign rvalid  = (state == S_RD_RESP);
    assign rdata   = mem_rdata;
    assign rresp   = mem_error ? RESP_SLVERR : RESP_OKAY;

    //semnale pentru arbitru de coliziuni si mem
    assign mem_valid = (state == S_WR_RESP) || (state == S_RD_RESP);
    assign mem_write = (state == S_WR_RESP);
    assign mem_addr  = (state == S_RD_RESP) ? araddr_reg : awaddr_reg;
    assign mem_wdata = wdata_reg; 
    assign mem_wstrb = wstrb_reg;

endmodule
