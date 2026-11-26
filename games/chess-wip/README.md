# Chess, work in progress (checkpoint after step 2)

Not a game yet: move generation, make/unmake and perft, plus the tools that measured them.
`CHESSDEV.TXT` becomes `games/CHESS.TXT` once the design choices are settled.

| File | What it does |
|---|---|
| `CHESSDEV.TXT` | Board, generators (full: H J, captures only: A B), make M, unmake U, perft P, setup F |
| `perftcheck.py FILE D` | Perft 1..D of five positions on ref.py against python-chess (queen-only promotion) |
| `measure.py FILE base fast [--perft]` | Z80 cycles: full and capture generation, make+unmake, perft (needs `out/z80` from build.sh) |
| `mgen.py FILES` | Mean generation cycles over the five positions, for comparing variants |
| `gengen.py FILE` | Writes the four generator variants (border or s&136 tests, per-side or shared tests) |
| `model.py`, `model2.py` | Node counts of the planned search in Python, times the measured costs: seconds per move |
| `prof2.py`, `runref.py`, `bench.py`, `refperft.py` | Helpers: profile per word, run on ref.py, run on the Z80 harness, reference perft |

Run from this folder, after `pip install z80 chess==1.10.0` and building the Z80 interpreters with
`build.sh` (small, base and fast) as in `B8Script-interpreters/testing/README.md`.
