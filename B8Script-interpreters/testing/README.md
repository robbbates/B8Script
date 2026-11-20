# Testing the interpreters

Everything here runs from this folder.

## Setup

- `npm install -g asm80@1.11.14`. Or set `ASM80=/path/to/asm80.js`. Version 0.9.x does not work: it assembles the inside of a false `IF`.
- `pip install z80 py65 MC6809`. The `z80` package includes an 8080 machine.

## Build and test

```
./build.sh Z80   ../z80/b8s-z80.asm   out/z80       # all four variants
python3 run_z80.py z80 out/z80                     # PASS/FAIL per variant
./build.sh I8080 ../8080/b8s-8080.asm out/8080
python3 run_8080.py out/8080
VARIANTS=$'0 0\n0 1' ./build.sh C6502 ../6502/b8s-6502.asm out/6502
python3 run_6502.py out/6502                       # --nogames skips Tiny BASIC
python3 chkbr6502.py out/6502/b8s-6502-gen.lst     # asm80 misses some bad 6502 branches
VARIANTS=$'0 0\n0 1' ./build.sh M6809 ../6809/b8s-6809.asm out/6809
python3 run_6809.py out/6809                       # -nogames skips Tiny BASIC
python3 sizes.py out/z80                           # bytes per variant
```

- The Z80 and 8080 runs take a minute or two.
- The 6502 takes about a minute.
- The 6809 emulator is much slower: tens of minutes with Tiny BASIC.

## The files

| File | What it does |
|---|---|
| `ref.py` | Reference interpreter written from the spec. It produces the expected output for every test |
| `tests.py` | The suite: `SUITE` (program, input), `MC` (machine-code tests per CPU), `ERRS` (checked-build errors) |
| `run_tests.py` | `check()` runs one build against everything, including Tiny BASIC and the Ctrl-C test |
| `harness_z80.py` | Z80/8080 emulator wrapper. In generic builds it traps CONIN/CONOUT/CONST/EXIT; in CP/M builds it emulates BDOS 6, 10, 15, 20 and 26 and loads the program as a file |
| `harness_6502.py`, `harness_6809.py` | The same wrapper for py65 and MC6809 |
| `games/` | Your programs. `TINYBAS.B8S` is part of the suite |
| `esc2slash.py` | Converts programs from the old `>` string escape to `/` |
| `mkrel.py` | Copies the builds in `out/` to the `.bin`, `.COM` and `.lst` files next to each source |

A harness finds `PROG`, `CONIN` and the other addresses in the assembler listing (`.lst`), so a source must keep those symbol names.
