# B8Script speed builds (Z80)

The Z80 interpreter built for speed, with no size limit: about twice as fast as the regular builds, and between 4 and 5 KB. It is the same source as the rest, [`../z80/b8s-z80.asm`](../z80/b8s-z80.asm), with the switch `FAST = 1`, and it passes the same tests.

| File | What it is | Bytes |
|---|---|---|
| `B8SZ80F.COM` | CP/M runner: `B8SZ80F PROG.B8S` | 4,608 |
| `B8SZ80FC.COM` | CP/M runner, checked | 4,864 |
| `b8s-z80-fast-rom-0000.bin` | Generic ROM, starting at 0000h (`ANSI = 0`) | 4,352 |
| `b8s-z80-fast-rom-checked-0000.bin` | Generic ROM, checked | 4,608 |
| `b8s-z80-fast-*.lst` | Their listings | |

They run any B8Script program exactly as the regular builds do. The generic ROMs have the regular generic ROM's machine interface and memory map (the interpreters README has both), and also use the page at the heap limit (F000h) for the skip cache. There is no editor build.

## How much faster

Z80 clock cycles on the generic builds, against the regular build, with the same output every time:

| Program | Regular | With `QUICK = 1` (`../quick/`) | This build |
|---|---|---|---|
| SIEVE, 1 pass | 56.8 M | 1.09× | 2.24× |
| PI, 100 digits | 316.2 M | 1.21× | 2.05× |
| MANDEL | 163.2 M | 1.36× | 2.53× |
| Tiny BASIC, a short program | 115.4 M | 1.38× | 2.40× |
| Robots, scripted play | 8.3 M | 1.18× | 2.11× |
| Reversi, scripted play | 43.9 M | 1.47× | 2.56× |
| Qubic, scripted play | 61.4 M | 1.26× | 2.35× |
| Tetris, scripted play | 10.9 M | 1.13× | 1.69× |

Tetris gains least because much of its time is spent in `n?` waits, which are timed and rightly don't get shorter.

## What it does differently

- **The inner loop is a table:** 256 entries, the low bytes of the handlers' addresses in one page and the high bytes in the next. Reading a character and getting to its handler is `LD A,(BC) / INC BC / EX DE,HL / LD L,A / LD H,page / LD A,(HL) / INC H / LD H,(HL) / LD L,A / JP (HL)`, against a chain of range tests and a jump through a table of low bytes in the regular builds.
- **That dispatcher is inline** at the end of the speed build's own entries, so there is no jump back to the loop. Every entry starts with TOS in DE.
- **One entry for each letter and digit.** A variable loads its own cell's address, and is fetched or stored in the same step when `@` or `!` follows (unchecked builds). A word call reads its own cell. A one-digit number needs no loop.
- **The commonest punctuation is written for the table:** `+ - : ; % @ , < = > & | ^ ~ * ( ) ]`, and `!` and `.` in the unchecked builds. The rest reach the regular handlers through a two-instruction thunk.
- **`*` and `/` are unrolled**, besides having `QUICK`'s speed-ups: 8 rounds of `*` for a small operand, `/` by a power of two as a shift.
- **The skip cache and the faster skip** of `QUICK`, the CP/M builds' `JP (IX)` for "next character" in the other handlers, and a true `)` that reads its block start in place.

The spec's [Speed](../../docs/b8script.md#speed) section explains each one, and the interpreters README's [Speed](../README.md#speed) section how to build these.

## Timing under CP/M

`n?` counts keyboard checks under CP/M, as the regular builds do. To tune it to your machine, see "Tuning `n?` under CP/M" in the interpreters README: its table has these two files too.
