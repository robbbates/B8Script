# The B8Script web player

[`b8script.html`](b8script.html) runs B8Script in a web browser, on a computer or a phone. It is one file with everything inside it: download it and open it, from disk or from any web server. No network is needed.

Every game in [`games/`](../games/) and every program in [`programs/`](../programs/) is in its menu, with a line on how to play. **Open** runs any other `.B8S` or `.TXT` file, and **Edit** shows a program's text to change and run. The **?** button explains the rest.

## Keys

- Ctrl-C, or **Stop**, stops a program.
- The arrow keys send Esc `[` and a letter, as on an ANSI terminal.
- Pasting types the text, so a BASIC program can be pasted into Tiny BASIC.
- On a phone, tap the screen for the keyboard. The bar below the screen has Esc, Ctrl, Tab, the arrows, Backspace, Return and Break.
  - **Pad** adds big keys for games: w a s d, Space, Return, y, n and q. Held down, they repeat.
  - Sideways, the pad sits either side of the screen.

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
- **Timing:** `n?` waits n milliseconds by the clock. Between waits a program runs as fast as the browser can run it.
- **The screen** is 80 × 24, and understands the ANSI sequences the console escapes send.

## Files

| File | What it is |
|---|---|
| `b8script.html` | The player, built by `build.py`. Don't edit it: edit the sources and build it again |
| `player.html` | The page: its look, the screen, the keys and the menu |
| `b8s.js` | The interpreter |
| `build.py` | Builds `b8script.html` from `player.html`, `b8s.js` and the programs, taking each program's line of help from the READMEs. `build.py --check` checks it is up to date. Run it after changing a game or a program |

The tests are in [`B8Script-interpreters/testing/`](../B8Script-interpreters/testing/):
- **`test_web.py`** runs the test suite, Tiny BASIC, the programs and the scripted games on `b8s.js` under Node, and checks every run against `ref.py`, byte for byte.
- **`test_page.js`** drives the page in Chromium (Playwright), as a computer and as phones: the screen, typing, the phone's keyboard, the pad, `n?`'s clock, the break key and checked reports.
