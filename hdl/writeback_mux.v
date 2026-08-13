`timescale 1ns/1ps

`include "defines.vh"

module writeback_mux (
    input      [31:0] alu_result,       // rezultat ALU (sau valoarea CSR, muxata in S2)
    input      [31:0] mem_data,
    input      [31:0] pc_plus4,
    input      [1:0]  MemtoReg,

    output reg [31:0] wb_data
);

// ce ajunge in rd
always @(*)
    case (MemtoReg)
        `WB_ALU: wb_data = alu_result;   // R/I arit, LUI, AUIPC, CSR
        `WB_MEM: wb_data = mem_data;     // load
        `WB_PC4: wb_data = pc_plus4;     // JAL/JALR link
        default: wb_data = 32'b0;
    endcase

endmodule
