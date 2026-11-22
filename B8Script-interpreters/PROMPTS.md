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
- The language is in ../docs/b8script.md, which the builds follow; its
  appendices hold each CPU's memory map and system addresses.
- README.md covers sizes, what the spec leaves to the builds, the console
  interface (KEY/CONOUT/EXIT), the break key, the line editor, the checked
  builds' errors and report, the machine-code contracts and the layout
  rules.
- testing/ holds the build script, the reference interpreter, the test
  suite, emulator harnesses for every CPU and the layout checkers;
  testing/README.md shows how to run them.

Read README.md and testing/README.md first. Things that are easy to break:
- A checked build's report is compared byte for byte with testing/ref.py,
  stack lines included. Most errors must show the stacks as they were
  before the failing character, so test before you pop.
- The break key: getk and the poll must be called straight from a handler
  (the checked report counts on the stack depth), and the Z80 and 8080
  need TOS in HL there.
- The Z80 editor tests model the editor key for key, echo included: change
  testing/test_editor.py together with the editor.
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
- 6502, b8s-6502-zp.asm: 1095 bytes. Its page layout has 68, 66 and 41
  bytes to spare in its three pages (46, 69 and 25 in the checked build,
  whose inner loop and skipper live after the third page).
- 6809, checked: it keeps a whole-address table because its code is bigger
  than the two ranges of the one-byte scheme (its handlers need about 550
  bytes). A three-range split was worked out on paper: it would save 13
  to 20 bytes, but needs a handler order the unchecked build can't share.
- Z80/8080: the first 256 bytes are packed by hand around the RST vectors.
- Z80 with EDITOR = 1: 1488 bytes, 723 of them the editor (four builds:
  with or without CPM and CHECKED). It was written for the spec's
  suggested standard and has had one light size pass. What is left needs
  a decision or a redesign: the key dispatch (seven compares and a
  27-byte table: a chain of SUB and JR would be about 10 bytes smaller if
  every unknown control key may drop the line), ^V (about 170 bytes in an
  unchecked build, since it brings in the stack listing), the paste's
  care with LF-only text (about 14 bytes), the CP/M file code (about
  135 bytes).
- Every checked build: the report (about 200 bytes on the Z80, 300 on the
  6502) was written once and not squeezed. The line and column count is
  the biggest part of it.
- Every build: the break-off cell and its 250 ms wait for a second Ctrl-C
  is about 30 bytes.

Report a table of bytes before and after for every variant, the techniques
that paid off, and the ones you tried that didn't.
```

---

## 3. Bring the interpreters up to the 2026-11-21 spec

Model: Claude Opus 5.5, effort high.

```
I'm Robb. Read, in this order: docs/b8script.md (the new spec, now the
source of truth), B8Script-interpreters/README.md, testing/README.md, and
prompt 1 in B8Script-interpreters/PROMPTS.md, whose rules all apply here.
Work on a branch off the spec branch (spec-2026-11) and open one pull
request. Commit after each stage below, with every build of every CPU
passing its tests at each commit.

The spec changed in the ways listed here. Where this list and the spec
disagree, the spec wins; ask me if it is unclear.

Stage 1: language and checked builds (all CPUs, all variants)
 1. `_` takes a signed count: a negative count releases. Unchecked builds
    need no change (a 16-bit add is the same signed or unsigned). Checked
    builds stop with H when the new top is past the heap limit OR below
    the program's end (the first byte after the program's NUL).
 2. Error letters change: data stack overflow S / underflow s, return
    stack overflow R / underflow r, store outside the program's space O
    (was W), bad character after [ is W (was D). New: U undefined word,
    Q missing closing quote (a string skip reaching NUL, or $ reaching
    NUL), X reserved byte 80h-FFh outside a string, Z divide by zero,
    N unbalanced or mismatched brackets. B stays.
 3. N: a skip started by a false ( or by [ that reaches NUL, or reaches a
    closer of the wrong kind at its own level (( expects ), [ expects ]).
    \ with no closer still ends the program. Report the place of the
    opener where the skip started.
 4. U: at startup a checked build points every word cell at one internal
    byte that stops with U, reporting the return address on top of the
    return stack as the place. Checked builds also zero all 26 variables
    at startup. One-shot CP/M builds may keep the word and variable cells
    over their startup code if the fill loop sits outside that area.
 5. The hex loader's stores are no longer range-checked (remove chkst or
    its equivalent there). Machine code is never checked.
 6. The error report, exactly as in the spec: CR LF, then
      Err X @ line,col
      <up to 16 raw characters from the place, stopping at CR, LF or NUL>
      Stk n: <up to the top 8 values, bottom to top, "..." if more>
      Rtn n
    Lines and columns count from 1; a line typed at the editor is line 0;
    values up to 32767 must print right (the unsigned routine is fine).
    The stack lines show the stacks as they were at the error.
 7. After an error or a break: one-shot builds go to EXIT; editor builds
    go back to the editor with both stacks cleared, words and variables
    kept. On every stop restore the host's stack pointer (see "Host
    stacks" under The break key in the spec).
 8. Unchanged but check it: dividing by 2 or -2 stays fast; reserved
    bytes stay ignored in unchecked builds.

Stage 2: the break key in every build
 9. Unchecked builds now stop on Ctrl-C too. Poll at the true ) loop-back
    and at every word call, through an 8-bit countdown so KEY is called
    at most once every 256 such points (checked builds may poll every
    time, as now, or use the countdown). A key other than Ctrl-C is held
    for the next ?, and a newer key replaces the held one. ? takes the
    held key first.
10. A break-off cell: one byte in the letter page's gaps. Nonzero means
    a single Ctrl-C is passed to the program as an ordinary key (03h).
    Two Ctrl-Cs within about 250 ms always break. Fill in its address in
    every appendix of docs/b8script.md (hex, unsigned, signed), replacing
    the TBD entries.
11. What an unchecked build prints on a break is up to you; keep it tiny
    (nothing, or "B").

Stage 3: the Z80 line editor (EDITOR = 1, with either CHECKED setting)
12. Replace the editor's commands with the suggested standard in the
    spec's Environments chapter: n text inserts, n alone deletes,
    anything else runs at once; ^G run, n^L list (held by a key, ended by
    Ctrl-C), n^E edit line n, ^R and name^R read, ^W and name^W write,
    ^N ^N new, ^V view (both stacks, program size, free memory, line
    count, build name and version), ^X exit, Esc cancels the line (wait
    about 5 ms after Esc; if [ follows, read the sequence, act on C and D
    as right and left, ignore the rest), ^B ^F and the arrows move the
    cursor with insert and delete mid-line, Backspace and DEL delete.
    The old 0 (run) and -n (list) forms go.
13. The editor reads keys itself in the CP/M builds too (BDOS 6, not
    BDOS 10, which swallows control keys). -n? may keep BDOS 10.
14. Read and write: CP/M builds use files (open, read records to the
    first ^Z, make, write, close; a name typed before the key sets the
    current name). Generic builds read by paste (raw text until ^Z or
    ^@ replaces the program) and write by printing the raw text with
    CR LF line ends.
15. The data stack carries over between typed lines.

Tests and documents
16. Update testing/ref.py to the new spec (drop the z10+ assumption from
    its docstring; keep the heap where it is), add tests for every new
    error and its report, the startup fills, signed _, the break key in
    unchecked builds (held key, newest wins, break-off cell, double
    Ctrl-C) and the new editor keys (test_editor.py). Tests that read
    the old error format change to the new one.
17. Update B8Script-interpreters/README.md: sizes, the error table, the
    break key, the editor, and replace "The language, where it differs
    from the 2026-10-09 spec" with a short note that the builds follow
    docs/b8script.md. Fill in the measured sizes and any changed
    addresses in the spec's appendices. Update prompt 1 and 2 in this
    file if their facts changed.
18. Rebuild and refresh every .bin, .COM and .lst with mkrel.py.

Report a table of sizes before and after for every build, and anything in
the spec you found unclear, contradictory or costly, so I can decide.
```
