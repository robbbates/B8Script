import chess, random, sys
from runref import runref
prog=open(sys.argv[1],'rb').read()
random.seed(5); cases=[]
for t in range(400):
    b=chess.Board()
    for i in range(random.randint(0,70)):
        ms=list(b.pseudo_legal_moves)
        if not ms: break
        m=random.choice(ms)
        if b.piece_type_at(m.to_square)==chess.KING: continue
        b.push(m)
    f=b.fen().split(); s='.'.join(f[0].split('/'))+' '+f[1]+' - -'
    cases.append((s, b.is_attacked_by(b.turn, b.king(not b.turn))))
bad=0
for i in range(0,len(cases),50):
    ch=cases[i:i+50]
    tail=b''.join(f'"{s}"F O 0=0= # 32\''.encode() for s,_ in ch)
    o,r=runref(prog+tail, steps=10**10)
    try: got=[int(x) for x in o.split()]
    except ValueError: print(o[-300:]); sys.exit(1)
    for (s,w),g in zip(ch,got):
        if (g!=0)!=w: bad+=1; print('MISMATCH', s, w, g)
print(len(cases),'positions,', sum(w for _,w in cases),'attacked, mismatches', bad)
