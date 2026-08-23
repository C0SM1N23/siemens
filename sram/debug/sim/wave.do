onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate /tb_dp_sram_top/rst_n
add wave -noupdate /tb_dp_sram_top/clk

add wave -noupdate /tb_dp_sram_top/a_arvalid
add wave -noupdate /tb_dp_sram_top/a_arready
add wave -noupdate /tb_dp_sram_top/a_araddr

add wave -noupdate /tb_dp_sram_top/a_awvalid
add wave -noupdate /tb_dp_sram_top/a_awready
add wave -noupdate /tb_dp_sram_top/a_awaddr

add wave -noupdate /tb_dp_sram_top/b_arvalid
add wave -noupdate /tb_dp_sram_top/b_arready
add wave -noupdate /tb_dp_sram_top/b_araddr

add wave -noupdate /tb_dp_sram_top/b_awvalid
add wave -noupdate /tb_dp_sram_top/b_awready
add wave -noupdate /tb_dp_sram_top/b_awaddr


add wave -noupdate /tb_dp_sram_top/a_bready
add wave -noupdate /tb_dp_sram_top/a_bresp
add wave -noupdate /tb_dp_sram_top/a_bvalid
add wave -noupdate /tb_dp_sram_top/a_rdata
add wave -noupdate /tb_dp_sram_top/a_rready
add wave -noupdate /tb_dp_sram_top/a_rresp
add wave -noupdate /tb_dp_sram_top/a_rvalid
add wave -noupdate /tb_dp_sram_top/a_wdata
add wave -noupdate /tb_dp_sram_top/a_wready
add wave -noupdate /tb_dp_sram_top/a_wstrb
add wave -noupdate /tb_dp_sram_top/a_wvalid
add wave -noupdate /tb_dp_sram_top/arg1
add wave -noupdate /tb_dp_sram_top/arg2
add wave -noupdate /tb_dp_sram_top/arg3
add wave -noupdate /tb_dp_sram_top/arg4
add wave -noupdate /tb_dp_sram_top/b_bready
add wave -noupdate /tb_dp_sram_top/b_bresp
add wave -noupdate /tb_dp_sram_top/b_bvalid
add wave -noupdate /tb_dp_sram_top/b_rdata
add wave -noupdate /tb_dp_sram_top/b_rready
add wave -noupdate /tb_dp_sram_top/b_rresp
add wave -noupdate /tb_dp_sram_top/b_rvalid
add wave -noupdate /tb_dp_sram_top/b_wdata
add wave -noupdate /tb_dp_sram_top/b_wready
add wave -noupdate /tb_dp_sram_top/b_wstrb
add wave -noupdate /tb_dp_sram_top/b_wvalid
add wave -noupdate /tb_dp_sram_top/cmd
add wave -noupdate /tb_dp_sram_top/fail_count
add wave -noupdate /tb_dp_sram_top/fd
add wave -noupdate /tb_dp_sram_top/fgets_ret
add wave -noupdate /tb_dp_sram_top/irq
add wave -noupdate /tb_dp_sram_top/line
add wave -noupdate /tb_dp_sram_top/line_num
add wave -noupdate /tb_dp_sram_top/pass_count
add wave -noupdate /tb_dp_sram_top/scan_count
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {0 ps} 0}
quietly wave cursor active 0
configure wave -namecolwidth 150
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ps
update
WaveRestoreZoom {0 ps} {3246 ps}
