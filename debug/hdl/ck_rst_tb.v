//------------------------------------------------------------------------------
// Universitatea Transilvania din Brasov
// Departamentul de Electronica si Calculatoare
// Proiect     : Laborator HDL
// Modul       : ck_rst_tb
// Autor       : Dan NICULA (DN)
// Data        : Oct. 1, 2019
//------------------------------------------------------------------------------
// Descriere   : Generator de semnal de ceas si de reset asincron (activ 0)
//------------------------------------------------------------------------------
// Modificari  :
// Oct. 1, 2019 (DN): Initial 
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module ck_rst_tb #(
parameter CK_SEMIPERIOD = 'd10        // semi-perioada semnalului de ceas
)(
output reg              clk         , // ceas
output reg              rst_n         // reset asincron activ 0
);  
initial 
begin
  clk = 1'b0;             // valoare initiala 0
  forever #CK_SEMIPERIOD  // valoare complementata la fiecare semi-perioada
    clk = ~clk;
end

initial begin
  rst_n = 1'b0;    // initial inactiv
  #123;
  rst_n = 1'b1;    // activare sincrona
end

endmodule // ck_rst_tb
