import sys
from bench import run
from refperft import POS
def fen(k):
    f=POS[k].split(); return '.'.join(f[0].split('/'))+' '+f[1]+' '+f[2]+' '+f[3]
N=20
for path in sys.argv[1:]:
    prog=open(path,'rb').read()
    for b in ('base','fast'):
        tg=tk=0
        for k in POS:
            t0=run(prog+f' "{fen(k)}"F'.encode(),b)[0]
            tg+=run(prog+f' "{fen(k)}"F 0_a! {N} 1( G a@0_-_; 1-: );'.encode(),b)[0]-t0
            tk+=run(prog+f' "{fen(k)}"F 0_a! {N} 1( K a@0_-_; 1-: );'.encode(),b)[0]-t0
        print(f'{path:24} {b:5} gen avg {tg/N/len(POS):9,.0f}  capgen avg {tk/N/len(POS):9,.0f}')
