"""Register-driven use flows for the two presentations and interface chapters."""
from diagrams import SVG, MUT

def build(kind):
    d=SVG(670,920)
    if kind=='cpu':
        steps=[('1 · Configure',['mtvec = handler address','mie[16+n] = 1']),('2 · Enable',['mstatus.MIE = 1','source n can be accepted']),('3 · Enter handler',['HW saves mepc / mcause / mtval','HW clears MIE; sends claim']),('4 · Return',['service + clear the source','MRET → mepc; EOI to PIC'])]
    else:
        steps=[('1 · Configure',['SRCx_CONFIG + band policy','NEST_MAX + escalation']),('2 · Enable / request',['INT_ENABLE + CPU mask','HW edge/level or keyed SW write']),('3 · Claim / service',['claim saves ID + priority','handler clears the source']),('4 · Complete',['EOI restores outer context','RW1C clears sticky event flags'])]
    for i,(title,lines) in enumerate(steps):
        y=30+i*220
        d.box(40,y,590,160,title,lines)
        if i<3:d.line([(335,y+160),(335,y+220)])
    d.text(335,909,'CPU instructions ↔ hardware state' if kind=='cpu' else 'Register configuration → service sequence',22,color=MUT)
    d.save(kind+'_software')

if __name__=='__main__':
    build('cpu');build('pic')
