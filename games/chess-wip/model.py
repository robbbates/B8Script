"""Node-count model of the planned search (negamax alpha-beta, king-capture legality,
captures first, capture search with stand-pat, delta pruning and a depth cap)."""
import chess, sys
V = {chess.PAWN:100, chess.KNIGHT:300, chess.BISHOP:320, chess.ROOK:500, chess.QUEEN:900, chess.KING:0}
def bonus(sq):
    f, r = chess.square_file(sq), chess.square_rank(sq)
    return 2*(min(f,7-f)+min(r,7-r))
def evalw(b):
    s = 0
    for sq, p in b.piece_map().items():
        v = V[p.piece_type] + bonus(sq)
        s += v if p.color == chess.WHITE else -v
    return s
MATE = 30000
class S:
    def __init__(s, mvv): s.full=s.cap=s.mu=s.nodes=0; s.mvv=mvv
def order(b, moves, mvv):
    caps=[m for m in moves if b.is_capture(m)]; quiet=[m for m in moves if not b.is_capture(m)]
    if mvv:
        def key(m):
            vic = chess.PAWN if b.is_en_passant(m) else b.piece_type_at(m.to_square)
            return -(V[vic]*8 - b.piece_type_at(m.from_square))
        caps.sort(key=key)
    return caps+quiet
def king_capturable(b):
    # side to move can capture the other king?
    k = b.king(not b.turn)
    return k is not None and b.is_attacked_by(b.turn, k)
def search(b, d, alpha, beta, st, qd=0, ply=0):
    st.nodes += 1
    if d > 0: st.full += 1
    else: st.cap += 1
    if king_capturable(b): return MATE
    pl = [m for m in b.pseudo_legal_moves if not (m.promotion and m.promotion != chess.QUEEN)]
    e = evalw(b) * (1 if b.turn == chess.WHITE else -1)
    if d <= 0:
        if e >= beta or qd >= 6: return e
        alpha = max(alpha, e)
        moves = order(b, [m for m in pl if b.is_capture(m)], st.mvv)
    else:
        moves = order(b, pl, st.mvv)
    best = -MATE if d > 0 else e
    for m in moves:
        if d <= 0:
            vic = chess.PAWN if b.is_en_passant(m) else b.piece_type_at(m.to_square)
            if e + V[vic] + 200 < alpha: continue
        st.mu += 1
        b.push(m)
        sc = -search(b, d-1, -beta, -alpha, st, qd+(d<=0), ply+1)
        b.pop()
        if sc > best:
            best = sc
            if sc > alpha:
                alpha = sc
                if alpha >= beta: break
    return best
POS = {
 'start': chess.STARTING_FEN,
 'e4e5':  'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
 'italian': 'r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4',
 'qgd':   'rnbqkb1r/ppp2ppp/4pn2/3p4/2PP4/2N5/PP2PPPP/R1BQKBNR w KQkq - 2 4',
 'middle': 'r2q1rk1/pp2bppp/2n1bn2/2pp4/3P4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 9',
 'kiwi':  'r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1',
 'endgame': '8/5pk1/6p1/3P4/2P2K2/8/5P2/8 w - - 0 1',
}
if __name__ == '__main__':
    G, K, MU, OV = (float(x) for x in sys.argv[1:5])   # cycles: full gen, capture gen, make+unmake, per-child overhead
    for mvv in (False, True):
        print('MVV-LVA' if mvv else 'captures in found order')
        for d in (1, 2, 3):
            tot = 0
            for k, f in POS.items():
                st = S(mvv); search(chess.Board(f), d, -MATE-1, MATE+1, st)
                c = st.full*G + st.cap*K + st.mu*(MU+OV)
                tot += c
                print(f'  d{d} {k:8} full {st.full:6} cap {st.cap:7} make {st.mu:7}  {c/4e6:8.1f} s')
            print(f'  d{d} average {tot/len(POS)/4e6:8.1f} s at 4 MHz')
