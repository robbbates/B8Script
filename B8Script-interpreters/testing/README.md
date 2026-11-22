# Testing the interpreters

Everything here runs from this folder.

## Setup

- `npm install -g asm80@1.11.14`. Or set `ASM80=/path/to/asm80.js`. Version 0.9.x does not work: it assembles the inside of a false `IF`.
- `pip install z80 py65 MC6809`. The `z80` package includes an 8080 machine.
- For the Windows builds: NASM 2.16 (`apt-get install nasm`) and `pip install unicorn`.

## Build and test

```
./build.sh Z80   ../z80/b8s-z80.asm   out/z80       # all four variants
VARIANTS=$'0 0 1\n0 1 1\n1 0 1\n1 1 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80   # and the four editor builds
python3 run_z80.py z80 out/z80                     # PASS/FAIL per variant
./build.sh I8080 ../8080/b8s-8080.asm out/8080
python3 run_8080.py out/8080
VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502.asm out/6502
VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502-zp.asm out/6502
python3 run_6502.py out/6502                       # --nogames skips Tiny BASIC
VARIANTS=$'0 0\n0 1' ./build.sh M6809 ../6809/b8s-6809.asm out/6809
python3 run_6809.py out/6809                       # -nogames skips Tiny BASIC

./build_win32.sh                                   # the four Windows .EXE files (NASM), then chkpe.py
python3 run_win32.py out/win32                     # --nogames skips Tiny BASIC

python3 chktab.py out/z80/*.lst out/8080/*.lst     # layout rules (see the main README)
python3 chktab09.py out/6809/*.lst
python3 chktab6502.py out/6502/*.lst
python3 chkbr6502.py out/6502/*.lst                # asm80 misses some bad 6502 branches
python3 gamecheck.py out                           # every game on every build, briefly
python3 sizes.py out/z80                           # bytes per variant
python3 mkrel.py                                   # copy out/ to the .bin, .COM and .lst files
```

- A variant line for `build.sh` is `CPM CHECKED`, then `EDITOR` for the Z80. A build is named after its source, plus `-gen` or `-cpm` (with the editor: `-ed` or `-cpm-ed`), plus `-chk` if checked.
- `run_z80.py` tests the editor builds by typing at them (`test_editor.py`, which can also be run by itself: `python3 test_editor.py out/z80`).
- Run the layout and branch checks after every change. They catch mistakes the assembler lets through and the tests may not reach.
- Each CPU's full run takes a few minutes at most.

## The files

| File | What it does |
|---|---|
| `ref.py` | Reference interpreter written from the spec. It produces the expected output for every test. With `checked=True` it is a checked build: it stops on every error in the spec's table and prints the report |
| `tests.py` | The suite: `SUITE` (program, input), `MC` (machine-code tests per CPU), `LOOSE` (unchecked builds only), `CHK` (checked builds only), `ERRS` (checked-build errors: the whole output is compared with `ref.py`'s, or with a pattern for the stack overruns) |
| `run_tests.py` | `check()` runs one build against everything, including Tiny BASIC and the break-key tests (`break_tests()`, for unchecked and checked builds alike) |
| `harness_z80.py` | Z80/8080 emulator wrapper. In generic builds it traps KEY/CONOUT/EXIT; in CP/M builds it emulates BDOS 6, 10, 15, 16, 19 to 22 and 26, with a small disk of files (the program is the file PROG.B8S). Its editor modes type the input a chunk at a time |
| `harness_6502.py`, `harness_6809.py` | The same wrapper for py65 and MC6809 |
| `run_z80.py`, `run_8080.py`, `run_6502.py`, `run_6809.py` | Run every build in a folder through `check()`. `run_6502.py` holds the two 6502 machine-code tests, one per interpreter |
| `test_editor.py` | Types sessions at the Z80 editor builds, each step when the editor is waiting for it, and compares the output byte for byte with a model of the editor (which follows the source key for key, and uses `ref.py` for whatever a line runs). Generic builds get paste and print sessions, CP/M builds file ones (the disk is compared too), checked builds error ones; a few sessions with keys pressed while a program is busy are compared with patterns |
| `build_win32.sh` | Builds the four Windows programs into `out/win32` (each with a listing and a map file of its symbols), then runs `chkpe.py` |
| `harness_win32.py` | Runs a Windows .EXE in the Unicorn emulator: maps the file as Windows would, models the `kernel32` calls it makes, gives it a command line, a console (or redirected input) and a few files. Same interface as the others |
| `run_win32.py` | Runs every Windows build through `check()`, the editor builds through `test_editor.py`, and all of them through a few Windows-only tests |
| `chkpe.py` | Checks a Windows .EXE's header against the rules: alignments, sizes, the section, the entry point, the import table |
| `gamecheck.py` | Runs every game on every build for a short while and compares the output with `ref.py` |
| `chktab.py`, `chktab09.py`, `chktab6502.py` | Check the dispatch-table layout rules on Z80/8080, 6809 and zero-page 6502 listings |
| `chkbr6502.py` | Checks every 6502 branch against its target |
| `games/` | Your programs. `TINYBAS.B8S` is part of the suite |
| `esc2slash.py` | Converts older programs to the `/` escape |
| `mkrel.py` | Copies the builds in `out/` to the `.bin`, `.COM`, `.EXE` and `.lst` files next to each source |

Notes on the harnesses:
- **Keys are typed as a person types them:** a key from the input is given only when the program is waiting for one, which the harness takes to be two looks at the keyboard close together (`GAP`: clock ticks on the Z80 and 8080, instructions on the others). Every build looks at the keyboard now and then for the break key, and holds only the newest key it finds, so a queue of keys handed over at every look would mostly be lost.
- Keys that must arrive while a program is busy are given with `timed`, a list of (n, keys): they are pressed, at once, when n characters have been printed. The break-key tests use it.
- Each harness counts its looks at the keyboard (`looks`); the break-key tests check that a busy loop asks only once in 256 times.
- A runner is `runner(program, input, timed=None)`, returns (output, how it ended), and keeps its harness in `runner.last`. The runners hand `check()` the build's own addresses (`plat`), so `ref.py` can reproduce a checked build's report exactly.
- A run that only polls for a key, with no input left, is stopped as "waiting for input". Tiny BASIC's test ends that way, which is why the suites are quick.
- The MC6809 emulator's SEX instruction is wrong (it never sets A to FFh). `harness_6809.py` replaces it.
- KEY is modelled as the contract says: A = the key or 0, with the zero flag to match.

A harness finds `PROG`, `KEY`, `CONOUT`, `EXIT` and (6502, 6809) `START` in the assembler listing (`.lst`), so a source must keep those symbol names. The runners also read `LET`, `LINEBUF` and `HEAPLIM`, and the editor tests `LEAVE`.
