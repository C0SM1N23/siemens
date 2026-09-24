#!/usr/bin/env bash
# Formal verification of the SoC fabric with SymbiYosys: decoder, arbiter and
# burst bridge. For each block: safety by induction (prove), bounded completion
# time in a fair environment (live) and reachability of the interesting states
# (cover). Then every harness is run against injected defects and must fail on
# each one: a proof that still passes with the defect in place checks nothing.
#
# Needs: yosys, sby, yosys-abc and z3 on PATH.
set -euo pipefail
cd "$(dirname "$0")"

status=0
for block in dec arb bridge; do
    for task in prove live cover; do
        if sby -f "$block.sby" "$task" > "${block}_${task}.log" 2>&1; then
            echo "PASS: $block $task"
        else
            echo "FAIL: $block $task (see ${block}_${task}.log)"
            status=1
        fi
    done
done

# name # harness # RTL file # original text # defective text
MUTATIONS=(
  "dec_read_gate#dec#soc_axi_lite_dec.v#ar_accept = ~rd_addr_valid_q;#ar_accept = 1'b1;"
  "dec_stale_write#dec#soc_axi_lite_dec.v#wr_addr_valid_q ? wr_sel_q : aw_hit#m_awvalid_i ? aw_hit : wr_sel_q"
  "dec_early_decerr#dec#soc_axi_lite_dec.v#if ((err_awdone | err_aw_hs) && (err_wdone | err_w_hs)) err_bvalid#if (err_awdone | err_aw_hs) err_bvalid"
  "arb_second_address#arb#soc_axi_lite_arb.v#write_grant_q && !aw_taken_q && |(gnt & m_awvalid_i)#write_grant_q && |(gnt & m_awvalid_i)"
  "arb_both_directions#arb#soc_axi_lite_arb.v#!write_grant_q && !ar_taken_q && |(gnt & m_arvalid_i)#!ar_taken_q && |(gnt & m_arvalid_i)"
  "arb_release_early#arb#soc_axi_lite_arb.v#wire release_gnt = (s_bvalid_i & s_bready_o[0]) | (s_rvalid_i & s_rready_o[0]);#wire release_gnt = s_bvalid_i | s_rvalid_i;"
  "bridge_alignment#bridge#soc_axi_full2lite.v# && (s_awaddr_i[1:0] == 2'b00)#"
  "bridge_response_fold#bridge#soc_axi_full2lite.v#m_bresp_i > w_resp#m_bresp_i != RESP_OKAY"
  "bridge_write_stride#bridge#soc_axi_full2lite.v#w_addr <= w_addr + 32'd4;#w_addr <= w_addr + 32'd8;"
  "bridge_rlast#bridge#soc_axi_full2lite.v#wire r_last = (r_beat == r_len);#wire r_last = (r_beat == r_len) && r_ar_sent;"
)
WORK=$(mktemp -d)
for entry in "${MUTATIONS[@]}"; do
    IFS='#' read -r name block file old new <<< "$entry"
    rm -rf "${WORK:?}"/*
    cp "$block.sby" "${block}_formal.sv" "$WORK/"
    python3 - "../../hdl/$file" "$WORK/$file" "$old" "$new" <<'PYEOF'
import sys
text = open(sys.argv[1]).read()
if text.count(sys.argv[3]) != 1:
    sys.exit(f"stale mutation anchor in {sys.argv[1]}: {sys.argv[3]}")
open(sys.argv[2], "w").write(text.replace(sys.argv[3], sys.argv[4]))
PYEOF
    sed -i "s#../../hdl/$file#$file#" "$WORK/$block.sby"
    if (cd "$WORK" && sby -f "$block.sby" prove > sby.log 2>&1); then
        echo "MISSED: $name (the $block proof still passes)"
        status=1
    elif grep -q "DONE (FAIL" "$WORK"/"$block"_prove/logfile.txt; then
        echo "DETECTED: $name"
    else
        echo "ERROR: $name did not run"
        status=1
    fi
done
rm -rf "$WORK"

[ "$status" -eq 0 ] && echo "FORMAL PASS: 3 blocks x 3 tasks, ${#MUTATIONS[@]} injected defects detected"
exit "$status"
