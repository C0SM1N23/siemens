# SoC regression: one compile, fourteen runs.
#
#   vsim -c -do "do regress.do; quit -f"
#
# Each run ends in its own PASS banner and none may print a FAIL line, the same
# convention the CPU block's regression uses, so a log can be checked by
# counting banners rather than by trusting an exit code.
#
# THE FIVE BENCHES
# Run 1 checks the address map against the decoder that implements it: every
# window is exactly the size of its block, so an address inside the window but
# past the block cannot alias back onto it. That property is invisible to the
# runs below, because working software never issues such an address. Run 2 is
# the block bench for the burst bridge, the only piece of new RTL the whole SoC
# data path runs through. Runs 3-6 are the system bench: real software on the
# real CPU driving a real DMA transfer, with the CPU asleep while it happens.
# Runs 7-10 run the same system with the CPU working the bus throughout, which
# is what reaches the contention logic - the arbiter under load, both SRAM
# ports at once, and the decoder's error path. Runs 11-14 walk five DMA
# transfer lengths that are not whole 32-byte bursts. The other two system
# programs move 64 and 256 bytes, exact multiples of the burst size, so the
# channel's short-burst path was unreachable from the system tests - and a
# transfer ending mid-burst is where a DMA writes past what it was asked to
# move. The bench reads the SRAM array directly and fails on a word delivered
# short as well as on a word written past the end.
#
# The stress bench exists because a coverage probe on the system bench showed
# it never contended the arbiter, never drove both SRAM ports in one cycle and
# never produced a collision. It passed without touching any of it. The stress
# bench measures those and fails if they did not happen, so the coverage cannot
# quietly rot.
#
# THE TIMING SWEEP
# Each system-level bench runs under four bus timings, the same four the CPU
# block's regression uses: nominal, high fixed latency, and two seeds of random
# READY backpressure. A fabric that only works when every slave answers in one
# cycle has not been tested - the decoder holds a latched routing select across
# the response, the arbiter holds a grant across it, and the burst bridge holds
# a beat counter across it, and all three are exactly the kind of state that
# only breaks when a slave takes its time.
#
# The coverage floors are enforced in ALL four stress runs, not only the
# nominal one. That was not a given: injected latency changes the schedule, so
# the program reaches different corners each time. Measured, the floors hold
# everywhere - the arbiter is contended for 161 to 224 cycles and at least one
# real SRAM address conflict occurs in every configuration - so there is no
# reason to let the stressed runs off. COVERAGE_GATE stays as a parameter for
# the day a new timing legitimately cannot reach a floor, and turning it off
# should be argued for, not assumed.
#
# Note: -G (force), not -g - vopt folds parameters into the elaborated design
# and -g then fails SILENTLY. Each parameterised run echoes the values examined
# from the elaborated design, so the log proves the configuration was applied.

do compile.do

echo "=== run 1/14: SoC address map, windows and aliasing ==="
vsim -onfinish stop -voptargs=+acc work.tb_addr_map
run -all
quit -sim

echo "=== run 2/14: AXI4-Full to AXI4-Lite burst bridge ==="
vsim -onfinish stop -voptargs=+acc work.tb_full2lite
run -all
quit -sim

echo "=== run 3/14: system bench, nominal bus timing ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_top
echo "cfg: imem RL=[examine -radix dec /tb_soc_top/dut/IMEM_READ_LAT] SP=[examine -radix dec /tb_soc_top/dut/IMEM_STALL_PROB] | dmem RL=[examine -radix dec /tb_soc_top/dut/DMEM_READ_LAT] WL=[examine -radix dec /tb_soc_top/dut/DMEM_WRITE_LAT] SP=[examine -radix dec /tb_soc_top/dut/DMEM_STALL_PROB]"
run -all
quit -sim

echo "=== run 4/14: system bench, high fixed memory latency ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_top \
     -G/tb_soc_top/dut/IMEM_READ_LAT=2 \
     -G/tb_soc_top/dut/DMEM_READ_LAT=3 \
     -G/tb_soc_top/dut/DMEM_WRITE_LAT=2
echo "cfg: imem RL=[examine -radix dec /tb_soc_top/dut/IMEM_READ_LAT] | dmem RL=[examine -radix dec /tb_soc_top/dut/DMEM_READ_LAT] WL=[examine -radix dec /tb_soc_top/dut/DMEM_WRITE_LAT]"
run -all
quit -sim

echo "=== run 5/14: system bench, random READY backpressure, seed set A ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_top \
     -G/tb_soc_top/dut/IMEM_STALL_PROB=25 -G/tb_soc_top/dut/IMEM_SEED=101 \
     -G/tb_soc_top/dut/DMEM_STALL_PROB=35 -G/tb_soc_top/dut/DMEM_SEED=202
echo "cfg: imem SP=[examine -radix dec /tb_soc_top/dut/IMEM_STALL_PROB] SEED=[examine -radix dec /tb_soc_top/dut/IMEM_SEED] | dmem SP=[examine -radix dec /tb_soc_top/dut/DMEM_STALL_PROB] SEED=[examine -radix dec /tb_soc_top/dut/DMEM_SEED]"
run -all
quit -sim

echo "=== run 6/14: system bench, random READY backpressure, seed set B ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_top \
     -G/tb_soc_top/dut/IMEM_STALL_PROB=40 -G/tb_soc_top/dut/IMEM_SEED=777 \
     -G/tb_soc_top/dut/DMEM_STALL_PROB=20 -G/tb_soc_top/dut/DMEM_SEED=888 \
     -G/tb_soc_top/dut/DMEM_READ_LAT=1
echo "cfg: imem SP=[examine -radix dec /tb_soc_top/dut/IMEM_STALL_PROB] SEED=[examine -radix dec /tb_soc_top/dut/IMEM_SEED] | dmem SP=[examine -radix dec /tb_soc_top/dut/DMEM_STALL_PROB] SEED=[examine -radix dec /tb_soc_top/dut/DMEM_SEED] RL=[examine -radix dec /tb_soc_top/dut/DMEM_READ_LAT]"
run -all
quit -sim

echo "=== run 7/14: stress bench, nominal timing ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_stress
echo "cfg: gate=[examine -radix dec /tb_soc_stress/COVERAGE_GATE] | dmem RL=[examine -radix dec /tb_soc_stress/dut/DMEM_READ_LAT] SP=[examine -radix dec /tb_soc_stress/dut/DMEM_STALL_PROB]"
run -all
quit -sim

echo "=== run 8/14: stress bench, high fixed memory latency ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_stress \
     -G/tb_soc_stress/dut/IMEM_READ_LAT=2 \
     -G/tb_soc_stress/dut/DMEM_READ_LAT=3 \
     -G/tb_soc_stress/dut/DMEM_WRITE_LAT=2
echo "cfg: gate=[examine -radix dec /tb_soc_stress/COVERAGE_GATE] | imem RL=[examine -radix dec /tb_soc_stress/dut/IMEM_READ_LAT] | dmem RL=[examine -radix dec /tb_soc_stress/dut/DMEM_READ_LAT] WL=[examine -radix dec /tb_soc_stress/dut/DMEM_WRITE_LAT]"
run -all
quit -sim

echo "=== run 9/14: stress bench, random READY backpressure, seed set A ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_stress \
     -G/tb_soc_stress/dut/IMEM_STALL_PROB=25 -G/tb_soc_stress/dut/IMEM_SEED=101 \
     -G/tb_soc_stress/dut/DMEM_STALL_PROB=35 -G/tb_soc_stress/dut/DMEM_SEED=202
echo "cfg: gate=[examine -radix dec /tb_soc_stress/COVERAGE_GATE] | imem SP=[examine -radix dec /tb_soc_stress/dut/IMEM_STALL_PROB] | dmem SP=[examine -radix dec /tb_soc_stress/dut/DMEM_STALL_PROB] SEED=[examine -radix dec /tb_soc_stress/dut/DMEM_SEED]"
run -all
quit -sim

echo "=== run 10/14: stress bench, random READY backpressure, seed set B ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_stress \
     -G/tb_soc_stress/dut/IMEM_STALL_PROB=40 -G/tb_soc_stress/dut/IMEM_SEED=777 \
     -G/tb_soc_stress/dut/DMEM_STALL_PROB=20 -G/tb_soc_stress/dut/DMEM_SEED=888 \
     -G/tb_soc_stress/dut/DMEM_WRITE_LAT=1
echo "cfg: gate=[examine -radix dec /tb_soc_stress/COVERAGE_GATE] | imem SP=[examine -radix dec /tb_soc_stress/dut/IMEM_STALL_PROB] | dmem SP=[examine -radix dec /tb_soc_stress/dut/DMEM_STALL_PROB] WL=[examine -radix dec /tb_soc_stress/dut/DMEM_WRITE_LAT]"
run -all
quit -sim

echo "=== soc regression done ==="

echo "=== run 11/14: DMA transfer lengths, nominal bus timing ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_dma_len
run -all
quit -sim

echo "=== run 12/14: DMA transfer lengths, high fixed memory latency ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_dma_len      -G/tb_soc_dma_len/dut/IMEM_READ_LAT=2      -G/tb_soc_dma_len/dut/DMEM_READ_LAT=3      -G/tb_soc_dma_len/dut/DMEM_WRITE_LAT=2
echo "cfg: imem RL=[examine -radix dec /tb_soc_dma_len/dut/IMEM_READ_LAT] | dmem RL=[examine -radix dec /tb_soc_dma_len/dut/DMEM_READ_LAT] WL=[examine -radix dec /tb_soc_dma_len/dut/DMEM_WRITE_LAT]"
run -all
quit -sim

echo "=== run 13/14: DMA transfer lengths, random READY backpressure, seed set A ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_dma_len      -G/tb_soc_dma_len/dut/IMEM_STALL_PROB=25 -G/tb_soc_dma_len/dut/IMEM_SEED=101      -G/tb_soc_dma_len/dut/DMEM_STALL_PROB=35 -G/tb_soc_dma_len/dut/DMEM_SEED=202
echo "cfg: imem SP=[examine -radix dec /tb_soc_dma_len/dut/IMEM_STALL_PROB] | dmem SP=[examine -radix dec /tb_soc_dma_len/dut/DMEM_STALL_PROB]"
run -all
quit -sim

echo "=== run 14/14: DMA transfer lengths, random READY backpressure, seed set B ==="
vsim -onfinish stop -voptargs=+acc work.tb_soc_dma_len      -G/tb_soc_dma_len/dut/IMEM_STALL_PROB=40 -G/tb_soc_dma_len/dut/IMEM_SEED=777      -G/tb_soc_dma_len/dut/DMEM_STALL_PROB=20 -G/tb_soc_dma_len/dut/DMEM_SEED=888
echo "cfg: imem SP=[examine -radix dec /tb_soc_dma_len/dut/IMEM_STALL_PROB] | dmem SP=[examine -radix dec /tb_soc_dma_len/dut/DMEM_STALL_PROB]"
run -all
quit -sim
