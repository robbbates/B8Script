# B8Script interpreters: Z80, 8080, 6502, 6809

Generic interpreters for minimal homebrew machines (serial console only), plus CP/M 2.2 versions for the Z80 and 8080. Each CPU has one source with switches at the top:

```
CPM     EQU     0               ; 1 = CP/M .COM build        (Z80, 8080)
CHECKED EQU     0               ; 1 = checked build          (all four)
ZPSTACK EQU     0               ; 1 = data stack in zero page (6502)
EDITOR  EQU     0               ; 1 = with the line editor   (Z80, generic unchecked only)
```

## Sizes (bytes, measured)

| CPU | Generic | Generic, checked | CP/M | CP/M, checked |
|---|---|---|---|---|
| Z80 | 673 | 820 | 736 | 885 |
| Z80 with the line editor | 767 | n/a | n/a | n/a |
| 8080 | 749 | 904 | 796 | 953 |
| 6502, stack in pages 2-3 | 1,087 | 1,252 | n/a | n/a |
| 6502, stack in zero page | 1,053 | 1,218 | n/a | n/a |
| 6809 | 741 | 920 | n/a | n/a |

- A generic size is the whole ROM image: the code plus the punctuation table.
- The letter cells, stacks and line buffer are all in RAM, so they aren't counted.
- The CP/M size is the .COM file, which includes the program loader.

## Files

| File | What it is |
|---|---|
| `*/b8s-*.asm` | The source, with comments |
| `*-rom-XXXX.bin` | Generic ROM image, to load at XXXXh (`-zp-` = 6502 with the stack in zero page, `-editor-` = Z80 with the line editor) |
| `B8SZ80.COM`, `B8SZ80C.COM`, `B8S8080.COM`, `B8S8080C.COM` | CP/M builds; the C means checked. Run as `B8SZ80 PROG.B8S` |
| `*.lst` | The assembler's listings |

## The language, where it differs from the 2026-10-09 spec

- `[x` stores the address in a variable; `[` followed by a space pushes an anonymous block; any other character after `[` is an error.
- The heap pointer lives at `z10+`.
- The string escape is `/` (it was `>`): `/M` is CR, `/"` a quote, `//` a slash. `>` is an ordinary character inside strings. A `/` directly before a closing quote escapes the quote, in comments too.
- `/` is `( a b -- r q )`: the quotient is on top. `/;` gives the remainder and `/%;` the quotient.
- Dividing by zero is not checked. It returns two cells of no meaning (different on each CPU), and the stack stays balanced.
- There is no fast path for dividing by 2.
- `-n?` (generic builds): Backspace takes a character back and is echoed as it is; every other key but CR is stored and echoed, control keys and DEL included. `n` is not checked: the buffer holds 127 characters and the CR, so **a program must ask for 127 or fewer**, or the line can run into the start of the program text. The CP/M builds use BDOS 10, which does its own editing.

## Building

The sources use asm80 1.11.14, from npm (`npm install -g asm80@1.11.14`):

```
node asm80.js -m Z80 -t hex -o b8s-z80.hex b8s-z80.asm
```

The machine name is `Z80`, `I8080`, `C6502` or `M6809`. To build a variant, edit the EQU lines first, or use `testing/build.sh`, which builds every variant.

asm80 has some quirks the sources work around:
- `IF`/`IFN`/`ENDIF` must not be nested, and there is no `ELSE`. Combined conditions are written as arithmetic, like `IF (1-CPM)*CHECKED`.
- A label on the same line as an `IF` is lost.
- `'"'` doesn't parse, so it's written `22h`.
- In I8080 mode it assembles `RST 08h` wrongly. Write `RST 1` to `RST 6`.
- In C6502 mode it accepts some out-of-range branches without an error. Run `testing/chkbr6502.py` on every listing.
- A division inside a longer expression is not rounded down; only a value stored by `EQU` is. The page arithmetic is one division to a line for that reason.
- `abs` is a function name and can't be a label.
- Version 0.9.x assembles the inside of a false `IF`, so it can't build these.

## Layout rules the assembler can't check

To save the 32 bytes of a full address table, the Z80, the 8080 and the unchecked 6809 keep one byte per punctuation character and work the rest of the handler's address out from the character's place in the table. That puts rules on where handlers sit:

- **Z80, 8080:** the handlers of the first `NPG1` characters (in code order) start in the image's second 256 bytes, the rest in its first. `NPG1` is worked out by the assembler from where `] \ [ @` landed, so the split moves by itself when code grows or shrinks.
- **6809, unchecked:** the same idea with two 256-byte ranges after the table. The checked 6809 build is too big for that and keeps a table of whole addresses.
- **Z80, 8080:** the RST routines must sit at their vectors.

`testing/chktab.py` (Z80, 8080) and `testing/chktab09.py` (6809) check all of this on the listings. Run them after any change; each says how many bytes are to spare.

## Generic machine interface (edit the equates)

| | Z80 / 8080 | 6502 | 6809 |
|---|---|---|---|
| KEY | return a waiting key in A, or A = 0 if none is waiting; the zero flag must match A | same | same |
| CONOUT | print A | same | same |
| EXIT | jumped to when the program ends | same | same |
| KEY and CONOUT must keep | BC, DE, HL (and HL' on the Z80) | X, Y | B, X, Y, U, DP |
| Where to start | reset at 0000h | label `start`, E000h (point the reset vector at it) | label `start`: F003h unchecked, F037h checked (point the reset vector at it) |
| RAM | RS 8000h, DS 8100h, letters 8200h, PROG 8300h | RS = page 1, DS 0200h/0300h (or zero page), letters 0400h, PROG 0500h | RS 8000h (S), DS 8100h (U), letters 8200h (DP), PROG 8300h |
| Heap limit | `HEAPLIM` (page), default F0h | default E0h | default F0h |
| Timing | `MSLOOP` = loop passes per millisecond for `n?` (1-255); tune it to your clock and KEY | same | same |

- There is one input routine, KEY. It replaces the earlier CONST and CONIN: `0?` waits by calling KEY until a key comes.
- Your loader puts the program text, ending in a NUL, at `PROG`. The heap starts after the NUL.
- The generic Z80 and 8080 images start at 0000h and use RST 08h, 18h, 20h, 28h and 30h as one-byte calls.
- The CP/M builds copy those routines to 0008h-0033h when they start (they used 0008h-0014h before). A system whose interrupts use RST 1 to RST 6 can't run them.

## The Z80 line editor (EDITOR = 1)

The whole image is 767 bytes: the interpreter and an editor in one byte less than VTL-2's 768. The interpreter starts in the editor, and a program that ends comes back to it. There is no prompt. Type a line and press Return:

| You type | What happens |
|---|---|
| `n text` | The text goes in as line n, and the lines from n on move down. A number past the end adds the line at the end |
| `n` | Line n is taken out |
| `0` | The program is listed |
| `0 text` | The text is added at the end |
| anything not starting with a digit | It runs at once, as B8Script |
| ` 33536{]` | Runs the program (a jump to PROG, 8300h; the leading space keeps the number from being a line number) |

What the 94 bytes don't buy:
- Lines are counted, not numbered. The list shows no numbers, and only the first 128 lines; a line number above 128 lists part of the program on its way there.
- A line holds 125 characters. The space after the line number is stored with the text.
- Reset empties the program. There is no save or load.
- Nothing is checked, and nothing is printed between a program's output and what you type next.
- Putting a line in moves the rest of the program up one byte for each character typed: fine for a few hundred bytes, slow in a long program.
- Words and variables last from one line to the next, so you can call a word from the keyboard after running the program. A word's address points into the program text, so run the program again after editing it.
- A line run at once sits in the line buffer, which `-n?` also reads into. A program started with `{]` never returns to the line, so it can use `-n?` freely; a typed line that calls `-n?` itself and carries on afterwards runs what was typed.

## Checked builds

A checked build stops with a letter, ` @ ` and the offset in the program of the character it was reading, like `S @ 245`:

| Letter | Meaning |
|---|---|
| `S` | data stack over or under |
| `R` | return stack over or under |
| `B` | Ctrl-C |
| `H` | heap past the limit |
| `W` | a store outside the program's own space |
| `D` | a character other than a letter or a space after `[` |

- Nothing is printed before the letter: no CR LF.
- **Store range.** "The program's own space" runs from the letter page up to the heap limit, not just up to the heap top. Tiny BASIC keeps its program lines above the heap top without allocating them, so the stricter rule would stop it.
- **Stack checks.** These happen once per character, not in every handler. An overrun is caught at most a cell late, so the offset printed can be one character late. A guard band above the return stack absorbs calls made while the data stack is full. The stacks hold 127 data cells and 112 return entries (Z80/8080), 252 or 112 and about 100 (6502), or 127 and 127 (6809).
- **Ctrl-C** is checked at every word call, block entry, loop-back and `{` (Z80, 8080), or at every `)` loop-back and every return (6502, 6809). Other keys pressed meanwhile are held for the next `?`.
- **Unchecked builds and `[`.** They don't look at the character: anything below `A` is taken as the space, anything from `A` up as a letter.

## Machine-code contracts (the grave)

- **Z80 / 8080:** as in the spec. Entered by CALL, with the data cells above the return address. The code must keep BC. On return, the top cell becomes TOS. The loader appends C9h.
  - Generic builds also need page zero left intact.
  - The Z80 saves and restores HL' itself, so the code may use the alternate registers.
- **6502:** entered as a subroutine (`JMP (T0)`, with a return address on the stack), ending in RTS (60h, appended by the loader).
  - TOS is at $02/$03. X is the data-stack index; NOS is $0200,X (low) and $0300,X (high), or $10,X and $80,X when the stack is in zero page.
  - To push: DEX, store, then set TOS. To drop: load, then INX.
  - The code may change A, X (consistently), Y, $04-$06 and $08-$09. It must keep the IP at $00/$01 and leave the hardware stack balanced. $0A-$0F is free for its own use.
- **6809:** entered by a jump, with the dispatcher's return address on S, so the code ends in RTS (39h, appended by the loader).
  - U points at the top data cell, which becomes TOS on return. Cells on the data stack are big-endian (6809 order); cells in memory stay little-endian, as the spec says.
  - The code may change A, B, X, CC and U (consistently). It must keep Y (the IP) and DP, and leave S balanced.

## The 6502's two stack layouts

`ZPSTACK = 0` keeps the data stack in pages 2 and 3 (252 cells). `ZPSTACK = 1` moves it to zero page: low bytes at $10-$7F, high bytes at $80-$EF, 112 cells. The code is the same; the zero-page build is 34 bytes smaller because every stack access is a byte shorter. Machine code written for one layout needs its stack addresses changed for the other.

## How they were tested

Every build runs, in an emulator, against a reference interpreter written from the spec:
- every example program in the spec;
- edge cases for `/`, compares, number wrap, string escapes, skips over strings, `\`, `[x`, `[ `, `{]` jumps, heap mark and release, the hex loader, `0?`, `n?`, `-n?` with editing, and deep stacks;
- your Tiny BASIC, driven with a typed program (entering, LIST, RUN, GOSUB, FOR, expressions);
- a machine-code test per CPU (and per stack layout on the 6502);
- for checked builds, every error plus Ctrl-C.

The editor build is tested by typing at it (`testing/test_editor.py`): entering, inserting, deleting, listing, running, more than 128 lines, full-length lines, Backspace, and programs that read lines and keys.

The other eight games were also run on every CPU against the reference, for as far as a short run gets. The test setup is in `testing/` (see its README).

## Converting older programs

- `testing/esc2slash.py FILE...` rewrites sources that still use `>` as the string escape. Printed strings (`"..."$`) get the full conversion, so they print what they did before. Comments (`"...";`) and data strings are only touched where the closing quote would move. It lists every data string that holds a `/` or `>`, so you can check those by hand.
- `testing/divswap.py FILE...` rewrites sources written for `( a b -- q r )`: every `/` outside a string becomes `/%`, and a `/%%` that makes is cancelled. It lists data strings that hold a `/`, in case they are code.
- Both take `-n` to report without changing anything.
