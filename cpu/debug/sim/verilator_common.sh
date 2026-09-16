#!/usr/bin/env bash
# Shared assertion runner. Build failures, crashes and missing verdicts all fail.
run_asserted() {
    local top="$1"
    shift
    echo "RUN SVA: $top"
    mkdir -p "obj_dir/$top" || return 1
    verilator --binary --timing --timescale 1ns/1ps --assert -Wno-fatal --unroll-count 64 -j 4 \
        --top-module "$top" --Mdir "obj_dir/$top" -o "V$top" "$@" \
        > "build_$top.log" 2>&1 || { tail -80 "build_$top.log"; return 1; }
    "./obj_dir/$top/V$top" 2>&1 | tee "run_$top.log" || return 1
    grep -Eq 'ALL TESTS PASSED|DUAL-CORE TEST PASSED' "run_$top.log" || return 1
    if grep -Eq '%Error|FAIL:|GATE FAILED' "run_$top.log"; then return 1; fi
    echo "PASS SVA: $top"
}
