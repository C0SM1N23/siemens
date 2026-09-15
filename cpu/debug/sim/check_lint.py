"""Run RTL lint; reject new diagnostics and stale upstream findings."""

from collections import Counter
from pathlib import Path
import argparse
import json
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("block", choices=["cpu", "soc"])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    cwd = root / args.block / "debug/sim"
    top, filelist = ("rv32i_cpu_top", "rtl.f") if args.block == "cpu" else ("soc_top", "soc_rtl.f")
    command = ["verilator", "--lint-only", "-Wall", "-Wno-fatal",
               "-Wno-UNUSEDSIGNAL", "-Wno-PINCONNECTEMPTY", "-Wno-EOFNEWLINE", "-Wno-DECLFILENAME",
               "--top-module", top, "-f", filelist]
    result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (cwd / "lint_audit.log").write_text(result.stdout)
    actual = Counter()
    for line in result.stdout.splitlines():
        if line.startswith("%Warning"):
            match = re.match(r"%Warning-(\w+): (?:\.\./)*([^:]+):(\d+):(\d+):", line)
            if not match:
                raise SystemExit(f"FAIL: unparsed lint diagnostic: {line}")
            actual[" ".join(match.groups())] += 1
    expected = Counter(json.loads((root / "soc/debug/sim/known_lint.json").read_text())) if args.block == "soc" else Counter()
    if result.returncode or "%Error" in result.stdout or actual != expected:
        print(result.stdout)
        print("Unexpected:", dict(actual - expected))
        print("Stale:", dict(expected - actual))
        raise SystemExit(1)
    print(f"LINT PASS: {args.block}, {sum(expected.values())} documented upstream diagnostics")


if __name__ == "__main__":
    main()
