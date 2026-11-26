"""Reference perft with queen-only promotions (python-chess)."""
import chess, sys
def perft(b, d):
    if d == 0: return 1
    n = 0
    for m in b.legal_moves:
        if m.promotion and m.promotion != chess.QUEEN: continue
        if d == 1: n += 1; continue
        b.push(m); n += perft(b, d-1); b.pop()
    return n
POS = {
 'start': 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
 'kiwi':  'r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1',
 'pos3':  '8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1',
 'pos4':  'r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1',
 'pos5':  'rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8',
}
if __name__ == '__main__':
    for k, f in POS.items():
        b = chess.Board(f)
        print(k, [perft(b, d) for d in range(1, int(sys.argv[1]) + 1)])
