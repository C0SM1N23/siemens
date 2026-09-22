"""Populate PNG fallbacks for the SVGs embedded by artifact-tool."""
from pathlib import Path
import posixpath
import xml.etree.ElementTree as ET
from zipfile import ZipFile, ZIP_DEFLATED

DOCS=Path(__file__).resolve().parents[1]
NS={'p':'http://schemas.openxmlformats.org/presentationml/2006/main',
    'a':'http://schemas.openxmlformats.org/drawingml/2006/main',
    'r':'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
    'rel':'http://schemas.openxmlformats.org/package/2006/relationships'}
for path in (DOCS/'presentations/output').glob('*.pptx'):
    with ZipFile(path) as z:
        entries={n:z.read(n) for n in z.namelist() if not n.startswith('/')}
    count=0
    for n,data in list(entries.items()):
        if not n.startswith('ppt/slides/slide') or not n.endswith('.xml'):continue
        rels=ET.fromstring(entries['ppt/slides/_rels/'+posixpath.basename(n)+'.rels'])
        targets={r.attrib['Id']:posixpath.normpath(posixpath.join('ppt/slides',r.attrib['Target'])).lstrip('/') for r in rels}
        root=ET.fromstring(data)
        for pic in root.findall('.//p:pic',NS):
            name=pic.find('p:nvPicPr/p:cNvPr',NS).attrib['name']
            if not name.startswith('asset-'):continue
            stem=name.removeprefix('asset-')
            source=(DOCS/(stem+'.png')).resolve()
            assert source.is_relative_to(DOCS.resolve()) and source.is_file()
            blip=pic.find('p:blipFill/a:blip',NS)
            target=targets[blip.attrib['{'+NS['r']+'}embed']]
            assert target in entries, target
            entries[target]=source.read_bytes()
            count+=1
    temporary=path.with_suffix('.building.pptx')
    with ZipFile(temporary,'w',ZIP_DEFLATED) as z:
        for n,data in entries.items():z.writestr(n,data)
    temporary.replace(path)
    print(path.name,':',count,'SVG images with real PNG fallbacks')
