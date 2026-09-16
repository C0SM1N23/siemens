// Source list; paths are relative to this simulation directory.
+incdir+../hdl

// Level 0: leaf testbench models
../hdl/ck_rst_tb.v           // clock + async reset generator     (leaf)
../hdl/axi_lite_mem_model.v  // behavioural AXI4-Lite memory      (leaf)
../hdl/axi_lite_monitor.v    // passive protocol checker          (leaf)
../hdl/axi_lite_dec2.v       // 1-to-2 AXI4-Lite address decoder  (leaf)

// Level 1: the bench itself
../hdl/rv32i_tb_cpu_axi.v
