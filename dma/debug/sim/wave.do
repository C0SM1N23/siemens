onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate /tema1_tb/dut/clk_i
add wave -noupdate /tema1_tb/dut/rst_ni
add wave -noupdate /tema1_tb/dut/led_o
add wave -noupdate /tema1_tb/dut/cnt_o
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
WaveRestoreZoom {1837276 ps} {2040143 ps}
