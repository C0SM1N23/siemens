"""Merge the cover-property counts of every Verilator run and gate on them.

Each run writes cov/<tag>.dat. A cover statement is identified by its source
file and line, so one statement bound into several instances counts once: it is
reached when any instance in any run reaches it. Every statement present in the
databases must be reached, except the ones waived for this flow in
cover_waivers.json, each with its reason. The merged table is written to
cov/cover_report.txt.
"""

from collections import defaultdict
from pathlib import Path
import argparse
import json
import re
import sys


def records(path):
    """Yield (fields, count) for every point in one coverage database."""
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"C '(.*)' (\d+)$", line)
        if not match:
            continue
        fields = {}
        for part in match.group(1).split("\x01"):
            if "\x02" in part:
                key, value = part.split("\x02", 1)
                fields[key] = value
        yield fields, int(match.group(2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("flow", help="label printed with the verdict (cpu or soc)")
    parser.add_argument("--dir", default="cov")
    parser.add_argument("--waivers", default=str(Path(__file__).with_name("cover_waivers.json")))
    args = parser.parse_args()

    files = sorted(Path(args.dir).glob("*.dat"))
    if not files:
        sys.exit(f"FAIL: no coverage databases in {args.dir}")
    waivers = {}
    if Path(args.waivers).exists():
        waivers = json.loads(Path(args.waivers).read_text()).get(args.flow, {})

    hits = defaultdict(int)        # (file, line) -> total count
    names = {}                     # (file, line) -> cover label
    instances = defaultdict(set)   # (file, line) -> instances that reached it
    every = defaultdict(set)       # (file, line) -> every instance seen
    runs = defaultdict(set)        # (file, line) -> runs that reached it
    for path in files:
        for fields, count in records(path):
            if fields.get("t") != "user":
                continue
            key = (Path(fields.get("f", "?")).name, int(fields.get("l", 0)))
            names[key] = fields.get("o", "cover")
            hierarchy = fields.get("h", "?")
            every[key].add(hierarchy)
            hits[key] += count
            if count:
                instances[key].add(hierarchy)
                runs[key].add(path.stem)

    lines = [f"{'cover':38s} {'source':28s} {'hits':>9s} {'instances':>9s} {'runs':>5s}"]
    missing = []
    for key in sorted(hits):
        label = f"{key[0]}:{key[1]}"
        waived = waivers.get(label)
        state = "" if hits[key] else ("  waived: " + waived if waived else "  NOT REACHED")
        lines.append(f"{names[key]:38s} {label:28s} {hits[key]:9d} "
                     f"{len(instances[key]):4d}/{len(every[key]):<4d} {len(runs[key]):5d}{state}")
        if not hits[key] and not waived:
            missing.append(label)
    stale = [label for label in waivers if label not in {f"{k[0]}:{k[1]}" for k in hits if not hits[k]}]
    report = "\n".join(lines) + "\n"
    (Path(args.dir) / "cover_report.txt").write_text(report)
    print(report, end="")
    reached = sum(1 for key in hits if hits[key])
    print(f"COVER SUMMARY: {args.flow}, {reached}/{len(hits)} cover statements reached "
          f"over {len(files)} runs")
    if stale:
        print("Stale waivers (the statement is reached or no longer exists):", ", ".join(stale))
    if missing or stale:
        sys.exit(f"COVER GATE FAILED: {len(missing)} unreached, {len(stale)} stale waiver(s)")
    print(f"COVER GATE PASSED: {args.flow}")


if __name__ == "__main__":
    main()
