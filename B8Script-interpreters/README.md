# B8Script interpreters: Z80, 8080, 6502, 6809

Generic interpreters for minimal homebrew machines (serial console only), plus CP/M 2.2 versions for the Z80 and 8080. Each CPU has one source with two switches at the top:

```
CPM     EQU     0               ; 1 = CP/M .COM build
CHECKED EQU     0               ; 1 = checked build
```

The 6502 and 6809 have no CP/M build, so their `CPM` line is always 0.

## Sizes (bytes, measured)

| CPU | Generic | Generic, checked | CP/M | CP/M, checked | My estimate (generic / checked) |
|---|---|---|---|---|---|
| Z80 | 885 | 1,105 | 917 | 1,132 | ~700 / ~920 |
| 8080 | 944 | 1,166 | 963 | 1,174 | ~850 / ~1,100 |
| 6502 | 1,256 | 1,474 | n/a | n/a | ~1,050 / ~1,350 |
| 6809 | 886 | 1,084 | n/a | n/a | ~620 / ~800 |

- A generic size is the whole ROM image: the code plus the 64-byte punctuation table.
- The letter cells, stacks and line buffer are all in RAM, so they aren't counted.
- The CP/M size is the .COM file, which includes the program loader.

## Files

| File | What it is |
|---|---|
| `*/b8s-*.asm` | The source, with comments |
| `*-rom-XXXX.bin` | Generic ROM image, to load at XXXXh |
| `B8SZ80.COM`, `B8SZ80C.COM`, `B8S8080.COM`, `B8S8080C.COM` | CP/M builds; the C means checked. Run as `B8SZ80 PROG.B8S` |
| `*.lst` | The assembler's listings |

## Building

The sources use asm80, from npm (`npm install asm80`):

```
node asm80.js -m Z80 -t hex -o b8s-z80.hex b8s-z80.asm
```

The machine name is `Z80`, `I8080`, `C6502` or `M6809`. To build a variant, edit the two EQU lines first.

asm80 has some quirks the sources work around:
- `IF`/`IFN`/`ENDIF` must not be nested, and there is no `ELSE`. Combined conditions are written as arithmetic, like `IF (1-CPM)*CHECKED`.
- A label on the same line as an `IF` is lost.
- `'"'` doesn't parse, so it's written `22h`.
- In I8080 mode it assembles `RST 08h` wrongly. Write `RST 1` and `RST 2`.
- In C6502 mode it accepts some out-of-range branches without an error. These builds were checked separately for that.

## Generic machine interface (edit the equates)

| | Z80 / 8080 | 6502 | 6809 |
|---|---|---|---|
| CONIN | wait for a key, return it in A | same | same |
| CONOUT | print A | same | same |
| CONST | A = 0 if no key is waiting | same | same |
| EXIT | jumped to when the program ends | same | same |
| Console routines must keep | BC, DE, HL (and HL' on the Z80) | X, Y | B, X, Y, U, DP |
| Where to start | reset at 0000h | label `start`, E000h (point the reset vector at it) | label `start`, F08Ah (point the reset vector at it) |
| RAM | RS 8000h, DS 8100h, letters 8200h, PROG 8300h | RS = page 1, DS 0200h/0300h, letters 0400h, PROG 0500h | RS 8000h (S), DS 8100h (U), letters 8200h (DP), PROG 8300h |
| Heap limit | `HEAPLIM` (page), default F0h | default E0h | default F0h |
| Timing | `MSLOOP` = loop passes per millisecond for `n?`; tune it to your clock and CONST | same | same |

Your loader puts the program text, ending in a NUL, at `PROG`. The heap starts after the NUL.

## What's implemented

Everything in the spec, plus the 2026-11-20 changes:
- `[x` stores the address in a variable.
- `[` followed by a space pushes an anonymous block.
- Any other character after `[` is an error.
- The heap pointer lives at `z10+`.

Interpretations to be aware of:
- **CP/M line input.** `-n?` uses BDOS 10, which brings its own editing keys, ends a full line by itself, and echoes a CR. The interpreter appends the CR to the stored text. Every other character goes through BDOS 6, because BDOS 2 can swallow typed keys.
- **Checked store range.** "The program's own space" runs from the letter page up to the heap limit, not just up to the heap top. Tiny BASIC keeps its program lines above the heap top without allocating them, so the stricter rule would stop it.
- **Stack checks.** These happen once per character, not in every handler. An overrun is caught at most a cell late. A guard band above the return stack absorbs calls made while the data stack is full. The stacks hold 127 data cells and 112 return entries (Z80/8080), 252 and about 100 (6502), or 127 and 127 (6809).
- **Ctrl-C** (checked builds) is checked at every `)` loop-back and every return. Other keys pressed meanwhile are held for the next `?`.
- **Error report** (checked builds): CR LF, then one of `stack`, `return`, `break`, `heap`, `store` or `[`, then ` at ` and the offset in the program.

## Machine-code contracts (the grave)

- **Z80 / 8080:** as in the spec. Entered by CALL, with the data cells above the return address. The code must keep BC. On return, the top cell becomes TOS. The loader appends C9h.
  - Generic builds also need page zero left intact.
  - The Z80 saves and restores HL' itself, so the code may use the alternate registers.
- **6502:** entered as a subroutine (`JMP (T0)`, with a return address on the stack), ending in RTS (60h, appended by the loader).
  - TOS is at $02/$03. X is the data-stack index; NOS is $0200,X (low) and $0300,X (high).
  - To push: DEX, store, then set TOS. To drop: load, then INX.
  - The code may change A, X (consistently), Y, $04-$06 and $08-$0B. It must keep the IP at $00/$01 and leave the hardware stack balanced. $0C-$0F is free for its own use.
- **6809:** entered by a jump, with the dispatcher's return address on S, so the code ends in RTS (39h, appended by the loader).
  - U points at the top data cell, which becomes TOS on return. Cells on the data stack are big-endian (6809 order); cells in memory stay little-endian, as the spec says.
  - The code may change A, B, X, CC and U (consistently). It must keep Y (the IP) and DP, and leave S balanced.

## How they were tested

Every build runs, in an emulator, against a reference interpreter written from the spec:
- every example program in the spec;
- edge cases for `/`, compares, number wrap, string escapes, skips over strings, `\`, `[x`, `[ `, `{]` jumps, heap mark and release, the hex loader, `0?`, `n?`, `-n?` with editing, and deep stacks;
- your Tiny BASIC, driven with a typed program (entering, LIST, RUN, GOSUB, FOR, expressions);
- a machine-code test per CPU;
- for checked builds, every error plus Ctrl-C.

The test setup is in `testing/` (see its README). One spec change is not in this code yet: the string escape becomes `/` instead of `>`. Prompt 3 in `PROMPTS.md` covers it.
