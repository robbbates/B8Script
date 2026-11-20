# Prompts for Claude Code

Use these to hand this folder to a new session. Use a strong model at high effort: the work is tight assembly with a test loop.

---

## 1. Handoff: general changes

```
I'm Robb. I designed B8Script, a postfix language where every instruction is
one ASCII character and the source runs in place. This folder holds
minimum-size B8Script interpreters:

- z80/, 8080/, 6502/, 6809/ each hold one commented source, b8s-<cpu>.asm,
  with switches at the top: CPM EQU 0/1 (Z80 and 8080), CHECKED EQU 0/1
  (all), ZPSTACK EQU 0/1 (6502: data stack in zero page).
- README.md covers sizes, the language where it differs from the old spec,
  memory maps, the console interface (KEY/CONOUT/EXIT), the checked builds'
  error letters, the machine-code contracts and the layout rules.
- testing/ holds the build script, the reference interpreter, the test
  suite, emulator harnesses for every CPU and the layout checkers;
  testing/README.md shows how to run them.

Read README.md and testing/README.md first. Things that are easy to break:
- Z80, 8080 and the unchecked 6809 use a one-byte dispatch table, which
  puts rules on where handlers sit. Run testing/chktab.py and
  testing/chktab09.py on the listings after every change.
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

- 6502: the punctuation table still holds whole addresses (64 bytes). A
  one-byte table with the handlers grouped by page, as on the Z80, should
  save about 20-26 bytes. The catch is the handlers that fall into each
  other across far-apart table positions ('!' into '.' into ';').
- 6502 with ZPSTACK = 1: the code is the same as for the stack in pages
  2-3. Code written for the zero-page stack alone (cells as two adjacent
  bytes, shared 16-bit helpers through X) could be smaller still.
- 6809, checked: it keeps a whole-address table because its code is bigger
  than the two ranges of the one-byte scheme. A third range, or moving the
  checked-only routines, might get it back.
- Z80/8080: the first 256 bytes are packed by hand around the RST vectors;
  one spare byte remains on the Z80.

Report a table of bytes before and after for every variant, the techniques
that paid off, and the ones you tried that didn't.
```
