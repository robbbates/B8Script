# Prompts for Claude Code

Unpack this zip into the working folder first. Use **Opus at high effort**: the work is tight assembly with a test loop, which is where a stronger model pays off.

---

## 1. Handoff: general changes

```
I'm Robb. I designed B8Script, a postfix language where every instruction is
one ASCII character and the source runs in place (spec: docs/b8script.md in
my repo robbbates/B8SIC). This folder holds minimum-size B8Script
interpreters written in an earlier session:

- z80/, 8080/, 6502/, 6809/ each hold one commented source, b8s-<cpu>.asm,
  with two switches at the top: CPM EQU 0/1 (Z80 and 8080 only) and
  CHECKED EQU 0/1.
- README.md covers sizes, memory maps, the console interface
  (CONIN/CONOUT/CONST/EXIT), the machine-code contracts and the design
  choices.
- testing/ holds the build script, the reference interpreter, the test
  suite and emulator harnesses for every CPU; testing/README.md shows how
  to run them.

The spec changes they implement (newer than the spec file):
- [x (lowercase) stores the body's address in variable x
- "[ " (a space) pushes an anonymous block's address
- [ followed by anything else is an error (the checked build stops)
- the heap pointer is a RAM cell at z10+
- letter cells: cell(c) = LET + 2*(c-41h)
- CP/M builds: -n? uses BDOS 10 (appends CR); every character uses BDOS 6
- the string escape character is '/' (it was '>'); testing/esc2slash.py
  converts older programs

Assembler: asm80 from npm. Its quirks:
- no nested IF and no ELSE (write combined conditions as arithmetic)
- a label on the same line as IF is lost
- write '"' as 22h
- in I8080 mode, write RST 1/RST 2 instead of RST 08h/10h
- in C6502 mode it accepts some out-of-range branches without an error
  (run testing/chkbr6502.py)

Rules:
- After every change, rebuild and run that CPU's tests; never leave a
  failing build.
- Keep the comments accurate and somewhat verbose.
- Goal: minimum size; a few bytes for a big speed gain is fine.

My changes: [describe them here]
```

---

## 2. Another size-optimization pass on all four CPUs

```
Read README.md and testing/README.md in this folder. It holds minimum-size
B8Script interpreters for the Z80, 8080, 6502 and 6809, each one source with
CPM/CHECKED switches, plus a full test setup in testing/. Every build passes
its tests now. Do one more size-optimization pass on each CPU, one CPU at a
time, and keep everything passing.

First, build every variant, run its tests and record the sizes
(testing/sizes.py) as the baseline. Then work through each source looking
for:
- Fall-throughs: reorder handlers so a jump becomes a fall-through, or a
  short branch instead of a long one (JR on the Z80; Bcc/BRA on the 6809;
  on the NMOS 6502, a branch on a flag you know the state of, in place of
  JMP).
- Shared endings: identical tails across handlers become one, reached by
  fall-through or a short branch.
- Near-twins: & | ^ differ by one opcode, = and < share setup, the
  line-editor paths overlap. Everything must stay ROM-able, so no
  self-modifying code.
- Tail calls: JP/JMP/BRA instead of CALL+RET; conditional calls and returns
  (CALL cc, RET cc on the Z80/8080).
- One-byte calls: on the Z80/8080, RST for anything called from many
  places, but only where a vector slot is genuinely free. RST 18h and up
  fall inside the inner loop in the generic builds, and CP/M owns RST 7.
- Addressing: 6809 auto-increment and indexed modes, LEA arithmetic,
  multi-register PSHU/PULU, direct page; 6502 zero page wherever possible.
- Register caching: for example, keep TOS in D on the 6809 if it saves
  bytes overall.
- The bigger routines: the inner loop's range sort, the line editor, the
  hex loader, skip, multiply, divide (the spec requires divide-by-2 to stay
  fast), number printing, and the checked builds' error reporting.
- CP/M builds (Z80, 8080): the startup and file-loader code runs once and is
  dead after the program is loaded, so its bytes can be reused. In these
  builds the letter cells, stacks and line buffer sit in RAM past the image,
  not in the .COM file, so overlaying them on the loader saves RAM, not file
  size. To shrink the file, look for data that IS in the image and could
  live in the loader's space instead, or for loader code that can double
  as something needed later. Report which of these, if any, actually
  reduces the .COM size.

Rules:
- After every change, rebuild that CPU and run its tests. While iterating,
  the 6502 and 6809 runs may use --nogames / -nogames, but run the full
  suite, Tiny BASIC included, before you call a CPU done.
- On the 6502, also run testing/chkbr6502.py on every listing.
- Never leave a failing build; revert anything that breaks.
- Keep the comments accurate and somewhat verbose; update them as code moves.
- Don't change the behaviour, the memory maps, the console interface, the
  machine-code contracts or the symbol names the harnesses read (PROG,
  CONIN, CONOUT, CONST, EXIT).
- Don't edit testing/ except to add tests. If a test looks wrong, tell me.

Report a table of bytes before and after for every variant, the techniques
that paid off, and the ones you tried that didn't.
```

---

## 3. Change the string escape from `>` to `/` (DONE; kept for the record)

```
Read README.md and testing/README.md in this folder. Spec change from Robb:
inside strings, the escape character becomes '/' instead of '>'. The rules
are otherwise unchanged:
- '/' plus a character from 40h-7Fh clears that character's bit 6, so /M is
  CR, /J is LF and /[ is ESC
- '/' before a character from 20h-3Fh gives that character, so /" is a
  quote and // is a slash
- skips step over '/' and the character after it
- '>' becomes an ordinary character inside strings; outside them it is
  still the compare

1. Interpreters: in each of z80/, 8080/, 6502/ and 6809/, change the escape
   test in the string skip and in '$' (print) from '>' to '/', and update
   the comments. It should be a few bytes' change per CPU; confirm that the
   sizes don't move.
2. testing/ref.py: make the same change, so expected outputs follow the
   new rule.
3. Convert every B8Script program the tests use (testing/tests.py and
   testing/games/*.B8S) with a small script that walks strings the way the
   skip does. Inside strings only:
   - >X becomes /X
   - >> becomes >
   - every literal '/' becomes //
   Strings that are used as code (Tiny BASIC's statement handlers) follow
   the same rule, but their '/' is division and is only seen by the skip,
   so it must not be doubled unless it comes right before a closing quote.
   Report every string you had to treat as code. This one breaks if it is
   missed: HANGMAN.B8S prints its gallows arm with "/"$, which must become
   "//"$.
4. Rebuild and run every CPU's full suite, Tiny BASIC included. All
   variants must pass.

Report: the size per variant before and after, and the list of program
strings you changed by hand.
```
