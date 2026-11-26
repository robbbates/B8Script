"""measure.py DEV.TXT: Z80 cycles for gen, make/unmake, perft."""
import sys
from bench import run
from refperft import POS
prog=open(sys.argv[1],'rb').read()
builds=[a for a in sys.argv[2:] if not a.startswith('--')] or ['base','fast']
def fen(k):
    f=POS[k].split(); return '.'.join(f[0].split('/'))+' '+f[1]+' '+f[2]+' '+f[3]
def cyc(tail, b):
    t,o,e=run(prog+tail.encode(), b)
    assert e=='exit', (e,o[-200:])
    return t,o
N=50
for k in ('start','kiwi','pos3','pos4','pos5'):
    for b in builds:
        t0,_=cyc(f' "{fen(k)}"F', b)
        tg,o=cyc(f' "{fen(k)}"F 0_a! {N} 1( G a@0_-_; 1-: );', b)
        tk,o=cyc(f' "{fen(k)}"F 0_a! {N} 1( K a@0_-_; 1-: );', b)
        # count moves
        _,o2=cyc(f' "{fen(k)}"F 0_a! G 0_a@- 2/;#', b)
        nm=int(o2)
        # make/unmake every root move once, N/5 times
        tm,_=cyc(f' "{fen(k)}"F 0_a! G {N//5} 1( a@ 1( :M :U 2+ :0_<) ; 1-: );', b)
        tmb,_=cyc(f' "{fen(k)}"F 0_a! G {N//5} 1( a@ 1( 2+ :0_<) ; 1-: );', b)
        gen=(tg-t0)/N; mu=(tm-tmb)/(N//5)/nm
        print(f'{k:6} {b:5} moves {nm:3}  gen {gen:9,.0f} cyc ({gen/nm:6,.0f}/move)  capgen {(tk-t0)/N:9,.0f}  make+unmake {mu:7,.0f}')
for b in (builds if '--perft' in sys.argv else []):
    for d in (1,2,3):
        t0,_=cyc(f' "{fen("start")}"F', b)
        t,o=cyc(f' "{fen("start")}"F {d} f@10+! P #', b)
        print(f'perft start d{d} {b:5} = {o.decode()}  {t-t0:13,} cycles  {(t-t0)/4e6:7.2f} s at 4 MHz')
