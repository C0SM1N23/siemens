"""Audit every displayed transition against raw VCD and the local RTL clock policy.

Run after waves.do and waveforms.py. Requires the raw traces: this is an audit
of measured timing, not only an integrity check of the delivered figure files.
"""
from pathlib import Path
import bisect
import hashlib
import json
import re
from waveforms import DOCS, VCD

ROOT = DOCS.parents[1]


def main():
    manifest = json.loads((DOCS / 'waves/manifest.json').read_text())
    cache = {}
    rows = []
    violations = []
    reset_sites = 0
    scanned = 0
    for folder in ('cpu/hdl', 'cpu/debug/hdl', 'cpu/debug/sva',
                   'soc/hdl', 'soc/debug/hdl', 'soc/debug/sva'):
        for path in (ROOT / folder).rglob('*'):
            if path.suffix not in ('.v', '.sv', '.vh'):
                continue
            scanned += 1
            source = re.sub(r'/\*.*?\*/|//[^\n]*', '', path.read_text(), flags=re.S)
            for m in re.finditer(r'\bnegedge\s+(\w+)', source):
                signal = m[1]
                if not re.fullmatch(r'(?:rst|reset)\w*', signal):
                    violations.append(f'{path.relative_to(ROOT)}: negedge {signal}')
                else:
                    reset_sites += 1

    for item in manifest:
        name = item['testbench']
        if name not in cache:
            cache[name] = VCD(name)
        vcd = cache[name]
        assert hashlib.sha256(vcd.path.read_bytes()).hexdigest() == item['source_sha256']
        rise = {t for t, _ in vcd.changes('clk', 1)}
        fall = {t for t, _ in vcd.changes('clk', 0) if t > 0}
        reset = {t for t, _ in vcd.changes('rst_n') if t > 0}
        counts = {'posedge': 0, 'posedge_plus_1ns': 0, 'reset_event': 0}
        short_reset = []
        start, stop = item['start_ns'], item['stop_ns']
        clock_edges=[t for t,_ in vcd.changes('clk') if start <= t <= stop]
        if item['file'] != 'cpu_reset_stopped':
            assert all(b-a==5 for a,b in zip(clock_edges,clock_edges[1:])), (item['file'],'nonuniform clock')
        for sig in item['signals']:
            signal = sig['signal']
            width, sequence = vcd.signal(signal)
            assert width == sig['width'], (item['file'], signal, 'width')
            times = [t for t, _ in sequence]
            idx = bisect.bisect_right(times, start) - 1
            expected = [(start, sequence[idx][1] if idx >= 0 else 'x')]
            expected += [(t, value) for t, value in sequence if start < t < stop]
            assert [list(x) for x in expected] == sig['events'], (item['file'], signal, 'events')
            if signal == 'clk':
                continue
            for t, value in sequence:
                if not start < t < stop:
                    continue
                if t in fall:
                    violations.append(f'{item["file"]}: {signal} changes on falling clock at {t} ns')
                if t in rise:
                    counts['posedge'] += 1
                elif t in reset:
                    counts['reset_event'] += 1
                elif t - 1 in rise:
                    counts['posedge_plus_1ns'] += 1
                else:
                    violations.append(f'{item["file"]}: {signal} unexplained transition at {t} ns')
            if width != 1 or signal in ('rst_n', 'clock_run'):
                continue
            for (t, value), (end, _) in zip(sequence, sequence[1:]):
                if start <= t < end <= stop and 0 < end - t < 10:
                    if t in reset or end in reset:
                        short_reset.append({'signal': signal, 'start_ns': t, 'end_ns': end})
                    else:
                        violations.append(f'{item["file"]}: {signal} interval {t}..{end} ns is shorter than a clock')
        rows.append({'waveform': item['file'], 'transitions': counts,
                     'short_intervals_explained_by_reset': short_reset})
        print('PASS' if not violations else 'CHECK', item['file'], counts)
    result = {'rtl_and_test_files_scanned': scanned, 'async_reset_sensitivities': reset_sites,
              'waveform_windows': rows, 'violations': violations}
    out = DOCS / 'waves/timing_audit.json'
    out.write_text(json.dumps(result, indent=2) + '\n')
    if violations:
        raise SystemExit('\n'.join(violations))
    print(f'PASS: {scanned} RTL/test files; {len(rows)} exact VCD windows; no falling-clock data transitions')


if __name__ == '__main__':
    main()
