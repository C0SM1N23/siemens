// Reopen the delivered PPTX packages and render them without a desktop app.
import fs from 'node:fs/promises';
import path from 'node:path';
import {PresentationFile} from '@oai/artifact-tool';

try {
 const root='scratch/saved'; await fs.mkdir(root,{recursive:true});
 const report={renderer:'artifact-tool, imported saved PPTX',slides:0,issues:[]};
 for(const name of (await fs.readdir('output')).filter(n=>n.endsWith('.pptx'))){
  const deck=await PresentationFile.importPptx(await fs.readFile(path.join('output',name)));
  const out=path.join(root,path.basename(name,'.pptx'));await fs.mkdir(out,{recursive:true});
  for(let i=0;i<deck.slides.items.length;i++){
   const slide=deck.slides.items[i];
   const png=await slide.export({format:'png'});
   await fs.writeFile(path.join(out,`Slide${i+1}.png`),new Uint8Array(await png.arrayBuffer()));
   const layout=JSON.parse(await (await slide.export({format:'layout'})).text());
   await fs.writeFile(path.join(out,`Slide${i+1}.json`),JSON.stringify(layout,null,2));
   for(const e of layout.elements){
    const [x,y,w,h]=e.bbox;
    if(x<-.5||y<-.5||x+w>1920.5||y+h>1080.5)report.issues.push(`${name} slide ${i+1}: outside slide ${e.name}`);
    if(e.textLayout?.lineCount && e.resolvedFontSize && e.textLayout.lineCount*e.resolvedFontSize>h+1)report.issues.push(`${name} slide ${i+1}: insufficient text height ${e.name}`);
   }
   report.slides++;
  }
  console.log('RENDERED saved PPTX',name,deck.slides.items.length,'slides');
 }
 await fs.writeFile(path.join(root,'report.json'),JSON.stringify(report,null,2));
 if(report.issues.length)throw Error(report.issues.join('\n'));
 console.log('PASS',report.slides,'slides; saved-package geometry');
}catch(e){console.error(e.message);process.exitCode=1;}
