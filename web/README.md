# The B8Script web player

[`b8script.html`](b8script.html) runs B8Script in a web browser, on a computer or a phone. It is one file with everything inside it: download it and open it, from disk or from any web server. No network is needed.

Every game in [`games/`](../games/) and every program in [`programs/`](../programs/) is in its menu, with a line on how to play. **Open** runs any other `.B8S` or `.TXT` file, and **Edit** shows a program's text to change and run. The **?** button explains the rest.

## Keys

- Ctrl-C, or **Stop**, stops a program.
- The arrow keys send Esc `[` and a letter, as on an ANSI terminal.
- Pasting types the text, so a BASIC program can be pasted into Tiny BASIC.
- On a phone, tap the screen for the keyboard. The bar below the screen has Esc, Ctrl, Tab, the arrows, Backspace, Return and Break.
  - Each program has its own big keys: the ones it uses, laid out as it uses them (w a s d as a cross, GREED's eight directions as a 3 × 3 grid, Tic-tac-toe's 1 to 9 as its board, Ski's j and l one each side). **Pad** shows or hides them. Movement keys repeat while held.
  - Upright, **☰** in the screen's corner hides everything but the screen, so that it keeps its room with the phone's keyboard up, for typing in Tiny BASIC or MON; **☰** again shows it all.
  - Closing the phone's keyboard lets go of the focus, so a pad key pressed after it doesn't bring the keyboard back.
  - Sideways, the screen takes the whole height, with the program's keys either side and ⌨, Ctrl, ⌫, ⏎ and Break above them; **☰** shows the bars above and below the screen.

## This build

- **The interpreter** is [`b8s.js`](b8s.js), a JavaScript translation of the reference interpreter (`B8Script-interpreters/testing/ref.py`), step for step.
- **Checked** runs it as a checked build: an error stops the program with the spec's report.
- **Machine code:** there's no CPU to run it, so a grave that would execute code stops the program. The hex loader still stores bytes, and writes the RET byte C9h.
- **Memory:**

  | What | Where |
  |---|---|
  | The letter cells | 0100h |
  | The line buffer | 0200h |
  | The program | 0400h |
  | The heap | after the program, up to FF00h |

  So a program of 60 KB fits.
- **The serial line:** most B8Script machines talk to their terminal over a serial line, and the speed menu sets one: 9600 baud, 115200 baud (where it starts), or full speed, with no line at all.
  - A byte takes 10 bits (a start bit, 8 data bits and a stop bit), so 960 bytes a second at 9600 baud and 11,520 at 115200.
  - While the line is busy, the program waits, as it would for a real UART that holds one byte while sending another. So a game's frame wait starts only once its drawing has gone out.
  - The choice takes effect at once, even in a running program, and the page remembers it.
- **8-bit CPU:** runs B8Script at the pace of a real 8-bit machine, about 24,600 steps a second.
  - That's a Z80 at 7.3728 MHz (an RC2014), at the average of about 300 clock cycles a step measured on the Z80 build.
  - It's an average, so one program's time can differ: a program of cheap steps (stack moves, `+`) runs faster on the real machine, and one heavy on `*` and `/` slower.

    | Program | Here | On the Z80 build |
    |---|---|---|
    | MANDEL | 27 s | 22 s |
    | PI, 250 digits | 216 s | 252 s |
    | SIEVE, 10 passes | 106 s | 77 s |
  - Off, a program runs as fast as the browser can run it.
  - Like the line speed, it takes effect at once and is remembered.
- **Timing:** `n?` waits n milliseconds by the clock.
- **The screen** is 80 × 24, and understands the ANSI sequences the console escapes send.

## Files

| File | What it is |
|---|---|
| `b8script.html` | The player, built by `build.py`. Don't edit it: edit the sources and build it again |
| `template.html` | The page: its look, the screen, the keys and the menu. It has no programs in it, so open `b8script.html`, not this |
| `b8s.js` | The interpreter |
| `build.py` | Builds `b8script.html` from `template.html`, `b8s.js` and the programs, taking each program's line of help from the READMEs; each program's keys are listed in it. `build.py --check` checks it is up to date. Run it after changing a game or a program |

The tests are in [`B8Script-interpreters/testing/`](../B8Script-interpreters/testing/):
- **`test_web.py`** runs the test suite, Tiny BASIC, the programs and the scripted games on `b8s.js` under Node, and checks every run against `ref.py`, byte for byte.
- **`test_page.js`** drives the page in Chromium (Playwright), as a computer and as phones: the screen, typing, the phone's keyboard, the pad, the serial line's speeds, the 8-bit CPU, `n?`'s clock, the break key and checked reports.
