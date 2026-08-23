# SoC regression: one compile, three runs.
#
#   vsim -c -do "do regress.do; quit -f"
#
# Each run ends in its own PASS banner and none may print a FAIL line, the same
# convention the CPU block's regression uses, so a log can be checked by
# counting banners rather than by trusting an exit code.
#
# Run 1 is the block bench for the burst bridge, the only piece of new RTL the
# whole SoC data path runs through. Run 2 is the system bench: real software on
# the real CPU driving a real DMA transfer into the real SRAM, with the CPU
# asleep while it happens. Run 3 runs the same system with the CPU working the
# bus throughout, which is what actually reaches the contention logic - the
# arbiter under load, both SRAM ports at once, and the decoder's error path.
#
# Run 3 exists because a coverage probe on run 2 showed it never contended the
# arbiter, never drove both SRAM ports in one cycle and never produced a
# collision. It passed without touching any of it. Run 3 measures those and
# fails if they did not happen, so the coverage cannot quietly rot.
#
# The bridge runs first on purpose. If several fail, the bridge's failure is the
# one to read: nothing above it can be right if the bridge under it is wrong.

do compile.do

echo "=== run 1/3: AXI4-Full to AXI4-Lite burst bridge ==="
vsim -onfinish stop -voptargs=+acc work.tb_full2lite
run -all
quit -sim

echo "=== run 2/3: SoC system test, CPU asleep while the DMA transfers ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_top
run -all
quit -sim

echo "=== run 3/3: SoC stress test, CPU working the bus during the transfer ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_stress
run -all
quit -sim

echo "=== soc regression done ==="
