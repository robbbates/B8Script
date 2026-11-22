"""Scripted play tests for the games in games/, run on the reference interpreter.

usage: test_games.py [NAME...]      (run by hand, like the other test scripts)

Each test types a fixed key sequence at a game and checks that what it prints
holds the messages expected: a win, a loss or some other known message. The
games seed their random numbers from how long a key took to come. In ref.py a
key is there at once, so every run is the same; a NUL in the keys is a key
that hasn't come yet (n? returns 0): it stirs the seed by one, and in a
real-time game it is a frame with no key. The run ends when the keys do.

Each test runs on a checked reference build, so a stack or bracket mistake
stops it with a report, and must end without one.
"""
import sys, os, re
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from ref import Ref, NeedKey


class Play(Ref):
    """ref.py, but a ? with no keys left ends the run (in ref.py a timed ?
    returns 0 for ever, so a game waiting in a loop of 1? would never end)."""
    def step(self):
        if self.m[self.ip] == ord('?') and not self.inp:
            raise NeedKey
        super().step()


TESTS = []     # (game, what it shows, keys, texts that must all be printed)


# Hunt the Wumpus. Seed 1: you in room 1, the Wumpus in 4, pits in 5 and 14,
# bats in 6 and 16
TESTS += [
    ('WUMPUS', 'shoot it from room 3', b'nm2\rm3\rs1\r4\rq',
     [b'I smell a Wumpus!', b'Aha! You got the Wumpus!', b"Hee hee hee - the Wumpus'll getcha next time!!", b'Bye.']),
    ('WUMPUS', 'a pit', b'nm5\rq', [b'I feel a draft!', b'fell in a pit!', b'Ha ha ha - you lose!']),
    ('WUMPUS', 'walk into it, it moves off', b'nm2\rm3\rm4\rq', [b'Bumped a Wumpus!', b'You are in room 4']),
    ('WUMPUS', 'bats, crooked arrows', b'nm8\rm7\rm6\rs3\r2\r3\r2\r',
     [b'Bats nearby!', b'Super bat snatch!', b"Arrows aren't that crooked"]),
    ('WUMPUS', 'five misses', b'n' + b's1\r8\r' * 5 + b'q',
     [b'Missed.', b'You have no arrows left.', b'you lose!']),
    ('WUMPUS', 'not a tunnel', b'nm7\r', [b'Not possible - ']),
    # Seed 9: you in room 3, the Wumpus in 1
    ('WUMPUS', 'walk into it, eaten', b'\0' * 8 + b'nm2\rm1\rq', [b'Bumped a Wumpus!', b'the Wumpus got you!']),
]


# Robots, seed 1. Waiting and teleporting clears the first wave; standing still
# is fatal
TESTS += [
    ('ROBOTS', 'wave 2', b'x' + b' t' * 40 + b'Qn', [b'Wave   2', b'Robots 20', b'Bye.']),
    ('ROBOTS', 'caught', b'x' + b's' * 13 + b'n', [b'Score  20', b'AARRrrgghhhh....  Score 20, wave 1.', b'Bye.']),
]


# 2048: a winning game on seed 6, found by a model of the game in Python that
# draws the same random numbers, playing one move ahead
WIN2048 = (
    b'aswwdaaaswadwwdsddwwdaawaadasawdwddsdawadawwwawwdwdawawdawwwawdwwdawawaa'
    b'wawwaawdawawdwaadwawawddawadwawwwwdwdawawddwdawwwdadwddddwadwddwaawdwwdw'
    b'wawddwawwawddwawdwwdawdwddwwawdwadadwwawdwwawddwwadwadwaawaawawaaaaadwad'
    b'asawsawdwddwdwadawdwadwddadaawaaaddawssawdwdaawaaadadwaawwdwdwwdawdawaws'
    b'aswaasaawwadwddwawawawawddwdwdwawdwwawwdadwadwdwawwwdwdwaaddwdwdwwdwasaw'
    b'awadwwaaasawdwawawadwadwwwawdwdwdddddddwddwdwawdwdwdawwdwwawdwawwadwwaww'
    b'awwwawdwddwaawdawdwaawdawdwawdwwaaadwawwdwaawwwdwawwwadwadwdwddwaawdawwd'
    b'wwaawawawadawwdwdwawdaaddasdwadwwasdswawsawswawwawwwdwswawsawawdwsaadwds'
    b'dwadwaawasaawdwawddwdwdwdawdwawdwddawwawsawdawwdwadwwwawdwdawdadsawawswa'
    b'wdwdwwawdwwawwadwawwwwdaawdwwwaawdadwawwwdwddddddawdwawwawawdaawdwawawaw'
    b'dwdwwwawawwwdwdaadwawwwaawaddawwawdwdwddawwaadawawaawadwdawadwwdawdwdddd'
    b'dwaddwawdwadwwdwddwawdwdawwaawwddddwaaawwdwawwddwwwawawdwwdwdwdwwawwwaww'
    b'awdwadwdwdwwawwwawdwadwadawwawdwwawadwawwaawadaaaddwdwdawdwddawadwddwwdw'
    b'dwawadadwawdwaawawawwdwddwawdwaawa'
)

TESTS += [
    # Seed 1 starts with 2s in the top left and bottom right cells. Each key must
    # move them its own way (upper case too); the cell rubbed out shows which way
    ('G2048', 'W slides up', b'xW', [b'\x1b[6;28H   2   ', b'\x1b[18;28H       ']),
    ('G2048', 's slides down', b'xs', [b'\x1b[18;4H   2   ', b'\x1b[6;4H       ']),
    ('G2048', 'a slides left', b'xa', [b'\x1b[18;4H   2   ', b'\x1b[18;28H       ']),
    ('G2048', 'd slides right', b'xd', [b'\x1b[6;28H   2   ', b'\x1b[6;4H       ']),
    ('G2048', 'no more moves', b'x' + b'sadw' * 25 + b'n', [b'No more moves. Score 732. Play again?', b'Bye.']),
    ('G2048', 'make 2048', b'\0' * 5 + b'x' + WIN2048 + b'qn',
     [b'You made 2048! Keep going', b' 2048 ', b'Score 20468. Play again?', b'Bye.']),
]


def play(game, keys, steps=20_000_000):
    prog = open(os.path.join(here, 'games', game + '.B8S'), 'rb').read()
    r = Play(prog, keys, checked=True)
    out = r.run(steps)
    return r, out


if __name__ == '__main__':
    want = [a.upper() for a in sys.argv[1:]]
    bad = 0
    for game, what, keys, texts in TESTS:
        if want and game not in want:
            continue
        r, out = play(game, keys)
        miss = [t for t in texts if t not in out]
        ok = not miss and r.error is None
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  {game:9} {what}')
        if r.error:
            print('      error report:', out[out.rfind(b'Err'):].decode('latin-1'))
        for t in miss:
            print('      missing:', t.decode('latin-1'))
    print('games:', 'all pass' if not bad else f'{bad} FAILED')
    sys.exit(1 if bad else 0)
