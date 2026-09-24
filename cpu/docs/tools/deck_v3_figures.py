"""Figures used only by the v3 presentations; the specification figures are not modified.

Needs the VCD traces written by presentations/src/capture_traces.do (cpu/debug/sim)
and presentations/src/capture_waves.do (soc/debug/sim). Every value drawn in the
end-to-end excerpts and waveforms is read from those traces or from the generated
reference vectors, never typed in.
"""
from pathlib import Path
from html import escape
import math
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pymupdf as fitz
from waveforms import VCD

DOCS = Path(__file__).resolve().parents[1]
SIM = DOCS.parent / 'debug/sim'
OUT = DOCS / 'presentations/assets'
OUT.mkdir(parents=True, exist_ok=True)
INK, ACC, MUT, LIGHT, GOLD = '#173442', '#006B75', '#526772', '#EDF5F5', '#A35B17'
SANS, MONO = 'Arial, Helvetica, sans-serif', 'Consolas, DejaVu Sans Mono, monospace'


class Svg:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
                  '<rect width="100%" height="100%" fill="white"/>']

    def rect(self, x, y, w, h, fill=LIGHT, stroke=ACC, width=2, rx=8, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ''
        self.s.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{width}"{d}/>')

    def text(self, x, y, lines, size=24, color=INK, anchor='middle', bold=False, family=SANS, gap=8):
        if isinstance(lines, str):
            lines = [lines]
        for i, line in enumerate(lines):
            self.s.append(f'<text x="{x}" y="{y + i * (size + gap)}" text-anchor="{anchor}" font-family="{family}" '
                          f'font-size="{size}" font-weight="{700 if bold else 400}" fill="{color}" xml:space="preserve">{escape(line)}</text>')

    def box(self, x, y, w, h, title, sub=(), tsize=28, ssize=22, fill=LIGHT, stroke=ACC, tcolor=INK, scolor=MUT):
        self.rect(x, y, w, h, fill, stroke)
        lines = len(sub)
        block = tsize + lines * (ssize + 8)
        top = y + (h - block) / 2 + tsize * 0.8
        self.text(x + w / 2, top, title, tsize, tcolor, bold=True)
        if sub:
            self.text(x + w / 2, top + tsize * 0.35 + ssize + 4, list(sub), ssize, scolor)

    def arrow(self, pts, label=None, lx=None, ly=None, size=21, anchor='middle', dash=False, color=ACC, head=True, width=3):
        coords = ' '.join(f'{x},{y}' for x, y in pts)
        d = ' stroke-dasharray="8 6"' if dash else ''
        self.s.append(f'<polyline points="{coords}" fill="none" stroke="white" stroke-width="9"/>')
        self.s.append(f'<polyline points="{coords}" fill="none" stroke="{color}" stroke-width="{width}"{d}/>')
        if head:
            x, y = pts[-1]
            px, py = pts[-2]
            a = math.atan2(y - py, x - px)
            k = 1 + (width - 3) * 0.15
            bx, by = x - 14 * k * math.cos(a), y - 14 * k * math.sin(a)
            self.s.append(f'<polygon points="{x},{y} {bx + 6.5 * k * math.sin(a)},{by - 6.5 * k * math.cos(a)} '
                          f'{bx - 6.5 * k * math.sin(a)},{by + 6.5 * k * math.cos(a)}" fill="{color}"/>')
        if label:
            self.text(lx, ly, label, size, INK, anchor)

    def save(self, name, scale=2.0):
        path = OUT / (name + '.svg')
        path.write_text('\n'.join(self.s + ['</svg>']), encoding='utf-8')
        pdf = fitz.open('pdf', fitz.open(path).convert_to_pdf())
        pdf[0].get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False).save(OUT / (name + '.png'))


def fabric(d, x, y, w, h, lines, vertical=False):
    """Interconnect element (decoder, arbiter, bridge): lighter than a functional block."""
    d.rect(x, y, w, h, '#F4F7F8', '#8FA7AD', 2, 6)
    if vertical:
        cx, cy = x + w / 2, y + h / 2
        for i, (line, size, bold) in enumerate(lines):
            dx = (i - (len(lines) - 1) / 2) * (size + 8)
            d.s.append(f'<text transform="rotate(-90 {cx + dx + size * 0.35} {cy})" x="{cx + dx + size * 0.35}" y="{cy}" '
                       f'text-anchor="middle" font-family="{SANS}" font-size="{size}" font-weight="{700 if bold else 400}" '
                       f'fill="{INK if bold else MUT}">{escape(line)}</text>')
    else:
        top = y + h / 2 - (len(lines) - 1) * 13 + 7
        for i, (line, size, bold) in enumerate(lines):
            d.text(x + w / 2, top + i * 27, line, size, INK if bold else MUT, bold=bold)


def soc_context(highlight):
    """soc_top.v: every block, decoder, arbiter and wire drawn here exists there with this connection."""
    d = Svg(1320, 870)
    hi = dict(fill=ACC, stroke=ACC, tcolor='white', scolor='#D9EEF0')
    d.box(30, 20, 290, 95, 'Instruction memory', ['read-only RAM'], 27, 22)
    fabric(d, 30, 160, 290, 58, [('ibus decoder', 23, True)])
    d.box(30, 265, 290, 170, 'RV32I CPU', ['3-stage pipeline', 'ibus + dbus masters'], 29, 22, **(hi if highlight == 'cpu' else {}))
    d.box(30, 575, 290, 215, 'PIC', ['16 sources · 4 bands', 'src 0–3: DMA', 'src 4: SRAM · src 7: timer'], 29, 22,
          **(hi if highlight == 'pic' else {}))
    fabric(d, 420, 20, 70, 780, [('CPU bus decoder', 24, True), ('5 windows', 21, False)], vertical=True)
    fabric(d, 670, 20, 200, 58, [('arbiter 2:1', 23, True)])
    d.box(580, 112, 380, 88, 'Data memory', ['shared by CPU and DMA'], 27, 22)
    d.box(580, 245, 380, 115, 'Dual-port SRAM', ['port A: CPU · port B: DMA'], 27, 22)
    d.box(580, 410, 380, 100, 'Machine timer', ['64-bit mtime · compare IRQ'], 27, 22)
    d.box(580, 560, 380, 140, 'DMA', ['4 channels · register slave', 'AXI4 burst master'], 27, 22)
    fabric(d, 1070, 20, 70, 350, [('DMA decoder', 24, True), ('2 windows', 21, False)], vertical=True)
    fabric(d, 1010, 590, 290, 90, [('AXI4 → AXI4-Lite', 23, True), ('bridge', 21, False)])
    # Wires that belong to the presented block are thick and dark; the rest of the fabric is context.
    cpu, pic = highlight == 'cpu', highlight == 'pic'
    def wire(pts, on, label=None, lx=None, ly=None, size=21, anchor='middle', dash=False, head=True):
        d.arrow(pts, label, lx, ly, size, anchor, dash, color=INK if on else '#7FA3A9', head=head, width=5 if on else 3)
    # CPU side
    wire([(175, 265), (175, 218)], cpu, 'ibus', 190, 250, 21, 'start')
    wire([(175, 160), (175, 115)], False)
    wire([(320, 350), (420, 350)], cpu, 'dbus', 370, 336, 21)
    wire([(490, 49), (670, 49)], False)
    wire([(770, 78), (770, 112)], False)
    wire([(490, 300), (580, 300)], False, 'port A', 535, 288, 21)
    wire([(490, 455), (580, 455)], False)
    wire([(490, 610), (580, 610)], False)
    wire([(420, 690), (320, 690)], pic, 'registers', 370, 678, 21)
    # DMA side: master -> bridge -> DMA decoder -> arbiter / SRAM port B
    wire([(960, 635), (1010, 635)], False)
    wire([(1105, 590), (1105, 370)], False)
    wire([(1070, 49), (870, 49)], False)
    wire([(1070, 300), (960, 300)], False, 'port B', 1015, 288, 21)
    # CPU <-> PIC link
    wire([(44, 575), (44, 435)], True)
    wire([(306, 435), (306, 575)], True)
    d.text(175, 492, '↑ IRQ · vector · pending', 20)
    d.text(175, 532, '↓ mask · claim · EOI', 20)
    # interrupt lines into the PIC, drawn dashed, collected right of the slaves
    for y in (340, 490, 680):
        wire([(960, y), (990, y)], pic, head=False, dash=True)
    wire([(990, 340), (990, 840), (175, 840), (175, 790)], pic, 'interrupt lines: SRAM · timer · DMA ×4', 640, 826, 21, dash=True)
    d.save('soc_context_v3_' + highlight)


def stage(d, x, y, w, h, title):
    d.rect(x, y, w, h, '#F4F7F8', '#CEDADD', 2, 10)
    d.text(x + 18, y + 38, title, 25, MUT, 'start', True)


def cpu_architecture():
    """rv32i_cpu_top.v as five functional blocks; the pipeline reads left to right."""
    d = Svg(1780, 640)
    stage(d, 10, 118, 370, 512, 'S1 · FETCH')
    stage(d, 440, 118, 900, 512, 'S2 · DECODE + EXECUTE')
    stage(d, 1400, 118, 190, 302, 'S3')
    d.box(40, 8, 310, 84, 'Instruction memory', ['instruction bus'], 25, 20)
    d.box(960, 8, 360, 84, 'Data memory · devices', ['data bus'], 25, 20)
    d.box(40, 170, 310, 170, 'Fetch unit', ['PC · one read in flight', 'skid register', 'wrong-path drain'])
    d.box(40, 450, 310, 160, 'Branch predictor', ['direct-mapped, 128 entries', '1-bit BHT · BTB · 8-entry RAS'], ssize=21)
    d.box(470, 170, 360, 170, 'Decode + registers', ['control · immediates', 'x0–x31, 2 read ports', 'S3 → S2 forwarding'])
    d.box(930, 170, 380, 170, 'Execute', ['ALU · branch unit', 'load / store unit', 'exception unit'])
    d.box(470, 450, 840, 160, 'Control + CSRs', ['hazard unit: stall · flush · one redirect per instruction',
                                                 'CSR file · trap-kind stack · 64-bit counters'])
    d.box(1415, 170, 160, 170, 'Write-back', ['ALU / CSR', 'load · PC+4'], 25, 20)
    d.box(1630, 450, 140, 160, 'PIC', ['16 sources'], 28, 21)
    for x, label in ((395, 'IF/DX'), (1355, 'DX/WB')):
        d.rect(x, 170, 22, 170, '#D4E3E5', ACC, 2, 3)
        d.text(x + 11, 160, label, 19, MUT, bold=True)
    # buses to the memories, clear of the stage titles
    d.arrow([(215, 170), (215, 92)])
    d.arrow([(310, 92), (310, 170)])
    d.arrow([(1030, 170), (1030, 92)])
    d.arrow([(1260, 92), (1260, 170)])
    # main path
    d.arrow([(350, 255), (395, 255)], head=False)
    d.arrow([(417, 255), (470, 255)])
    d.arrow([(830, 255), (930, 255)], 'operands', 880, 240, 20)
    d.arrow([(1310, 255), (1355, 255)], head=False)
    d.arrow([(1377, 255), (1415, 255)])
    # write-back and forwarding into S2
    d.arrow([(1495, 340), (1495, 395), (650, 395), (650, 340)], 'register write · forward', 850, 385, 20)
    # predictor lookup / update, redirect back to fetch
    d.arrow([(90, 340), (90, 450)], 'lookup', 80, 402, 20, 'end')
    d.arrow([(170, 450), (170, 340)], 'taken · target', 180, 402, 20, 'start')
    d.arrow([(470, 560), (350, 560)], 'update', 410, 550, 20)
    d.arrow([(470, 490), (425, 490), (425, 415), (335, 415), (335, 340)], 'redirect', 380, 405, 20, dash=True)
    # branch outcome and load/store progress reach control, which stalls or squashes
    d.arrow([(1200, 340), (1200, 450)], 'branch · LSU status', 1188, 432, 20, 'end')
    d.arrow([(700, 340), (700, 450)], 'decoded op', 688, 432, 20, 'end')
    d.arrow([(980, 450), (980, 340)], 'CSR value', 968, 432, 20, 'end')
    # control drives the pipeline registers: IF/DX holds or takes a bubble, DX/WB advances or is squashed
    d.arrow([(490, 450), (490, 360), (406, 360), (406, 340)], 'hold / bubble', 500, 405, 20, 'start', dash=True)
    d.arrow([(1290, 450), (1290, 360), (1366, 360), (1366, 340)], 'advance / squash', 1302, 442, 20, 'start', dash=True)
    # PIC link
    d.arrow([(1630, 495), (1310, 495)], 'IRQ · vector · pending', 1470, 485, 20)
    d.arrow([(1310, 575), (1630, 575)], 'mask · claim · EOI', 1470, 565, 20)
    d.save('cpu_arch_v3')


def pic_architecture():
    """pic.v functional groups: source -> key -> resolver -> CPU, with the nesting stack below."""
    d = Svg(1780, 610)
    d.text(160, 36, 'irq_src · 16 lines', 22, MUT)
    d.box(20, 110, 330, 190, 'Source conditioning', ['level / edge per source', 'HW line OR keyed SW request', 'INT_ENABLE'])
    d.box(470, 110, 400, 190, 'Priority key', ['10-bit key: urgency ·', 'priority in band · inverted ID', 'deadline counter → escalation'])
    d.box(990, 110, 390, 190, 'Resolver + offer', ['highest eligible key', 'registered IRQ + 4-bit vector'])
    d.box(1500, 110, 260, 190, 'CPU', ['claim · EOI', 'mask'], 28, 21)
    d.box(20, 400, 330, 190, 'Register map', ['AXI4-Lite slave', 'configuration · status'])
    d.box(470, 400, 910, 190, 'Nesting stack', ['16 levels, limit NEST_MAX · claim pushes ID + key · EOI pops',
                                                 'active mask · spurious check at claim'])
    d.arrow([(160, 50), (160, 110)])
    d.arrow([(350, 205), (470, 205)], 'requests', 410, 192, 20)
    d.arrow([(870, 205), (990, 205)], 'keys', 930, 192, 20)
    d.arrow([(1380, 175), (1500, 175)], 'IRQ · vector', 1440, 162, 20)
    d.arrow([(1500, 250), (1380, 250)], 'CPU mask', 1440, 237, 20)
    d.arrow([(1630, 300), (1630, 495), (1380, 495)], 'claim · EOI', 1645, 445, 20, 'start')
    d.arrow([(1185, 400), (1185, 300)], 'top key · depth < limit', 1170, 340, 20, 'end')
    # the claim pushes the offered ID and that source's key
    d.arrow([(840, 300), (840, 400)], 'keys', 852, 340, 20, 'start')
    d.arrow([(1320, 300), (1320, 400)], 'claimed ID', 1332, 340, 20, 'start')
    d.arrow([(760, 400), (760, 300)], 'active sources', 745, 340, 20, 'end')
    d.arrow([(185, 400), (185, 300)], 'configuration', 170, 340, 20, 'end')
    d.arrow([(470, 540), (350, 540)], 'status', 410, 528, 20)
    d.arrow([(350, 280), (420, 280), (420, 470), (470, 470)], 'spurious check', 428, 340, 20, 'start')
    d.arrow([(300, 300), (300, 375), (1700, 375), (1700, 300)], 'pending mask → mip', 1500, 367, 20, dash=True)
    d.save('pic_arch_v3')


def disasm(word):
    """Only the formats that appear in the excerpt: loads and stores relative to x31."""
    op, rd, f3, rs1, rs2 = word & 127, (word >> 7) & 31, (word >> 12) & 7, (word >> 15) & 31, (word >> 20) & 31
    if op == 0x03:
        imm = (word >> 20) - (4096 if word >> 31 else 0)
        return f'{ {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}[f3]:<4} x{rd}, {imm}(x{rs1})'
    if op == 0x23:
        imm = ((word >> 25) << 5) | ((word >> 7) & 31)
        return f'{ {0: "sb", 1: "sh", 2: "sw"}[f3]:<4} x{rs2}, {imm}(x{rs1})'
    raise ValueError(f'{word:08x}')


def isa_excerpt():
    code = [int(x, 16) for x in (SIM / 'program_isa.hex').read_text().split()]
    trace = [(int(x[:8], 16), int(x[8:16], 16), int(x[16:], 16)) for x in (SIM / 'program_isa_trace.hex').read_text().split()]
    # First byte store into lane 1 of the data window, then the three loads that read it back.
    start = next(k for k, (pc, _, _) in enumerate(trace) if code[pc // 4] & 0x707F == 0x0023 and (code[pc // 4] >> 7) & 31 == 1)
    steps = list(range(start, start + 4))
    vcd = VCD('rv32i_tb_isa')
    observed = {}
    # The bench compares on the posedge where dxwb_valid_q is high; step is the index before it increments.
    for t, _ in vcd.changes('clk', 1):
        k = vcd.value('step', t - 0.001)
        if k in steps and k not in observed and vcd.value('dut.dxwb_valid_q', t - 0.001) == 1:
            observed[k] = (vcd.value('dut.dxwb_pc4_q', t - 0.001) - 4, vcd.value('actual_rd', t - 0.001),
                           vcd.value('actual_value', t - 0.001))
    rows = []
    for k in steps:
        pc, rd, value = trace[k]
        got = observed[k]
        assert got == (pc, rd, value), (k, got, trace[k])
        rows.append((k, pc, disasm(code[pc // 4]), rd, value, got))
    return rows, len(trace)


def cpu_end_to_end():
    rows, steps = isa_excerpt()
    d = Svg(1180, 760)
    d.box(20, 20, 330, 130, 'Golden ISA model', ['isa_reference.py (Python)', 'independent of the RTL'], 27, 21)
    d.box(430, 20, 300, 130, 'Program', [f'{len((SIM / "program_isa.hex").read_text().split()):,} words', 'instruction memory'], 27, 21)
    d.box(820, 20, 340, 130, 'RV32I CPU', ['memories with delay', 'and backpressure'], 27, 21, fill=ACC, stroke=ACC, tcolor='white', scolor='#D9EEF0')
    d.arrow([(350, 85), (430, 85)])
    d.arrow([(730, 85), (820, 85)])
    d.box(20, 250, 330, 130, 'Expected trace', [f'{steps:,} steps: PC · rd · value', '+ 256 memory words'], 27, 21)
    d.box(820, 250, 340, 130, 'Write-back', ['PC · rd · value', 'at every retirement'], 27, 21)
    d.arrow([(185, 150), (185, 250)])
    d.arrow([(990, 150), (990, 250)])
    d.box(430, 250, 300, 130, 'Compare', ['every step', 'then all memory words'], 27, 21, fill='white')
    d.arrow([(350, 315), (430, 315)])
    d.arrow([(820, 315), (730, 315)])
    d.rect(20, 440, 1140, 300, '#F7FAFA', '#CEDADD', 2, 10)
    d.text(44, 482, 'Nominal run: a byte store, then three loads of the same word', 22, MUT, 'start', True)
    cols = (44, 150, 300, 640, 910)
    heads = ('step', 'PC', 'instruction', 'model', 'CPU')
    for x, h in zip(cols, heads):
        d.text(x, 530, h, 21, MUT, 'start', True)
    d.s.append(f'<line x1="40" y1="544" x2="1140" y2="544" stroke="#CEDADD" stroke-width="2"/>')
    for i, (k, pc, asm, rd, value, got) in enumerate(rows):
        y = 584 + i * 42
        fmt = (lambda r, v: f'x{r} = {v:08X}' if r else 'no write')
        d.text(cols[0], y, str(k), 22, INK, 'start', family=MONO)
        d.text(cols[1], y, f'{pc:08X}', 22, INK, 'start', family=MONO)
        d.text(cols[2], y, asm, 22, INK, 'start', family=MONO)
        d.text(cols[3], y, fmt(rd, value), 22, INK, 'start', family=MONO)
        d.text(cols[4], y, fmt(got[1], got[2]), 22, ACC, 'start', True, MONO)
        d.text(1130, y, '✓', 24, ACC, 'end', True)
    d.save('cpu_e2e_v3')


def pic_excerpt(case):
    words = [int(x, 16) for x in (SIM / 'pic_reference.hex').read_text().split()]
    base = case * 22
    configs, bands, enable, mask, sources, offer, pending = (words[base:base + 16], words[base + 16], words[base + 17],
                                                             words[base + 18], words[base + 19], words[base + 20], words[base + 21])
    vcd = VCD('pic_tb_reference')
    # The bench drives sources and mask, waits four edges and checks at posedge + 1 ns, in the
    # same step that starts the next case: sample half a nanosecond after that last edge.
    t0 = next(t for t, v in vcd.changes('test_index') if v == case)
    t_src = next(t for t, v in vcd.changes('irq_src') if t > t0 and v == sources)
    t = t_src + 39.5
    got = (vcd.value('cpu_irq', t), vcd.value('cpu_irq_vec', t), vcd.value('pending', t))
    assert vcd.value('cpu_mask', t) == mask and vcd.value('irq_src', t) == sources
    assert got == (offer >> 4, offer & 15, pending), (got, offer, pending)
    rows = []
    for s in range(16):
        if sources & enable & (1 << s):
            band = (configs[s] >> 1) & 3
            rows.append((s, band, (bands >> (band * 2)) & 3, (configs[s] >> 4) & 15, bool(mask & (1 << s))))
    return rows, bands, offer & 15, pending, got


def pic_end_to_end(case=72):
    rows, bands, winner, pending, got = pic_excerpt(case)
    count = int((SIM / 'pic_reference_count.vh').read_text().split('=')[1].strip(' ;\n'))
    d = Svg(1180, 800)
    d.box(20, 20, 330, 130, 'Golden priority model', ['pic_reference.py (Python)', 'independent of the RTL'], 26, 21)
    d.box(430, 20, 300, 130, 'Register writes', ['18 per case, over AXI', 'then sources + CPU mask'], 27, 21)
    d.box(820, 20, 340, 130, 'PIC', ['registered offer', 'one cycle after the request'], 27, 21, fill=ACC, stroke=ACC, tcolor='white', scolor='#D9EEF0')
    d.arrow([(350, 85), (430, 85)])
    d.arrow([(730, 85), (820, 85)])
    d.box(20, 250, 330, 130, 'Expected result', [f'{count} cases: winner', '+ pending mask'], 27, 21)
    d.box(820, 250, 340, 130, 'Observed', ['IRQ · vector · pending', 'sampled 4 cycles later'], 27, 21)
    d.arrow([(185, 150), (185, 250)])
    d.arrow([(990, 150), (990, 250)])
    d.box(430, 250, 300, 130, 'Compare', ['every case'], 27, 21, fill='white')
    d.arrow([(350, 315), (430, 315)])
    d.arrow([(820, 315), (730, 315)])
    d.rect(20, 440, 1140, 340, '#F7FAFA', '#CEDADD', 2, 10)
    urg = ' · '.join(f'band {b}: {(bands >> (2 * b)) & 3}' for b in range(4))
    d.text(44, 482, f'Case {case}: BAND_CONFIG = 0x{bands:02X}  →  urgency  {urg}', 22, MUT, 'start', True)
    cols = (44, 180, 300, 450, 600, 760)
    for x, h in zip(cols, ('source', 'band', 'urgency', 'priority', 'CPU mask', 'result')):
        d.text(x, 530, h, 21, MUT, 'start', True)
    d.s.append(f'<line x1="40" y1="544" x2="1140" y2="544" stroke="#CEDADD" stroke-width="2"/>')
    y = 580
    for s, band, urgency, prio, allowed in rows:
        note = 'winner' if s == winner else ('pending, not offered' if not allowed else '')
        color = ACC if s == winner else INK
        for x, v in zip(cols[:5], (str(s), str(band), str(urgency), str(prio), 'on' if allowed else 'off')):
            d.text(x, y, v, 22, color, 'start', s == winner, MONO)
        d.text(cols[5], y, note, 22, color, 'start', s == winner)
        y += 38
    d.text(44, y + 14, f'model: offer {winner} · pending {pending:04X}', 22, INK, 'start', family=MONO)
    d.text(560, y + 14, f'PIC: offer {got[1]} · pending {got[2]:04X}', 22, ACC, 'start', True, MONO)
    d.text(1130, y + 14, '✓', 24, ACC, 'end', True)
    d.save('pic_e2e_v3')


def software_flow(kind):
    d = Svg(560, 860)
    steps = ([('Configure', ['mtvec: handler address', 'mie: PIC sources allowed']),
              ('Enable', ['mstatus.MIE = 1', 'taken between instructions']),
              ('Enter the handler', ['hardware saves mepc,', 'mcause, mtval; clears MIE;', 'claim to the PIC']),
              ('Return', ['MRET jumps to mepc', 'EOI to the PIC'])] if kind == 'cpu' else
             [('Configure', ['SRCx_CONFIG · BAND_CONFIG', 'ESCALATION_CFG · NEST_MAX']),
              ('Enable / request', ['INT_ENABLE · CPU mask', 'HW line or keyed SW write']),
              ('Claim', ['stack saves ID + key', 'ACTIVE_VEC names the source']),
              ('Complete', ['EOI restores the outer context', 'W1C clears logged events'])])
    for i, (title, lines) in enumerate(steps):
        y = 10 + i * 215
        d.box(20, y, 520, 165, f'{i + 1} · {title}', lines, 27, 21)
        if i < 3:
            d.arrow([(280, y + 165), (280, y + 215)])
    d.save(kind + '_flow_v3')


def split_wave(name, slug, rows, windows, markers, width=10.2):
    """Measured signals in several time windows of one run; each window keeps its own time axis."""
    vcd = VCD(name)
    spans = [b - a for a, b in windows]
    n = len(rows)
    fig = plt.figure(figsize=(width, 0.44 * n + 0.95), dpi=160)
    left, right, gap = 0.235, 0.99, 0.026
    usable = right - left - gap * (len(windows) - 1)
    boxes, x0 = [], left
    for span in spans:
        boxes.append((x0, usable * span / sum(spans)))
        x0 += usable * span / sum(spans) + gap
    top_y = n * 1.15
    edges = [t for t, _ in vcd.changes('clk', 1)]
    for w, ((start, stop), (bx, bw)) in enumerate(zip(windows, boxes)):
        ax = fig.add_axes([bx, 0.14, bw, 0.83])
        for i, (sig, label) in enumerate(rows):
            width_bits, seq = vcd.signal(sig)
            initial = 'x'
            for t, v in seq:
                if t <= start:
                    initial = v
                else:
                    break
            pts = [(start, initial)] + [(t, v) for t, v in seq if start < t < stop] + [(stop, None)]
            y = (n - 1 - i) * 1.15
            color = '#596A76' if sig == 'clk' else '#005F73'
            if width_bits == 1:
                xs = [p[0] for p in pts[:-1]] + [stop]
                ys = [y + (0.62 if p[1] == '1' else 0) for p in pts[:-1]]
                ax.step(xs, ys + [ys[-1]], where='post', color=color, lw=1.7)
            else:
                for (t, v), (t2, _) in zip(pts, pts[1:]):
                    ax.plot([t, t2], [y, y], color=color, lw=1.25)
                    ax.plot([t, t2], [y + .62, y + .62], color=color, lw=1.25)
                    if t > start:
                        ax.plot([t, t], [y, y + .62], color=color, lw=1)
                    if t2 - t >= 9.5:
                        ax.text((t + t2) / 2, y + .31, f'{int(v, 2):X}' if set(v) <= set('01') else v, ha='center',
                                va='center', fontsize=12, color='#142D3B', fontfamily='DejaVu Sans Mono')
            if w == 0:
                fig.text(bx - 0.008, 0.14 + 0.83 * (y + .31 + .35) / (top_y + 1.05), label, ha='right', va='center',
                         fontsize=12.5, fontfamily='DejaVu Sans Mono', color='#142D3B')
        for t in edges:
            if start <= t <= stop:
                ax.axvline(t, color='#D8E2E6', lw=.55, zorder=0)
        for t, label in markers:
            if start <= t <= stop:
                ax.axvline(t, color='#BB6B21', lw=1.1, ls='--', zorder=1)
                ax.text(t, top_y + .12, label, ha='center', va='bottom', fontsize=14, color='#905013', fontweight='bold')
                ax.annotate('', xy=(t, top_y - .43), xytext=(t, top_y + .06),
                            arrowprops={'arrowstyle': '-|>', 'color': '#BB6B21', 'lw': 1})
        ax.set_xlim(start, stop)
        ax.set_ylim(-.35, top_y + .7)
        ax.set_yticks([])
        # Tick spacing from the panel width, so four-digit times never touch.
        width_pt = bw * fig.get_figwidth() * 72
        step = next(s for s in (10, 20, 40, 50, 100, 200) if s / (stop - start) * width_pt >= 42)
        ax.set_xticks([t for t in range(int(math.ceil(start / step) * step), int(stop) + 1, step)])
        ax.tick_params(axis='x', labelsize=11, colors='#52626B')
        for sp in ('left', 'right', 'top'):
            ax.spines[sp].set_visible(False)
        ax.spines['bottom'].set_color('#ADBCC4')
        if w:
            fig.text(bx - gap / 2, 0.14, '//', ha='center', va='center', fontsize=13, color='#7C8D96')
    fig.text((left + right) / 2, 0.03, 'Time (ns) · buses: hex · grid: posedge clk', ha='center', fontsize=11.5, color='#52626B')
    for ext in ('svg', 'png'):
        fig.savefig(OUT / f'{slug}.{ext}', facecolor='white')
    plt.close(fig)


def cpu_nesting_wave():
    v = VCD('soc_tb_pic_nest')
    claims = [t for t, _ in v.changes('dut.cpu_inst.cpu_irq_ack_o', 1)]
    eois = [t for t, _ in v.changes('dut.cpu_inst.cpu_irq_eoi_o', 1)]
    assert len(claims) == 2 and len(eois) == 2
    assert [v.value('dut.pic_inst.cpu_irq_vec_o', t - 1) for t in claims] == [9, 8]
    assert [x for _, x in v.changes('dut.pic_inst.depth')][1:] == [1, 2, 1, 0]
    mie_on = max(t for t, x in v.changes('dut.cpu_inst.csr_file_inst.mstatus_mie_q') if x == 1 and t < claims[1])
    windows = [(claims[0] - 30, claims[0] + 40), (mie_on - 30, claims[1] + 40), (eois[0] - 20, eois[0] + 30), (eois[1] - 20, eois[1] + 30)]
    rows = [('clk', 'clk'),
            ('dut.pic_inst.cpu_irq_o', 'cpu_irq_i'),
            ('dut.pic_inst.cpu_irq_vec_o', 'cpu_irq_vec_i [3:0]'),
            ('dut.cpu_inst.csr_file_inst.mstatus_mie_q', 'mstatus.MIE'),
            ('dut.cpu_inst.cpu_irq_ack_o', 'claim'),
            ('dut.cpu_inst.cpu_irq_eoi_o', 'EOI'),
            ('dut.cpu_inst.cpu_in_trap_o', 'cpu_in_trap_o'),
            ('dut.cpu_inst.trap_depth_q', 'CPU trap stack depth'),
            ('dut.pic_inst.depth', 'PIC stack depth'),
            ('dut.pic_inst.active', 'PIC active [15:0]')]
    split_wave('soc_tb_pic_nest', 'cpu_nesting_v3', rows, windows,
               [(claims[0], '1'), (claims[1], '2'), (eois[0], '3'), (eois[1], '4')])
    return claims, eois, mie_on


def pic_escalation_wave():
    v = VCD('soc_tb_pic_escalate')
    claims = [t for t, _ in v.changes('dut.cpu_inst.cpu_irq_ack_o', 1)]
    eois = [t for t, _ in v.changes('dut.cpu_inst.cpu_irq_eoi_o', 1)]
    esc = next(t for t, x in v.changes('dut.pic_inst.escalated') if x == 0x200)
    both = next(t for t, x in v.changes('dut.pic_inst.req') if x == 0x300)
    assert [v.value('dut.pic_inst.cpu_irq_vec_o', t - 1) for t in claims] == [9, 8]
    assert v.value('dut.pic_inst.cpu_irq_vec_o', both + 20) == 9 and both > esc
    mie_on = next(t for t, x in v.changes('dut.cpu_inst.csr_file_inst.mstatus_mie_q') if x == 1)
    windows = [(esc - 30, both + 40), (mie_on - 20, claims[0] + 40), (eois[0] - 20, eois[1] + 20)]
    rows = [('clk', 'clk'),
            ('dut.pic_inst.req', 'requests [15:0]'),
            ('dut.pic_inst.escalated', 'escalated [15:0]'),
            ('dut.pic_inst.cpu_irq_o', 'cpu_irq_o'),
            ('dut.pic_inst.cpu_irq_vec_o', 'cpu_irq_vec_o [3:0]'),
            ('dut.cpu_inst.csr_file_inst.mstatus_mie_q', 'CPU mstatus.MIE'),
            ('dut.pic_inst.cpu_irq_ack_i', 'claim'),
            ('dut.pic_inst.cpu_irq_eoi_i', 'EOI'),
            ('dut.pic_inst.active', 'active [15:0]')]
    split_wave('soc_tb_pic_escalate', 'pic_escalation_v3', rows, windows,
               [(esc, '1'), (both, '2'), (claims[0], '3'), (claims[1], '4')])
    return esc, both, claims, eois


if __name__ == '__main__':
    soc_context('cpu')
    soc_context('pic')
    cpu_architecture()
    pic_architecture()
    cpu_end_to_end()
    pic_end_to_end()
    software_flow('cpu')
    software_flow('pic')
    print('CPU nesting', cpu_nesting_wave())
    print('PIC escalation', pic_escalation_wave())
    print('Wrote v3 figures to', OUT.relative_to(DOCS))
