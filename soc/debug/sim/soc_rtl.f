// Source list; paths are relative to this simulation directory.
+incdir+../../../cpu/hdl        // rv32i_defines.vh, shared CPU encodings
+incdir+../../hdl           // soc_addr_map.vh

// L0: CPU leaves
../../../cpu/hdl/rv32i_alu.v
../../../cpu/hdl/axi_lite_slave.v
../../../cpu/hdl/rv32i_branch_predictor.v
../../../cpu/hdl/rv32i_branch_unit.v
../../../cpu/hdl/rv32i_control.v
../../../cpu/hdl/rv32i_csr_file.v
../../../cpu/hdl/rv32i_decode.v
../../../cpu/hdl/rv32i_exception_unit.v
../../../cpu/hdl/rv32i_fetch_unit.v
../../../cpu/hdl/rv32i_hazard_unit.v
../../../cpu/hdl/rv32i_imm_gen.v
../../../cpu/hdl/rv32i_lsu.v
../../../cpu/hdl/rv32i_regfile.v
../../../cpu/hdl/rv32i_writeback_mux.v

// L0: DMA leaves
../../../dma/hdl/mc_dma_axi4_lite_slave.v
../../../dma/hdl/mc_dma_axi4_full_master.v
../../../dma/hdl/mc_dma_channel.v
../../../dma/hdl/mc_dma_priority_arbiter.v

// L0: DP-SRAM leaves
../../../sram/hdl/dp_sram_axi4lite_slave_fsm.v
../../../sram/hdl/dp_sram_collision_det.v
../../../sram/hdl/dp_sram_mem_array.v
../../../sram/hdl/dp_sram_regfile.v

// L0: interconnect
../../hdl/soc_axi_lite_dec.v      // 1 master -> N slaves, DECERR on a miss
../../hdl/soc_axi_lite_arb.v      // M masters -> 1 slave, round-robin
../../hdl/soc_axi_full2lite.v     // AXI4-Full burst -> AXI4-Lite beats
../../hdl/soc_axi_lite_ram.v      // AXI4-Lite RAM slave (IMEM / DMEM)

// L1: depend on L0 only
../../../cpu/hdl/rv32i_alu_top.v        // -> alu
../../../cpu/hdl/mtimer.v         // -> axi_lite_slave
../../../cpu/hdl/pic.v            // -> axi_lite_slave
../../../sram/hdl/dp_sram.v   // -> slave_fsm, collision_det, mem_array, dp_sram_regfile

// L2: block tops
../../../cpu/hdl/rv32i_cpu_top.v
../../../dma/hdl/mc_dma.v

// L3: the SoC
../../hdl/soc_top.v
