# full regression: one compile, five configurations.
#   vsim -c -do "do regress.do; quit -f"
# every run must end in "ALL TESTS PASSED" / "DUAL-CORE TEST PASSED".
#
# note: -G (force), not -g — vopt folds parameters like READ_LAT into the
# elaborated design and -g then fails SILENTLY. Each run echoes the values
# examined from the elaborated design so the log proves the config applied.

do compile.do

echo "=== run 1/5: single-core, default latencies (CPI check active) ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi
echo "cfg: imem RL=[examine -radix dec /tb_cpu_axi/imem_inst/READ_LAT] SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] | dmem RL=[examine -radix dec /tb_cpu_axi/dmem_inst/READ_LAT] WL=[examine -radix dec /tb_cpu_axi/dmem_inst/WRITE_LAT] SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB]"
run -all
quit -sim

echo "=== run 2/5: single-core, high fixed AXI latencies ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/READ_LAT=2 \
     -G/tb_cpu_axi/dmem_inst/READ_LAT=3 \
     -G/tb_cpu_axi/dmem_inst/WRITE_LAT=2
echo "cfg: imem RL=[examine -radix dec /tb_cpu_axi/imem_inst/READ_LAT] SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] | dmem RL=[examine -radix dec /tb_cpu_axi/dmem_inst/READ_LAT] WL=[examine -radix dec /tb_cpu_axi/dmem_inst/WRITE_LAT] SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB]"
run -all
quit -sim

echo "=== run 3/5: single-core, random READY backpressure, seed set A ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/STALL_PROB=25 -G/tb_cpu_axi/imem_inst/SEED=101 \
     -G/tb_cpu_axi/dmem_inst/STALL_PROB=35 -G/tb_cpu_axi/dmem_inst/SEED=202
echo "cfg: imem SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/imem_inst/SEED] | dmem SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/dmem_inst/SEED]"
run -all
quit -sim

echo "=== run 4/5: single-core, random READY backpressure, seed set B ==="
vsim -onfinish stop -voptargs=+acc work.tb_cpu_axi \
     -G/tb_cpu_axi/imem_inst/STALL_PROB=40 -G/tb_cpu_axi/imem_inst/SEED=777 \
     -G/tb_cpu_axi/dmem_inst/STALL_PROB=20 -G/tb_cpu_axi/dmem_inst/SEED=888
echo "cfg: imem SP=[examine -radix dec /tb_cpu_axi/imem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/imem_inst/SEED] | dmem SP=[examine -radix dec /tb_cpu_axi/dmem_inst/STALL_PROB] SEED=[examine -radix dec /tb_cpu_axi/dmem_inst/SEED]"
run -all
quit -sim

echo "=== run 5/5: dual-core shared-memory handshake ==="
vsim -onfinish stop -voptargs=+acc work.tb_dual_core
run -all
quit -sim

echo "=== regression done ==="
