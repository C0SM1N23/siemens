from pathlib import Path
import xml.etree.ElementTree as E
from PIL import ImageFont
root=Path(__file__).resolve().parents[1]/'figures'
issues=[]
for name in ['cpu_essential','pic_essential','cpu_verification','pic_verification','cpu_software','pic_software']:
    doc=E.parse(root/(name+'.svg')); ns={'s':'http://www.w3.org/2000/svg'}
    lines=[]
    for e in doc.findall('s:polyline',ns):
        if e.attrib['stroke']=='white':continue
        ps=[tuple(map(float,p.split(','))) for p in e.attrib['points'].split()]
        lines.extend(zip(ps,ps[1:]))
    labels=[]
    for t in doc.findall('s:text',ns):
        x,y=float(t.attrib['x']),float(t.attrib['y']); sz=int(t.attrib['font-size']); s=t.text or ''
        f=ImageFont.truetype('C:/Windows/Fonts/arialbd.ttf' if t.attrib.get('font-weight')=='700' else 'C:/Windows/Fonts/arial.ttf',sz)
        w=f.getlength(s); a=t.attrib.get('text-anchor','start'); l=x-(w/2 if a=='middle' else w if a=='end' else 0)
        box=(l,y-sz*.80,l+w,y+sz*.15)
        for other,ob in labels:
            if min(box[2],ob[2])-max(box[0],ob[0])>2 and min(box[3],ob[3])-max(box[1],ob[1])>2:
                issues.append(f'{name}: text overlap: {s} / {other}')
        labels.append((s,box))
        for (x1,y1),(x2,y2) in lines:
            if x1==x2 and box[0]-3<x1<box[2]+3 and min(y1,y2)<box[3]+3 and max(y1,y2)>box[1]-3 or y1==y2 and box[1]-3<y1<box[3]+3 and min(x1,x2)<box[2]+3 and max(x1,x2)>box[0]-3:
                issues.append(f'{name}: {s} crosses route {(x1,y1,x2,y2)}')
for issue in issues:print(issue)
if issues:raise SystemExit(1)
print('PASS: six diagrams; no text/route or text/text overlap')
