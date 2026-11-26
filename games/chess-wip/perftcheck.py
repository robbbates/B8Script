import sys, time
from runref import runref
from refperft import POS, perft
import chess
prog=open(sys.argv[1],'rb').read()
D=int(sys.argv[2]) if len(sys.argv)>2 else 3
for k,fen in POS.items():
    f=fen.split()
    s='.'.join(f[0].split('/'))+' '+f[1]+' '+f[2]+' '+f[3]
    want=[perft(chess.Board(fen),d)%65536 for d in range(1,D+1)]
    got=[]
    for d in range(1,D+1):
        t=time.time()
        o,r=runref(prog+f' "{s}"F {d} f@10+! P #'.encode(), steps=2_000_000_000)
        got.append(int(o) % 65536 if o.strip().lstrip(b'-').isdigit() else o)
    print(k, 'OK' if got==want else 'BAD', got, want)
