# B8Script Z80 builds with QUICK

Every regular Z80 build again, assembled with `QUICK = 1`: the speed-ups that cost 180 to 230 bytes. Same source ([`../z80/b8s-z80.asm`](../z80/b8s-z80.asm)), same tests, same behaviour; 1.1 to 1.5 times as fast.

| File | The regular build it matches | Bytes | Regular |
|---|---|---|---|
| `B8SZ80Q.COM` | `B8SZ80.COM`, CP/M runner | 1,231 | 1,017 |
| `B8SZ80QC.COM` | `B8SZ80C.COM`, checked | 1,593 | 1,414 |
| `B8SZ80QE.COM` | `B8SZ80E.COM`, with the line editor | 1,860 | 1,646 |
| `B8SZ80QEC.COM` | `B8SZ80EC.COM`, with the editor, checked | 2,227 | 2,048 |
| `b8s-z80-quick-rom-0000.bin` | generic ROM (`ANSI = 0`) | 1,054 | 835 |
| `b8s-z80-quick-rom-checked-0000.bin` | generic ROM, checked | 1,402 | 1,219 |
| `b8s-z80-quick-rom-editor-0000.bin` | generic ROM with the editor | 1,568 | 1,355 |
| `b8s-z80-quick-rom-editor-checked-0000.bin` | the same, checked | 1,951 | 1,742 |
| `b8s-z80-quick-*.lst` | their listings | | |

`B8SZ80QEC.COM` is past the 2,048 bytes the regular builds keep to, and the checked generic ROM built with `ANSI = 1` (1,449 bytes) past the 1,280 of its regular one.

## What QUICK adds

- **A skip cache.** Nearly every skip has happened before (a loop skips the same false block on every pass), so the end of each is remembered: 64 entries in a page of RAM, and the next skip from the same place is one lookup. The page is the one at the heap limit (F000h) in the generic builds, and the page after the image, before the return stack, under CP/M. Only skips in the program text are kept, and the cache is emptied whenever a run starts. A program that changes its own text while it runs is unsafe in these builds.
- **A faster skip.** Two range tests rule out most characters before the six that matter are tested.
- **`*` in 8 rounds** when either operand is below 256.
- **`/` by a power of two** as a shift: `256/` for a high byte, the 32 and 64 of fixed point.
- **A true `)`** reads its block start in place.
- **A variable then `@` or `!`** in one step (unchecked builds).

The interpreters README's [Speed](../README.md#speed) section has the measurements, and the speed builds, about twice as fast, are in [`../fast/`](../fast/).

## Timing under CP/M

`n?` counts keyboard checks under CP/M, as the regular builds do. To tune it, see "Tuning `n?` under CP/M" in the interpreters README: its table has these four files too.
