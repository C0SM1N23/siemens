//------------------------------------------------------------------------------
// Transilvania University of Brasov
// Department of Electronics and Computers
// Project : HDL Laboratory
// Module  : ck_rst_tb
// Author  : Dan NICULA (DN)
// Date    : Oct. 1, 2019
//------------------------------------------------------------------------------
// Description : Clock generator and asynchronous, active-low reset generator.
//------------------------------------------------------------------------------
// Revisions :
// Oct. 1, 2019 (DN): Initial
// Aug. 2026      : comments translated to English (no functional change)
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module ck_rst_tb #(
parameter CK_SEMIPERIOD = 'd10        // half period of the clock signal
)(
output reg              clk_o         , // clock
output reg              rst_n_o         // asynchronous reset, active low
);
initial
begin
  clk_o = 1'b0;             // initial value 0
  forever #CK_SEMIPERIOD  // value inverted every half period
    clk_o = ~clk_o;
end

initial begin
  rst_n_o = 1'b0;    // asserted (active) from time zero
  #123;
  rst_n_o = 1'b1;    // released between clock edges, on purpose
end

endmodule // ck_rst_tb
