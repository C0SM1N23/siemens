# rm -rf work
vlib work
vmap work work

vlog -work work ../../hdl/dp_sram_axi4lite_slave_fsm.v
vlog -work work ../../hdl/dp_sram_collision_det.v
vlog -work work ../../hdl/dp_sram_mem_array.v
vlog -work work ../../hdl/dp_sram_regfile.v
vlog -work work ../../hdl/dp_sram.v
vlog -work work ../hdl/tb_dp_sram_top.v
