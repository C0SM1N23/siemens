"""Add up the CPU functional-coverage bins of several runs and gate on the total.

Each run of a bench that binds rv32i_cpu_func_cov prints one "[FCOV] <bin> :
<count> ..." line per bin. The merged gate requires every bin to be reached by
at least one run, except the masked-channel bins: source 5 is enabled in the PIC
but never in mie, so it must never be taken, and those bins must stay at zero.
"""

from collections import OrderedDict
from pathlib import Path
import argparse
import re
import sys

MUST_STAY_ZERO = ("trap irq channel 5 (21)", "PIC ack channel 5")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+")
    parser.add_argument("--report", default="cov/fcov_report.txt")
    args = parser.parse_args()

    totals = OrderedDict()
    for name in args.logs:
        found = 0
        for line in Path(name).read_text(errors="replace").splitlines():
            match = re.match(r"\[FCOV\] (.+?) : (\d+) ", line + " ")
            if match and not match.group(1).startswith("functional coverage"):
                totals[match.group(1)] = totals.get(match.group(1), 0) + int(match.group(2))
                found += 1
        if not found:
            sys.exit(f"FAIL: no [FCOV] lines in {name}")

    lines, missed, fired = [], [], []
    for name, count in totals.items():
        if name in MUST_STAY_ZERO:
            verdict = "zero as required" if count == 0 else "FIRED"
            if count:
                fired.append(name)
        else:
            verdict = "hit" if count else "MISS"
            if not count:
                missed.append(name)
        lines.append(f"{name:42s} {count:9d}  {verdict}")
    reached = len(totals) - len(missed) - len(MUST_STAY_ZERO)
    lines.append(f"{reached}/{len(totals) - len(MUST_STAY_ZERO)} bins reached over "
                 f"{len(args.logs)} runs; {len(MUST_STAY_ZERO)} masked-channel bins stay at zero")
    report = "\n".join(lines) + "\n"
    Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    Path(args.report).write_text(report)
    print(report, end="")
    if missed or fired:
        sys.exit(f"MERGED COVERAGE GATE FAILED: missed {missed}, fired {fired}")
    print("MERGED COVERAGE GATE PASSED")


if __name__ == "__main__":
    main()
