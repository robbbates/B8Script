import chess
from model import POS, V, evalw, king_capturable, order, MATE
class S: pass
def search(b, d, alpha, beta, st, qd=0):
    if d > 0: st.full += 1
    else: st.cap += 1
    e = evalw(b) * (1 if b.turn == chess.WHITE else -1)
    if d <= 0 and e >= beta: st.spcut += 1
    if king_capturable(b): return MATE
    pl = [m for m in b.pseudo_legal_moves if not (m.promotion and m.promotion != chess.QUEEN)]
    if d <= 0:
        if e >= beta or qd >= 6: return e
        alpha = max(alpha, e)
        moves = order(b, [m for m in pl if b.is_capture(m)], True)
    else:
        moves = order(b, pl, True)
    best = -MATE if d > 0 else e
    for m in moves:
        if d <= 0:
            vic = chess.PAWN if b.is_en_passant(m) else b.piece_type_at(m.to_square)
            if e + V[vic] + 200 < alpha: continue
        st.mu += 1
        b.push(m); sc = -search(b, d-1, -beta, -alpha, st, qd+(d<=0)); b.pop()
        if sc > best:
            best = sc
            if sc > alpha:
                alpha = sc
                if alpha >= beta: break
    return best
COST = {'base': dict(G=392e3, K=273e3, MU=60e3, OV=25e3, P=50e3),
        'fast': dict(G=204e3, K=139e3, MU=29e3, OV=13e3, P=25e3)}
res = {}
for d in (2, 3):
    for k, f in POS.items():
        st = S(); st.full = st.cap = st.mu = st.spcut = 0
        search(chess.Board(f), d, -MATE-1, MATE+1, st)
        res[d, k] = st
        print(f'd{d} {k:8} full {st.full:5} capture-search {st.cap:6} (stand-pat cuts {st.spcut:6}) make {st.mu:6}')
for bld, c in COST.items():
    for d in (2, 3):
        t = [(st.full*c['G'] + st.cap*c['K'] + st.mu*(c['MU']+c['OV']))/4e6 for (dd, k), st in res.items() if dd == d]
        tp = [(st.full*c['G'] + (st.cap-st.spcut)*c['K'] + st.spcut*c['P'] + st.mu*(c['MU']+c['OV']))/4e6 for (dd, k), st in res.items() if dd == d]
        print(f'{bld} depth {d}: mean {sum(t)/len(t):6.0f} s, range {min(t):5.0f}-{max(t):5.0f} s   | with a king-attack probe at stand-pat cuts: mean {sum(tp)/len(tp):6.0f} s, range {min(tp):5.0f}-{max(tp):5.0f}')
