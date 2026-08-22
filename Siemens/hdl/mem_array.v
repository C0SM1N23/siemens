// =============================================================================

// 256 x 32-bit memory with independent access from Port A and Port B
// Write is only allowed when the collision module grants it
// Combinational read (happens before the write lands)
// Content is X at reset
// Global address decoding is done at top level; here we only use the local offset
// Word address is [9:2] of the 10-bit global address, ignoring the 2 offset bits

// =============================================================================

module mem_array #(
    parameter ADDR_W = 10 // address width
) (
    input  wire               clk_i, // clock

    //Port A
    input  wire [ADDR_W-1:0]  a_addr_i,        // Port A address
    input  wire [31:0]        a_wdata_i,       // Port A write data
    input  wire [3:0]         a_wstrb_i,       // Port A byte enable
    input  wire                a_write_grant_i,// 1-write allowed on Port A
    output wire [31:0]         a_rdata_o,      // Port A read data

    //Port B
    input  wire [ADDR_W-1:0]  b_addr_i,        // Port B address
    input  wire [31:0]        b_wdata_i,       // Port B write data
    input  wire [3:0]         b_wstrb_i,       // Port B byte enable
    input  wire                b_write_grant_i,// 1-write allowed on Port B
    output wire [31:0]         b_rdata_o       // Port B read data
);

    //actual memory
    reg [31:0] mem [0:255];

    wire [7:0] a_word_addr = a_addr_i[ADDR_W-1:2]; // select word for A
    wire [7:0] b_word_addr = b_addr_i[ADDR_W-1:2]; // select word for B

    assign a_rdata_o = mem[a_word_addr]; // combinational read Port A
    assign b_rdata_o = mem[b_word_addr]; // combinational read Port B

    //write
    always @(posedge clk_i) begin
        if (a_write_grant_i) begin
            if (a_wstrb_i[0]) mem[a_word_addr][7:0]   <= a_wdata_i[7:0];   // byte 0
            if (a_wstrb_i[1]) mem[a_word_addr][15:8]  <= a_wdata_i[15:8];  // byte 1
            if (a_wstrb_i[2]) mem[a_word_addr][23:16] <= a_wdata_i[23:16]; // byte 2
            if (a_wstrb_i[3]) mem[a_word_addr][31:24] <= a_wdata_i[31:24]; // byte 3
        end

        if (b_write_grant_i) begin
            if (b_wstrb_i[0]) mem[b_word_addr][7:0]   <= b_wdata_i[7:0];   // byte 0
            if (b_wstrb_i[1]) mem[b_word_addr][15:8]  <= b_wdata_i[15:8];  // byte 1
            if (b_wstrb_i[2]) mem[b_word_addr][23:16] <= b_wdata_i[23:16]; // byte 2
            if (b_wstrb_i[3]) mem[b_word_addr][31:24] <= b_wdata_i[31:24]; // byte 3
        end
    end

endmodule
