# Full regression: one compile, twelve runs.
#   vsim -c -do "do regress.do; quit -f"
#
# Every run must end in its own PASS banner and none may print a FAIL line.
# The banners are deliberately distinct per bench so the log can be checked by
# counting them rather than by trusting an exit code.
#
# Runs 1-6 are the system and feature regression: the same self-checking
# program under different bus timing, the dual-core bench, and the PIC feature
# bench. Runs 7-12 are the block-level benches, which check the properties a
# system run cannot isolate - reset values, read-only enforcement, individual
# status fields and one trap cause at a time.
#
# Note: -G (force), not -g - vopt folds parameters like READ_LAT into the
# elaborated design and -g then fails SILENTLY. Each parameterised run echoes
# the values examined from the elaborated design, so the log proves the
# configuration was actually applied.

do compile.do

echo "=== run 1/12: single-core, default latencies (CPI check active) ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi
echo "cfg: imem RL=[examine -radix dec /tb_cpu_axi/imem_inst/READ_LAT] SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] | dmem RL=[examine -radix dec /tb_cpu_axi/dmem_inst/READ_LAT] WL=[examine -radix dec /tb_cpu_axi/dmem_inst/WRITE_LAT] SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB]"
run -all
quit -sim

echo "=== run 2/12: single-core, high fixed AXI latencies ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/READ_LAT=2 \
     -G/tb_cpu_axi/dmem_inst/READ_LAT=3 \
     -G/tb_cpu_axi/dmem_inst/WRITE_LAT=2
echo "cfg: imem RL=[examine -radix dec /tb_cpu_axi/imem_inst/READ_LAT] SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] | dmem RL=[examine -radix dec /tb_cpu_axi/dmem_inst/READ_LAT] WL=[examine -radix dec /tb_cpu_axi/dmem_inst/WRITE_LAT] SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB]"
run -all
quit -sim

echo "=== run 3/12: single-core, random READY backpressure, seed set A ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/STALL_PROB=25 -G/tb_cpu_axi/imem_inst/SEED=101 \
     -G/tb_cpu_axi/dmem_inst/STALL_PROB=35 -G/tb_cpu_axi/dmem_inst/SEED=202
echo "cfg: imem SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/imem_inst/SEED] | dmem SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/dmem_inst/SEED]"
run -all
quit -sim

echo "=== run 4/12: single-core, random READY backpressure, seed set B ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/STALL_PROB=40 -G/tb_cpu_axi/imem_inst/SEED=777 \
     -G/tb_cpu_axi/dmem_inst/STALL_PROB=20 -G/tb_cpu_axi/dmem_inst/SEED=888
echo "cfg: imem SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/imem_inst/SEED] | dmem SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/dmem_inst/SEED]"
run -all
quit -sim

echo "=== run 5/12: dual-core shared-memory handshake ==="
vsim -onfinish stop -voptargs=+acc work.tb_dual_core
run -all
quit -sim

echo "=== run 6/12: standalone PIC feature bench ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic
run -all
quit -sim

echo "=== run 7/12: PIC reset verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic_reset
run -all
quit -sim

echo "=== run 8/12: PIC read-only and reserved-bit verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic_ro
run -all
quit -sim

echo "=== run 9/12: PIC SRCx_STATUS field-by-field verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic_status
run -all
quit -sim

echo "=== run 10/12: machine-timer register verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_mtimer_regs
run -all
quit -sim

echo "=== run 11/12: CSR read-only / WARL / reset verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_csr_ro
run -all
quit -sim

echo "=== run 12/12: one directed test per trap cause ==="
vsim -onfinish stop -voptargs=+acc work.tb_traps
run -all
quit -sim

echo "=== regression done ==="
