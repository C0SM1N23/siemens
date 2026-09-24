#!/usr/bin/env bash
# The official RISC-V ISA tests (riscv-software-src/riscv-tests), rv32ui and
# rv32mi in the physical "p" environment, on the core with bound SVA.
#
# The test sources are fetched at a pinned revision into riscv_tests_ref/ and
# built into riscv_tests/; both are ignored by git. Each test is linked at
# address 0 (riscv_tests.ld) and run twice: nominal memory timing and 40%
# random backpressure. Every test must pass, except the ones listed in
# riscv_tests_expected.json with the reason, which must still fail.
#
#   RISCV_PREFIX=/path/to/riscv-none-elf- bash run_riscv_tests.sh
#
# Needs: a RISC-V GCC (any bare-metal riscv*-elf toolchain), git, verilator,
# python3, network access for the first run. After a build, riscv_tests.do runs
# the same programs in ModelSim.
set -euo pipefail
cd "$(dirname "$0")"
source ./verilator_common.sh

REF="${RISCV_TESTS_DIR:-./riscv_tests_ref}"
REV="${RISCV_TESTS_REV:-793a5ff2d99a6d9fbd91e84c34b9a0437e313b88}"
OUT=riscv_tests

if [ -z "${RISCV_PREFIX:-}" ]; then
    for gcc in "$HOME"/tools/xpack-riscv-none-elf-gcc-*/bin/riscv-none-elf-gcc \
        riscv-none-elf-gcc riscv64-unknown-elf-gcc riscv32-unknown-elf-gcc; do
        if command -v "$gcc" > /dev/null 2>&1; then RISCV_PREFIX="${gcc%gcc}"; break; fi
    done
fi
command -v "${RISCV_PREFIX:-none}gcc" > /dev/null || { echo "FAIL: no RISC-V GCC; set RISCV_PREFIX"; exit 1; }
echo "toolchain: $("${RISCV_PREFIX}gcc" --version | head -1)"

if [ -d "$REF/.git" ]; then
    actual="$(git -C "$REF" rev-parse HEAD)"
    [ "$actual" = "$REV" ] || { echo "FAIL: $REF is at $actual, expected $REV"; exit 1; }
    [ -z "$(git -C "$REF" status --porcelain)" ] || { echo "FAIL: modified reference: $REF"; exit 1; }
else
    echo "fetching riscv-tests ($REV) into $REF"
    git init -q "$REF"
    git -C "$REF" remote add origin https://github.com/riscv-software-src/riscv-tests.git
    git -C "$REF" fetch --depth 1 origin "$REV"
    git -C "$REF" checkout -q --detach FETCH_HEAD
fi
git -C "$REF" submodule update --init --depth 1 env > /dev/null
echo "riscv-tests: $(git -C "$REF" rev-parse --short HEAD), env $(git -C "$REF/env" rev-parse --short HEAD)"

rm -rf "$OUT"
mkdir -p "$OUT"
: > "$OUT/tests.txt"
for suite in rv32ui rv32mi; do
    tests=$(sed -n "/^${suite}_sc_tests = /,/^\$/p" "$REF/isa/$suite/Makefrag" \
        | tr -d '\\' | tr ' \t' '\n\n' | grep -v -e '=' -e '_sc_tests' -e '^$')
    for t in $tests; do
        name="$suite-p-$t"
        "${RISCV_PREFIX}gcc" -march=rv32i_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
            -fvisibility=hidden -nostdlib -nostartfiles -I"$REF/env/p" -I"$REF/isa/macros/scalar" \
            -T riscv_tests.ld "$REF/isa/$suite/$t.S" -o "$OUT/$name.elf"
        "${RISCV_PREFIX}objcopy" -O binary "$OUT/$name.elf" "$OUT/$name.bin"
        python3 -c "import sys; d=open(sys.argv[1],'rb').read(); d+=bytes(-len(d)%4); open(sys.argv[2],'w',newline='\n').write(''.join('%08x\n'%int.from_bytes(d[i:i+4],'little') for i in range(0,len(d),4)))" \
            "$OUT/$name.bin" "$OUT/$name.hex"
        tohost=$("${RISCV_PREFIX}nm" "$OUT/$name.elf" | awk '$3 == "tohost" {print $1}')
        echo "$name $tohost" >> "$OUT/tests.txt"
    done
done
echo "built $(wc -l < "$OUT/tests.txt") tests"

SVA=(../sva/axi_lite_sva.sv ../sva/rv32i_cpu_core_sva.sv ../sva/pic_sva.sv ../sva/rv32i_bind_core_sva.sv)
SRC=(-f rtl.f -f tb_cpu.f +incdir+. ../hdl/rv32i_tb_riscv_tests.v "${SVA[@]}")
mkdir -p cov
for build in rv32i_tb_riscv_tests rv32i_tb_riscv_tests_bp40; do
    extra=()
    [ "$build" = rv32i_tb_riscv_tests_bp40 ] && extra=(-GSTALL_PROB=40)
    mkdir -p "obj_dir/$build"
    verilator --binary --timing --timescale 1ns/1ps --assert --coverage-user -Wno-fatal \
        --unroll-count 64 -j 4 --top-module rv32i_tb_riscv_tests --Mdir "obj_dir/$build" \
        -o Vrv32i_tb_riscv_tests "${SRC[@]}" "${extra[@]}" > "build_$build.log" 2>&1 \
        || { tail -60 "build_$build.log"; exit 1; }
done

python3 - "$OUT/tests.txt" riscv_tests_expected.json <<'PYEOF'
import json, subprocess, sys
tests = [line.split() for line in open(sys.argv[1]) if line.strip()]
expected_fail = json.load(open(sys.argv[2]))
passed, failed, unexpected, stale, pass_list = [], [], [], [], []
for name, tohost in tests:
    verdicts = []
    for build in ("rv32i_tb_riscv_tests", "rv32i_tb_riscv_tests_bp40"):
        run = subprocess.run([f"./obj_dir/{build}/Vrv32i_tb_riscv_tests", f"+test={name}", f"+tohost={tohost}",
                              f"+verilator+coverage+file+cov/{build}_{name}.dat"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
        open(f"run_{build}_{name}.log", "w").write(run.stdout)
        ok = run.returncode == 0 and "ALL TESTS PASSED" in run.stdout and "%Error" not in run.stdout
        verdicts.append(ok)
    ok = all(verdicts)
    detail = next((l for l in open(f"run_rv32i_tb_riscv_tests_{name}.log") if l.startswith("FAIL")), "").strip()
    if name in expected_fail:
        (stale if any(verdicts) else failed).append(name)
        print(f"{'STALE' if any(verdicts) else 'EXPECTED FAIL'}: {name}  {detail}")
    elif ok:
        passed.append(name)
        pass_list.append(f"{name} {tohost}")
        print(f"PASS: {name}")
    else:
        unexpected.append(name)
        print(f"FAIL: {name}  nominal={'pass' if verdicts[0] else 'fail'} bp40={'pass' if verdicts[1] else 'fail'}  {detail}")
open("riscv_tests/pass_list.txt", "w", newline="\n").write("\n".join(pass_list) + "\n")
print(f"RISCV-TESTS SUMMARY: {len(passed)}/{len(tests)} pass at nominal and 40% backpressure; "
      f"{len(failed)} outside the implemented ISA ({', '.join(failed)})")
if unexpected or stale:
    sys.exit(f"RISCV-TESTS FAILED: unexpected {unexpected}, stale expectations {stale}")
print("RISCV-TESTS PASS")
PYEOF
