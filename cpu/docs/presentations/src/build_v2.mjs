import fs from 'node:fs/promises';
import path from 'node:path';
import {Presentation,PresentationFile,column,row,text,image,rule,fill} from '@oai/artifact-tool';

const OUT='output',QA='scratch/rendered';
await fs.mkdir(OUT,{recursive:true});await fs.mkdir(QA,{recursive:true});
const INK='#173442',ACC='#006B75',MUT='#526772',GOLD='#A35B17';
const manifest=JSON.parse(await fs.readFile('../waves/manifest.json','utf8'));
const t=(v,size=32,bold=false,h=70,color=INK,w=fill,name='text')=>text(v,{name,width:w,height:h,style:{fontSize:size,bold,color}});
const col=(children,w=fill,h=fill,gap=12)=>column({width:w,height:h,gap},children);
const blank=(w,h=1)=>col([],w,h,0);
async function asset(stem,w,h){
 const b=await fs.readFile('../'+stem+'.svg'),s=b.toString('utf8'),m=s.match(/viewBox="[\d.]+ [\d.]+ ([\d.]+) ([\d.]+)"/);
 if(!m)throw Error('Missing viewBox '+stem);
 const hh=Math.min(h,w/(+m[1]/+m[2])),ww=hh*(+m[1]/+m[2]);
 return row({name:'asset-frame-'+stem,width:w,height:h,gap:0},[...((w-ww)>1?[blank((w-ww)/2,h)]:[]),image({name:'asset-'+stem,dataUrl:'data:image/svg+xml;base64,'+b.toString('base64'),width:ww,height:hh,fit:'contain',alt:stem})]);
}
function add(p,kind,index,phase,title,body,notes,dense=false){
 const s=p.slides.add();
 if(dense)s.compose(col([t(title,48,true,62),body],fill,fill,4),{frame:{left:18,top:12,width:1884,height:1056},baseUnit:1});
 else s.compose(column({width:fill,height:fill,padding:{left:60,right:60,top:36,bottom:24},gap:14},[
  t(title,52,true,82,INK,fill,'slide-title'),rule({width:170,height:4,stroke:ACC,weight:4}),body,
  t(`${kind==='cpu'?'RV32I':'PIC'}   ·   ${String(index).padStart(2,'0')} / 07   ·   ${phase}`,20,false,30,MUT,fill,'footer')
 ]),{frame:{left:0,top:0,width:1920,height:1080},baseUnit:1});
 s.speakerNotes.setText(notes);return s;
}
function req(n,v){return row({width:fill,height:112,gap:24},[t(String(n).padStart(2,'0'),33,true,75,ACC,65),t(v,33,false,105,INK,765)]);}
function registerTable(rows){
 const widths=[200,365,455];
 const rr=(r,head=false)=>row({width:fill,height:head?45:86,gap:25},r.map((v,i)=>t(v,head?25:27,head,head?45:86,INK,widths[i])));
 const children=[rr(['Address','Register / group','Role in use'],true),rule({width:fill,height:2,stroke:ACC,weight:2})];
 for(const r of rows)children.push(rr(r),rule({width:fill,height:1,stroke:'#D7E1E4',weight:1}));
 return col(children,1100,770,4);
}
async function build(kind){
 const cpu=kind==='cpu',p=Presentation.create({slideSize:{width:1920,height:1080}});
 const cover=p.slides.add();
 cover.compose(column({width:fill,height:fill,padding:{left:100,right:100,top:95,bottom:70},gap:22},[
  t('INTERNSHIP · SIEMENS · 2026',26,false,45,MUT),rule({width:220,height:5,stroke:ACC,weight:5}),
  t(cpu?'RV32I Processor':'Interrupt Controller',78,true,115),
  t(cpu?'Three-stage pipeline':'Programmable priority and preemption',48,false,90,ACC),
  blank(fill,25),
  row({width:fill,height:110,gap:24},[
   t(cpu?'FETCH':'REQUESTS',34,true,75,ACC,380),t('→',50,false,75,MUT,70),
   t(cpu?'DECODE / EXECUTE':'ARBITRATION',34,true,75,ACC,550),t('→',50,false,75,MUT,70),
   t(cpu?'WRITEBACK':'SERVICE',34,true,75,ACC,380)]),
  blank(fill,30),t('Bunea Cosmin-Andrei\nComputer Engineering · year III · academic year 2025–2026\nTransilvania University of Brașov',34,false,180),
  t('RTL implementation · interfaces · verification',28,false,55,MUT)
 ]),{frame:{left:0,top:0,width:1920,height:1080},baseUnit:1});
 cover.speakerNotes.setText('0:20. Introduce the project and my own contribution: defining the behaviour, writing the RTL, integrating it and verifying it. Total planned time: 10 minutes.');

 const requirements=cpu?[
 'RV32I set: arithmetic, logic, control transfer, memory',
 'Three stages: fetch, decode + execute, writeback',
 '32 × 32-bit register file; x0 hardwired to zero',
 'Branch prediction with one direction bit',
 'Exceptions and interrupts at instruction boundaries',
 'Two AXI4-Lite ports: instruction and data',
 'CSRs for control, traps and IRQ state',
 'Centralized control for stall, flush and hazards',
 'Defined behaviour for AXI latency and errors',
 'Interrupt link to the PIC'
 ]:[
 '16 hardware sources + 16 software triggers',
 'Level / edge selection for every source',
 'Priority bands and intra-band arbitration',
 'Preemption that preserves the active contexts',
 'Programmable limit for the nesting depth',
 'Detection and reporting of spurious requests',
 'Per-source deadline and automatic escalation',
 'Protected software trigger and a defined clear rule',
 'AXI4-Lite: configuration and status registers',
 'SW interrupts identical to HW once they enter arbitration'
 ];
 const requirementBody=col([
  row({width:fill,height:680,gap:70},[
   col(requirements.slice(0,5).map((v,i)=>req(i+1,v)),865,660,17),
   col(requirements.slice(5).map((v,i)=>req(i+6,v)),865,660,17)]),
  ...(cpu?[]:[t('The 32 HW/SW inputs merge into 16 source identities.',27,false,65,MUT)])
 ],1800,790,20);
 add(p,kind,2,'Requirements',cpu?'The task: a three-stage RV32I core with two AXI4-Lite ports':'The task: a PIC with priority bands, nesting and deadlines',requirementBody,
 cpu?'1:20. Start from the requirements in the RV32I brief: pipeline, ISA, register file, predictor, traps, AXI ports, CSRs and stall/flush control. The brief left the predictor capacity, the order of concurrent events and the reaction to bus errors to be defined. Those decisions are my design contribution. The interrupt link to the PIC has 16 sources, a 4-bit ID and scalar claim and EOI.'
 :'1:20. The requirement goes well beyond a priority encoder: it asks for grouping, nesting, spurious events, deadlines and software injection. Stress that 16 hardware plus 16 software means two origins for each of the 16 arbitration slots. The number of bands, the exact policy and the context-saving mechanism all had to be defined. Arbitration is a combinational comparison followed by a registered offer.');

 add(p,kind,3,'Architecture',cpu?'Three stages; the memory access completes inside S2':'The selected request becomes an active context only at claim',await asset('figures/'+kind+'_essential',1884,990),
 cpu?'2:20. Follow the main path: fetch and prediction in S1, the IF/DX boundary, decode and operands and execution in S2, then DX/WB and the S3 mux. The LSU finishes its transfer before S2 advances. S3 feeds back into the register file and the forwarding path. Then show the feedback along the bottom: the branch result and the LSU status reach the control block, which issues the redirect and the valid bits of the pipeline registers. The predictor is updated when a valid branch or jump completes. S1 drains the wrong-path response. The PIC and the memories are external; the numbers on the links are widths in bits. The parameters are RESET_PC, HART_ID, BP_ENTRIES and RAS_DEPTH.'
 :'2:20. Follow the request from the top left: level/edge plus software, enable, eligibility and the priority key. The 10-bit key compares band urgency, intra-band priority and the inverted ID. The offer is registered. A claim uses the saved ID and pushes that ID plus the current key onto the stack; an EOI pops the inner context. Show the feedback paths: top key, active mask and depth limit. Reconfiguring an active source does not change the key already saved. The registers control the policy, and pending is separate from the selected offer. The blocks are functional groups inside pic.v; the AXI front-end is axi_lite_slave. The PIC module has no Verilog parameters.',true);

 const registers=cpu?[
 ['0x300','mstatus','Global MIE; state on entry / return'],
 ['0x304 / 344','mie / mip','Per-source mask / pending requests'],
 ['0x305','mtvec','Handler base; direct or vectored'],
 ['0x341–343','mepc / mcause / mtval','Return PC; cause; fault payload'],
 ['0x340','mscratch','Context managed by software'],
 ['0xB00 / B02','mcycle / minstret','Cycles and retired instructions']
 ]:[
 ['0x00 + 4n','SRCn_CONFIG','Trigger, band, priority, deadline'],
 ['0x40 + 4n','SRCn_SW_TRIG','Injection with key 0xA5A5; clear'],
 ['0x80 + 4n','SRCn_STATUS','Pending, active, escalated, spurious'],
 ['0xC0 / D4','BAND_CONFIG / ESCALATION_CFG','Band urgencies and escalation policy'],
 ['0xC4 / C8 / CC','NEST_STATUS / NEST_MAX / ACTIVE_VEC','Active context and nesting limit'],
 ['0xD8','INT_ENABLE','Per-source enable'],
 ['0xD0 / DC','SPURIOUS_LOG / INT_STATUS','Logged events; cleared by RW1C']
 ];
 add(p,kind,4,'Software interface',cpu?'The CSRs link configuration to trap entry and return':'The registers set the policy and make the state observable',row({width:fill,height:790,gap:80},[registerTable(registers),await asset('figures/'+kind+'_software',620,790)]),
 cpu?'1:20. This is the software-interface slide. CSRs are reached through CSR instructions, not over AXI. Follow the four steps: mtvec and mie, then global MIE; on acceptance the hardware saves mepc, mcause and mtval and clears MIE; the handler removes the cause, MRET returns to mepc and emits an EOI when it returns from an interrupt. For nesting, software saves and restores the CSR context before re-enabling MIE. The specification lists every address and field, including the identity and counter registers.'
 :'1:20. Follow configuration, enabling, claim and EOI. SRCn_CONFIG fixes the behaviour of each source; BAND_CONFIG and ESCALATION_CFG set the shared policy. NEST_MAX limits the active services, and the status registers expose the context. A software trigger writes 0xA5A50001 with the strobes for the key bytes and the set bit. The handler removes the cause before the EOI. RW1C clears the logged events; a hardware event arriving in the same cycle is kept. Every address in the table is an offset inside the 256-byte window; n is 0 to 15.');

 const evidence=cpu?[
 ['Independent model','1,287 instructions with expected results'],
 ['Protocol + state','AXI monitors, scoreboard and SVA through bind'],
 ['Critical cases','IRQ in stall · flush with AXI response · async reset']
 ]:[
 ['Independent model','24 urgency permutations + masks + ties'],
 ['Protocol + state','AXI monitors, registers, stack and SVA through bind'],
 ['Critical cases','edge + claim · nesting · deadline · async reset']
 ];
 const proof=row({width:fill,height:200,gap:55},evidence.map(([h,b])=>col([t(h,35,true,65,ACC),t(b,29,false,115)],563,200,6)));
 add(p,kind,5,'Verification','The functional result and the bus protocol are checked separately',col([await asset('figures/'+kind+'_verification',1800,525),proof,t('ModelSim: 22 CPU/PIC configurations   ·   Verilator: 16 benches with assertions',24,false,40,MUT)],1800,790,12),
 cpu?'1:40. Show the two paths in the diagram: program and stimulus into the DUT, expected results and observations into the checks. The ISA model is independent of the RTL; the memories can delay responses and apply backpressure. The monitors check the transfers, the scoreboard checks the architectural effect, and the SVA attached through bind check the pipeline rules. The hardest cases combine events: an IRQ during a load, a response arriving after a redirect, a counter write meeting an increment. Reset is asserted 2 ns after a rising edge and checked at plus 3 ns, including from an active state. The next slide shows one complete case.'
 :'1:40. Follow the independent reference into the stimulus and the checks. The Python model computes the winner for 24 orderings of the bands, together with masks and ties. The directed tests add the temporal part: claim, EOI, a coincident edge, the stack limit, deadlines and reset. AXI is checked separately; the PULP comparison covers the decoder and a register profile with 96 WSTRB / AW-W / backpressure combinations, plus error and reset cases. It is not a proof of equivalence with the whole PULP library.');

 const w=manifest.find(x=>x.file===(cpu?'cpu_irq':'pic_nesting'));
 const events=cpu?[
 ['1 · New IRQ','LSU busy → claim = 0'],['2 · R handshake','Load complete → S2 may advance'],['3 · Claim','Trap entry; one-cycle pulse']
 ]:[['1 · Claim 8','depth 1 · active 0x100'],['2 · Claim 9','depth 2 · active 0x300'],['3 · Inner EOI','depth 1 · source 8 stays active'],['4 · Outer EOI','depth 0 · active 0']];
 add(p,kind,6,'Critical scenario',cpu?'The IRQ waits for the load to finish before the claim':'Preemption keeps the context; two EOIs close it in order',col([
  await asset('waves/'+w.file,1800,596),
  row({width:fill,height:140,gap:24},events.map(([h,b])=>col([t(h,31,true,55,GOLD),t(b,27,false,80)],cpu?584:432,140,5))),
  t(cpu?'The markers follow the same instruction and the same IRQ request.':'Bus values are hexadecimal; the offered vector is valid while IRQ = 1.',23,false,35,MUT)
 ],1800,790,7),
 cpu?'2:00. Use the markers and the arrows. At 7575 ns the IRQ appears, but lsu_active is still 1, so there is no claim. At 7595 ns RVALID and RREADY are evaluated on the rising edge and the load response is accepted. At 7605 ns the claim and cpu_in_trap appear. A response cannot be abandoned to enter the handler sooner. The test also checks the loaded value and mepc; the waveform shows the ordering behind that result.'
 :'2:00. Walk through the four markers. Claim 8 saves the first context; claim 9 adds the more urgent one and active stays 0x300. The first EOI closes source 9 and restores the context of source 8. The second EOI empties the stack. Seeing two IRQ pulses is not enough: depth and active show whether the state was preserved correctly. State changes on the rising edge; the testbench stimulus is driven 1 ns after it.');

 const results=cpu?['RV32I pipeline, predictor and forwarding integrated','CSRs, traps and AXI access with explicit rules','Execution compared against an independent ISA model']:['Banded priority, nesting and deadlines, all configurable','Registers and CPU handshake integrated with arbitration','Policy checked independently and in concurrent tests'];
 const learned=cpu?['I defined the stall / flush / trap order before integration.','I separated protocol checking from the architectural effect.','I used concurrent scenarios to test the boundaries between blocks.']:['I defined tie cases and the priority of simultaneous events.','I tracked the saved context, not only the winning vector.','I checked arbitration against a model independent of the RTL.'];
 add(p,kind,7,'Conclusions',cpu?'Result: an integrated core, checked instruction by instruction':'Result: configurable arbitration with verified preemption',col([
  row({width:fill,height:610,gap:100},[
   col([t('WHAT I BUILT',30,true,75,ACC),...results.map((v,i)=>t(`${i+1}.  ${v}`,35,false,145))],850,610,14),
   col([t('WHAT I LEARNED',30,true,75,ACC),...learned.map(v=>t(v,33,false,145))],850,610,14)]),
  rule({width:1800,height:2,stroke:'#D7E1E4',weight:2}),
  t('My contribution: design decisions → RTL → integration → verification',31,true,90,ACC)
 ],1800,790,25),
 cpu?'1:00. Close with what I built and what I learned. The result is an integrated CPU whose execution is compared against an independent model. The hard part was defining the ordering at the boundary between memory, pipeline and traps. The internship taught me to turn incomplete requirements into precise contracts, and to write tests that check those contracts. My contribution covers the architectural decisions, the RTL, the integration and the verification.'
 :'1:00. The result is a PIC with a configurable policy and verified preemption, not just an isolated priority resolver. I learned to define the tie case, the simultaneous events and the lifetime of an active context explicitly. The independent model gave me a reference for arbitration, and the directed tests checked the event sequences. This is my contribution, from requirements through RTL to verification.');
 const name=cpu?'RV32I_CPU_Bunea_Cosmin-Andrei.pptx':'PIC_Bunea_Cosmin-Andrei.pptx';
 await (await PresentationFile.exportPptx(p)).save(path.join(OUT,name));
 for(let i=0;i<p.slides.items.length;i++){
  const s=p.slides.items[i];
  await fs.writeFile(`${QA}/${kind}-${i+1}.png`,new Uint8Array(await (await s.export({format:'png'})).arrayBuffer()));
  await fs.writeFile(`${QA}/${kind}-${i+1}.layout.json`,new Uint8Array(await (await s.export({format:'layout'})).arrayBuffer()));
 }
 console.log('EXPORTED',name,'7 slides / 10 minutes');
}
try {await build('cpu');await build('pic');}catch(e){console.error(e.message);process.exitCode=1;}
