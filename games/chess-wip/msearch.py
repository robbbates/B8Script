"""msearch.py FILE DEPTHS BUILDS: Z80 cycles for one root search per position; max stack depths on ref.py."""
import sys
from bench import run
from model import POS
sys.path.insert(0,'/home/user/B8Script/B8Script-interpreters/testing')
from ref import Ref
prog=open(sys.argv[1],'rb').read()
depths=[int(x) for x in sys.argv[2].split(',')]; builds=sys.argv[3].split(',')
def fen(f):
    f=f.split(); return '.'.join(f[0].split('/'))+' '+f[1]+' '+f[2]+' '+f[3]
class R(Ref):
    def step(self):
        super().step()
        if len(self.rs)>self.mr: self.mr=len(self.rs)
        if len(self.ds)>self.md: self.md=len(self.ds)
for d in depths:
    tot={b:[] for b in builds}; mr=md=0
    for k,f in POS.items():
        r=R(prog+f'"{fen(f)}"F {d}Z;'.encode(), checked=True); r.mr=r.md=0; r.run(20_000_000_000)
        mr=max(mr,r.mr); md=max(md,r.md)
        line=f'd{d} {k:8}'
        for b in builds:
            t0=run(prog+f'"{fen(f)}"F'.encode(),b)[0]
            t,o,e=run(prog+f'"{fen(f)}"F {d}Z;'.encode(),b)
            tot[b].append((t-t0)/4e6); line+=f'  {b} {(t-t0)/4e6:7.1f} s'
        print(line, f' R {r.mr} D {r.md}', flush=True)
    for b in builds:
        x=tot[b]; print(f'd{d} {b}: mean {sum(x)/len(x):.1f} s, range {min(x):.1f}-{max(x):.1f} s')
    print(f'd{d}: max return stack {mr}, max data stack {md}')
