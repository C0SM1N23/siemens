"""Document order and functional explanations, following the supplied spec template."""

FIGURE_TEXT={
'figures/cpu_essential': 'Follow the instruction from S1 through IF/DX to S2, then through DX/WB to S3. The lower paths carry writeback forwarding, execution status, predictor updates and redirects; the LSU completes a memory access before S2 advances.',
'figures/pic_essential': 'An enabled HW or software request enters priority selection. The registered offer identifies the candidate; claim saves its ID and priority, while EOI restores the previous active context. The return paths carry masks, the saved priority threshold and the depth limit.',
'figures/cpu_verification': 'The program image supplies instructions and initial data to the responders. Checks compare observed architectural state with expected results, while protocol monitors and assertions inspect the bus and pipeline independently.',
'figures/pic_verification': 'Register-access tasks configure the PIC and drive source, mask and claim/EOI events. The independent model supplies expected winners and pending masks; the checkers also inspect register responses and service-state transitions.',
'figures/cpu_software': 'Software programs the trap destination and interrupt masks before enabling delivery. On acceptance, hardware records the return PC and cause; the handler services the source and MRET restores execution.',
'figures/pic_software': 'Configuration determines which source can be offered and when it may preempt. The handler removes the source condition before EOI, while sticky event registers retain diagnostic information until software clears it.',
'waves/cpu_fetch': 'ARVALID remains asserted until the instruction address is accepted. The R handshake supplies the instruction to IF/DX; the address trace shows the next sequential fetch.',
'waves/cpu_load': 'The load holds S2 while its request or response is pending. At the RVALID/RREADY handshake, the data is available and s2_advance permits the instruction to enter writeback.',
'waves/cpu_store': 'AW and W are accepted independently. The store completes only when the B response is accepted, so an earlier address or data handshake alone does not release the instruction.',
'waves/cpu_irq': 'The interrupt arrives while the LSU is active. Marker 2 identifies the accepted load response; marker 3 shows the registered claim and trap-active state at the next instruction boundary.',
'waves/cpu_redirect': 'The resolved branch differs from the prediction, causing redirect. IF/DX is invalidated so younger work cannot commit; an outstanding fetch response still completes its AXI transaction.',
'waves/cpu_reset': 'Reset is asserted while an instruction request is waiting. ARVALID clears at the reset event, before the next rising edge; after release the fetch request resumes from RESET_PC.',
'waves/cpu_reset_stopped': 'The test stops the clock with S3 valid, then asserts reset at 97 ns. S3 clears without another clock edge, isolating asynchronous reset behavior from normal pipeline advancement.',
'waves/pic_claim': 'Source 3 is offered and claimed once. Claim increases the active depth; after the source clears, EOI returns the controller to depth zero.',
'waves/pic_nesting': 'Source 9 preempts source 8. The active mask keeps both sources during nesting; the first EOI restores source 8 and the second empties the stack. The offer vector is meaningful while cpu_irq_o is high.',
'waves/pic_spurious': 'The level source disappears after its offer but before claim. The claim creates a service context marked spurious, allowing the CPU to unwind it through the same EOI sequence.',
'waves/pic_edge_claim': 'A second source edge is sampled with the claim of the first event. The edge latch remains set, and the source is offered again after EOI.',
'waves/pic_escalation': 'Source 1 initially wins the tie. Source 2 reaches its ten-cycle deadline; the escalation event changes its effective priority, and the registered offer changes to source 2 on the following edge.',
'waves/pic_reset': 'The controller starts with active nested service and enabled sources. Reset clears both depth and INT_ENABLE between clock edges; the test checks the state one nanosecond after assertion.'}

CPU_RULES=[
('Branch prediction', 'Prediction chooses the next fetch address; S2 remains responsible for resolving the instruction and committing any predictor update.',[
('Table and mapping','BP_ENTRIES=128 by default. A direct-mapped entry uses PC[IDX_W+1:2], with IDX_W=log2(BP_ENTRIES); upper PC bits form the tag. An alias replaces that indexed entry.'),
('Unseen branch','Invalid entry or tag miss predicts not taken, selecting PC+4. Each valid entry stores one direction bit and a 32-bit target.'),
('Misprediction','At S2, compare predicted direction with the resolved direction; for a taken transfer also compare targets. A mismatch redirects fetch when S2 advances.'),
('Update point','A live, non-faulting branch/jump updates direction, tag and target at S2 completion, including the correcting edge. Wrong-path or trapping instructions do not train the table.'),
('Trap entry / return','BTB/BHT and RAS are preserved across traps and MRET; reset clears them.'),
('Call / return','RAS_DEPTH=8 by default; zero disables the stack. JAL/JALR hints use x1/x5. Return entries use the stack top, falling back to the BTB target when empty. Full pushes replace the oldest entry; empty pops have no effect.')]),
('Trap entry, return and competing events','Trap acceptance cancels the current S2 instruction and redirects younger fetch work. Older S3 work can still complete; the saved PC identifies where software must resume.',[
('Entry edge','When trap_take and s2_advance are true, save mepc/mcause/mtval, copy MIE to MPIE, clear MIE, invalidate the incoming IF/DX entry and suppress the S2-to-S3 valid bit.'),
('Return PC','Synchronous exceptions save the faulting instruction PC. An ordinary interrupt saves the preempted S2 PC. An interrupt accepted at WFI saves PC+4; software advances mepc when it elects to skip a synchronous fault.'),
('Competing redirect','An eligible interrupt preempts the current instruction before synchronous exception evaluation. Otherwise a synchronous exception wins over MRET and branch correction. Redirect requires S2 completion.'),
('Data transfer in progress','lsu_active prevents IRQ acceptance until the outstanding access completes. An error response causes the load/store access-fault exception at completion.'),
('Nested service','Trap entry clears MIE. Software must save trap CSRs and handler context before enabling nested interrupts. A 16-level trap-kind stack distinguishes interrupt returns from exception returns; software must keep combined depth at or below 16.'),
('MRET','Restore MIE from MPIE, set MPIE, redirect to mepc and pop one trap level. Emit EOI only if the popped level was an interrupt; cpu_in_trap remains high while any level is open.'),
('MIE write versus IRQ','Arbitration uses the current MIE value. With MIE=0, a CSR write enabling it completes before later acceptance. With MIE=1 and an eligible offer, IRQ preempts the CSR instruction; that instruction can execute after return.'),
('WFI','Hold S2 until a locally enabled offer exists. Wakeup does not require global MIE; entering the interrupt handler does.')]),
('Stall, forwarding and flush','Centralized pipeline control decides advancement and invalidation. A stalled memory instruction holds its operands in S2 while S3 receives bubbles after older work completes.',[
('Fetch unavailable','No fetched instruction inserts an IF/DX bubble when S2 can advance. Fetch tracks its own address/response and may retain one returned instruction while S2 is stalled.'),
('Data access / WFI','lsu_busy or wfi_wait holds IF/DX. S3 valid is cleared while S2 is held, preventing repeated writeback.'),
('Load-use dependency','S2 waits for the load response. Once the load reaches S3, its result forwards to either matching S2 operand; no extra load-use bubble is needed. x0 is excluded from forwarding.'),
('Stall and redirect','A redirect is gated by s2_advance, so the active data access completes first. At the advancing edge, trap/MRET/correction determines the new fetch address and IF/DX receives a bubble.'),
('Wrong-path fetch','An accepted AR cannot be cancelled. An outstanding wrong-path response is drained and discarded; it cannot create a GPR write or instruction-access exception.'),
('Pipeline registers','IF/DX stores instruction, PC, prediction and fault with valid. DX/WB stores the destination and result choices with valid. Reset clears valid bits and initializes the instruction to ADDI x0,x0,0; invalid payloads cannot execute.')]),
('Independent memory ports','Instruction fetch and the LSU have separate AXI channel state. They can progress concurrently; the pipeline consumes their results in order.',[
('Both ports stalled','Hold each VALID and payload until its own READY. S2 retains the data operation; a fetched instruction can be held until S2 becomes available.'),
('Read / write errors','Instruction RRESP[1] becomes instruction-access fault (cause 1). Data RRESP[1]/BRESP[1] becomes load/store access fault (5/7); the faulting instruction cannot write its destination.'),
('Future AXI4 integration','An external Lite-to-Full wrapper can emit single-beat transactions with fixed ID, LEN=0, SIZE=2 and no outstanding reordering. Bursts or multiple outstanding instructions would require new request tracking and verification; the current CPU ports remain AXI4-Lite.')])]

PIC_RULES=[
('Source aggregation and offer timing','The controller maintains one service identity per source slot. HW and SW requests for the same slot share configuration, priority, deadline and active state.',[
('HW / SW collision','The enabled request is (selected HW level/latched edge OR SW pending). Simultaneous HW and SW activity produces one candidate, not two queued interrupt identities.'),
('Pending storage','Edge and software requests use one pending bit per slot; repeated events before consumption coalesce. Level sources remain pending while the external line remains asserted.'),
('Same-cycle events','A fresh edge wins over clearing the previous edge on claim. A keyed software set wins over the claim clear. After EOI, a retained request may be offered again.'),
('Priority key','Four configurable 2-bit band urgencies, a per-source 4-bit intra-band priority, then inverted 4-bit ID. Select the largest key; lower source ID wins the final tie.'),
('Reconfiguration','Changing an active source configuration affects future arbitration; the active stack entry keeps the key captured at claim until that context is popped.'),
('Offer latency','Request conditioning and key comparison are combinational; IRQ/vector are registered at posedge. The claim consumes a one-cycle delayed copy of the offered vector.'),
('Depth enforcement','Only an inactive, enabled, CPU-unmasked source above the saved top key is eligible. depth < NEST_MAX is additionally required for an offer; an eligible blocked source sets OVF.')]),
('Spurious and deadline policy','The service decision uses the request state at claim. Deadline accounting covers enabled requests waiting for service, including requests masked at the CPU.',[
('Spurious criterion','A claim is spurious when its saved source ID is no longer requested. Preserve the claimed service context, mark SRCx_STATUS.SPUR, and set SPURIOUS_LOG and INT_STATUS.SPUR; EOI unwinds it normally.'),
('Fast-clearing source','A level pulse gone before claim meets the same spurious criterion. Edge mode latches a pulse until claim and is the appropriate configuration when the event must survive deassertion.'),
('Deadline storage / count','SRCx_CONFIG[31:16] stores the 16-bit cycle deadline. Each slot counts while enabled pending and inactive; zero disables counting. CPU masking does not pause the timer.'),
('Escalation','At deadline, either jump to the configured target band or select the next strictly greater programmed urgency. MULTI enables another escalation at each further deadline; the effective band cannot advance beyond the highest urgency.'),
('After service / idle','On the first edge observing no wait, clear the counter and wait-local escalation flag and restore the configured band. Sticky INT_STATUS.ESC remains until software clears it.'),
('Software injection','Write 0xA5A50001 to SRCx_SW_TRIG with WSTRB[3:2]=11 and WSTRB[0]=1. Clear explicitly with bit 0=0, or automatically by claim. A software-only request follows the same deadline policy as hardware.')])]


CPU_LIMITS=[
('FENCE.I is not implemented and traps as an illegal instruction.','Load instruction memory before the core executes from it; code cannot modify itself.'),
('Misaligned loads and stores trap (cause 4 / 6).','Align the data, or emulate the access in the trap handler.'),
('The user counters cycle, time and instret (0xC00–0xC02) and mcountinhibit (0x320) are absent and trap.','Read mcycle and minstret in machine mode.'),
('The trap-kind stack holds 16 levels, interrupts and exceptions combined.','Keep the combined nesting depth at or below 16, for example through NEST_MAX.')]
PIC_LIMITS=[
('A level request that drops before the claim produces a spurious claim.','Use edge mode for short pulses. The handler reads SRCx_STATUS.SPUR and still sends the EOI.'),
('A software trigger needs WSTRB[3:2] and WSTRB[0].','Arm it with a 32-bit store; byte and halfword stores cannot set a request.'),
('Lowering NEST_MAX below the current depth keeps the open levels.','Offers resume once EOIs bring the depth below the limit; change NEST_MAX while no source is in service for immediate effect.')]


def render_document(doc,api):
    T,esc,fig,wave=(api[x] for x in ('T','esc','fig','wave'))
    cpu='RV32I' in doc.filename
    design=doc.filename.startswith('Design')
    kind='CPU' if cpu else 'PIC'
    pages={title:(content,wide) for title,content,wide in doc.pages}
    result=[]
    def para(text):return r'\noindent '+esc(text)+r'\par\medskip'+'\n'
    def emit(title,body,level='subsection',parents=(),wide=False,brk=None):
        # Sections start a page; a lower heading stays with the content it introduces.
        if brk is None:brk=level=='section' or any(lev=='section' for lev,_ in parents)
        result.append(r'\clearpage' if brk else r'\needspace{7\baselineskip}')
        if wide:result.extend([r'\newgeometry{top=15mm,bottom=15mm,left=16mm,right=16mm}',r'\begin{landscape}',r'\thispagestyle{plain}'])
        for lev,head in parents:result.append('\\'+lev+'{'+esc(head)+'}')
        result.extend(['\\'+level+'{'+esc(title)+'}',body])
        if wide:result.extend([r'\end{landscape}',r'\restoregeometry'])
        # A section opened on a landscape page still names the pages after it.
        if wide and level=='section':result.append(r'\sectionmark{'+esc(title)+'}')
    def take(title,new=None,level='subsection',parents=(),lead=None):
        # A table never opens a section: lead with what the reader should take from it.
        body,wide=pages.pop(title)
        emit(new or title,(para(lead) if lead else '')+body,level,parents,wide)
    purpose=('the implemented RTL, programming model and integration contracts' if design else 'the simulation strategy, stimulus, reference models and acceptance checks')
    block=('RV32I three-stage CPU' if cpu else 'programmable interrupt controller')
    emit('Introduction','','section')
    emit('Purpose of the document',
         para(f'This specification describes {purpose} of the {block}. It is intended for hardware designers, verification engineers and software developers integrating the block.')
         +para('It defines the behaviour that the RTL must show at its interfaces.'),brk=False)
    emit('Validity of the document',
         para('The documented configuration is the RTL in cpu/hdl and the associated CPU/PIC and SoC simulation environments. Interface adaptations from the supplied briefs are identified in the integration section.')
         +para('Revision 2.2 of 23 September 2026 describes the delivered state of that RTL.'),brk=False)
    terms=[('AXI4-Lite','Single-beat AXI read/write channels.'),('CSR','Control and status register.'),('DUT','Device under test.'),('EOI','End of interrupt; completes one service level.'),('IRQ','Interrupt request.'),('NBA','Nonblocking-assignment update region in simulation.'),('PIC','Programmable interrupt controller.'),('SVA','SystemVerilog Assertions.')]
    if cpu:terms += [('BHT / BTB','Branch direction / target tables.'),('RAS','Return-address stack.'),('LSU','Load/store unit.'),('S1 / S2 / S3','Fetch / decode-execute / writeback.')]
    emit('Definitions of terms and abbreviations',T(['Term','Meaning'],sorted(terms),[.23,.77]),brk=False)
    emit('Relationship with other documents',
         para('The documents below are the ones this specification is derived from or read with.')
         +T(['Document','Version / date','Author','Relationship'],[
        ('RV32I 3-Stage Pipeline CPU' if cpu else 'Programmable Interrupt Controller with Advanced Scheduling','Draft, '+('1 July 2026' if cpu else '26 June 2026'),'D. Borzasi, Siemens','Functional requirements; see section 2.'),
        ('Spec table of contents and templates','2 September 2026','D. Borzasi, Siemens','Document structure and verification-plan template.'),
        (f'{"Verification" if design else "Design"} Specification — {kind}','Rev. 2.2, 23 September 2026','C.-A. Bunea','Companion document.')]
        +([('Design Specification — '+('PIC' if cpu else 'RV32I CPU'),'Rev. 2.2, 23 September 2026','C.-A. Bunea','Other side of the CPU–PIC interrupt link.')] if design else [])
        +([('RISC-V Unprivileged ISA','20191213','RISC-V International','Instruction semantics.'),('RISC-V Privileged Architecture','20211203','RISC-V International','Machine-mode CSRs and traps.')] if cpu else [])
        +[('AMBA AXI and ACE Protocol Specification','IHI0022E','Arm','AXI4-Lite ports.'),('IEEE Std 1364 (Verilog)','2005','IEEE','RTL language.')],[.34,.22,.18,.26]))
    emit('Notes on the notation used',
         para('Signal and register names follow the RTL. Addresses and waveform bus values are hexadecimal; time is in ns and widths are in bits. Register offsets are byte offsets; CSR addresses are instruction-encoded indices.')
         +T(['Notation','Meaning'],[
        ('Fixed-width name','A Verilog module, port, file or script name, spelled as in the source.'),
        ('Signal suffix _i / _o','Module input / output, seen from inside that module.'),
        ('[a:b]','Bit range, most significant bit first.'),
        ('S1 / S2 / S3' if cpu else 'Source slot','Pipeline stage names used throughout the document.' if cpu else 'One of the 16 arbitration identities; x or n denotes its index 0–15.'),
        ('posedge +1 ns','A testbench stimulus time, one nanosecond after the sampling edge.')],[.26,.74]),brk=False)

    if design:
        take('Scope and original requirements','Requirements and integration',parents=(('section','Specifications and system integration'),),
             lead=('The table sets each requirement of the brief RV32I 3-Stage Pipeline CPU against the contract implemented in rv32i_cpu_top, including the points where the two differ. In the SoC, the instruction port reaches the instruction memory, the data port reaches data memory, the SRAM and the peripheral registers through the SoC decoder, and the interrupt link connects directly to the PIC; the address map is in soc/README.md.' if cpu else
                   'The table sets each requirement of the brief Programmable Interrupt Controller with Advanced Scheduling against the contract implemented in pic.v and axi_lite_slave.v. In the SoC, the register port sits on the CPU data decoder; sources 0–3 are the DMA channels, 4 the SRAM and 7 the timer, and the remaining inputs are tied low.'))
        if not cpu:
            take('Module configuration and integration constraints','Configuration and integration limits',
                 lead='The module has no Verilog parameters: every quantity is either fixed in the RTL or programmed through a register. The first table lists the fixed quantities; the second states what an integrator has to guarantee outside the block.')
            emit('Interface adaptations',para('The integrated CPU/PIC interface resolves the different source counts in the two drafts. The following choices define the implemented connection and arbitration timing.')+T(['Brief item','Implemented contract'],[
                ('CPU brief IRQ interface','8 request bits / 3-bit ID / 8 acknowledge bits become one offer, 4-bit source ID, 16-bit pending/mask and scalar claim/EOI.'),
                ('Claim / completion','Claim starts active service and consumes latched requests. The added EOI input completes service and pops one context.'),
                ('Resolution pipeline','The PIC brief describes staged resolution. This RTL resolves eligibility and the priority key combinationally and registers the offer; there are no successive registered arbitration stages.')],[.34,.66]))
        take('Architecture','Overview of overall structure',level='section')
        if cpu:
            take('Pipeline and control contract',
                 lead='Each stage owns one part of an instruction, and only S2 decides when an instruction is finished. The table states what each stage is responsible for, and which redirect wins when several are requested in the same cycle.')
            emit('Instruction groups',para('Integer instructions execute in order. Loads and stores complete in S2; CSR effects also commit there, while GPR writeback occurs in S3.')+T(['Group','Implemented instructions / behavior'],[
                ('Arithmetic / upper immediate','ADD, ADDI, SUB, LUI, AUIPC.'),('Logic','AND/ANDI, OR/ORI, XOR/XORI.'),('Shift','SLL/SLLI, SRL/SRLI, SRA/SRAI.'),('Compare','SLT/SLTI, SLTU/SLTIU.'),('Control transfer','BEQ, BNE, BLT, BGE, BLTU, BGEU, JAL and JALR.'),('Load / store','LB, LH, LW, LBU, LHU; SB, SH, SW. Naturally aligned accesses only.'),('System','ECALL, EBREAK, FENCE as a no-op; CSRRW/CSRRS/CSRRC and immediate variants; MRET and WFI.'),('Unsupported encoding','Illegal-instruction exception, including M/A/C instructions and FENCE.I.')],[.28,.72]))
            for title,lead,rows in CPU_RULES:emit(title,para(lead)+T(['Decision','Behaviour'],rows,[.25,.75]))
        else:
            take('Arbitration and service contract',
                 lead='Arbitration answers one question per cycle: which enabled source, if any, may be offered to the CPU. The table fixes how the winner is chosen, when a candidate may preempt an active context, and what the claim records.')
            for title,lead,rows in PIC_RULES:emit(title,para(lead)+T(['Decision','Behaviour'],rows,[.25,.75]))
            for title in ('Level request, claim and EOI','Preemption and nesting','Edge capture and spurious claims','Deadline escalation'):take(title)
        # Hardware contracts precede the complete software register descriptions.
        if cpu:
            body,_=pages.pop('Module parameters')
            ports,_=pages.pop('Hardware interface')
            emit('Hardware interface',para('The two memory ports and the PIC link are independent interfaces. All ports are digital and synchronous to the rising edge of clk_i; rst_n_i is the only asynchronous input.')+body+ports,parents=(('section','Interfaces'),))
            take('Reset contract',level='subsubsection',
                 lead='Reset must leave the core in a state software can start from, without needing a clock edge to get there. The table lists what reset forces; the waveform below shows it interrupting a fetch that is already in progress.')
            for title in ('Instruction AXI4-Lite interface','Data AXI4-Lite interface','Interrupts and redirects'):take(title,level='subsubsection')
            take('CSR address map','Software interface',
                 lead='The CSR file is the only software-visible interface of the core, and it is reached through CSR instructions rather than through the AXI ports. The map lists every implemented address with its access class and reset value; the subsections that follow give the fields of each register.')
            for title in list(pages):
                if title.startswith('CSR fields:'):take(title.removeprefix('') ,level='subsubsection')
            take('Programming and integration','Programming sequence',level='subsubsection',
                 lead='The order below is the one the hardware assumes: a handler address and the masks must exist before delivery is enabled. The second table lists the limits that software written for this core has to respect.')
        else:
            take('Hardware interface',parents=(('section','Interfaces'),),
                 lead='All ports are digital and synchronous to the rising edge of clk_i; rst_n_i is the only asynchronous input. The ports are the 16 source inputs, the CPU handshake (offer to the CPU, claim and EOI back) and the AXI4-Lite register port.')
            take('Reset and register-access contract',level='subsubsection')
            take('Register address map','Software interface',
                 lead='Every software-visible control and status bit of the controller lives in one 256-byte AXI4-Lite window. The map lists each offset with its access class and reset value; the subsections that follow give the fields of each register.')
            for title in list(pages):
                if title.startswith('Register fields:'):take(title,title.removeprefix('Register fields: '),level='subsubsection')
            take('Programming sequences',level='subsubsection',
                 lead='A source is configured while it is disabled, enabled once its policy is set, then claimed and completed by the handler. The second table names the registers that make that state observable while the system is running.')
        take('Reuse and integration by another developer','Reuse and reusability',level='section',
             lead=('The core contains no third-party component. rv32i_alu, rv32i_imm_gen, rv32i_decode and rv32i_regfile can be reused unchanged in another RV32I datapath; rv32i_branch_predictor is sized by ENTRIES and RAS_DEPTH. Reusing the whole core:' if cpu else
                   'The one reused component is the register front end axi_lite_slave (section 6.1), which the machine timer also uses. Reusing the controller:'))
        modules=[key for key in pages if key.startswith(('Module contract:','Register-interface module:'))]
        # Each module keeps its numbered 6.x.1 / 6.x.2 headings; the contents list stops at 6.x.
        emit('Design of submodules',para('Submodule ports are synchronous to the rising edge of clk_i and rst_n_i resets asynchronously; combinational modules have neither.')+r'\addtocontents{toc}{\protect\setcounter{tocdepth}{2}}',level='section')
        for i,title in enumerate(modules):
            name=title.split(': ',1)[1]
            details={
                'rv32i_fetch_unit':'An address request is retained until AR handshake, then inflight tracks the owed R response. A returned instruction is either consumed by S2 or retained in the holding slot. Redirect drops held data and marks an owed response for discard; the next request uses the redirected PC when the slot is free.',
                'rv32i_lsu':'S_IDLE accepts a legal request and selects S_RD or S_WR. S_RD waits for address acceptance and an R handshake; S_WR collects AW and W independently, then waits for B. The response handshake returns the unit to S_IDLE and releases S2. Request address, write data and strobes remain latched during the transaction.',
                'rv32i_branch_predictor':'The lookup is combinational and an update is committed on posedge. The prediction and update policies, including aliases, cold entries and trap preservation, are specified in section 3.3.',
                'rv32i_csr_file':'A CSR instruction reads the pre-write value. RW replaces bits, RS sets bits and RC clears bits; immediate forms zero-extend the five-bit operand. Trap entry has priority over software writes. Counter writes take priority over increment and preserve the unaddressed half.',
                'rv32i_hazard_unit':'The unit forms s2_advance from LSU/WFI blocking conditions. An advancing redirect inserts an IF/DX bubble; trap entry additionally suppresses S2 writeback. Forwarding matches the valid S3 destination against each S2 source, excluding x0.',
                'axi_lite_slave':'AW and W are captured independently and one register-write pulse is issued after both are available. BRESP is retained until BREADY. An AR handshake samples the peripheral read mux and RRESP, which remain stable until RREADY. Register acceptance selects OKAY or SLVERR.',
                'rv32i_decode':'Field extraction is purely combinational: opcode, funct3, funct7, the three register indices and the CSR address are sliced from fixed instruction bit positions. The module applies no legality check; an unsupported encoding is rejected by rv32i_control.',
                'rv32i_control':'A case over the opcode, refined by funct3 and funct7, produces the control set for one instruction. An encoding that matches no supported case asserts illegal_o and leaves the write-enable and memory controls inactive, so a rejected instruction cannot change architectural state.',
                'rv32i_imm_gen':'The immediate format is selected from the opcode: I, S, B, U or J. Each form is assembled from its instruction bit fields and sign-extended to 32 bits, with the implicit zero bit added for the B and J displacements.',
                'rv32i_regfile':'Both read ports are combinational, so an operand is available in the cycle it is addressed. A write commits at posedge when RegWrite_i is high and the destination is nonzero; index zero is never written and always reads as zero. Reset clears all 32 registers.',
                'rv32i_alu_top':'The unit selects the second operand between rs2 and the immediate, then translates the generic operation class from the decoder, together with funct3 and funct7, into the concrete ALU function. It holds no state.',
                'rv32i_alu':'One combinational block computes the selected function over the two operands: addition and subtraction, the bitwise operations, logical and arithmetic shifts by the low five bits of the second operand, and the signed and unsigned comparisons that produce a zero-or-one result.',
                'rv32i_branch_unit':'The comparison of the two register operands is combined with the decoded branch condition, or with an unconditional jump, to produce pc_src_o. The target is the instruction PC plus the displacement, except for JALR, where it is the first operand plus the immediate with bit 0 cleared.',
                'rv32i_exception_unit':'Candidate causes are evaluated for the instruction in S2 and one is selected by fixed priority: fetch fault, illegal instruction, environment call or breakpoint, then address misalignment, then a completed data access that returned an error. The selected cause also determines the mtval payload. A misaligned address is reported before the transaction is issued, so a faulting access never reaches the bus.',
                'rv32i_writeback_mux':'The select encoding chooses among the ALU or CSR result, the extended load data and the sequential PC+4 link value. The chosen value is what S3 writes to the destination register and what the forwarding path returns to S2.'}
            assert name in details,('Missing functional description',name)
            body,wide=pages[title];pages[title]=(body+para(details[name]),wide)
            take(title,title.split(': ',1)[1])
        result.append(r'\addtocontents{toc}{\protect\setcounter{tocdepth}{3}}')
        emit('List of bugs and workarounds',para('No open RTL defects are known at revision 2.2. Limitations that software and follow-up projects have to work around:')+T(['Limitation','Workaround'],CPU_LIMITS if cpu else PIC_LIMITS,[.5,.5]),level='section')
        if cpu:take('Shared Verilog definitions','Shared Verilog definitions',parents=(('section','Annex'),),
                    lead='These macros are defined once in rv32i_defines.vh and used by several modules. They are listed so that an encoding named in a port table can be resolved without opening the source.')
    else:
        take('Verification objective and evidence','Overview',parents=(('section','Verification methodology'),),
             lead='A run either passes or fails; this section states what that verdict covers. The first table gives the acceptance conditions applied to every test and the limits of what simulation shows; the second gives the runs behind the results quoted in this document.')
        emit('Implementation strategy',para('Directed tests exercise individual features and simultaneous events; program and reference tests check end-to-end results. Protocol checks observe accepted transfers; state checks sample after nonblocking updates.')+para(('Seeded random programs and the official riscv-tests extend the directed set.' if cpu else 'Seeded random traffic and formal proofs extend the directed set.')+' Every bench also runs under Verilator with the assertions bound.'))
        emit('Verification plans',para('The plan in section 4.1 follows the supplied template: ID, title, description, status and test/checker, one row per test.'))
        emit('Reference model',para('isa_reference.py encodes and interprets RV32I in Python, independently of the RTL and the assembler. For each program it writes the image, the expected PC, destination and value of every completed instruction, and the final data memory. The official riscv-tests are an external reference; each test reports its result through tohost.' if cpu else 'pic_reference.py computes the winner and pending mask of 275 static cases from the priority rule. pic_model.py is a cycle model of the controller, written from this specification; it replays the inputs recorded by pic_tb_random and must reproduce outputs and state on every cycle. pic_formal.sv states invariants that SymbiYosys proves for every input sequence.'))
        take('Verification environment','Overview',parents=(('section','Verification environment'),))
        take('Stimulus timing and asynchronous reset','Control and drivers',
             lead='Stimulus is driven one nanosecond after the sampling edge, so that a test never races the design it is checking. The table gives the timing rule for each driven event and the reason for it; the waveform shows the reset case, the one event placed off the clock grid.')
        take('Assertions, monitors and bind','Monitors and checkers',
             lead='Checking is split between bus protocol and functional result, so that a failure points at one of the two.')
        take('Environment setup and named scripts','Simulation environment setup',
             lead='The environment is a fixed folder layout plus a small number of named scripts. The tables give that layout, the exact command for each step in the order it is run, and the tools each step needs.')
        pages.pop('Directed scenarios and expected results')
        cases=api['CPU_TESTS' if cpu else 'PIC_TESTS']
        titles=['CPU integration','ISA reference','ALU','Predictor / RAS','Exceptions / traps','CSR access','Counters','Two harts','Asynchronous reset','Official ISA tests'] if cpu else ['Feature sequences','Priority reference','Simultaneous events','Asynchronous reset','Read-only registers','Status transitions','CPU integration','SoC integration','Random traffic','Formal proofs']
        emit('Verification plan',para('PASS indicates the recorded regression completed with its expected results and zero checker errors. Each row identifies the test that exercises the listed behavior.')+T(['ID','Title','Description','Status','Test / checker'],[(row[0],title,row[2],'PASS',row[1]) for title,row in zip(titles,cases)],[.08,.16,.37,.10,.29]),parents=(('section','Annex'),))
        take('Scenarios requiring cycle-level attention','Critical sequences')
        take('External AXI reference and comparison boundary','External AXI reference',
             lead='The AXI4-Lite front-end is compared against a published implementation to check the interpretation of the protocol. The first table states what was compared and on what evidence; the second names every difference found and what it means.')
    assert not pages, ('Unplaced sections',doc.filename,list(pages))
    return result
