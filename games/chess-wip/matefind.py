import chess, random, sys
def mates_in(b, n):
    """moves of the side to move that force mate in n of its own moves"""
    out = []
    for m in list(b.legal_moves):
        b.push(m)
        if b.is_checkmate(): ok = True
        elif n == 1 or b.is_game_over(): ok = False
        else: ok = all(forced(b, r, n-1) for r in list(b.legal_moves))
        b.pop()
        if ok: out.append(m)
    return out
def forced(b, r, n):
    b.push(r); ok = bool(mates_in(b, n)); b.pop(); return ok
if __name__ == '__main__':
    random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 3)
    got = 0
    for piece in 'RQ':
        for t in range(40000):
            sq = random.sample(range(64), 3)
            b = chess.Board(None)
            b.set_piece_at(sq[0], chess.Piece(chess.KING, True)); b.set_piece_at(sq[1], chess.Piece(chess.KING, False))
            b.set_piece_at(sq[2], chess.Piece.from_symbol(piece)); b.turn = True
            if not b.is_valid() or mates_in(b, 1): continue
            m = mates_in(b, 2)
            if m and len(m) <= 2:
                print(b.fen(), [x.uci() for x in m]); got += 1
                if got % 2 == 0: break
