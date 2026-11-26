# Testing the interpreters

Everything here runs from this folder.

## Setup

- `npm install -g asm80@1.11.14`. Or set `ASM80=/path/to/asm80.js`. Version 0.9.x does not work: it assembles the inside of a false `IF`.
- `pip install z80 py65 MC6809`. The `z80` package includes an 8080 machine.
- For the Windows builds: NASM 2.16 (`apt-get install nasm`) and `pip install unicorn`.

## Build and test

```
./build.sh Z80   ../z80/b8s-z80.asm   out/z80       # the four base variants (b8s-z80-base-...)
VARIANTS=$'0 0 1\n0 1 1\n1 0 1\n1 1 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80   # and the four base editor builds
SPEED=0 ./build.sh Z80 ../z80/b8s-z80.asm out/z80 # the same four small (b8s-z80-small-...), and
SPEED=0 VARIANTS=$'0 0 1\n0 1 1\n1 0 1\n1 1 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80   # the small editor ones
SPEED=2 ./build.sh Z80 ../z80/b8s-z80.asm out/z80 # the four fast builds (b8s-z80-fast-...; no editor)
SPEED=0 ./build.sh I8080 ../8080/b8s-8080.asm out/8080   # SPEED=0 and SPEED=2 go with every CPU's build.sh line below
python3 run_z80.py z80 out/z80                     # PASS/FAIL per variant
ANSI=1 VARIANTS=$'0 0\n0 1\n0 0 1\n0 1 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80a   # the generic ones with ANSI = 1
python3 run_z80.py z80 out/z80a                    # (do the same for each CPU)
./build.sh I8080 ../8080/b8s-8080.asm out/8080
python3 run_8080.py out/8080
VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502.asm out/6502
VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502-zp.asm out/6502
python3 run_6502.py out/6502                       # --nogames skips Tiny BASIC
VARIANTS=$'0 0\n0 1' ./build.sh M6809 ../6809/b8s-6809.asm out/6809
python3 run_6809.py out/6809                       # -nogames skips Tiny BASIC

./build_win32.sh                                   # the twelve Windows .EXE files (NASM), then chkpe.py
python3 run_win32.py out/win32                     # --nogames skips Tiny BASIC

python3 chktab.py out/z80/*.lst out/8080/*.lst     # layout rules (see ../README.md)
python3 chktab09.py out/6809/*.lst
python3 chktab6502.py out/6502/*.lst
python3 chkbr6502.py out/6502/*.lst                # asm80 misses some bad 6502 branches
python3 gamecheck.py out                           # every game on every build, briefly
python3 test_games.py                              # scripted games played to an end on ref.py
python3 test_chess.py                              # the chess engine: perft and searches, on ref.py
python3 test_programs.py out                       # SIEVE, PI, MANDEL and MON on ref.py and every build
python3 test_web.py                                # the web player's interpreter against ref.py
node test_page.js                                  # the web player's page, in Chromium
python3 b8strip.py ../../games/NAME.TXT ../../games/NAME.B8S    # after editing a game's commented version
python3 sizes.py out/z80                           # bytes per variant
python3 mkrel.py                                   # copy out/ to the .bin, .COM and .lst files
```

- A variant line for `build.sh` is `CPM CHECKED`, then `EDITOR` for the Z80. `SPEED=0`, `1` (the default) or `2` picks the tier: small, base or fast. A build is named after its source, plus the tier, plus `-gen` or `-cpm` (with the editor: `-ed` or `-cpm-ed`), plus `-chk` if checked: `b8s-z80-base-cpm-chk`.
- `ANSI=1 ./build.sh ...` builds with `ANSI = 1` (the console escapes send ANSI sequences); the default is `ANSI = 0`, where they call the machine's routines. The CP/M builds send ANSI either way. Build the generic variants both ways, into two folders, and test both: in an `ANSI = 0` build the harness traps the four routines (`CONCLS`, `CONEOL`, `CONCUR`, `CONAT`) and records the ANSI bytes each stands for, so the output compares with `ref.py`'s just the same.
- `run_z80.py` tests the editor builds by typing at them (`test_editor.py`, which can also be run by itself: `python3 test_editor.py out/z80`).
- Run the layout and branch checks after every change. They catch mistakes the assembler lets through and the tests may not reach.
- Each CPU's full run takes a few minutes at most.

## The files

| File | What it does |
|---|---|
| `ref.py` | Reference interpreter written from the spec. It produces the expected output for every test. With `checked=True` it is a checked build: it stops on every error in the spec's table and prints the report |
| `tests.py` | The suite: `SUITE` (program, input), `MC` (machine-code tests per CPU), `LOOSE` (unchecked builds only), `CHK` (checked builds only), `ERRS` (checked-build errors: the whole output is compared with `ref.py`'s, or with a pattern for the stack overruns) |
| `run_tests.py` | `check()` runs one build against everything, including Tiny BASIC and the break-key tests (`break_tests()`, for unchecked and checked builds alike) |
| `harness_z80.py` | Z80/8080 emulator wrapper. In generic builds it traps KEY/CONOUT/EXIT; in CP/M builds it emulates BDOS 6, 15, 16, 19 to 22 and 26 (any other call stops the run), with a small disk of files (the program is the file PROG.B8S). Its editor modes type the input a chunk at a time |
| `harness_6502.py`, `harness_6809.py` | The same wrapper for py65 and MC6809 |
| `run_z80.py`, `run_8080.py`, `run_6502.py`, `run_6809.py` | Run every build in a folder through `check()`. `run_6502.py` holds the two 6502 machine-code tests, one per interpreter |
| `test_editor.py` | Types sessions at the Z80 editor builds, each step when the editor is waiting for it, and compares the output byte for byte with a model of the editor (which follows the source key for key, and uses `ref.py` for whatever a line runs). Generic builds get paste and print sessions, CP/M builds file ones (the disk is compared too), checked builds error ones; a few sessions with keys pressed while a program is busy are compared with patterns |
| `build_win32.sh` | Builds the twelve Windows programs, four in each tier (`B8S.EXE`, `B8SU.EXE`, `B8SE.EXE`, `B8SUE.EXE`, and the same with S or F after `B8S`), into `out/win32` (each with a listing and a map file of its symbols), then runs `chkpe.py` |
| `harness_win32.py` | Runs a Windows .EXE in the Unicorn emulator: maps the file as Windows would, models the `kernel32` calls it makes, gives it a command line, a console (or redirected input) and a few files. Same interface as the others |
| `run_win32.py` | Runs every Windows build through `check()`, the editor builds through `test_editor.py`, and all of them through a few Windows-only tests |
| `chkpe.py` | Checks a Windows .EXE's header against the rules: alignments, sizes, the section, the entry point, the import table |
| `gamecheck.py` | Runs every full-size game in `games/`, and every program in `programs/` but MON, both `.B8S` and `.TXT` (IDOL's `.TXT` is documentation only, so it is left out), on every build for a short while and compares the output with `ref.py` |
| `test_web.py` | Runs the suite, Tiny BASIC, the programs and the scripted games on the web player's interpreter (`../../web/b8s.js`) under Node, through `web_run.js`, and checks every run against `ref.py`, byte for byte. It also checks that `../../web/b8script.html` is up to date |
| `test_page.js` | Drives the web player in Chromium (Playwright), as a computer and as phones: the screen, typing, a phone's keyboard, the pad, `n?`'s clock, the break key and checked reports. `node test_page.js DIR` also saves screenshots in DIR |
| `test_programs.py` | Checks SIEVE, PI, MANDEL and MON on `ref.py` against models written in Python (PI's digits are themselves checked against Machin's formula), then, given `out`, runs each on every build and compares the output with `ref.py`'s. MON's R runs one return instruction of the build's CPU |
| `test_games.py` | Types a fixed key sequence at a game on a checked `ref.py` and checks for the messages it should reach: a win, a loss or another known message. It runs both versions, which must print the same, and checks that every `.B8S` in `games/` and `programs/` holds the code of its `.TXT`. `test_games.py NAME` runs one game's tests |
| `test_chess.py` | Checks the engine of `games/CHESS.TXT` on a checked `ref.py`: perft (the count of the move tree) of five standard positions to depth 2 or 3, against the known counts with promotion to a queen only, then mates in one and two, free and guarded pieces, stalemate and mate. The perft word lives in a comment in `CHESS.TXT`, so this adds it to `CHESS.B8S` cut before its main program |
| `chktab.py`, `chktab09.py`, `chktab6502.py` | Check the dispatch-table layout rules on Z80/8080, 6809 and zero-page 6502 listings |
| `chkbr6502.py` | Checks every 6502 branch against its target |
| `test_tweets.py` | Plays the tiny games in `games/tweet140/` and `games/tweet280/` the same way, and checks each against its folder's limit: 140 or 280 characters (see `docs/tweets.md`). `test_tweets.py NAME` runs one game's tests; `--all` adds the slow check that Tic-tac-toe never loses |
| `../../games/` | The games, at the root of the repository (its README says how to play each one). The programs are each in two files: `NAME.TXT`, with comments that explain how it works, and `NAME.B8S`, the same code stripped of comments and white space. `games/tweet140/` and `games/tweet280/` hold the tiny games, which are already stripped and have no `.TXT` |
| `../../programs/` | Programs that aren't games, in the same two files: Tiny BASIC (`TINYBAS.B8S` is part of the suite), MON, SIEVE, PI and MANDEL |
| `b8strip.py` | Strips a program of comments and white space (but keeps a comment that starts with `!`), keeping a space only where B8Script needs one (`b8strip.py ../../games/NAME.TXT ../../games/NAME.B8S` after editing a game). `--same A B` checks that two files hold the same code |
| `mkrel.py` | Copies the builds in `out/` to the `.bin`, `.COM`, `.EXE` and `.lst` files in each CPU's `small/`, `base/` and `fast/` folders, under the names `../README.md` gives (`B8S.COM`, `b8s-z80-base-rom-0000.bin` and so on) |
| `patchinfo.py` | Where n?'s timing count sits in each CP/M .COM, to patch it for a machine whose BDOS is faster or slower (see `../TIMING.B8S`) |
| `cpmsim.py` | Runs the CP/M builds under real CP/M 2.2 (Digital Research's BDOS and CCP) in z80pack's `cpmsim`: `cpmsim.py suite out B8S B8SU` runs the suite's programs and compares each output with `ref.py`'s; `cpmsim.py type out STEP...` types at CP/M, for the editors. `-8` runs on an 8080 instead of the Z80 (which traps undocumented opcodes). Needs z80pack (set `Z80PACK`) and cpmtools; see its header. Not part of the usual run: it takes about ten minutes a build |

Notes on the harnesses:
- **Keys are typed as a person types them:** a key from the input is given only when the program is waiting for one, which the harness takes to be two looks at the keyboard close together (`GAP`: clock ticks on the Z80 and 8080, instructions on the others). Every build looks at the keyboard now and then for the break key, and holds only the newest key it finds, so a queue of keys handed over at every look would mostly be lost.
- Keys that must arrive while a program is busy are given with `timed`, a list of (n, keys): they are pressed, at once, when n characters have been printed. The break-key tests use it.
- Each harness counts its looks at the keyboard (`looks`); the break-key tests check that a busy loop asks only once in 256 times.
- A runner is `runner(program, input, timed=None)`, returns (output, how it ended), and keeps its harness in `runner.last`. The runners hand `check()` the build's own addresses (`plat`), so `ref.py` can reproduce a checked build's report exactly.
- A run that only polls for a key, with no input left, is stopped as "waiting for input". Tiny BASIC's test ends that way, which is why the suites are quick.
- The MC6809 emulator's SEX instruction is wrong (it never sets A to FFh). `harness_6809.py` replaces it.
- KEY is modelled as the contract says: A = the key or 0, with the zero flag to match.

A harness finds `PROG`, `KEY`, `CONOUT`, `EXIT` and (6502, 6809) `START` in the assembler listing (`.lst`), so a source must keep those symbol names. The runners also read `LET`, `LINEBUF` and `HEAPLIM`, and the editor tests `LEAVE`.
