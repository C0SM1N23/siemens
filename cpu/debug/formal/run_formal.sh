#!/usr/bin/env bash
# Formal verification of the PIC with SymbiYosys: invariants by induction
# (prove), stack consistency for every 24-cycle sequence from reset (stack) and
# reachability (cover). Then the harness is run against injected defects and
# must fail on each one: a proof that still passes with the defect in place
# checks nothing.
#
# Needs: yosys, sby, yosys-abc and z3 on PATH.
set -euo pipefail
cd "$(dirname "$0")"

status=0
for task in prove stack cover; do
    if sby -f pic.sby "$task" > "pic_${task}.log" 2>&1; then
        echo "PASS: pic $task"
    else
        echo "FAIL: pic $task (see pic_${task}.log)"
        status=1
    fi
done

# name # original text in pic.v # defective text # task that must fail
MUTATIONS=(
  "claim_past_limit#wire            claim_push = cpu_irq_ack_i && (depth < nest_max);#wire            claim_push = cpu_irq_ack_i;#prove"
  "eoi_on_empty_stack#wire            eoi_pop = cpu_irq_eoi_i && has_active;#wire            eoi_pop = cpu_irq_eoi_i;#prove"
  "trigger_without_key_strobes#wire swt_key_ok = (reg_wdata[31:16] == SW_KEY) && (reg_wstrb[3:2] == 2'b11);#wire swt_key_ok = (reg_wdata[31:16] == SW_KEY);#prove"
  "offer_ignores_mask#assign eligible[s] = req[s] && cpu_mask_i[s] && !active[s]#assign eligible[s] = req[s] && !active[s]#prove"
  "nest_max_zero#if (nest_max_wr == 5'd0) nest_max <= 5'd1;#if (nest_max_wr == 5'd0) nest_max <= 5'd0;#prove"
)
WORK=$(mktemp -d)
for entry in "${MUTATIONS[@]}"; do
    IFS='#' read -r name old new task <<< "$entry"
    rm -rf "${WORK:?}"/*
    cp pic.sby pic_formal.sv ../../hdl/axi_lite_slave.v "$WORK/"
    python3 - ../../hdl/pic.v "$WORK/pic.v" "$old" "$new" <<'PYEOF'
import sys
text = open(sys.argv[1]).read()
if text.count(sys.argv[3]) != 1:
    sys.exit(f"stale mutation anchor: {sys.argv[3]}")
open(sys.argv[2], "w").write(text.replace(sys.argv[3], sys.argv[4]))
PYEOF
    sed -i 's#../../hdl/##' "$WORK/pic.sby"
    if (cd "$WORK" && sby -f pic.sby "$task" > sby.log 2>&1); then
        echo "MISSED: $name (the pic $task task still passes)"
        status=1
    elif grep -q "DONE (FAIL" "$WORK/pic_$task/logfile.txt"; then
        echo "DETECTED: $name"
    else
        echo "ERROR: $name did not run"
        status=1
    fi
done
rm -rf "$WORK"

[ "$status" -eq 0 ] && echo "FORMAL PASS: PIC x 3 tasks, ${#MUTATIONS[@]} injected defects detected"
exit "$status"
