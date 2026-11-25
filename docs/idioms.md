# B8Script Idioms, Tips and Tricks

## How to read this

This is a working collection of B8Script idioms, tips and tricks. It gathers the spec's Idioms and Tips with the tricks found in the tutorial, the size-contest games and the commented game sources. The source file is named for each idea that came from a program. The language itself is defined in [b8script.md](b8script.md).

- **Stack effects** are written `( before -- after )`, top of the stack on the right; `R:` marks the return stack.
- **Letters are examples.** Word and variable letters in an idiom are only what its source used; rename freely.
- **Flags** are −1 for true and 0 for false from comparisons, but `(`, `)` and `\` treat any nonzero value as true.
- **Hex** is written with an h (F000h); B8Script itself reads only decimal, so programs write 61440 or −4096.

## Stack

B8Script has only dup, drop and swap, so every other shuffle is built from those plus the return stack: park a value with `{`, work under it, bring it back with `}`.

| Name | Code | Effect |
| --- | --- | --- |
| over | `{:}%` | `( a b -- a b a )` |
| rot | `{%}%` | `( a b c -- b c a )` |
| -rot | `%{%}` | `( a b c -- c a b )` |
| nip | `%;` | `( a b -- b )` |
| tuck | `:{%}` | `( a b -- b a b )` |
| 2dup | `{:}%{:}%` | `( a b -- a b a b )` |
| 2drop | `;;` | `( a b -- )` |
| Copy the parked value | `}:{` | Like Forth's R@ |

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| Read-modify-write a cell | `:@ 10+ %!` | Keeps the address under the value; `%!` brings it back on top to store (SUPERTRK, LIGHTS) |
| Change a byte in place | `:,1+%.` | `( addr -- )` adds 1 to a byte (KLONDIKE, BATTLE) |
| Update and keep the new value | `:@ f@- :{ %! }` | Parks a copy of the result across the store (SUPERTRK) |
| Read and mark | `:,%1%.` | `( addr -- old )` leaves the old byte and sets it to 1 (TRON) |
| Store with the value pushed last | `1%.` | Address first, then value, then swap (LIFE, GREED) |
| One value into two variables | `11:y!x!` | Dup, then two stores: the ball starts at 11, 11 (BREAKOUT in tweet280) |
| Value and flag in one | `4:( ... 1-:)` | A nonzero count is already true, so `:` makes the loop flag (TICTAC) |
| Count up, print after | `0 1( ... 1+1)#` | The score sits under the loop; a `\` inside ends it (SKI) |
| Fold results under a loop | `0 0i! 1( ... \| i@1+:i! 16<)` | Start at 0 and OR each test in; start at −1 and AND for "all hold" (G2048, BATTLE, LIGHTS) |
| Dummy value for a retry loop | `0 1( ; try test)` | Each pass drops the last try; the accepted one is left (ROBOTS, the K word) |
| Park a copy across a call | `:{ ... S }` | One copy is used now, the parked one after S (G2048) |
| Fill a table from the stack | `27i! 1( i@2*t@+! i@1-:i! -1>)` | Push all the constants, then store them counting down (TETRIS) |
| Accumulate under an index | `6 1(:G@{%}%+%1+:14<);` | The sum rides under the index; `{%}%` (rot) brings it up to add (IDOL) |

## Arithmetic, comparisons and flags

True is all ones (−1), so a flag can be used as a mask, added, or multiplied without a branch.

| Name | Code | Effect |
| --- | --- | --- |
| Negate | `-1*` |  |
| Absolute value | `:0<(-1*0)` |  |
| Sign | `:0<%0>-` | −1, 0 or 1 |
| Min | `{:}%{:}%>(%0);` | `( a b -- min )` |
| Max | `{:}%{:}%<(%0);` | `( a b -- max )` |
| Quotient | `/;` | `( a b -- q )` |
| Remainder | `/%;` | `( a b -- r )`, with a's sign |
| Modulo word | `[M/%;]` | `( n d -- n mod d )` |
| Double | `:+` | Faster than `2*` everywhere |
| Halve, toward zero | `2/;` | Fast everywhere |
| Increment a variable | `[I:@1+%!]` | `xI` adds 1 to x |
| Flag to 1 or 0 | `0=1+` |  |
| Branchless select | `flag n&` | n if true, else 0 |
| Logical not | `0=` | Right for a flag or any value |
| Not equal, in a test | `-(` | a−b is nonzero exactly when a ≠ b; use `=0=` when you need a real flag |
| Both results of a divide | `i@40/ x! y!` | One division gives column and row |

Min and max work by copying both values, comparing, swapping when needed, and dropping the top one.

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| Cap or floor in place | `:120>(;120 0)`, `:0<(;0 0)`, `:1<(;1 0)` | If past the limit, drop the value and push the limit; the second number closes the block (IDOL, KLONDIKE, LANDER) |
| Default, then override | `-1 z@48> z@56<&( ; z@49- 0) z@119=( ; 7 0)` | Push the default; each matching test drops it and pushes its own value (KLONDIKE, SUPERTRK) |
| Count digits with flags | `1 z@9>- z@99>- z@999>- z@9999>-` | Each true flag is −1, so subtracting it adds one (G2048) |
| Count matches | `0 0i! 1( ... a@= - i@1+:i! 64<)` | The same subtract-the-flag trick tallies a loop (REVERSI) |
| Weighted score, no branches | `c@H 100&+ c@Q 3000&+ c@X 2000&-` | `flag n&` gives n or 0 to add or subtract (REVERSI, QUBIC) |
| Random tie-break | `8* 8R+` | Equal scores are ordered by chance; unequal ones never swap (REVERSI, QUBIC) |
| Keys to −1, 0, +1 | `:106=%108=-` | j gives −1, l gives +1, anything else 0 (SKI, BREAKOUT in tweet280); `:46=%44=-` gives −1 for `.` and +1 for `,`, to turn one way or the other (TRON, SNAKE, DUEL) |
| Bump 0 to 1 | `:0=-` | Adds 1 only when the value is 0 (NIM) |
| Positive modulo | `c@- 3+3/%;` | Add the modulus before the remainder so the dividend is positive (RPS) |
| Mod 3 compare to a score | `:1=%2=-` | 0, 1, 2 become 0, +1, −1 (RPS) |
| Wrap by mask | `j@1+63&j!`, `d@%- 3&:d!` | Power-of-two rings need no division, and negatives wrap too (IDOL, TRON) |
| The other side | `3z@-` | With sides 1 and 2 (REVERSI); `2f@+` turns a flag into player 1 or 2 (QUBIC) |
| Toggle a flag | `f@0=f!` or `o@~o!` | (QUBIC, TINYBAS) |
| Two-way range test | `c@47> c@58<&` | True for the digits 48–57 (most games) |
| One-test range | `32767&30<` | Masking makes a negative large, so one compare checks 0–29 (BREAKOUT, b8sms) |
| Unsigned compare | `32768^` on both sides, then `<` | Flipping both sign bits turns the signed compare unsigned (TINYBAS) |
| Numbers past 32767 | `y@9999>( y@10000-y! x@1+x! 0)` | Keep x×10000+y in two cells and carry (G2048, IDOL money) |
| Percentage in 16 bits | `s@5*7/;` | s×1000/1400 reduced so it never overflows (GREED) |
| Random pick that skips the current one | `63R:5G@<0=-` | Adds 1 to any roll at or above the current value (IDOL) |

## Bits, bytes and hex

There are no shift commands and no hex literals; these idioms make them from `:+`, `/` and masks.

| Name | Code | Effect |
| --- | --- | --- |
| Bitwise NOT | `~` or `-1^` |  |
| Set, clear, test bits | `m\|`, `m~&`, `m&` |  |
| Shift left | `:+` | Repeat for more places |
| Arithmetic shift right | `2/:0<&+` | Rounds down: −7 gives −4 |
| Logical shift right | `2/:0<&+32767&` | FFFFh gives 7FFFh |
| Low byte, high byte | `255&`, `256/;255&` |  |
| Hex digit | `[D:9>7&+48+']` | Prints a value of 0–15 as one digit |
| Print a cell in hex | `[H:-4096&4096/;15&D:3840&256/;D:240&16/;D15&D]` | Uses D; always four digits |
| Hex constant from text | `[P0%1(:,32\|48-:9>(39- 0):-16&\{%}%:+:+:+:++%1+1);;]` | `"F000"P` pushes F000h |
| Hex from the keyboard | `-8?P` | Uses P |
| Hex constant by bytes | `3_h!` once, then ``h@:`3412;@`` | Pushes 1234h with no parsing |

- **Why the shifts work.** `/` leaves the remainder with the dividend's sign, so adding a negative remainder turns truncation into rounding down.
- **Why D has no branch.** `9>` is all ones for A–F, so `7&` adds exactly the 7 that separates `9` from `A` in ASCII.
- **H's top nibble** divides to −8…−1 on negative cells, which is why it is masked again with `15&`.
- **P** folds case with `32|`, subtracts 39 more for `a`–`f`, and stops at the first value with a bit outside 0–15 (`-16&`). Parsing is slow, so keep the result in a variable inside loops.
- **The by-bytes form** writes bytes little-endian; the third byte takes the hex loader's RET, so any bit pattern is reachable, such as 8000h (`` `0080 ``).

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| Set or toggle a bit in a byte | `:,32\|%.`, `[F:,1^%.]` | Fetch, change, swap, store (MINE390, LIGHTS) |
| Count and flag in one byte | `16+` to mark; `,15>` and `,15&` to read | A mine adds 16; the low bits hold the neighbour count (MINES) |
| Fields in one byte | `5G@K3&`, `5G@K4/;3&` | Mask the low field; shift a higher one down with `4/;` first (IDOL) |
| Decimal-packed record | `k@100/;`, `k@10/;10M`, `k@10M` | One cell holds three digits of data (SUPERTRK) |
| Stored value plus 1 | `:1+` to store, `:1-` to print | Lets 0 mean "not yet known" (SUPERTRK) |
| Fold a key to lower or upper case | `0? 32\|`, `0?95&` | Set or clear bit 5 (KLONDIKE, HANGMAN) |
| Fold letters only | `0? :64>( 32\| 0)` | Leaves Return and the digits alone (BATTLE) |
| Digit key to its value | `0?15&` | The low nibble of 0–9 is the value (LANDER) |
| Any key to 1–3 | `0?:'3&:0=-` | Low two bits, with 0 bumped to 1 (NIM) |
| Opposite of a 0–3 direction | `2^` | XOR 2 swaps up and down, left and right (FIFTEEN) |
| Step from a 0–3 heading | `:1&63*1+%2&1%-*` | +1, +64, −1 or −64 on a 64-wide grid, with no table (TRON) |
| A bit and its neighbours | `b@7* 2/; 31&` | Three adjacent bits centred on b; the edges fall off by themselves (LIGHTS) |
| What changed | new `^` old | XOR with the last drawn copy leaves only the bits to redraw (LIGHTS) |
| Bit values from a string | ``"ABDHP`"+,64-`` | 1, 2, 4, 8, 16, 32 stored as printable letters (IDOL) |
| All bits of a mask set? | `[V:w@&=\|]` | `( flag mask -- flag' )` ORs in "every bit of mask is in w" (TICTAC) |
| Self-inverse scramble | XOR each byte with a seeded random stream | Running it again restores the data (IDOL save codes) |
| Rolling checksum | `0 0i! 1( 3* h@1032+i@+,+63& i@1+:i! 47<)` | c = 3c + byte, mod 64; any changed byte shows (IDOL) |

## Control flow

One pair of round brackets makes every structure: the flag before `(` decides whether to enter, the flag before `)` whether to go round again, and `\` leaves early when true.

| Structure | Code |
| --- | --- |
| If | `flag( body 0)` |
| Do-while | `1( body flag)` |
| While, test in the middle | `1( test 0=\ body 1)` |
| If-else | `:{( then 0)}0=( else 0)` |
| Guard clause | `[W cond\ rest]` |
| Halt | `1\` at the top level |
| Countdown on the stack | `10 1( :# 1-: );` |
| Quit on a key | `1( 1?113=\ ...frame... 1)` |

**Continue.** `skip\` ends this pass early and the outer loop goes on:

```text
1(
  1( part  skip\  rest 0)
cond)
```

**Return from inside a loop.** Record the flag as you break, then test it after the closer:

```text
[W 0q!
   1( ...  cond:q!\  ... 1)
   q@\
   ...after the loop...
]
```

**Switch, short.** Every case is tested, so bodies must leave the stack alone:

```text
v :1=( one   0)
  :2=( two   0)
  :3=( three 0)
;
```

**Switch, fast, with a default.** A match drops the value, runs its body, then breaks past the rest without testing them:

```text
v 1(
  :1=:( %; one   0)\
  :2=:( %; two   0)\
  :3=:( %; three 0)\
  ;        other
0)
```

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| Guard with an action | `p@0=:( "You have no potions."s! 0)\` | `:` makes two flags: `(` uses one to act, `\` the other to leave the word (DUNGEON, TRADER, IDOL) |
| Guard that returns a value | `a@,13=:(n@%0)\` | Puts the result under the flag inside the block, then leaves (IDOL) |
| Message, then leave the loop | `1<:(" you lose"$0)\` | The same shape at the top level (NIM) |
| Priority ladder | `q@-1>:( q@m! 0)\ k@-1>:( k@m! 0)\` | Take a win, else a block, else fall through (QUBIC) |
| If-else on a copied flag | `:( then 0)0=( else 0)` | The flag stays on the data stack, so the then-part must leave the stack as it found it (KLONDIKE, LIGHTS) |
| Else by NOT | `:( then 0)~( else 0)` | One byte shorter than `0=`; right only on a real −1/0 flag (SUPERTRK) |
| Choose, then act once | `" CRASH"%5<(;" LANDED"0)$` | Push one string, swap in the other if the test says so, print once (LANDER) |
| Choose one of three, print once | `" WIN"p@(;" LOSE"0)q@p@&(;" DRAW"0)$` | Each test that holds drops the message on the stack and pushes its own; one `$` prints what is left (DUEL in tweet280) |
| Last case takes the selector | `:1=( ... 0) :2=( ... 0) 5=( ... 0)` | Every case copies but the last, so nothing is left to drop (BATTLE, QUBIC) |
| Fast switch with its own break | `:16=:(;;+ 1 0)\` | The body drops flag and selector, works, and pushes 1 for the `\` (TINYBAS) |
| While, tested at both ends | `n@( body n@)` | Runs zero or more times with no break (TINYBAS) |
| Zero-or-more with a count | `1( :( body 0) 1-: 0>)` | The copied count is the if-flag (SUPERTRK) |
| The data is the loop flag | `1( 8R 8R C a! a@, )` | Repeat while the fetched byte is nonzero (SUPERTRK, CONNECT4) |
| Search, record, break | `-1j! ... 1( ... G:( i@j! 0)\ ... 1)` | j stays −1 if nothing is found (KLONDIKE) |
| Why the loop ended | `0q! 1( ... q@0=) q@1=( ... 0) q@2=( ... 0)` | One variable is both the loop test and the reason (IDOL, LIGHTS) |
| Check everything, decide at the end | `1n@1(%0?:'D=&%1-:);` | Each test is ANDed into one flag under the counter (SIMON) |
| Error code, not unwinding | `(2x!0) x@\` | Set a code, keep the stack balanced, and leave at the next `x@\` (TINYBAS) |
| Look for Ctrl-C every 16 passes | `k@1+:k!15&0=(1?3=(4x!0)0)` | A masked counter makes a one-in-16 test (TINYBAS) |
| Take Ctrl-C for yourself | `""134- 1%.` as the program's very first characters | Stores 1 in the break-off cell, so Ctrl-C reaches the program as key 3 instead of stopping it; two quick Ctrl-Cs still stop it. A string at the very start of a program lies 1 byte into the text, and the cell is offset 7Bh of the letter page, the page just below: 133 bytes before the text, on every build. The space keeps `-1` from reading as a negative number (TINYBAS) |
| Neighbourhood scan | `y@1-j! 1( x@1-i! 1( ... i@1+:i! x@2+<) j@1+:j! y@2+<)` | The 3×3 around x, y with no offset table (SUPERTRK) |

## Words and code as data

Executing `]` pops whatever address is on the return stack and jumps there, so code addresses can be stored, passed and run like any other value.

| Word | Code | Use |
| --- | --- | --- |
| Eval | `[X{]` | `"1 2+#]"X` runs a string that ends with `]` |
| Function in a variable | `[f 7#]` then `f@X` | The body's address goes straight into f |
| Anonymous block | `[ 7#]X` | Pushes code to hand to a word |
| Function from a string | `"7#]"f!` then `f@X` | Code built or chosen at run time |
| Here | `[L}:{]` | Pushes the address just after `L` |
| Goto | `[G};{]` | `L x! ... x@:G` loops back to the `x!` |
| Tail call | `f@G` | Jumps to f without returning here |
| Continue | `}:{G` | Restarts the current block |
| Exit the caller | `[E};]` | Returns from the word that called E |
| Run a typed line | `[X{] -72?:{1(:,13=\1+1)93%.}X` | Writes `]` over the CR, then runs the line |

- **Know your depth.** Inside a block the top of the return stack is the block's start, not a return address.
- **Strings hide brackets.** An eval string may hold brackets that look unbalanced, because the skipper steps over strings whole; it must still end with `]` and leave the return stack as its caller expects.

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| More than 26 words | `[Z:+z@+@{]`, `[P:+z@+!]`, then `[ body] nP` and `nZ` | A table of anonymous blocks: P files routine n, Z runs it, and the routine's own `]` returns to Z's caller (IDOL, about 80 routines) |
| Dispatch through a table | `[S B 4*z@+2+@{]` | Fetches a handler address and `{` it, so S's `]` jumps there (TINYBAS) |
| Handlers as strings | `"t@1+t! P]"128 4*z@+2+!` | A code string ending in `]` is stored in a table slot; `:` lets two slots share one (TINYBAS) |
| A state block instead of variables | `[G:+g@+]`, then `3G@` and `3G!` | Cell n of one block; saves letters and can be saved or cleared in a loop (IDOL) |
| Message as an address | `[Z 16 41Y $ E]`, `""Z` to clear | A word takes a string's address and prints it in a fixed place (KLONDIKE) |
| Pending message | `s@( s@$ 0) "/}"$ 0s!` | s holds a message address or 0; the draw prints it once (DUNGEON) |
| Output to screen or buffer | `[E o@0=:(%'0)\ o@. o@1+o!]` | o is 0 for the screen, or the address of the next byte (IDOL) |
| Save a variable around recursion | `v@{TN;0v@-T}v!` | The caller's value waits on the return stack (TICTAC) |
| Save the random state | `[Q r@{ ... }r!]` | A deterministic draw inside leaves the game's sequence untouched (IDOL) |
| Neighbour chain | `[T:F:1-F:1+F:6-F6+F]` | Copy the base before each call; the last call consumes it (LIGHTS) |
| One mover for two players | `[S{D+1023&:P}':g@+:,%1%.]` | Both players share every line but the steering (DUEL) |

## Memory and data layout

The 26 variables hold one cell each; anything bigger lives on the heap, reached through an address kept in a variable.

| Name | Code |
| --- | --- |
| Allocate n bytes | `n_a!` |
| Mark the heap | `0_m!` |
| Release to the mark | `m@0_-_;` |
| Clear n bytes at a | `0i! 1( 0a@i@+. i@1+:i! n@<)` |
| Address of cell i | `a@i@:++` then `@` or `!` |

- **Releasing works** because the mark minus the current top is negative, and `_` with a negative count moves the top down.
- **A block over 32767 bytes** takes two `_` calls.
- **Store before you read.** Variables start with garbage on unchecked builds.

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| Border ring | `100_b!` for an 8×8 board in 10×10 | Neighbours are fixed offsets and walks stop at the border, with no edge tests (REVERSI, MINES, BATTLE, LIFE, GREED, DUNGEON, MINE390) |
| A spare column | 9 columns for 7 cells | A step off the right edge lands on a dead cell, never the next row (CONNECT4) |
| Torus by mask | `1023&` after each step | A 64×16 grid that wraps with one AND (TRON) |
| Index to row and column | `[P 72/Y]` with `[Y"/~"$]` | One `/` gives row and column in the order `/~` takes them, so a board as wide as the screen needs no arithmetic at all (GREED; ROBOTS and BATTLE add offsets first) |
| Neighbour offsets as text | `"345EGWXY"+,70-`, `[O"012:<DEF"+,59-a@+]` | The offsets stored as characters plus a bias (MINES, MINE390) |
| Allocate and clear in one loop | `0_g!1024 1(0 1_.1-:);` | Takes the heap a byte at a time, storing 0 (TRON, SNAKE, DUEL) |
| Fixed-width records in a string | `"Sol     Vega    Rigel   "u!` and `%8*+` | The data stays in the program text (TRADER, IDOL, HANGMAN) |
| Several tables in one block | `996_v!`, then `v@356+`, `v@990+@` | One allocation for everything, addressed as v plus a constant (TINYBAS, IDOL) |
| Use the heap top without allocating | `0_:p!e!` | Memory above the top still belongs to the program (TINYBAS) |
| Stack in the heap | push `d@z@p@+! p@2+p!`, pop `p@2-:p! z@+@c!` | A flood fill with no recursion (MINES); TINYBAS keeps a byte stack the same way |
| Swap two buffers | `g@h@g!h!` | Double-buffering for Life (LIFE) |
| Shadow copy | Keep what the screen shows; draw only the cells that differ | Start it at an impossible value to force a full first draw (G2048, REVERSI, IDOL) |
| Compact in place | Read index i, write index k, with k never ahead of i | Packs and merges a row with no second buffer (G2048) |
| One routine, four directions | Rotate the board, slide one way, rotate back | (G2048) |
| Store the exponent | Tile 2048 is the byte 11 | Never overflows; the value is made only to print (G2048) |
| The body is its own list | Each cell the snake leaves holds the direction it left by | The tail follows the arrows; no history buffer (SNAKE) |
| Records with a length byte | `[Q h!p@ :@h@<( :2+,+ :@h@<)]` | Hop from record to record; a last line numbered 32767 ends every search (TINYBAS) |
| Overlap-safe move | Copy up when the destination is below the source, down otherwise | (TINYBAS U) |
| −1 means gone | `a@0<\` | Dead entries are skipped without a separate flag (ROBOTS, DUNGEON) |

## Strings and output

A string stays where it is in the program text: `"` pushes its address and `$` prints it, decoding `/` escapes: control codes, variables and the console escapes.

| Name | Code | Effect |
| --- | --- | --- |
| Print a string | `"Hi"$` |  |
| Comment | `"any text";` | A string whose address is dropped |
| New line | `13'10'`, or `/M/J` inside a string | CR LF |
| A slash | `//` | `"n/s/e/w"` would print n, then the variables s, e and w |
| A quote inside a string | `/"` |  |
| A variable inside the text | `"Day /d of /t./M/J"$` | Prints d and t as `#` would, read when the string is printed |
| ESC | `/[` | For a terminal's own sequences, beyond the console escapes |
| Print a number | `#` | Signed, with no space after |
| Trace a value | `:#" "$` | Prints the top, leaves it |

- **What a slash does.** Before a small letter it prints that variable; before `{` `}` `|` `` ` `` `~` it is a console escape (see Screen); before anything else it prints the character with bit 6 cleared: `/@` to `/_` give the control codes 00h–1Fh, and `//`, `/"` and the rest below 40h give themselves.
- **The variable escape is for plain variables.** `/x` prints the cell of x when the string is printed. An expression, an array cell or a value on the stack still needs `#` between two strings, and a string that is copied somewhere and printed later shows the value at that later time (IDOL keeps its message buffers free of escapes for this reason).
- **A string ending in a slash** must write `//`, or the slash escapes the closing quote. This applies to comments too.
- **Addresses print signed.** Anything above 7FFFh prints negative: F000h prints as −4096.

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| One character | `32'` | Three bytes against four for `" "$` (PIG, TRON, SNAKE) |
| Glyph by value | `".XO?+"w@+,'` | Index a string with `+,` and print (REVERSI, CONNECT4, LIFE, SUPERTRK) |
| Two-character glyphs | `2* " .[]##"+ :,' 1+,'` | A doubled index picks a pair (TETRIS) |
| Card faces | `"A23456789TJQK"+,'` | (KLONDIKE, BLACKJCK) |
| n spaces | `[S1(:1<\32'1- 1);]` | `( n -- )`, safe for 0 (SKI, COPTER, G2048) |
| n of any character | `[ %1(%:'%1-:);;]` | `( n c -- )` for borders and rules (IDOL) |
| Leading zeros | `y@:1000<("0"$0):100<("0"$0):10<("0"$0)#` | One zero for each power of ten the value is below (G2048, IDOL) |
| Exactly three digits | `[U :100/;48+' :10/;10M48+' 10M48+']` | No loop (SUPERTRK) |
| Right-aligned | `[A 1-%:{:9>%:99>%:999>%9999>++++ 6%-"      "+$ }#]` | `( n w -- )` counts digits with flags and prints the tail of a string of six spaces (IDOL) |
| Digits without a buffer | `[N -1% 1(10/ 48+% :0=0=); 1(E :0<0=);]` | Stacks the digits above a −1 marker, then prints them back (IDOL) |
| Wipe old digits | `s@# " "$`, or `/}` after the number | A shorter number leaves nothing behind (KLONDIKE, BREAKOUT) |
| A live template | `"v/x;"g!`, then `1x! g@$ 2x! g@$` | The string's address is kept, and each `g@$` prints x as it is then: `v1;` and then `v2;`. The other side of the stored-message gotcha (tests.py) |
| Status line in one string | `"/~DUNGEON  Level /l  HP /h//20  Gold /g  Potions /p  Sword "$` | Placed, with four variables, in one `$`; `/h//20` prints h, then a slash (DUNGEON) |
| A buffer as a string | `34b@6+.`, then `b@$` | Store a quote after the text and `$` prints it (HANGMAN, MAZE, IDOL) |
| Rub out the last character | `8'32'8'` | BS, space, BS (TINYBAS) |
| Grid lines by parity | `j@2M( cell line 0) j@2M0=( border line 0)` | One modulo picks the line (FIFTEEN, G2048) |

## Input

`?` does every kind of input, chosen by its argument: 0 waits for a key, a positive n waits up to about n ms, and a negative n reads a line.

| Name | Code | Effect |
| --- | --- | --- |
| Wait for a key | `0?` | No echo |
| Look for a key | `1?` | 0 if none came |
| Read a number | `[N0v!1(0?:48<\48-:#v@10*+v!1);v@]` | Echoes digits; ends at any key below 0, such as CR |
| Read a line | `-72?a!` | The text at a ends with CR (13) |
| One character, confirmed | `-1?` | Typed, then CR |
| Quit on q | `1?113=\` | Inside a loop |

- **Use `0?` for keys and `-n?` for typed text**, which echoes and handles Backspace for you.
- **i j k l are the arrow keys.** On a keyboard they sit like the arrows (or like w a s d), and their codes, 105 to 108, run in a row, so arithmetic on the key can stand in for four tests. Their low two bits are 1, 2, 3 and 0, all different, so `3&` turns i, j, k, l into 1, 2, 3, 0, and a four-character string indexed with `+,` gives each one's step, stored as a printable character with a bias: in Maze `"Q'Oy"` less 80 is +1 for l, −41 (a row up, on a grid 41 wide) for i, −1 for j and +41 for k. Every other key also lands on one of the four, which Maze can allow because a wall stops a wrong step; mask or test the key first where a stray step would matter.
- **`1?` is a quick look, not a clock.** Each look can cost up to a millisecond, so in long computations look every few hundred steps.

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| Number reader with no variable | `[N0 1(0?:13=\:'48-%10*+1);]` | The total rides on the stack; Return ends it (HILO) |
| Number reader that ignores other keys | `[N 0n! 1( K c! c@47> c@58<&( c@' n@10*c@48-+n! 0) c@13= ~) n@]` | Only digits echo; K stirs the random seed while waiting (TRADER, SUPERTRK) |
| Number from a typed line | `[N -3?a! 0n! 1( a@,48- d! d@-1> d@10<& :( n@10*d@+n! a@1+a! 0) ) L n@]` | Walks the line until a non-digit (WUMPUS) |
| Two digits as an index | `0?48- 10*0?48-+g@+` | Row and column typed straight into a 10×10 grid (MINE390) |
| Key to a number by position | `"wasd"i@+, c@=` in a loop | The index where the key matches is the command (G2048, ROBOTS, FIFTEEN) |
| Keypad to a step | `v@1- 3/ 1-d! 1-o!` | Position 0–8 to dy and dx of −1…+1 (ROBOTS) |
| i j k l as arrow keys | `0?3&"Q'Oy"+,80-` | The step for a 41-wide grid: +1, −41, −1 or +41 (MAZE in tweet280). See below |
| j k l as −1, 0, +1 | `0?107-` | k is the middle letter, so subtracting its code leaves −1, 0 or +1; check the range (`:1+32767&3<`) unless every key may move. No game uses it yet: SKI uses the two-test form above |
| Ask until valid | `1( K 48- c! c@0> c@8<&:( ; c@F 0) 0= )` | A bad key leaves the false flag, so the loop asks again (CONNECT4, KLONDIKE) |
| Echo printable keys only | `:32>(:' 0)` | (KLONDIKE, WUMPUS, QUBIC) |
| Letter, then digit | Remember a letter key in l; a digit after it fires | Two-key commands like B7 (BATTLE) |
| A pause | `999?;` | About a second, cut short by a key (SIMON) |
| A random pause that spots a jumped start | `t@2047&999+?` | A key back means too early (REFLEX) |

## Screen

B8Script's screen commands are five escapes inside the strings that `$` prints. Each build turns them into ANSI sequences or the machine's own screen routines, so a program's screen code runs unchanged on every console.

| Name | Code | Effect |
| --- | --- | --- |
| Clear the screen | `"/{"$` | Clears it and homes the cursor (row 0, column 0) |
| Clear to the end of the line | `"/}"$` | The cursor stays put |
| Cursor to row, column | `r c"/~"$` | `( row col -- )`, both counted from 0 |
| Home the cursor | `0 0"/~"$` | Draw over the old picture without clearing it |
| Print at a place | `5 10"/~Hello"$` | The escape and the text in one string |
| Several places in one string | `3 0 1 0"/~Top/~Next"$` | Each `/~` takes the next pair, the first nearest the string |
| Hide the cursor | ``"/`"$`` | At the start of a game that redraws |
| Show the cursor | `"/\|"$` | Before the program ends |
| Cursor word | `[Y"/~"$]` | `( row col -- )`; `5 10Y"Hi"$` is one character shorter than `5 10"/~Hi"$`, so the word's 8 characters pay off after about eight places |

- **Counted from 0.** Row 0 is the top line and column 0 the left edge; on an 80 × 24 screen the last cell is row 23, column 79.
- **Order of the pairs.** `/~` takes the column from just under the string's address and the row from under that; a second `/~` takes the pair below those. So push the pairs for a string's places last first.
- **A program that hides the cursor must show it again** before it ends.
- **Draw to the edge with care.** What happens after the last column is implementation-defined; place the cursor yourself.
- **More than the escapes.** Colours and the like need a terminal's own sequences, sent with `/[` or `27'`; they work only on that kind of terminal.

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| Home, don't clear | `0 0"/~"$` at the top of the draw | Overwrites the old picture in place, with no flicker (LIFE, TETRIS, MINE390) |
| Index straight to the cursor | `[P64/"/~"$]` | `/` leaves the quotient (the row) under the remainder (the column): the order `/~` takes them in (SNAKE, TRON, DUEL, DUNGEON) |
| Cell to screen place | `[Q2*5+%4*29+Y]` | Scale and offset each half for Y (LIGHTS, BATTLE, G2048) |
| Clear, then draw | `"/{IDOL/M/J/M/J..."$` | The clear and the first text in one string (IDOL) |
| Clear and place in one string | `1 0"/{/~+"$` | Clears, then puts the frame's first corner at row 1 (IDOL) |
| Cursor back after drawing | `[Z p@P 64' p@P]` | Printing moves the cursor, so place it again (ROBOTS) |
| Redraw only what changed | Compare with a shadow copy, or XOR rows | After a move most of the screen is not sent again (IDOL, G2048, LIGHTS) |
| Erase, move, redraw | Rub everything out, move it all, draw it all | Movers never overwrite each other's new places (ROBOTS) |
| Sprites over a map | Draw the map, then place each live entity with the cursor | (DUNGEON) |
| Paddle that erases its trail | `"  ====  "$` | Blanks at both ends cover the last position (BREAKOUT) |
| Overwrite a line | `"/M/}"$` | CR then clear to the end of the line hides what was shown (SIMON) |
| Clear a panel | Print a row of spaces on each line | Clears part of the screen, not all of it (IDOL) |
| Status at the bottom | `17 0"/~score /l"$` | Place, label and value in one string (SNAKE, TRON) |
| Rows before the divide | `[P36+18/:+2+Y]`, `[P40+40/"/~"$]` | Adding k widths to an index before `/` adds k to the quotient (the row) and leaves the remainder (the column) alone, so a row offset costs nothing extra (MINES, DUNGEON, BATTLE, ROBOTS, REVERSI) |
| One row, two places | `i@4+:42%2"/~/i  . . . ./~/i  . . . ."$` | `:42%2` turns row r into `r 42 r 2`: column 2 for the first `/~`, column 42 for the second (BATTLE) |
| Both walls in one string | `j@49j@0"/~\|/~\|"$` | The left and right bars of a frame row with one `$` (BREAKOUT, ROBOTS) |
| Clear the line, put the border back | `%79"/}/~\|"$` | `/}` also erases the frame's right-hand bar, so a second `/~` in the same string redraws it (IDOL) |
| Clear a line and step in | `0 0Y"/} "$` | To the start of the line, clear it, and a space: the text starts at column 1 on a clean line (IDOL) |
| Zero a counter and home the cursor | `0:c!:"/~"$` | `0:` makes two zeros: one is stored in c, and `:` doubles the other into row 0, column 0 (MINE390) |
| Mark the map and draw from one index | `96 1(1-:32+:g@+1%.32/1+"/~#"$:);` | The bricks lie one map row down, so the same index marks the map byte and, through `32/`, gives the screen row and column (BREAKOUT in tweet280) |

## Random numbers

B8Script has no random command; the games carry a two-word kit: K seeds from how long the player takes to press a key, and R draws numbers from a linear congruential generator.

| Name | Code | Effect |
| --- | --- | --- |
| Seed from key timing | `0r! [K0 1(;r@1+r!1?:0=)]` | `( -- key )`: counts in r until a key comes |
| Random 0 to n−1 | `[Rr@75*74+:r!256/;255&%M]` | `( n -- r )`; needs M (BATTLE, MINES, TRADER and most games) |
| Random, other constants | `[Rr@25173*13849+:r!256/;255&%/%;]` | The same shape, with the remainder inline (IDOL) |
| A die | `6R1+` | 1 to 6 |

- **Use the high byte.** The low bits of a 16-bit LCG repeat quickly, so R takes `256/;255&` before the modulo.
- **Call K before the first R.** A title screen's "press a key" is the natural place; without a key wait the numbers come out the same every run.
- **Good enough for games only:** there are just 65,536 states.

## Game and real-time patterns

The games share a few shapes: a frame is one timed key wait, end conditions fold into the loop flag, and the computer player tries a move, tests it and takes it back.

| Name | Code | What it does |
| --- | --- | --- |
| Frame loop | `1( 20? c! c@( Y 0) n@1+:n! s@>( 0n! G 0) d@0=)` | Keys act at once; gravity every s+1 frames (TETRIS) |
| The wait is the frame | `99?` for about 10 steps a second, `20?` for 50 | The timed wait is also the input (README, all real-time games) |
| Speed from what's left | `b@24/;2+v!` | Fewer bricks, fewer frames per ball step (BREAKOUT) |
| All end conditions in the flag | `1( D K c! ... V h@0> c@113=~& )` | Go on while alive and the key wasn't q (DUNGEON) |
| Try, then commit | `[T X0=:( e@x! f@y! g@o! 0)]` | Test a candidate position, keep it only if it fits (TETRIS) |
| Hard drop | `1( x@e! y@1+f! o@g! U )` | Repeat the one-row move while it works (TETRIS) |
| Look again after a clear | `F:( ... 0)~( u@1-u! 0)` | Step up a row only when the row wasn't full (TETRIS) |
| Keep the best so far | `:e@>( :e! c@m! 0);` | Store the score and the move together (REVERSI, QUBIC) |
| Computer player | Place, test, take back; try for self, then for the opponent, else random | (CONNECT4, QUBIC) |
| Negamax | Swap players with T and call N; save shared variables on the return stack | About 110 characters for perfect tic-tac-toe (TICTAC) |
| Predict the player | `i@3*p@+9/%;` | Indexes what the player did last time after the same two moves (RPS) |
| A puzzle by playing it | Shuffle from solved with legal moves | Always solvable (FIFTEEN, LIGHTS) |
| Walk to a sentinel | `1( t@b@+,o@=0=\ t@d@+t! k@1+k! 1)` | Border bytes match nothing, so the walk stops at the edge (REVERSI) |
| Bounce | `d@-1*d!`, or `[Z:@0%-%!]` then `dZ` | Negate a velocity (BREAKOUT) |
| Smooth motion | `x@4/;` | Positions in quarter cells, drawn in whole ones (COPTER) |
| Capped gravity | `v@1+:3>(;3 0)` | Falling speeds up to a limit (COPTER) |
| Flood fill without recursion | Sweep until nothing changes, or keep an explicit stack | Recursion can pass the 64 return-stack entries every build guarantees (MINE390, MINES) |
| Catch up on arrival | Update a place from the day you last saw it | Nothing runs for places you aren't at (IDOL) |
| Play again | `K 121=)` | The outer loop's flag is whether the key was y (all) |

**From the programs**

| Name | Code | What it does |
| --- | --- | --- |
| Chances | `100R90>`, `4R0=`, `2R(` | 9 in 100, 1 in 4, a coin flip as its own flag (SUPERTRK, IDOL, DUNGEON) |
| 1 in 8 from high bits | `:r!7168&0=` | No modulo needed (MINE390) |
| −1 or +1 | `2R2*1-` | (BREAKOUT); `1 10R0=-` gives 1, or 2 one time in ten (G2048) |
| Wobble by a percentage | `21R10- *100/;+` | A value moves by −10 to +10 percent (IDOL) |
| 1 to n, other constants | `[Z s@25173*13849+:s! 16/;4095& %/%; 1+]` | Twelve bits from the middle of the state (TINYBAS) |
| Shuffle | `51i! 1( i@1+R j! i@d@+, j@d@+, i@d@+. j@d@+. i@1-:i! 0>)` | Fisher–Yates, swapping by fetching both bytes first (KLONDIKE) |
| Random empty cell | Count the empties, draw below the count, count down to it | Never loops forever on a full board (G2048, BATTLE) |
| Retry until empty | `1( 8R 8R C a! a@, )` | Simplest when the board is mostly empty (SUPERTRK) |
| Seed on the stack | `0 1(1+1?0=)7&20+n!` | The wait's count is the seed, masked into range (NIM, HILO) |
| Stir in the player | `99?:r@+r!` | Each frame's key goes into the state (SKI, KINGDOM) |
| Replay a sequence | `s@r!`, then the same draws | Store only the seed (SIMON) |
| A world from a seed | `[H 0G@+ 25173*13849+ r! 1R;]` | Names, prices and maps are drawn again from seed and place, not stored (IDOL) |
| Cheap sizes | `7&`, `31&`, `3&` on R's byte | Masks for power-of-two ranges skip the modulo (SIMON, BLACKJCK) |

## Machine code and the hex loader

The grave does two jobs: followed by a hex digit it loads bytes, followed by anything else it calls the code at the address on top.

| Name | Code | Effect |
| --- | --- | --- |
| Load (Z80, 8080) | ``8_:d! `D1E129E5D5 ;`` | Code that doubles TOS, kept at d |
| Call it | ``21 d@` #`` | Prints 42 |
| Build code over several lines | ``16_:x! `3E2A `3C ;`` | Each load overwrites the last RET |
| Binary data, zero bytes included | `3_h!` then ``h@:`3412;@`` | Strings hold text; the loader holds everything else |

- **Allocate one byte more than the code,** for the RET the loader writes after it.
- **Save the start first** with `:` or `{` before the first load, and drop the final address with `;`.
- **Space after a load** when a digit or A–F, a–f comes next, or the load swallows it; likewise a grave that should call must not be followed by a hex character (``x@` b@``).
- **Never checked.** The loader and the code it runs are the programmer's responsibility, even on checked builds; each CPU's appendix gives the calling contract.

## Making programs small and fast

Every character costs a byte of memory and a dispatch each time it runs, so the same choices make a program both smaller and faster.

| Tip | Example |
| --- | --- |
| Keep a counter on the stack | `1-` is 2 bytes; `t@1-t!` is 6 (b8sms) |
| Print one character with `'` | `32'` is 3 bytes; `" "$` is 4 |
| Put variables in the text | `"Day /d"$` is 9 bytes; `"Day "$d@#` is 10, and each further number saves 4 more (most games) |
| Place text with the escape, for a few places | `5 10"/~Hi"$` needs no word; past about eight places a cursor word `[Y"/~"$]` is shorter overall (IDOL keeps Y; MAZE and DUEL write the escape) |
| Let the value be the flag | `4:(` pushes a count and enters the loop (TICTAC) |
| Use `~` for an else on a real flag | One byte less than `0=` |
| Double with `:+`, halve with `2/;` | Both are fast; other multiplies and divides run the full routine |
| Take both results of `/` | One division gives row and column |
| Keep hot constants in variables | A literal is read digit by digit each time it runs; `m@` is one fetch |
| Keep comments out of hot code | A comment is a string that is skipped each pass; put notes before the word (all games) |
| Strip finished programs | Keep only the spaces that separate: `12 34`, `5- 3`, `0 1(`, `1 1_.`, a load before a hex character (`b8strip.py`) |
| Tables beat if-chains | One multiply and fetch decide a character's class (TINYBAS) |
| Store data as biased text | `"BCDLNVWX"+,77-` is shorter than code that builds the table |
| Derive, don't store | Names, prices and maps redrawn from a seed shrink both memory and save codes (IDOL) |
| Fast path first | Print to the screen with one `$`; copy a byte at a time only into a buffer (IDOL) |
| Spend letters on the hot words | Rarely used routines go in a numbered table (IDOL) |
| Push the identity before a fold | Start at 0 for OR or −1 for AND under the loop, so no result variable is needed (G2048, LIGHTS) |

## Gotchas

The minus before a digit is the one that bites most: it got into 9 of the 31 small games, 12 times.

| Gotcha | What to do |
| --- | --- |
| `5-3` pushes 5 and −3 | Write `5- 3`; it applies after any operator, so `0>-10*` pushes −10. Search outside strings for `-` before a digit |
| `39-0)` is 39, −0, close | Write `39- 0)` |
| Variables start with garbage | Store before you read; a checked build hides this by zeroing them |
| `x#` prints an address | You meant `x@#` (tutorial) |
| `{` and `}` unpaired inside a block | `)` jumps to whatever is on top of the return stack |
| Deep recursion | Every build holds 64 return-stack entries and 64 data cells; most hold more, but don't count on it. Loop or tail-call with G instead (TICTAC's perfect play peaks at 43 entries) |
| A slash in a string or comment | Write `//`: `"y//n"` prints y/n, where `"y/n"` would print y and then variable n (IDOL, QUBIC) |
| A variable escape in a stored message | `/x` reads x when the string is printed, so text copied into a buffer and shown later prints the later value; keep `#` for numbers there (IDOL) |
| `&` and `\|` don't short-circuit | Both sides always run, so the second must be safe when the first is false (BATTLE) |
| Do-while runs at least once | Test first, or use the copied-count form, when zero passes is possible (SUPERTRK) |
| Words sharing scratch variables | Note which word uses which letter; prefer the stack inside reusable words (BATTLE, REVERSI, TINYBAS). SUPERTRK once kept its command key in z, which its number reader also used, so the test that let the Klingons fire never held |
| Divide by zero still runs on an unchecked build | Guard it yourself; never call R with 0 (TINYBAS, G2048) |
| Values past 32767 wrap | Cap them, or keep two cells (KINGDOM, G2048) |
| R's byte is one higher when the state is negative | Truncation toward zero; harmless, the result is still 0–255 (all games) |
| A key ends a wait early | Frames with keypresses are shorter, so games speed up while keys are held (README) |
| Counting polls is not a clock | `1?` lasts 15.6 ms on Windows without a high-resolution timer (REFLEX) |
| The last cell of the last row | Writing it can scroll some terminals; stop one column short (IDOL) |
| A digit at the start of an editor line | It's taken as a line number; start the line with a space (tutorial) |
| Stray keys as indexes | Mask them into range, or they write outside a table (LIGHTS) |

## Debugging

Develop on a checked build, which stops with an error code, the line and column, and both stacks; then test once on an unchecked build too.

| Name | Code |
| --- | --- |
| Stack-leak sentinel | `12345` first, then `12345=0=("Stack leak"$0)` last |
| Trace a value | `:#" "$` |
| Mark a place | `"@3"$` |

- **Take the sentinel out** before the program goes into a pipe, since it prints.
- **A checked run is not proof.** Checked builds zero the variables, so a program that reads before it stores can work there and fail unchecked.
- **Ctrl-C breaks every build,** and a checked build reports `B` with the place, which shows where an endless loop was spinning.

## Sources

- [b8script.md](b8script.md): the spec's Idioms, Tips and Don't rely on
- [tutorial.md](tutorial.md) and [b8sms.md](b8sms.md)
- [games/](../games/): the commented .TXT sources of the 22 games, their README, and the size-contest games in b8sms, tweet140, tweet280 and longer
- [design/trading-game.md](design/trading-game.md)

Code quoted from a program was checked against its source; rows that describe a pattern in words have no code to check.
