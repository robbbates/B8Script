# B8Script programs

Programs for B8Script that aren't games: a BASIC interpreter, a memory monitor, a benchmark, two classic demonstrations of arithmetic, and in [`cpm/`](cpm/) a program that reads CP/M files. The games are in [`games/`](../games/).

Every `.B8S` file is a complete program. Run it with any B8Script runner, the same way as a game (`B8S PI.B8S`, on Windows or CP/M; see [`games/README.md`](../games/README.md#running-a-game)). Each one also has a `NAME.TXT` with comments that explain how it works. It runs the same as the `.B8S`, which is that file with the comments and spaces stripped out.

| File | Program | How to use it |
|---|---|---|
| `TINYBAS.B8S` | **Tiny BASIC**: a BASIC interpreter written in B8Script, with PRINT, IF, FOR, GOSUB, INPUT and RND. | Type BASIC lines, then `RUN`. Ctrl-B stops a running program (BREAK); `BYE` or Ctrl-C leaves. |
| `MON.B8S` | **MON**, a memory monitor in the manner of the Apple 1's Wozmon: look at memory, change it, run machine code. | See below. |
| `SIEVE.B8S` | **The BYTE sieve**, the benchmark from *BYTE* magazine (1981): find the primes with the Sieve of Eratosthenes, over 8,191 flags. | Type how many passes to make. It prints a dot for each pass, then the count, `1899 primes`. Time it with a watch to compare machines. |
| `PI.B8S` | **The digits of pi**, by the spigot of Rabinowitz and Wagon, which needs nothing bigger than a 16-bit cell. | Type how many digits, 1 to 250. They come out in groups of ten, fifty to a line. 250 digits take a while on an 8-bit machine. |
| `MANDEL.B8S` | **The Mandelbrot set**, drawn in characters, 78 × 22, with 16-bit fixed-point arithmetic. | Just run it. Denser characters mean the point took longer to escape; `@` is inside the set. |

## CP/M file programs

The programs in [`cpm/`](cpm/) read files through the CP/M BDOS, with a little machine code (see [Files under CP/M](../docs/idioms.md#files-under-cpm) in idioms.md). They need a CP/M build on a Z80 or an 8080; on any other build they say so and end. They are not in the web player.

| File | Program | How to use it |
|---|---|---|
| `cpm/HEXDUMP.B8S` | **HEXDUMP**: shows any file in hex and as text, a page of 256 bytes at a time, in MON's row format. | `B8S HEXDUMP.B8S FILE.COM`, or with no name it asks for one. Space or Return shows the next page, b the one before, q quits. |

## The benchmarks

SIEVE, PI and MANDEL are written for speed, each step measured on the Z80 build. SIEVE and PI keep their published algorithms unchanged, so their times compare with other languages'; MANDEL's arithmetic gives the same result as the plain way for every point, with its squares from a table. Each `.TXT` says how. Times on a Z80 at 7.3728 MHz (an RC2014), with the small generic Z80 build, measured in an emulator with the output not counted:

| Run | Time |
|---|---|
| SIEVE, 10 passes | 77.0 s |
| PI, 100 digits | 42.9 s |
| PI, 250 digits | 251.8 s |
| MANDEL | 22.1 s |

The time printing takes depends on the terminal: MANDEL prints 1,760 bytes, 1.8 s at 9600 baud, though on a serial line most of that overlaps the computing. MANDEL also needs 2 KB of heap for its table.

## MON

MON starts where free memory starts, at the heap top, and says that address. At its `*` prompt, addresses and bytes are typed in hex (upper or lower case):

| Command | What it does |
|---|---|
| `XXXX` | Shows 16 bytes from `XXXX`, in hex and as text. |
| Return | Shows the next 16. |
| `XXXX.YYYY` | Shows `XXXX` to `YYYY`. A key stops it. |
| `XXXX: hh hh …` | Stores bytes from `XXXX`. |
| `: hh hh …` | Stores more bytes, going on from where the last line stopped. |
| `XXXXR` | Runs the machine code at `XXXX`. |
| `?` | Shows a short help. |
| `Q` | Quits. |

`R` calls the code with B8Script's grave (see the CPU's appendix in [the spec](../docs/b8script.md)). The code must end with its CPU's return, or MON won't get control back:

| CPU | Return |
|---|---|
| Z80, 8080 | `C9` |
| 6502 | `60` |
| 6809 | `39` |
| Windows (x86) | `C3` |

So `C000: C9` and then `C000R` runs a routine that does nothing and comes straight back, on a Z80.

Which addresses are safe to change depends on the machine. The program, the interpreter and the stacks are memory too, and changing them can crash B8Script.
