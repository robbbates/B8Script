# B8Script

A postfix stack language for 64 KB 8-bit computers, by Robb Bates. Every instruction is one ASCII character, and the source text runs in place, with no compile step.

```
"Hello, world!"$`'
[F :1>( :1-F* 0)] 7F#
```

## Where things are

| Path | What it is |
|---|---|
| [`docs/b8script.md`](docs/b8script.md) | The spec: the language, idioms, examples, how to implement it, and an appendix per CPU |
| [`B8Script-interpreters/`](B8Script-interpreters/) | Interpreters for the Z80, 8080, 6502 and 6809 (generic ROM images and CP/M .COM files) and for the Windows command shell (32-bit .EXE files), checked and unchecked, with and without a line editor. Its README covers sizes and building |
| [`games/`](games/) | Fifty-four games, from Star Trek and Klondike to thirty-two that each fit in a tweet. Its README says how to run and play each one |
| [`B8Script-interpreters/testing/`](B8Script-interpreters/testing/) | The reference interpreter, the test suite and emulator harnesses, which also run the games |
| [`docs/b8sms.md`](docs/b8sms.md) | Thirty-one tiny games: ten that fit in a text message (B8SMS, 160 characters), the same ten in a 140-character tweet, and eleven more in 280, with how each one fits |
| [`archive/1.0beta/`](archive/1.0beta/) | The original B8Script 1.0beta for CP/M (2025), kept for history |

## History

B8Script began as B8SCRIPT.COM, a 2 KB CP/M program for the Z80 with a built-in editor and loadable plugins ("If Forth and VTL had a love child!"). That dialect used different characters: `{` `}` for loops, `,` to print, `#` for the heap, `$` for hex literals, `~` for string compare and `` ` `` to load plugins. It is kept unchanged in `archive/1.0beta/`, with its lunar lander game and the CHAR, PRINTHEX and UNSIGNED plugins. Its user manual was a Google Doc that is now out of date.

The language was then redesigned into the one in the spec, and the interpreters were rewritten for size. The plugin system was dropped: machine code is loaded and called with the grave (`` ` ``) instead.

In November 2026 the grave became a prefix: a grave and one more character are one command. That gave the language its own codes for the cursor and the screen (so a console no longer has to understand ANSI), random numbers, a new line, minimum and maximum, and adding or subtracting 1 in place. The fifty-four games came out 4,104 bytes shorter between them (7 per cent), and the smallest interpreters, which had been under 800 bytes, are now under 1,000.

> There once was a game small and sweet
> That Mr. Bates crammed in a tweet
> With all the fluff stripped
> It ran on B8Script
> A CP/M programming feat!
