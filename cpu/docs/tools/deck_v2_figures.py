"""Figures used only by the v2 presentations; the specification figures are not modified."""
from pathlib import Path
import pymupdf as fitz
from diagrams import SVG, INK, ACC, MUT

DOCS = Path(__file__).resolve().parents[1]
OUT = DOCS / 'presentations/assets'
OUT.mkdir(parents=True, exist_ok=True)


def save(svg_text, name, scale=2.0):
    path = OUT / (name + '.svg')
    path.write_text(svg_text, encoding='utf-8')
    pdf = fitz.open('pdf', fitz.open(path).convert_to_pdf())
    pdf[0].get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False).save(OUT / (name + '.png'))


def soc(highlight):
    d = SVG(1200, 770)

    def block(x, y, w, h, title, sub):
        if title.startswith(highlight):
            d.s.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="{ACC}" stroke="{ACC}" stroke-width="2"/>')
            d.text(x + w / 2, y + 39, title, 29, color='white', bold=True)
            d.text(x + w / 2, y + 79, sub, 23, color='#D9EEF0')
        else:
            d.box(x, y, w, h, title, sub)

    block(30, 30, 300, 110, 'Instruction memory', 'read only')
    block(30, 250, 300, 160, 'RV32I CPU', ['3 pipeline stages', 'ibus + dbus masters'])
    block(30, 590, 300, 160, 'PIC', ['16 sources · 4 bands', 'IRQ: DMA, SRAM, timer'])
    d.s.append(f'<rect x="450" y="30" width="120" height="720" rx="7" fill="#F4F7F8" stroke="{ACC}" stroke-width="2"/>')
    for dx, line, size, bold in ((-6, 'AXI4-Lite interconnect', 27, True), (28, 'decoders · arbiter · bridge', 20, False)):
        d.s.append(f'<text transform="rotate(-90 {510 + dx} 390)" x="{510 + dx}" y="390" text-anchor="middle" '
                   f'font-family="Arial, sans-serif" font-size="{size}" font-weight="{700 if bold else 400}" '
                   f'fill="{INK if bold else MUT}">{line}</text>')
    block(690, 30, 480, 110, 'Data memory', 'CPU and DMA, arbitrated')
    block(690, 180, 480, 110, 'Dual-port SRAM', 'port A: CPU · port B: DMA')
    block(690, 330, 480, 110, 'Machine timer', 'timer interrupt')
    block(690, 480, 480, 150, 'DMA', ['register slave', 'AXI4 master via bridge'])
    d.line([(180, 250), (180, 140)], 'ibus', 220, 205, 20)
    d.line([(330, 300), (450, 300)], 'dbus', 390, 288, 20)
    d.line([(450, 670), (330, 670)], 'registers', 390, 658, 19)
    d.line([(120, 590), (120, 410)], 'IRQ · ID', 70, 505, 19)
    d.line([(240, 410), (240, 590)], 'claim · EOI', 300, 505, 19)
    for y in (85, 235, 385):
        d.line([(570, y), (690, y)])
    d.line([(570, 530), (690, 530)], 'registers', 630, 518, 18)
    d.line([(690, 595), (570, 595)], 'AXI4 master', 630, 583, 18)
    save('\n'.join(d.s + ['</svg>']), 'soc_context_' + ('cpu' if highlight == 'RV32I' else 'pic'))


def escalation():
    # Axes span 915..1065 ns between x=235.008 and x=907.776 (matplotlib output of waveforms.py).
    x0, x1, t0, t1 = 235.008, 907.776, 915, 1065
    top, bottom = 8.4888, 243.3456
    y = lambda d: bottom - (d + 0.35) * (bottom - top) / 7.9
    text = (DOCS / 'waves/pic_escalation.svg').read_text(encoding='utf-8')
    extra = []
    for n, t in ((1, 945), (2, 1025), (3, 1045)):
        x = x0 + (t - t0) / (t1 - t0) * (x1 - x0)
        tip = y(6.47)
        # Same marker as waveforms.py: number, arrow, then a dashed line below the arrow.
        extra.append(f'<line x1="{x:.2f}" y1="{tip:.2f}" x2="{x:.2f}" y2="{bottom}" stroke="#BB6B21" stroke-width="1" stroke-dasharray="4,2.5"/>')
        extra.append(f'<text x="{x:.2f}" y="{y(7.02):.2f}" text-anchor="middle" font-family="DejaVu Sans, Arial, sans-serif" '
                     f'font-size="10" font-weight="700" fill="#905013">{n}</text>')
        extra.append(f'<line x1="{x:.2f}" y1="{y(6.96):.2f}" x2="{x:.2f}" y2="{tip - 3:.2f}" stroke="#BB6B21" stroke-width="1"/>')
        extra.append(f'<polygon points="{x:.2f},{tip:.2f} {x - 2.2:.2f},{tip - 4:.2f} {x + 2.2:.2f},{tip - 4:.2f}" fill="#BB6B21"/>')
    save(text.replace('</svg>', '\n'.join(extra) + '\n</svg>'), 'pic_escalation_marked', scale=3.0)


if __name__ == '__main__':
    soc('RV32I')
    soc('PIC')
    escalation()
    print('Wrote', len(list(OUT.glob('*.svg'))), 'v2 figures to', OUT.relative_to(DOCS))
