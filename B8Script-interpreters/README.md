# B8Script interpreters: Z80, 8080, 6502, 6809 and Windows

Generic interpreters for minimal homebrew machines (serial console only), CP/M 2.2 versions for the Z80 and 8080, and a 32-bit x86 one for the Windows command shell. Each source has switches at the top:

```
CPM     EQU     0               ; 1 = CP/M .COM build        (Z80, 8080)
CHECKED EQU     0               ; 1 = checked build          (all)
EDITOR  EQU     0               ; 1 = with the line editor   (Z80, Windows)
ANSI    EQU     0               ; 1 = the console escapes send ANSI sequences (Z80, 8080, 6502, 6809)
SPEED   EQU     1               ; 0 = small, 1 = base, 2 = fast (all)
```

The Windows source takes its switches (`CHECKED`, `EDITOR`, `SPEED`) as NASM defines, such as `-DSPEED=0`.

`SPEED` picks one of three tiers, which every CPU has (see [Speed](#speed)):

- **small** (`SPEED = 0`) is tuned for size: the smallest build of each CPU.
- **base** (`SPEED = 1`, the default) adds the speed-ups that cost least: about 120 to 330 bytes more than small, for 1.1 to 1.6 times its speed.
- **fast** (`SPEED = 2`) is base and everything else, size no object: 4 to 9 KB, and 1.7 to 4.6 times the speed of small. It is built for running benchmarks. It goes with every build except the Z80's line editor.

`ANSI` decides what the console escapes of `$` (`/{` `/}` `/|` `` /` `` `/~`) do. With `ANSI = 1` they send ANSI (VT100) sequences through `CONOUT`. With `ANSI = 0` they call four routines of the machine's own (see the machine interface below). The generic builds default to `ANSI = 0`; the CP/M builds always send ANSI, whatever the switch says; the Windows builds always send ANSI, in the console mode they set.

The 6502 has two sources: `b8s-6502.asm` keeps the data stack in pages 2 and 3, and `b8s-6502-zp.asm` is a smaller interpreter that keeps it in zero page.

**Contents**

- [Sizes (bytes, measured)](#sizes-bytes-measured)
- [Files](#files)
- [The language](#the-language)
- [Tuning `n?` under CP/M](#tuning-n-under-cpm)
- [Building](#building)
- [Layout rules the assembler can't check](#layout-rules-the-assembler-cant-check)
- [Generic machine interface (edit the equates)](#generic-machine-interface-edit-the-equates)
- [The break key](#the-break-key)
- [The Z80 line editor (EDITOR = 1)](#the-z80-line-editor-editor--1)
- [The Windows builds (`win32/`)](#the-windows-builds-win32)
- [Checked builds](#checked-builds)
- [Machine-code contracts (the grave)](#machine-code-contracts-the-grave)
- [The two 6502 interpreters](#the-two-6502-interpreters)
- [Speed](#speed)
- [How they were tested](#how-they-were-tested)

## Sizes (bytes, measured)

**Generic ROM images.** `ANSI = 0` is the default (the console escapes call the machine's routines); `ANSI = 1` sends ANSI sequences.

| CPU | Tier | Unchecked, `ANSI = 0` | Unchecked, `ANSI = 1` | Checked, `ANSI = 0` | Checked, `ANSI = 1` |
|---|---|---|---|---|---|
| Z80 | small | 835 | 886 | 1,219 | 1,266 |
| Z80 | base | 1,054 | 1,118 | 1,402 | 1,449 |
| Z80 | fast | 4,352 | 4,352 | 4,608 | 4,608 |
| Z80 with the line editor | small | 1,355 | 1,405 | 1,742 | 1,788 |
| Z80 with the line editor | base | 1,568 | 1,618 | 1,951 | 1,968 |
| 8080 | small | 926 | 980 | 1,348 | 1,402 |
| 8080 | base | 1,134 | 1,188 | 1,528 | 1,582 |
| 8080 | fast | 4,352 | 4,352 | 4,864 | 4,864 |
| 6502, stack in pages 2-3 | small | 1,208 | 1,265 | 1,707 | 1,750 |
| 6502, stack in pages 2-3 | base | 1,534 | 1,591 | 1,976 | 2,019 |
| 6502, stack in pages 2-3 | fast | 7,448 | 7,505 | 5,506 † | 5,549 † |
| 6502, stack in zero page | small | 1,155 | 1,217 | 1,673 | 1,721 |
| 6502, stack in zero page | base | 1,474 | 1,536 | 1,937 | 1,985 |
| 6502, stack in zero page | fast | 6,940 | 7,002 | 5,060 † | 5,108 † |
| 6809 | small | 873 | 934 | 1,264 | 1,313 |
| 6809 | base | 1,023 | 1,084 | 1,377 | 1,426 |
| 6809 | fast | 4,651 | 4,712 | 4,254 † | 4,303 † |

**CP/M .COM files** (always ANSI):

| CPU | Tier | Unchecked | Checked |
|---|---|---|---|
| Z80 | small | 1,017 | 1,414 |
| Z80 | base | 1,231 | 1,593 |
| Z80 | fast | 4,608 | 4,864 |
| Z80 with the line editor | small | 1,646 | 2,048 |
| Z80 with the line editor | base | 1,860 | 2,227 |
| 8080 | small | 1,129 | 1,583 |
| 8080 | base | 1,341 | 1,763 |
| 8080 | fast | 4,608 | 4,864 |

**Windows .EXE files** (always ANSI):

| Tier | | Unchecked | Checked | With the editor, unchecked | With the editor, checked |
|---|---|---|---|---|---|
| small | The file | 2,560 | 3,072 | 3,072 | 3,584 |
| small | Code and table | 1,319 | 1,829 | 2,021 | 2,543 |
| base | The file | 2,560 | 3,072 | 3,584 | 4,096 |
| base | Code and table | 1,509 | 1,973 | 2,207 | 2,687 |
| fast | The file | 8,192 | 7,680 † | 8,704 | 8,704 |
| fast | Code and tables | 6,963 | 6,575 † | 7,663 | 7,291 † |

- A generic size is the whole ROM image: the code plus the punctuation table.
- † A checked fast build can be smaller than its unchecked one (6502, 6809, Windows): the unchecked one's 26 variable entries each also do `@` and `!`, in one step with the variable, which a checked build can't do, as it tests the stacks between the two.
- The 8080 fast builds include up to 255 bytes of padding, which puts their 512-byte table on a page boundary.
- A Windows file is a 512-byte header and then the code, the table and about 375 to 400 bytes of import data, rounded up to the next 512 bytes: so a file shrinks only in steps of 512. The four small ones have 357, 359, 143 and 133 bytes to spare before their next step up.
- The letter cells, stacks and line buffer are all in RAM, so they aren't counted.
- The CP/M size is the .COM file, which includes the program loader.
- Where the bytes go, in the Z80's small builds: the console escapes take about 60 bytes with `ANSI = 0` and 110 with `ANSI = 1`; the break key 60 to 80 (about 30 of them the break-off cell and its wait for a second Ctrl-C); a checked build's checks and report about 380 more; the line editor about 520 (generic) or 630 (CP/M, with its file commands). The CP/M builds reach their five most-used routines with CALL and jumps instead of one-byte RSTs (page zero is the system's), which costs them about 60 bytes on the Z80 and 80 to 100 on the 8080.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## Files

Each CPU has a folder, `z80/`, `8080/`, `6502/`, `6809/` and `win32/`, which holds its source and three subfolders, `small/`, `base/` and `fast/`, with that tier's builds.

| File | What it is |
|---|---|
| `CPU/b8s-*.asm` | The source, with comments |
| `CPU/TIER/b8s-CPU-TIER-rom-ORG.bin` | Generic ROM image, to load at ORG: 0000h on the Z80 and 8080, E000h on the 6502, F000h on the 6809 (E000h in its fast tier). After `rom`, `-zp` marks the zero-page 6502 interpreter, `-editor` the Z80 with the line editor, and `-unchecked` an unchecked build: `z80/base/b8s-z80-base-rom-0000.bin` is checked, `z80/base/b8s-z80-base-rom-unchecked-0000.bin` unchecked, `6502/small/b8s-6502-small-rom-zp-unchecked-E000.bin` the small zero-page 6502, unchecked |
| `z80/TIER/B8S*.COM`, `8080/TIER/B8S*.COM` | CP/M builds, named as below. Run as `B8S PROG.B8S` |
| `win32/TIER/B8S*.EXE` | Windows command-shell builds, named as below. Run as `B8S PROG.B8S` |
| `*.lst` | The assembler's listings, each named as its build, next to it |
| `TIMING.B8S` | Times `n?` on your machine, to tune the CP/M builds' count (see The language) |

The CP/M and Windows files are named `B8S`, then `U` if unchecked, then `S` (small) or `F` (fast), then `E` with the line editor. The CPU is in the folder, not the name:

| Build | `small/` | `base/` | `fast/` |
|---|---|---|---|
| Runner, checked | `B8SS` | `B8S` | `B8SF` |
| Runner, unchecked | `B8SUS` | `B8SU` | `B8SUF` |
| With the line editor, checked | `B8SSE` | `B8SE` | `B8SFE` (Windows only) |
| With the line editor, unchecked | `B8SUSE` | `B8SUE` | `B8SUFE` (Windows only) |

The Z80 has all ten as `.COM` files, the 8080 the six runners, and Windows all twelve as `.EXE` files. `B8S.COM` (or `B8S.EXE`) is the one to start with: the base runner, checked.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## The language

The builds follow [`docs/b8script.md`](../docs/b8script.md) (2026-11-24). What the spec leaves to the implementation:

- `-n?`: Backspace takes a character back and is echoed as it is; every other key but CR is stored and echoed, control keys and DEL included; CR ends the line and is not echoed. A count above 127 is taken as 127. The CP/M builds read the line the same way, with BDOS 6 a key at a time, not with BDOS 10: so a key held by the break check is the line's first, and the editing keys are the same on every build.
- Dividing by zero in an unchecked build returns two cells of no meaning (different on each CPU), and the stack stays balanced.
- `[` followed by anything but a letter is taken as `[ ` in an unchecked build.
- The CP/M builds print through BDOS 6, which can't print the bytes FFh and FEh: to BDOS 6, FFh means "read a key", and in Digital Research's CP/M 2.2 BDOS (an undocumented case, also in CP/M 3) FEh means "is a key waiting?". Neither reaches the screen. Found by running the test suite under real CP/M 2.2 (z80pack); see How they were tested.
- **`n?` under CP/M** has no clock to go by: it counts keyboard checks (BDOS 6 calls), 4 a millisecond, which suits an RC2014 with RomWBW and ZPM3. On another machine it may run fast or slow: see Tuning `n?` under CP/M.
- The memory maps, stack sizes, heap limits and system addresses are in the spec's appendices.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## Tuning `n?` under CP/M

CP/M has no clock a program can count on, so the CP/M builds time `n?` by counting keyboard checks: BDOS 6 calls, 4 to a millisecond. How long a call takes depends on the BIOS. On an RC2014 with RomWBW and ZPM3 one takes about 280 µs, and 4 of them make `n?` about 13% slow, which is the closest a whole number gets. A machine with a faster or slower BIOS can be tuned once:

1. **Measure.** Run `B8S TIMING.B8S` (or whichever build you use) and time its step 1 with a watch. It should take 10 seconds. If it takes T seconds, the count your machine wants is 40 / T, rounded: 11.3 seconds gives 3.5, so 4; 5 seconds gives 8; 20 seconds gives 2. It must be 1 to 255. (Step 3 should take the same as step 1; step 4 just shows the machine's speed.)
2. **Find the byte.** The count is one byte in the .COM file:

   | File | File offset | Address once loaded | Pages (CP/M 2.2 SAVE) | Last address (CP/M 3 SAVE) |
   |---|---|---|---|---|
   | `z80/small/B8SS.COM` | 1E5h | 2E5h | 6 | 685h |
   | `z80/small/B8SUS.COM` | 1E8h | 2E8h | 4 | 4F8h |
   | `z80/small/B8SSE.COM` | 1DEh | 2DEh | 8 | 8FFh |
   | `z80/small/B8SUSE.COM` | 1D8h | 2D8h | 7 | 76Dh |
   | `z80/base/B8S.COM` | 1CEh | 2CEh | 7 | 738h |
   | `z80/base/B8SU.COM` | 1CDh | 2CDh | 5 | 5CEh |
   | `z80/base/B8SE.COM` | 1C7h | 2C7h | 9 | 9B2h |
   | `z80/base/B8SUE.COM` | 1BDh | 2BDh | 8 | 843h |
   | `z80/fast/B8SF.COM` | 19Ah | 29Ah | 19 | 13FFh |
   | `z80/fast/B8SUF.COM` | 1A0h | 2A0h | 18 | 12FFh |
   | `8080/small/B8SS.COM` | 202h | 302h | 7 | 72Eh |
   | `8080/small/B8SUS.COM` | 1D7h | 2D7h | 5 | 568h |
   | `8080/base/B8S.COM` | 1E2h | 2E2h | 7 | 7E2h |
   | `8080/base/B8SU.COM` | 1B7h | 2B7h | 6 | 63Ch |
   | `8080/fast/B8SF.COM` | 1A7h | 2A7h | 19 | 13FFh |
   | `8080/fast/B8SUF.COM` | 17Eh | 27Eh | 18 | 12FFh |

   These move when the code changes: `testing/patchinfo.py` prints the table for the current builds.
3. **Patch it**, in hex (8 is `08`, 12 is `0C`). Use **either** a hex editor on a PC **or** the CP/M tools on the machine itself; you need only one of the three ways below.
   - **On a PC, with a hex editor:** change the byte at the file offset (`04` as built), then copy the file to the machine.
   - **Or on CP/M 2.2, with DDT**, for the Z80's `B8S.COM`:
     ```
     A>DDT B8S.COM
     -S2CE
     02CE 04 08
     02CF xx .
     -G0
     A>SAVE 7 B8S.COM
     ```
     `S` shows the byte and takes the new one; `.` ends; `G0` leaves DDT; `SAVE` takes the page count from the table.
   - **Or on CP/M 3 or ZPM3**, where SAVE is a program run first, then the debugger (SAVE waits, and when the debugger exits it asks where to save memory, before anything is cleared):
     ```
     A>SAVE
     A>SID B8S.COM
     #S2CE
     02CE 04 08
     02CF xx .
     #G0
     Enter file (type RETURN to exit): B8S.COM
     Delete B8S.COM? Y
     Beginning hex address 100
     Ending hex address 738
     ```
     ZSID, DDTZ (which RomWBW ships) and DDT work the same way: any debugger that loads the file at 0100h and leaves with `G0`, which is the exit SAVE waits for. Its prompt may differ; `?` lists a debugger's commands.
4. **Check.** Run `TIMING.B8S` again: step 1 should now take about 10 seconds.

Two other waits are built from the same count: Ctrl-C's 250 ms wait for a second Ctrl-C, and the editor's 5 ms wait after Esc, which is how it tells an arrow key (Esc `[` and a letter, sent together) from a lone Esc. The patch doesn't change them, and they don't need it: a little off either way does no harm.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## Building

The sources use asm80 1.11.14, from npm (`npm install -g asm80@1.11.14`):

```
node asm80.js -m Z80 -t hex -o b8s-z80.hex b8s-z80.asm
```

The machine name is `Z80`, `I8080`, `C6502` or `M6809`. That builds the source as its EQU lines stand: the base generic ROM, unchecked. To build a variant, edit the EQU lines first, or use `testing/build.sh`, which builds every variant of a source in one tier: `SPEED=0`, `1` (the default) or `2` picks small, base or fast, and the tier goes in the name.

```
cd testing
./build.sh Z80 ../z80/b8s-z80.asm out/z80              # base: b8s-z80-base-gen, -gen-chk, -cpm, -cpm-chk
VARIANTS=$'0 0 1\n0 1 1\n1 0 1\n1 1 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80   # base with the editor: -ed, -cpm-ed
SPEED=0 ./build.sh Z80 ../z80/b8s-z80.asm out/z80      # small: b8s-z80-small-gen and so on
SPEED=0 VARIANTS=$'0 0 1\n0 1 1\n1 0 1\n1 1 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80
SPEED=2 ./build.sh Z80 ../z80/b8s-z80.asm out/z80      # fast: b8s-z80-fast-gen and so on (no editor)
for sp in 0 1 2; do SPEED=$sp ./build.sh I8080 ../8080/b8s-8080.asm out/8080; done
for sp in 0 1 2; do SPEED=$sp VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502.asm out/6502; done
for sp in 0 1 2; do SPEED=$sp VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502-zp.asm out/6502; done
for sp in 0 1 2; do SPEED=$sp VARIANTS=$'0 0\n0 1' ./build.sh M6809 ../6809/b8s-6809.asm out/6809; done
ANSI=1 VARIANTS=$'0 0\n0 1\n0 0 1\n0 1 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80a   # the generic ones with ANSI = 1
./build_win32.sh                                        # all twelve Windows files, into out/win32
python3 run_z80.py z80 out/z80                          # each CPU's tests take every tier in the folder
python3 mkrel.py                                        # copies them to each CPU's small/, base/ and fast/
```

The Windows source is for NASM (2.16), which writes the .EXE directly, with no linker: the source lays the file's header out itself.

```
nasm -f bin -DCHECKED=1 -DEDITOR=1 -o B8SE.EXE b8s-win32.asm
```

That is the base build with the editor, checked; `-DSPEED=0` makes it small (`B8SSE.EXE`) and `-DSPEED=2` fast (`B8SFE.EXE`). `testing/build_win32.sh` builds all twelve.

asm80 has some quirks the sources work around:
- `IF`/`IFN`/`ENDIF` must not be nested, and there is no `ELSE`. Combined conditions are written as arithmetic, like `IF (1-CPM)*CHECKED`.
- A label on the same line as an `IF` is lost.
- `'"'` doesn't parse, so it's written `22h`.
- In I8080 mode it assembles `RST 08h` wrongly. Write `RST 1` to `RST 6`.
- In C6502 mode it accepts some out-of-range branches without an error. Run `testing/chkbr6502.py` on every listing.
- A division inside a longer expression is not rounded down; only a value stored by `EQU` is. The page arithmetic is one division to a line for that reason.
- `abs` is a function name and can't be a label.
- Version 0.9.x assembles the inside of a false `IF`, so it can't build these.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## Layout rules the assembler can't check

To save the 32 bytes of a full address table, the Z80, the 8080, the unchecked 6809 and the zero-page 6502 keep one byte per punctuation character and work the rest of the handler's address out from the character's place in the table. That puts rules on where handlers sit:

- **Z80, 8080:** the handlers of the first `NPG1` characters (in code order) start in the image's second 256 bytes, the rest in its first. `NPG1` is worked out by the assembler from where `] \ [ @` landed, so the split moves by itself when code grows or shrinks.
- **6809, unchecked:** the same idea with two 256-byte ranges after the table. The checked 6809 build is too big for that and keeps a table of whole addresses.
- **6502, zero page:** three pages. The handlers of `! " # $ % & ' (` start in the image's first 256 bytes, those of `) * + , - . / : ; < = > ?` in its second, and the rest in its third. The split is fixed (`N1`, `N2`), so code that grows may have to move; the source marks the stretches where no handler starts, which are the places to move it to. The image must be assembled at a multiple of 512.
- **Z80, 8080:** the RST routines must sit at their vectors.

`testing/chktab.py` (Z80, 8080), `testing/chktab09.py` (6809) and `testing/chktab6502.py` check all of this on the listings. Run them after any change; each says how many bytes are to spare. `b8s-6502.asm` has a table of whole addresses and no such rules, and the fast builds of every CPU dispatch through a full table and have none either.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## Generic machine interface (edit the equates)

| | Z80 / 8080 | 6502 | 6809 |
|---|---|---|---|
| KEY | return a waiting key in A, or A = 0 if none is waiting; the zero flag must match A | same | same |
| CONOUT | print A | same | same |
| EXIT | jumped to when the program ends | same | same |
| KEY and CONOUT must keep | BC, DE, HL (and IY on the Z80) | X, Y | B, X, Y, U, DP |
| Where to start | reset at 0000h | label `start`, E000h (point the reset vector at it); E200h in the fast builds, whose table fills E000h-E1FFh | label `start`, F000h (point the reset vector at it); E000h in the fast builds |
| RAM | RS 8000h, DS 8100h, letters 8200h, PROG 8300h; the skip cache (base and fast builds) the page at the heap limit, F000h | RS = page 1, DS 0200h/0300h (or zero page 10h-EFh), letters 0400h, PROG 0500h; the skip cache (base and fast builds) the page at the heap limit, DF00h, or 0200h in the zero-page interpreter | RS 8000h (S), DS 8100h (U), letters 8200h (DP), PROG 8300h; the skip cache (base and fast builds) the page at the heap limit |
| Heap limit | `HEAPLIM` (page), F0h as built | E0h as built; DFh in the base and fast builds of the pages 2-3 interpreter | F0h in the small build, EFh in base, DFh in fast |
| Timing | `MSLOOP` = loop passes per millisecond for `n?` (1-255); tune it to your clock and KEY | same | same |
| With `ANSI = 0`: CONCLS (FF0Ch), CONEOL (FF0Fh) | clear the screen and home the cursor; clear to the end of the line | same | same |
| CONCUR (FF12h) | show the cursor if A is not 0, hide it if A = 0 | show if the carry is set, hide if clear | as the Z80 |
| CONAT (FF15h) | cursor to row HL, column DE, both from 0 | row A, column Y | row X, column D |
| The four must keep | BC (and IY on the Z80); HL too, all but CONAT | X | Y, U, DP |

- There is one input routine, KEY: `0?` waits by calling KEY until a key comes.
- KEY is also called while a program runs, for the break key: once in every 256 word calls and loop-backs. A key it returns then is taken, so KEY must not wait, and should be quick.
- The Z80 builds with the editor have one more address, `LEAVE`: where ^X goes. A program that ends goes back to the editor.
- Your loader puts the program text, ending in a NUL, at `PROG`. The heap starts after the NUL.
- The generic Z80 and 8080 images start at 0000h and use RST 08h, 18h, 20h, 28h and 30h as one-byte calls.
- The CP/M builds don't touch page zero: there the same routines are reached with CALL and JP, and on the Z80 "next character" is `JP (IX)`, with IX holding its address. Page zero is the system's: RomWBW's BIOS calls itself through RST 08h, and some systems take interrupts through RST 1 to RST 6.
- The Z80 builds don't use the alternate registers: the return-stack pointer is IY. An interrupt routine may use the alternate registers freely; it must save IX and IY if it uses them, as it would any register.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## The break key

Every build stops a running program on Ctrl-C. An unchecked build prints nothing and goes to EXIT (or back to the editor); a checked build reports `B`.

- **Where it is looked for.** At every word call and every true `)` loop-back (on the Z80 and 8080 also at block entry and `{`), but KEY is only called one time in 256: a counter gates it. A program stuck in `?` is stopped too, since `?` treats Ctrl-C the same way.
- **Other keys.** A key the check reads is held for the next `?`. A newer key replaces it, and `?` takes the held key before it looks at KEY. So one key typed ahead is kept, not more.
- **The break-off cell** is the byte at offset 7Bh of the letter page: 827Bh on the generic Z80, 8080 and 6809, $047B on the 6502. A program that stores a non-zero byte there gets Ctrl-C as key 03h. When it does, the interpreter waits about 250 ms (250 x `MSLOOP` calls of KEY) for one more key: a second Ctrl-C stops the program all the same, and any other key becomes the held key. Each build clears the cell when it starts; the editor clears it before every line.
- **The held key** is a cell of the interpreter's own. Most builds keep it in the byte below the break-off cell; the appendices say where.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## The Z80 line editor (EDITOR = 1)

The line editor is built into the Z80 builds (small and base) and the Windows builds (every tier). The 8080, 6502 and 6809 builds are runners only, and the Z80's fast build has no editor. An editor can be added to any of them if there's enough interest.

The interpreter starts in the editor, and a program that ends comes back to it. There is no prompt. It follows the suggested standard in the spec's Environments chapter. Type a line and press Return:

| You type | What happens |
|---|---|
| `n text` | The text goes in as line n, and the lines from n on move down. A number past the end, or 0, adds the line at the end |
| `n` | Line n is taken out |
| anything else | It runs at once, as B8Script. Start such a line with a space if it would begin with a digit |

A command key ends the line too, and takes what was typed before it as its argument:

| Key | What it does |
|---|---|
| ^G | Runs the program |
| `n`^L | Lists from line n, or all of it with no number, each line with its number. Any key holds the list until the next key; Ctrl-C ends it |
| `n`^E | Puts line n in the input line. Return puts the text back in its place, as changed; Esc leaves the line as it was |
| ^R, `name`^R | Reads. CP/M: the file of that name, or the same file as last time. Generic: whatever is typed or pasted from then until ^Z replaces the program, with no echo |
| ^W, `name`^W | Writes. CP/M: to that file, or the same file as last time. Generic: prints the text as it is, for the terminal to capture |
| ^N | New: no program |
| ^X | Leaves: to `LEAVE` (generic) or to CP/M |
| The left and right arrow keys | Move the cursor in the line. Text goes in at the cursor |
| Backspace, DEL | Take out the character before the cursor |
| Esc | Drops the line |

- Lines are counted, not numbered: the text holds no line numbers, and the list shows each line's place. There can be 65,535 lines.
- A typed line holds 125 characters, the line number included. The one character after the line number separates it from the text and is not stored, whatever it is: `3 5#` stores `5#`, and so does `3x5#`. Type a space there.
- The editor sends only printing characters, CR, LF and Backspace, so it works on any terminal. A character put in or taken out in the middle of the line prints the rest of the line again.
- After Esc the editor waits about 5 ms for another key. If `[` follows, it reads on to the letter that ends the sequence and acts on C (right) and D (left); it ignores the rest. A lone Esc drops the line.
- Tab is text. Other control keys do nothing.
- **What lasts from line to line:** the program, the words, the variables and the data stack. The return stack starts empty for every line. After an error or a break both stacks are empty, and the editor shows the cursor (it does when it starts, too), since a program that hid it can't show it again then. A word's address points into the program text, so run the program again after editing it.
- A line run at once sits in the line buffer, which `-n?` also reads into. The stored program never returns to the line, so it can use `-n?` freely; a typed line that calls `-n?` itself and carries on afterwards runs what was typed.
- `-n?` in a program is the plain line read of the other builds, not the editor's.
- Nothing is printed between a program's output and what you type next.
- Reset empties the program (generic builds).

**Reading and writing, generic builds:**
- ^R stores each CR as CR LF. A LF straight after a line end is dropped; a LF anywhere else ends a line too. So text with CR LF, CR or LF line ends all comes in right, but empty lines can be lost. A last line with no line end is given one.
- ^R ends at ^Z only. The spec also names ^@, but KEY returns 0 for "no key", so a NUL can't be seen.
- Nothing checks that the text fits in memory.

**With CP/M** (`B8SE`, `B8SUE`, `B8SSE`, `B8SUSE`):
- The file named on the command line is the program to start with, and the name that ^R and ^W use until another is typed. With no file, or no such file, there is no program.
- A name is up to 8 characters, a dot and up to 3 more, on the current drive. It is put in capitals.
- The text ends at the file's first ^Z, and a last line with no CR LF is given one. ^W pads the last record with ^Z.
- ^W deletes the old file first. It does not notice a full disk or directory: the file is then short, or missing.
- The editor reads its keys with BDOS 6, so BDOS 10's editing keys don't apply to it, and Ctrl-C at the editor does nothing: ^X leaves.

**Checked** (`B8SE`, `B8SSE`, and the `-rom-editor-` images without `-unchecked`):
- A program that is stopped, by an error or by Ctrl-C, prints its report and comes back to the editor, with both stacks empty.
- A line typed at the editor is line 0 in the report; the column is the place in the line.

In the small builds the editor adds 520 bytes to the unchecked generic build and 629 to the CP/M one (523 and 634 to the checked ones); in base it adds 514 and 629 (549 and 634).

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## The Windows builds (`win32/`)

Twelve programs for the Windows command shell, in 32-bit x86 assembly, four in each tier. In `win32/base/`: `B8S.EXE` (the runner, checked), `B8SU.EXE` (unchecked), `B8SE.EXE` (with the line editor, checked) and `B8SUE.EXE` (editor, unchecked); in `win32/small/` the same with an S after `B8S` (`B8SS.EXE` and so on), and in `win32/fast/` with an F (`B8SF.EXE` and so on). A 32-bit program runs on every Windows, the 64-bit and ARM ones included.

```
B8S PROG.B8S
B8S PROG.B8S > out.txt
B8SE PROG.B8S
```

- **They have not been run on Windows yet.** They are tested in an emulator, with the Windows calls they make modelled by hand, and their headers are checked against the documented rules (see How they were tested). The first run on a real machine is still to do.
- **The machine is the spec's:** 64 KB of memory, 16-bit cells and addresses. The memory map is in the spec's Appendix E. The language, the break key, the checked builds' errors and report, and the editor are the Z80's, key for key.
- **The file.** A runner loads the file named on the command line, runs it and exits. With no file, or one that can't be opened, it exits without a word. An editor build starts with that file as its program, or empty. A file can hold up to 64,765 bytes.
- **Output** goes to standard output, so it can be redirected. A checked build's report goes to standard error.
- **Keys** are read from the console raw: no echo, and Ctrl-C arrives as a key, so the interpreter's own break rules apply. The console's mode is put back on every way out. The left and right arrow keys work in the editor: they are read as the codes 1Ch and 1Eh, which a program reading keys with `?` sees too. The Delete key does nothing; Backspace deletes.
- **Input that is not the console** (a pipe or a file) is read a byte at a time, and only by `?`, `-n?` and the editor: the break check does not read it, so Ctrl-C can't break in, and `n?` waits for a byte however small n is. At the end of the input the program exits.
- **Time.** A plain timed wait on Windows ends only on the system's tick, every 15.6 ms, so `1?` would take about 16 ms and a game timed by it would crawl. So `n?`, the break-off cell's 250 ms and the editor's Esc wait use a high-resolution waitable timer (Windows 10 1803 and later), set once for the whole wait: the wait ends on a key or when the timer is due, to about a millisecond. On older Windows the timer can't be made, and the waits are plain ones, to the tick. The builds import `CreateWaitableTimerExW`, so they start on Windows Vista and later.
- **The editor's files.** A name typed before ^R or ^W is a Windows path, as typed, and stays the name until another is typed. Nothing is said if a file can't be read or written: a read then gives no program.
- **The header** is laid out by hand in the source, by the documented rules and nothing clever: one section, 512-byte file alignment, imports from `kernel32.dll` only (`GetStdHandle`, `GetConsoleMode`, `SetConsoleMode`, `GetCommandLineA`, `CreateFileA`, `ReadFile`, `WriteFile`, `WaitForMultipleObjects`, `CreateWaitableTimerExW`, `SetWaitableTimer`, `ReadConsoleInputA`, `ExitProcess`, and `CloseHandle` in the editor builds). `testing/chkpe.py` checks every file.
- **Dispatch.** In small and base, one byte per punctuation character, as on the Z80, but with a single range: every handler starts within 255 bytes of one address, and the assembler stops if one doesn't.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## Checked builds

A checked build starts with every variable at 0 and every word undefined. It stops on the errors in the spec's table:

| Letter | Meaning |
|---|---|
| `S` / `s` | data stack overflow / underflow |
| `R` / `r` | return stack overflow / underflow |
| `H` | the heap past its limit, released below the program's end, or moved so far that the address wrapped round |
| `O` | a store with `!` or `.` outside the program's space |
| `U` | a call of a word that was never defined |
| `Q` | no closing quote: a string that runs into the end of the text, or `$` that does |
| `W` | a character other than a letter or a space after `[` |
| `X` | a reserved byte, 80h-FFh, outside a string |
| `Z` | dividing by zero |
| `N` | a false `(` or a `[` whose skip runs into the end of the text or into the wrong closer |
| `B` | Ctrl-C |

The report is the spec's:

```
Err Z @ 3,5
D:6: 1 2 3 4 5 0
R:0
```

- It starts and ends with CR LF. Then the build goes to EXIT, or back to the editor.
- **The place** is the character that failed. For `U` it is the call, for `N` the `(` or `[` where the skip started, for `Q` the opening quote or the `$`, and for `W` the character after the `[`. Lines and columns count from 1; text below the program (a line read by `-n?` and then run, or a line typed at the editor) is line 0.
- **The stack lines** show the stacks as they were before the failing character ran: `7 0/` shows `D:2: 7 0`. More than 8 cells are shown as ` ...` and the top 8. Values are signed, as `#` prints them. There are three exceptions:
  - A stack overrun (`S` `s` `R` `r`) is found after the character has run, once per character. After `s` the data stack counts as empty, after `r` the return stack. The place can be one character late, and after `r` it is wherever the bad return went.
  - `N`, and `Q` for an unclosed string, show the stack after the opener took its flag or pushed its address.
  - `B` shows whatever is there when the key is noticed.
- **A string with no closing quote inside skipped text** is an `N` at the skip's opener (or the quiet end of the program, for `\`), not a `Q`: the skip ran into the end.
- **Store range.** "The program's space" runs from the letter page up to the heap limit, not just up to the heap top. Tiny BASIC keeps its program lines above the heap top without allocating them, so the stricter rule would stop it. On the Z80 and 8080 one test serves both bytes of a cell, so `.` can't store to the very last byte below the limit.
- **The hex loader and machine code are never checked.**
- **Stacks.** The stacks hold 127 data cells and 112 return entries (Z80/8080), 252 or 112 and about 110 (6502), or 125 and 96 (6809). A few spare bytes above each stack and a guard band below take what a character does before the check sees it, so an overrun can't reach the letter cells.
- **Undefined words.** The word cells start at 0000h. On the Z80 and 8080 the byte there is a reserved one, and the reserved-byte path sees that the text pointer is in page zero; the 6502 reads a NUL there (the text pointer's own low byte) and its end-of-text path sees that the pointer is in page zero; the 6809 tests the cell at the call.
- **Unchecked builds and `[`.** A letter defines; anything else is taken as the space.
- **Don't treat a checked run as proof.** What an unchecked build does with the same mistake is not defined. One example: an unclosed string in an unchecked build is skipped on through memory until some quote turns up.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## Machine-code contracts (the grave)

- **Z80 / 8080:** as in the spec. Entered by CALL, with the data cells above the return address. The code must keep BC. On return, the top cell becomes TOS. The loader appends C9h.
  - Generic builds also need page zero left intact.
  - The code may change IX, IY and the alternate registers: the Z80 interpreter restores IX and IY itself.
  - Under CP/M, print through the BDOS: page zero is the system's, so `RST 28h` is only for the generic builds.
- **6502, both:** entered as a subroutine (`JMP (T0)`, with a return address on the stack), ending in RTS (60h, appended by the loader). The address has been dropped. The code must keep the IP at $00/$01 and leave the hardware stack balanced.
  - **`b8s-6502.asm`:** TOS is at $02/$03. X is the data-stack index; NOS is $0200,X (low) and $0300,X (high). To push: DEX, store TOS there, then set TOS. To drop: load TOS from there, then INX. The code may change A, X (consistently), Y, $04-$06 and $08-$09; $0A-$0F is free for its own use.
  - **`b8s-6502-zp.asm`:** X is the data-stack pointer. TOS is at 0,X (low) and 1,X (high), NOS at 2,X and 3,X. To push: DEX, DEX, then store. To drop: INX, INX. The code may change A, Y and X (consistently); $02, $03, $07 and $0A-$0D are free for its own use. $0C-$0D keep their values only while the code runs: a `$` that prints a variable escape with the data stack full writes there.
- **6809:** entered by a jump, with the dispatcher's return address on S, so the code ends in RTS (39h, appended by the loader).
  - U points at the top data cell, which becomes TOS on return. Cells on the data stack are big-endian (6809 order); cells in memory stay little-endian, as the spec says.
  - The code may change A, B, X, CC and U (consistently). It must keep Y (the IP) and DP, and leave S balanced.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## The two 6502 interpreters

| | `b8s-6502.asm` | `b8s-6502-zp.asm` |
|---|---|---|
| Data stack | pages 2 and 3, 252 cells, low and high bytes in separate pages; TOS in zero page | zero page $10-$EF, 112 cells, each cell two bytes side by side |
| Zero page used | $00-$09 ($07 is the held key in the unchecked build, and with $06 the place of the character being run in the checked one) | $00, $01, $04-$06, $08, $09, and the stack ($0E-$0F are scratch when it is full). A checked build's report also uses $02, $03, $0A and $0B, after the program has stopped |
| Dispatch table (small and base) | whole addresses (64 bytes) | one byte each (32 bytes), with the layout rules above |
| Size, small (`ANSI = 0`) | 1,208 / 1,707 checked | 1,155 / 1,673 checked |

The zero-page one is smaller because a cell that holds an address is used as the pointer where it lies (`(0,X)`), a drop is two `INX`, and the 16-bit operators work a byte at a time through one short routine called twice. Machine code written for one needs changing for the other: see the contracts below.

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## Speed

Every source builds in three tiers, set by `SPEED`. They come from the same source, pass the same tests and run any program the same way, with the same machine interface but for the differences named below; the spec's [Speed](../docs/b8script.md#speed) section says what each idea does and why.

- **small** (`SPEED = 0`) is tuned for size. Its files are in each CPU's `small/`.
- **base** (`SPEED = 1`, the default) adds the speed-ups that cost least, about 120 to 330 bytes, and is 1.1 to 1.6 times as fast as small. It goes with every build. Its files are in each CPU's `base/`.
- **fast** (`SPEED = 2`) is base and everything else, size no object: 4 to 9 KB, 1.7 to 3 times as fast as small on the 8-bit CPUs and 2.7 to 4.6 times on Windows. It is built for running benchmarks. It goes with every build except the Z80's line editor; Windows has fast editor builds. Its files are in each CPU's `fast/`.

**What base adds:**

- **A skip cache.** Nearly every skip has happened before (a loop skips the same false block on every pass), so the end of each is remembered: 64 entries in a page of RAM, and the next skip from the same place is one lookup. Only skips that start in the program text are kept, and the cache is emptied whenever a run starts (in the editor builds, at every line too). A program that changes its own text while it runs is unsafe in the base and fast builds (the spec says so).
- **A faster skip.** Two range tests rule out most characters before the few that matter are tested.
- **`*` faster for a small operand** on the 8-bit CPUs.
- **`/` by a power of two** as a shift: `256/` for a high byte, the 32 and 64 of fixed point.
- **A true `)`** reads its block start in place.
- **A variable then `@` or `!`** in one step (unchecked builds).

**How each CPU does it:**

| CPU | Skip cache | `*` | True `)` |
|---|---|---|---|
| Z80 | The page at the heap limit, F000h with the default `HEAPLIM`, which the heap never reaches; under CP/M the page after the image, before the return stack | 8 rounds when either operand is below 256 | Added |
| 8080 | The same as the Z80 | The small operand becomes a byte multiplier, with a shorter round; otherwise 8 rounds for the low byte, then the high byte as a small multiplier | Added |
| 6502, pages 2-3 | DF00h, with the heap limit moved down a page to it | 8 rounds when either operand is below 256 | Added |
| 6502, zero page | 0200h, page 2, which this interpreter doesn't otherwise use | The same | Added |
| 6809 | The page below the ROM, EF00h (DF00h in the fast build), with the heap limit moved down to it | It already uses MUL: a cross term is skipped when a high byte is 0 | Already in the small build |
| Windows | Outside the 64 KB of B8Script memory | Not needed: x86 has IMUL | Already in the small build |

Under CP/M the skip cache's page comes before the return stack, so the letter page is still the one just below the program text, and the break-off cell is at offset 7Bh of it; the spec's appendices give its address in every .COM file.

**What fast adds**, besides all of base:

- **The inner loop is a table:** 256 entries, so a character goes straight to its handler, instead of through the chain of range tests and table of low bytes that small and base use.
- **That dispatcher is inline** at the end of the fast build's own entries, so there is no jump back to the loop.
- **One entry for each letter and digit.** A variable loads its own cell's address, and is fetched or stored in the same step when `@` or `!` follows (unchecked builds). A word call reads its own cell. A one-digit number needs no loop.
- **The commonest punctuation is written for the table:** `+ - : ; % @ , < = > & | ^ ~ * ( ) ]`, and `!` and `.` in the unchecked builds (Windows adds more). The rest reach the shared handlers through a short thunk.
- **`*` and `/` unrolled** where the CPU has no instruction for them.

A checked fast build can be smaller than its unchecked one: the unchecked one's 26 variable entries each also do `@` and `!`.

**Each CPU's table and dispatcher, in the fast build:**

| CPU | Table | Dispatch | Notes |
|---|---|---|---|
| Z80 | Low bytes in one page, high bytes in the next (512 bytes) | `LD A,(BC) / INC BC / EX DE,HL / LD L,A / LD H,page / LD A,(HL) / INC H / LD H,(HL) / LD L,A / JP (HL)` | Every entry starts with TOS in DE. Other handlers end with `JP (IX)` |
| 8080 | The same, padded onto a page boundary | `LDAX B / INX B / XCHG / MOV L,A / MVI H,page / MOV A,M / INR H / MOV H,M / MOV L,A / PCHL` | A second entry, for results already in DE, saves two XCHGs. `*` isn't unrolled (a jump takes 10 cycles either way, so it gains nothing); `/` is |
| 6502 | Low bytes in one page, high bytes in the next, at E000h-E1FFh | `LDA (IP),Y`, step IP, then the two bytes into a zero-page vector and `JMP (vector)`, a cycle faster than RTS | The code starts at E200h: point the reset vector there. No self-modifying code, so it runs from ROM |
| 6809 | 256 whole addresses | `LDB ,Y+ / LDX #table / ABX / ABX / JMP [,X]`, 21 cycles | The image starts at E000h, and the heap limit and skip cache are at DF00h |
| Windows | 256 whole addresses, plus one for the character after a digit | `movzx eax,byte [esi] / inc esi / jmp [table+eax*4]` | Its own copy of the indirect jump at the end of every hot handler, which also suits a modern CPU's branch prediction |

**How much faster**, against the small build of the same CPU, on the generic builds (Windows: the runner), with the same output every time. Measured in clock cycles, except on Windows, where the count is instructions:

| Program | Z80 | 8080 | 6502 | 6502, zero page | 6809 | Windows |
|---|---|---|---|---|---|---|
| **base** | | | | | | |
| SIEVE, 1 pass | 1.09× | 1.09× | 1.10× | 1.11× | 1.10× | 1.11× |
| PI, 100 digits | 1.21× | 1.16× | 1.20× | 1.21× | 1.14× | 1.12× |
| MANDEL | 1.36× | 1.40× | 1.37× | 1.38× | 1.40× | 1.22× |
| Tiny BASIC, a short program | 1.42× | 1.44× | 1.49× | 1.51× | 1.42× | 1.57× |
| Robots, scripted play | 1.18× | 1.18× | 1.17× | 1.18× | 1.16× | 1.19× |
| Reversi, scripted play | 1.47× | 1.49× | 1.49× | 1.51× | 1.52× | 1.49× |
| Qubic, scripted play | 1.26× | 1.28× | 1.28× | 1.29× | 1.28× | 1.28× |
| Tetris, scripted play | 1.13× | 1.12× | 1.16× | 1.16× | 1.16× | 1.10× |
| **fast** | | | | | | |
| SIEVE, 1 pass | 2.24× | 2.30× | 2.18× | 2.23× | 2.26× | 3.32× |
| PI, 100 digits | 2.05× | 1.98× | 1.90× | 1.87× | 1.94× | 3.12× |
| MANDEL | 2.53× | 2.69× | 2.45× | 2.52× | 2.50× | 3.47× |
| Tiny BASIC, a short program | 2.56× | 2.59× | 2.71× | 2.74× | 2.81× | 4.61× |
| Robots, scripted play | 2.10× | 2.24× | 1.96× | 1.96× | 2.18× | 2.81× |
| Reversi, scripted play | 2.56× | 2.65× | 2.66× | 2.72× | 2.95× | 3.92× |
| Qubic, scripted play | 2.35× | 2.48× | 2.48× | 2.55× | 2.64× | 3.70× |
| Tetris, scripted play | 1.69× | 1.76× | 1.78× | 1.76× | 2.05× | 2.68× |

The small builds' own counts, for SIEVE's pass: 56.8 M cycles on the Z80, 58.1 M on the 8080, 38.5 M and 37.7 M on the two 6502s, 24.0 M on the 6809 and 4.8 M x86 instructions. Tetris gains least everywhere because much of its time is spent in `n?` waits, which are timed and rightly don't get shorter.

To build the tiers, see [Building](#building).

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)

## How they were tested

Every build runs, in an emulator, against a reference interpreter written from the spec (`testing/ref.py`):
- every example program in the spec;
- edge cases for `/`, compares, number wrap, string escapes, skips over strings, `\`, `[x`, `[ `, `{]` jumps, heap mark and release with a signed `_`, the hex loader, `0?`, `n?`, `-n?` with editing, and deep stacks;
- Tiny BASIC (`programs/TINYBAS.B8S`), driven with a typed program (entering, LIST, RUN, GOSUB, FOR, expressions);
- a machine-code test per CPU (and per interpreter on the 6502);
- the break key, on unchecked and checked builds alike: Ctrl-C in a loop, in a chain of word calls and in `?`; the held key, the newest key winning, `?` taking the held key first; the break-off cell, with one Ctrl-C, two quick ones and two slow ones; and a count of how often KEY is called;
- for checked builds, every error in the table, several ways each, with the whole report compared byte for byte against the reference (run with that build's own addresses); the stack overruns are compared against patterns, since stack sizes differ.

The Z80's eight editor builds (four in small, four in base) are tested by typing at them (`testing/test_editor.py`), each step when the editor is waiting for it, against a model of the editor that follows the source key for key, echo included: entering, inserting, deleting, listing from any line, holding the list and ending it with Ctrl-C, running, 300 lines, full-length lines, the arrow keys, Esc, editing a line in place, new, the data stack lasting between lines, and programs that read lines and keys. The generic ones also paste a program in (with every kind of line end) and print it out; the CP/M ones read and write files on a small emulated disk; the checked ones also hit errors and Ctrl-C and carry on in the editor.

The six small CP/M .COM files have also run under real CP/M 2.2, Digital Research's own BDOS and CCP, in z80pack's `cpmsim` (`testing/cpmsim.py`). There the suite's programs (all but two that need a clock or Z80 machine code) gave the reference's output on every build, on a Z80 that traps undocumented opcodes, and the 8080 builds also on an 8080. The one difference, everywhere, was the byte FEh in a string, which that BDOS doesn't print (see The language). Both editor builds were also driven by hand there: listing, running, a typed line, `/~`, an error, Ctrl-C, writing a file and reading it back. The Z80 builds don't run on an 8080 or 8085 (they use Z80 instructions throughout); use the 8080 builds there.

The Windows builds run in the Unicorn emulator (`testing/harness_win32.py`): the .EXE is mapped as Windows would map it, and the dozen `kernel32` calls it makes are modelled. They go through the same suite as the others, the break-key tests and the editor sessions included, plus a few tests of their own (the report on standard error, redirected input, the arrow keys, the command line). That tests the interpreter, and the header against the rules; it can't show that Windows itself accepts the file, or that the model of each call is right.

Every full-size game, and every program in `programs/` but MON, is also run on every build against the reference, for as far as a short run gets (`testing/gamecheck.py`); SIEVE, PI, MANDEL and MON are run in full, and MON's R with each CPU's own return instruction (`testing/test_programs.py`). Each full-size game is in two files, `NAME.TXT` with comments that explain it and `NAME.B8S` stripped from it (`testing/b8strip.py`), and both are run (IDOL's `.TXT` is documentation only, so only its `.B8S` is). The reference plays scripted games of all 21 full-size games to a win, a loss or a known message (`testing/test_games.py`), and of the 21 tiny ones (`testing/test_tweets.py`). The test setup is in `testing/` (see its README).

[↑ Back to top](#b8script-interpreters-z80-8080-6502-6809-and-windows)
