import sys, time
from runref import runref
prog=open(sys.argv[1],'rb').read()
SHOW=b' [P :7&97+\' 16/;49+\'] '
def best(fen, d, steps=4_000_000_000):
    f=fen.split(); s='.'.join(f[0].split('/'))+' '+f[1]+' '+f[2]+' '+f[3]
    t=time.time()
    o,r=runref(prog+SHOW+f'"{s}"F {d}Z # 32\' h@( h@1+,P h@,P 0)'.encode(), steps=steps, checked=True)
    return o.decode('latin1'), r, time.time()-t
TESTS=[
 ('mate in 1, back rank', '6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - -', 2, 'd1d8'),
 ('mate in 1, black', '3r2k1/8/8/8/8/8/5PPP/6K1 b - -', 2, 'd8d1'),
 ('mate in 1, queen', 'k7/8/1K6/8/8/8/8/6Q1 w - -', 2, 'g1g8'),
 ('mate in 2, rook', '5R2/8/8/8/1K6/8/8/k7 w - -', 4, 'b4b3'),
 ('mate in 2, rook 2', '8/8/7R/8/8/6K1/8/5k2 w - -', 4, 'h6e6'),
 ('mate in 2, queen', '5K2/8/8/7k/8/6Q1/8/8 w - -', 4, 'f8f7'),
 ('mate in 2, black', 'K7/8/8/1k6/8/8/8/5r2 b - -', 4, 'b5b6'),
 ('free queen', '4k3/8/8/3q4/8/8/3R4/4K3 w - -', 2, 'd2d5'),
 ('free queen, black', '4k3/3r4/8/8/3Q4/8/8/4K3 b - -', 2, 'd7d4'),
 ('free queen at depth 3', '4k3/8/8/3q4/8/8/3R4/4K3 w - -', 3, 'd2d5'),
 ('pawn guarded by pawn: leave it', '4k3/8/2p5/3p4/8/8/3R4/4K3 w - -', 2, '!d2d5'),
 ('knight guarded by pawn: not with Q', '4k3/8/2p5/3n4/8/8/3Q4/4K3 w - -', 2, '!d2d5'),
 ('take with the pawn, not the queen', '4k3/8/2p5/3n4/4P3/8/3Q4/4K3 w - -', 2, 'e4d5'),
 ('stalemate: no move, score 0', 'k7/8/1Q6/8/8/8/8/4K3 b - -', 2, None),
 ('mated: no move', 'k7/1Q6/1K6/8/8/8/8/8 b - -', 2, None),
]
for name, fen, d, want in TESTS:
    o, r, t = best(fen, d)
    ok = ''
    if want:
        mv = o.split()[-1] if o.split() else ''
        ok = ('OK' if mv not in want[1:].split() else 'BAD') if want.startswith('!') else ('OK' if mv in want.split() else 'BAD')
    print(f'{name:34} d{d}: {o.strip():30} {ok:4} {t:5.1f}s ds={r.ds[-4:]}')
