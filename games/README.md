# B8Script games

Fifty-three games for B8Script: twenty-one full-size ones, and thirty-two tiny ones that each fit in a text message or a tweet. Programs that aren't games, such as Tiny BASIC, a memory monitor and benchmarks, are in [`programs/`](../programs/).

## Running a game

Every `.B8S` file is a complete program. Run it with any B8Script runner:

| On | Command |
|---|---|
| Windows (command shell) | `B8SWIN BREAKOUT.B8S` |
| CP/M, Z80 | `B8SZ80 BREAKOUT.B8S` |
| CP/M, 8080 | `B8S8080 BREAKOUT.B8S` |
| A web browser, on a computer or a phone | Open [`web/b8script.html`](../web/b8script.html) and pick the game from its menu |

The interpreters are in [`B8Script-interpreters/`](../B8Script-interpreters/), and its README covers every build, including the 6502 and 6809 ROMs.

- **The screen.** Most games draw on a screen of 80 × 24, with the console escapes of `$` (`/{` clears it, `/~` places the cursor). The CP/M and Windows builds send them as ANSI (VT100) sequences: on CP/M use an ANSI terminal or emulator, and the Windows builds switch the console into ANSI mode themselves. A generic ROM built with `ANSI = 0` draws through the machine's own screen routines instead.
- **Ctrl-C** stops any game.
- **Random numbers** come from how long you take to press a key. That's why many games say "Key" or "Press a key to start": your timing picks the game.
- **`.TXT` files.** Each full-size game also has a `NAME.TXT` with comments that explain how it works. It runs the same as the `.B8S`; the `.B8S` is just that file with the comments and spaces stripped out.

## Full-size games

| File | Game | How to play |
|---|---|---|
| `BATTLE.B8S` | **Battleship** against the computer: five ships each on a 10 × 10 sea. | Place ships with w a s d, t to turn, space to set, r for random. Fire with w a s d and space, or type a cell such as `c5`. q gives up. |
| `BREAKOUT.B8S` | **Breakout**: knock out the wall with the ball. Three balls; where the ball hits the paddle sets its angle. | a and d move the paddle, space serves, q quits. |
| `CONNECT4.B8S` | **Connect Four**: you are X and move first. The machine takes a win when it sees one and blocks yours. | 1–7 drops a piece into that column. y plays again. |
| `DUNGEON.B8S` | **Dungeon**, a small roguelike: find the stairs `>` and go deeper. Gold `$`, potions `!`, a sword and armour `]`. | w a s d move; walk into a monster to fight it. p drinks a potion, q quits. |
| `FIFTEEN.B8S` | **The 15-puzzle** (and the 8-puzzle on 3 × 3): slide the tiles back into order. Every puzzle can be solved. | w a s d slide a tile into the gap; the key is the way the tile moves. q gives up. |
| `G2048.B8S` | **2048**: slide the tiles, and equal tiles merge. Make 2048, then keep going if you like. | w a s d slide, q quits. |
| `GREED.B8S` | **Greed**: move across a field of digits. Each move eats as many cells as the digit you step on. | q w e / a d / z x c move in eight directions, h shows the legal ones, Q quits. |
| `HANGMAN.B8S` | **Hangman**: guess the word a letter at a time; six misses and you hang. | a–z guess; y or n at the end. |
| `IDOL.B8S` | **Idol**, a space trading game: trade among 64 star systems, fight or flee, take contracts, upgrade your ship, and find the six parts of an ancient idol. Games can be saved as a code. | Docked: c chart, m market, y shipyard, k contract, l pay the loan, f refuel, r repair, t trade for an idol part, v save code, ? help, q quit. In lists: w s move, Return jumps, b buys, x sells. |
| `KLONDIKE.B8S` | **Klondike** solitaire: build the four foundations up by suit, ace to king. Draw one or three. | d draws. A move is a source (w the waste, or 1–7 a pile) and then a destination (1–7 a pile, or f the foundation). q quits. |
| `LIFE.B8S` | **Conway's Life** on a 32 × 16 grid. A demo, not a game. | Any key stops it. |
| `LIGHTS.B8S` | **Lights Out**: pressing a light switches it and its neighbours; put them all out. Levels grow harder. | w a s d move, space presses, n gives a new puzzle, q quits. |
| `MASTER.B8S` | **Mastermind**: break a code of four digits 1–6 in ten tries. | Type four digits per guess; y or n at the end. |
| `MINES.B8S` | **Minesweeper**: 16 × 16 cells, 40 mines. The first cell you open is always safe. | w a s d move, space opens, f flags, q quits. |
| `QUBIC.B8S` | **Qubic**: four in a row on a 4 × 4 × 4 cube, against a machine that blocks, forks and scores lines. | Type layer, row and column (1–4 each), then Return. |
| `REVERSI.B8S` | **Reversi** (Othello) on 8 × 8, against the computer. | w a s d and space, or type a cell such as `d3`. m marks your legal moves, q resigns. |
| `ROBOTS.B8S` | **Robots**: the robots step towards you each turn. Make them crash into each other. | q w e / a d / z x c move, s stays, space waits, t teleports, Q quits. |
| `SUPERTRK.B8S` | **Super Star Trek**: 8 × 8 quadrants; destroy every Klingon before the stardates run out. | m move, j warp, l long-range scan, g map, p phasers, t torpedo, z shields, h help, q quit. |
| `TETRIS.B8S` | **Tetris**. | a d move, w rotates, s moves down, space drops, q quits. |
| `TRADER.B8S` | **Space Trader**: buy low, fly, sell high, among five planets in 40 days. | b buy, s sell, f refuel, t travel, q quit. |
| `WUMPUS.B8S` | **Hunt the Wumpus**, after the 1973 original: 20 rooms on a dodecahedron. | m moves, s shoots, then type room numbers and press Return. |

## Tiny games

Thirty-two games, each one complete in a few lines. [`docs/b8sms.md`](../docs/b8sms.md) shows the code of each and explains how it fits.

### `b8sms/`: 160 characters, the length of a text message

| File | Game | How to play |
|---|---|---|
| `HILO.B8S` | **Hi-Lo**: guess a number from 0 to 127 in seven tries. A perfect binary search always wins. | Press a key, then type guesses and press Return. |
| `LANDER.B8S` | **Lunar Lander**, turn by turn, with tight fuel. Touch down slower than 5. | 0–9 burns that much fuel each turn. |
| `NIM.B8S` | **Nim**: take 1–3 sticks, and whoever takes the last loses. The computer plays perfectly. | Press a key, then 1–3 each turn. |
| `REFLEX.B8S` | **Reflex**: five rounds; hit a key the moment it says GO. Lowest total wins, and pressing early costs 999. | Press a key to start, then any key at GO. |
| `SKI.B8S` | **Ski**: a slalom course scrolls past; stay between the poles. | j left, l right. |
| `RPS.B8S` | **Rock Paper Scissors** against an AI that learns your habits. First to +5 or −5. | 1 rock, 2 paper, 3 scissors. |
| `SIMON.B8S` | **Simon**: repeat a growing string of digits after it vanishes. | Press a key, then type the digits. |
| `PIG.B8S` | **Pig**, the dice game: reach 100 in as few turns as you can. A 1 loses the turn's points. | Any key rolls, h banks the points. |
| `TRON.B8S` | **Tron**: a light cycle that never stops. Don't hit your own trail. | `,` turns left, `.` turns right. |
| `LIGHTS.B8S` | **Lights Out**, the classic 5 × 5 puzzle from all lights on. Upper case is on, lower case is off; 15 presses is the best. | a–y press that cell. |

### `tweet140/`: 140 characters, the classic tweet

The same ten games, cut down. They play the same, with shorter titles and messages. Hi-Lo answers `64>` (too high), `4<` (too low) and `4=` (right).

### `tweet280/`: 280 characters, a tweet since 2017

| File | Game | How to play |
|---|---|---|
| `SNAKE.B8S` | **Snake**: eat the `*` and grow, and don't bite yourself. The edges wrap round. | `,` turns left, `.` turns right. |
| `MASTER.B8S` | **Mastermind**, full black and white pegs: four digits 1–6, ten tries. | Press a key, then type four digits and press Return. |
| `NIM357.B8S` | **Nim 3-5-7**: three heaps, and whoever takes the last stick wins. The computer plays perfectly; you can win only with perfect play from the first move. | A heap (1–3), then how many to take. |
| `DUEL.B8S` | **Duel**: Tron against the computer. Last one moving wins. | `,` turns left, `.` turns right. |
| `KINGDOM.B8S` | **Kingdom** (Hamurabi): rule for ten years. Each person eats 20 bushels and can plant 10, on at most 999 acres. Feed fewer than half and you are overthrown. | Type how much grain to feed each year, then Return. |
| `TICTAC.B8S` | **Tic-tac-toe** against an unbeatable opponent. A draw is the best you can do. | 1–9, row by row from the top left. |
| `BLACKJCK.B8S` | **Blackjack**: $100, betting $10 a hand. The dealer draws to 17. | Press a key, then h to hit, any other key to stand. |
| `COPTER.B8S` | **Copter**: fly down a narrowing cave. Gravity pulls you right; you have inertia. | Any key pushes left. |
| `BREAKOUT.B8S` | **Breakout**: 96 bricks; keep the ball in play. | j left, l right. |
| `HANGMAN.B8S` | **Hangman**: eight six-letter computer words, six misses allowed. | Press a key, then guess letters. |
| `MAZE.B8S` | **Maze**: a new maze every game. Start in the gap at the top right and get out through the gap at the bottom left. | Press a key, then i up, j left, k down, l right. |

### `longer/`

| File | Game | How to play |
|---|---|---|
| `MINE390.B8S` | **Minesweeper** with flood fill, in 390 characters: an example of what a little more than a tweet buys. 8 × 8, about one mine in eight. | Press a key, then a row digit and a column digit (1–8 each). |

### Speed of the real-time tiny games

Ski, Tron, Snake, Duel and Copter move one step per `99?` in their code: a wait of up to 99 ms for a key, so about ten steps a second. Breakout waits `250?`, about four steps a second, which keeps it playable but still a challenge. It is now exactly 280 characters, so it has no room for a longer number. To change the speed, change that number: bigger is slower. Up to `99?` it costs nothing; a three-digit wait costs one character, which still fits every limit. Pressing a key ends a wait early, so a game runs a little faster while you press keys.
