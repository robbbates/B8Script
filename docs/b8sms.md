# B8SMS and tweet games

Thirty-one B8Script games, in three sizes, and one that runs over:

- **B8SMS**: 160 characters or fewer, the length of a text message. Ten games.
- **Tweet 140**: the classic tweet. The same ten games, cut down.
- **Tweet 280**: the tweet since 2017. Eleven more games that need the room.

Each one is a complete program, with no line breaks and nothing left out. Paste it into a runner and play.

The files are in `games/` (at the root of the repository): [`b8sms/`](../games/b8sms/), [`tweet140/`](../games/tweet140/) and [`tweet280/`](../games/tweet280/), plus [`longer/`](../games/longer/) for one over the limit. `test_tweets.py` in `testing/` checks each folder's limit and plays every game with scripted keys on the checked reference interpreter; `test_tweets.py --all` adds the check that Tic-tac-toe never loses, which plays all 201 legal games against it. All of them were developed and tested on `ref.py`. `gamecheck.py`, which compares the CPU builds with it, covers only `games/*.B8S`.

| Game | SMS | 140 | Kind | You press |
|---|---|---|---|---|
| [Hi-Lo](#hi-lo) | 158 | 139 | Guessing | Digits, Return |
| [Lander](#lander) | 139 | 125 | Physics, turn by turn | 0–9 |
| [Nim](#nim) | 155 | 137 | Strategy against a perfect opponent | 1–3 |
| [Reflex](#reflex) | 150 | 138 | Reaction time | Any key |
| [Ski](#ski) | 158 | 137 | Real-time scroller | j, l |
| [Rock Paper Scissors](#rock-paper-scissors) | 153 | 137 | Against an AI that learns | 1–3 |
| [Simon](#simon) | 157 | 138 | Memory | Digits |
| [Pig](#pig) | 150 | 132 | Push your luck | h, any key |
| [Tron](#tron) | 139 | 128 | Real-time, 2D | `,` and `.` |
| [Lights Out](#lights-out) | 159 | 139 | Puzzle | a–y |

| Game | 280 | Kind | You press |
|---|---|---|---|
| [Snake](#snake) | 256 | Real-time, 2D | `,` and `.` |
| [Mastermind](#mastermind) | 271 | Deduction | Four digits, Return |
| [Nim 3-5-7](#nim-3-5-7) | 273 | Strategy against a perfect opponent | Heap, then count |
| [Duel](#duel) | 236 | Real-time, against the computer | `,` and `.` |
| [Kingdom](#kingdom) | 267 | Economic strategy | A number, Return |
| [Tic-tac-toe](#tic-tac-toe) | 277 | Against an unbeatable opponent | 1–9 |
| [Blackjack](#blackjack) | 276 | Cards | h, any key |
| [Copter](#copter) | 243 | Real-time, one key | Any key |
| [Breakout](#breakout) | 265 | Real-time arcade | j, l |
| [Hangman](#hangman) | 268 | Words | Letters |
| [Maze](#maze) | 258 | A new maze every game | i j k l |

Ski, Tron, Snake, Duel, Copter and Breakout are real-time. Tron, Snake, Duel, Breakout and Maze clear the screen with `/{` and draw with the cursor escape `/~`, MINE390 redraws its board from the top left with `/~`, and Simon clears its line with `/}`, so those need a console that does the screen escapes (see [The console](b8script.md#the-console)). The rest are plain teletype games.

## The tricks that make them fit

These come up again and again.

- **Randomness from the player.** No machine has a clock B8Script can read, but a person can't time a key to the millisecond. `0 1(1+1?0=)` counts while it waits for a key, and the count is the seed. Pig rolls its die this way on every key (the count runs 0–5 and wraps), so every roll is fresh.
- **A generator you can replay.** `r@75*74+:r!256/;` is a linear congruential generator; its high byte is usable, but its low bit never changes, so the code always takes the high byte. Set `r` to the same seed and you get the same numbers again. Simon uses this to store nothing: it replays the sequence to show it, and again to check your answer.
- **The stack as a variable.** A counter that lives on the stack under a loop costs one character to update (`1-`), where a variable costs six (`t@1-t!`). Hi-Lo's tries, Reflex's rounds and Lights Out's move count all live there.
- **Flags are −1.** A true flag is all ones, so it is arithmetic. `:106=%108=-` turns the keys j and l into −1 and +1 with no branch. `flag 32&` is 32 or nothing, which is how Lights Out picks upper or lower case.
- **Numbers inside the string.** `/h` in a string prints the variable h as `#` would, so Lander's status line is one string, `"/M/Jh/h v/v f/f ?"$`, with no `#` at all. It prints the value the variable has when the string is printed; a number worked out on the stack still needs `#`.
- **The cursor place comes off the stack.** `/~` takes a row and a column, both from 0, from under the string's address, and a map index divided by the map's width leaves just those two, quotient then remainder. So `:64/"/~O"$` draws Tron's bike at its place in a 64-wide map. Snake and Duel do the same, Breakout divides by 32, and Maze by 41.
- **Pick the string, then print it.** `" CRASH"%5<(;" LANDED"0)$` pushes one message, swaps in the other if needed, and prints whichever is left: an if-else with one `$`.
- **Padding instead of edge tests.** Lights Out's grid has a dead border, as Conway's Life does in the spec, so pressing a corner toggles border cells that are never shown. Tron goes the other way: its arena is a torus, so `1023&` is the only bounds check it needs.
- **`1:(` is a value and a true flag.** `(` needs a flag, and a nonzero count is one, so `4:(` starts a loop with 4 on the stack in three characters. Tic-tac-toe uses it three times.
- **Allocate and clear in one go.** `0_g!` notes the heap top, then `1024 1(0 1_.1-:)` allocates one byte at a time and stores a 0 in each. That is cheaper than allocating the block and clearing it with an index. Tron, Snake, Duel, Breakout and Lights Out use it.
- **An unsigned bounds test.** `32767&30<` is true only for 0–29: masking turns a negative number into a large positive one. Breakout clamps its paddle with it, one test instead of two.
- **Watch the minus sign.** `1-3&` is 1 and then −3. It got into nine of these thirty-one games, twelve times in all, and it is easy to miss on review: `0>-10*` looks like "negate, times ten" and is really "push −10". The fix is a space, `1- 3&`. A search of the code outside strings for a minus before a digit finds every case, and each one is either meant or a bug. The stripper (`b8strip.py`) keeps exactly the spaces B8Script needs, and every game here is already in its stripped form.

## B8SMS: 160 characters

### Hi-Lo

```text
[N0 1(0?:13=\:'48-%10*+1);]"Key=go. 0-127, 7 tries"$0 1(1+127&1?0=)s!7 1(13'10'N:g!s@<(" up"$0)g@s@>(" down"$0)1-:0>g@s@=0=&);g@s@=:(" WIN"$0)0=(" LOSE /s"$0)
```

Press a key to start, then type guesses and press Return. The number is 0–127 and you get 7 tries, and 2⁷ = 128, so a perfect binary search always wins and one wasted guess can lose. That makes it a game rather than a quiz.

- `N` reads a number from the keys, echoing digits but not the Return, so the hint lands on the same line.
- The seed loop masks with `127&` as it counts, so the secret is in range with no division.
- The tries counter lives on the stack; the loop runs while tries are left and the guess is wrong.

### Lander

```text
"LANDER burn 0-9, land under 5"$1000h!0v!99f!1("/M/Jh/h v/v f/f ?"$0?15&:f@>(;f@0):f@%-f!v@%- 3+v!h@v@-h!h@0>)v@:#" CRASH"%5<(;" LANDED"0)$
```

You start at height 1000 with no speed and 99 fuel. Each turn press 0–9 to burn that much fuel. Gravity adds 3 to your downward speed and a burn takes it off. Touch down at under 5 to land.

The numbers are tuned so the classic trick, a **suicide burn**, is needed: the least fuel that can land at under 5 is 89, so 99 leaves almost no slack. Fall freely for about 20 turns, then burn hard and feather the last few turns. A search over every burn sequence found landings at speed 1.

- `0?15&` maps the digit keys to 0–9 with no subtraction (and space to 0).
- The burn is capped at the fuel left with `:f@>(;f@0)`.

### Nim

```text
"NIM take 1-3, last loses. Key"$0 1(1+1?0=)7&20+n!1("/M/J/n take "$0?:'3&:0=-n@%-:n!1<:(" you lose"$0)\" I take "$n@1- 4/%;:0=-:#n@%-:n!1<:(" I lose"$0)0=)
```

Press a key to start: there are 20 to 27 sticks. You and the computer take 1–3 in turn, and whoever takes the last stick loses. The computer plays perfectly. It always tries to leave a number that is 1 more than a multiple of 4, so it takes (n − 1) mod 4, or 1 when that is 0. You can beat it only by finding that rule and getting there first, and on 2 starts in 8 (21 and 25) the position is already lost.

- `3&:0=-` turns any key into 1–3: the low two bits, with 0 bumped to 1.
- `1<:( message 0)\` prints the message and leaves the main loop in one go.

### Reflex

```text
[W0 1(1+1?0=)]"REFLEX: 5 rounds, hit a key at GO. Key"$Wt!0s!5 1("/M/Jwait.."$t@2047&999+?:{(" early"$999 0)}0=(" GO! "$W:#0):t!s@+s!1-:);" total /s"$
```

Five rounds. After a random pause it says GO!, and you hit a key as fast as you can. Pressing during the pause costs 999. Lowest total wins.

- `W` counts while waiting for a key. It both times you and, at the start, seeds the first pause. Each pause is your last time, masked and offset, so it is different every round.
- The pause is one `n?`. If it returns a key, you jumped early.
- The score is in polls of `1?`, roughly milliseconds on most machines but not all: the spec notes that the shortest wait is about 15.6 ms on Windows without a high-resolution timer. Compare scores on the same machine.

### Ski

```text
"SKI j l/M/J"$[S1(:1<\32'1- 1);]5q!9p!0t!0r!1(r@75*74+:r!:0<%256/;31&p@<%-:p@+p!99?:r@+r!:106=%108=-%-q@+:q!:0>%9<&0=\p@S"|"$q@1-S"V"$8q@-S"|/M/J"$t@1+t!1)t@#
```

A slalom course scrolls up past your skier, `V`. Steer with j and l to stay between the poles. The score is the number of lines you survive.

- The course wanders by −1, 0 or +1 a line. It is the difference of two random bits, one of them more likely to be set the further right the course is, so it drifts back toward the middle and never leaves the screen. No clamping code needed.
- The skier is kept as `q`, its place relative to the left pole, so a crash is just `q` outside 1–8 and a line is always three runs of spaces.
- Every key you press is added into the random state, so your steering changes the course to come.
- One frame is one `99?`, about 10 lines a second. Make the number bigger to slow it down, smaller to speed it up.

### Rock Paper Scissors

```text
"ROCK PAPER SCISSORS 1 2 3, to +-5"$9_t!0i!0s!1("/M/J? "$t@i@+:,1+3/%;c!0?1- 3&:p!%."RPS":p@+,'c@+,'32'i@3*p@+9/%;i!p@c@- 3+3/%;:1=%2=-s@%-:s!:#:5<%-5>&)
```

Press 1, 2 or 3 for rock, paper or scissors. Each line shows your move, the computer's, and the score. First to +5 or −5.

The computer learns. It keeps a 9-entry table indexed by your last two moves, holding what you played the last time that pair came up. It predicts you'll do it again and plays what beats that. People are bad at being random, so it catches patterns fast: it beats the cycle 1 2 3 by −5 after 9 rounds. To beat it, you have to model its model.

- The table is 9 bytes of heap and is never cleared. Whatever was in memory just becomes its first guesses, and `3/%;` brings any byte into range.
- The history index is `(i·3 + p) mod 9`, an order-2 Markov context in eight characters.
- The result is `(p − c) mod 3`: 0 tie, 1 you win, 2 it wins. `:1=%2=-` turns that into the score change without a branch.

### Simon

```text
[Dr@75*74+:r!256/;7&49+]"SIMON repeat the digits. Key"$0 1(1+1?0=)s!1n!1("/M/J"$s@r!n@1(D'1-:);999?;"/M/}"$s@r!-1n@1(%0?:'D=&%1-:);:(n@1+n!0))" score "$n@1-#
```

A string of digits flashes for a second and is wiped. Type it back. Each round adds a digit. One mistake and the game is over.

It stores no sequence at all. The digits are generator output from a fixed seed, so resetting `r` to the seed replays them: once to show them, and again to check what you type. The sequence is unlimited and costs no memory.

- `"/M/}"` goes back to the start of the line and clears it, hiding the digits.
- The check is an AND of all the comparisons, so a wrong digit doesn't stop you typing the rest; the round just fails at the end.

### Pig

```text
"PIG to 100, h=hold"$0y!0s!1t!1("/M/J/t /y+/s "$0 0 1(;1+:5>(;0 0)1?:0=)104=%1+d!:0=(d@#0):s@&y@+y!d@1=|:(0s!t@1+t!0)0=(d@s@+s!0)y@100<)t@1-#" turns"$
```

The dice game Pig, solo: reach 100 in as few turns as you can. Each line shows the turn number, your banked score, the points riding on this turn, and the last roll. Any key rolls the die; a 1 loses the turn's points. Press h to bank them and end the turn. A common rule of thumb is to bank at about 20, but the end game is subtler.

- The die is the key wait itself. A count runs 0–5 and wraps until a key comes, so each roll depends on your timing to the millisecond.
- Holding banks the turn with `s@&`, a branchless "add s if h was pressed". Holding and rolling a 1 share one end-of-turn branch.

### Tron

```text
"/{"$1024_g!0 1(:g@+0%.1+:1024<);520i!0d!0t!1(99?:46=%44=-d@%- 3&:d!:1&63*1+%2&1%-*i@+1023&:i!:64/"/~O"$g@+:,%1%.t@1+t!0=)17 0"/~score /t"$
```

A light cycle that never stops, leaving a wall behind it. `,` turns left and `.` turns right. Run into the wall, anywhere along it, and you're done. The arena is 64 × 16 and wraps at the edges, so the danger is only ever the trail. Survive as long as you can.

- The arena is a 1024-byte map in the heap, cleared at the start. Position `i` is one number, so one `1023&` both wraps the edges and keeps the index in the map.
- The direction `d` is 0–3, and a turn is `d ± 1` masked with `3&`. The step comes from `d` with no table: `(d&1)·63 + 1` is 1 or 64, and `1 − (d&2)` gives the sign.
- Drawing is one string, `"/~O"`: one `64/` leaves the row and the column, and `/~` takes them.
- The crash test reads the cell and marks it in one go: `g@+:,%1%.` leaves the old value, nonzero if you had been there.

### Lights Out

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

## Tweet 140

The same ten games, each cut by 11 to 21 characters. Most of the savings repeat:

- **Titles shrink to a name and the keys.** The rules move here, into the doc.
- **Counters move to the stack.** Ski's score, Nim's stick count, Pig's turn count and Tron's score each lose a variable.
- **Messages become symbols.** Hi-Lo answers `64>` and `4=` instead of "down" and "WIN": the sign of the guess minus the secret, plus 61, is one of `<`, `=` and `>`, so the hint is three characters of arithmetic with no branch.
- **Allocate-and-clear** replaces the clearing loops in Tron and Lights Out.

What the cuts cost:

- Pig no longer shows the turn number on each line, only at the end.
- Ski shows no title.

The files are in [`games/tweet140/`](../games/tweet140/).

```text
[N0 1(0?:13=\:'48-%10*+1);]"0-127, 7 tries. Key"$0 1(1+127&1?0=)s!7 1(13'10'N:g!s@-:0<%0>- 61+'1-:0>g@s@-&);g@s@-:(" was /s"$0)0=(" WIN"$0)
```

That is Hi-Lo, at 139.

## Tweet 280

Eleven games that don't fit in 160, several of them ones I had called out of reach.

### Snake

```text
"/{"$0_g!1024 1(0 1_.1-:);1023m![P64/"/~"$][Rr@75*74+:r!64/;m@&][F0 1(;R:g@+,):g@+128%.P"*"$][D:1&63*1+%2&1%-*]0r!0i!0j!0d!0l!F1(99?R;:46=%44=-d@%- 3&:d!1+i@g@+.d@Di@+m@&:i!g@+,:7&\:(l@1+l!F0)0=(j@:P32':g@+:,1-D%0%.+m@&j!0)i@:g@+1%.P79'1);17 0"/~score /l"$
```

Steer with `,` and `.`, eat the `*`, and don't bite yourself. The board is 64 × 16 and wraps at the edges, like Tron's. The score is your length.

- **The tail follows a trail, not a history.** The usual snake keeps a list of every position so it knows where the tail is. This one stores, in each cell the head leaves, the direction it left by (1–4). The tail reads its own cell, clears it and steps the same way, so the body is its own linked list. That dropped a 2 KB buffer and about 20 characters.
- Food is 128, so `7&` tests "body" (1–4) and leaves food (128) and empty (0) to the next test.
- The generator is stepped every frame (`R;`), so where the next food lands depends on when you ate.

### Mastermind

```text
[Rr@75*74+:r!256/;255&]"MASTERMIND: 4 digits 1-6, 10 tries. Key"$0 1(1+1?0=)r!5_s!4_c!4 1(1-:s@+R6/%;49+%.:);34s@4+.10 1("/M/J"$-4?a!s@@c@!s@2+@c@2+!0b!4 1(1-:s@+,{:}%a@+,=b@%-b!:);0w!4 1(1-:a@+,v!4 1(1-:c@+:,:v@=:w@%-w!:{0=&%.}\:);:);" /bB"$w@b@-#"W"$1-:0>b@4<&);" "$s@$
```

Type four digits from 1 to 6 and press Return. B is the number in the right place, W the number of right digits in the wrong place. Repeats are allowed in the code and in guesses. The code is shown at the end.

- Whites are the hard part. A copy of the code is taken with two cell moves (`s@@c@!s@2+@c@2+!`). Then each guess digit crosses off the first equal digit in the copy. Every match counts, and W is matches minus B.
- The crossing-off is branchless: the copy's byte is ANDed with "not equal", so a match writes 0, and the same flag breaks the inner loop.
- The code is stored with a `"` after it, so `s@$` prints it as a string.

### Nim 3-5-7

```text
[X0x!0y!3 1(:h@+,:x@^x!y@+y!1-:);]"NIM 3-5-7: heap 1-3, then how many. Last stick wins"$4_h!3h@1+.5h@2+.7h@3+.1("/M/J"$1 1(:h@+,#32'1+:4<);"? "$0?:'3&:0=-h@+:,0?:'15&:0=--:0<(;0 0)%.Xy@0=:(" you win"$0)\X3 1(:h@+,:x@^x@0=+:t!>t@-1>&:{(:t@%h@+.0)}\1-:);Xy@0=:(" I win"$0)0=)
```

Three heaps of 3, 5 and 7. Press a heap (1–3), then how many to take. Whoever takes the last stick wins. The computer plays perfectly. 3 XOR 5 XOR 7 = 1, so you, moving first, can win, but only if every move you make leaves the XOR of the heaps at 0. One slip and it never gives the game back.

- `X` works out the XOR and the sum of the heaps in one loop.
- **The whole strategy is one expression.** For each heap, the target size is `(heap XOR x) + (x = 0)`. When x isn't 0, that is the classic winning reply. When x is 0 (a lost position), the flag adds −1, so it takes one stick and plays on. A move is legal when the target is below the heap and not negative.

### Duel

```text
"/{"$0_g!1024 1(0 1_.1-:);[D:1&63*1+%2&1%-*][S{D+1023&:64/"/~"$}':g@+:,%1%.][ADj@+1023&g@+,]520i!0d!556j!2e!1(99?:46=%44=-d@%- 3&:d!i@%79S%i!p!e@A(e@1+3&e!0)e@A(e@2+3&e!0)j@e@88S%j!q!p@q@|0=)17 0"/~"$" WIN"p@(;" LOSE"0)q@p@&(;" DRAW"0)$
```

Tron for two: you are `O`, the computer is `X`, and you start facing each other. Last one moving wins.

- The computer looks one cell ahead. If it is blocked, it turns right, and if that is blocked too, it turns the other way. It never drives into a wall it can see, so you win by boxing it in. Against random keys it won 144 games in 150.
- `S` moves either bike, draws it and marks the map, so the two players share every line of code but the steering.

### Kingdom

```text
[N0 1(0?:13=\:'48-%10*+1);][M:g@>(;g@0)]"KINGDOM: eat 20, plant 10 each"$99p!4999g!0r!1y!1("/M/J/y: pop /p grain /g feed? "$N:r@+r!M:g@%-g!20/;:p@2/;<:q!\p@-:0>(2/;0)p@+p!p@10*M:999>(;999 0)r@75*74+:r!256/;3&1+:" yield "$1+#*g@+g!y@1+:y!11<)q@(;" Overthrown"$0)" /p"$
```

Hamurabi in a tweet. Each year, type how much grain to feed your people. Each person needs 20. Whatever is left is planted: each person can plant 10, on at most 999 acres, and each planted bushel returns 2–5. If fewer than half are fed, you are overthrown. Food beyond 20 a head draws newcomers: half the surplus in people. Score: your population after ten years.

The tension: people are labour, but the land caps the harvest at 999 acres, so more than about 100 people only eat. Feeding exactly 20 a head survives all ten years with a big stockpile; feeding extra from the start gets you overthrown by year 5. The winning plan is to hoard, then feed a surplus late for a population boom.

- The land cap is also what keeps grain under 32767, where a cell would wrap.
- Your typed numbers are mixed into the random state, so the harvests depend on how you rule.

### Tic-tac-toe

```text
[V:w@&=|][Ww!0 7V56V448V73V146V292V273V84V][Tm@e@m!e!][N2v!1::(:m@e@|&0=(:m@|m!m@W:0=(;v@{TN;0v@-T}v!0)%:m@^m!%:v@<(:v!{%;:}0);0):+:512<v@-1>&);v@:2<&v!][D1:(:73&(13'10'0)::m@&0>33&%e@&0>42&+46+':+:512<);]0e!16m!4:(D1 0?48-:(%:+%1-:);2/;e@|e!Nm@|:m!W\1-:)D" draw"%(;" I win"0)$
```

The computer can't be beaten. It is `O` and opens in the centre. You are `X`: press 1–9 for the cells, row by row from the top left. The best you can do is draw. Playing all 201 legal games against it gives 194 losses and 7 draws, and `test_tweets.py --all` checks that again.

- **A full game-tree search** (negamax) in about 110 characters. `N` tries every empty cell, and a move scores 1 if it wins on the spot. Otherwise it scores the negation of the opponent's best reply, found by swapping the two players (`T`) and calling `N` again. It stops searching a position as soon as it finds a winning move, which makes it about four times faster. The first reply takes up to about 30 seconds on a 4 MHz Z80.
- **The board is two 9-bit numbers**, one per player. A win is any of 8 line masks fully set, and `V` tests one mask, so the table is just `0 7V56V448V…`.
- The search's best move comes back on the stack, and its score in `v`. `v` is saved and restored around each recursive call, since a variable is shared by every level.
- **There is no code for a human win.** Against a perfect opponent it can't happen, so the game only checks its own lines. Opening in the centre also means a draw is simply "four rounds passed".
- A cell you take twice is yours twice. The game doesn't stop you, and it doesn't help you either.

### Blackjack

```text
[Rr@75*74+:r!256/;255&13/%;][CR:"A23456789TJQK"+,'1+:10>(;10 0)][HC%{:1=}|{+}][V{:12<}&10&+][S{:}%{:}%V][D0 0HH]"BLACKJACK. Key"$0 1(1+1?0=)r!100b!1("/M/J$/b You "$D1(S:32'#21<:(;" h?"$0?104=0):(;H-1 0))V:21>(;-1 0)" Me "$D1(S17<:(;H-1 0))V:32'#:21>(;0 0)-:0<%0>- 10*b@+:b!0>)
```

You start with $100 and bet $10 a hand. Press h to hit, any other key to stand. The dealer draws to 17. Ties push, and the game runs until you're broke.

- **A hand is two numbers on the stack:** the sum, counting aces as 1, and a flag for "has an ace". `H` deals a card into it. `V` turns it into the best total by adding 10 when there is an ace and the sum is under 12. That one rule is all the soft-hand logic.
- **Busts fold into one comparison.** A player bust becomes −1 and a dealer bust becomes 0, so the sign of player minus dealer is the result in every case, double busts included.

### Copter

```text
"COPTER: any key pushes left/M/J"$[S1(:1<\32'1- 1);]9p!56x!0v!0t!0r!1(r@75*74+:r!:0<%256/;31&p@<%-p@+p!12t@50/;-:5<(;5 0)w!99?:r@+r!(-4v!0)v@1+:3>(;3 0):v!x@+:x!4/;p@-:0>%w@<&0=\p@S"|"$x@4/;p@- 1-S"H"$p@w@+x@4/;- 1-S"|/M/J"$t@1+t!1)"score /t"$
```

The one-key game. A cave scrolls past, and gravity pulls your craft, `H`, to the right. Any key gives a push left. It has inertia, so you feather it rather than steer it. The cave narrows from 12 to 5 as you go.

- Position and speed are in quarter-columns, so the motion is smooth at whole-character resolution. Gravity adds 1 a frame up to 3, and a push sets the speed to −4.
- It is Ski's renderer and wandering course, with physics instead of steering. A simple pilot that pushes when it is right of centre and drifting right survives about 175 lines.

### Breakout

```text
[Z:@0%-%!]"/{"$0_g!736 1(0 1_.1-:);96 1(1-:32+:g@+1%.32/1+"/~#"$:);11:y!x!1d!-1e!0s!0p!1(250?:106=%108=-:+p@+:32767&30<(:p!0);19p@"/~  ====  "$y@x@"/~ "$x@1=x@32=|(dZ0)y@0=(eZ0)x@d@+x!y@e@+y!y@32*x@+1-g@+:,(:0%.eZs@1+s!0);x@p@- 2+4/;1=y@19=&(eZ0)y@x@"/~o"$y@20<)s@#
```

Three rows of 32 bricks; j and l move the paddle. Keep the ball in play. The score is the number of bricks broken.

- **The ball erases what it breaks.** A brick the ball hits isn't drawn over: the ball moves into its cell and reverses, and next frame the ball's old cell is wiped, brick and all.
- **The paddle erases its own trail.** It is drawn with two blanks on each side, as `"  ====  "`, and moves 2 a frame. It has to move faster than the ball, or the ball can outrun it, and a first version found that out.
- The paddle's place starts at 0 and steps by 2, so it stays even, 0 to 28, and one unsigned test, `32767&30<`, clamps both ends: a step left from 0 gives −2, which the mask turns into a large number.
- `Z` negates a variable in place: `dZ` and `eZ` are the bounces.
- A bot that predicts where the ball will land kept it in play for over 1100 frames and broke 41 bricks.

### Hangman

```text
"HANGMAN, 6 misses. Key"$0 1(1+1?0=)7&6*"STACKSBINARYMEMORYCURSORSYNTAXPARSERBUFFERKERNEL"+w!7_b!6 1(1-:b@+95%.:);34b@6+.0m!6u!1("/M/J"$b@$" /m ?"$0?95&c!0f!6 1(1-:w@+,c@=(:b@+:,95=u@+u!c@%.-1f!0):);f@0=(m@1+m!0)u@0>m@6<&)"/M/J"$w@6 1(%:,'1+%1-:);;" won"u@(;" lost"0)$
```

Guess the word a letter at a time; six misses and you lose. Eight six-letter words, all from the machine room: STACKS, BINARY, MEMORY, CURSOR, SYNTAX, PARSER, BUFFER, KERNEL.

- The words are one 48-character string, and word n starts at 6n. No separators or table are needed.
- The word as guessed so far is a 6-byte buffer of `_` with a `"` after it, so `b@$` prints it.
- A letter you already found counts as found again, at no cost. A wrong letter costs a miss every time, so don't repeat it.
- `95&` folds lower case to upper.

### Maze

```text
"MAZE ijkl. Key"$0 1(1+1?0=)r!0_g!0 1(:41/%;:39=3&%39<25&+10+1_.1+:779<);34 1_.1y!1(1x!1(y@41*x@+g@+:32%.y@1=x@37<r@75*74+:r!0<&|42&41-+32%.x@2+:x!38<)y@2+:y!18<)32g@697+."/{"$g@$79i!1(i@41/"/~@"$0?3&"Q'Oy"+,80-:i@+g@+,32=&i@41/"/~ "$i@+:i!697-)20 0"/~Out!"$
```

A new 19 × 9 maze every game. You are `@`, in the gap at the top right; get out through the gap at the bottom left. i, j, k and l move up, left, down and right.

- **Binary-tree generation.** Each cell opens one wall, north or east, at random. The top row can only open east and the right column only north, which joins everything into one tree. That is about 85 characters for a perfect maze: every cell reachable, by exactly one path.
- **The maze is a string.** It is built in a buffer of 41-byte rows: 39 maze characters, then CR and LF, with a `"` after the last row. So `g@$` prints the whole maze, and the same buffer is the wall map for moving: a step is allowed only onto a space.
- **One formula fills the buffer.** For column c, the character is `(c = 39)·3 + (c < 39)·25 + 10`: that gives `#` for the maze, CR at column 39, and LF at column 40. It is written with the allocate-and-store trick.
- **The keys are a table.** `key & 3` is 0–3 for l, i, j and k, so it indexes the string `"Q'Oy"`, whose characters minus 80 are the steps +1, −41, −1 and +41. A blocked move becomes a step of 0 (`32=&`), so moving and not moving are the same code.
- **The catch.** A binary-tree maze has a bias: from any cell, north or east is always open. So the way out is always a staircase down and left of the same length (54 steps), and the maze's difficulty is all in its dead ends. Starting at the top right is what makes it a maze at all: from the bottom left, "always go up or right" would walk straight out. A less biased algorithm, such as sidewinder, doesn't fit in what's left.

## Longer: MINE390

Minesweeper, with the flood fill that opens blank areas. It doesn't fit in 280, and is here as an example of what a little more room buys. It is 390 characters. The repository's own Minesweeper, `MINES.B8S`, is the full-size version.

```text
[O"012:<DEF"+,59-a@+][Ca!0 8 1(1-:O,16&{%}+%:);16/;][Ea!8 1(1-:O:,32|%.:);][D0:c!:"/~"$11 1(:g@+,32&(c@1+c!0):10/%;:9=(13'10'0):9<%0>&(:g@+:,32&:{(:C:0=(%:E%0)48+%;'0)}0=(;35'0)0)1+:89<);c@]"MINES: row, column. Key"$0 1(1+1?0=)r!0_g!0m!0 1(:10/:9<%0>&%:9<%0>&&:r@75*74+:r!7168&0=16&&%0=96&|:16=m@+m!1_.1+:100<);1(0 1(D:{=0=}%)m@78+=\0?48- 10*0?48-+g@+:,16&:q!\:,32|%.1)" WIN"q@(;;" BOOM"0)$
```

An 8 × 8 board with about one mine in eight. Type a row digit, then a column digit, both 1–8. A number is how many of the eight cells around it hold a mine. Open every safe cell to win.

- **The board is a 10 × 10 byte grid** with a border all round, so the eight neighbours of a cell are always at the same offsets (±1, ±9, ±10, ±11), and the index is just "row, column" as two decimal digits. Bit 16 is a mine, bit 32 is open, and the border is 96: open, but never shown or counted as a cell.
- **One allocate-and-store loop lays out the board**: the border, and the mines (one cell in eight, from three bits of the generator). It also counts the mines, for the win test.
- **Counts aren't stored.** `C` adds up the mine bits of the eight neighbours whenever a cell is drawn.
- **The flood fill is the display.** `D` draws the board, and whenever it draws an open cell with a count of 0, it opens all eight neighbours (`E`). It returns how many cells are open. The game redraws until that number stops changing, so you can watch the flood spread. A recursive fill would be shorter to write, but on a 64-cell board it can need about 130 return-stack entries, and real builds have about 110.

## More ideas

Most of the ideas from the first round became the 280 games: Nim 3-5-7, Hamurabi (Kingdom), the one-key game (Copter), and the three I had called out of reach at 160 (Snake, Tron against the computer, full Mastermind), and a maze. Ones still open:

- **Minesweeper at 280.** [MINE390](#longer-mine390) works at 390; getting it under 280 would take about 110 characters of new ideas.
- **Bagels (Fermi/Pico) at 160.** Guess a 3-digit code and learn how many digits are in the right place. Simon's replay trick stores the code for free.
- **Hurkle at 160.** Hi-Lo in 2D on a 10 × 10 grid, with hints like "NE".
- **2048, Battleship, Sokoban.** Probably over 280 each, but untried.
