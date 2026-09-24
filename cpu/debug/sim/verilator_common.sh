#!/usr/bin/env bash
# Shared assertion runner. Build failures, crashes and missing verdicts all fail.
#
# run_asserted <top> [verilator args...]            default configuration
# run_variant  <tag> <top> [verilator args...]      a named configuration; -G
#                                                   options set top-level parameters
#
# Every run is built with --coverage-user, so the cover properties it reaches are
# kept as cov/<tag>.dat. check_covers.py merges those files afterwards.
# RUN_ARGS, when set for one call, adds plusargs to that run.
SVA_RUNS=0

# run_binary <tag> <binary> [plusargs...]: run one simulation, keep its log and
# coverage file, and require a passing verdict. Verilator writes coverage.dat,
# or logs/coverage.dat in older releases.
run_binary() {
    local tag="$1" bin="$2" f
    shift 2
    echo "RUN SVA: $tag"
    rm -f coverage.dat logs/coverage.dat
    "$bin" "$@" 2>&1 | tee "run_$tag.log" || return 1
    for f in coverage.dat logs/coverage.dat; do
        if [ -f "$f" ]; then mv "$f" "cov/$tag.dat"; break; fi
    done
    [ -f "cov/$tag.dat" ] || { echo "FAIL: $tag wrote no coverage file"; return 1; }
    grep -Eq 'ALL TESTS PASSED|DUAL-CORE TEST PASSED' "run_$tag.log" || return 1
    if grep -Eq '%Error|FAIL:|GATE FAILED' "run_$tag.log"; then return 1; fi
    SVA_RUNS=$((SVA_RUNS + 1))
    echo "PASS SVA: $tag"
}

run_variant() {
    local tag="$1" top="$2"
    shift 2
    mkdir -p "obj_dir/$tag" cov || return 1
    verilator --binary --timing --timescale 1ns/1ps --assert --coverage-user -Wno-fatal \
        --unroll-count 64 -j 4 --top-module "$top" --Mdir "obj_dir/$tag" -o "V$top" "$@" \
        > "build_$tag.log" 2>&1 || { tail -80 "build_$tag.log"; return 1; }
    # shellcheck disable=SC2086
    run_binary "$tag" "./obj_dir/$tag/V$top" ${RUN_ARGS:-}
}

run_asserted() {
    local top="$1"
    shift
    run_variant "$top" "$top" "$@"
}

# rerun <build tag> <run tag> <top> [plusargs...]: run an existing build again,
# for benches that select their stimulus at run time.
rerun() {
    local build="$1" tag="$2" top="$3"
    shift 3
    run_binary "$tag" "./obj_dir/$build/V$top" "$@"
}

# Start every flow from an empty coverage directory, so a stale file from an
# earlier run can never satisfy a cover point.
reset_coverage() {
    rm -rf cov
    mkdir -p cov
}
