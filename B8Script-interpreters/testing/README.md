# Testing the interpreters

Everything here runs from this folder.

## Setup

- `npm install -g asm80@1.11.14`. Or set `ASM80=/path/to/asm80.js`. Version 0.9.x does not work: it assembles the inside of a false `IF`.
- `pip install z80 py65 MC6809`. The `z80` package includes an 8080 machine.

## Build and test

```
./build.sh Z80   ../z80/b8s-z80.asm   out/z80       # all four variants
VARIANTS='0 0 1' ./build.sh Z80 ../z80/b8s-z80.asm out/z80   # and the editor build
python3 run_z80.py z80 out/z80                     # PASS/FAIL per variant
./build.sh I8080 ../8080/b8s-8080.asm out/8080
python3 run_8080.py out/8080
VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502.asm out/6502
VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502-zp.asm out/6502
python3 run_6502.py out/6502                       # --nogames skips Tiny BASIC
VARIANTS=$'0 0\n0 1' ./build.sh M6809 ../6809/b8s-6809.asm out/6809
python3 run_6809.py out/6809                       # -nogames skips Tiny BASIC

python3 chktab.py out/z80/*.lst out/8080/*.lst     # layout rules (see the main README)
python3 chktab09.py out/6809/*.lst
python3 chktab6502.py out/6502/*.lst
python3 chkbr6502.py out/6502/*.lst                # asm80 misses some bad 6502 branches
python3 gamecheck.py out                           # every game on every build, briefly
python3 sizes.py out/z80                           # bytes per variant
python3 mkrel.py                                   # copy out/ to the .bin, .COM and .lst files
```

- A variant line for `build.sh` is `CPM CHECKED`, then `EDITOR` for the Z80. A build is named after its source, plus `-gen`, `-cpm` or `-ed`, plus `-chk` if checked.
- `run_z80.py` tests the editor build by typing at it (`test_editor.py`, which can also be run by itself).
- Run the layout and branch checks after every change. They catch mistakes the assembler lets through and the tests may not reach.
- Each CPU's full run takes a few minutes at most.

## The files

| File | What it does |
|---|---|
| `ref.py` | Reference interpreter written from the spec. It produces the expected output for every test |
| `tests.py` | The suite: `SUITE` (program, input), `MC` (machine-code tests per CPU), `LOOSE` (unchecked builds only), `ERRS` (checked-build errors: letter and offset) |
| `run_tests.py` | `check()` runs one build against everything, including Tiny BASIC and the Ctrl-C test |
| `harness_z80.py` | Z80/8080 emulator wrapper. In generic builds it traps KEY/CONOUT/EXIT; in CP/M builds it emulates BDOS 6, 10, 15, 20 and 26 and loads the program as a file |
| `harness_6502.py`, `harness_6809.py` | The same wrapper for py65 and MC6809 |
| `run_z80.py`, `run_8080.py`, `run_6502.py`, `run_6809.py` | Run every build in a folder through `check()`. `run_6502.py` holds the two 6502 machine-code tests, one per interpreter |
| `test_editor.py` | Types sessions at the Z80 editor build, each line when the editor is waiting for it, and compares the output with a model of the editor (which uses `ref.py` for whatever a line runs) |
| `gamecheck.py` | Runs every game on every build for a short while and compares the output with `ref.py` |
| `chktab.py`, `chktab09.py`, `chktab6502.py` | Check the dispatch-table layout rules on Z80/8080, 6809 and zero-page 6502 listings |
| `chkbr6502.py` | Checks every 6502 branch against its target |
| `games/` | Your programs. `TINYBAS.B8S` is part of the suite |
| `esc2slash.py` | Converts older programs to the `/` escape |
| `mkrel.py` | Copies the builds in `out/` to the `.bin`, `.COM` and `.lst` files next to each source |

Notes on the harnesses:
- A run that only polls for a key, with no input left, is stopped as "waiting for input". Tiny BASIC's test ends that way, which is why the suites are quick.
- The MC6809 emulator's SEX instruction is wrong (it never sets A to FFh). `harness_6809.py` replaces it.
- KEY is modelled as the contract says: A = the key or 0, with the zero flag to match.

A harness finds `PROG`, `KEY`, `CONOUT`, `EXIT` and (6502, 6809) `START` in the assembler listing (`.lst`), so a source must keep those symbol names.
