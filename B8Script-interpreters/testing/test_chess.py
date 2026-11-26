"""Tests of the chess engine in games/CHESS.TXT on the reference interpreter.

usage: test_chess.py            (run by hand, like the other test scripts)

CHESS.TXT keeps a perft word (it counts the leaves of the move tree to a depth) in a
comment, so that it is in neither program's code. This takes CHESS.B8S up to its main
program, adds that word, and checks:
  - perft of five standard positions against the known counts, with promotion to a
    queen only (as the game plays it), so the counts are those of python-chess with
    the underpromotions left out;
  - searches: mates in one (depth 2) and two (depth 4), free pieces taken, guarded
    ones left, stalemate and mate scored.
Each run is a checked ref.py, so a stack or bracket mistake stops it with a report.
"""
import sys, os, re
here = os.path.dirname(os.path.abspath(__file__))
GAMES = os.path.normpath(os.path.join(here, '..', '..', 'games'))
sys.path.insert(0, here)
from ref import Ref


def program():
    """CHESS.B8S before its main program, with the perft word from CHESS.TXT."""
    b8s = open(os.path.join(GAMES, 'CHESS.B8S'), 'rb').read()
    txt = open(os.path.join(GAMES, 'CHESS.TXT'), 'rb').read()
    perft = re.search(rb'\[P 0_.*?;%0_-_;\]', txt, re.S).group(0)
    perft = re.sub(rb'";\s*"', b' ', perft)
    return b8s[:b8s.index(b'"! Main program";')] + perft + b' '


def fen(f):
    """A FEN as the game's F word takes it: ranks joined by '.'."""
    p = f.split()
    return '.'.join(p[0].split('/')) + ' ' + p[1] + ' ' + p[2] + ' ' + p[3]


def run(prog, tail):
    r = Ref(prog + tail.encode(), checked=True)
    r.run(4_000_000_000)
    return bytes(r.out).decode('latin-1'), r


PERFT = [   # (name, FEN, counts at depth 1, 2, ...), queen promotions only
    ('start', 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -', [20, 400, 8902]),
    ('Kiwipete', 'r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -', [48, 2039]),
    ('position 3', '8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -', [14, 191, 2812]),
    ('position 4', 'r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq -', [6, 228]),
    ('position 5', 'rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ -', [41, 1373]),
]

SEARCH = [  # (what, FEN, depth, the move it must play or, with !, must not play)
    ('mate in 1, back rank', '6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - -', 2, 'd1d8'),
    ('mate in 1, as black', '3r2k1/8/8/8/8/8/5PPP/6K1 b - -', 2, 'd8d1'),
    ('mate in 1, queen', 'k7/8/1K6/8/8/8/8/6Q1 w - -', 2, 'g1g8'),
    ('mate in 2, rook', '5R2/8/8/8/1K6/8/8/k7 w - -', 4, 'b4b3'),
    ('mate in 2, queen', '5K2/8/8/7k/8/6Q1/8/8 w - -', 4, 'f8f7'),
    ('mate in 2, as black', 'K7/8/8/1k6/8/8/8/5r2 b - -', 4, 'b5b6'),
    ('free queen', '4k3/8/8/3q4/8/8/3R4/4K3 w - -', 2, 'd2d5'),
    ('free queen, as black', '4k3/3r4/8/8/3Q4/8/8/4K3 b - -', 2, 'd7d4'),
    ('pawn guarded by a pawn: leave it', '4k3/8/2p5/3p4/8/8/3R4/4K3 w - -', 2, '!d2d5'),
    ('knight guarded by a pawn: not with the queen', '4k3/8/2p5/3n4/8/8/3Q4/4K3 w - -', 2, '!d2d5'),
    ('take it with the pawn', '4k3/8/2p5/3n4/4P3/8/3Q4/4K3 w - -', 2, 'e4d5'),
]
SCORE = [   # (what, FEN, depth, score: no legal move)
    ('stalemated: 0', 'k7/8/1Q6/8/8/8/8/4K3 b - -', 2, 0),
    ('mated: -29000 less the depth', 'k7/1Q6/1K6/8/8/8/8/8 b - -', 2, -29002),
]
SQ = " [X :1+,:7&97+'16/;49+' ,:7&97+'16/;49+'] "     # print the move at an address
ROOT = '{d} 0h! f@a! a@10+! -30000a@12+! 30000a@14+! N'


if __name__ == '__main__':
    prog = program()
    bad = 0
    for name, f, want in PERFT:
        got = []
        for d in range(1, len(want) + 1):
            out, r = run(prog, f'"{fen(f)}"F {d} f@10+! P #')
            got.append(int(out) % 65536 if out.strip().lstrip('-').isdigit() else out.strip())
        ok = got == [w % 65536 for w in want]
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  perft {name:11} {got}' + ('' if ok else f'  want {want}'))
    for what, f, d, want in SEARCH:
        out, r = run(prog + SQ.encode(), f'"{fen(f)}"F {ROOT.format(d=d)} # 32\' h@X')
        mv = out.split()[-1] if out.split() else ''
        ok = (mv != want[1:]) if want.startswith('!') else (mv == want)
        ok = ok and not r.ds
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  search {what}: {out.strip()}')
    for what, f, d, want in SCORE:
        out, r = run(prog, f'"{fen(f)}"F {ROOT.format(d=d)} # h@#')
        ok = out.strip() == f'{want}0' and not r.ds
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  search {what}: {out.strip()} (score, then 0 for no move)')
    print('chess:', 'all pass' if not bad else f'{bad} FAILED')
    sys.exit(1 if bad else 0)
