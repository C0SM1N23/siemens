"""Build the table-led CPU/PIC design and verification specifications."""
from pathlib import Path
import re

D=Path(__file__).resolve().parents[1]
RTL=D.parent/'hdl'
def esc(s):
    return ''.join({'_':r'\_', '&':r'\&', '%':r'\%', '#':r'\#', '$':r'\$', '{':r'\{','}':r'\}','~':r'\textasciitilde{}','^':r'\textasciicircum{}','\\':r'\textbackslash{}'}.get(c,c) for c in str(s))
def tt(s):return r'\texttt{'+esc(s)+'}'
def table(head,rows,widths=None,small=True):
    n=len(head)
    widths=widths or [1/n]*n
    # Column dimensions include all inter-column padding.
    col='@{}'+''.join(r'L{'+f'{w:.4f}'+r'\dimexpr\linewidth-'+str(12*(n-1))+r'pt\relax}' for w in widths)+'@{}'
    hdr=' & '.join(r'\textbf{'+esc(x)+'}' for x in head)+r' \\ \midrule'+'\n'
    result=(r'{\small' if small else '{')+'\n'+r'\begin{longtable}{'+col+'}\n'+r'\toprule'+'\n'+hdr+r'\endfirsthead'+'\n'+r'\toprule'+'\n'+hdr+r'\endhead'+'\n'
    # The last row may not end a page, so the bottom rule never stands alone under a repeated head.
    for i,row in enumerate(rows):result+=' & '.join(str(x) for x in row)+(r' \\*' if i==len(rows)-1 else r' \\ \addlinespace[3pt]')+'\n'
    return result+r'\bottomrule\end{longtable}}'+'\n'
def T(head,rows,widths=None):return table(head,[[esc(x) for x in r] for r in rows],widths)
def P(text):return r'\noindent '+esc(text)+r'\par\medskip'+'\n'
def sub(title,body):return r'\subsubsection{'+esc(title)+'}'+'\n'+body
def fig(name,caption,height=None):
    from spec_content import FIGURE_TEXT
    opt=r'width=\linewidth' if height is None else r'width=\linewidth,height='+height+r',keepaspectratio'
    explanation=FIGURE_TEXT.get(name)
    if not explanation:raise ValueError('Missing figure explanation: '+name)
    return '\n'+r'\noindent '+esc(explanation)+r'\par'+'\n'+r'\begin{figure}[H]\centering\includegraphics['+opt+']{'+name+r'.pdf}\caption{'+esc(caption)+r'}\end{figure}'+'\n'
def wave(slug,caption):return fig('waves/'+slug,caption)
class Doc:
    def __init__(self,title,subject,filename,kind):
        self.filename=filename
        self.pages=[]
        self.s=[r'\documentclass[11pt]{article}',r'\newcommand{\doctitle}{'+esc(title)+'}',r'\newcommand{\docsubject}{'+esc(subject)+'}',r'\newcommand{\docrev}{2.2}',r'\newcommand{\docdate}{23 September 2026}',r'\input{preamble_spec}',r'\begin{document}',r'\begin{titlepage}\vspace*{24mm}',r'{\Huge\bfseries\color{accent}'+esc(title)+r'\par}\vspace{12mm}',r'{\Large '+esc(subject)+r'\par}\vfill',r'\identblock{'+kind+r'}\end{titlepage}',r'\tableofcontents']
    def page(self,title,content,level='section'):
        self.pages.append((title,content,False))
    def wide_page(self,title,content):
        self.pages.append((title,content,True))
    def save(self):
        from spec_content import render_document
        self.s.extend(render_document(self,globals()))
        # Keep the document name intact on the title page; no split words.
        self.s=[re.sub(r'\{\\Huge\\bfseries\\color\{accent\}([^—]+) — ([^\\]+)\\par\}',r'{\\Huge\\bfseries\\color{accent}\1\\par}\\vspace{4mm}{\\LARGE \2\\par}',x) for x in self.s]
        (D/self.filename).write_text('\n'.join(self.s+[r'\end{document}'])+'\n',encoding='utf-8')

CPU_REQ=[
('Pipeline','Three stages: fetch; decode + execute; writeback.','S1 / S2 / S3; S2 waits for the complete data transaction.'),
('ISA','RV32I integer instructions; no multiply/divide.','RV32I, machine-mode CSRs, traps, MRET and WFI.'),
('Prediction','One direction bit per branch; structure to be defined.','Tagged direct-mapped BTB/BHT; 128 entries by default; optional return stack.'),
('Memory','Independent AXI4-Lite instruction/data masters.','Read-only instruction port; read/write data port; 32-bit buses.'),
('Exceptions','Define causes, entry, return and flush precedence.','Precise instruction-boundary traps; faulting instruction does not commit.'),
('Register file','32 × 32 bits, two reads, one write; x0 = 0.','Combinational reads; S3 write; all GPRs reset to zero.'),
('Reset / target','Active-low asynchronous reset; behavioural RTL simulation.','posedge clk_i; asynchronous assertion of rst_n_i; no synthesis result claimed.'),
('IRQ integration','CPU brief: 8 requests, 3-bit ID, 8-bit acknowledgement.','Implemented PIC contract: 16 sources, scalar request/claim, 4-bit ID and EOI.')]
PIC_REQ=[
('Sources','16 hardware lines and 16 software-trigger channels.','HW/SW merge into 16 source slots; one vector per slot.'),
('Priority grouping','Define bands and inter-/intra-band arbitration.','Four bands; programmable 2-bit urgency; 4-bit intra-band priority; lowest ID breaks ties.'),
('Preemption','Preserve and restore active contexts.','16-entry stack; configured limit 1–16, reset 8; explicit EOI pops one level.'),
('Spurious requests','Detect a source withdrawn before acknowledgement.','Claim-time detection; source and global sticky logs.'),
('Deadlines','Per-source service deadline and automatic escalation.','16-bit cycle count; jump or next-more-urgent-band policy; optional repeated escalation.'),
('Software trigger','Protect injection; define clear and HW/SW collision.','0xA5A5 key; key byte strobes required; zero or claim clears request.'),
('Register port','AXI4-Lite slave; documented register map.','32-bit data/address; 256-byte window; independent AW/W collection.'),
('Reset / target','Active-low asynchronous reset; behavioural RTL simulation.','posedge clk_i; reset disables all sources; no synthesis result claimed.')]

CPU_PARAM=[('RESET_PC',"32'h0000_0000",'Word-aligned first fetch address.'),('HART_ID',"32'd0",'Value returned by mhartid.'),('BP_ENTRIES','128','BTB/BHT entries; power of two, at least 2.'),('RAS_DEPTH','8','Return-address stack entries; zero disables it.')]
PARAMS={'rv32i_cpu_top':CPU_PARAM,'rv32i_fetch_unit':[CPU_PARAM[0]],'rv32i_branch_predictor':[('ENTRIES','128','Power-of-two BTB/BHT entries; at least 2.'),CPU_PARAM[3]],'rv32i_csr_file':[CPU_PARAM[1]]}
FUNCTIONS={
'rv32i_cpu_top':'Connects the three pipeline stages, memory masters and interrupt interface.',
'rv32i_fetch_unit':'Fetches instructions; retains outstanding AXI requests across redirect and discards wrong-path responses.',
'rv32i_branch_predictor':'Predicts direction and target; learns completed control transfers; handles call/return hints.',
'rv32i_decode':'Extracts register indices, opcode, function fields and CSR address from the instruction.',
'rv32i_control':'Decodes instruction controls and rejects unsupported encodings.',
'rv32i_imm_gen':'Forms and sign-extends I/S/B/U/J immediates.',
'rv32i_regfile':'Stores 32 general-purpose registers; ignores x0 writes; reads x0 as zero.',
'rv32i_alu_top':'Selects operands and decodes the concrete ALU operation.',
'rv32i_alu':'Computes 32-bit arithmetic, logic, shifts and signed/unsigned comparisons.',
'rv32i_branch_unit':'Resolves branch/jump direction and target; clears JALR target bit 0.',
'rv32i_lsu':'Performs byte/halfword/word accesses, byte strobes, read extraction and error reporting.',
'rv32i_exception_unit':'Selects the synchronous trap cause and associated value.',
'rv32i_csr_file':'Implements machine-mode control, status and performance counters.',
'rv32i_hazard_unit':'Controls advance/flush and detects S3-to-S2 forwarding; an active LSU keeps S2 stalled.',
'rv32i_writeback_mux':'Selects ALU/CSR result, loaded data or PC+4 for register writeback.',
'pic':'Prioritizes source requests, manages nested service and exposes configuration/status registers.',
'axi_lite_slave':'Collects independent AW/W channels and maps register-access acceptance to AXI response codes.'}

DESCS={
'clk_i':'Rising-edge clock input.','rst_n_i':'Asynchronous reset, active low.',
'cpu_irq_i':'Prioritized interrupt request from PIC.','cpu_irq_o':'Registered interrupt offer; vector is valid while high.',
'cpu_irq_vec_i':'Source ID associated with cpu_irq_i.','cpu_irq_vec_o':'Registered offered source ID; meaningful while cpu_irq_o is high.',
'cpu_irq_ack_i':'One-cycle claim of the previously sampled offer.','cpu_irq_ack_o':'Registered one-cycle claim to PIC.',
'cpu_irq_eoi_i':'One-cycle end of interrupt; pop one active level.','cpu_irq_eoi_o':'One-cycle EOI on return from an interrupt.',
'cpu_in_trap_o':'CPU has an active trap context.','irq_pending_i':'Enabled pending sources from PIC; exposed in mip[31:16].',
'irq_mask_o':'mie[31:16], sent to the PIC resolver.','cpu_mask_i':'CPU acceptance mask, applied before priority selection.',
'irq_src_i':'16 synchronous hardware interrupt source lines.','pending_o':'Enabled pending sources excluding active sources; independent of CPU mask.',
'wr_en_o':'Register write pulse after both AW and W have been collected.',
'wr_addr_o':'Register word offset: captured AWADDR[7:2].','wr_data_o':'Captured write data.','wr_strb_o':'Captured byte-lane enables.',
'wr_ok_i':'Offset is writable; low selects SLVERR. Peripheral must qualify state updates.',
'rd_addr_o':'Register word offset ARADDR[7:2].','rd_data_i':'Peripheral read-mux data, sampled on AR handshake.',
'rd_ok_i':'Offset is readable; low selects SLVERR.',
'lookup_pc_i':'PC looked up in the predictor.','pred_taken_o':'Tagged predictor hit with taken direction.',
'pred_target_o':'Predicted target address; used only when pred_taken_o is high.',
'update_en_i':'Enable one predictor update at the rising edge.','update_pc_i':'Resolved control-transfer PC.',
'update_taken_i':'Resolved direction bit.','update_target_i':'Resolved target address.',
'update_call_i':'Push return address.','update_ret_i':'Pop return address.','update_is_ret_i':'Mark entry as a return.',
'update_link_i':'Return address PC+4.',
'csr_addr_i':'12-bit CSR address.','csr_op_i':'CSR operation: RW=01, RS=10, RC=11.',
'csr_ren_i':'CSR read enable.','csr_wen_i':'CSR write enable.','csr_illegal_o':'Unimplemented address or disallowed write.',
'csr_rdata_o':'CSR read value before write.','csr_wdata_i':'CSR write operand.',
'trap_set_i':'Commit a trap entry.','trap_is_irq_i':'Trap is an interrupt.','trap_code_i':'Trap cause code.',
'trap_pc_i':'PC to save in mepc.','trap_val_i':'Value to save in mtval.','mret_i':'Commit trap return.',
'irq_lines_i':'Pending interrupt sources.','irq_enable_o':'Enabled interrupt sources.',
'mie_global_o':'Current value of mstatus.MIE.','trap_vector_o':'Direct or vectored trap address.','mepc_out_o':'Saved aligned return PC.',
'retire_i':'One non-trapping instruction completes S2.',
'ev_mispredict_i':'Branch misprediction event.','ev_ibus_wait_i':'S2 lacks a valid instruction.',
'ev_dbus_stall_i':'Data transaction active.','ev_wfi_sleep_i':'WFI sleep cycle.',
'RegWrite_i':'Write-enable for nonzero destination register.',
'rs1_addr_i':'First register index.','rs2_addr_i':'Second register index.','rd_addr_i':'Destination register index.',
'rs1_data_o':'First register operand.','rs2_data_o':'Second register operand.','rd_data_i':'Register write data.'}
DESCS.update({
    'bp_lookup_pc_o':'Fetch PC presented to the branch predictor.',
    'bp_pred_taken_i':'Predicted taken control transfer at the lookup PC.',
    'bp_pred_target_i':'Predicted next PC when the taken prediction is valid.',
    'redirect_i':'Discard younger fetch work and select redirect_pc_i.',
    'redirect_pc_i':'New fetch PC selected by trap, return or branch correction.',
    'instr_valid_o':'Fetched instruction and metadata can be accepted by S2.',
    'instr_o':'Fetched 32-bit instruction word.',
    'instr_pc_o':'Byte address of the fetched instruction.',
    'fetch_fault_o':'Instruction response reported an AXI error.',
    'instr_i':'32-bit instruction word to decode or check.',
    'opcode_o':'Instruction opcode, bits [6:0].',
    'opcode_i':'Instruction opcode, bits [6:0].',
    'funct3_o':'Instruction function field, bits [14:12].',
    'funct3_i':'Instruction function field; selects operation or memory size/sign.',
    'funct7_o':'Instruction function field, bits [31:25].',
    'funct7_i':'Instruction function field; distinguishes arithmetic and shift variants.',
    'rd_o':'Destination GPR index from instruction bits [11:7].',
    'rd_i':'Destination GPR index; zero can suppress a CSR read.',
    'rs1_o':'First source GPR index from instruction bits [19:15].',
    'rs2_o':'Second source GPR index from instruction bits [24:20].',
    'rs1_i':'First source GPR index (or immediate CSR operand).',
    'rs2_i':'Second source GPR index.',
    'ALUOp_o':'Decoded ALU operation class; encodings are in rv32i_defines.vh.',
    'MemRead_o':'Decoded instruction performs a load.',
    'MemWrite_o':'Decoded instruction performs a store.',
    'Branch_o':'Decoded instruction is a conditional branch.',
    'mret_o':'Decoded instruction returns from a machine-mode trap.',
    'ecall_o':'Decoded ECALL requests an environment-call exception.',
    'ebreak_o':'Decoded EBREAK requests a breakpoint exception.',
    'illegal_o':'Encoding is not supported by the implemented instruction set.',
    'imm_out_o':'Immediate expanded to 32 bits for the decoded instruction format.',
    'operand_a_i':'First 32-bit ALU operand.',
    'operand_b_i':'Second 32-bit ALU operand.',
    'alu_ctrl_i':'Concrete ALU function; encodings are listed in the shared defines.',
    'result_o':'32-bit ALU result for the selected operation.',
    'pc_in_i':'PC of the control-transfer instruction in S2.',
    'imm_out_i':'Decoded sign-extended branch/jump displacement.',
    'rs1_data_i':'First forwarded register operand; JALR base or comparison value.',
    'rs2_data_i':'Second forwarded register operand for branch comparison.',
    'Branch_i':'Enable conditional-branch evaluation.',
    'Jump_i':'Enable unconditional JAL/JALR evaluation.',
    'branch_target_o':'Resolved branch/jump target; JALR bit 0 is cleared.',
    'ecall_i':'Current instruction is an ECALL.',
    'ebreak_i':'Current instruction is an EBREAK.',
    'MemRead_i':'Current operation is a load.',
    'MemWrite_i':'Current operation is a store.',
    'exception_o':'A synchronous exception is selected for the current instruction.',
    'cause_o':'Selected synchronous exception code from the cause table.',
    'mret_exec_i':'A valid MRET instruction is executing.',
    'mispredict_i':'Resolved direction or target differs from the prediction.',
    'wb_valid_i':'S3 contains a valid instruction.',
    'wb_reg_write_i':'S3 instruction enables a GPR write.',
    'wb_rd_i':'S3 destination GPR index.',
    'fwd_rs1_o':'Use S3 writeback data as the first S2 register operand.',
    'fwd_rs2_o':'Use S3 writeback data as the second S2 register operand.',
    'mem_data_i':'Completed load value after size/sign extraction.',
    'pc_plus4_i':'Sequential next PC, used as the JAL/JALR link value.',
    'MemtoReg_i':'Writeback source: 00 ALU/CSR; 01 load; 10 PC+4.',
    'wb_data_o':'Selected 32-bit value to write to the destination GPR.'
})
# Written descriptions for the remaining ports, so no table cell reproduces an RTL comment.
DESCS.update({
    's2_ready_i':'S2 can accept a new instruction into IF/DX this cycle.',
    'imm12_i':'Instruction bits [31:20]; distinguishes ECALL, EBREAK, MRET and WFI.',
    'RegWrite_o':'Decoded instruction writes its destination register.',
    'ALUSrc_o':'Second ALU operand select: 0 register rs2, 1 immediate.',
    'MemtoReg_o':'Writeback source select; a CSR read uses the ALU slot.',
    'Jump_o':'Decoded instruction is JAL or JALR.',
    'csr_instr_o':'Decoded instruction is a Zicsr CSR access.',
    'csr_op_o':'CSR operation: RW=01, RS=10, RC=11.',
    'csr_imm_o':'Immediate CSR form; the operand is the five-bit field in the rs1 position.',
    'wfi_o':'Decoded WFI; S2 waits for an enabled interrupt offer.',
    'operand_b_reg_i':'Second register operand, taken from rs2.',
    'operand_b_imm_i':'Decoded immediate operand.',
    'ALUSrc_i':'Second operand select: 0 register, 1 immediate.',
    'ALUOp_i':'Generic operation class from rv32i_control; encodings are in rv32i_defines.vh.',
    'pc_src_o':'Next PC takes branch_target_o instead of the sequential address.',
    'req_i':'A valid memory operation is presented this cycle.',
    'we_i':'Access direction: 1 store, 0 load.',
    'addr_i':'Byte address of the access, taken from the ALU result.',
    'st_data_i':'Store data from rs2, after forwarding.',
    'busy_o':'Transaction is not finished; S2 must stall.',
    'done_o':'Response accepted this cycle.',
    'err_o':'Response carried SLVERR or DECERR.',
    'active_o':'Transaction has been issued; an interrupt cannot be accepted mid-access.',
    'ld_data_o':'Load data after size and sign extension; valid on done_o for a read.',
    'valid_i':'S2 holds a real, non-preempted instruction.',
    'fetch_fault_i':'The fetch of this instruction reported an AXI error.',
    'illegal_i':'Decoder or CSR access reported an illegal operation.',
    'pc_i':'Address of the instruction in S2.',
    'ctl_taken_i':'Resolved control-transfer direction is taken.',
    'ctl_target_i':'Resolved control-transfer target address.',
    'mem_addr_i':'ALU result; meaningful only before the access is issued.',
    'mem_active_i':'Data transaction has already been issued.',
    'mem_done_i':'Data response landed this cycle.',
    'mem_err_i':'Data response was SLVERR or DECERR.',
    'tval_o':'mtval payload for the selected cause.',
    'mem_misaligned_o':'Address is not naturally aligned; the AXI issue is blocked.',
    'fetch_valid_i':'S1 offers an instruction this cycle.',
    'lsu_busy_i':'A data transaction is still in flight in S2.',
    'wfi_wait_i':'WFI is in S2 and no wake condition exists yet.',
    'trap_take_i':'A synchronous exception or an accepted interrupt commits this cycle.',
    's2_advance_o':'S2 finishes its instruction this cycle.',
    'redirect_o':'Fetch changes path; held S1 content is dropped.',
    'if_dx_we_o':'IF/DX loads a new instruction or a bubble.',
    'if_dx_bubble_o':'The value loaded into IF/DX is a bubble.',
    'dx_squash_o':'The S2 instruction must not commit to S3.',
    'alu_result_i':'ALU result, or the CSR read value muxed in S2.'
})

def meaning(name):
    if name in DESCS:return DESCS[name]
    for key,desc in [('awaddr','Write byte address.'),('araddr','Read byte address.'),('awprot','Write protection attributes.'),('arprot','Read protection attributes.'),('wstrb','One enable bit per write byte.'),('wdata','Write payload.'),('rdata','Read payload.'),('bresp','Write response: OKAY=00, SLVERR=10, DECERR=11.'),('rresp','Read response: OKAY=00, SLVERR=10, DECERR=11.')]:
        if key in name:return desc
    for ch in ['aw','ar','w','r','b']:
        if ch+'valid' in name:return {'aw':'Write address','ar':'Read address','w':'Write data','r':'Read response','b':'Write response'}[ch]+' is valid; hold until handshake.'
        if ch+'ready' in name:return 'Receiver can accept the '+{'aw':'write address','ar':'read address','w':'write data','r':'read response','b':'write response'}[ch]+'.'
    # Port meanings are written for the specification; an RTL comment is not a table cell.
    raise ValueError('Missing port description: '+name)
def ports(mod):
    src=(RTL/(mod+'.v')).read_text()
    header=src[:src.index(');')]
    result=[]
    for line in header.splitlines():
        m=re.match(r'\s*(input|output|inout)\s+(?:(?:reg|wire|logic)\s+)?(?:\[([^\]]+)\]\s*)?(\w+)',line)
        if not m:continue
        direction,rng,name=m.groups();width='1'
        if rng:
            a,b=[x.strip() for x in rng.split(':')]
            width=str(int(a)-int(b)+1) if a.isdigit() and b.isdigit() else a.removesuffix('-1') if b=='0' else '('+a+') - ('+b+') + 1'
        desc='Register read value for rd_addr_o.' if mod=='axi_lite_slave' and name=='rd_data_i' else meaning(name)
        result.append([tt(name),direction,width,esc(desc)])
    return result
def modulebody(mod):
    # Template 6.x: the purpose leads, then 6.x.1 the interface, then 6.x.2 the function.
    params=paramtable(mod) if mod in PARAMS else P('No parameters.')
    return (esc(FUNCTIONS[mod])+'\n'+r'\subsubsection{Interface description}'+'\n'
            +params+porttable(mod)+r'\subsubsection{Functional description}'+'\n')
def paramtable(mod):
    return T(['Parameter','Default','Meaning / valid setting'],PARAMS.get(mod,[('None','—','All port widths are fixed in this module.')]),[.25,.23,.52])
def porttable(mod):return table(['Signal','Dir.','Width (bits)','Meaning'],ports(mod),[.34,.10,.10,.46])
def fields(name,offset,rows):
    return r'\subsection*{'+esc(name)+' — '+esc(offset)+'}\n'+T(['Bits','Field','Access type','Reset','Description'],rows,[.12,.18,.12,.12,.46])

PIC_FIELDS={
'SRCx_CONFIG':('0x00 + 4x',[
('[31:16]','DEADLINE','RW','0','Pending cycles to escalation; zero disables the timer.'),('[15:8]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[7:4]','INTRA','RW','0','Higher value means higher priority within equal band urgency.'),('[3]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[2:1]','BAND','RW','0','Band index 0–3; urgency comes from BAND_CONFIG.'),('[0]','TRIG','RW','0','0: level. 1: latch rising edges until claim.')]),
'SRCx_SW_TRIG':('0x40 + 4x',[
('[31:16]','KEY','WO / RAZ','0','0xA5A5 plus WSTRB[3:2]=11 is required to set SWREQ.'),('[15:1]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[0]','SWREQ','RW + HW clear','0','Set with key; zero clears without key. WSTRB[0] required. Claim clears; a simultaneous new set is retained.')]),
'SRCx_STATUS':('0x80 + 4x',[
('[31:16]','DDL_TIMER','RO','0','Elapsed enabled-pending cycles. Clears when idle or escalating; otherwise saturates at DEADLINE-1.'),('[15:6]','Reserved','RO','0','Reads zero.'),('[5:4]','EFF_BAND','RO','0','Configured band, or temporary escalated band.'),('[3]','SPUR','RO','0','This active service level was claimed after its source disappeared.'),('[2]','ESC','RO','0','Escalated during the present wait; clears when claimed / no longer pending.'),('[1]','ACTIVE','RO','0','Source occupies a nesting level.'),('[0]','PEND','RO','0','Enabled HW/SW request, including a held level during its handler.')]),
'BAND_CONFIG':('0xC0',[
('[31:8]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[7:6]','BAND3_URG','RW','0','Urgency of band 3.'),('[5:4]','BAND2_URG','RW','1','Urgency of band 2.'),('[3:2]','BAND1_URG','RW','2','Urgency of band 1.'),('[1:0]','BAND0_URG','RW','3','Urgency of band 0. Higher urgency wins.')]),
'NEST_STATUS':('0xC4',[
('[31:17]','Reserved','RO','0','Reads zero.'),('[16]','OVF','RO','0','Alias of INT_STATUS.OVF; clear at 0xDC.'),('[15:12]','Reserved','RO','0','Reads zero.'),('[11:8]','TOP_ID','RO','0','Top active source ID; zero when depth is zero.'),('[7:5]','Reserved','RO','0','Reads zero.'),('[4:0]','DEPTH','RO','0','Active nesting levels, 0–16.')]),
'NEST_MAX':('0xC8',[
('[31:5]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[4:0]','LIMIT','RW / WARL','8','Clamp 0 to 1 and values above 16 to 16. Requires WSTRB[0]. Lowering the limit does not unwind active handlers.')]),
'ACTIVE_VEC':('0xCC',[
('[31:9]','Reserved','RO','0','Reads zero.'),('[8]','VALID','RO','0','At least one source is in service.'),('[7:4]','Reserved','RO','0','Reads zero.'),('[3:0]','ID','RO','0','Top active source; meaningful when VALID=1.')]),
'SPURIOUS_LOG':('0xD0',[
('[31:16]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[15:0]','FLAGS','RW1C','0','One sticky bit per spurious source. WSTRB[1:0] qualify clear. New hardware set wins over clear.')]),
'ESCALATION_CFG':('0xD4',[
('[31:9]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[8]','MULTI','RW','0','1: repeat each deadline. 0: one escalation per wait.'),('[7:5]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[4]','MODE','RW','0','0: jump to TARGET. 1: next strictly more urgent band.'),('[3:2]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[1:0]','TARGET','RW','0','Destination band for jump mode.')]),
'INT_ENABLE':('0xD8',[
('[31:16]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[15:0]','ENABLE','RW','0','One source enable per bit; byte strobes apply. CPU mask is a separate filter.')]),
'INT_STATUS':('0xDC',[
('[31:3]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[2]','OVF','RW1C','0','Eligible source blocked by depth limit.'),('[1]','ESC','RW1C','0','At least one deadline escalation occurred.'),('[0]','SPUR','RW1C','0','At least one spurious claim occurred. New hardware event wins over a same-cycle clear.')])}
PIC_MAP=[('0x00–0x3C','SRC0..15_CONFIG','RW','0x00000000','Trigger, band, priority, deadline.'),('0x40–0x7C','SRC0..15_SW_TRIG','RW','0x00000000','Keyed injection / clear.'),('0x80–0xBC','SRC0..15_STATUS','RO','0x00000000','Per-source state and timer.'),('0xC0','BAND_CONFIG','RW','0x0000001B','Four urgency values.'),('0xC4','NEST_STATUS','RO','0x00000000','Depth, top ID and overflow.'),('0xC8','NEST_MAX','RW / WARL','0x00000008','Allowed active depth.'),('0xCC','ACTIVE_VEC','RO','0x00000000','Active source and valid bit.'),('0xD0','SPURIOUS_LOG','RW1C','0x00000000','Per-source spurious flags.'),('0xD4','ESCALATION_CFG','RW','0x00000000','Escalation policy.'),('0xD8','INT_ENABLE','RW','0x00000000','Source enables.'),('0xDC','INT_STATUS','RW1C','0x00000000','Global event flags.')]

CSR_MAP=[('0x300','mstatus','RW / fixed','0x00001800','Global interrupt state.'),('0x301','misa','WARL / fixed','0x40000100','RV32I capability.'),('0x304','mie','RW','0','Interrupt enables [31:16].'),('0x305','mtvec','RW / WARL','0','Trap base and mode.'),('0x323–0x327','mhpmevent3..7','WARL / fixed','1..5','Fixed performance-event selectors.'),('0x328–0x33F','mhpmevent8..31','WARL / fixed','0','Unused event selectors.'),('0x340','mscratch','RW','0','Software scratch word.'),('0x341','mepc','RW / aligned','0','Trap return PC.'),('0x342','mcause','RW','0','Trap cause.'),('0x343','mtval','RW','0','Fault payload.'),('0x344','mip','RO','input-dependent','irq_pending_i in [31:16].'),('0xB00 / 0xB80','mcycle / mcycleh','RW','0','64-bit cycle count.'),('0xB02 / 0xB82','minstret / minstreth','RW','0','64-bit completed-instruction count.'),('0xB03–0xB07 / 0xB83–0xB87','mhpmcounter3..7 / high','RW','0','64-bit event counts.'),('0xB08–0xB1F / 0xB88–0xB9F','mhpmcounter8..31 / high','WARL / fixed','0','Unused counters; writes ignored.'),('0xF11–0xF13','mvendorid / marchid / mimpid','RO','0','Identification values.'),('0xF14','mhartid','RO','HART_ID','Instance identifier.')]

def cpu_design():
    d=Doc('RV32I CPU — Design Specification','Three-stage processor · RTL interface and programming contract','Design_Specification_RV32I_CPU.tex','Design specification')
    d.page('Scope and original requirements',T(['Topic','Initial requirement','Implemented contract'],CPU_REQ,[.14,.37,.49]))
    d.wide_page('Architecture',fig('figures/cpu_essential','Three stages with pipeline boundaries, data paths and essential control feedback; widths are in bits. PIC and memories are external.','132mm'))
    d.page('Pipeline and control contract',T(['Stage / control','Behaviour'],[('S1','One outstanding instruction read; predictor selects next PC; wrong-path responses are drained and discarded.'),('S2','Decode, execute and complete memory access. CSR side effects / instruction retirement occur at completion.'),('S3','Write result to the destination GPR. Forward this value to dependent S2 operands.'),('Redirect priority','Synchronous trap / accepted interrupt, then MRET, then branch correction; redirect requires S2 to advance.')],[.22,.78]))
    d.page('Module parameters',paramtable('rv32i_cpu_top')+P('Instructions, addresses and data are 32 bits and GPR indices 5 bits. The interrupt link has 16 mask and pending bits and a 4-bit source ID. BP_ENTRIES and RAS_DEPTH set internal capacity only; no port width depends on a parameter.'))
    d.page('Hardware interface',porttable('rv32i_cpu_top'))
    d.page('Reset contract',T(['Item','Required behaviour'],[('Clock','Sequential state updates on posedge clk_i.'),('Assertion','Asynchronous active-low rst_n_i; no clock edge required for assertion.'),('Outputs','AXI request VALID signals, IRQ claim/EOI and trap-active state are inactive.'),('Architectural state','GPRs=0; PC=RESET_PC; mstatus=0x1800; other stored CSRs/counters=0, except documented fixed values.'),('mip','Combinational pending input, not a reset storage element. Zero requires irq_pending_i=0.'),('Integration','Distribute reset to CPU and bus responders. Release it with the system reset controller; release between clock edges is also supported.')],[.25,.75])+wave('cpu_reset','Instruction request interrupted by asynchronous reset at 27 ns.'))
    d.page('Instruction AXI4-Lite interface',wave('cpu_fetch','Instruction fetch after rst_n release at 123 ns.')+T(['Property','Contract'],[('Channels','AR/R only; fixed 32-bit address and data.'),('Handshake','Transfer at posedge when VALID and READY are both high; retain VALID and payload while stalled.'),('Outstanding requests','At most one; issuing the next AR may overlap completion of the prior R.'),('Protection','ARPROT=111: instruction, non-secure, privileged.'),('Errors','SLVERR/DECERR become an instruction-access fault in S2. A wrong-path fault is discarded.'),('Redirect','An accepted request cannot be cancelled. Retain its route / drain the response before using the new path.')],[.25,.75]))
    d.page('Data AXI4-Lite interface',wave('cpu_load','Load: lsu_active holds S2 until the data response completes.')+wave('cpu_store','Store: address and write data are accepted independently; B completes the store.')+T(['Property','Contract'],[('Transactions','One load or store outstanding; byte, halfword and word accesses.'),('Byte lanes','WSTRB selects bytes; reads extract/sign-extend according to the instruction.'),('Misalignment','Detected before bus issue; misaligned accesses trap.'),('Errors','SLVERR/DECERR produce load/store access faults; destination is not committed.'),('Protection','AWPROT/ARPROT=011: data, non-secure, privileged.')],[.24,.76]))
    d.page('Interrupts and redirects',wave('cpu_irq','Interrupt claim: cpu_irq_ack_o is a full-cycle registered pulse.')+wave('cpu_redirect','Branch correction: redirect invalidates younger work.')+T(['Event','Contract'],[('Interrupt eligibility','mstatus.MIE and the enabled source must allow it; acceptance waits for an instruction boundary, including completion of an active LSU transfer.'),('Cause','External source n uses mcause=0x80000000 | (16+n).'),('Claim / EOI','Claim is sent after the offer is sampled. EOI is sent when returning from an interrupt; a synchronous exception return does not pop the PIC.'),('Nested software','Save mepc, mstatus and handler context before enabling nested interrupts; restore before MRET.')],[.24,.76]))
    d.page('CSR address map',T(['Address','Name','Access type','Reset','Description'],CSR_MAP,[.19,.23,.14,.15,.29])+T(['Access rule','Behaviour'],[('Unknown address / read-only write','Illegal-instruction exception; CSR addresses are not memory-mapped AXI addresses.'),('CSRRW / CSRRS / CSRRC','Replace / set / clear; immediate variants use zero-extended zimm. Zero-source CSRRS/CSRRC do not write.'),('Unimplemented inhibit','0x320 (mcountinhibit) is absent and traps.')],[.34,.66]))
    d.page('CSR fields: status and interrupt enables',fields('mstatus','0x300',[
        ('[31:13], [10:8], [6:4], [2:0]','Reserved','RAZ/WI','0','Reads zero; writes ignored.'),('[12:11]','MPP','fixed','3','Machine mode only.'),('[7]','MPIE','RW + HW','0','Saved MIE; MRET sets it to 1.'),('[3]','MIE','RW + HW','0','Global enable; trap clears it; MRET restores MPIE.')])+fields('mie','0x304',[
        ('[31:16]','ENABLE','RW','0','16 source-enable bits; exported as irq_mask_o.'),('[15:0]','Reserved','RAZ/WI','0','Reads zero; writes ignored.')])+fields('mip','0x344',[
        ('[31:16]','PENDING','RO','input','Reflects irq_pending_i; zero when the connected PIC is reset.'),('[15:0]','Reserved','RO','0','Reads zero.')]))
    d.page('CSR fields: trap vector and return',fields('mtvec','0x305',[
        ('[31:2]','BASE','RW','0','Word-aligned handler base.'),('[1:0]','MODE','RW / WARL','0','0 direct; 1 vectored. Values 2/3 read back as direct.')])+T(['Trap type','Entry address'],[('Synchronous exception','BASE in both modes.'),('External interrupt, direct','BASE.'),('External interrupt, vectored','BASE + 4 × (16 + source ID).')],[.44,.56])+fields('mepc','0x341',[
        ('[31:2]','RETURN_PC','RW + HW','0','Saved PC; software may update the return location.'),('[1:0]','Alignment','fixed','0','Reads zero; writes discarded.')])+fields('mscratch','0x340',[('[31:0]','VALUE','RW','0','Software-owned scratch word.')]))
    d.page('CSR fields: causes and fault payload',fields('mcause','0x342',[
        ('[31]','INTERRUPT','RW + HW','0','Trap entry sets 1 for interrupt, 0 for synchronous exception.'),('[30:5]','Software bits','RW','0','Hardware trap entry writes zero; software writes are retained by this RTL.'),('[4:0]','CODE','RW + HW','0','Hardware cause code; external source n is 16+n.')])+fields('mtval','0x343',[('[31:0]','VALUE','RW + HW','0','Faulting address or illegal instruction; zero where the cause supplies no payload.')])+T(['Code','Synchronous cause'],[('0','Instruction-address misalignment.'),('1','Instruction-access fault.'),('2','Illegal instruction / invalid CSR access.'),('3','EBREAK.'),('4 / 6','Load / store address misalignment.'),('5 / 7','Load / store access fault.'),('11','ECALL from machine mode.')],[.20,.80]))
    d.page('CSR fields: identity and capability',fields('misa','0x301',[
        ('[31:30]','MXL','fixed WARL','1','32-bit architecture; writes ignored.'),('[29:9], [7:0]','Other extensions','fixed WARL','0','Not advertised; writes ignored.'),('[8]','I','fixed WARL','1','RV32I base integer set.')])+fields('mvendorid / marchid / mimpid','0xF11 / 0xF12 / 0xF13',[('[31:0]','VALUE','RO','0','No implementation-specific identifier assigned.')])+fields('mhartid','0xF14',[('[31:0]','VALUE','RO','HART_ID','Instance parameter; use unique values for multiple harts.')]))
    d.page('CSR fields: counters and events',fields('mcycle / minstret / mhpmcounter3..7','low and high CSR addresses in map',[
        ('[31:0]','LOW / HIGH','RW','0','Each address accesses one half of a 64-bit counter. Explicit writes suppress that cycle’s event increment and preserve the other half.')])+fields('mhpmevent3..7','0x323–0x327',[('[31:0]','EVENT','fixed WARL','1..5','Fixed event IDs; writes accepted and ignored.')])+fields('Unused HPM counters / selectors','addresses in map',[('[31:0]','VALUE','fixed WARL','0','Reads zero; writes accepted and ignored.')])+T(['Counter','Event'],[('mcycle','Every cycle.'),('minstret','Non-trapping instruction completes S2.'),('mhpmcounter3','Mispredicted control transfer.'),('mhpmcounter4','S2 has no valid instruction.'),('mhpmcounter5','Data transaction active.'),('mhpmcounter6','Trap entry.'),('mhpmcounter7','WFI sleep cycle.')],[.30,.70])+P('A 64-bit counter is read high, low, high; the read is repeated when the two high values differ.'))
    d.page('Programming and integration',T(['Step','Action','Expected result'],[('1','Set RESET_PC and provide executable instruction memory.','First fetch is word aligned.'),('2','Initialize stack/context and program mtvec.','Trap entry reaches a valid handler.'),('3','Configure PIC source type, band and INT_ENABLE.','Sources can become pending.'),('4','Set mie[16+n], then mstatus.MIE.','CPU can accept source n at an instruction boundary.'),('5','Handler services and clears the peripheral; MRET returns.','CPU generates EOI for an interrupt return.'),('6','For nesting, save trap CSRs/context before re-enabling MIE.','Inner handler cannot overwrite the outer return state.')],[.08,.48,.44])+T(['Integration constraint','Consequence'],[('No M/A/C extensions, caches or MMU','Do not emit unsupported instructions; target machine-mode RV32I with the documented CSR extensions.'),('Protection constant','The core does not switch bus privilege/security attributes.'),('Reset and source synchrony','Clock/reset must reach the full transaction path; asynchronous external IRQ lines need synchronization outside this block.'),('Behavioural verification target','No area, frequency, power or physical timing result is specified.')],[.34,.66]))
    d.page('Reuse and integration by another developer',T(['Task','How to use this block'],[('Source list','Compile cpu/debug/sim/rtl.f from its simulation directory, or copy its RTL entries into the integrating project.'),('Instantiation','Instantiate rv32i_cpu_top and override RESET_PC, HART_ID, BP_ENTRIES or RAS_DEPTH as needed. No external signal width is parameterized.'),('Memory','Connect ibus to instruction memory and dbus to the memory/peripheral fabric. Honour all five data-port channels independently.'),('Interrupts','Connect the documented scalar request, 4-bit vector, masks, pending set and claim/EOI pair.'),('Tie-offs','Without interrupts: cpu_irq_i=0, cpu_irq_vec_i=0 and irq_pending_i=0.'),('Verification','Run regress.do and run_verilator.sh, then test the integration map and slave latency of the target system.')],[.23,.77]))
    for mod in FUNCTIONS:
        if not mod.startswith('rv32i_') or mod=='rv32i_cpu_top':continue
        d.page('Module contract: '+mod,modulebody(mod))
    const=[]
    for line in (RTL/'rv32i_defines.vh').read_text().splitlines():
        m=re.match(r'`define (\w+)\s+(\S+)',line)
        if m:
            name,value=m.groups();category='Instruction opcode' if name.startswith('OPC') else 'ALU decode' if name.startswith('ALUOP') else 'ALU operation' if name.startswith('ALU_') else 'Writeback source' if name.startswith('WB_') else 'CSR operation' if name.startswith('CSROP') else 'Trap cause'
            const.append((name,value,category))
    d.page('Shared Verilog definitions',T(['Definition','Value','Use'],const,[.42,.25,.33]))
    d.save()

def pic_design():
    d=Doc('PIC — Design Specification','Programmable interrupt controller · interface and register contract','Design_Specification_PIC.tex','Design specification')
    d.page('Scope and original requirements',T(['Topic','Initial requirement','Implemented contract'],PIC_REQ,[.15,.35,.50]))
    d.wide_page('Architecture',fig('figures/pic_essential','Architectural view: HW/SW requests share 16 source slots; the stack records active service contexts.','132mm'))
    d.page('Arbitration and service contract',T(['Decision','Contract'],[('Priority key','Band urgency first, then higher intra-band priority, then lower source ID.'),('Preemption','A candidate must be enabled, CPU-unmasked, inactive and strictly more urgent than the active top context.'),('Recorded context','Claim snapshots the selected source ID and priority. Reconfiguring an active source does not change that saved threshold.'),('Offer','cpu_irq_o and cpu_irq_vec_o are registered together; pending_o is a separate combinational mask.')],[.24,.76]))
    d.page('Module configuration and integration constraints',T(['Fixed quantity','Value'],[('Source slots','16; each merges a hardware line and software request.'),('Priority bands','4; configurable urgency, not additional modules.'),('Physical nesting depth','16; run-time NEST_MAX defaults to 8.'),('AXI width','32-bit address/data; four strobes; three protection bits; two response bits.')],[.35,.65])+T(['Constraint','Required integration behaviour'],[('Address window','Decode exactly a 256-byte window. Only address bits [7:2] are used; upper bits alias and low bits select the containing word.'),('IRQ input synchrony','irq_src_i must be synchronous to clk_i; synchronize asynchronous peripheral sources outside the PIC.'),('CPU handshake','Claim refers to the offer sampled one cycle earlier. Never assert claim and EOI together.'),('One CPU','One offer / mask / claim / EOI interface per PIC instance.'),('Protection','AWPROT/ARPROT accepted and ignored; no access-control mechanism in this block.'),('Implementation target','Behavioural RTL simulation. No synthesis / frequency claim.')],[.26,.74]))
    d.page('Hardware interface',porttable('pic'))
    d.page('Reset and register-access contract',wave('pic_reset','Reset from a configured state: rst_n asserts at posedge +2 ns; depth and enables clear before the next edge.')+T(['Item','Behaviour'],[('Reset','Asynchronous active-low rst_n_i; sequential state updates on posedge clk_i.'),('Reset state','INT_ENABLE=0, depth=0, all source requests inactive; BAND_CONFIG=0x1B, NEST_MAX=8; other readable state zero.'),('Transactions','One outstanding read and one outstanding write. AW and W may arrive independently, in either order.'),('Read / write response','OKAY for a mapped permitted access. SLVERR for unmapped read/write or a write to RO. Rejected read data is zero.'),('Writes','WSTRB applies per byte as described in each field. No strobe does not authorize an otherwise forbidden write.'),('Reset during transfer','Captured AW/W and pending B/R responses are cleared; no pre-reset response is replayed afterwards.')],[.26,.74]))
    d.page('Register address map',T(['Byte offset','Name','Access type','Reset','Description'],PIC_MAP,[.17,.24,.13,.17,.29])+T(['Rule','Meaning'],[('Per-source offsets','x ranges from 0 to 15. Configuration=4x; software trigger=0x40+4x; status=0x80+4x.'),('Reserved addresses','0xE0–0xFC return SLVERR.'),('Access classes','RW: read/write; RO: read-only; RW1C: write-one-to-clear; WARL: value coerced to a legal setting; RAZ/WI: read zero / write ignored.')],[.26,.74]))
    for name,(offset,rows) in PIC_FIELDS.items():
        d.page('Register fields: '+name+' — '+offset,T(['Bits','Field','Access type','Reset','Description'],rows,[.12,.18,.12,.12,.46]))
    d.page('Level request, claim and EOI',wave('pic_claim','Source 3 service: the request is claimed once; EOI returns nesting depth to zero.')+T(['Condition','Observable behaviour'],[('Enabled level high','Source becomes pending. cpu_irq_o is registered on the next resolution.'),('Claim','Push the previously offered source; mark it active; active sources are excluded from offers.'),('Source clears','The handler removes the peripheral cause before return.'),('EOI','Pop exactly one level. EOI on an empty stack is ignored.'),('Source remains high after EOI','It can become eligible again; PIC does not clear the external peripheral.')],[.28,.72]))
    d.page('Preemption and nesting',wave('pic_nesting','Source 8 enters service, source 9 preempts, and two EOIs restore then remove the outer context.')+T(['Condition','Result'],[('Higher priority arrives','It may be offered while the current source is active.'),('Second claim','Depth increases from 1 to 2; outer source remains active.'),('Inner EOI','Depth returns to 1; outer priority threshold is restored.'),('At NEST_MAX','No new offer; an eligible blocked source sets OVF.'),('Reband active source','Saved priority threshold is unchanged until that context is popped.')],[.28,.72]))
    d.page('Edge capture and spurious claims',wave('pic_edge_claim','Simultaneous claim and a new source edge: the new edge remains latched for service after EOI.')+wave('pic_spurious','Source withdrawal before claim: the active context is marked spurious and the event is logged.')+T(['Event','Contract'],[('Disabled edge source','A rising edge remains latched; enabling later exposes it. Level-mode reset slots capture no edges.'),('Claim with a new edge','New edge takes precedence over consuming the previous pending edge.'),('Spurious claim','The previously offered source is no longer pending when claimed; log globally and per source; unwind with normal EOI.')],[.27,.73]))
    d.page('Deadline escalation',wave('pic_escalation','Reordered bands, source 2 deadline = 10 cycles: escalation precedes the registered offer changing from source 1 to 2.')+T(['Setting / event','Behaviour'],[('DEADLINE=0','Timer disabled and held at zero.'),('Nonzero deadline','Count while enabled pending and not active. CPU masking does not stop the pending timer.'),('MODE=0','Jump to TARGET when deadline expires.'),('MODE=1','Move to the next strictly greater urgency in BAND_CONFIG, which need not be the next lower band number.'),('MULTI=1','Repeat at each deadline. In bump mode, the effective band stays unchanged if no higher urgency exists.'),('Claim / no longer pending','Clear elapsed wait and escalation state; configured priority applies again.'),('Status','SRCx_STATUS.ESC is wait-local; INT_STATUS.ESC is sticky until RW1C.')],[.29,.71]))
    d.page('Programming sequences',T(['Step','Register / signal','Action'],[('1','INT_ENABLE (0xD8)','Disable target source while configuring its trigger, band, intra priority and deadline.'),('2','SRCx_CONFIG (4x)','Write desired fields; set reserved bits to zero.'),('3','BAND_CONFIG / ESCALATION_CFG / NEST_MAX','Program shared policy as needed.'),('4','INT_ENABLE and cpu_mask_i','Enable source in PIC and permit it at CPU.'),('5','SRCx_SW_TRIG (0x40+4x)','Set: WDATA=0xA5A50001 with WSTRB=0xD or 0xF. Clear: bit 0=0 with WSTRB[0]=1.'),('6','cpu_irq_ack_i','Claim one cycle after observing the offered request/vector.'),('7','Peripheral / cpu_irq_eoi_i','Clear the cause, then issue one EOI when the handler returns.'),('8','INT_STATUS / SPURIOUS_LOG','Read events and write ones to the flags that should be cleared.')],[.08,.34,.58])+T(['Useful observation','Read'],[('Pending / active / elapsed','SRCx_STATUS.'),('Current handler','ACTIVE_VEC.VALID and ID.'),('Nested contexts','NEST_STATUS.DEPTH and TOP_ID; software cannot read the whole stack.')],[.38,.62]))
    d.page('Reuse and integration by another developer',T(['Task','How to use this block'],[('Compile','Include pic.v and axi_lite_slave.v.'),('Instantiate','pic has no Verilog module parameters; all configuration uses registers.'),('Connect','Map its 256-byte AXI window and connect 16 synchronous IRQ lines. Tie unused lines low.'),('CPU link','Connect request 1, vector 4, mask/pending 16 and claim/EOI 1 each. The original CPU brief differs; use the interface documented here.'),('Reset','Reset PIC, master and fabric together; keep a consistent reset domain for in-flight transactions.'),('Verify','Run the PIC benches in regress.do and the bound-assertion flow run_verilator.sh; check the final address map.')],[.25,.75]))
    d.page('Register-interface module: axi_lite_slave',modulebody('axi_lite_slave'))
    d.save()

CPU_TESTS=[
('CPU-01','rv32i_tb_cpu_axi','Arithmetic, logic, load/store, trap/IRQ/WFI programs; memory/register results and protocol monitors.'),
('CPU-02','rv32i_tb_isa','Independently generated reference traces: a directed program of 1,287 instructions and ten seeded random programs of 47,862 in total; nominal, delayed and stalled memories.'),
('CPU-03','rv32i_tb_alu','ALU operations, signed/unsigned boundaries and shifts.'),
('CPU-04','rv32i_tb_bp','Tagged lookup, direction update, collisions, RAS push/pop/overflow/disabled setting and reset.'),
('CPU-05','rv32i_tb_traps','All implemented synchronous causes; precedence, wrong-path errors and precise architectural state; an interrupt and an exception on one instruction; an interrupt pending when MRET re-enables interrupts.'),
('CPU-06','rv32i_tb_csr_ro','CSR legality, fixed fields, write suppression, reserved modes and reset values.'),
('CPU-07','rv32i_tb_counters','Explicit write versus increment; half preservation, carry, CSRRS/CSRRC and fixed event IDs.'),
('CPU-08','rv32i_tb_dual_core','Two distinct HART_IDs on shared memory arbitration; no result corruption.'),
('CPU-09','rv32i_tb_reset','Reset between edges during fetch/load stall, nonzero GPR state, clock stopped, and resumed execution.'),
('CPU-10','rv32i_tb_riscv_tests','Official rv32ui/rv32mi tests at a pinned revision: 53 pass at nominal timing and 40% backpressure; five that need features outside the implemented ISA must fail.')]
PIC_TESTS=[
('PIC-01','pic_tb_feature','Level/edge sources, priority bands/intra-band/ties, nesting, limit, spurious, escalation, SW trigger and access response codes.'),
('PIC-02','pic_tb_reference','Independent priority model: 275 cases covering all 256 BAND_CONFIG encodings, request/enable/CPU masks and ties.'),
('PIC-03','pic_tb_sched','Masked source cannot starve another; fresh edge coincident with claim; reordered-band escalation; trigger-key strobes.'),
('PIC-04','pic_tb_reset','All per-source/global defaults, loaded-state reset before next clock edge, reset with AW-only/W-only/B-held/R-held, recovery.'),
('PIC-05','pic_tb_ro','Write every RO register from a nonzero hardware state; expect SLVERR and unchanged value.'),
('PIC-06','pic_tb_status','PEND, ACTIVE, ESC, SPUR, EFF_BAND and timer fields; exact escalation transitions and complete source life cycle.'),
('PIC-07','rv32i_tb_cpu_axi','CPU programs the real PIC; claim/EOI order, masks, pending and interrupt handling across LSU stalls.'),
('PIC-08','soc_tb_pic_sources / nest / escalate / spurious / deep_nest','Interrupt source routing, nesting to sixteen levels, escalation and a spurious claim with the real CPU in the integrated SoC.'),
('PIC-09','pic_tb_random','Random register writes, sources, masks, claims and EOIs, reconfiguration while nested included; every cycle equal to the cycle model pic_model.py.'),
('PIC-10','pic_formal.sv (SymbiYosys)','Proven for every input: stack depth at most 16, NEST_MAX in 1..16, a claim at the limit and an EOI on an empty stack change nothing, software requests only through a keyed write, only eligible sources offered; five injected defects each fail the proof.')]

def verification(kind):
    cpu=kind=='cpu'; name='RV32I CPU' if cpu else 'PIC';slug='RV32I_CPU' if cpu else 'PIC'
    d=Doc(name+' — Verification Specification','Reproducible stimuli, checks and waveform evidence','Verification_Specification_'+slug+'.tex','Verification specification')
    d.page('Verification objective and evidence',T(['Item','Contract'],[('Requirement source','RV32I 3-Stage Pipeline CPU.pdf' if cpu else 'Programmable Interrupt Controller with Advanced Scheduling (original PIC brief).'),('Device under test','rv32i_cpu_top and its RTL modules.' if cpu else 'pic and axi_lite_slave.'),('Functional verdict','Every expected value and response must match; errors=0 and test_done=1 are required.'),('Protocol verdict','VALID/payload stability, response ordering and outstanding transaction limits; clocked at posedge.'),('Failure handling','Mismatch, timeout, incomplete test, assertion failure or coverage-gate failure returns a failing run.'),('Limits of evidence',('Simulation against independent reference models and the official ISA tests; no synthesis or timing result.' if cpu else 'Simulation against independent models, plus formal proofs of the invariants listed in PIC-10; no synthesis or timing result.'))],[.29,.71])+T(['Simulator / flow','Recorded evidence (23 September 2026)'],[('ModelSim','39 CPU/PIC runs; zero mismatches.'),('Verilator --assert','17 CPU/PIC benches in 53 runs; merged functional coverage 90/90 bins and every cover property reached.'),('Integrated SoC','34 ModelSim runs; 23 assertion-enabled benches in 51 Verilator runs.'),(('riscv-tests','53 of 58 rv32ui/rv32mi tests pass; the other five need features outside the implemented ISA.') if cpu else ('SymbiYosys','Ten PIC invariants proven; each of five injected defects fails the proof.')),('Mutation check','25 injected RTL defects, each detected by its bench.'),('PULP comparison','Decoder over ten random seeds plus 96 register-slave strobe/order/stall cases and RO/unmapped/reset cases.')],[.29,.71]))
    d.page('Verification environment',fig('figures/'+kind+'_verification','Test stimuli, DUT and independent checking paths.','105mm')+T(['Component','File / role'],[('Clock / reset','ck_rst_tb.v: shared generator; dedicated reset benches can drive a reset pulse between edges.'),('Bus stimulus','tb_axil_master.vh: register-access tasks; CPU programs supply real load/store requests at system level.'),('Memory model','axi_lite_mem_model.v: configurable response delay and repeatable backpressure.'),('Reference','isa_reference.py: instruction trace.' if cpu else 'pic_reference.py: expected priority winner and pending mask.'),('Verdict','tb_check.vh: explicit mismatch count, completion and fatal failure.'),('Protocol','axi_lite_monitor.v for ModelSim; axi_lite_sva.sv under Verilator.')],[.24,.76]))
    d.page('Stimulus timing and asynchronous reset',T(['Signal / event','Timing rule','Reason'],[('clk','10 ns period in these traces; rising edges are 5, 15, 25… ns.','Defines the handshake observation points.'),('Shared bus / claim tasks','Drive 1 ns after posedge, in a separate statement. Hold until the sampling edge.','Avoid blocking-assignment races with DUT active/NBA evaluation.'),('Handshake observation','Sample VALID && READY at posedge before changing stimulus.','Records the transfer that the DUT accepted.'),('Reset assertion','Dedicated reset tests assert at posedge +2 ns, check at +3 ns.','The check occurs before either the next falling or rising edge.'),('Reset release','Explicit nanosecond delays, off the clock grid; shared generator releases at 123 ns.','Exercises asynchronous stimulus without a coincident clock event.')],[.24,.42,.34])+wave('cpu_reset' if cpu else 'pic_reset','Reset from active state at posedge +2 ns; cleared state is checked at +3 ns.')
        +sub('Clock and reset generator',P('ck_rst_tb.v generates a 10 ns clock and holds reset from time 0 to 123 ns, off the clock edge. '+('rv32i_tb_reset' if cpu else 'pic_tb_reset')+' drives its own reset pulses between edges.'))
        +(sub('Memory models',P('axi_lite_mem_model.v serves the instruction and data ports. READ_LAT and WRITE_LAT add fixed latency; STALL_PROB and SEED add seeded random backpressure. Overrides are passed with -G and read back after elaboration.'))
          +sub('Programs',P('program_axi.s, assembled by asm.py, runs on the system bench. isa_reference.py writes the directed ISA program and, with --random-set, ten random programs, each with its expected trace. run_riscv_tests.sh builds the official tests with a RISC-V GCC and links them at address 0.'))
          if cpu else
          sub('AXI4-Lite master tasks',P('tb_axil_master.vh provides register read and write tasks that check the response code. AW and W are issued together and may complete in either order.'))
          +sub('Source and CPU-side drivers',P('The block benches drive irq_src_i, cpu_mask_i and the claim/EOI pair directly, in place of the CPU.'))
          +sub('Random traffic',P('pic_tb_random draws register writes, sources, masks, claims and EOIs from a seed (+seed, +cycles) and writes every cycle to pic_random.trace.'))))
    d.page('Directed scenarios and expected results',T(['ID','Testbench','Required observation'],CPU_TESTS if cpu else PIC_TESTS,[.10,.28,.62]))
    d.page('Scenarios requiring cycle-level attention',wave('cpu_load' if cpu else 'pic_edge_claim','Load completion and pipeline advance.' if cpu else 'New edge coincident with claim: the edge latch remains set.')+wave('cpu_redirect' if cpu else 'pic_escalation','Branch correction after a mispredicted branch.' if cpu else 'Ten-cycle deadline: escalation event, then registered source 2 offer under reordered band urgency.')+T(['Scenario','Check'],([('IRQ during load','No accepted IRQ until active LSU transaction is complete.'),('Wrong-path response error','Response is drained; wrong-path instruction cannot write GPR/CSR or trap.'),('Store channel skew','AW and W can complete in either order; one B response completes the store.')] if cpu else [('New edge + claim','Old event is consumed, new event is retained.'),('Band reordering','Escalation follows programmed urgency, not numeric band order.'),('Nest limit + eligible source','Offer suppressed and overflow logged; existing stack is preserved.')]),[.30,.70]))
    d.page('Assertions, monitors and bind',sub('AXI protocol monitor',P('axi_lite_monitor.v checks every transfer on the monitored ports in ModelSim and counts transactions; a run without traffic fails.'))
        +sub('Assertions',P(('axi_lite_sva.sv checks channel stability, legal responses, ordering and one outstanding transaction per direction; rv32i_cpu_core_sva.sv checks pipeline, trap and forwarding invariants.' if cpu else 'axi_lite_sva.sv checks the register port; pic_sva.sv checks offer eligibility, the CPU mask, the priority threshold, depth transitions, claim/EOI exclusion and the empty EOI.')+' rv32i_bind_core_sva.sv attaches the checkers to the RTL module types with bind; they only read DUT signals. Verilator runs them with --assert; ModelSim ASE runs the procedural monitors.'))
        +(sub('Functional coverage',P('rv32i_bind_sva.sv attaches the coverage model rv32i_cpu_func_cov.sv. Its bin counts are merged over the system and ISA runs, and every bin must be reached; every cover property must be reached as well.')) if cpu else '')
        +sub('Result checkers',P('tb_check.vh counts mismatches and ends each run with an explicit verdict. '+('rv32i_tb_isa compares the PC, destination and value of every completed instruction with the reference trace, then the whole data memory.' if cpu else 'pic_tb_reference compares winner and pending mask with pic_reference.py; pic_model.py replays each random trace and compares every cycle.')))
        +(sub('Formal harness',P('pic_formal.sv states the PIC invariants for SymbiYosys. run_formal.sh runs the proofs, then repeats them with five injected defects, each of which must fail.')) if not cpu else '')
        +sub('Non-vacuous checks',T(['Non-vacuous check','Evidence'],[('Valid traffic','Read/write counts and exercised tests prevent a disconnected monitor from being counted as coverage.'),('Preconditions','RO-write test first creates nonzero state; async-reset test first creates pending/nonzero state.'),('Negative scenarios','Watch an interval for forbidden offers/claims; do not infer absence from one sample.')],[.32,.68])))
    d.page('Environment setup and named scripts',r'\needspace{7\baselineskip}\subsubsection{Structure}'+'\n'+T(['Folder','Contents'],[
        ('cpu/hdl','Synthesizable RTL: the CPU modules, the PIC, the timer and the AXI4-Lite register front-end.'),
        ('cpu/debug/hdl','Testbenches, bus masters and the configurable memory and responder models.'),
        ('cpu/debug/sva','Assertion modules and the bind files that attach them to RTL module types.'),
        ('cpu/debug/sim','Run scripts, file lists, reference models, generated programs and run logs.'),
        ('soc/hdl','Integration fabric: address decode, arbitration, AXI4-Full to Lite conversion and RAM.'),
        ('soc/debug/hdl, sva, sim','The same split as above, applied to the integrated SoC.'),
        ('cpu/docs','Specification sources, generated figures and the waveform windows.')],[.22,.78])
        +r'\needspace{7\baselineskip}\subsubsection{Scripts}'+'\n'+T(['Step','Working directory','Command / script','Result'],[('1','Repository root','make asm','Regenerate programs and independent reference vectors.'),('2','cpu/debug/sim','vsim -c -do "do regress.do; quit -f"','Compile and run 39 CPU/PIC runs.'),('3','cpu/debug/sim (Bash / WSL)','bash run_verilator.sh','Lint, 17 benches in 53 runs with SVA, coverage and cover gates.'),('4','soc/debug/sim','vsim -c -do "do regress.do; quit -f"','34 integration runs.'),('5','Repository root (Bash / WSL)','bash soc/debug/sim/run_verilator.sh','SoC lint and 23 assertion-enabled benches in 51 runs.'),('6','soc/debug/sim (Bash / WSL)','bash run_pulp_compare.sh','Pinned external decoder/register comparison.'),('7','Repository root (Bash / WSL)',('bash cpu/debug/sim/run_riscv_tests.sh' if cpu else 'bash cpu/debug/formal/run_formal.sh'),('Official rv32ui/rv32mi tests.' if cpu else 'PIC proofs, then the injected defects.')),('8','Repository root','python cpu/debug/sim/mutation_check.py','25 injected RTL defects.'),('9','cpu/debug/sim','vsim -c -do "do waves.do"','Run 8 checked benches and export VCD traces.'),('10','Repository root','python cpu/docs/tools/waveforms.py','SVG/PDF/PNG figures and source-window manifest.')],[.06,.22,.43,.29])+r'\needspace{7\baselineskip}\subsubsection{Setup and configuration}'+'\n'+T(['Tool / setup','Requirement'],[('ModelSim','vsim/vlog on PATH; run from the named simulation directory so file lists resolve.'),('Verilator','Verilator 5.050 used for the recorded run; C++ build tools, Bash and Python 3 are required.'),('PULP','Git and network only for the initial checkout; explicit revision pins recorded in the runner.'),(('RISC-V GCC','A bare-metal riscv*-elf toolchain; the riscv-tests revision is pinned in the runner.') if cpu else ('SymbiYosys','yosys, sby, yosys-abc and z3 on PATH.')),('Wave rendering','Python with matplotlib; raw VCD files produced by waves.do.'),('Configuration','Latency/stall overrides are read back after elaboration; seeds are fixed for repeatability.')],[.26,.74]))
    d.page('External AXI reference and comparison boundary',T(['Compared block','Shared contract','Evidence'],[('soc_axi_lite_dec vs axi_lite_demux','Two mapped targets, MaxTrans=1; independent progress and response timing.','Compare ordered data/response records and per-target address counts.'),('axi_lite_slave vs axi_lite_regs','32-bit words; four RW words and one RO word; same byte strobes.','96 cases = 16 WSTRB masks × 3 AW/W orders × 2 response-stall settings.'),('Additional register cases','RO write, unmapped access, reset and post-reset access.','Same access-class response and no forbidden state update; each side checked against expected data.')],[.32,.35,.33])+T(['Difference / boundary','Interpretation'],[('Latency','Not cycle-identical; compare completed transactions and protocol compliance.'),('Unmapped read data','Our front-end returns zero; pinned PULP axi_lite_regs returns 0xBA5E1E55. Both return SLVERR; error-data policy is documented separately.'),('Address aliases','Different register-bank sizing; equality claimed only for the explicit compared address profile.'),('AXI4-Full','The PULP run does not establish equivalence of the DMA or soc_axi_full2lite to every upstream AXI4 module.'),('Converter','Local soc_tb_full2lite and soc_tb_full2lite_err check supported burst handling and errors. Local write error aggregation preserves DECERR over SLVERR; PULP is not a cycle-exact reference for that policy.'),('Versions','axi: 70b8e54fd460e3308e58be596ceb3566a6e3576e; common_cells: 03d98106aa19952a10360d2230def85144a0008b.')],[.25,.75])+r'\noindent Reference: \url{https://github.com/pulp-platform/axi}.'+'\n')
    d.save()

if __name__=='__main__':
    cpu_design();pic_design();verification('cpu');verification('pic')
    print('Wrote four table-led specifications.')
