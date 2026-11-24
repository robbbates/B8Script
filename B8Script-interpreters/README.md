# B8Script interpreters: Z80, 8080, 6502, 6809 and Windows

Generic interpreters for minimal homebrew machines (serial console only), CP/M 2.2 versions for the Z80 and 8080, and a 32-bit x86 one for the Windows command shell. Each source has switches at the top:

```
CPM     EQU     0               ; 1 = CP/M .COM build        (Z80, 8080)
CHECKED EQU     0               ; 1 = checked build          (all)
EDITOR  EQU     0               ; 1 = with the line editor   (Z80, Windows)
ANSI    EQU     0               ; 1 = the console escapes send ANSI sequences (Z80, 8080, 6502, 6809)
```

`ANSI` decides what the console escapes of `$` (`/{` `/}` `/|` `` /` `` `/~`) do. With `ANSI = 1` they send ANSI (VT100) sequences through `CONOUT`. With `ANSI = 0` they call four routines of the machine's own (see the machine interface below). The generic builds default to `ANSI = 0`; the CP/M builds always send ANSI, whatever the switch says; the Windows builds always send ANSI, in the console mode they set.

The 6502 has two sources: `b8s-6502.asm` keeps the data stack in pages 2 and 3, and `b8s-6502-zp.asm` is a smaller interpreter that keeps it in zero page.

## Sizes (bytes, measured)

**Generic ROM images.** `ANSI = 0` is the default (the console escapes call the machine's routines); `ANSI = 1` sends ANSI sequences. "Before" is the last build without the escapes (commit `9c7f40c`).

| CPU | Before | `ANSI = 0` | `ANSI = 1` | Checked, before | Checked, `ANSI = 0` | Checked, `ANSI = 1` |
|---|---|---|---|---|---|---|
| Z80 | 765 | 827 | 876 | 1,163 | 1,230 | 1,279 |
| Z80 with the line editor | 1,488 | 1,358 | 1,407 | 1,796 | 1,765 | 1,814 |
| 8080 | 854 | 925 | 980 | 1,299 | 1,377 | 1,432 |
| 6502, stack in pages 2-3 | 1,175 | 1,208 | 1,265 | 1,706 | 1,748 | 1,791 |
| 6502, stack in zero page | 1,095 | 1,155 | 1,219 | 1,628 | 1,698 | 1,748 |
| 6809 | 825 | 873 | 934 | 1,220 | 1,284 | 1,333 |

**CP/M .COM files** (always ANSI):

| CPU | Before | Now | Checked, before | Checked, now |
|---|---|---|---|---|
| Z80 | 831 | 957 | 1,243 | 1,374 |
| Z80 with the line editor | 1,663 | 1,593 | 1,987 | 2,012 |
| 8080 | 904 | 1,049 | 1,364 | 1,516 |

**Windows .EXE files** (always ANSI):

| | Unchecked | Checked | With the editor | Editor, checked |
|---|---|---|---|---|
| The file, before | 2,560 | 3,072 | 3,584 | 4,096 |
| The file, now | 2,560 | 3,072 | 3,072 | 3,584 |
| Code and table, before | 1,286 | 1,816 | 2,298 | 2,728 |
| Code and table, now | 1,319 | 1,845 | 2,009 | 2,539 |

- A generic size is the whole ROM image: the code plus the punctuation table.
- A Windows file is a 512-byte header and then the code, the table and about 375 to 400 bytes of import data, rounded up to the next 512 bytes: so a file shrinks only in steps of 512. The four have 357, 343, 155 and 137 bytes to spare before their next step up.
- The letter cells, stacks and line buffer are all in RAM, so they aren't counted.
- The CP/M size is the .COM file, which includes the program loader.
- Where the bytes went with the escapes: on the Z80 the escapes cost an unchecked generic build 62 bytes with `ANSI = 0` and 111 with `ANSI = 1`, and the checked one 67 and 116. The CP/M builds also read `-n?` themselves now (15 bytes on the Z80, 19 on the 8080; see The language). The editor builds lost ^V, which saved about 170 bytes in the unchecked ones (the stack listing was there only for it) and 100 in the checked ones.
- Where the bytes went since the builds of the 2026-10-09 spec: the break key in every build costs an unchecked build 60 to 80 bytes (about 30 of them are the break-off cell and its wait for a second Ctrl-C); the checked builds grew by 280 to 470 bytes in all, most of it the report with its line, column, text and both stacks (about 200 bytes on the Z80, 300 on the 6502).

## Files

| File | What it is |
|---|---|
| `*/b8s-*.asm` | The source, with comments |
| `*-rom-XXXX.bin` | Generic ROM image, to load at XXXXh (`-zp-` = the zero-page 6502 interpreter, `-editor-` = Z80 with the line editor) |
| `B8SZ80.COM`, `B8SZ80C.COM`, `B8S8080.COM`, `B8S8080C.COM` | CP/M builds; the C means checked. Run as `B8SZ80 PROG.B8S` |
| `B8SZ80E.COM`, `B8SZ80EC.COM` | CP/M builds with the line editor; the C means checked. Run as `B8SZ80E PROG.B8S`, or with no file |
| `win32/B8SWIN.EXE`, `B8SWINC.EXE`, `B8SWINE.EXE`, `B8SWINEC.EXE` | Windows command-shell builds: C means checked, E with the line editor. Run as `B8SWIN PROG.B8S` |
| `*.lst` | The assembler's listings |

## The language

The builds follow [`docs/b8script.md`](../docs/b8script.md) (2026-11-24). What the spec leaves to the implementation:

- `-n?`: Backspace takes a character back and is echoed as it is; every other key but CR is stored and echoed, control keys and DEL included; CR ends the line and is not echoed. A count above 127 is taken as 127. The CP/M builds read the line the same way, with BDOS 6 a key at a time, not with BDOS 10: so a key held by the break check is the line's first, and the editing keys are the same on every build.
- Dividing by zero in an unchecked build returns two cells of no meaning (different on each CPU), and the stack stays balanced.
- `[` followed by anything but a letter is taken as `[ ` in an unchecked build.
- The CP/M builds print through BDOS 6, which can't print the byte FFh (it means "read a key" there).
- The memory maps, stack sizes, heap limits and system addresses are in the spec's appendices.

## Building

The sources use asm80 1.11.14, from npm (`npm install -g asm80@1.11.14`):

```
node asm80.js -m Z80 -t hex -o b8s-z80.hex b8s-z80.asm
```

The machine name is `Z80`, `I8080`, `C6502` or `M6809`. To build a variant, edit the EQU lines first, or use `testing/build.sh`, which builds every variant.

The Windows source is for NASM (2.16), which writes the .EXE directly, with no linker: the source lays the file's header out itself.

```
nasm -f bin -DCHECKED=1 -DEDITOR=1 -o B8SWINEC.EXE b8s-win32.asm
```

`testing/build_win32.sh` builds all four.

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

To save the 32 bytes of a full address table, the Z80, the 8080, the unchecked 6809 and the zero-page 6502 keep one byte per punctuation character and work the rest of the handler's address out from the character's place in the table. That puts rules on where handlers sit:

- **Z80, 8080:** the handlers of the first `NPG1` characters (in code order) start in the image's second 256 bytes, the rest in its first. `NPG1` is worked out by the assembler from where `] \ [ @` landed, so the split moves by itself when code grows or shrinks.
- **6809, unchecked:** the same idea with two 256-byte ranges after the table. The checked 6809 build is too big for that and keeps a table of whole addresses.
- **6502, zero page:** three pages. The handlers of `! " # $ % & ' (` start in the image's first 256 bytes, those of `) * + , - . / : ; < = > ?` in its second, and the rest in its third. The split is fixed (`N1`, `N2`), so code that grows may have to move; the source marks the stretches where no handler starts, which are the places to move it to. The image must be assembled at a multiple of 512.
- **Z80, 8080:** the RST routines must sit at their vectors.

`testing/chktab.py` (Z80, 8080), `testing/chktab09.py` (6809) and `testing/chktab6502.py` check all of this on the listings. Run them after any change; each says how many bytes are to spare. `b8s-6502.asm` has a table of whole addresses and no such rules.

## Generic machine interface (edit the equates)

| | Z80 / 8080 | 6502 | 6809 |
|---|---|---|---|
| KEY | return a waiting key in A, or A = 0 if none is waiting; the zero flag must match A | same | same |
| CONOUT | print A | same | same |
| EXIT | jumped to when the program ends | same | same |
| KEY and CONOUT must keep | BC, DE, HL (and HL' on the Z80) | X, Y | B, X, Y, U, DP |
| Where to start | reset at 0000h | label `start`, E000h (point the reset vector at it) | label `start`, F000h (point the reset vector at it) |
| RAM | RS 8000h, DS 8100h, letters 8200h, PROG 8300h | RS = page 1, DS 0200h/0300h (or zero page 10h-EFh), letters 0400h, PROG 0500h | RS 8000h (S), DS 8100h (U), letters 8200h (DP), PROG 8300h |
| Heap limit | `HEAPLIM` (page), default F0h | default E0h | default F0h |
| Timing | `MSLOOP` = loop passes per millisecond for `n?` (1-255); tune it to your clock and KEY | same | same |
| With `ANSI = 0`: CONCLS (FF0Ch), CONEOL (FF0Fh) | clear the screen and home the cursor; clear to the end of the line | same | same |
| CONCUR (FF12h) | show the cursor if A is not 0, hide it if A = 0 | show if the carry is set, hide if clear | as the Z80 |
| CONAT (FF15h) | cursor to row HL, column DE, both from 0 | row A, column Y | row X, column D |
| The four must keep | BC and HL'; and DE and HL, all but CONAT | X | Y, U, DP |

- There is one input routine, KEY. It replaces the earlier CONST and CONIN: `0?` waits by calling KEY until a key comes.
- KEY is also called while a program runs, for the break key: once in every 256 word calls and loop-backs. A key it returns then is taken, so KEY must not wait, and should be quick.
- The Z80 builds with the editor have one more address, `LEAVE`: where ^X goes. A program that ends goes back to the editor.
- Your loader puts the program text, ending in a NUL, at `PROG`. The heap starts after the NUL.
- The generic Z80 and 8080 images start at 0000h and use RST 08h, 18h, 20h, 28h and 30h as one-byte calls.
- The CP/M builds copy those routines to 0008h-0033h when they start (they used 0008h-0014h before). A system whose interrupts use RST 1 to RST 6 can't run them.

## The break key

Every build stops a running program on Ctrl-C. An unchecked build prints nothing and goes to EXIT (or back to the editor); a checked build reports `B`.

- **Where it is looked for.** At every word call and every true `)` loop-back (on the Z80 and 8080 also at block entry and `{`), but KEY is only called one time in 256: a counter gates it. A program stuck in `?` is stopped too, since `?` treats Ctrl-C the same way.
- **Other keys.** A key the check reads is held for the next `?`. A newer key replaces it, and `?` takes the held key before it looks at KEY. So one key typed ahead is kept, not more.
- **The break-off cell** is the byte at offset 7Bh of the letter page: 827Bh on the generic Z80, 8080 and 6809, $047B on the 6502. A program that stores a non-zero byte there gets Ctrl-C as key 03h. When it does, the interpreter waits about 250 ms (250 x `MSLOOP` calls of KEY) for one more key: a second Ctrl-C stops the program all the same, and any other key becomes the held key. Each build clears the cell when it starts; the editor clears it before every line.
- **The held key** is a cell of the interpreter's own. Most builds keep it in the byte below the break-off cell; the appendices say where.

## The Z80 line editor (EDITOR = 1)

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
| ^N ^N | New: no program (the key twice in a row; any other second key calls it off) |
| ^X | Leaves: to `LEAVE` (generic) or to CP/M |
| ^B ^F, or the left and right arrow keys | Move the cursor in the line. Text goes in at the cursor |
| Backspace, DEL | Take out the character before the cursor |
| Esc | Drops the line |

- Lines are counted, not numbered: the text holds no line numbers, and the list shows each line's place. There can be 65,535 lines.
- A typed line holds 125 characters, the line number included. The one character after the line number separates it from the text and is not stored, whatever it is: `3 5#` stores `5#`, and so does `3x5#`. Type a space there.
- The editor sends only printing characters, CR, LF and Backspace, so it works on any terminal. A character put in or taken out in the middle of the line prints the rest of the line again.
- After Esc the editor waits about 5 ms for another key. If `[` follows, it reads on to the letter that ends the sequence and acts on C (right) and D (left); it ignores the rest. A lone Esc drops the line.
- Tab is text. Other control keys do nothing.
- **What lasts from line to line:** the program, the words, the variables and the data stack. The return stack starts empty for every line. After an error or a break both stacks are empty. A word's address points into the program text, so run the program again after editing it.
- A line run at once sits in the line buffer, which `-n?` also reads into. The stored program never returns to the line, so it can use `-n?` freely; a typed line that calls `-n?` itself and carries on afterwards runs what was typed.
- `-n?` in a program is the plain line read of the other builds, not the editor's.
- Nothing is printed between a program's output and what you type next.
- Reset empties the program (generic builds).

**Reading and writing, generic builds:**
- ^R stores each CR as CR LF. A LF straight after a line end is dropped; a LF anywhere else ends a line too. So text with CR LF, CR or LF line ends all comes in right, but empty lines can be lost. A last line with no line end is given one.
- ^R ends at ^Z only. The spec also names ^@, but KEY returns 0 for "no key", so a NUL can't be seen.
- Nothing checks that the text fits in memory.

**With CP/M** (`B8SZ80E`, `B8SZ80EC`):
- The file named on the command line is the program to start with, and the name that ^R and ^W use until another is typed. With no file, or no such file, there is no program.
- A name is up to 8 characters, a dot and up to 3 more, on the current drive. It is put in capitals.
- The text ends at the file's first ^Z, and a last line with no CR LF is given one. ^W pads the last record with ^Z.
- ^W deletes the old file first. It does not notice a full disk or directory: the file is then short, or missing.
- The editor reads its keys with BDOS 6, so BDOS 10's editing keys don't apply to it, and Ctrl-C at the editor does nothing: ^X leaves.

**Checked** (`-editor-checked-`, `B8SZ80EC`):
- A program that is stopped, by an error or by Ctrl-C, prints its report and comes back to the editor, with both stacks empty.
- A line typed at the editor is line 0 in the report; the column is the place in the line.

The editor adds 531 bytes to the unchecked generic build and 636 to the CP/M one (535 and 638 to the checked ones). It has no ^V (view): taking it out saved about 170 bytes in an unchecked build, which needed the stack listing only for it, and kept the CP/M checked editor inside 2,048 bytes. The first editor, which brought the whole image to 768 bytes with the leaner language of that day, is commit `4fbf418`; the one before this rewrite (183 bytes, no cursor, no files) is commit `ddc1a4c`.

## The Windows builds (`win32/`)

Four programs for the Windows command shell, in 32-bit x86 assembly: `B8SWIN.EXE`, `B8SWINC.EXE` (checked), `B8SWINE.EXE` (with the line editor) and `B8SWINEC.EXE` (editor, checked). A 32-bit program runs on every Windows, the 64-bit and ARM ones included.

```
B8SWIN PROG.B8S
B8SWIN PROG.B8S > out.txt
B8SWINE PROG.B8S
```

- **They have not been run on Windows yet.** They are tested in an emulator, with the Windows calls they make modelled by hand, and their headers are checked against the documented rules (see How they were tested). Wine would not start in the container they were written in. The first run on a real machine is still to do.
- **The machine is the spec's:** 64 KB of memory, 16-bit cells and addresses. The memory map is in the spec's Appendix G. The language, the break key, the checked builds' errors and report, and the editor are the Z80's, key for key.
- **The file.** A runner loads the file named on the command line, runs it and exits. With no file, or one that can't be opened, it exits without a word. An editor build starts with that file as its program, or empty. A file can hold up to 64,765 bytes.
- **Output** goes to standard output, so it can be redirected. A checked build's report goes to standard error.
- **Keys** are read from the console raw: no echo, and Ctrl-C arrives as a key, so the interpreter's own break rules apply. The console's mode is put back on every way out. The left and right arrow keys work in the editor (they are turned into ^B and ^F). The Delete key does nothing; Backspace deletes.
- **Input that is not the console** (a pipe or a file) is read a byte at a time, and only by `?`, `-n?` and the editor: the break check does not read it, so Ctrl-C can't break in, and `n?` waits for a byte however small n is. At the end of the input the program exits.
- **Time.** A plain timed wait on Windows ends only on the system's tick, every 15.6 ms, so `1?` would take about 16 ms and a game timed by it would crawl. So `n?`, the break-off cell's 250 ms and the editor's Esc wait use a high-resolution waitable timer (Windows 10 1803 and later), set once for the whole wait: the wait ends on a key or when the timer is due, to about a millisecond. On older Windows the timer can't be made, and the waits are plain ones, to the tick. The builds import `CreateWaitableTimerExW`, so they start on Windows Vista and later.
- **The editor's files.** A name typed before ^R or ^W is a Windows path, as typed, and stays the name until another is typed. Nothing is said if a file can't be read or written: a read then gives no program.
- **The header** is laid out by hand in the source, by the documented rules and nothing clever: one section, 512-byte file alignment, imports from `kernel32.dll` only (`GetStdHandle`, `GetConsoleMode`, `SetConsoleMode`, `GetCommandLineA`, `CreateFileA`, `ReadFile`, `WriteFile`, `WaitForMultipleObjects`, `CreateWaitableTimerExW`, `SetWaitableTimer`, `ReadConsoleInputA`, `ExitProcess`, and `CloseHandle` in the editor builds). `testing/chkpe.py` checks every file.
- **Dispatch.** One byte per punctuation character, as on the Z80, but with a single range: every handler starts within 255 bytes of one address, and the assembler stops if one doesn't.

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
/ "no"$
Stk 6: 1 2 3 4 5 0
Rtn 0
```

- It starts and ends with CR LF. Then the build goes to EXIT, or back to the editor.
- **The place** is the character that failed. For `U` it is the call, for `N` the `(` or `[` where the skip started, for `Q` the opening quote or the `$`, and for `W` the character after the `[`. Lines and columns count from 1; text below the program (a line read by `-n?` and then run, or a line typed at the editor) is line 0.
- **The text line** stops at CR, LF or NUL, and in the CP/M builds at ^Z too.
- **The stack lines** show the stacks as they were before the failing character ran: `7 0/` shows `Stk 2: 7 0`. More than 8 cells are shown as ` ...` and the top 8. Values are signed, as `#` prints them. There are three exceptions:
  - A stack overrun (`S` `s` `R` `r`) is found after the character has run, once per character. After `s` the data stack counts as empty, after `r` the return stack. The place can be one character late, and after `r` it is wherever the bad return went.
  - `N`, and `Q` for an unclosed string, show the stack after the opener took its flag or pushed its address.
  - `B` shows whatever is there when the key is noticed.
- **A string with no closing quote inside skipped text** is an `N` at the skip's opener (or the quiet end of the program, for `\`), not a `Q`: the skip ran into the end.
- **Store range.** "The program's space" runs from the letter page up to the heap limit, not just up to the heap top. Tiny BASIC keeps its program lines above the heap top without allocating them, so the stricter rule would stop it. On the Z80 and 8080 one test serves both bytes of a cell, so `.` can't store to the very last byte below the limit.
- **The hex loader and machine code are never checked.**
- **Stacks.** The stacks hold 127 data cells and 112 return entries (Z80/8080), 252 or 112 and about 110 (6502), or 126 and 112 (6809). A few spare bytes above each stack and a guard band below take what a character does before the check sees it, so an overrun can't reach the letter cells.
- **Undefined words.** The word cells start at 0000h. On the Z80 and 8080 the byte there is a reserved one, and the reserved-byte path sees that the text pointer is in page zero; the 6502 reads a NUL there (the text pointer's own low byte) and its end-of-text path sees that the pointer is in page zero; the 6809 tests the cell at the call.
- **Unchecked builds and `[`.** A letter defines; anything else is taken as the space.
- **Don't treat a checked run as proof.** What an unchecked build does with the same mistake is not defined. One example: an unclosed string in an unchecked build is skipped on through memory until some quote turns up.

## Machine-code contracts (the grave)

- **Z80 / 8080:** as in the spec. Entered by CALL, with the data cells above the return address. The code must keep BC. On return, the top cell becomes TOS. The loader appends C9h.
  - Generic builds also need page zero left intact.
  - The Z80 saves and restores HL' itself, so the code may use the alternate registers.
- **6502, both:** entered as a subroutine (`JMP (T0)`, with a return address on the stack), ending in RTS (60h, appended by the loader). The address has been dropped. The code must keep the IP at $00/$01 and leave the hardware stack balanced.
  - **`b8s-6502.asm`:** TOS is at $02/$03. X is the data-stack index; NOS is $0200,X (low) and $0300,X (high). To push: DEX, store TOS there, then set TOS. To drop: load TOS from there, then INX. The code may change A, X (consistently), Y, $04-$06 and $08-$09; $0A-$0F is free for its own use.
  - **`b8s-6502-zp.asm`:** X is the data-stack pointer. TOS is at 0,X (low) and 1,X (high), NOS at 2,X and 3,X. To push: DEX, DEX, then store. To drop: INX, INX. The code may change A, Y and X (consistently); $02, $03, $07 and $0A-$0D are free for its own use.
- **6809:** entered by a jump, with the dispatcher's return address on S, so the code ends in RTS (39h, appended by the loader).
  - U points at the top data cell, which becomes TOS on return. Cells on the data stack are big-endian (6809 order); cells in memory stay little-endian, as the spec says.
  - The code may change A, B, X, CC and U (consistently). It must keep Y (the IP) and DP, and leave S balanced.

## The two 6502 interpreters

| | `b8s-6502.asm` | `b8s-6502-zp.asm` |
|---|---|---|
| Data stack | pages 2 and 3, 252 cells, low and high bytes in separate pages; TOS in zero page | zero page $10-$EF, 112 cells, each cell two bytes side by side |
| Zero page used | $00-$09 ($07 is the held key in the unchecked build, and with $06 the place of the character being run in the checked one) | $00, $01, $04-$06, $08, $09, and the stack ($0E-$0F are scratch when it is full). A checked build's report also uses $02, $03, $0A and $0B, after the program has stopped |
| Dispatch table | whole addresses (64 bytes) | one byte each (32 bytes), with the layout rules above |
| Size | 1,175 / 1,706 checked | 1,095 / 1,628 checked |

The zero-page one is smaller because a cell that holds an address is used as the pointer where it lies (`(0,X)`), a drop is two `INX`, and the 16-bit operators work a byte at a time through one short routine called twice. Machine code written for one needs changing for the other: see the contracts below.

## How they were tested

Every build runs, in an emulator, against a reference interpreter written from the spec (`testing/ref.py`):
- every example program in the spec;
- edge cases for `/`, compares, number wrap, string escapes, skips over strings, `\`, `[x`, `[ `, `{]` jumps, heap mark and release with a signed `_`, the hex loader, `0?`, `n?`, `-n?` with editing, and deep stacks;
- your Tiny BASIC, driven with a typed program (entering, LIST, RUN, GOSUB, FOR, expressions);
- a machine-code test per CPU (and per interpreter on the 6502);
- the break key, on unchecked and checked builds alike: Ctrl-C in a loop, in a chain of word calls and in `?`; the held key, the newest key winning, `?` taking the held key first; the break-off cell, with one Ctrl-C, two quick ones and two slow ones; and a count of how often KEY is called;
- for checked builds, every error in the table, several ways each, with the whole report compared byte for byte against the reference (run with that build's own addresses); the stack overruns are compared against patterns, since stack sizes differ.

The four editor builds are tested by typing at them (`testing/test_editor.py`), each step when the editor is waiting for it, against a model of the editor that follows the source key for key, echo included: entering, inserting, deleting, listing from any line, holding the list and ending it with Ctrl-C, running, 300 lines, full-length lines, the cursor keys and arrows, Esc, editing a line in place, new, view, the data stack lasting between lines, and programs that read lines and keys. The generic ones also paste a program in (with every kind of line end) and print it out; the CP/M ones read and write files on a small emulated disk; the checked ones also hit errors and Ctrl-C and carry on in the editor.

The Windows builds run in the Unicorn emulator (`testing/harness_win32.py`): the .EXE is mapped as Windows would map it, and the dozen `kernel32` calls it makes are modelled. They go through the same suite as the others, the break-key tests and the editor sessions included, plus a few tests of their own (the report on standard error, redirected input, the arrow keys, the command line). That tests the interpreter, and the header against the rules; it can't show that Windows itself accepts the file, or that the model of each call is right.

The other twenty games are also run on every build against the reference, for as far as a short run gets (`testing/gamecheck.py`). Each game is in two files, `NAME.TXT` with comments that explain it and `NAME.B8S` stripped from it (`testing/b8strip.py`), and both are run, and the reference plays scripted games of the newest twelve (Wumpus, Robots, 2048, Minesweeper, Breakout, Qubic, Klondike, Lights Out, Fifteen, Greed, Reversi and Battleship) to a win, a loss or a known message (`testing/test_games.py`). The test setup is in `testing/` (see its README).

## Converting older programs

- `testing/esc2slash.py FILE...` rewrites sources that still use `>` as the string escape. Printed strings (`"..."$`) get the full conversion, so they print what they did before. Comments (`"...";`) and data strings are only touched where the closing quote would move. It lists every data string that holds a `/` or `>`, so you can check those by hand.
- `-n` reports without changing anything.
