"""Scripted play tests for the games in games/ (at the root of the repository), run on the reference interpreter.

usage: test_games.py [NAME...]      (run by hand, like the other test scripts)

Every test runs on both versions of the game, the stripped NAME.B8S and the
commented NAME.TXT (where there is one), and the two must print exactly the same.
A NAME.TXT in DOCS_ONLY is documentation only and need not run (it may not fit in
memory), so only its NAME.B8S is run. For every game the NAME.B8S must be the
NAME.TXT stripped (b8strip.py --same), which is checked first.

Each test types a fixed key sequence at a game and checks that what it prints
holds the messages expected: a win, a loss or some other known message. The
games draw their random numbers with `, whose seed the interpreter stirs
while a program waits for a key. In ref.py the seed starts at 0 and a key is
there at once, which stirs nothing, so every run is the same. A NUL in the
keys is a timed wait that runs out (n? returns 0): it stirs the seed by the
wait's count, and in a real-time game it is a frame with no key. (0? takes a
NUL as key 0.) The run ends when the keys do.

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


# 2048: a winning game on seed 0 (the seed ref.py starts with), found by a beam
# search on a model of the game in Python that draws the same random numbers
WIN2048 = (
    b'adsdasasassasaaasawsassasadwddwwwaaaassawawwwwawaasasssaawwasaawssssssaa'
    b'sasasassdassdsdsdsdwawwwdwwawwdwwwwwwddddwdwdwadwdssaawasaawwaasadwdwdws'
    b'dwdwsdwddddwsddwddwddwwwwwwsdsddssdwdwdwdsdsdwswdddsdsdswdwsdsswdwddsddw'
    b'wsdsdsswdddwwwwwdsdsdwswdddaasdsasddsddawwwdwwwwwawdwdwaaawddwwawwwwdawa'
    b'aawwwaaawwwwddwaawdawawdddwwddddwwddwawaawwdwwaawwawdwdwawdwwadawawdwwdw'
    b'wddwwwwwawwdawwwwaawaawwdwadwwasasssaadasaassadasasddssassssasassassaass'
    b'sasadassdddsasssssdsdsdddasaadassssaasdadsdwdsswdwddwdsdwdswsssddwddssdd'
    b'dwdwdwdssddwddwdsswwwdwddssddddddwddsdsdwwwdddssssddsdsdsddswdwwdddwsssd'
    b'ddddsdswwdssdddddwdswsdwdsddswwwdddwwswdsdwdddwdswwwdwdssswdwddwswdwwdsd'
    b'dwwwddsdswdwddwwdddwssdwwdwswddwddwwddswdwwwwwdwddswdddwddssdwsdddddssdw'
    b'aasaasswawwaasaaaswswwasasaawwawwaaaaswaawaawwwwwaaasawsasaaswwaawawwssa'
    b'aaaawasswawawwaswaawssawwasaswswaawwwaaawswwaaasasswasaaswasassawwasssaw'
    b'awawawswawwwwawwsswwawwwwwaawaaaasssaawssssasaawasawasaawssaawaswaasswas'
    b'ww'
)

TESTS += [
    # Seed 0 starts with two 2s side by side in the top row, so s is played first:
    # then there is a 2 at the left of the third row and two at the middle of the
    # bottom row. Each key must move them its own way (upper case too); the cells
    # drawn and rubbed out show which way
    ('G2048', 'W slides up', b'xsW', [b'\x1b[6;4H   2   \x1b[6;12H   2   \x1b[6;20H   2   ',
                                       b'\x1b[14;4H       \x1b[18;12H       \x1b[18;20H       \x1b[22;3H']),
    ('G2048', 's slides down', b'xss', [b'\x1b[18;4H   2   ', b'\x1b[14;4H       \x1b[18;4H']),
    ('G2048', 'a slides left', b'xsa', [b'\x1b[18;4H   4   ', b'\x1b[18;12H       \x1b[18;20H       \x1b[22;3H']),
    ('G2048', 'd slides right', b'xsd', [b'\x1b[18;28H   4   ', b'\x1b[18;12H       \x1b[18;20H       \x1b[18;28H']),
    ('G2048', 'no more moves', b'x' + b'sadw' * 25 + b'n', [b'No more moves. Score 316. Play again?', b'Bye.']),
    ('G2048', 'make 2048', b'x' + WIN2048 + b'qn',
     [b'You made 2048! Keep going', b' 2048 ', b'Score 20120. Play again?', b'Bye.']),
]


# Minesweeper, seed 0 (the seed ref.py starts with), first cell (7,7): visit every
# cell row by row from the top left and open each one that has no mine, as laid out
# by that seed (read from the game's memory)
MINES_ROWS = [
    '...*......*.*...', '*......*........', '.*...*..........', '.......*.....*.*',
    '.**..*....*.*...', '*........*......', '..*...*..*......', '....*...........',
    '...*....*......*', '................', '......*........*', '...*.......*....',
    '............*.*.', '.*.........*....', '...*...*........', '.*.**..*.*.*....']


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
    # in the top row: flag the mine at column 3 and the empty cell at 2, put a flag on
    # 9 and take it off, then open the mine at 10. The flag on 3 stays, 2 shows X
    ('MINES', 'flags, then a mine', b'x ' + b'w' * 7 + b'a' * 4 + b'f af' + b'd' * 7 + b'ffd n',
     [b'Mines 39', b'Mines 38', b'Mines 37', b'BOOM! You hit a mine.', b"\x1b[4;11H'", b'\x1b[4;9HX', b'Bye.']),
]


# Breakout. The seed starts at 0 and the key on the title comes at once, but every
# frame with no key (a timed 20? that runs out) adds 20 to it, so each serve
# depends on the frames played before it. A whole wall cleared, as played by a
# small bot that read the ball and the paddle from the interpreter every frame and
# went to one of the paddle places that catch the ball. A number is that many
# frames with no key (NULs)
BREAKOUT_WIN = (
    'x ddd51dd42aaaaaaaa36ddddd39aaaaaa38d43dddd40aaaa40ddddd43aaaaa43aa46ddd'
    'ddddd40aaaaaaaa36ddd41ddddddd37aa42aaaa44aaa45a51ddddaaa5ddddaaaa4ddddaa'
    'aa4dd2aa18a23d23d11d11dd19dd7d20dd13aa13aa13aa13aa13aa34ddd12d14dd13ddd1'
    '5d20aaaa17aa22aaaa35dddd17dd19dddd20aa22aaaa14aaaa16ddd13dd12dddd30aaaaa'
    '17aaaa20dddd16dddd64aaaaaaaa42dd20dd18dd18dd44aaaaa43ddddd43aaaa46dddddd'
    '18aaaa16aaaa42aa46dddd44d49ddd47dd72aaaaaaaa66a73dddd18dddd18d73aa72aaaa'
    '70aaaa44dddddd42ddd71aaaaaaa67a73dddd22'
)


def frames(s):
    return b''.join(b'\0' * int(n) if n else k.encode() for n, k in re.findall(r'(\d+)|([^\d.])', s))


TESTS += [
    ('BREAKOUT', 'clear the wall', frames(BREAKOUT_WIN) + b'\0n',
     [b'Score 252', b'Balls 3', b'You cleared the wall!  Score 252. Play again?', b'Bye.']),
    # serve and leave the paddle where it is: each ball is lost in 150 frames
    ('BREAKOUT', 'out of balls', b'x' + (b' ' + b'\0' * 150) * 3 + b'\0n',
     [b'Balls 2', b'Balls 1', b'Balls 0', b'Out of balls.  Score ', b'Bye.']),
]


# Qubic, seed 0 (no NULs): two games against a simple player that takes a win,
# blocks a line of three, and otherwise plays where its own pieces add up most
# on the lines through a cell that hold no O (then where most such lines hold one
# of its own), trying the corners and the other outer cells first
QUBIC_LOST = '111 114 141 441 112 132 332 131 331 341 134 143 334 443 433'
QUBIC_WON = '111 114 144 414 433 443 431 424 412 343 341 244 142 112 122 132'


def typed(moves):
    return b''.join(m.encode() + b'\r' for m in moves.split())


TESTS += [
    ('QUBIC', 'it wins', b'y' + typed(QUBIC_LOST) + b'n', [b'I play ', b'I win!', b'Bye.']),
    ('QUBIC', 'you win', b'n' + typed(QUBIC_WON) + b'n', [b'I play ', b'You win!', b'Bye.']),
    ('QUBIC', 'bad moves', b'y1 2 3\r12\r9 9 9\r123\r1x1x1\rqn',
     [b'Type three digits, each 1 to 4', b'That cell is taken.', b'I play ']),
]


# Klondike, seed 0 (as ref.py starts), draw one: a win found by a depth-first
# search on a model of the deal in Python, with the cards read from the game's
# memory after the shuffle. Each move is d, or a source and a destination
KLONDIKE_WIN = (
    '24dddddwfddddddddwf3fwfwf1fdddddddddddwfddwfdddw5454341w4545fdddddddwfw3'
    'ddw7ddddw7275256dw646ddddw17175dw2ddw131ddddw232dw5656f646f646f1fddddwfd'
    'wf7f7f73dddwf1f1f4f1f4f1f4f1f4f1f43535f1f5f5f212f5f121fddw2727fddwfwf3f2'
    'f3f2f3f2f3f2f3f2f3f2f3f'
)

TESTS += [
    ('KLONDIKE', 'all 52 home', b'1' + KLONDIKE_WIN.encode() + b'n',
     [b'KS Kh Kd KC', b'All 52 are home. You win!', b'Bye.']),
    ('KLONDIKE', 'bad moves', b'x173w3wf1f1xqn',
     [b'KLONDIKE   draw 1', b"That doesn't go there.", b'The waste is empty.', b'Bye.']),
    # the fourth draw shows the waste's top three; the eighth empties the stock
    # (row 2, column 2 is blank, and the count at column 5 is 0, rows and columns
    # from 0); the ninth turns the waste over
    ('KLONDIKE', 'draw three, turn the waste over', b'3' + b'd' * 9 + b'qn',
     [b'2d 4C 3C', b'\x1b[3;3H  \x1b[3;6H0 ', b'Bye.']),
]


# Lights Out, seed 0 (the seed ref.py starts with): three levels solved (by chasing
# the lights down from the top row, with the best of the 32 first rows), then n.
# And a new puzzle, then q
LIGHTS_WIN = b'xwa ywd aaa s dd ssdd ywwa sddd saa sdd sa '

TESTS += [
    ('LIGHTS', 'three levels', LIGHTS_WIN + b'n',
     [b'Made with 3 presses.', b'Level 2', b'Made with 7 presses.', b'All out in 5 moves! Next level?', b'Bye.']),
    ('LIGHTS', 'a new puzzle, then quit', b'x  n q',
     [b'Level 1    Moves 2', b'Level 1    Moves 0', b'Bye.']),
]


# Fifteen, seed 0 (as ref.py starts): the 8-puzzle solved by a breadth-first search,
# and the 15-puzzle by a weighted A* search (not the fewest moves), on a model of
# the board read from the game. Then a few slides (the 15-puzzle's gap starts in
# row 2, column 2: w moves it down twice, d left once, the rest are blocked) and
# giving up
TESTS += [
    ('FIFTEEN', 'the 8-puzzle', b'x3wdsaawddsasdwaasdwdsawawn',
     [b'Moves 24', b'Solved in 24 moves! Play again?', b'Bye.']),
    ('FIFTEEN', 'the 15-puzzle', b'xysaawdwawddsdssaawdwasddsaaawdddwwassdwaassddwaawawdddsawaan',
     [b'Moves 58', b'Solved in 58 moves! Play again?', b'Bye.']),
    ('FIFTEEN', 'three slides, the rest blocked, give up', b'xywwwwwwddddddqn',
     [b'Moves 3', b'Play again?', b'Bye.']),
]


# Greed: a whole game, as played by a bot on a model of the field read from
# the game, taking the move that leaves it most moves next (the first such in
# qweadzxc). With the seed at 0 you start at column 63, row 3 of the field,
# where w e a z x are open
TESTS += [
    ('GREED', 'no moves left', b'xxaaqqzzaaaaqwecewdeddxxxxedzcewdzddedxxxqaxdqwczdeaqewwaxqedzaen',
     [b'Score 247  17.6%', b'No moves left. Play again?', b'Bye.']),
    ('GREED', 'the moves shown, a blocked one, quit', b'xhqQn',
     [b'You can go: w e a z x ', b"You can't go that way.", b'Score 0  0.0%', b'Play again?', b'Bye.']),
]


# Reversi, seed 0 (no NULs): games against a small minimax player in Python,
# reading the board from the game and scoring a board by its discs plus 10 for
# each corner (two moves deep wins as X and as O; one deep loses)
TESTS += [
    ('REVERSI', 'you win as X', b'xyd3f2d6f5g3d2e1b3c2b1g1f4c5h7f7h5b6g5b8d8a5g8h1h2a3g7g4d7b7b2n',
     [b'You are X, I am O.', b'I play ', b'You win 34 to 30.', b'Bye.']),
    ('REVERSI', 'you win as O', b'xnc3e3c5g1a3g4f5e1d7d1b1f3a4h3g5g7h5h1h8h7a5e7b2g2c6a2c8b7a7b8n',
     [b'You are O, I am X.', b'You win 49 to 15.', b'Bye.']),
    ('REVERSI', 'it wins', b'xyd3f3f5d1f1e7b3h5d7b6d8f7g3c7a5b5b7f6g6b4g7b8g8c2b2f2g2a2f4n',
     [b'I win 48 to 16.', b'Bye.']),
    ('REVERSI', 'marks, a bad cell, the cursor, resign', b'xymd4a1 d3qn',
     [b'\x1b[6;11H+', b"You can't play there.", b'I play ', b'X 4   O 1', b'You resign.', b'Bye.']),
]


# Battleship, the seed at 0: firing only at my ships (read from the game), and
# only at water, which lets it find and sink the whole fleet. And placing,
# firing twice at a cell, and giving up
BATTLE_MISS = (b'a0b0c0d0e0f0g0h0i0j0b1c1d1e1f1g1h1i1j1e2f2g2h2i2j2b3c3d3e3f3g3h3i3j3a4b4c4d4'
               b'e4g4h4i4j4a5b5c5d5e5h5i5j5a6f6h6i6j6a7b7c7d7e7f7h7i7j7a8b8c8d8e8f8h8i8j8a9b9c9d9e9f9h9i9j9')

TESTS += [
    ('BATTLE', 'you win', b'x     a1a2b2c2d2a3f4f5g5b6c6d6e6g6g7g8g9n',
     [b'You fire at A1: a hit.', b'You sank my destroyer!', b'I sank your carrier!',
      b'You sank my whole fleet. You win!', b'Bye.']),
    ('BATTLE', 'it wins', b'xr' + BATTLE_MISS + b'n',
     [b'You fire at A0: a miss.', b'I sank your carrier!', b'I sank your destroyer!',
      b'I sank your whole fleet. I win!', b'Bye.']),
    ('BATTLE', 'placing, a cell twice, give up', b'x ww ss ra0a0qn',
     [b'Place your battleship (4 cells).', b"Ships can't overlap.", b'You fire at A0: a miss.',
      b'You already fired at A0.', b'You give up.', b'Bye.']),
]


# Idol, seed 0 (n at once on the title starts a new game: no key wait stirs the
# seed): home is Xeorra (Mining, policed). The chart chooses the nearest system in
# range; s steps to the next farther, Return jumps. Xeorra mines ore (cheap) and
# Neon, the nearest system, is industrial and wants it, and has a shipyard
TESTS += [
    ('IDOL', 'fly: step, jump, refuel', b'nss\rf',
     [b'Docked at Xeorra.', b'Docked at Dada.', b'Day 2', b'Fuel 4/7', b'Debt 5050',
      b'Refuelled 3 units for 60.', b'Cr 940']),
    ('IDOL', 'a profitable trade', b'nmssb\rc\rmssx\r',
     [b'Buy Ore: how many (Return for 20)? ', b'Bought 20 t of Ore for 460.',
      b'Docked at Neon.', b'Sold 20 t of Ore for 600.', b'Cr 1140']),
    ('IDOL', 'an upgrade, then too little money', b'n\rysbsbr',
     [b'Docked at Neon.', b'Shield\x1b[5;17H0 of 2\x1b[5;46H  1000', b'Bought: Shield.',
      b'Courier L1 S1 M0', b'Cr 0\x1b', b"You can't pay for that.", b'The hull needs no repair.']),
    ('IDOL', 'ships at a high-tech system, at the trade-in price', b'ns\rysssssssb',
     [b'Docked at Cexege.', b'Freighter\x1b[12;17H50 t, tank 8, hull 50\x1b[12;46H  6500',
      b'Clipper\x1b[14;17H70 t, tank 10, hull 80\x1b[14;46H 27500', b'You fly one already.']),
    # the ore sold at Neon pays for two missiles there, which win against the
    # level 0 pirate at Nela
    ('IDOL', 'a duel won with missiles', b'nmssb\rc\rmssx\ryssbbfc' + b's' * 22 + b'\rmm',
     [b'Bought: Missile.', b'Duel: pirate ship, level 0', b'Your missile hits for 15.',
      b'You win. A bounty of 250.', b'You salvage 1 t of Medicine.', b'Docked at Nela.']),
    ('IDOL', 'a duel lost: game over', b'n' + b's' * 20 + b'\rc' + b'l' * 30 + b'x',
     [b'Duel: pirate ship, level 1', b'You close in.', b'The pirate hits you for ',
      b'Your ship is destroyed, and you with it. Game over.', b'Press a key.', b'Bye.']),
    # the police scan you at Neon on day 3, on the way back from Dada
    ('IDOL', 'a police scan: submit', b'nmssssssb5\rcss\r\rs',
     [b'Bought 5 t of Narcotics for 730.', b'The police find 5 t of contraband. s submits, r resists.',
      b'They take it and fine you 600.', b'Docked at Neon.', b'Cr 0\x1b', b'Debt 5430']),
    ('IDOL', 'a police scan: resist', b'nmssssssb5\rcss\r\rrff',
     [b'You resist the police!', b'Duel: police ship, level 3', b'You fail to get away.', b'You get away.',
      b'Wanted 20']),
    ('IDOL', 'pay the loan', b'nl500\rl\rl',
     [b'Pay how much (Return for 1000)? ', b'You pay 500 off the loan.', b'Debt 4500',
      b'Debt 4000', b'You have no cash.']),
    # the Head of the idol lies at Zebe, the 12th system out (the rumour at home
    # says so)
    ('IDOL', 'an idol part found, its price, then known', b'n' + b's' * 11 + b'\rtct\rt',
     [b'Docked at Zebe.', b"The Idol's Head is here: 23 t of Textiles and 11 t of Ore (t trades).",
      b"The Idol's Head wants 23 t of Textiles and 11 t of Ore.",
      b"The Idol's Head lies at Zebe: 23 t of Textiles and 11 t of Ore."]),
    # offers and rumours on docking: the offer at home is shown again by k, which
    # Return leaves untaken; Neon has none
    ('IDOL', 'offers and a rumour', b'nk\r\rk',
     [b'Docked at Xeorra.', b"Rumour: the Idol's Head lies at Zebe.",
      b'Offer 1: 11 passengers to Elve, by day 9, pay 1620.', b'Take which? ',
      b'Docked at Neon.', b"Rumour: the Idol's Base lies at Elve.", b'There are no offers here today.']),
    # the first offer at Xean, passengers to Rielso, taken there by way of Dabe
    ('IDOL', 'a contract delivered', b'nsss\rk1fc' + b's' * 12 + b'\rfc' + b's' * 6 + b'\r',
     [b'Offer 1: 20 passengers to Rielso, by day 10, pay 1300.', b'Contract taken.', b'20 passengers',
      b'to Rielso by day 10', b'Docked at Dabe.', b'Docked at Rielso.', b'You deliver: 1300.', b'Cr 840']),
    ('IDOL', 'sealed cargo sold', b'nsss\rk2mssssssssx',
     [b'Sealed Textiles', b'You sell the sealed cargo for 176. You are wanted, and owe more.',
      b'Debt 5270', b'Wanted 20']),
    # a save code made, loaded back, and played on: the state cells and the stock
    # here are checked by idol_save() below; here the messages
    ('IDOL', 'a save code', b'nmssb\rc\rv',
     [b'Save code: zwFTwUcguJLoCkL1w3mR07cTVIiIrrMuR_e7EUDTCcUzAGp9']),
    ('IDOL', 'a mistyped save code refused, then the right one', b'lzwFTwUcguJLoCkL1w3mR07cTVIiIrrMuR_e7EUDTCcUzAHp9\rlzwFTwUcguJLoCkL1w3mR07cTVIiIrrMuR_e7EUDTCcUzAGp9\r',
     [b'That code is not right.', b'Docked at Neon.', b'Cr 540\x1b', b'Debt 5050', b'Fuel 5/7', b'Cargo 20/20']),
]


# Idol's save code must load back to exactly the state it was made from, and the
# game must play on the same: (keys that end with v, keys to play on). The state
# cells 0 to 33 and the stock where you are are compared, after loading and
# again after playing on. Only the stock where you are is saved, so the keys to
# play on go nowhere whose stock was changed before the save.
IDOL_SAVES = [
    (b'nmssb\rc\rv', b'mssx\rcss\r'),
    (b'nsss\rk2mssssssssbc\rv', b'\rf\r'),
    (b'n' + b's' * 11 + b'\rtv', b'sss\rf'),
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
    r = salt
    for i in range(1, len(vals)):
        r = (r * 261 + 1) & 0xFFFF                  # 64R, the interpreter's `,
        vals[i] ^= (r ^ r >> 8) % 64
    c = 0
    for v in vals:
        c = (c * 3 + v) & 63
    return bytes(IDOL_ALPHA[v] for v in vals + [c])


def idol_cells(**kw):
    """the state of a new game on seed 0 (day 1, home, a new Courier), changed by kw"""
    names = ('seed day cashhi cashlo debt pos c0 c1 c2 c3 c4 c5 c6 c7 cls laser shield missiles pods '
             'tankup hull fuel escape hidden wanted held known ckind cdest cgood ctonnes cdead cpay cpass').split()
    cells = dict.fromkeys(names, 0)
    cells.update(seed=0, day=1, cashlo=1000, debt=5000, laser=1, hull=30, fuel=7)
    cells.update(kw)
    return [cells[n] for n in names]


# seed 0: the Base of the idol (part 5) lies at system 9, Elve, and wants 18 t of
# Luxuries and 15 t of Textiles
IDOL_BASE = dict(pos=9, c5=18, c1=15, pods=2, cashlo=3000, day=50)
TESTS += [
    ('IDOL', 'an idol part traded', b'l' + idol_code(idol_cells(**IDOL_BASE), [60] * 8) + b'\rt',
     [b"The Idol's Base is here: 18 t of Luxuries and 15 t of Textiles (t trades).",
      b"You trade for the Idol's Base: 1 of 6.", b'Idol 1/6', b'Cargo 0/40']),
    ('IDOL', 'the win', b'l' + idol_code(idol_cells(held=31, debt=0, **IDOL_BASE), [60] * 8) + b'\rt\r',
     [b"You trade for the Idol's Base: 6 of 6.", b' is whole and the loan is paid. You win in 50 days!',
      b'Press a key.', b'Bye.']),
    ('IDOL', 'the end at day 999', b'l' + idol_code(idol_cells(day=998, held=5), [60] * 8) + b'\r\r\r',
     [b'Day 999', b'Day 999: the end. You held 2 of the six parts of the Idol of ', b'Bye.']),
    # a hull of 2 loses the first duel out (the 19th system): with an escape pod,
    # and without one
    ('IDOL', 'a duel lost with an escape pod', b'l' + idol_code(idol_cells(hull=2, escape=1, c0=10), [60] * 8)
     + b'\r' + b's' * 18 + b'\rcl',
     [b'Duel: pirate ship', b'Your ship is lost. The escape pod takes you home to a new Courier.',
      b'Docked at Xeorra.', b'Debt 10050', b'Cargo 0/20']),
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
