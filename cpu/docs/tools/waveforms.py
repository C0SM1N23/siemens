"""Render measured VCD windows as SVG/PDF/PNG; never synthesize signal transitions."""
from pathlib import Path
from collections import defaultdict
import bisect, hashlib, json, re
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

DOCS = Path(__file__).resolve().parents[1]

class VCD:
    def __init__(self, name):
        self.path = DOCS / 'waves/raw' / (name + '.vcd')
        self.name = name
        self.ids = {}
        self.data = defaultdict(list)
        scope = []
        header = True
        time = 0
        source = self.path.read_text()
        unit = re.search(r'\$timescale\s+(\d+)\s*(fs|ps|ns|us|ms|s)\s+\$end', source)
        if not unit:
            raise ValueError(f'Missing VCD timescale: {self.path}')
        tick_ns = int(unit[1]) * {'fs': 1e-6, 'ps': .001, 'ns': 1, 'us': 1e3, 'ms': 1e6, 's': 1e9}[unit[2]]
        for line in source.splitlines():
            tok = line.split()
            if not tok: continue
            if header:
                if tok[0] == '$scope': scope.append(tok[2])
                elif tok[0] == '$upscope': scope.pop()
                elif tok[0] == '$var':
                    suffix = tok[5] if tok[5].startswith('[') else ''
                    key = '.'.join(scope + [tok[4]])
                    if int(tok[2]) == 1 and suffix: key += suffix
                    self.ids[key] = (tok[3], int(tok[2]))
                elif tok[0] == '$enddefinitions': header = False
                continue
            if line[0] == '#': time = round(int(line[1:]) * tick_ns, 9)
            elif line[0] in '01xXzZ':
                self.data[line[1:]].append((time,line[0].lower()))
            elif line[0] in 'bB': self.data[tok[1]].append((time,tok[0][1:].lower()))
        self.end = time
        # VCD can record several delta-cycle updates at one physical time.
        # Show the settled value at that timestamp; retain all nonzero durations.
        for code,seq in self.data.items():
            settled = dict(seq)
            result = []
            for t,v in settled.items():
                if not result or result[-1][1] != v: result.append((t,v))
            self.data[code] = result

    def signal(self, name):
        full = self.name + '.' + name
        if full in self.ids:
            code, width = self.ids[full]
            return width, self.data[code]
        bits = []
        for key, (code,width) in self.ids.items():
            m=re.fullmatch(re.escape(full)+r'\[(\d+)\]', key)
            if m: bits.append((int(m[1]),code))
        if not bits: raise KeyError(full)
        width=max(x[0] for x in bits)+1
        events=defaultdict(list)
        for bit,code in bits:
            for t,v in self.data[code]: events[t].append((bit,v))
        state=['x']*width
        result=[]
        for t,changes in sorted(events.items()):
            for bit,value in changes: state[bit]=value
            value=''.join(reversed(state))
            if not result or value!=result[-1][1]: result.append((t,value))
        return width,result

    def changes(self, name, value=None):
        return [(t,int(v,2)) for t,v in self.signal(name)[1] if set(v)<=set('01') and (value is None or int(v,2)==value)]

    def value(self, name, time):
        seq=self.signal(name)[1]
        i=bisect.bisect_right([x[0] for x in seq],time)-1
        return int(seq[i][1],2) if i>=0 and set(seq[i][1])<=set('01') else None

def render(vcd, slug, names, start, stop, description, markers=()):
    import math
    # Show complete ten-nanosecond cycles at both ends of each window.
    start = 5 + 10 * math.floor((start - 5) / 10)
    stop = 5 + 10 * math.floor((stop - 5) / 10)
    out=DOCS/'waves'
    out.mkdir(exist_ok=True)
    fig,ax=plt.subplots(figsize=(12.8,0.53*len(names)+0.75),dpi=160)
    fig.patch.set_facecolor('white')
    ax.set_facecolor('white')
    records=[]
    for n,item in enumerate(names):
        name,label=item if isinstance(item,tuple) else (item,item)
        width,seq=vcd.signal(name)
        initial='x'
        for t,v in seq:
            if t<=start: initial=v
            else: break
        points=[(start,initial)]+[(t,v) for t,v in seq if start<t<stop]+[(stop,None)]
        y=(len(names)-1-n)*1.15
        color='#005F73' if name!='clk' else '#596A76'
        if width==1:
            xs=[p[0] for p in points[:-1]]+[stop]
            ys=[y+(0.62 if p[1]=='1' else 0) for p in points[:-1]]
            ys+=[ys[-1]]
            ax.step(xs,ys,where='post',color=color,lw=1.7)
            for (t,v),(t2,_) in zip(points,points[1:]):
                if v not in ('0','1'): ax.text((t+t2)/2,y+0.2,v,color='#B04B35',ha='center',fontsize=9)
        else:
            for (t,v),(t2,_) in zip(points,points[1:]):
                ax.plot([t,t2],[y,y],color=color,lw=1.25)
                ax.plot([t,t2],[y+0.62,y+0.62],color=color,lw=1.25)
                if t>start: ax.plot([t,t],[y,y+0.62],color=color,lw=1)
                if t2-t>(stop-start)*.025:
                    value=f'{int(v,2):X}' if set(v)<=set('01') else v
                    ax.text((t+t2)/2,y+.31,value,ha='center',va='center',fontsize=9,color='#142D3B',fontfamily='DejaVu Sans Mono')
        ax.text(start-(stop-start)*.018,y+.3,label,ha='right',va='center',fontsize=10,fontfamily='DejaVu Sans Mono',color='#142D3B')
        records.append({'signal':name,'label':label,'width':width,'events':points[:-1]})
    clk=vcd.changes('clk',1)
    for t,_ in clk:
        if start<=t<=stop: ax.axvline(t,color='#D8E2E6',lw=.55,zorder=0)
    for t,label in markers:
        ax.axvline(t,color='#BB6B21',lw=1,ls='--',zorder=1)
        ax.text(t,len(names)*1.15+.12,label,ha='center',va='bottom',fontsize=10,color='#905013',fontweight='bold')
        ax.annotate('',xy=(t,(len(names)-1)*1.15+.72),xytext=(t,len(names)*1.15+.06),arrowprops={'arrowstyle':'-|>','color':'#BB6B21','lw':1})
    ax.set_xlim(start,stop)
    ax.set_ylim(-.35,len(names)*1.15+.65)
    ax.set_yticks([])
    ax.set_xlabel('Time (ns) · buses: hex · grid: posedge clk',fontsize=10,color='#52626B')
    for sp in ('left','right','top'): ax.spines[sp].set_visible(False)
    ax.spines['bottom'].set_color('#ADBCC4')
    ax.tick_params(axis='x',labelsize=9)
    fig.subplots_adjust(left=.255,right=.985,top=.97,bottom=.14)
    for ext in ('svg','pdf','png'): fig.savefig(out/f'{slug}.{ext}',facecolor='white')
    plt.close(fig)
    return {'file':slug,'testbench':vcd.name,'source_sha256':hashlib.sha256(vcd.path.read_bytes()).hexdigest(),
            'start_ns':start,'stop_ns':stop,'description':description,'signals':records,'markers':markers}

def main():
    import argparse
    p=argparse.ArgumentParser();p.add_argument('--inspect',action='store_true');args=p.parse_args()
    vs={n:VCD(n) for n in ['rv32i_tb_cpu_axi','rv32i_tb_reset','rv32i_tb_bp','rv32i_tb_traps','pic_tb_feature','pic_tb_sched','pic_tb_status','pic_tb_reset']}
    if args.inspect:
        for n,signals in {
            'rv32i_tb_cpu_axi':['db_arvalid','db_awvalid','cpu_irq_ack','cpu_irq_eoi','uut.mispredict','uut.wfi_wait'],
            'pic_tb_feature':['irq_src','cpu_irq_ack','cpu_irq_eoi','dut.depth','dut.spurious'],
            'pic_tb_sched':['irq_src','cpu_irq_ack'],
            'pic_tb_status':['irq_src'],
            'pic_tb_reset':['rst_n'],
            'rv32i_tb_reset':['rst_n','clock_run']}.items():
            print(n)
            for sig in signals:
                print(sig,vs[n].changes(sig)[:70])
        return
    specs=[]
    def add(v,slug,names,start,stop,desc,markers=()):specs.append(render(vs[v],slug,names,start,stop,desc,markers))
    cpu=vs['rv32i_tb_cpu_axi']
    # Windows are selected from actual events in the generated trace.
    t=cpu.changes('db_arvalid',1)[0][0]
    add(cpu.name,'cpu_load',['clk',('db_arvalid','dbus_axi_arvalid_o'),('db_arready','dbus_axi_arready_i'),('db_rvalid','dbus_axi_rvalid_i'),('db_rready','dbus_axi_rready_o'),('uut.lsu_active','lsu_active'),('uut.s2_advance','s2_advance')],t-15,t+85,'Load: S2 waits until the response handshake.')
    t=cpu.changes('db_awvalid',1)[0][0]
    add(cpu.name,'cpu_store',['clk',('db_awvalid','dbus_axi_awvalid_o'),('db_awready','dbus_axi_awready_i'),('db_wvalid','dbus_axi_wvalid_o'),('db_wready','dbus_axi_wready_i'),('db_bvalid','dbus_axi_bvalid_i'),('db_bready','dbus_axi_bready_o')],t-15,t+85,'Write address, data and response are separate handshakes.')
    add(cpu.name,'cpu_fetch',['clk',('ib_araddr','ibus_axi_araddr_o [31:0]'),('ib_arvalid','ibus_axi_arvalid_o'),('ib_arready','ibus_axi_arready_i'),('ib_rvalid','ibus_axi_rvalid_i'),('ib_rready','ibus_axi_rready_o'),('uut.ifdx_valid_q','ifdx_valid_q')],120,220,'Instruction fetch after reset release at 123 ns.')
    # Use the directed IRQ-through-LSU scenario, not the first convenient pulse.
    rdone=cpu.changes('t_rbeat2')[-1][1]
    claim=next(t for t,_ in cpu.changes('cpu_irq_ack',1) if t>rdone)
    request=max(t for t,_ in cpu.changes('cpu_irq',1) if t<rdone)
    assert cpu.value('uut.lsu_active',request)==1 and claim>rdone
    assert cpu.value('cpu_irq_ack',rdone-0.001)==0
    add(cpu.name,'cpu_irq',['clk',('db_rvalid','dbus_axi_rvalid_i'),('db_rready','dbus_axi_rready_o'),('uut.lsu_active','lsu_active'),('cpu_irq','cpu_irq_i'),('cpu_irq_ack','cpu_irq_ack_o'),('cpu_in_trap','cpu_in_trap_o')],request-25,claim+35,'IRQ waits for the load response handshake; claim follows at the next instruction boundary.',[(request,'1'),(rdone,'2'),(claim,'3')])
    t=cpu.changes('uut.mispredict',1)[0][0]
    add(cpu.name,'cpu_redirect',['clk',('uut.mispredict','mispredict'),('uut.redirect','redirect'),('uut.ifdx_valid_q','ifdx_valid_q'),('ib_arvalid','ibus_axi_arvalid_o'),('ib_rvalid','ibus_axi_rvalid_i'),('uut.dxwb_valid_q','dxwb_valid_q')],t-15,t+85,'A misprediction redirects fetch and removes younger work.')
    for slug,start,stop in [('cpu_reset',22,65),('cpu_reset_stopped',85,135)]:
        reset_signals=['clk','rst_n','clock_run',('dut.dxwb_valid_q','dxwb_valid_q (S3)')] if slug.endswith('stopped') else ['clk','rst_n',('ib_arvalid','ibus_axi_arvalid_o')]
        add('rv32i_tb_reset',slug,reset_signals,start,stop,'Reset asserts between clock edges; state clears before the next edge.')
    pic=vs['pic_tb_feature']
    t=next(t for t,v in pic.changes('irq_src') if v==8)
    end=next(t1 for t1,v in pic.changes('dut.depth') if t1>t and v==0)
    names=['clk',('irq_src','irq_src_i [15:0]'),('cpu_irq','cpu_irq_o'),('cpu_irq_vec','cpu_irq_vec_o [3:0]'),('cpu_irq_ack','cpu_irq_ack_i'),('cpu_irq_eoi','cpu_irq_eoi_i'),('dut.depth','depth [4:0]')]
    add(pic.name,'pic_claim',names,t-15,end+20,'A level request is claimed; EOI removes the active stack entry.')
    t=next(t for t,v in pic.changes('irq_src') if v==256)
    end=next(t1 for t1,v in pic.changes('dut.depth') if t1>t and v==0)
    edges=[(t1,v) for t1,v in pic.changes('dut.depth') if t<=t1<=end]
    assert [v for _,v in edges]==[1,2,1,0]
    assert [pic.value('dut.active',t1) for t1,_ in edges]==[0x100,0x300,0x100,0]
    offer=next(x for x,_ in pic.changes('cpu_irq',1) if x>=t)
    add(pic.name,'pic_nesting',names+[('dut.active','active [15:0]')],offer,end+20,'Source 9 preempts source 8; active masks prove retention and restoration of the outer context. Vector is meaningful only while IRQ is high.',[(x,str(i+1)) for i,(x,_) in enumerate(edges)])
    t=next(t for t,v in pic.changes('dut.spurious') if v!=0)
    add(pic.name,'pic_spurious',names+ [('dut.spurious','spurious [15:0]')],t-65,t+55,'A source disappears before claim; the event is marked spurious.')
    sc=vs['pic_tb_sched']
    t=next(t for t,v in sc.changes('irq_src') if v==8)
    end=next(x for x,_ in sc.changes('rst_n',0) if x>t)-1
    add(sc.name,'pic_edge_claim',['clk',('irq_src','irq_src_i [15:0]'),('cpu_irq_ack','cpu_irq_ack_i'),('cpu_irq_eoi','cpu_irq_eoi_i'),('cpu_irq','cpu_irq_o'),('dut.edge_pend','edge_pend [15:0]')],t-15,end,'A second rising edge coincident with a claim remains pending; the source is offered again after EOI.')
    t=next(t for t,v in sc.changes('irq_src') if v==6)
    offered=next(x for x,value in sc.changes('cpu_irq_vec') if x>t and value==2)
    end=min(offered+20,next(x for x,_ in sc.changes('rst_n',0) if x>t)-1)
    add(sc.name,'pic_escalation',['clk',('irq_src','irq_src_i [15:0]'),('cpu_irq','cpu_irq_o'),('dut.escalate_v[2]','deadline event (src 2)'),('dut.escalated','escalated [15:0]'),('cpu_irq_vec','cpu_irq_vec_o [3:0]')],t-15,end,'Source 2 deadline is 10 cycles: the escalation event precedes the registered change of offered source.')
    pr=vs['pic_tb_reset'];t=[t for t,v in pr.changes('rst_n') if v==0 and t>0][0]
    add(pr.name,'pic_reset',['clk','rst_n',('dut.depth','depth [4:0]'),('dut.int_enable','int_enable [15:0]')],t-22,t+48,'Reset at posedge +2 ns clears configured state before the next clock edge.')
    (DOCS/'waves/manifest.json').write_text(json.dumps(specs,indent=2))
    print(f'Rendered {len(specs)} measured waveforms.')

if __name__=='__main__':main()
