# Prompts for Claude Code

Use these to hand this folder to a new session. Use a strong model at high effort: the work is tight assembly with a test loop.

---

## 1. Handoff: general changes

```
I'm Robb. I designed B8Script, a postfix language where every instruction is
one ASCII character and the source runs in place. This folder holds
minimum-size B8Script interpreters:

- z80/, 8080/, 6502/, 6809/ each hold a commented source, b8s-<cpu>.asm,
  with switches at the top: CPM EQU 0/1 (Z80 and 8080), CHECKED EQU 0/1
  (all), EDITOR EQU 0/1 (Z80: a built-in line editor). 6502/ holds a
  second, smaller interpreter, b8s-6502-zp.asm, with its data stack in
  zero page.
- README.md covers sizes, the language where it differs from the old spec,
  memory maps, the console interface (KEY/CONOUT/EXIT), the checked builds'
  error letters, the machine-code contracts and the layout rules.
- testing/ holds the build script, the reference interpreter, the test
  suite, emulator harnesses for every CPU and the layout checkers;
  testing/README.md shows how to run them.

Read README.md and testing/README.md first. Things that are easy to break:
- Z80, 8080, the unchecked 6809 and the zero-page 6502 use a one-byte
  dispatch table, which puts rules on where handlers sit. Run
  testing/chktab.py, chktab09.py and chktab6502.py on the listings after
  every change.
- asm80 accepts some out-of-range 6502 branches. Run testing/chkbr6502.py.
- On the 6502 every punctuation handler starts with the carry clear, and
  several handlers count on it (the comments say where).
- asm80 quirks are listed in README.md (no nested IF, no ELSE, division
  only rounds down in an EQU, and more).

Rules:
- After every change, rebuild every variant of that CPU, run the checkers
  and the tests; never leave a failing build.
- Keep the comments accurate and somewhat verbose.
- Goal: minimum size; a few bytes for a big speed gain is fine.
- Don't change the language, the memory maps, the console interface or the
  machine-code contracts unless I ask.

My changes: [describe them here]
```

---

## 2. Another size pass

```
Read README.md and testing/README.md in this folder, then follow the rules
in prompt 1 of PROMPTS.md. Every build passes its tests now. Look for more
bytes, one CPU at a time. Ideas not yet tried:

- 6502, b8s-6502.asm: the punctuation table still holds whole addresses
  (64 bytes). The three-page one-byte scheme of b8s-6502-zp.asm would fit,
  but this interpreter's handlers lean on each other more (falling into
  each other, sharing `fin`), and the jumps needed to split them into
  three groups leave only about 11 bytes of the 32.
- 6502, b8s-6502-zp.asm: 1015 bytes. Its page layout has 32 and 31 bytes
  to spare in the second and third pages (16 in the checked build).
- 6809, checked: it keeps a whole-address table because its code is bigger
  than the two ranges of the one-byte scheme. A third range, or moving the
  checked-only routines, might get it back.
- Z80/8080: the first 256 bytes are packed by hand around the RST vectors.
- Z80 with EDITOR = 1: 877 bytes, 183 of them the editor (four builds:
  with or without CPM and CHECKED). It has no prompt and prints nothing
  after a program ends; the CP/M builds load a file but can't save one;
  a checked build's error gives a byte offset, not a line number.

Report a table of bytes before and after for every variant, the techniques
that paid off, and the ones you tried that didn't.
```
