#!/usr/bin/env bash
# Compare soc_axi_lite_dec against pulp-platform/axi's axi_lite_demux on the
# same stimulus. Separate from run_verilator.sh on purpose: this is the only
# flow that needs an external repository, and no other flow may depend on one.
#
# The upstream sources are NOT vendored into this repository. They are fetched
# into a work directory (default: a sibling of this script, ignored by git), or
# taken from an existing checkout:
#
#   PULP_AXI_DIR=/path/to/axi PULP_CC_DIR=/path/to/common_cells ./run_pulp_compare.sh
#
# Upstream is Solderpad 0.51 licensed; see the LICENSE file in each checkout.
# The only file here that touches it is ../hdl/pulp_lite_demux_wrap.sv, which is
# ours and contains no upstream code.
#
# Needs: verilator, git (unless both paths are supplied), network access for the
# first run.
set -euo pipefail
cd "$(dirname "$0")"

WORK="${PULP_WORK_DIR:-./pulp_ref}"
AXI_REV="${PULP_AXI_REV:-master}"
CC_REV="${PULP_CC_REV:-v2.0.0-beta.2}"   # the revision axi's Bender.yml pins

fetch() { # fetch <url> <rev> <dir>
    if [ -d "$3/.git" ]; then
        echo "using existing checkout: $3"
    else
        echo "fetching $1 ($2) into $3"
        git clone --depth 1 --branch "$2" "$1" "$3" \
            || { echo "FAIL: could not fetch $1 - no network access?"; exit 1; }
    fi
}

if [ -n "${PULP_AXI_DIR:-}" ] && [ -n "${PULP_CC_DIR:-}" ]; then
    AXI="$PULP_AXI_DIR"
    CC="$PULP_CC_DIR"
else
    mkdir -p "$WORK"
    AXI="$WORK/axi"
    CC="$WORK/common_cells"
    fetch https://github.com/pulp-platform/axi.git          "$AXI_REV" "$AXI"
    fetch https://github.com/pulp-platform/common_cells.git "$CC_REV"  "$CC"
fi

for d in "$AXI/src" "$CC/src"; do
    [ -d "$d" ] || { echo "FAIL: $d is not a source directory"; exit 1; }
done

echo "upstream axi:          $(git -C "$AXI" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "upstream common_cells: $(git -C "$CC"  rev-parse --short HEAD 2>/dev/null || echo '?')"

TOP=soc_tb_pulp_compare
mkdir -p "obj_dir/$TOP"

# -Wno-fatal: upstream carries its own lint diagnostics and is not this
# project's code to clean up. Our own files are linted by run_verilator.sh.
verilator --binary --timing --timescale 1ns/1ps --assert -Wno-fatal -j 4 \
    --top-module "$TOP" --Mdir "obj_dir/$TOP" -o "V$TOP" \
    +incdir+../../../cpu/debug/hdl \
    "+incdir+$AXI/include" "+incdir+$CC/include" \
    -y "$AXI/src" -y "$CC/src" \
    "$AXI/src/axi_pkg.sv" "$CC/src/cc_pkg.sv" \
    ../../hdl/soc_axi_lite_dec.v \
    ../hdl/soc_lite_slave_stub.v \
    ../hdl/soc_lite_seq_master.v \
    ../hdl/pulp_lite_demux_wrap.sv \
    "../hdl/$TOP.sv" \
    > "build_$TOP.log" 2>&1 || { tail -60 "build_$TOP.log"; exit 1; }

"./obj_dir/$TOP/V$TOP" "$@" 2>&1 | tee "run_$TOP.log"

grep -q 'ALL TESTS PASSED' "run_$TOP.log" || { echo "FAIL: comparison did not pass"; exit 1; }
grep -Eq '%Error|FAIL:' "run_$TOP.log" && { echo "FAIL: errors in the comparison run"; exit 1; }
echo "PULP COMPARISON PASS"
