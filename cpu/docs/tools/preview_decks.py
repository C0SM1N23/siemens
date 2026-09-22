"""Create screen-preview PDFs from the headless renders of the saved PPTX files."""
from pathlib import Path
import pymupdf

D=Path(__file__).resolve().parents[1]/'presentations'
for folder in (D/'scratch/saved').iterdir():
    if not folder.is_dir():
        continue
    images=sorted(folder.glob('Slide*.png'))
    assert len(images)==7
    doc=pymupdf.open()
    for image in images:
        page=doc.new_page(width=960,height=540)
        page.insert_image(page.rect,filename=str(image))
    doc.set_metadata({'title':folder.name, 'subject':'Screen preview of the saved PPTX; editable text and vector diagrams are in the PPTX.'})
    doc.save(D/'output'/(folder.name+'.pdf'),deflate=True)
    print('PREVIEW',folder.name+'.pdf')
