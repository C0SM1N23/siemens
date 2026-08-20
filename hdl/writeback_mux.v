`timescale 1ns/1ps

`include "defines.vh"

module writeback_mux (
    input      [31:0] alu_result_i,       // ALU result (or the CSR read value, muxed in S2)
    input      [31:0] mem_data_i,
    input      [31:0] pc_plus4_i,
    input      [1:0]  MemtoReg_i,

    output reg [31:0] wb_data_o
);

// what lands in rd
always @(*)
    case (MemtoReg_i)
        `WB_ALU: wb_data_o = alu_result_i;   // R/I arithmetic, LUI, AUIPC, CSR
        `WB_MEM: wb_data_o = mem_data_i;     // load
        `WB_PC4: wb_data_o = pc_plus4_i;     // JAL/JALR link
        default: wb_data_o = 32'b0;
    endcase

endmodule
