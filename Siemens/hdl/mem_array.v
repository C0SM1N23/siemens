// =============================================================================

// Memoria 256 x 32b cu acces independent din Port A si Port B
// Scrierea e permisa doar cand modulul de coliziuni permite scrierea
// Citire combinationala inainte de scriere 
// X la reset
// Decodarea adresei globale o facem in top lvl si aici folosim doar offset local
// Adresa de cuvant e [9:2] din adresa globala de 10 biti, ignora cei 2 biti de offset

// =============================================================================

module mem_array #(
    parameter ADDR_W = 10 // latime adresa
) (
    input  wire               clk, // ceas

    //Port A
    input  wire [ADDR_W-1:0]  a_addr,        // adresa Port A
    input  wire [31:0]        a_wdata,       // date de scris Port A
    input  wire [3:0]         a_wstrb,       // care byte Port A
    input  wire                a_write_grant,// 1-scriere permisa pe Port A
    output wire [31:0]         a_rdata,      // date citite Port A

    //Port B
    input  wire [ADDR_W-1:0]  b_addr,        // adresa Port B
    input  wire [31:0]        b_wdata,       // date de scris Port B
    input  wire [3:0]         b_wstrb,       // care byte Port B
    input  wire                b_write_grant,// 1-scriere permisa pe Port B
    output wire [31:0]         b_rdata       // date citite Port B
);

    //memorie efectiva
    reg [31:0] mem [0:255];

    wire [7:0] a_word_addr = a_addr[ADDR_W-1:2]; // selecteaza cuvantul pentru A
    wire [7:0] b_word_addr = b_addr[ADDR_W-1:2]; // selecteaza cuvantul pentru B

    assign a_rdata = mem[a_word_addr]; // citire combinationala Port A
    assign b_rdata = mem[b_word_addr]; // citire combinationala Port B

    //scriere Port A
    always @(posedge clk) 
        if (a_write_grant) begin
            if (a_wstrb[0]) mem[a_word_addr][7:0]   <= a_wdata[7:0];   // byte 0
            if (a_wstrb[1]) mem[a_word_addr][15:8]  <= a_wdata[15:8];  // byte 1
            if (a_wstrb[2]) mem[a_word_addr][23:16] <= a_wdata[23:16]; // byte 2
            if (a_wstrb[3]) mem[a_word_addr][31:24] <= a_wdata[31:24]; // byte 3
        end


    always @(posedge clk)
        if (b_write_grant) begin
            if (b_wstrb[0]) mem[b_word_addr][7:0]   <= b_wdata[7:0];   // byte 0
            if (b_wstrb[1]) mem[b_word_addr][15:8]  <= b_wdata[15:8];  // byte 1
            if (b_wstrb[2]) mem[b_word_addr][23:16] <= b_wdata[23:16]; // byte 2
            if (b_wstrb[3]) mem[b_word_addr][31:24] <= b_wdata[31:24]; // byte 3
        end
        

endmodule
