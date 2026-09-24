// Second version of the two decks. The first version (build_v2.mjs) is kept for comparison.
import fs from 'node:fs/promises';
import path from 'node:path';
import {Presentation,PresentationFile,column,row,text,image,rule,panel,grid,fr,fixed} from '@oai/artifact-tool';

const OUT='output',QA='scratch/rendered_v2',SLIDES=8;
await fs.mkdir(OUT,{recursive:true});await fs.mkdir(QA,{recursive:true});
const INK='#173442',ACC='#006B75',MUT='#526772',GOLD='#A35B17',CARD='#EEF5F5',STRIPE='#F5F9F9';
const FRAME={frame:{left:0,top:0,width:1920,height:1080},baseUnit:1};
const manifest=JSON.parse(await fs.readFile('../waves/manifest.json','utf8'));

// Text sized by its content; the layout decides where it sits.
const T=(v,size,o={})=>text(v,{name:o.name,width:o.w??'fill',height:o.h??'hug',style:{fontSize:size,bold:!!o.bold,color:o.color??INK}});
const gapV=h=>column({width:'fill',height:h},[]);
const gapH=w=>column({width:w,height:1},[]);
// Light card that fills its grid cell and centres its content vertically.
const card=(child,o={})=>panel({name:o.name,fill:o.fill??CARD,borderRadius:12,padding:o.pad??{left:34,right:34,top:20,bottom:20},width:'fill',height:o.h??'fill',justify:o.justify??'center'},child);
async function asset(stem,w,h){
 const b=await fs.readFile('../'+stem+'.svg'),s=b.toString('utf8'),m=s.match(/viewBox="[\d.]+ [\d.]+ ([\d.]+) ([\d.]+)"/);
 if(!m)throw Error('Missing viewBox '+stem);
 const hh=Math.min(h,w/(+m[1]/+m[2])),ww=hh*(+m[1]/+m[2]);
 return row({name:'asset-frame-'+stem,width:w,height:h,gap:0,align:'center',justify:'center'},[image({name:'asset-'+stem,dataUrl:'data:image/svg+xml;base64,'+b.toString('base64'),width:ww,height:hh,fit:'contain',alt:stem})]);
}
function add(p,kind,index,phase,title,body,notes){
 const s=p.slides.add();
 s.compose(column({width:'fill',height:'fill',padding:{left:70,right:70,top:44,bottom:30},gap:0},[
  T(title,50,{bold:true,name:'slide-title'}),gapV(14),rule({width:170,height:4,stroke:ACC,weight:4}),gapV(28),
  column({width:'fill',height:'fill',gap:0},[body]),gapV(16),
  T(`${kind==='cpu'?'RV32I':'PIC'}   ·   ${String(index).padStart(2,'0')} / ${String(SLIDES).padStart(2,'0')}   ·   ${phase}`,20,{color:MUT,name:'footer'})
 ]),FRAME);
 s.speakerNotes.setText(notes);return s;
}
// Architecture diagrams use the whole slide below a single title line.
function addFigure(p,title,figure,notes){
 const s=p.slides.add();
 s.compose(column({width:'fill',height:'fill',padding:{left:18,right:18,top:12,bottom:12},gap:4},[T(title,48,{bold:true,name:'slide-title'}),figure]),FRAME);
 s.speakerNotes.setText(notes);return s;
}
// Table as a grid: bold header, then striped rows that share the height equally.
function stripes(head,rows,cols){
 const cell=(v,i,r)=>panel({fill:r%2?STRIPE:'#FFFFFF',padding:{left:22,right:18,top:10,bottom:10},width:'fill',height:'fill',justify:'center'},T(v,29,{color:i===0?ACC:INK,bold:i===0}));
 return grid({width:'fill',height:'fill',columns:cols,rows:[fixed(46),...rows.map(()=>fr(1))],columnGap:0,rowGap:6},[
  ...head.map(h=>panel({padding:{left:22,right:18,top:0,bottom:6},width:'fill',height:'fill',justify:'end'},T(h,25,{bold:true,color:MUT}))),
  ...rows.flatMap((r,k)=>r.map((v,i)=>cell(v,i,k)))
 ]);
}

async function build(kind){
 const cpu=kind==='cpu',p=Presentation.create({slideSize:{width:1920,height:1080}});

 const cover=p.slides.add();
 cover.compose(grid({width:'fill',height:'fill',columns:[fr(1),fr(1.15)],rows:[fr(1)],columnGap:70,padding:{left:110,right:80,top:70,bottom:70},alignItems:'center'},[
  column({width:'fill',height:'hug',gap:0},[
   T('INTERNSHIP · SIEMENS · 2026',26,{color:MUT}),gapV(16),rule({width:220,height:5,stroke:ACC,weight:5}),gapV(36),
   T(cpu?'RV32I Processor':'Interrupt Controller',84,{bold:true}),gapV(10),
   T(cpu?'Three-stage pipeline':'Programmable priority and preemption',44,{color:ACC}),gapV(70),
   T('Bunea Cosmin-Andrei',36,{bold:true}),gapV(8),
   T('Computer Engineering, year III\nAcademic year 2025–2026\nTransilvania University of Brașov',32),gapV(56),
   T('RTL implementation · interfaces · verification',28,{color:MUT})
  ]),
  await asset('presentations/assets/soc_context_'+kind,880,600)
 ]),FRAME);
 cover.speakerNotes.setText(cpu
  ?'0:30. The project is an RV32I core that I specified, wrote in RTL, integrated and verified. The figure is the SoC from the kick-off: the CPU has an instruction port, a data port on the interconnect and a direct link to the PIC. Total time: 10 minutes.'
  :'0:30. The project is the interrupt controller of the SoC, which I specified, wrote in RTL, integrated with the CPU and verified. In the figure, the PIC has a register port on the interconnect and a direct link to the CPU; its sources are the DMA, the SRAM and the timer. Total time: 10 minutes.');

 const reqs=cpu?[
  'RV32I base ISA; no multiply or divide',
  'Three stages: fetch, decode + execute, writeback',
  '32 × 32-bit register file; x0 reads as zero',
  'Branch predictor with one direction bit',
  'Exceptions and external interrupts',
  'CSRs for traps and interrupt control',
  'Two independent AXI4-Lite masters',
  'Central stall and flush control',
  'Interrupt link to the PIC',
  'Interrupts taken only at instruction boundaries'
 ]:[
  '16 hardware sources + 16 software triggers',
  'Level or edge mode for every source',
  'Priority bands, not a flat priority',
  'Preemption with nesting',
  'Spurious interrupt detection',
  'Deadline-based priority escalation',
  'Software-triggered interrupts',
  'AXI4-Lite register map, 11 registers',
  'One request + vector to the CPU',
  'SW interrupts identical to HW once they enter arbitration'
 ];
 // Grid fills row by row: interleave so 1–5 run down the left column and 6–10 down the right.
 const reqCell=i=>card(row({width:'fill',height:'hug',gap:26,align:'center'},[T(String(i+1).padStart(2,'0'),36,{bold:true,color:ACC,w:64}),T(reqs[i],34)]));
 const reqGrid=grid({width:'fill',height:'fill',columns:[fr(1),fr(1)],rows:[fr(1),fr(1),fr(1),fr(1),fr(1)],columnGap:28,rowGap:18},
  [0,1,2,3,4].flatMap(i=>[reqCell(i),reqCell(i+5)]));
 add(p,kind,2,'Requirements',cpu?'The task: a three-stage RV32I core with two AXI4-Lite ports':'The task: a PIC with priority bands, nesting and deadlines',
  cpu?reqGrid:column({width:'fill',height:'fill',gap:0},[reqGrid,gapV(18),T('The 32 HW/SW inputs merge into 16 source identities.',26,{color:MUT})]),
 cpu?'1:00. These are the requirements from the kick-off and the CPU brief: the ISA, the three stages, two AXI4-Lite ports, a simple predictor, traps, CSRs and central stall/flush control; interrupts are taken only at instruction boundaries. The interrupt link to the PIC uses 16 sources, a 4-bit ID, a claim and an EOI.'
 :'1:00. These come from the PIC brief. It asks for more than a priority encoder: bands, nesting, spurious detection, deadlines and software triggers, all configured through AXI4-Lite registers. The 16 hardware and 16 software inputs share the same 16 arbitration slots.');

 const decisions=cpu?[
  ['How large is the predictor, and how is a branch mapped?','128 entries, direct-mapped by PC, with a tag; a miss predicts not taken'],
  ['Trap, MRET and misprediction in the same cycle?','One redirect, only when S2 completes: IRQ, then exception, then MRET, then branch'],
  ['What happens on an AXI error response?','Access-fault exception (cause 1, 5 or 7); the destination register is not written'],
  ['During a stall, how is a wrong fetch avoided?','S1 holds one instruction until S2 is free; a redirect waits for S2, and a wrong-path response is drained'],
  ['How is a new trap blocked while a handler runs?','Trap entry clears MIE; a 16-level stack tells MRET whether to send an EOI']
 ]:[
  ['How many bands, and how is a tie resolved?','4 bands with programmable urgency; one 10-bit key per source; the lower ID wins a tie'],
  ['What if an active source is moved to another band?','The key saved at claim stays; the new band applies to the next request'],
  ['What happens when the nesting limit is reached?','No new offer and the overflow flag is set; active contexts are kept'],
  ['When is a request spurious, and is it visible?','Checked at claim; the context is kept and closed by EOI; logged per source and globally'],
  ['What does escalation mean?','Jump to a target band or bump one urgency step; may repeat; cleared when served']
 ];
 // Fixed number and arrow columns so questions and answers line up across the cards.
 const Q=600,A=900;
 const decisionRow=([q,a],i)=>card(row({width:'fill',height:'hug',gap:24,align:'center'},[T(String(i+1),38,{bold:true,color:ACC,w:40}),T(q,29,{color:MUT,w:Q}),T('→',36,{color:ACC,w:44}),T(a,31,{w:A})]));
 add(p,kind,3,'Design decisions',cpu?'The brief left 23 questions open; five of them shaped the design':'The brief left 21 questions open; five of them shaped the design',column({width:'fill',height:'fill',gap:0},[
  row({width:'fill',height:'hug',gap:24,padding:{left:34,right:34}},[gapH(40),T('Question from the brief',25,{bold:true,color:MUT,w:Q}),gapH(44),T('What I decided',25,{bold:true,color:ACC,w:A})]),gapV(12),
  grid({width:'fill',height:'fill',columns:[fr(1)],rows:decisions.map(()=>fr(1)),rowGap:14},decisions.map(decisionRow))
 ]),
 cpu?'1:40. The brief asked 23 questions and left the answers to me; these five shaped the design most. The predictor size and mapping; the order when several redirects are requested together; what an AXI error turns into; how S1 avoids a wrong fetch while S2 is stalled, including a read that is already on the bus; and how a second trap is kept out while a handler runs.'
 :'1:40. The brief asked 21 questions and left the answers to me; these five shaped the design most. How bands and ties work; what happens to an active source that is reconfigured; what the nesting limit does; when a request counts as spurious; and what escalation means in practice.');

 addFigure(p,cpu?'Three stages; S2 decides when an instruction is complete':'A request becomes an active context only at claim',await asset('figures/'+kind+'_essential',1884,990),
 cpu?'1:50. Follow the main path from S1 to S3. Loads and stores finish inside S2, so a dependent instruction gets the value by forwarding from S3, with no extra bubble. The decisions from the previous slide sit in these blocks: the predictor next to fetch; the fetch unit, which holds an instruction during a stall and drains a wrong-path response; the LSU inside execution, which turns an AXI error into an exception; and the control block, which orders redirects and keeps the trap state. Parameters: RESET_PC, HART_ID, BP_ENTRIES and RAS_DEPTH.'
 :'1:50. Follow a request from the top left: conditioning, then eligibility and the priority key, then the registered offer; claim pushes the context and EOI pops it. The decisions from the previous slide sit in these blocks: the priority block builds the key and applies escalation; the resolver stops offering at the nesting limit; the nesting block keeps the saved key and marks spurious claims. The module has no Verilog parameters.');

 const sw=cpu
  ?stripes(['CSR / event','PIC signal','Rule'],[
    ['mie[16+n]','cpu_mask_i[n]','Masked sources are skipped by the PIC'],
    ['mip[16+n]','pending_o[n]','Every pending source is visible'],
    ['mcause','cpu_irq_vec_o','0x8000_0000 + 16 + n'],
    ['mtvec, MODE = 1','—','Handler at BASE + 4 × (16 + n)'],
    ['Trap entry','cpu_irq_ack_i','One-cycle claim'],
    ['MRET','cpu_irq_eoi_i','EOI only after an interrupt']],[fr(0.95),fr(1),fr(1.65)])
  :stripes(['Address','Register / group','Role in use'],[
    ['0x00 + 4n','SRCn_CONFIG','Trigger, band, priority, deadline'],
    ['0x40 + 4n','SRCn_SW_TRIG','Set with key 0xA5A5 in both upper byte lanes'],
    ['0x80 + 4n','SRCn_STATUS','Pending, active, escalated, spurious'],
    ['0xC0 / D4','BAND_CONFIG / ESCALATION_CFG','Band urgencies and escalation policy'],
    ['0xC4 / C8 / CC','NEST_STATUS / NEST_MAX / ACTIVE_VEC','Active context and nesting limit'],
    ['0xD8','INT_ENABLE','Per-source enable'],
    ['0xD0 / DC','SPURIOUS_LOG / INT_STATUS','Logged events; cleared by RW1C']],[fr(0.7),fr(1.35),fr(1.45)]);
 add(p,kind,5,'Software interface',cpu?'CSR bits 16 to 31 connect software to the PIC':'The registers set the policy and make the state observable',
  grid({width:'fill',height:'fill',columns:[fr(1),fixed(600)],columnGap:60,alignItems:'center'},[sw,await asset('figures/'+kind+'_software',600,830)]),
 cpu?'1:20. The CSRs follow RISC-V; the part specific to this project is bits 16 to 31, one per PIC source. mie bit 16+n goes to the PIC as a mask, so a masked source is skipped in arbitration and cannot hold back the others. mip shows every pending source, not only the one offered. On trap entry the CPU saves cause 16+n and sends one claim; with vectored mtvec the handler address follows from n. MRET sends an EOI only when it closes an interrupt.'
 :'1:20. Every register here is defined by the project. SRCn_CONFIG sets trigger, band, priority and deadline for each source; BAND_CONFIG and ESCALATION_CFG set the shared policy; NEST_MAX limits the depth. A software trigger needs the key 0xA5A5 written with both upper byte strobes, so a partial write cannot arm a channel. RW1C clears logged events, and a hardware event in the same cycle is kept. Addresses are offsets in a 256-byte window; n is 0 to 15.');

 const cards=cpu?[
  ['Independent model','49,149 instructions in 11 programs, compared step by step'],
  ['Latency and backpressure','Memories delay replies and stall channels'],
  ['Mutation suite','25 injected RTL defects; each makes a named bench fail']
 ]:[
  ['Independent model','All 24 band orders, with masks and ties'],
  ['Same-cycle events','Edge at claim, masked source, strobed key'],
  ['External AXI reference','Front-end compared with PULP: 96 cases']
 ];
 add(p,kind,6,'Verification',cpu?'The environment checks results, bus protocol and its own tests':'The priority rules are checked against an independent model',column({width:'fill',height:'fill',gap:0},[
  await asset('figures/'+kind+'_verification',1780,540),gapV(22),
  grid({width:'fill',height:'fill',columns:[fr(1),fr(1),fr(1)],rows:[fr(1)],columnGap:28},cards.map(([h,b])=>card(column({width:'fill',height:'hug',gap:10},[T(h,33,{bold:true,color:ACC}),T(b,29)])))),
  gapV(14),T('ModelSim: 39 CPU/PIC runs   ·   Verilator: 17 benches, 53 runs with assertions bound to the RTL',24,{color:MUT})
 ]),
 cpu?'1:30. Stimulus and program go into the DUT; expected values and observations go into the checks. The ISA model is written separately from the RTL and gives the expected state after each instruction: a directed program and ten random ones, 49,149 instructions in all. The memories add delay and backpressure, so the same program also exercises stalls. Assertions are attached with bind and check pipeline and AXI rules. The mutation suite inserts a known defect into the RTL and requires a named bench to fail; all 25 are rejected.'
 :'1:30. The Python model computes the expected winner and pending set for all 24 orders of band urgency, with enable masks, CPU masks and ties. Directed tests cover the timing cases the model cannot: a new edge in the claim cycle, a masked source next to lower-priority ones, a key written with partial strobes, nesting, deadlines and reset. The AXI4-Lite front-end is compared with the PULP axi_lite_regs module on 96 strobe, order and stall cases. The four PIC cases of the mutation suite are all rejected.');

 const w=cpu?'waves/cpu_irq':'presentations/assets/pic_escalation_marked';
 if(cpu&&!manifest.find(x=>x.file==='cpu_irq'))throw Error('cpu_irq window missing from manifest');
 const events=cpu?[
  ['1 · New IRQ','LSU busy → claim = 0'],['2 · R handshake','Load complete → S2 may advance'],['3 · Claim','Trap entry; one-cycle pulse']
 ]:[
  ['1 · Source 1 offered','Same band: the lower ID wins the tie'],['2 · Source 2 deadline','10 cycles pending → escalation'],['3 · Offer moves to 2','Bumped to band 3, the next urgency']
 ];
 add(p,kind,7,'Critical scenario',cpu?'The IRQ waits for the load to finish before the claim':'Escalation follows the programmed urgency, not the band number',column({width:'fill',height:'fill',gap:0},[
  await asset(w,1780,560),gapV(20),
  grid({width:'fill',height:'fill',columns:[fr(1),fr(1),fr(1)],rows:[fr(1)],columnGap:28},events.map(([h,b])=>card(column({width:'fill',height:'hug',gap:10},[T(h,34,{bold:true,color:GOLD}),T(b,31)])))),
  gapV(12),T(cpu?'The markers follow the same instruction and the same IRQ request.':'Bands reordered: band 0 is the least urgent. Bus values are hexadecimal.',23,{color:MUT})
 ]),
 cpu?'1:30. At 7575 ns the IRQ appears, but lsu_active is still 1, so there is no claim. At 7595 ns RVALID and RREADY are high on the same edge and the load response is accepted. At 7605 ns the claim and cpu_in_trap appear. An accepted response cannot be dropped to reach the handler sooner. The test also checks the loaded value and mepc.'
 :'1:30. The test reorders the bands so band 0 is the least urgent. Sources 1 and 2 are both in band 0 and requested together; source 1 wins the tie. At marker 2, source 2 reaches its 10-cycle deadline and escalates. It moves to the next more urgent band in the programmed order, band 3, not to band 0 minus one. At marker 3 the registered offer changes to source 2 on the next edge. This is decision 5 in practice.');

 const built=cpu?['RV32I pipeline with predictor, forwarding and traps','CPU–PIC link: mask, pending, claim and EOI','Checks: ISA model, bound assertions, mutation suite']
  :['Banded priority with programmable urgency','Nesting stack, spurious handling, deadline escalation','Priority model covering all 24 band orders'];
 const learned=cpu?['Simultaneous events need a written order; the brief only lists them.','An accepted AXI transfer cannot be cancelled, and that decides when a trap can start.','A test counts only if a real defect makes it fail.']
  :['Ties and same-cycle events need a written rule.','Saving the key at claim keeps the stack valid after reconfiguration.','The CPU mask belongs inside the PIC, or a masked source holds back the others.'];
 const listCard=(head,items,numbered)=>card(column({width:'fill',height:'fill',gap:0},[
  T(head,30,{bold:true,color:ACC}),gapV(18),
  grid({width:'fill',height:'fill',columns:[fr(1)],rows:items.map(()=>fr(1)),rowGap:10,alignItems:'center'},
   items.map((v,i)=>row({width:'fill',height:'hug',gap:20,align:'start'},[T(numbered?`${i+1}.`:'–',35,{bold:numbered,color:ACC,w:44}),T(v,35)])))
 ]),{justify:'start',pad:{left:40,right:40,top:32,bottom:24}});
 add(p,kind,8,'Conclusions',cpu?'Result: an integrated core, checked instruction by instruction':'Result: configurable arbitration with verified preemption',column({width:'fill',height:'fill',gap:0},[
  grid({width:'fill',height:'fill',columns:[fr(1),fr(1)],rows:[fr(1)],columnGap:28},[listCard('WHAT I BUILT',built,true),listCard('WHAT I LEARNED',learned,false)]),
  gapV(22),
  panel({fill:ACC,borderRadius:12,padding:{left:40,right:40,top:22,bottom:22},width:'fill',height:'hug'},T('Internship: brief → specification → RTL → verification, with a review at each step.',30,{bold:true,color:'#FFFFFF'}))
 ]),
 cpu?'0:40. The result is an RV32I core connected to the PIC and checked against an independent model. What I keep from the project: simultaneous events need a written order; bus rules shape the pipeline control; and a test is useful only if a real defect makes it fail. The internship followed the path of a real block, from brief to verification, with reviews in between.'
 :'0:40. The result is a PIC with a configurable policy and verified preemption. What I keep from the project: ties and same-cycle events need a written rule; the key saved at claim keeps the stack correct when software reconfigures a source; and the CPU mask has to act inside the PIC. The internship followed the path of a real block, from brief to verification, with reviews in between.');

 const name=cpu?'RV32I_CPU_Bunea_Cosmin-Andrei_v2.pptx':'PIC_Bunea_Cosmin-Andrei_v2.pptx';
 await (await PresentationFile.exportPptx(p)).save(path.join(OUT,name));
 for(let i=0;i<p.slides.items.length;i++){
  const s=p.slides.items[i];
  await fs.writeFile(`${QA}/${kind}-${i+1}.png`,new Uint8Array(await (await s.export({format:'png'})).arrayBuffer()));
 }
 console.log('EXPORTED',name,`${SLIDES} slides / 10 minutes`);
}
try {await build('cpu');await build('pic');}catch(e){console.error(e.stack||e.message);process.exitCode=1;}
