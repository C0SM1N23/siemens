#!/usr/bin/env bash
# SoC lint + SVA run on Verilator.
#
# ModelSim ASE cannot compile SystemVerilog assertions, so the SVA layer under
# soc/debug/sva runs here, exactly as the CPU block does it. This is a second
# pair of eyes on the same design the ModelSim regression runs: the RTL, the
# testbenches and the .do flow are untouched.
#
# Usage:  bash soc/debug/sim/run_verilator.sh
#         (from Windows, via WSL: wsl bash soc/debug/sim/run_verilator.sh)
#
# Two stages, both of which must pass:
#   1. lint    -Wall over the whole SoC. The waivers below are listed one by
#              one with a reason; nothing is waived wholesale.
#   2. run     every bench, with --assert, so the bind layer is live. An
#              assertion failure prints %Error and fails the script.
#
# The bind layer is both files: the CPU block's assertion binds (cpu_core_sva,
# pic_sva and the AXI4-Lite checkers on cpu_top, the PIC and the timer) plus
# the SoC's own. The CPU half was missing here until the two were split, so a
# CPU or PIC invariant broken by the integration would not have been caught in
# a SoC run at all.

set -e
cd "$(dirname "$0")"

SVA="../sva"
CPUSVA="../../../cpu/debug/sva"

# --- waivers, each with a reason ---------------------------------------------
# UNUSEDSIGNAL   the fabric carries full 32-bit addresses to every slave; the
#                SRAM decodes 10 of them and the peripherals fewer still, so
#                unused upper bits are the design, not an oversight.
# PINCONNECTEMPTY the instruction path's decoder and RAM have their write
#                channels deliberately tied off - the ibus cannot write.
# EOFNEWLINE     missing final newline in five files inherited from the DMA
#                branch; a text-file convention, not a design property, and not
#                worth a diff in someone else's block.
# DECLFILENAME   soc_fabric_sva.sv holds three checkers, one per fabric block.
WAIVE="-Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-EOFNEWLINE -Wno-DECLFILENAME"

# --- known unrepaired findings in blocks this integration does not own --------
# One entry per warning that lint is expected to raise, each pinned to file and
# line. These are NOT waived: lint still reports them, and the stage still fails
# on anything the list does not account for, so a new warning cannot hide behind
# them. The list is also checked for staleness - if an entry stops appearing,
# the block was fixed upstream and the entry has to go.
#
# dma/hdl/dma_channel.v:249
#   req_len = (desc_len >= 32) ? 8'd7 : (desc_len[7:2] - 1)
#   desc_len[7:2] is 6 bits, so the subtraction wraps before it is zero-extended
#   into the 8-bit req_len. A descriptor shorter than 4 bytes gives 6'b111111
#   and the channel issues a 64-beat burst: 256 bytes written for a request of
#   at most 3. Reported in TO_MODIFY.md; the DMA is not ours to change.
KNOWN_LINT="dma/hdl/dma_channel.v:249"

echo "=== stage 1/2: lint ==="
set +e
lint_out=$(verilator --lint-only -Wall $WAIVE --top-module soc_top -f soc_rtl.f 2>&1)
set -e
echo "$lint_out"

# every diagnostic line, minus the ones the known list accounts for
unexpected=$(echo "$lint_out" | grep -E '^%(Warning|Error)-' | grep -vF "$KNOWN_LINT" || true)
if [ -n "$unexpected" ]; then
    echo
    echo "FAIL: lint raised something the known-findings list does not cover:"
    echo "$unexpected"
    exit 1
fi

# staleness: a known finding that no longer fires means the list is out of date
for k in $KNOWN_LINT; do
    echo "$lint_out" | grep -qF "$k" || {
        echo "FAIL: '$k' no longer warns - it was fixed upstream, drop it from KNOWN_LINT"
        exit 1
    }
done

echo "lint clean apart from $(echo "$KNOWN_LINT" | wc -w) known finding(s) in the DMA block"

# --- stage 2: build and run each bench with the assertion layer --------------
# --timing is needed for the benches' delay controls; --assert turns the bound
# SVA into real checks; --binary builds a self-contained executable.
run_bench () {
    local top="$1"
    local extra="$2"
    echo
    echo "=== running $top with assertions ==="
    verilator --binary --timing --assert -Wno-fatal $WAIVE \
        --unroll-count 64 \
        --top-module "$top" -o "V$top" \
        -f soc_rtl.f \
        +incdir+../../../cpu/debug/hdl \
        ../../../cpu/debug/hdl/ck_rst_tb.v \
        "../hdl/$top.v" \
        "$CPUSVA"/axi_lite_sva.sv \
        "$CPUSVA"/cpu_core_sva.sv \
        "$CPUSVA"/pic_sva.sv \
        "$CPUSVA"/bind_core_sva.sv \
        "$SVA"/axi_full_sva.sv \
        "$SVA"/soc_fabric_sva.sv \
        "$SVA"/soc_bind_sva.sv \
        > "build_$top.log" 2>&1 || { cat "build_$top.log"; return 1; }

    "./obj_dir/V$top" | tee "run_$top.log"

    grep -q "ALL TESTS PASSED" "run_$top.log" \
        || { echo "FAIL: $top self-check"; return 1; }
    grep -q "%Error" "run_$top.log" \
        && { echo "FAIL: $top assertion fired"; return 1; }
    return 0
}

status=0
run_bench tb_addr_map   || status=1
run_bench tb_full2lite  || status=1
run_bench tb_soc_top    || status=1
run_bench tb_soc_stress  || status=1
run_bench tb_soc_dma_len || status=1

echo
if [ $status -eq 0 ]; then
    echo "== run_verilator (soc): PASS =="
else
    echo "== run_verilator (soc): FAIL =="
fi
exit $status
