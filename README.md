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
| [`B8Script-interpreters/`](B8Script-interpreters/) | Interpreters for the Z80, 8080, 6502 and 6809 (generic ROM images and CP/M .COM files) and for the Windows command shell (32-bit .EXE files), checked and unchecked, with and without a line editor, in three tiers for every CPU: small, base and fast (about twice as fast as small). Its README covers sizes, speed and building |
| [`web/`](web/) | The web player: [`b8script.html`](web/b8script.html) runs B8Script and every game and program in a browser, on a computer or a phone. One file: download it and open it |
| [`games/`](games/) | Forty-two games, from Star Trek and Klondike to twenty-one that each fit in a tweet. Its README says how to run and play each one |
| [`programs/`](programs/) | Programs that aren't games: Tiny BASIC, a memory monitor, the BYTE sieve benchmark, the digits of pi and the Mandelbrot set |
| [`B8Script-interpreters/testing/`](B8Script-interpreters/testing/) | The reference interpreter, the test suite and emulator harnesses, which also run the games |
| [`docs/tweets.md`](docs/tweets.md) | Twenty-one tiny games, each in a tweet: ten in 140 characters and eleven in 280, with how each one fits |
| [`editors/vscode-b8script/`](editors/vscode-b8script/) | Syntax highlighting for Visual Studio Code: words, variables, numbers, strings and their escapes, comments, and the command groups each in their own color |

> There once was a game small and sweet
> That Mr. Bates crammed in a tweet
> With all the fluff stripped
> It ran on B8Script
> A CP/M programming feat!
