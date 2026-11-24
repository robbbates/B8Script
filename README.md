# B8Script

A postfix stack language for 64 KB 8-bit computers, by Robb Bates. Every instruction is one ASCII character, and the source text runs in place, with no compile step.

```
"Hello, world!/M/J"$
[F :1>( :1-F* 0)] 7F#
```

## Where things are

| Path | What it is |
|---|---|
| [`docs/b8script.md`](docs/b8script.md) | The spec: the language, idioms, examples, how to implement it, and an appendix per CPU |
| [`docs/idioms.md`](docs/idioms.md) | Idioms, tips and tricks, collected from the spec, the tutorial and the games, each with the game it came from |
| [`B8Script-interpreters/`](B8Script-interpreters/) | Interpreters for the Z80, 8080, 6502 and 6809 (generic ROM images and CP/M .COM files) and for the Windows command shell (32-bit .EXE files), checked and unchecked, with and without a line editor. Its README covers sizes and building |
| [`games/`](games/) | Fifty-four games, from Star Trek and Klondike to thirty-one that each fit in a tweet and one in 390 characters. Its README says how to run and play each one |
| [`B8Script-interpreters/testing/`](B8Script-interpreters/testing/) | The reference interpreter, the test suite and emulator harnesses, which also run the games |
| [`docs/b8sms.md`](docs/b8sms.md) | Thirty-one tiny games: ten that fit in a text message (B8SMS, 160 characters), the same ten in a 140-character tweet, and eleven more in 280, with how each one fits |
| [`editors/vscode-b8script/`](editors/vscode-b8script/) | Syntax highlighting for Visual Studio Code: words, variables, numbers, strings and their escapes, comments, and the command groups each in their own color |
| [`archive/1.0beta/`](archive/1.0beta/) | The original B8Script 1.0beta for CP/M (2025), kept for history |

## History

B8Script began as B8SCRIPT.COM, a 2 KB CP/M program for the Z80 with a built-in editor and loadable plugins ("If Forth and VTL had a love child!"). That dialect used different characters: `{` `}` for loops, `,` to print, `#` for the heap, `$` for hex literals, `~` for string compare and `` ` `` to load plugins. It is kept unchanged in `archive/1.0beta/`, with its lunar lander game and the CHAR, PRINTHEX and UNSIGNED plugins. Its user manual was a Google Doc that is now out of date.

The language was then redesigned into the one in the spec, and the interpreters were rewritten for size, now under 900 bytes for the smallest builds. The plugin system was dropped: machine code is loaded with the grave (`` ` ``) instead.

> There once was a game small and sweet
> That Mr. Bates crammed in a tweet
> With all the fluff stripped
> It ran on B8Script
> A CP/M programming feat!
