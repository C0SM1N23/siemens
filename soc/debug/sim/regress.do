# SoC regression: one compile, two runs.
#
#   vsim -c -do "do regress.do; quit -f"
#
# Each run ends in its own PASS banner and none may print a FAIL line, the same
# convention the CPU block's regression uses, so a log can be checked by
# counting banners rather than by trusting an exit code.
#
# Run 1 is the block bench for the burst bridge, the only piece of new RTL the
# whole SoC data path runs through. Run 2 is the system bench: real software on
# the real CPU driving a real DMA transfer into the real SRAM.
#
# The bridge runs first on purpose. If both fail, the bridge's failure is the
# one to read: the system bench cannot be right if the bridge under it is wrong.

do compile.do

echo "=== run 1/2: AXI4-Full to AXI4-Lite burst bridge ==="
vsim -onfinish stop -voptargs=+acc work.tb_full2lite
run -all
quit -sim

echo "=== run 2/2: SoC system test, CPU + DMA + dual-port SRAM ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_top
run -all
quit -sim

echo "=== soc regression done ==="
