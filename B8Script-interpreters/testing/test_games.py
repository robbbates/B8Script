"""Scripted play tests for the games in games/ (at the root of the repository), run on the reference interpreter.

usage: test_games.py [NAME...]      (run by hand, like the other test scripts)

Every test runs on both versions of the game, the stripped NAME.B8S and the
commented NAME.TXT (where there is one), and the two must print exactly the same.
A NAME.TXT in DOCS_ONLY is documentation only and need not run (it may not fit in
memory), so only its NAME.B8S is run. For every game the NAME.B8S must be the
NAME.TXT stripped (b8strip.py --same), which is checked first.

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
GAMES = os.path.normpath(os.path.join(here, '..', '..', 'games'))   # games/ at the root of the repository
sys.path.insert(0, here)
from ref import Ref, NeedKey
from b8strip import strip

DOCS_ONLY = {'IDOL.TXT'}


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


# Minesweeper, seed 1, first cell (7,7): visit every cell row by row from the
# top left and open each one that has no mine, as laid out by that seed
MINES_ROWS = [
    '...*.....*.*..*.', '........*.*..*.*', '.*..............', '..**.......*....',
    '............*.*.', '.*.....**....*..', '........*....*..', '....*...........',
    '......*.....*...', '................', '.............**.', '*............*..',
    '.....*..*...**.*', '.....*....**....', '*...*...........', '..*...*..*......']


def sweep():
    keys, x = b'x ' + b'w' * 7 + b'a' * 7, 0
    for y, row in enumerate(MINES_ROWS):
        if y:
            keys += b's'
        for xx in (range(16) if y % 2 == 0 else range(15, -1, -1)):
            keys += b'd' * (xx - x) + b'a' * (x - xx)
            x = xx
            keys += b' ' if row[xx] == '.' else b''
    return keys


TESTS += [
    ('MINES', 'clear the field', sweep() + b'n', [b'You cleared the field!', b'Bye.']),
    ('MINES', 'flags, then a mine', b'x ' + b'w' * 7 + b'a' * 4 + b'f af' + b'd' * 6 + b'ffd n',
     [b'Mines 39', b'Mines 38', b'Mines 37', b'BOOM! You hit a mine.', b"\x1b[4;11H'", b'\x1b[4;9HX', b'Bye.']),
]


# Breakout, seed 1: a whole wall cleared, as played by a small bot that read the
# ball and the paddle every frame. A number is that many frames with no key (NULs)
BREAKOUT_WIN = (
    'x 54aaaaa83ddd85dddd84aaaa84aa86dddddddd80aa94aaaa92ddddd91aaaaa83ddddd9'
    '1d95aaaaaaa177ddddd91aaaa100a87dddddd98a103aaaaa99dddddddd96aaaaaaaa96dd'
    'dddd215aaa75aaaa176a95dddddddd282aaaaaaa67ddd49dddddd46aaaaaaaaaa106dddd'
    'dddd80aaaaa95dddd40ddd81aaaaaaaaaa46ddddd219aaaaa51ddddd69aaaa70dddddd68'
    'a83aaa71dd72ddd47'
)


def frames(s):
    return b''.join(b'\0' * int(n) if n else k.encode() for n, k in re.findall(r'(\d+)|([^\d.])', s))


TESTS += [
    ('BREAKOUT', 'clear the wall', frames(BREAKOUT_WIN) + b'\0n',
     [b'Score 252', b'Balls 3', b'You cleared the wall!  Score 252. Play again?', b'Bye.']),
    ('BREAKOUT', 'out of balls', b'x' + (b' ' + b'\0' * 150) * 3 + b'\0n',
     [b'Balls 2', b'Balls 1', b'Balls 0', b'Out of balls.  Score ', b'Bye.']),
]


# Qubic, seed 1: two games against a simple player that takes a win, blocks a
# line of three, and otherwise plays where it has most of its own lines
QUBIC_LOST = '411 322 222 332 133 333 113 142'
QUBIC_WON = '322 333 231 232 211 121 341 221 222 332 223 342 142 122 124 123'


def typed(moves):
    return b''.join(m.encode() + b'\r' for m in moves.split())


TESTS += [
    ('QUBIC', 'it wins', b'y' + typed(QUBIC_LOST) + b'n', [b'I play ', b'I win!', b'Bye.']),
    ('QUBIC', 'you win', b'n' + typed(QUBIC_WON) + b'n', [b'I play ', b'You win!', b'Bye.']),
    ('QUBIC', 'bad moves', b'y1 2 3\r12\r9 9 9\r123\r1x1x1\rqn',
     [b'Type three digits, each 1 to 4', b'That cell is taken.', b'I play ']),
]


# Klondike, seed 1, draw one: a win found by a search on a model of the deal
# in Python (the same shuffle). Each move is d, or a source and a destination
KLONDIKE_WIN = (
    '4f4257dwf7fdddw6dw121dw6ddddwfdwfdwfddw6ddwf6fddw25225d52dw325d52d25d52d'
    '25d52dw65626d62dw326d62dw526dw5155135313f146241d142641d146241d142641dw11'
    '46241d142641d146241d142641d146241d142641d146241d142641dw1717f67757673145'
    '2415314233635415362143541676f76w7w5w3636f2f1f2f1f3f3f1416173546536735711'
    '4164653dw7674635711617537161dw7676f4f7f171f353f537135dwf2f1f1f5f1f5f1f5f'
    '1f1f3f1f5f535f1f353f3f717fdwf1f1f5f1f5f1f5f1f5f'
)

TESTS += [
    ('KLONDIKE', 'all 52 home', b'1' + KLONDIKE_WIN.encode() + b'n',
     [b'KS Kh Kd KC', b'All 52 are home. You win!', b'Bye.']),
    ('KLONDIKE', 'bad moves', b'x173w3wf1f1xqn',
     [b'KLONDIKE   draw 1', b"That doesn't go there.", b'The waste is empty.', b'Bye.']),
    ('KLONDIKE', 'draw three, turn the waste over', b'3' + b'd' * 9 + b'qn',
     [b'3S 2C Ah', b'\x1b[3;3H  \x1b[3;6H0 ', b'Bye.']),
]


# Lights Out, seed 1: three levels solved (by chasing the lights down from the
# top row, with the best of the 32 first rows), then q. And a new puzzle, then q
LIGHTS_WIN = b'xaaww sss dddd yaaww d dd aas ass ydww d aaaas dddd aas ds ds '

TESTS += [
    ('LIGHTS', 'three levels', LIGHTS_WIN + b'n',
     [b'Made with 3 presses.', b'Level 2', b'Made with 7 presses.', b'All out in 7 moves! Next level?', b'Bye.']),
    ('LIGHTS', 'a new puzzle, then quit', b'x  n q',
     [b'Level 1    Moves 2', b'Level 1    Moves 0', b'Bye.']),
]


# Fifteen, seed 1: the 8-puzzle solved by a breadth-first search, and the
# 15-puzzle by a weighted A* search (not the fewest moves), on a model of the
# board read from the game. Then giving up
TESTS += [
    ('FIFTEEN', 'the 8-puzzle', b'x3ddwaawddsasawdsdwawan',
     [b'Moves 20', b'Solved in 20 moves! Play again?', b'Bye.']),
    ('FIFTEEN', 'the 15-puzzle', b'xywawwassawdsdsdwaasdwaasdwddwawdssawwdsssawwawasddwaassdddwwassawdwaasdsawwn',
     [b'Moves 74', b'Solved in 74 moves! Play again?', b'Bye.']),
    ('FIFTEEN', 'three slides down, the rest blocked, give up', b'xywwwwwwddddddqn',
     [b'Moves 3', b'Play again?', b'Bye.']),
]


# Greed, seed 1: a whole game, as played by a bot on a model of the field read
# from the game, taking the move that leaves it most moves next. You start in
# the left column, where only d x c are open
TESTS += [
    ('GREED', 'no moves left', b'xdzxedzxeeddcxecdqqdzcwcwqwaaaazcaqdcczaeexqqxn',
     [b'Score 256  18.2%', b'No moves left. Play again?', b'Bye.']),
    ('GREED', 'the moves shown, a blocked one, quit', b'xhwQn',
     [b'You can go: d x c ', b"You can't go that way.", b'Score 0  0.0%', b'Play again?', b'Bye.']),
]


# Reversi, seed 1: games against a small minimax player in Python, reading the
# board from the game (three moves deep wins as X and as O; two deep loses)
TESTS += [
    ('REVERSI', 'you win as X', b'xyd3b6c2d1f5f3a5b1h3c7a3e1g6f1e2a4h5h7f6f8a7c4d7h1d8b8b2h2b7g7n',
     [b'You are X, I am O.', b'I play ', b'You win 37 to 27.', b'Bye.']),
    ('REVERSI', 'you win as O', b'xnd6d3b3d8a5a3e1c1f4f8e2c2a1b5a7c5c8e3a8g4f1h3h5h1e6g5f6h7h8g2n',
     [b'You are O, I am X.', b'You win 48 to 16.', b'Bye.']),
    ('REVERSI', 'it wins', b'xyd3b6c2d1d6g3b1g6h6h4a5e1c4c3a3a4g1d8h3h1a7c6e6f8f7f6b8b7g7h7n',
     [b'I win 42 to 22.', b'Bye.']),
    ('REVERSI', 'marks, a bad cell, the cursor, resign', b'xymd4a1 d3qn',
     [b'\x1b[6;11H+', b"You can't play there.", b'I play ', b'X 4   O 1', b'You resign.', b'Bye.']),
]


# Battleship, seed 1: firing only at my ships (read from the game), and only
# at water, which lets it find and sink the whole fleet. And placing, firing
# twice at a cell, and giving up
BATTLE_MISS = (b'a0b0c0d0e0f0g0h0i0j0a1b1c1d1e1f1g1h1i1j1a2b2c2f2g2h2i2j2a3b3c3d3e3f3g3h3i3j3'
               b'a4g4h4i4j4a5b5c5d5e5g5h5i5a6b6c6e6g6h6i6a7b7c7e7g7h7i7a8b8c8e8g8h8i8j8a9b9c9d9e9f9g9h9i9j9')

TESTS += [
    ('BATTLE', 'you win', b'x     d2e2b4c4d4e4f4f5j5d6f6j6d7f7j7d8f8n',
     [b'You fire at D2: a hit.', b'You sank my destroyer!', b'I sank your battleship!',
      b'You sank my whole fleet. You win!', b'Bye.']),
    ('BATTLE', 'it wins', b'xr' + BATTLE_MISS + b'n',
     [b'You fire at A0: a miss.', b'I sank your carrier!', b'I sank your destroyer!',
      b'I sank your whole fleet. I win!', b'Bye.']),
    ('BATTLE', 'placing, a cell twice, give up', b'x ww ss ra0a0qn',
     [b'Place your battleship (4 cells).', b"Ships can't overlap.", b'You fire at A0: a miss.',
      b'You already fired at A0.', b'You give up.', b'Bye.']),
]


# Idol, seed 1 (n at once on the title starts a new game): home is Xeva (Industry, policed). The chart chooses the nearest
# system in range; s steps to the next farther, Return jumps. Xeva makes
# machinery (cheap) and Talo, the eighth system out, is agricultural and wants it
TESTS += [
    ('IDOL', 'fly: step, jump, refuel', b'nss\rf',
     [b'Docked at Xeva.', b'Docked at Kaxe.', b'Day 2', b'Fuel 4/7', b'Debt 5050',
      b'Refuelled 3 units for 60.', b'Cr 940']),
    ('IDOL', 'a profitable trade', b'nmsssb\rcsssssss\rmsssx\r',
     [b'Buy Machinery: how many (Return for 20)? ', b'Bought 20 t of Machinery for 980.',
      b'Docked at Talo.', b'Sold 20 t of Machinery for 1400.', b'Cr 1420']),
    ('IDOL', 'an upgrade, then too little money', b'nysbsbr',
     [b'Shield\x1b[5;17H0 of 2\x1b[5;46H  1000', b'Bought: Shield.',
      b'Courier L1 S1 M0', b'Cr 0\x1b', b"You can't pay for that.", b'The hull needs no repair.']),
    ('IDOL', 'ships at a high-tech system, at the trade-in price', b'nsss\rysssssssb',
     [b'Docked at Orelma.', b'Freighter\x1b[12;17H50 t, tank 8, hull 50\x1b[12;46H  6500',
      b'Clipper\x1b[14;17H70 t, tank 10, hull 80\x1b[14;46H 27500', b'You fly one already.']),
    # two missiles bought at home win against the level 0 pirate at Bequon
    ('IDOL', 'a duel won with missiles', b'nyssbbc' + b's' * 11 + b'\rmm',
     [b'Bought: Missile.', b'Duel: pirate ship, level 0', b'Your missile hits for 15.',
      b'You win. A bounty of 250.', b'You salvage 3 t of Ore.', b'Docked at Bequon.']),
    ('IDOL', 'a duel lost: game over', b'n' + b's' * 16 + b'\rc' + b'l' * 30 + b'x',
     [b'Duel: pirate ship, level 1', b'You close in.', b'The pirate hits you for ',
      b'Your ship is destroyed, and you with it. Game over.', b'Press a key.', b'Bye.']),
    # the police scan you on the way back home on day 3
    ('IDOL', 'a police scan: submit', b'nmssssssb5\rc\r\rs',
     [b'Bought 5 t of Narcotics for 730.', b'The police find 5 t of contraband. s submits, r resists.',
      b'They take it and fine you 600.', b'Docked at Xeva.', b'Cr 0\x1b', b'Debt 5430']),
    ('IDOL', 'a police scan: resist', b'nmssssssb5\rc\r\rrf',
     [b'You resist the police!', b'Duel: police ship, level 3', b'Wanted 20']),
    ('IDOL', 'pay the loan', b'nl500\rl\rl',
     [b'Pay how much (Return for 1000)? ', b'You pay 500 off the loan.', b'Debt 4500',
      b'Debt 4000', b'You have no cash.']),
    # the Heart of the idol lies at Usis, the 14th system out
    ('IDOL', 'an idol part found, its price, then known', b'n' + b's' * 13 + b'\rtct\rt',
     [b'Docked at Usis.', b"The Idol's Heart is here: 18 t of Medicine and 19 t of Textiles (t trades).",
      b"The Idol's Heart wants 18 t of Medicine and 19 t of Textiles.",
      b"The Idol's Heart lies at Usis: 18 t of Medicine and 19 t of Textiles."]),
    # offers and rumours on docking; the second offer at Kaxe goes to Qucelo, by way of Rasoar
    ('IDOL', 'offers and a rumour', b'n\rk\r',
     [b'Docked at Xeva.', b"Rumour: the Idol's RHand lies at Damige.", b'Docked at Orbuso.',
      b"Rumour: the Idol's LHand lies at Suelne.", b'Offer 1: 9 t of Food to Tixeta, by day 7, pay 880.',
      b'Take which? ']),
    ('IDOL', 'a contract delivered', b'nss\rk2fcsssssssssssss\rfcssssssssssssssssssssssssssss\r',
     [b'Offer 2: 5 t of Ore to Qucelo, by day 9, pay 900.', b'Contract taken.', b'5 t Ore',
      b'to Qucelo by day 9', b'Docked at Qucelo.', b'You deliver: 900.', b'Cr 840']),
    ('IDOL', 'sealed cargo sold', b'nss\rk2mssssssssx',
     [b'Sealed Ore', b'You sell the sealed cargo for 180. You are wanted, and owe more.',
      b'Debt 5200', b'Wanted 20']),
    # a save code made, loaded back, and played on: the state cells and the stock
    # here are checked by idol_save() below; here the messages
    ('IDOL', 'a save code', b'nmsssb\rcss\rv',
     [b'Save code: cMIVd2vD-BP5q_XvytvjNOXj4es2fvBMuX4lS-LB8ucy1M6M']),
    ('IDOL', 'a mistyped save code refused, then the right one', b'lcMIVd2vD-BP5q_XvytvjNOXj4es2fvBMuX4lS-LB8ucy1N6M\rlcMIVd2vD-BP5q_XvytvjNOXj4es2fvBMuX4lS-LB8ucy1M6M\r',
     [b'That code is not right.', b'Docked at Kaxe.', b'Cr 20\x1b', b'Debt 5050', b'Fuel 4/7', b'Cargo 20/20']),
]


# Idol's save code must load back to exactly the state it was made from, and the
# game must play on the same: (keys that end with v, keys to play on). The state
# cells 0 to 33 and the stock where you are are compared, after loading and
# again after playing on.
IDOL_SAVES = [
    (b'nmsssb\rcss\rv', b'mb\rcs\r'),
    (b'nss\rk2mssssssssbcs\rv', b'\rf\r'),
    (b'n' + b's' * 13 + b'\rtv', b'sss\rf'),
]


# Idol's save code, made in Python from the format in IDOL.TXT (the notes before
# routine 70), so that a test can start from a state set up for it: the cells 0
# to 33 at their widths, the stock where you are, a salt, the XOR, the check
IDOL_WIDTHS = [16, 10, 10, 14, 15, 6] + [7] * 8 + [2, 3, 3, 3, 2, 2, 7, 4, 1, 1, 5, 6, 6, 2, 6, 3, 7, 10, 15, 1]
IDOL_ALPHA = b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'


def idol_code(cells, stock, salt=5):
    bits = '0001' + ''.join(format(v & (1 << w) - 1, f'0{w}b') for v, w in zip(cells, IDOL_WIDTHS))
    bits += ''.join(format(v, '07b') for v in stock)
    vals = [salt] + [int(bits[i:i + 6], 2) for i in range(0, len(bits), 6)]
    r = (salt * 97 + 12345) & 0xFFFF
    for i in range(1, len(vals)):
        r = (r * 25173 + 13849) & 0xFFFF            # R, as in the program
        q = int((r - 65536 if r > 32767 else r) / 256)
        vals[i] ^= (q & 255) % 64
    c = 0
    for v in vals:
        c = (c * 3 + v) & 63
    return bytes(IDOL_ALPHA[v] for v in vals + [c])


def idol_cells(**kw):
    """the state of a new game on seed 1 (day 1, home, a new Courier), changed by kw"""
    names = ('seed day cashhi cashlo debt pos c0 c1 c2 c3 c4 c5 c6 c7 cls laser shield missiles pods '
             'tankup hull fuel escape hidden wanted held known ckind cdest cgood ctonnes cdead cpay cpass').split()
    cells = dict.fromkeys(names, 0)
    cells.update(seed=1, day=1, cashlo=1000, debt=5000, laser=1, hull=30, fuel=7)
    cells.update(kw)
    return [cells[n] for n in names]


# seed 1: the Base of the idol (part 5) lies at system 43 and wants 26 t of
# Medicine and 13 t of Machinery
IDOL_BASE = dict(pos=43, c4=26, c3=13, pods=2, cashlo=3000, day=50)
TESTS += [
    ('IDOL', 'an idol part traded', b'l' + idol_code(idol_cells(**IDOL_BASE), [60] * 8) + b'\rt',
     [b"The Idol's Base is here: 26 t of Medicine and 13 t of Machinery (t trades).",
      b"You trade for the Idol's Base: 1 of 6.", b'Idol 1/6', b'Cargo 0/40']),
    ('IDOL', 'the win', b'l' + idol_code(idol_cells(held=31, debt=0, **IDOL_BASE), [60] * 8) + b'\rt\r',
     [b"You trade for the Idol's Base: 6 of 6.", b' is whole and the loan is paid. You win in 50 days!',
      b'Press a key.', b'Bye.']),
    ('IDOL', 'the end at day 999', b'l' + idol_code(idol_cells(day=998, held=5), [60] * 8) + b'\r\r\r',
     [b'Day 999', b'Day 999: the end. You held 2 of the six parts of the Idol of ', b'Bye.']),
    # a hull of 2 loses the first duel out (the 16th system): with an escape pod,
    # and without one
    ('IDOL', 'a duel lost with an escape pod', b'l' + idol_code(idol_cells(hull=2, escape=1, c0=10), [60] * 8)
     + b'\r' + b's' * 16 + b'\rcl',
     [b'Duel: pirate ship', b'Your ship is lost. The escape pod takes you home to a new Courier.',
      b'Docked at Xeva.', b'Debt 10050', b'Cargo 0/20']),
]


def idol_state(r):
    """The saved part of Idol's state, read from the reference machine."""
    cell = lambda c: r.r(r.let + 2 * (ord(c) - 0x41))
    g, h = cell('g'), cell('h')
    pos = r.r(g + 10)
    return [r.r(g + 2 * n) for n in range(34)] + list(r.m[h + 192 + 8 * pos:h + 200 + 8 * pos])


def idol_saves(path):
    bad = 0
    for keys, more in IDOL_SAVES:
        r, out = play(path, keys)
        code = re.findall(rb'Save code: ([A-Za-z0-9_-]{48})', out)[-1]
        for tail in (b'', more):
            a, _ = play(path, keys + tail)
            b, _ = play(path, b'l' + code + b'\r' + tail)
            ok = idol_state(a) == idol_state(b) and a.error is None and b.error is None
            bad += not ok
            print(f'{"PASS" if ok else "FAIL"}  IDOL      save code {code.decode()} loads back'
                  + (' and plays on the same' if tail else ''))
    return bad


def play(path, keys, steps=20_000_000):
    r = Play(open(path, 'rb').read(), keys, checked=True)
    out = r.run(steps)
    return r, out


if __name__ == '__main__':
    want = [a.upper() for a in sys.argv[1:]]
    bad = 0
    # the stripped NAME.B8S of every game must hold the same code as its NAME.TXT
    for txt in sorted(os.listdir(GAMES)):
        name, ext = os.path.splitext(txt)
        if ext != '.TXT' or (want and name not in want):
            continue
        a, b = (strip(open(os.path.join(GAMES, name + e), 'rb').read()) for e in ('.TXT', '.B8S'))
        ok = a == b
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  {name:9} {name}.B8S is {name}.TXT stripped')
    for game, what, keys, texts in TESTS:
        if want and game not in want:
            continue
        # both versions: the stripped NAME.B8S and the commented NAME.TXT. They
        # hold the same code, so they must print exactly the same
        paths = [os.path.join(GAMES, game + ext) for ext in ('.B8S', '.TXT')
                 if game + ext not in DOCS_ONLY]
        runs = [play(p, keys) for p in paths if os.path.exists(p)]
        (r, out), (r2, out2) = runs[0], runs[-1]
        miss = [t for t in texts if t not in out]
        ok = not miss and r.error is None and r2.error is None and out == out2
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  {game:9} {what}')
        for x, o, ext in ((r, out, 'B8S'), (r2, out2, 'TXT')):
            if x.error:
                print(f'      {ext} error report:', o[o.rfind(b'Err'):].decode('latin-1'))
        if out != out2:
            d = next((i for i in range(min(len(out), len(out2))) if out[i] != out2[i]), min(len(out), len(out2)))
            print(f'      B8S and TXT differ at byte {d}: {out[d-20:d+20]!r} {out2[d-20:d+20]!r}')
        for t in miss:
            print('      missing:', t.decode('latin-1'))
    if not want or 'IDOL' in want:
        bad += idol_saves(os.path.join(GAMES, 'IDOL.B8S'))
    print('games:', 'all pass' if not bad else f'{bad} FAILED')
    sys.exit(1 if bad else 0)
