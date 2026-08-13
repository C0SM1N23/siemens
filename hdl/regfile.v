// Register file (REQ10, to spec): 32x32-bit GPRs, x0 hardwired to 0, one write
// port (Stage 3 writeback) and two combinational read ports (Stage 2), reset 0.
`timescale 1ns/1ps

module regfile (
    input             clk,
    input             rst_n,            // reset asincron, activ 0
    input      [4:0]  rs1_addr,
    input      [4:0]  rs2_addr,
    input      [4:0]  rd_addr,
    input      [31:0] rd_data,          // de la writeback
    input             RegWrite,

    output     [31:0] rs1_data,
    output     [31:0] rs2_data
);

reg [31:0] regs [0:31];
integer i;

// citire combinationala, x0 = 0
assign rs1_data = (rs1_addr == 5'b0) ? 32'b0 : regs[rs1_addr];
assign rs2_data = (rs2_addr == 5'b0) ? 32'b0 : regs[rs2_addr];

// scriere sincrona; x0 nescris
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        for (i = 0; i < 32; i = i + 1)
            regs[i] <= 32'b0;
    else if (RegWrite && rd_addr != 5'b0)
        regs[rd_addr] <= rd_data;
end

endmodule
