"""Scripted play tests for the tweet-sized games in games/tweets/, on ref.py.

usage: test_tweets.py [NAME...]

Every game must fit in a tweet: 160 characters at most. Each test types a fixed
key sequence at a checked reference build, as test_games.py does (a NUL is a
key that hasn't come yet), and checks that the run prints the expected texts
and stops without an error report. A test marked 'end' must also reach the end
of the program, not just run out of keys, and leave the data stack empty.
See docs/tweet-games.md for the games themselves.
"""
import sys, os
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from ref import Ref, NeedKey

GAMES = os.path.join(here, 'games', 'tweets')
LIMIT = 160


class Play(Ref):
    """ref.py, but a ? with no keys left ends the run, and says so."""
    waiting = False

    def step(self):
        if self.m[self.ip] == ord('?') and not self.inp:
            self.waiting = True
            raise NeedKey
        super().step()


def simon(seed, rounds):
    """Keys for Simon: the seed key after seed-1 empty looks, then each round's
    digits (worked out with the game's own generator), then a wrong round."""
    keys, r = b'\0' * (seed - 1) + b'k', seed
    for n in range(1, rounds + 1):
        r, digits = seed, b''
        for _ in range(n):
            r = (r * 75 + 74) & 0xFFFF
            sr = r - 65536 if r > 32767 else r
            digits += bytes([(int(sr / 256) & 7) + 49])
        keys += b'\0' + digits
    return keys + b'\0' + b'9' * (rounds + 1)


TESTS = [
    # Hi-Lo: the key after three empty looks picks 4; binary search finds it
    ('HILO', 'binary search wins', b'\0\0\0k64\r32\r16\r8\r4\r', [b'4 WIN'], 'end'),
    ('HILO', 'seven misses lose', b'k100\r50\r25\r12\r6\r3\r2\r', [b'2 down LOSE 1'], 'end'),
    # Lander: free fall, then a suicide burn (found by search over every burn)
    ('LANDER', 'suicide burn lands', b'0' * 21 + b'99998999996', [b'h1000 v0 f99 ?', b'1 LANDED'], 'end'),
    ('LANDER', 'no burn crashes', b'0' * 30, [b'CRASH'], 'end'),
    # Nim: start 24. Taking 3 leaves 21 (1 mod 4), and the player keeps it there
    ('NIM', 'perfect play wins', b'\0\0\0k3333333', [b'24 take 3 I take 1', b'I lose'], 'end'),
    ('NIM', 'start 21 loses', b'k3333333333', [b'21 take 3', b'you lose'], 'end'),
    ('REFLEX', 'early and on time', b'k' + b'\0' * 7 + b'x' + b'\0' * 5 + b'yzk' + b'\0' * 50 + b'a',
     [b'GO! 7', b'early', b'GO! 50', b'total 2060'], 'end'),
    # Ski: nobody steers, so the course drifts into the skier
    ('SKI', 'drift into a wall', b'\0' * 300, [b'SKI j l', b'|    V   |'], 'end'),
    ('SKI', 'j steers left', b'\0\0j', [b'        |     V  |\r\n        |    V   |'], None),
    # Rock paper scissors: the AI learns a cycle; beating its prediction wins
    ('RPS', 'it learns 1 2 3', b'1231231231231231231231', [b'? SR -5'], 'end'),
    ('RPS', 'beat its prediction', b'33323', [b'? SP 1', b'? PR 4', b'? SP 5'], 'end'),
    ('SIMON', 'eight rounds', simon(7, 8), [b'31824664', b'score 8'], 'end'),
    # Pig: the roll is the key's timing mod 6; five empty looks roll a 1
    ('PIG', 'pig, then hold at 102', b'r' + b'\0' * 5 + b'r' + (b'\0' * 4 + b'r') * 17 + b'h',
     [b'1 0+2 1', b'2 0+96 6', b'2 turns'], 'end'),
    ('TRON', 'turn into its own trail', b'\0' * 5 + b'.' + b'\0' * 20 + b',' + b'\0' * 3 + b',' + b'\0' * 3 + b',' + b'\0' * 5,
     [b'\x1b[9;10HO', b'\x1b[1;14HO', b'\x1b[18Hscore 21'], 'end'),
    # Lights Out: the 15-press solution of the all-on board, in both cases
    ('LIGHTS', 'solve it', b'abfgijmnoqrsvwy', [b'ABCDE', b'abCDE', b'uvwxy in 15'], 'end'),
    ('LIGHTS', 'upper case, stray keys', b' 0ABFGIJMNOQRSVWY0', [b'uvwxy in 18'], 'end'),
]


if __name__ == '__main__':
    want = [a.upper() for a in sys.argv[1:]]
    bad = 0
    for f in sorted(os.listdir(GAMES)):
        name = f[:-4]
        if not f.endswith('.B8S') or (want and name not in want):
            continue
        n = len(open(os.path.join(GAMES, f), 'rb').read())
        ok = n <= LIMIT
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  {name:7} {n} characters')
    for game, what, keys, texts, end in TESTS:
        if want and game not in want:
            continue
        r = Play(open(os.path.join(GAMES, game + '.B8S'), 'rb').read(), keys, checked=True)
        out = r.run(20_000_000)
        miss = [t for t in texts if t not in out]
        ended = not r.waiting and not r.ds
        ok = not miss and r.error is None and (ended or end != 'end')
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  {game:7} {what}')
        if r.error:
            print('      error report:', out[out.rfind(b'Err'):].decode('latin-1'))
        for t in miss:
            print('      missing:', t)
        if end == 'end' and not ended:
            print('      did not end cleanly:', 'waiting for a key' if r.waiting else f'stack {r.ds}')
    print('tweets:', 'all pass' if not bad else f'{bad} FAILED')
    sys.exit(1 if bad else 0)
