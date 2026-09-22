"""Check the saved packages, embedded assets and measured-waveform provenance."""
from pathlib import Path
from zipfile import ZipFile
import hashlib, io, json, posixpath
import xml.etree.ElementTree as ET
from PIL import Image
import pymupdf

D=Path(__file__).resolve().parents[1]
NS={'p':'http://schemas.openxmlformats.org/presentationml/2006/main',
    'a':'http://schemas.openxmlformats.org/drawingml/2006/main',
    'r':'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
    'svg':'http://schemas.microsoft.com/office/drawing/2016/SVG/main'}
for path in (D/'presentations/output').glob('*.pptx'):
    count=0
    # v2 adds a design-decisions slide and the SoC context figure on the title slide.
    v2=path.stem.endswith('_v2')
    pages=8 if v2 else 7
    with ZipFile(path) as z:
        assert z.testzip() is None
        slides=[n for n in z.namelist() if n.startswith('ppt/slides/slide') and n.endswith('.xml')]
        notes=[n for n in z.namelist() if n.startswith('ppt/notesSlides/notesSlide') and n.endswith('.xml')]
        assert len(slides)==len(notes)==pages
        for n in slides:
            rels=ET.fromstring(z.read('ppt/slides/_rels/'+posixpath.basename(n)+'.rels'))
            targets={r.attrib['Id']:posixpath.normpath(posixpath.join('ppt/slides',r.attrib['Target'])).lstrip('/') for r in rels}
            for pic in ET.fromstring(z.read(n)).findall('.//p:pic',NS):
                stem=pic.find('p:nvPicPr/p:cNvPr',NS).attrib['name'].removeprefix('asset-')
                blip=pic.find('p:blipFill/a:blip',NS)
                png=z.read(targets[blip.attrib['{'+NS['r']+'}embed']])
                svg_blip=blip.find('.//svg:svgBlip',NS)
                svg=z.read(targets[svg_blip.attrib['{'+NS['r']+'}embed']])
                assert png==(D/(stem+'.png')).read_bytes(), stem+' PNG differs'
                assert svg==(D/(stem+'.svg')).read_bytes(), stem+' SVG differs'
                Image.open(io.BytesIO(png)).verify()
                ET.fromstring(svg)
                count+=1
    expected=5 if v2 else 4
    assert count==expected,(path.name,count)
    assert len(pymupdf.open(path.with_suffix('.pdf')))==pages
    print('PASS:',path.name,f'{pages} slides / {pages} notes / {expected} SVG+PNG assets / {pages}-page PDF')

manifest=json.loads((D/'waves/manifest.json').read_text())
assert len(manifest)==13
for item in manifest:
    raw=D/'waves/raw'/(item['testbench']+'.vcd')
    if raw.exists():assert hashlib.sha256(raw.read_bytes()).hexdigest()==item['source_sha256']
    for suffix in ('svg','png','pdf'):assert (D/'waves'/(item['file']+'.'+suffix)).is_file()
print('PASS: 13 waveform windows; available raw VCD hashes match')

for path in D.glob('*Specification*.pdf'):
    doc=pymupdf.open(path)
    assert len(doc)>1
    for page in doc:
        for block in page.get_text('blocks'):
            # Text coordinates are unrotated, including the landscape schematic pages.
            bounds=page.cropbox
            assert block[0]>=0 and block[1]>=0 and block[2]<=bounds.width+.1 and block[3]<=bounds.height+.1, path.name
    print('PASS:',path.name,len(doc),'pages; text within page bounds')
