// Register file (REQ10, to spec): 32x32-bit GPRs, x0 hardwired to 0, one write
// port (Stage 3 writeback) and two combinational read ports (Stage 2), reset 0.
`timescale 1ns/1ps

module regfile (
    input             clk_i,
    input             rst_n_i,            // asynchronous reset, active low
    input      [4:0]  rs1_addr_i,
    input      [4:0]  rs2_addr_i,
    input      [4:0]  rd_addr_i,
    input      [31:0] rd_data_i,          // from the writeback stage
    input             RegWrite_i,

    output     [31:0] rs1_data_o,
    output     [31:0] rs2_data_o
);

reg [31:0] regs [0:31];
integer i;

// combinational reads, x0 always reads 0
assign rs1_data_o = (rs1_addr_i == 5'b0) ? 32'b0 : regs[rs1_addr_i];
assign rs2_data_o = (rs2_addr_i == 5'b0) ? 32'b0 : regs[rs2_addr_i];

// synchronous write; x0 is never written
always @(posedge clk_i or negedge rst_n_i) begin
    if (~rst_n_i)
        for (i = 0; i < 32; i = i + 1)
            regs[i] <= 32'b0;
    else if (RegWrite_i && rd_addr_i != 5'b0)
        regs[rd_addr_i] <= rd_data_i;
end

endmodule
