// Third version of the two decks: decisions on the architecture slide, verification on two
// slides (the block alone, then the block in the system), registers without addresses.
// Figures come from cpu/docs/tools/deck_v3_figures.py. Earlier versions are kept for comparison.
import fs from 'node:fs/promises';
import path from 'node:path';
import {Presentation,PresentationFile,column,row,text,image,rule,panel,grid,fr,fixed} from '@oai/artifact-tool';

const OUT='output',QA='scratch/rendered_v3',SLIDES=7;
await fs.mkdir(OUT,{recursive:true});await fs.mkdir(QA,{recursive:true});
const INK='#173442',ACC='#006B75',MUT='#526772',GOLD='#A35B17',CARD='#EEF5F5',STRIPE='#F5F9F9';
const FRAME={frame:{left:0,top:0,width:1920,height:1080},baseUnit:1};

const T=(v,size,o={})=>text(v,{name:o.name,width:o.w??'fill',height:o.h??'hug',style:{fontSize:size,bold:!!o.bold,color:o.color??INK,...(o.align?{alignment:o.align}:{})}});
const gapV=h=>column({width:'fill',height:h},[]);
const card=(child,o={})=>panel({name:o.name,fill:o.fill??CARD,borderRadius:12,padding:o.pad??{left:30,right:30,top:18,bottom:18},width:'fill',height:o.h??'fill',justify:o.justify??'center'},child);
async function asset(stem,w,h){
 const b=await fs.readFile('../'+stem+'.svg'),s=b.toString('utf8'),m=s.match(/viewBox="[\d.]+ [\d.]+ ([\d.]+) ([\d.]+)"/);
 if(!m)throw Error('Missing viewBox '+stem);
 const hh=Math.min(h,w/(+m[1]/+m[2])),ww=hh*(+m[1]/+m[2]);
 return row({name:'asset-frame-'+stem,width:w,height:h,gap:0,align:'center',justify:'center'},[image({name:'asset-'+stem,dataUrl:'data:image/svg+xml;base64,'+b.toString('base64'),width:ww,height:hh,fit:'contain',alt:stem})]);
}
function add(p,kind,index,phase,title,body,notes){
 const s=p.slides.add();
 s.compose(column({width:'fill',height:'fill',padding:{left:70,right:70,top:40,bottom:28},gap:0},[
  T(title,48,{bold:true,name:'slide-title'}),gapV(12),rule({width:170,height:4,stroke:ACC,weight:4}),gapV(24),
  column({width:'fill',height:'fill',gap:0},[body]),gapV(14),
  T(`${kind==='cpu'?'RV32I':'PIC'}   ·   ${String(index).padStart(2,'0')} / ${String(SLIDES).padStart(2,'0')}   ·   ${phase}`,20,{color:MUT,name:'footer'})
 ]),FRAME);
 s.speakerNotes.setText(notes);return s;
}
// Two-column table: name in accent, role beside it; rows share the height.
function stripes(head,rows,cols){
 const cell=(v,i,r)=>panel({fill:r%2?STRIPE:'#FFFFFF',padding:{left:22,right:18,top:8,bottom:8},width:'fill',height:'fill',justify:'center'},T(v,i===0?27:26,{color:i===0?ACC:INK,bold:i===0}));
 return grid({width:'fill',height:'fill',columns:cols,rows:[fixed(42),...rows.map(()=>fr(1))],columnGap:0,rowGap:5},[
  ...head.map(h=>panel({padding:{left:22,right:18,top:0,bottom:6},width:'fill',height:'fill',justify:'end'},T(h,24,{bold:true,color:MUT}))),
  ...rows.flatMap((r,k)=>r.map((v,i)=>cell(v,i,k)))
 ]);
}
// Numbers per verification type: the figure, then what it counts.
function stats(head,items){
 return column({width:'fill',height:'fill',gap:0},[
  T(head,24,{bold:true,color:MUT}),gapV(12),
  grid({width:'fill',height:'fill',columns:[fr(1)],rows:items.map(()=>fr(1)),rowGap:10},
   items.map(([n,v])=>card(row({width:'fill',height:'hug',gap:14,align:'center'},[T(n,40,{bold:true,color:ACC,w:122}),T(v,items.length>6?23:24)]),{pad:{left:22,right:20,top:8,bottom:8}})))
 ]);
}
const eventCards=events=>grid({width:'fill',height:'fill',columns:events.map(()=>fr(1)),rows:[fr(1)],columnGap:16},
 events.map(([h,b])=>card(column({width:'fill',height:'hug',gap:6},[T(h,24,{bold:true,color:GOLD}),T(b,22)]),{pad:{left:18,right:14,top:10,bottom:10}})));

async function build(kind){
 const cpu=kind==='cpu',p=Presentation.create({slideSize:{width:1920,height:1080}});

 const cover=p.slides.add();
 cover.compose(grid({width:'fill',height:'fill',columns:[fr(0.8),fr(1.2)],rows:[fr(1)],columnGap:60,padding:{left:100,right:70,top:60,bottom:60},alignItems:'center'},[
  column({width:'fill',height:'hug',gap:0},[
   T('INTERNSHIP · SIEMENS · 2026',26,{color:MUT}),gapV(16),rule({width:220,height:5,stroke:ACC,weight:5}),gapV(36),
   T(cpu?'RV32I Processor':'Interrupt Controller',cpu?84:68,{bold:true}),gapV(10),
   T(cpu?'Three-stage pipeline':'Programmable priority and preemption',cpu?44:34,{color:ACC}),gapV(70),
   T('Bunea Cosmin-Andrei',36,{bold:true}),gapV(8),
   T('Computer Engineering, year III\nAcademic year 2025–2026\nTransilvania University of Brașov',32),gapV(56),
   T('RTL implementation · interfaces · verification',28,{color:MUT})
  ]),
  await asset('presentations/assets/soc_context_v3_'+kind,1000,660)
 ]),FRAME);
 cover.speakerNotes.setText(cpu
  ?'0:30. The project is the RV32I core of the SoC: I specified it, wrote the RTL, connected it to the PIC and verified it. In the figure the CPU has an instruction port, a data port on the interconnect and a direct interrupt link to the PIC.'
  :'0:30. The project is the interrupt controller of the SoC: I specified it, wrote the RTL, connected it to the CPU and verified it. In the figure the PIC has a register port on the interconnect and a direct link to the CPU; its sources are the DMA, the SRAM and the timer.');

 const reqs=cpu?[
  'Full RV32I instruction set;\nFENCE as a no-op, ECALL / EBREAK as traps',
  'Three stages; a load or store completes inside S2',
  '32 × 32-bit registers: 2 read ports, 1 write port, x0 = 0',
  'Branch predictor with a 1-bit counter per entry',
  'Exceptions and external interrupts,\ntaken only between instructions',
  'Machine-mode CSRs: mstatus, mie, mip,\nmtvec, mepc, mcause, mscratch',
  'One central unit for every stall and flush',
  'Two AXI4-Lite masters (instruction, data)\nand an interrupt link to the PIC'
 ]:[
  '16 hardware sources, each level- or edge-triggered',
  '16 software triggers, safe against accidental\nwrites, arbitrated exactly like hardware',
  'Priority bands, with arbitration inside each band',
  'Preemption with nesting;\nthe interrupted context is kept',
  'Spurious interrupts detected, handled and logged',
  'A deadline per source,\nwith automatic priority escalation',
  'One request + 4-bit vector to the CPU,\nacknowledged by a claim',
  'AXI4-Lite register map:\n11 registers, OKAY / SLVERR / DECERR'
 ];
 const reqCell=i=>card(row({width:'fill',height:'hug',gap:26,align:'center'},[T(String(i+1).padStart(2,'0'),38,{bold:true,color:ACC,w:66}),T(reqs[i],32)]));
 const reqGrid=grid({width:'fill',height:'fill',columns:[fr(1),fr(1)],rows:[fr(1),fr(1),fr(1),fr(1)],columnGap:28,rowGap:20},
  [0,1,2,3].flatMap(i=>[reqCell(i),reqCell(i+4)]));
 add(p,kind,2,'Requirements',cpu?'The brief asks for a three-stage RV32I core with prediction and traps':'The brief asks for a PIC with priority bands, nesting and deadlines',
  reqGrid,
 cpu?'1:00. These are the eight requirements from the CPU brief that shaped the design. The full RV32I set, with FENCE treated as a no-op and ECALL and EBREAK handled as traps. Three stages, where a load or store finishes inside S2, so S2 waits for the data bus. A register file with two read ports, one write port and x0 fixed at zero. A predictor with a 1-bit counter per entry. Exceptions and external interrupts, taken only between instructions. The machine-mode CSRs the brief lists. One central unit that decides every stall and flush. And the interfaces: two independent AXI4-Lite masters and the interrupt link to the PIC.'
 :'1:00. These are the eight requirements from the PIC brief. Sixteen hardware sources, each level- or edge-triggered, and sixteen software triggers that must be safe against accidental writes and, once pending, behave exactly like hardware; together they share sixteen arbitration slots. Priority bands instead of a flat priority, preemption with nesting, spurious detection with logging, and a deadline per source with automatic escalation. Towards the CPU, one request with a 4-bit vector, acknowledged by a claim; towards software, eleven registers over AXI4-Lite.');

 const decisions=cpu?[
  ['Predictor','Direct-mapped, 128 entries: index PC[8:2], tag PC[31:9]. 1-bit BHT + BTB + 8-entry RAS. Miss → not taken; trained at commit.'],
  ['Stalls','Only a data access or WFI stalls S2. Load-use costs 0 cycles (S3 → S2 forwarding). S1 parks one word in a skid register.'],
  ['Redirect order','Resolved in S2, one redirect per instruction: interrupt > exception > MRET > misprediction. Flush = valid bit cleared.'],
  ['Nested traps','Entry saves mepc, mcause, mtval and MIE → MPIE. A 16-level trap-kind stack: MRET sends EOI only for an interrupt.'],
  ['Precise errors','Fetch fault → cause 1, load / store fault → 5 / 7, misaligned → 4 / 6 before the bus, bad CSR → illegal. No write-back.']
 ]:[
  ['Bands','4 bands, 2-bit urgency each (BAND_CONFIG). 10-bit key: urgency · priority in band · inverted ID, so the lower ID wins ties.'],
  ['Reconfiguration','Claim pushes ID + key onto the stack. An active source keeps its saved key; a new band counts from its next request.'],
  ['Nesting','16-entry stack, NEST_MAX 1–16 (reset 8). Only a strictly higher key preempts; at the limit no offer, overflow flag.'],
  ['Spurious','Detected at claim, when the request is gone. The level still opens and EOI closes it; logged in SPURIOUS_LOG.'],
  ['Escalation','16-bit deadline counter per source. On a miss: jump to a target band or one urgency step up; optional repeat.']
 ];
 add(p,kind,3,'Architecture and decisions',cpu?'Three stages: S1 fetches, S2 decodes and executes, S3 writes back':'A request is conditioned, ranked by its key and offered to the CPU',column({width:'fill',height:'fill',gap:0},[
  await asset('presentations/assets/'+kind+'_arch_v3',1780,570),gapV(12),
  T(cpu?'THE BRIEF LEFT 23 QUESTIONS OPEN  ·  THE FIVE THAT SHAPED THE PIPELINE':'THE BRIEF LEFT 21 QUESTIONS OPEN  ·  THE FIVE THAT SHAPED THE CONTROLLER',22,{bold:true,color:MUT}),gapV(10),
  grid({width:'fill',height:'fill',columns:decisions.map(()=>fr(1)),rows:[fr(1)],columnGap:18},
   decisions.map(([h,b])=>card(column({width:'fill',height:'hug',gap:8},[T(h,27,{bold:true,color:ACC}),T(b,23)]),{pad:{left:20,right:16,top:12,bottom:12}})))
 ]),
 cpu?'2:30. The figure is the core as built: S1 fetches with the predictor beside it, S2 decodes, reads the registers and executes, including loads and stores, S3 writes back and forwards into S2; the control block with the CSRs sits under S2, and the PIC is on the right. The brief asked 23 questions about the predictor, traps, the buses, the CSRs and stall/flush control, and left the answers to me. Read the figure left to right; the five decisions below follow the same order. Predictor: direct-mapped with 128 entries, indexed by PC bits 8 to 2 and tagged with the upper bits, so a branch that only shares the index misses instead of taking a wrong target; a 1-bit direction, a BTB target and an 8-entry return-address stack for calls and returns. A miss predicts not taken, and only committed branches train it. Stalls: S2 stalls only while a data access is on the bus or during WFI; a load finishes inside S2, so a dependent instruction takes the value from S3 by forwarding and pays no extra cycle. While S2 waits, S1 keeps the fetched word in a skid register, and after a redirect it drains the wrong-path read. Redirects are resolved in S2, one per instruction, in the order interrupt, exception, MRET, misprediction; a flushed stage has its valid bit cleared and becomes a bubble. Traps: entry saves mepc, mcause and mtval and moves MIE into MPIE; a 16-level trap-kind stack remembers whether each open level is an interrupt, so MRET sends an EOI to the PIC only when it closes one. Errors are precise: fetch and data faults, misaligned accesses caught before the bus, and illegal CSR accesses trap without writing back. Parameters: RESET_PC, HART_ID, BP_ENTRIES, RAS_DEPTH.'
 :'2:30. The figure is the controller as built: a request is conditioned (level or edge, software trigger, enable), gets a 10-bit priority key, and the resolver offers the best eligible one to the CPU through a register; the nesting stack below holds the claimed contexts, and the register map configures everything over AXI4-Lite. The brief asked 21 questions about bands, nesting, spurious interrupts, deadlines and software triggers, and left the answers to me. Follow a request from the left: source conditioning, the priority key, the resolver and the registered offer to the CPU; a claim pushes the context on the nesting stack and EOI pops it. Bands: four bands, each with a 2-bit urgency in BAND_CONFIG; the 10-bit key is urgency, priority inside the band and the inverted ID, so one comparison decides and the lower ID wins ties. Reconfiguration: the claim stores the ID and the key on the stack, so changing the band of an active source affects only its next request. Nesting: 16 physical levels, NEST_MAX from 1 to 16, and only a strictly higher key may preempt; at the limit nothing is offered and the overflow flag is set. Spurious: a claim whose request has disappeared still opens a level, so the CPU and the PIC stay in step, and the event is logged. Escalation: a 16-bit counter per source measures the wait; on a missed deadline the source jumps to a target band or moves one urgency step up, optionally again.');

 const sw=cpu
  ?stripes(['CSR','What it does'],[
    ['mstatus','MIE global enable; MPIE holds it during a trap, MRET restores it'],
    ['mtvec','Handler base: direct, or vectored with one entry per interrupt'],
    ['mepc · mcause · mtval','Return PC · cause, bit 31 = interrupt · faulting address or instruction'],
    ['mscratch','Free word for the handler to save context'],
    ['mie','One enable bit per PIC source; also drives the PIC mask'],
    ['mip','Every source pending in the PIC; read-only'],
    ['mcycle · minstret','64-bit cycle and retired-instruction counters; each half writable'],
    ['mhpmcounter3–7','Event counters: mispredictions, fetch waits, data stalls, traps, WFI sleep'],
    ['misa · mhartid · IDs','RV32I in misa; mhartid from HART_ID, tested with two harts']],[fr(0.78),fr(1.62)])
  :stripes(['Register','What it does'],[
    ['SRCx_CONFIG ×16','Level / edge, band, priority in band, 16-bit deadline'],
    ['SRCx_SW_TRIG ×16','Software request: key 0xA5A5 + both upper strobes; cleared by claim or write'],
    ['SRCx_STATUS ×16','Pending, active, escalated, spurious, elapsed cycles, effective band'],
    ['BAND_CONFIG','2-bit urgency for each of the 4 bands'],
    ['ESCALATION_CFG','Jump to a target band or one step up; single or repeated'],
    ['NEST_MAX','Nesting limit 1–16, reset 8; out-of-range writes clamped'],
    ['INT_ENABLE','Per-source enable before arbitration'],
    ['NEST_STATUS · ACTIVE_VEC','Depth, source on top, overflow · source in service'],
    ['SPURIOUS_LOG · INT_STATUS','Sticky events, write 1 to clear; a hardware set wins']],[fr(1.02),fr(1.38)]);
 add(p,kind,4,'Registers',cpu?'The CSRs connect software to traps, counters and the PIC':'The registers set the policy and make the state observable',
  grid({width:'fill',height:'fill',columns:[fr(1),fixed(520)],columnGap:56,alignItems:'center'},[sw,await asset('presentations/assets/'+kind+'_flow_v3',520,820)]),
 cpu?'1:00. These are the CSRs the core needed. mstatus, mtvec, mepc, mcause, mtval and mscratch carry trap entry and return: MIE is copied into MPIE on entry and restored by MRET; mcause bit 31 separates interrupts from exceptions; vectored mtvec gives each interrupt its own entry. mie and mip are the link to the PIC: mie has one bit per PIC source and also drives the PIC mask, so a masked source never blocks the others; mip shows every pending source. mcycle and minstret are 64-bit, and five event counters measure mispredictions, fetch waits, data stalls, traps and WFI sleep. mhartid comes from the HART_ID parameter, tested with two cores on one shared memory. On the right is the order software uses them in.'
 :'1:00. These are the eleven registers the brief asked for, as I defined them. Each source has its configuration (level or edge, band, priority, 16-bit deadline), a software trigger and a status word with the elapsed time and the effective band. A software request needs the key 0xA5A5 written with both upper byte strobes, so a partial write cannot arm a channel; the claim clears it. BAND_CONFIG and ESCALATION_CFG set the shared policy, NEST_MAX the depth, INT_ENABLE the enables. NEST_STATUS and ACTIVE_VEC show the context in service; the logs are write-1-to-clear, and a hardware event in the same cycle wins. On the right is the order of use.');

 const alone=cpu?[
  ['11','programs vs the golden ISA model: 49,149 instructions, each checked at write-back'],
  ['53','official riscv-tests pass (rv32ui + rv32mi), nominal and 40% backpressure'],
  ['50','instruction kinds · all 32 shift amounts\nevery byte lane · 256 memory words'],
  ['925','directed checks: CSRs 293 · reset 217\ncounters 159 · traps 131\npredictor 68 · ALU 57'],
  ['37','SVA properties attached with bind: 17 pipeline / trap, 20 AXI protocol'],
  ['90','coverage bins, all hit over 28 runs: instructions, traps, predictor, PIC claims'],
  ['9 / 9','mutation testing: injected ALU, LSU, counter and trap defects, each caught']
 ]:[
  ['275','golden-model cases: all 256 BAND_CONFIG values + 19 corners · 5,741 checks'],
  ['15','random runs of 20,000 cycles, each cycle equal to a Python cycle model'],
  ['171','feature and same-cycle checks: nesting, spurious, escalation, triggers'],
  ['1,290','register checks: access rules 478\nstatus 424 · reset 388'],
  ['96','AXI4-Lite writes vs PULP axi_lite_regs: 16 WSTRB × 3 orders × 2 stalls'],
  ['10','properties proven with SymbiYosys; 5 / 5 injected defects fail the proof'],
  ['32','SVA properties attached with bind: 12 PIC, 20 AXI protocol'],
  ['4 / 4','mutation testing: mask, tie-break, empty EOI, nesting limit']
 ];
 add(p,kind,5,'Verification · block',cpu?'An independent model checks every instruction the core retires':'An independent model predicts every priority decision',
  grid({width:'fill',height:'fill',columns:[fixed(620),fr(1)],columnGap:40,alignItems:'center'},[
   stats(cpu?'THE CPU ALONE':'THE PIC ALONE',alone),
   await asset('presentations/assets/'+kind+'_e2e_v3',1120,860)]),
 cpu?'1:45. On the right is one test end to end. The golden model is a Python RV32I interpreter written independently of the RTL: it generates the program and the expected PC, destination register and value of every instruction, plus the final data memory. The CPU runs the same program; the bench compares the three values at every write-back and, at the end, all 256 memory words. The table is from the nominal run: a byte store, then LB, LBU and LW of the same word, so sign extension and byte lanes in four lines; model and CPU agree. Besides this directed program, the model generates ten seeded random programs of about five thousand instructions each, 49,149 instructions in all, and every program also runs with extra read latency or random backpressure. On the left, per type: the golden-model programs; the official riscv-tests, rv32ui and rv32mi, where 53 pass at nominal timing and under 40 percent backpressure and the other five of those suites target extensions this core does not include, such as FENCE.I and PMP; the directed benches; the SVA properties attached with bind and run under Verilator; the functional coverage, 92 bins merged over 28 runs, where all 90 reachable bins are hit and the two bins of a source the program masks must stay at zero; and mutation testing, where every injected defect is caught by a named bench.'
 :'1:45. On the right is one test end to end. The golden model is a Python script written from the priority rule, independently of the RTL. It produces 275 cases, every BAND_CONFIG value plus corner cases: the configuration of all 16 sources, the enables, the CPU mask and the active sources, with the expected winner and pending mask. The bench writes the 18 registers over AXI, drives the sources and the mask, and compares four cycles later; the offer itself is registered one cycle after the request. In case 72 source 9 is in the most urgent band but the CPU masks it, so it stays pending and source 15 wins; model and PIC agree. On the left, per type: the golden-model cases; the random traffic, fifteen runs of 20,000 cycles in which random register writes, sources, claims and EOIs drive the PIC and a separate Python cycle model must give the same outputs and state on every cycle; the feature and same-cycle benches; the register benches; the AXI front-end compared with PULP axi_lite_regs; ten properties proven with SymbiYosys for every input sequence, for example that the stack never exceeds sixteen levels and that a claim at the limit changes nothing, where each of five injected defects makes the proof fail; the SVA properties attached with bind; and mutation testing.');

 const system=cpu?[
  ['382','checks, one program on CPU + PIC + mtimer: 9 exception causes, 8 interrupts, WFI wake-up; 4 memory timings'],
  ['34','SoC runs, 767 checks; the CPU runs 16 programs: DMA, timer, PIC, isolation, reset, races'],
  ['133','interrupt checks through the CPU: SW sources 36 · 16 levels 54 · nesting 16 · spurious 15 · escalation 12'],
  ['29','CPU + PIC SVA properties bound in all 23 SoC benches, 51 Verilator runs'],
  ['CI','every push: lint, all CPU / PIC / SoC benches with SVA, coverage and cover gates']
 ]:[
  ['382','checks, CPU + PIC + mtimer program: priority, in-service suppression, masked source'],
  ['36','all 16 software-triggered sources claimed by the CPU with the right vector'],
  ['70','nesting checks through the CPU: 2 levels (16) and all 16 levels (54)'],
  ['15','spurious claim with the real CPU: logged, EOI balanced, next source served'],
  ['12','escalation through the CPU: service order reversed'],
  ['12','PIC SVA properties bound in all 23 SoC benches'],
  ['CI','every push: lint, all PIC / CPU / SoC benches with SVA, coverage and cover gates']
 ];
 const events=cpu?[
  ['1 · CPU takes source 9','claim pulses, cpu_in_trap rises, MIE drops to 0. Both stacks now hold 1 level; active = 200 (bit 9).'],
  ['2 · Source 8 preempts','Handler 9 sets MIE back to 1. Source 8 is more urgent and gets claimed too: 2 levels, active = 300 (8 and 9).'],
  ['3 · Handler 8 returns','Its MRET sends one EOI. Both stacks drop to 1 and active is back to 200; the CPU stays in the trap.'],
  ['4 · Handler 9 returns','Its MRET sends the last EOI. Both stacks reach 0, active is 0 and cpu_in_trap falls.']
 ]:[
  ['1 · Source 9 escalates','It has waited past its 2-cycle deadline: escalated = 200 (bit 9), and it moves to band 0, the most urgent.'],
  ['2 · Source 8 arrives','requests = 300 (8 and 9). Band 1 would beat band 3, but 9 is now in band 0, so the vector stays 9.'],
  ['3 · CPU takes source 9','The CPU sets MIE and claims vector 9 first; active = 200 (source 9 in service).'],
  ['4 · Then source 8','After the EOI of 9 the vector changes to 8 and the CPU claims it; active = 100 (bit 8).']
 ];
 add(p,kind,6,'Verification · system',cpu?'A nested interrupt opens two levels; each MRET closes one':'A missed deadline makes the CPU serve the escalated source first',
  grid({width:'fill',height:'fill',columns:[fixed(520),fr(1)],columnGap:36},[
   stats(cpu?'THE CPU WITH THE PIC':'THE PIC WITH THE CPU',system),
   column({width:'fill',height:'fill',gap:0},[
    await asset('presentations/assets/'+(cpu?'cpu_nesting_v3':'pic_escalation_v3'),1224,cpu?590:560),gapV(12),eventCards(events)])]),
 cpu?'2:15. This case comes from the SoC run, where claim and EOI come from the CPU itself; the windows are cut from one run and each keeps its own time axis. At 1 the CPU claims source 9: trap entry clears MIE and opens level 1 in the CPU trap-kind stack and in the PIC nesting stack. The handler saves mepc and mstatus in registers and sets MIE again. At 2 source 8, with a higher key, is offered and claimed inside that handler: two levels on both sides; PIC active is a bitmask in hex, so 300 means sources 8 and 9 are both in service. At 3 the inner MRET restores MIE from MPIE and sends exactly one EOI; the PIC pops back to source 9, and cpu_in_trap stays high because a level is still open. At 4 the outer MRET sends the last EOI and both stacks are empty. On the left are the system-level numbers: the CPU, PIC and mtimer program; the SoC regression, which also drives the error paths, such as accesses outside every window, DMA faults, reset in the middle of traffic and the CPU and the DMA writing the same words; and the interrupt checks that go through the CPU, up to sixteen nested levels and a spurious claim. All of it runs in CI on every push: lint, every bench with SVA, the coverage gate and the cover gate.'
 :'2:15. This case comes from the SoC run, where the CPU itself claims the sources. Source 8 is in band 1 and source 9 in band 3, so 8 is nominally more urgent; only 9 has a deadline, two cycles, and ESCALATION_CFG jumps to band 0. Both are raised while the CPU still has MIE cleared. At 1 source 9 misses its deadline and escalates to band 0. At 2 source 8 arrives, and the offer stays on 9. At 3 the CPU sets MIE and claims 9 first; the stack saves its ID and key. At 4, after the EOI of 9, the offer moves to 8 and the CPU claims it. The escalation changes which handler the processor runs first. On the left are the system-level numbers: sixteen nested interrupts climb and unwind in order with the real CPU, and a source that drops in the claim cycle is logged as spurious while its EOI still closes the level. All of it runs in CI on every push: lint, every bench with SVA, the coverage gate and the cover gate.');

 const built=cpu?['3-stage RV32I: S3 → S2 forwarding, direct-mapped predictor, precise traps','CSR file, 64-bit counters, CPU–PIC link: mask, pending, claim, EOI','Golden ISA model with random programs, riscv-tests, SVA, mutation testing']
  :['4 bands with programmable urgency and a 10-bit priority key','16-level nesting stack, spurious detection, deadline escalation','Golden priority model, cycle model and formal proofs of the stack'];
 const learned=cpu?[
  'Most of the thinking went into the moments when several things happen in one cycle: an interrupt, a stall and a wrong branch together. Writing their order down before the RTL made everything after it easier.',
  'Interrupts made me think about two blocks at once. The CPU and the PIC each keep their own stack, and nesting works because the two move in step, one level at a time.',
  'Writing the golden model in Python, apart from the Verilog, meant understanding every instruction twice: once for the model, once for the hardware.',
  'I stopped trusting a passing test by default. Injecting a defect into the RTL and watching the right test go red is what gave me confidence in the rest.'
 ]:[
  'A priority encoder looks simple until two requests tie or arrive in the same cycle. I learned to write down a rule for every such case before touching the RTL.',
  'Saving the key at claim was a small idea with a big effect: software can reconfigure a source at any moment and the stack stays correct.',
  'Looking at the PIC and the CPU together showed me where the mask belongs: inside the PIC, so a source the CPU ignores never holds back the others.',
  'Writing the priority model in Python, apart from the Verilog, meant understanding every rule twice, and that is where the design became clear to me.'
 ];
 const builtCard=card(column({width:'fill',height:'fill',gap:0},[
  T('WHAT I BUILT',28,{bold:true,color:ACC}),gapV(16),
  grid({width:'fill',height:'fill',columns:[fr(1)],rows:built.map(()=>fr(1)),rowGap:10,alignItems:'center'},
   built.map((v,i)=>row({width:'fill',height:'hug',gap:18,align:'start'},[T(`${i+1}.`,31,{bold:true,color:ACC,w:40}),T(v,31)])))
 ]),{justify:'start',pad:{left:36,right:32,top:28,bottom:20}});
 const learnedCard=card(column({width:'fill',height:'fill',gap:0},[
  T('WHAT I LEARNED',28,{bold:true,color:ACC}),gapV(16),
  grid({width:'fill',height:'fill',columns:[fr(1)],rows:learned.map(()=>fr(1)),rowGap:12,alignItems:'center'},
   learned.map(v=>row({width:'fill',height:'hug',gap:16,align:'start'},[T('–',28,{color:ACC,w:26}),T(v,27)])))
 ]),{justify:'start',pad:{left:36,right:32,top:28,bottom:20}});
 add(p,kind,7,'Conclusions',cpu?'Result: an integrated core, checked instruction by instruction':'Result: configurable arbitration with verified preemption',column({width:'fill',height:'fill',gap:0},[
  grid({width:'fill',height:'fill',columns:[fr(0.82),fr(1.18)],rows:[fr(1)],columnGap:28},[builtCard,learnedCard]),
  gapV(20),
  panel({fill:ACC,borderRadius:12,padding:{left:40,right:40,top:20,bottom:20},width:'fill',height:'hug'},T('Thank you! Questions are welcome.',32,{bold:true,color:'#FFFFFF',align:'center'}))
 ]),
 cpu?'1:00. On the left is what I built: the three-stage core with forwarding, the direct-mapped predictor and precise traps; the CSR file and the link to the PIC; and the verification around it. On the right is what I take away from it, in my own words. Most of the design work was in the cycles where several events meet, and writing their order down first paid off. The interrupt path taught me to think about the CPU and the PIC as one system, each with its own stack. Writing a separate Python model made me understand every instruction twice. And mutation testing changed how I read a passing test.'
 :'1:00. On the left is what I built: four bands with programmable urgency and a 10-bit key, the nesting stack with spurious detection and escalation, and the checks around it: a priority model over every band configuration, a cycle model for random traffic and formal proofs of the stack. On the right is what I take away from it, in my own words: ties and same-cycle events need a rule before the RTL; saving the key at claim keeps the stack correct under reconfiguration; the CPU mask belongs inside the PIC; and a separate Python model made every rule clear twice.');

 const name=cpu?'RV32I_CPU_Bunea_Cosmin-Andrei_v3.pptx':'PIC_Bunea_Cosmin-Andrei_v3.pptx';
 // A deck open in PowerPoint is locked; keep rendering the previews and report it.
 let saved=true;
 try{await (await PresentationFile.exportPptx(p)).save(path.join(OUT,name));}
 catch(e){if(e.code!=='EBUSY')throw e;saved=false;console.warn('LOCKED',name,'(open in another program); previews only');}
 for(let i=0;i<p.slides.items.length;i++){
  const s=p.slides.items[i];
  await fs.writeFile(`${QA}/${kind}-${i+1}.png`,new Uint8Array(await (await s.export({format:'png'})).arrayBuffer()));
 }
 if(saved)console.log('EXPORTED',name,`${SLIDES} slides / 10 minutes`);
}
try {await build('cpu');await build('pic');}catch(e){console.error(e.stack||e.message);process.exitCode=1;}
