# rm -rf work
vlib work
vmap work work

vlog -work work ../../hdl/axi4lite_slave_fsm.v
vlog -work work ../../hdl/collision_det.v
vlog -work work ../../hdl/mem_array.v
vlog -work work ../../hdl/regfile.v
vlog -work work ../../hdl/dp_sram_top.v
vlog -work work ../hdl/tb_dp_sram_top.v
