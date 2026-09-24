"""Editable SVG block diagrams from the implemented CPU/PIC interfaces."""
from pathlib import Path
from html import escape
import pymupdf as fitz

OUT=Path(__file__).resolve().parents[1]/'figures'
OUT.mkdir(exist_ok=True)
INK='#173442';ACC='#006B75';MUT='#526772';LIGHT='#EDF5F5'

class SVG:
    def __init__(self,w=1600,h=850):
        self.w=w;self.h=h
        self.s=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
        '<defs><marker id="arrow" markerWidth="9" markerHeight="9" refX="8" refY="4" orient="auto" markerUnits="userSpaceOnUse"><path d="M0,0 L8,4 L0,8" fill="'+ACC+'"/></marker></defs>',
        '<rect width="100%" height="100%" fill="white"/>']
    def text(self,x,y,lines,size=27,color=INK,anchor='middle',bold=False):
        if isinstance(lines,str):lines=[lines]
        for i,line in enumerate(lines):
            self.s.append(f'<text x="{x}" y="{y+i*(size+9)}" text-anchor="{anchor}" font-family="Arial, sans-serif" font-size="{size}" font-weight="{700 if bold else 400}" fill="{color}">{escape(line)}</text>')
    def box(self,x,y,w,h,title,sub=None):
        self.s.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="{LIGHT}" stroke="{ACC}" stroke-width="2"/>')
        self.text(x+w/2,y+39,title,29,bold=True)
        if sub:self.text(x+w/2,y+79,sub,23,color=MUT)
    def line(self,pts,label=None,lx=None,ly=None,size=22,dashed=False):
        coords=' '.join(f'{x},{y}' for x,y in pts)
        dash=' stroke-dasharray="7 6"' if dashed else ''
        self.s.append(f'<polyline points="{coords}" fill="none" stroke="white" stroke-width="10"/>')
        self.s.append(f'<polyline points="{coords}" fill="none" stroke="{ACC}" stroke-width="3"{dash}/>')
        # Explicit arrowheads survive SVG -> PDF and Office fallback rendering.
        import math
        x,y=pts[-1]; px,py=pts[-2]; a=math.atan2(y-py,x-px)
        bx,by=x-13*math.cos(a),y-13*math.sin(a)
        self.s.append(f'<polygon points="{x},{y} {bx+6*math.sin(a)},{by-6*math.cos(a)} {bx-6*math.sin(a)},{by+6*math.cos(a)}" fill="{ACC}"/>')
        if label:
            self.text(lx if lx is not None else (pts[0][0]+pts[-1][0])/2,ly if ly is not None else (pts[0][1]+pts[-1][1])/2-12,label,size)
    def save(self,name):
        path=OUT/(name+'.svg');path.write_text('\n'.join(self.s+['</svg>']),encoding='utf-8')
        svg=fitz.open(path)
        pdf=fitz.open('pdf',svg.convert_to_pdf())
        pdf.save(OUT/(name+'.pdf'))
        pdf[0].get_pixmap(matrix=fitz.Matrix(1.5,1.5),alpha=False).save(OUT/(name+'.png'))

def environment(kind):
    d=SVG(1600,660)
    if kind=='cpu':
        d.box(30,220,330,170,'Stimulus',['program_axi.hex / ISA vectors','IRQ source events','clock + reset'])
        d.box(575,220,380,170,'DUT · RV32I CPU',['instruction AXI4-Lite','data AXI4-Lite · PIC interface'])
        d.box(1180,220,380,170,'Responders',['instruction / data memory','PIC + timer · address decode','latency / backpressure'])
        d.line([(360,270),(575,270)],'IRQ / reset',466,252,21)
        d.line([(195,220),(195,175),(1360,175),(1360,220)])
        d.text(770,162,'program / initial memory image',21)
        d.line([(955,268),(1180,268)],'AXI requests',1067,250,22)
        d.line([(1180,348),(955,348)],'AXI responses',1067,330,22)
        d.box(555,492,430,130,'Checks',['ISA reference · result scoreboard','protocol monitors · bound SVA'])
        d.line([(760,390),(760,492)])
        d.text(800,449,'observed state / transfers',21,anchor='start')
        d.line([(160,390),(160,556),(555,556)],'expected values',351,538,22)
        d.text(800,78,'One verdict: expected result + legal protocol + completed test',31,bold=True)
        d.text(800,130,'Widths: address/data 32 · IRQ mask 16 · IRQ ID 4',23,color=MUT)
    else:
        d.box(30,220,355,180,'Stimulus',['AXI register-access tasks','irq_src_i 16 · cpu_mask_i 16','claim / EOI 1 · reset'])
        d.box(610,220,350,180,'DUT · PIC',['pic + axi_lite_slave','16 sources · 4 bands'])
        d.box(1180,220,385,180,'Checks',['irq 1 · vector 4 · pending 16','register values + responses','nesting / deadline / reset'])
        d.line([(385,286),(610,286)],'stimulus at posedge +1 ns',496,260,18)
        d.line([(960,286),(1180,286)])
        d.text(1070,244,['protocol: posedge','state: after NBA'],18)
        d.box(520,492,490,130,'Independent reference',['pic_reference.py → expected winner','275 cases · all 256 BAND_CONFIG values'])
        d.line([(1010,553),(1370,553),(1370,400)],'expected source / pending',1220,537,21)
        d.line([(520,553),(210,553),(210,400)])
        d.text(355,537,'input vectors',21)
        d.text(800,78,'Directed scenarios plus an independent priority model',31,bold=True)
        d.text(800,130,'Protocol and PIC invariants are checked by assertions attached through bind.',23,color=MUT)
    d.save(kind+'_verification')

