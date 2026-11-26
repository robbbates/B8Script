"""bench.py: run a B8Script program on Z80 builds and print clock ticks.
usage: bench.py FILE|-e CODE [builds...]"""
import sys
import os
T=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','B8Script-interpreters','testing')
sys.path.insert(0,T)
import harness_z80
B={'small':'small-gen','base':'base-gen','fast':'fast-gen','basechk':'base-gen-chk'}
def run(prog, build='base', inp=b'', maxticks=40_000_000_000):
    n=f'{T}/out/z80/b8s-z80-{B[build]}'
    r=harness_z80.Run(n+'.hex',n+'.lst',prog,inp,maxticks=maxticks)
    out=r.run()
    return r.now, out, r.ended
if __name__=='__main__':
    a=sys.argv[1:]
    if a[0]=='-e': prog=a[1].encode(); a=a[2:]
    else: prog=open(a[0],'rb').read(); a=a[1:]
    for b in (a or ['base','fast']):
        t,o,e=run(prog,b)
        print(f'{b:6} {t:>12,} ticks  {e}  out={o[-300:]!r}')
