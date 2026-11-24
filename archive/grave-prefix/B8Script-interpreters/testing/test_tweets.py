"""Scripted play tests for the tiny games: games/b8sms/ (an SMS, 160 characters),
games/tweet140/ and games/tweet280/ (a tweet, old and new), and games/longer/
(an example of what fits in a few more), on ref.py.

usage: test_tweets.py [--all] [NAME...]

Every game must fit its folder's limit. Each test types a fixed key sequence at
a checked reference build, as test_games.py does (a NUL is a timed wait that
runs out with no key: it stirs the random seed by the wait's count), and checks
that the run prints the expected texts and stops without an error report. The
random seed starts at 0, as in ref.py, unless the test has a sixth item, which
is the seed to start from: no key can set it, since a key that is there at
once stirs nothing. A test marked 'end' must also reach the end of the program,
not just run out of keys, and leave the data stack empty. --all adds the slow
check that Tic-tac-toe never loses: it plays every legal line against it.
See docs/b8sms.md for the games themselves.
"""
import sys, os, random
here = os.path.dirname(os.path.abspath(__file__))
GAMES = os.path.normpath(os.path.join(here, '..', '..', 'games'))   # games/ at the root of the repository
sys.path.insert(0, here)
from ref import Ref, NeedKey

LIMITS = {'b8sms': 160, 'tweet140': 140, 'tweet280': 280, 'longer': 390}


class Play(Ref):
    """ref.py, but a ? with no keys left ends the run, and says so."""
    waiting = False

    def step(self):
        if self.m[self.ip] == ord('?') and not self.inp:
            self.waiting = True
            raise NeedKey
        super().step()


def path(folder, game):
    return os.path.join(GAMES, folder, game + '.B8S')


def play(folder, game, keys, steps=200_000_000, seed=0):
    r = Play(open(path(folder, game), 'rb').read(), keys, checked=True)
    r.w(r.seedcell, seed)       # the random seed `. starts here (ref.py: 0)
    return r, r.run(steps)


def simon(rounds):
    """Keys for Simon: a key to start (the seed is still 0 then, as ref.py
    starts it), then each round's digits (worked out with `, from that seed,
    as the game replays them), then a wrong round."""
    keys = b'k'
    for n in range(1, rounds + 1):
        r, digits = 0, b''
        for _ in range(n):
            r = (r * 261 + 1) & 0xFFFF
            digits += bytes([(r ^ r >> 8) % 8 + 49])
        keys += b'\0' + digits
    return keys + b'\0' + b'9' * (rounds + 1)


def kingdom(extra):
    """Keys for Kingdom: each year feed 20 a head, plus a share of what is left
    over, reading the state from what the game printed."""
    keys = b''
    for year in range(10):
        r, out = play('tweet280', 'KINGDOM', keys)
        if not r.waiting:
            break
        words = out.split(b'\r\n')[-1].split()
        pop, grain = int(words[2]), int(words[4])
        need = pop * 20
        keys += str(need + int((grain - need) * extra) if grain > need else grain).encode() + b'\r'
    return keys


def maze(seed=0):
    """Keys for Maze: a key to start, then the shortest way out, found by a
    breadth-first search of the maze the game printed from this seed."""
    from collections import deque
    r, out = play('tweet280', 'MAZE', b'k', seed=seed)
    top = out.index(b'\x1b[J') + 3
    m = out[top:top + 19 * 41]
    prev, todo = {79: None}, deque([79])
    while todo:
        a = todo.popleft()
        for step, key in ((1, b'l'), (-1, b'j'), (41, b'k'), (-41, b'i')):
            b = a + step
            if 0 <= b < len(m) and m[b] == 32 and b not in prev:
                prev[b] = (a, key)
                todo.append(b)
    keys, a = b'', 697
    while prev[a]:
        a, key = prev[a]
        keys = key + keys
    return b'k' + keys


def mines_safe(seed=0):
    """Keys for MINE390: a key to start, then every cell without a mine, read
    from the board the game laid out in memory (g, bit 16 is a mine)."""
    r = Play(open(path('longer', 'MINE390'), 'rb').read(), b'k', checked=True)
    r.w(r.seedcell, seed)
    r.run(10**8)
    g = r.r(r.let + 64 + 2 * (ord('g') - 97))
    return b'k' + ''.join(f'{y}{x}' for y in range(1, 9) for x in range(1, 9)
                          if not r.m[g + 10 * y + x] & 16).encode()


def mash(seed, keys, n):
    rnd = random.Random(seed)
    return bytes(rnd.choice(keys) for _ in range(n))


N = b'\0'
TESTS = {'b8sms': [
    # The seed starts at 0 (as in ref.py) and a key that is there at once doesn't
    # stir it; a test's optional sixth item sets another seed.
    # Hi-Lo: seed 0 picks 1, so the binary search needs all seven tries
    ('HILO', 'binary search wins', b'k64\r32\r16\r8\r4\r2\r1\r', [b'64 down', b'2 down', b'1 WIN'], 'end'),
    ('HILO', 'seven misses lose', b'k100\r50\r25\r12\r6\r3\r2\r', [b'2 down LOSE 1'], 'end'),
    # Lander: free fall, then a suicide burn (found by search over every burn)
    ('LANDER', 'suicide burn lands', b'0' * 21 + b'99998999996', [b'h1000 v0 f99 ?', b'1 LANDED'], 'end'),
    ('LANDER', 'no burn crashes', b'0' * 30, [b'CRASH'], 'end'),
    # Nim: seed 51 starts 24. Taking 3 leaves 21 (1 mod 4), and the player keeps it there
    ('NIM', 'perfect play wins', b'k3333333', [b'24 take 3 I take 1', b'I lose'], 'end', 51),
    # Seed 0 starts 21, a lost position
    ('NIM', 'start 21 loses', b'k3333333333', [b'21 take 3', b'you lose'], 'end'),
    ('REFLEX', 'early and on time', b'k' + N * 7 + b'x' + N * 5 + b'yzk' + N * 50 + b'a',
     [b'GO! 7', b'early', b'GO! 50', b'total 2060'], 'end'),
    # Ski: nobody steers, so the course drifts into the skier
    ('SKI', 'drift into a wall', N * 300, [b'SKI j l', b'|V       |\r\n12'], 'end'),
    ('SKI', 'j steers left', b'\0\0j', [b'          |   V    |\r\n           | V      |'], None),
    # Rock paper scissors: the AI learns a cycle; beating its prediction wins
    ('RPS', 'it learns 1 2 3', b'1231231231231231231231', [b'? SR -5'], 'end'),
    ('RPS', 'beat its prediction', b'33323', [b'? SP 1', b'? PR 4', b'? SP 5'], 'end'),
    ('SIMON', 'eight rounds', simon(8), [b'28531532', b'score 8'], 'end'),
    # Pig: seed 40367 rolls 2, then 1 (a pig), then 22 rolls without a 1 that reach 102
    ('PIG', 'pig, then hold at 102', b'r' * 24 + b'h', [b'1 0+2 1', b'2 0+99 3', b'2 turns'], 'end', 40367),
    ('TRON', 'turn into its own trail', N * 5 + b'.' + N * 20 + b',' + N * 3 + b',' + N * 3 + b',' + N * 5,
     [b'\x1b[9;10HO', b'\x1b[1;14HO', b'\x1b[18;1Hscore 21'], 'end'),
    # Lights Out: the 15-press solution of the all-on board, in both cases
    ('LIGHTS', 'solve it', b'abfgijmnoqrsvwy', [b'ABCDE', b'abCDE', b'uvwxy in 15'], 'end'),
    ('LIGHTS', 'upper case, stray keys', b' 0ABFGIJMNOQRSVWY0', [b'uvwxy in 18'], 'end'),
], 'tweet140': [
    # The same games cut to 140; the same keys, with the shorter messages
    ('HILO', 'binary search wins', b'k64\r32\r16\r8\r4\r2\r1\r', [b'64>', b'1= WIN'], 'end'),
    ('HILO', 'seven misses lose', b'k100\r50\r25\r12\r6\r3\r2\r', [b'2> was 1'], 'end'),
    ('LANDER', 'suicide burn lands', b'0' * 21 + b'99998999996', [b'1 LANDED'], 'end'),
    ('LANDER', 'no burn crashes', b'0' * 30, [b'CRASH'], 'end'),
    ('NIM', 'perfect play wins', b'k3333333', [b'24 take 3, I 1', b'I lose'], 'end', 51),
    ('NIM', 'start 21 loses', b'k3333333333', [b'21 take 3', b'you lose'], 'end'),
    ('REFLEX', 'early and on time', b'k' + N * 7 + b'x' + N * 5 + b'yzk' + N * 50 + b'a',
     [b'GO! 7', b'early', b'GO! 50', b'total 2060'], 'end'),
    ('SKI', 'drift into a wall', N * 300, [b'|V       |\r\n12'], 'end'),
    ('SKI', 'j steers left', b'\0\0j', [b'          |   V    |\r\n           | V      |'], None),
    ('RPS', 'it learns 1 2 3', b'1231231231231231231231', [b'? SR -5'], 'end'),
    ('RPS', 'beat its prediction', b'33323', [b'? SP 5'], 'end'),
    ('SIMON', 'eight rounds', simon(8), [b'28531532', b'score 8'], 'end'),
    ('PIG', 'pig, then hold at 102', b'r' * 24 + b'h', [b'0+2 1', b'0+99 3', b'2 turns'], 'end', 40367),
    ('TRON', 'turn into its own trail', N * 5 + b'.' + N * 20 + b',' + N * 3 + b',' + N * 3 + b',' + N * 5,
     [b'\x1b[1;2HO', b'\x1b[18;1H21'], 'end'),
    ('LIGHTS', 'solve it', b'abfgijmnoqrsvwy', [b'uvwxy 15'], 'end'),
    ('LIGHTS', 'upper case, stray keys', b' 0ABFGIJMNOQRSVWY0', [b'uvwxy 18'], 'end'),
], 'tweet280': [
    # Snake: the first food is next to the start, so it grows at once
    ('SNAKE', 'eat, grow, new food', N * 8 + b'.' + N * 4 + b',' + N * 30,
     [b'\x1b[1;2H*', b'\x1b[7;17H*', b'\x1b[1;2HO\x1b[1;1H \x1b[1;3HO\x1b[1;2H '], None),
    ('SNAKE', 'random steering, then a crash', mash(3, b'\0' * 6 + b',.', 20000), [b'\x1b[18;1Hscore 3'], 'end'),
    # Mastermind: seed 0 picks 1562
    ('MASTER', 'crack 1562', b'k1122\r3344\r1256\r2651\r1562\r',
     [b'1122 2B0W', b'3344 0B0W', b'1256 1B3W', b'2651 0B4W', b'1562 4B0W 1562'], 'end'),
    ('MASTER', 'ten misses', b'k' + b'1111\r' * 10, [b'1111 1B0W 1562'], 'end'),
    # Nim 3-5-7: the nim-sum line (found by a model of the game) beats it
    ('NIM357', 'perfect play wins', b'1121111121212121', [b'2 5 6 ?', b'you win'], 'end'),
    ('NIM357', 'it punishes a mistake', b'11' + b'31' * 10, [b'I win'], 'end'),
    ('DUEL', 'head on, the computer swerves', N * 40, [b'\x1b[7;28HX', b' LOSE'], 'end'),
    ('DUEL', 'the computer crashes', b',\0,\0\0\0\0,\0\0.\0\0\0\0\0,\0\0,\0\0\0\0\0\0\0.\0\0\0,\0\0\0\0\0\0,\0\0\0.\0\0',
     [b' WIN'], 'end'),
    # Kingdom: steady feeding lasts ten years; greedy growth is overthrown
    ('KINGDOM', 'steady ruler', kingdom(0), [b'10: pop 99', b' 99'], 'end'),
    ('KINGDOM', 'greedy ruler', kingdom(0.5), [b'Overthrown'], 'end'),
    ('KINGDOM', 'starve them', b'500\r', [b'Overthrown 99'], 'end'),
    # Tic-tac-toe: it opens in the centre; --all checks every line
    ('TICTAC', 'it wins a sloppy game', b'1739', [b'\r\n.O.', b'OOO', b' I win'], 'end'),
    ('TICTAC', 'it blocks a fork', b'2938', [b' I win'], 'end'),
    # Blackjack, seed 0: an ace as 11, a push, a bust, and a soft hand that turns hard
    ('BLACKJCK', 'thirteen hands', b'k' + b'hs' * 8,
     [b'$80 You AJ 21 Me 9K 19\r\n$90', b'$110 You J3 13 h?6 19 h? Me 3J6 19\r\n$110',
      b'$110 You 6K 16 h?J 26 Me 8A 19\r\n$100', b'$120 You A3 14 h?9 13 h?'], None),
    ('COPTER', 'flap and crash', b'\0\0\0k' * 30, [b'COPTER', b'score 9'], 'end'),
    ('BREAKOUT', 'one brick, then the ball is lost', N * 200, [b'\x1b[4;31H#', b'\x1b[21;'], 'end'),
    # Hangman: seed 0 picks BINARY
    ('HANGMAN', 'guess it', b'kbinary', [b'B_____ 0 ?', b'BINARY won'], 'end'),
    ('HANGMAN', 'six misses', b'kzqxjvw', [b'______ 5 ?', b'BINARY lost'], 'end'),
    # Maze: walls hold, and the shortest way out (54 steps in every binary-tree maze) gets out,
    # from seed 0 and from seed 5 (a sixth element in a test is the seed it starts from)
    ('MAZE', 'walls hold', b'kiiii', [b'#######################################\r\n#', b'\x1b[2;39H@'], None),
    ('MAZE', 'walk out', maze(), [b'\x1b[21;1HOut!'], 'end'),
    ('MAZE', 'another maze', maze(5), [b'\x1b[21;1HOut!'], 'end', 5),
], 'longer': [
    # Minesweeper with flood fill. Seed 0 has 8 mines, one at row 1, column 1
    ('MINE390', 'a blank cell floods open', b'k61', [b'0013####\r\n00011###\r\n00001###'], None),
    ('MINE390', 'a mine', b'k11', [b'######## BOOM'], 'end'),
    ('MINE390', 'every safe cell wins', mines_safe(), [b'00001#10\r\n00001110 WIN'], 'end'),
]}


def tictac_all():
    """Every legal line for the human against Tic-tac-toe: it must never lose."""
    src = open(path('tweet280', 'TICTAC'), 'rb').read()
    ends, bad = {}, []

    def dfs(keys):
        r = Play(src, keys, checked=True)
        out = r.run(900_000_000)
        if r.error or not r.waiting and not (out.endswith(b' I win') or out.endswith(b' draw')):
            bad.append(keys)
        elif not r.waiting:
            end = out[-5:]
            ends[end] = ends.get(end, 0) + 1
        else:
            board = b''.join(out.split(b'\r\n')[-3:])
            for i, c in enumerate(board):
                if c == ord('.'):
                    dfs(keys + bytes([49 + i]))
    dfs(b'')
    print(f'{"PASS" if not bad else "FAIL"}  TICTAC   every line: {ends}')
    for k in bad[:5]:
        print('      lost or broke on', k)
    return len(bad) > 0


if __name__ == '__main__':
    args = sys.argv[1:]
    full = '--all' in args
    want = [a.upper() for a in args if a != '--all']
    bad = 0
    for folder, limit in LIMITS.items():
        print(f'-- games/{folder}, {limit} characters')
        for f in sorted(os.listdir(os.path.join(GAMES, folder))):
            name = f[:-4]
            if not f.endswith('.B8S') or (want and name not in want):
                continue
            n = len(open(path(folder, name), 'rb').read())
            ok = n <= limit
            bad += not ok
            print(f'{"PASS" if ok else "FAIL"}  {name:8} {n} characters')
        for game, what, keys, texts, end, *seed in TESTS[folder]:
            if want and game not in want:
                continue
            r, out = play(folder, game, keys, seed=seed[0] if seed else 0)
            miss = [t for t in texts if t not in out]
            ended = not r.waiting and not r.ds
            ok = not miss and r.error is None and (ended or end != 'end')
            bad += not ok
            print(f'{"PASS" if ok else "FAIL"}  {game:8} {what}')
            if r.error:
                print('      error report:', out[out.rfind(b'Err'):].decode('latin-1'))
            for t in miss:
                print('      missing:', t)
            if end == 'end' and not ended:
                print('      did not end cleanly:', 'waiting for a key' if r.waiting else f'stack {r.ds}')
    if full and (not want or 'TICTAC' in want):
        bad += tictac_all()
    print('tiny games:', 'all pass' if not bad else f'{bad} FAILED')
    sys.exit(1 if bad else 0)
