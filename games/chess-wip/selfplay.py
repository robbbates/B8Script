import sys, chess
from runref import runref
prog=open(sys.argv[1],'rb').read(); depth=int(sys.argv[2]); n=int(sys.argv[3])
fens=sys.argv[4:] or [chess.STARTING_FEN]
SHOW=b' [P :7&97+\' 16/;49+\'] '
def bonus(sq):
    f, r = chess.square_file(sq), chess.square_rank(sq); return 2*(min(f,7-f)+min(r,7-r))
V={1:100,2:300,3:320,4:500,5:900,6:0}
def ev(b):
    s=0
    for sq,p in b.piece_map().items():
        r=chess.square_rank(sq)
        adv=4*((r-1) if p.color else (6-r))
        v=V[p.piece_type]+(bonus(sq)//2 if p.piece_type==6 else adv if p.piece_type==1 else bonus(sq)); s+= v if p.color else -v
    return s if b.turn else -s
for fen in fens:
    f=fen.split(); s='.'.join(f[0].split('/'))+' '+f[1]+' '+f[2]+' '+f[3]
    tail=f'"{s}"F {n} 1( {depth}Z; h@0=\\ h@1+,P h@,P h@M 32\' e@# 10\' 1-:);'
    o,r=runref(prog+SHOW+tail.encode(), steps=20_000_000_000)
    b=chess.Board(fen); bad=0; moves=[]
    for line in o.decode('latin1').split('\n'):
        p=line.split()
        if len(p)!=2: 
            if line.strip(): print('??', line); bad+=1
            continue
        u=p[0]; m=chess.Move.from_uci(u)
        if b.piece_type_at(m.from_square)==1 and chess.square_rank(m.to_square) in (0,7): m=chess.Move.from_uci(u+'q')
        if m not in b.legal_moves: print('ILLEGAL', u, b.fen()); bad+=1; break
        b.push(m); moves.append(u)
        if int(p[1])!=ev(b): print('EVAL', u, p[1], ev(b), b.fen()); bad+=1
    print(f'{"OK " if not bad else "BAD"} {len(moves)} moves, end: {b.fen()}  {b.outcome()}')
    print(' '.join(moves))
