module writeback_mux (
    input      [31:0] alu_result,
    input      [31:0] mem_data,
    input      [31:0] pc_plus4,
    input      [31:0] csr_data,
    input      [1:0]  MemtoReg,

    output reg [31:0] wb_data
);

// ce ajunge in rd
always @(*)
    case (MemtoReg)
        2'b00:   wb_data = alu_result;   // R/I arit, LUI, AUIPC
        2'b01:   wb_data = mem_data;     // load
        2'b10:   wb_data = pc_plus4;     // JAL/JALR link
        2'b11:   wb_data = csr_data;     // CSR
        default: wb_data = 32'b0;
    endcase

endmodule
