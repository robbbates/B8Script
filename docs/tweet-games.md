# Tweet games

Ten B8Script games, each 160 characters or fewer: a game in a tweet. Each one is a complete program, with no line breaks and nothing left out. Paste it into a runner and play.

The files are in [`B8Script-interpreters/testing/games/tweets/`](../B8Script-interpreters/testing/games/tweets/), and `test_tweets.py` in `testing/` plays each one with scripted keys on the checked reference interpreter. All of them were developed and tested on `ref.py`. None has been run on a real CPU build yet: `gamecheck.py` covers only `games/*.B8S`.

| Game | Chars | Kind | You press |
|---|---|---|---|
| [Hi-Lo](#hi-lo) | 159 | Guessing | Digits, Return |
| [Lander](#lander) | 151 | Physics, turn by turn | 0–9 |
| [Nim](#nim) | 159 | Strategy against a perfect opponent | 1–3 |
| [Reflex](#reflex) | 151 | Reaction time | Any key |
| [Ski](#ski) | 158 | Real-time scroller | j, l |
| [Rock Paper Scissors](#rock-paper-scissors) | 153 | Against an AI that learns | 1–3 |
| [Simon](#simon) | 159 | Memory | Digits |
| [Pig](#pig) | 160 | Push your luck | h, any key |
| [Tron](#tron) | 159 | Real-time, 2D | `,` and `.` |
| [Lights Out](#lights-out) | 159 | Puzzle | a–y |

Ski and Tron are real-time, and Tron draws with the cursor-position escape, so both need an ANSI console (see [The console](b8script.md#the-console)). Simon clears its line with ESC `[K`. The rest are plain teletype games.

## The tricks that make them fit

These come up again and again.

- **Randomness from the player.** No machine has a clock B8Script can read, but a person can't time a key to the millisecond. `0 1(1+1?0=)` counts while it waits for a key, and the count is the seed. Pig rolls its die this way on every key (the count runs 0–5 and wraps), so every roll is fresh.
- **A generator you can replay.** `r@75*74+:r!256/;` is a linear congruential generator; its high byte is usable, but its low bit never changes, so the code always takes the high byte. Set `r` to the same seed and you get the same numbers again. Simon uses this to store nothing: it replays the sequence to show it, and again to check your answer.
- **The stack as a variable.** A counter that lives on the stack under a loop costs one character to update (`1-`), where a variable costs six (`t@1-t!`). Hi-Lo's tries, Reflex's rounds and Lights Out's move count all live there.
- **Flags are −1.** A true flag is all ones, so it is arithmetic. `:106=%108=-` turns the keys j and l into −1 and +1 with no branch. `flag 32&` is 32 or nothing, which is how Lights Out picks upper or lower case.
- **Pick the string, then print it.** `" CRASH"%5<(;" LANDED"0)$` pushes one message, swaps in the other if needed, and prints whichever is left: an if-else with one `$`.
- **Padding instead of edge tests.** Lights Out's grid has a dead border, as Conway's Life does in the spec, so pressing a corner toggles border cells that are never shown. Tron goes the other way: its arena is a torus, so `1023&` is the only bounds check it needs.
- **Watch the minus sign.** `1-3&` is 1 and then −3. Four of these games had that bug in a first draft; the fix is a space, `1- 3&`. The stripper (`b8strip.py`) keeps exactly the spaces B8Script needs, and every game here is already in its stripped form.

## Hi-Lo

```text
[N0 1(0?:13=\:'48-%10*+1);]"Key=go. 0-127, 7 tries"$0 1(1+127&1?0=)s!7 1(13'10'N:g!s@<(" up"$0)g@s@>(" down"$0)1-:0>g@s@=0=&);g@s@=:(" WIN"$0)0=(" LOSE "$s@#0)
```

Press a key to start, then type guesses and press Return. The number is 0–127 and you get 7 tries, and 2⁷ = 128, so a perfect binary search always wins and one wasted guess can lose. That makes it a game rather than a quiz.

- `N` reads a number from the keys, echoing digits but not the Return, so the hint lands on the same line.
- The seed loop masks with `127&` as it counts, so the secret is in range with no division.
- The tries counter lives on the stack; the loop runs while tries are left and the guess is wrong.

## Lander

```text
"LANDER burn 0-9, land under 5"$1000h!0v!99f!1("/M/Jh"$h@#" v"$v@#" f"$f@#" ?"$0?15&:f@>(;f@0):f@%-f!v@%- 3+v!h@v@-h!h@0>)v@:#" CRASH"%5<(;" LANDED"0)$
```

You start at height 1000 with no speed and 99 fuel. Each turn press 0–9 to burn that much fuel. Gravity adds 3 to your downward speed and a burn takes it off. Touch down at under 5 to land.

The numbers are tuned so the classic trick, a **suicide burn**, is needed: the least fuel that can land at under 5 is 89, so 99 leaves almost no slack. Fall freely for about 20 turns, then burn hard and feather the last few turns. A search over every burn sequence found landings at speed 1.

- `0?15&` maps the digit keys to 0–9 with no subtraction (and space to 0).
- The burn is capped at the fuel left with `:f@>(;f@0)`.

## Nim

```text
"NIM take 1-3, last loses. Key"$0 1(1+1?0=)7&20+n!1("/M/J"$n@#" take "$0?:'3&:0=-n@%-:n!1<:(" you lose"$0)\" I take "$n@1- 4/%;:0=-:#n@%-:n!1<:(" I lose"$0)0=)
```

Press a key to start: there are 20 to 27 sticks. You and the computer take 1–3 in turn, and whoever takes the last stick loses. The computer plays perfectly. It always tries to leave a number that is 1 more than a multiple of 4, so it takes (n − 1) mod 4, or 1 when that is 0. You can beat it only by finding that rule and getting there first, and on 2 starts in 8 (21 and 25) the position is already lost.

- `3&:0=-` turns any key into 1–3: the low two bits, with 0 bumped to 1.
- `1<:( message 0)\` prints the message and leaves the main loop in one go.

## Reflex

```text
[W0 1(1+1?0=)]"REFLEX: 5 rounds, hit a key at GO. Key"$Wt!0s!5 1("/M/Jwait.."$t@2047&999+?:{(" early"$999 0)}0=(" GO! "$W:#0):t!s@+s!1-:);" total "$s@#
```

Five rounds. After a random pause it says GO!, and you hit a key as fast as you can. Pressing during the pause costs 999. Lowest total wins.

- `W` counts while waiting for a key. It both times you and, at the start, seeds the first pause. Each pause is your last time, masked and offset, so it is different every round.
- The pause is one `n?`. If it returns a key, you jumped early.
- The score is in polls of `1?`, roughly milliseconds on most machines but not all: the spec notes that the shortest wait is about 15.6 ms on Windows without a high-resolution timer. Compare scores on the same machine.

## Ski

```text
"SKI j l/M/J"$[S1(:1<\32'1- 1);]5q!9p!0t!0r!1(r@75*74+:r!:0<%256/;31&p@<%-:p@+p!50?:r@+r!:106=%108=-%-q@+:q!:0>%9<&0=\p@S"|"$q@1-S"V"$8q@-S"|/M/J"$t@1+t!1)t@#
```

A slalom course scrolls up past your skier, `V`. Steer with j and l to stay between the poles. The score is the number of lines you survive.

- The course wanders by −1, 0 or +1 a line. It is the difference of two random bits, one of them more likely to be set the further right the course is, so it drifts back toward the middle and never leaves the screen. No clamping code needed.
- The skier is kept as `q`, its place relative to the left pole, so a crash is just `q` outside 1–8 and a line is always three runs of spaces.
- Every key you press is added into the random state, so your steering changes the course to come.
- One frame is one `50?`, about 20 lines a second.

## Rock Paper Scissors

```text
"ROCK PAPER SCISSORS 1 2 3, to +-5"$9_t!0i!0s!1("/M/J? "$t@i@+:,1+3/%;c!0?1- 3&:p!%."RPS":p@+,'c@+,'32'i@3*p@+9/%;i!p@c@- 3+3/%;:1=%2=-s@%-:s!:#:5<%-5>&)
```

Press 1, 2 or 3 for rock, paper or scissors. Each line shows your move, the computer's, and the score. First to +5 or −5.

The computer learns. It keeps a 9-entry table indexed by your last two moves, holding what you played the last time that pair came up. It predicts you'll do it again and plays what beats that. People are bad at being random, so it catches patterns fast: it beats the cycle 1 2 3 by −5 after 9 rounds. To beat it, you have to model its model.

- The table is 9 bytes of heap and is never cleared. Whatever was in memory just becomes its first guesses, and `3/%;` brings any byte into range.
- The history index is `(i·3 + p) mod 9`, an order-2 Markov context in eight characters.
- The result is `(p − c) mod 3`: 0 tie, 1 you win, 2 it wins. `:1=%2=-` turns that into the score change without a branch.

## Simon

```text
[Dr@75*74+:r!256/;7&49+]"SIMON repeat the digits. Key"$0 1(1+1?0=)s!1n!1("/M/J"$s@r!n@1(D'1-:);999?;"/M/[[K"$s@r!-1n@1(%0?:'D=&%1-:);:(n@1+n!0))" score "$n@1-#
```

A string of digits flashes for a second and is wiped. Type it back. Each round adds a digit. One mistake and the game is over.

It stores no sequence at all. The digits are generator output from a fixed seed, so resetting `r` to the seed replays them: once to show them, and again to check what you type. The sequence is unlimited and costs no memory.

- `"/M/[[K"` goes back to the start of the line and clears it, hiding the digits.
- The check is an AND of all the comparisons, so a wrong digit doesn't stop you typing the rest; the round just fails at the end.

## Pig

```text
"PIG to 100, h=hold"$0y!0s!1t!1("/M/J"$t@#32'y@#"+"$s@#32'0 0 1(;1+:5>(;0 0)1?:0=)104=%1+d!:0=(d@#0):s@&y@+y!d@1=|:(0s!t@1+t!0)0=(d@s@+s!0)y@100<)t@1-#" turns"$
```

The dice game Pig, solo: reach 100 in as few turns as you can. Each line shows the turn number, your banked score, the points riding on this turn, and the last roll. Any key rolls the die; a 1 loses the turn's points. Press h to bank them and end the turn. A common rule of thumb is to bank at about 20, but the end game is subtler.

- The die is the key wait itself. A count runs 0–5 and wraps until a key comes, so each roll depends on your timing to the millisecond.
- Holding banks the turn with `s@&`, a branchless "add s if h was pressed". Holding and rolling a 1 share one end-of-turn branch.

## Tron

```text
"/[[2J"$1024_g!0 1(:g@+0%.1+:1024<);520i!0d!0t!1(40?:46=%44=-d@%- 3&:d!:1&63*1+%2&1%-*i@+1023&:i!:64/27'91'%1+#59'1+#72'79'g@+:,%1%.t@1+t!0=)"/[[18Hscore "$t@#
```

A light cycle that never stops, leaving a wall behind it. `,` turns left and `.` turns right. Run into the wall, anywhere along it, and you're done. The arena is 64 × 16 and wraps at the edges, so the danger is only ever the trail. Survive as long as you can.

- The arena is a 1024-byte map in the heap, cleared at the start. Position `i` is one number, so one `1023&` both wraps the edges and keeps the index in the map.
- The direction `d` is 0–3, and a turn is `d ± 1` masked with `3&`. The step comes from `d` with no table: `(d&1)·63 + 1` is 1 or 64, and `1 − (d&2)` gives the sign.
- Drawing is `ESC [ row ; col H` then `O`, with row and column from one `64/`.
- The crash test reads the cell and marks it in one go: `g@+:,%1%.` leaves the old value, nonzero if you had been there.

## Lights Out

```text
"LIGHTS OUT"$[F:,1^%.][T:F:1-F:1+F:6-F6+F][Q5/%6*+g@+6+]50_g!42 1(1-:g@+1%.:);0 1(0s!0 1(:5/%;0=(13'10'0)::Q,:s@+s!32*- 97+'1+:25<);s@0=\0?1- 31&QT1+1)" in "$#
```

The classic 5 × 5 puzzle. Each cell is labelled with its key, a to y: an upper-case letter is a light that's on, lower case is off. Pressing a cell toggles it and its four neighbours. Turn every light off. It starts with all 25 on, the famous hard start, whose best solution takes 15 presses. Upper-case keys work too.

This is the deepest game here. The puzzle is linear algebra over GF(2): the order of presses doesn't matter, pressing twice undoes a press, and the 5 × 5 board has 2 hidden null patterns, so only a quarter of all boards can be solved at all. The way most people learn to solve it is "chasing the lights": clear each row by pressing the cells below its lit ones, then the lights left on the bottom row tell you which top-row presses to start with.

- The board is a 7 × 6 byte grid: 5 × 5 cells with a dead column on the right and dead rows above and below. Every neighbour of a real cell is then just ±1 or ±6, with no edge tests. The column on the right does double duty as the left border of the next row.
- `F` flips one byte, `T` flips a cell and its four neighbours, and `Q` turns a cell number 0–24 into an address.
- The case of each letter is `32*-`: the cell's 0 or 1 times 32, taken off the lower-case letter.
- A count of lit cells, made while drawing, is the win test.
- `1- 31&` keeps every key inside the grid's 50 bytes, so a stray key can never write over the program. Most other keys just land on a cell or on the border, but z to `~`, Z to `^` and `:` to `>` land on the dead row below and toggle one bottom-row cell alone. That's a cheat, left in rather than spending characters to block it.

## More ideas

Ones that look like they fit, roughly in order of promise:

- **Nim 3-5-7 with a perfect opponent.** Three heaps; the computer computes the nim-sum (XOR) and always moves to 0 when it can. The heaps can be fixed at 3, 5 and 7, which needs no randomness, but by my estimate the XOR search puts it about 30 characters over.
- **Bagels (Fermi/Pico).** Guess a 3-digit code and learn how many digits are in the right place. Simon's replay trick stores the code for free.
- **Hamurabi in a tweet.** One decision a year, how much grain to feed. People = food ÷ 20, the rest is planted with a random yield. It's a real trade-off between growth and seed. My estimate is about 160, so it may just fit.
- **Hurkle.** Hi-Lo in 2D on a 10 × 10 grid, with hints like "NE".
- **A one-key game.** Flappy-style: one key gives a lift, against gravity and gaps in a scrolling wall, using Ski's renderer.

Out of reach at 160: Snake (the growing tail needs a ring buffer of positions, about 70 characters more than Tron), Tron against a computer opponent, and full Mastermind (the white-peg count is the expensive part).
