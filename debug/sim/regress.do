# Full regression: one compile, fifteen runs.
#   vsim -c -do "do regress.do; quit -f"
#
# Every run must end in its own PASS banner and none may print a FAIL line.
# The banners are deliberately distinct per bench so the log can be checked by
# counting them rather than by trusting an exit code.
#
# Runs 1-7 are the system and feature regression: the same self-checking
# program under different bus timing, the dual-core bench, and the two PIC
# benches. Runs 8-15 are the block-level benches, which check the properties a
# system run cannot isolate - reset values, read-only enforcement, individual
# status fields, one trap cause at a time, the branch predictor's RAS
# boundaries, and the ALU's operand boundaries.
#
# Note: -G (force), not -g - vopt folds parameters like READ_LAT into the
# elaborated design and -g then fails SILENTLY. Each parameterised run echoes
# the values examined from the elaborated design, so the log proves the
# configuration was actually applied.

do compile.do

echo "=== run 1/15: single-core, default latencies (CPI check active) ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi
echo "cfg: imem RL=[examine -radix dec /tb_cpu_axi/imem_inst/READ_LAT] SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] | dmem RL=[examine -radix dec /tb_cpu_axi/dmem_inst/READ_LAT] WL=[examine -radix dec /tb_cpu_axi/dmem_inst/WRITE_LAT] SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB]"
run -all
quit -sim

echo "=== run 2/15: single-core, high fixed AXI latencies ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/READ_LAT=2 \
     -G/tb_cpu_axi/dmem_inst/READ_LAT=3 \
     -G/tb_cpu_axi/dmem_inst/WRITE_LAT=2
echo "cfg: imem RL=[examine -radix dec /tb_cpu_axi/imem_inst/READ_LAT] SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] | dmem RL=[examine -radix dec /tb_cpu_axi/dmem_inst/READ_LAT] WL=[examine -radix dec /tb_cpu_axi/dmem_inst/WRITE_LAT] SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB]"
run -all
quit -sim

echo "=== run 3/15: single-core, random READY backpressure, seed set A ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/STALL_PROB=25 -G/tb_cpu_axi/imem_inst/SEED=101 \
     -G/tb_cpu_axi/dmem_inst/STALL_PROB=35 -G/tb_cpu_axi/dmem_inst/SEED=202
echo "cfg: imem SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/imem_inst/SEED] | dmem SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/dmem_inst/SEED]"
run -all
quit -sim

echo "=== run 4/15: single-core, random READY backpressure, seed set B ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/STALL_PROB=40 -G/tb_cpu_axi/imem_inst/SEED=777 \
     -G/tb_cpu_axi/dmem_inst/STALL_PROB=20 -G/tb_cpu_axi/dmem_inst/SEED=888
echo "cfg: imem SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/imem_inst/SEED] | dmem SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/dmem_inst/SEED]"
run -all
quit -sim

echo "=== run 5/15: dual-core shared-memory handshake ==="
vsim -onfinish stop -voptargs=+acc work.tb_dual_core
run -all
quit -sim

echo "=== run 6/15: standalone PIC feature bench ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic
run -all
quit -sim

echo "=== run 7/15: PIC scheduling corner cases ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic_sched
run -all
quit -sim

echo "=== run 8/15: PIC reset verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic_reset
run -all
quit -sim

echo "=== run 9/15: PIC read-only and reserved-bit verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic_ro
run -all
quit -sim

echo "=== run 10/15: PIC SRCx_STATUS field-by-field verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_pic_status
run -all
quit -sim

echo "=== run 11/15: machine-timer register verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_mtimer_regs
run -all
quit -sim

echo "=== run 12/15: CSR read-only / WARL / reset verification ==="
vsim -onfinish stop -voptargs=+acc work.tb_csr_ro
run -all
quit -sim

echo "=== run 13/15: one directed test per trap cause ==="
vsim -onfinish stop -voptargs=+acc work.tb_traps
run -all
quit -sim

echo "=== run 14/15: branch predictor BTB/BHT, RAS boundaries, reset ==="
vsim -onfinish stop -voptargs=+acc work.tb_bp
run -all
quit -sim

echo "=== run 15/15: ALU operation decode and operand boundaries ==="
vsim -onfinish stop -voptargs=+acc work.tb_alu
run -all
quit -sim

echo "=== regression done ==="
