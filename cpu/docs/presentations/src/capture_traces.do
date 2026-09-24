# VCD traces for the end-to-end excerpts in the v3 decks. Run from cpu/debug/sim:
#   vsim -c -do "do ../../docs/presentations/src/capture_traces.do"
onerror {quit -code 1 -f}
do run_common.do
do compile.do
file mkdir ../../docs/waves/raw
foreach {top signals} {
    rv32i_tb_isa        {/rv32i_tb_isa/clk /rv32i_tb_isa/step /rv32i_tb_isa/dut/dxwb_valid_q /rv32i_tb_isa/dut/dxwb_pc4_q /rv32i_tb_isa/actual_rd /rv32i_tb_isa/actual_value}
    pic_tb_reference    {/pic_tb_reference/clk /pic_tb_reference/test_index /pic_tb_reference/cpu_irq /pic_tb_reference/cpu_irq_vec /pic_tb_reference/pending /pic_tb_reference/cpu_mask /pic_tb_reference/irq_src}
} {
    vsim -onfinish stop -voptargs=+acc work.$top
    vcd file ../../docs/waves/raw/$top.vcd
    foreach s $signals {vcd add $s}
    run -all
    vcd flush
    if {[examine -radix binary /$top/test_done] ne "1"} {quit -code 1 -f}
    if {[examine -radix decimal /$top/errors] != 0} {quit -code 1 -f}
    vcd off
    quit -sim
}
echo "DECK TRACES PASS: 2 benches"
quit -f
