# Writing a new B8Script program

A checklist for writing a new game or program for this repository: what to read, the mistakes that keep coming up, where the files go, how to test, and what else to update. It is written so that it can be pasted into an AI coding session as a prompt, and it works just as well as a list for a person.

To use it as a prompt, copy everything from the line below to the end of the file, and fill in the first paragraph.

---

I want to write a new B8Script program: [DESCRIBE IT HERE: what it is, how it plays, the keys, any size limit such as "a tweet in 140 characters"].

The repository is robbbates/B8Script. Work on a branch, and open a pull request only when I ask. Before writing code, read what's below, then propose a design (data layout, words, variables, keys, screen) and wait for my OK.

## Learn the language first
B8Script is a tiny stack language interpreted from its source text: every command is one character.
- docs/b8script.md is the spec. Read these sections closely: Execution model, Literals, Character reference, Control flow and "How skipping works", "Memory, heap and machine code", "Errors and checked builds", The console, Idioms, "Tips and gotchas" and "Don't rely on". The appendices give each CPU's memory map and limits.
- docs/idioms.md is the full collection of idioms, tips and tricks, each with the game it came from. Use it: most problems already have an idiom.
- docs/tutorial.md shows the beginner-level style.
- For worked examples, read a few commented sources in games/*.TXT that resemble what I want: a board game, a real-time game, a text adventure. For tiny games, read docs/tweets.md and games/tweet140/ and games/tweet280/.

## Gotchas that bite
- A minus before a digit is a negative literal: `1-3&` is 1 then −3. Write `1- 3&`.
- In strings, `/` escapes: `//` is a slash, `/x` prints variable x, and `/"` doesn't end the string. "y/n" must be written "y//n".
- Comments are strings dropped at once, `"text";`. They cost time where they run, so keep them out of hot loops in the stripped form.
- There's no clock to read. Seed random numbers from key timing (`0 1(1+1?0=)` counts until a key) and use the generator idioms.
- Stacks are small on 8-bit builds: about 110 return-stack entries, which limits recursion depth. Check the spec's appendices.
- Store and keep with `:x!`, not `x!x@`. Avoid no-op pairs such as `%%`, `{}` and `:;`.
- The screen is 80 × 24 on an ANSI terminal. Use the console escapes (`/{` clears, `/~` positions the cursor, `/}` clears to the end of the line) to redraw in place rather than letting output scroll.

## Files and names
- Write the commented source as NAME.TXT, and make the stripped program NAME.B8S with `python3 B8Script-interpreters/testing/b8strip.py NAME.TXT NAME.B8S`. `b8strip.py --same NAME.TXT NAME.B8S` checks that they match. For tweet-sized games there is only the .B8S, kept in stripped form.
- Names are at most 8 characters (CP/M) and must not repeat any name in games/, games/tweet140/, games/tweet280/ or programs/.
- Where it goes:
  - full-size games in games/;
  - tiny games in games/tweet140/ (at most 140 characters) or games/tweet280/ (at most 280);
  - non-game programs in programs/.

## Test it
Work from B8Script-interpreters/testing/.
- **Run it:**
  - on the reference interpreter: `python3 ref.py FILE "keys"` (the keys take escapes, such as `\r` for Return);
  - as a checked build, which stops with a report on any stack, bracket or other error: in Python, `from ref import Ref; Ref(open(F,'rb').read(), b'keys', checked=True).run()`.

  Debug in checked mode until it plays cleanly.
- **Scripted play:** add tests to test_games.py, following its TESTS entries. Each is a fixed key sequence and the messages that must appear: a win, a loss and a few key situations. Tiny games go in test_tweets.py, which also checks the size limits. Programs go in test_programs.py. Run them.
- **On the real interpreters:** build them with the commands in B8Script-interpreters/testing/README.md (`SPEED=0|1|2 ./build.sh ...` for each CPU, and `./build_win32.sh`). Then `python3 gamecheck.py out` compares the game's output on every CPU build with ref.py. The 6502 and 6809 runs are slow, so you can start with the Z80 and Windows folders alone.
- Run `python3 test_web.py` after adding the game to the web player.

## Wire it in
- **README:** add a row to games/README.md (or programs/README.md, or the tweets section) in the same format: the bold name, what it is, and how to play. web/build.py reads its help line from that table.
- **Web player:**
  - add the program's on-screen keys to the KEYS table in web/build.py;
  - run `python3 web/build.py` to rebuild web/b8script.html;
  - `python3 web/build.py --check` confirms it's up to date.
- **Counts:** update the game counts in the root README.md and games/README.md.
- **Tiny games:** add a write-up to docs/tweets.md, with the code block matching the file exactly and its size.
- **Idioms:** if the program shows a new idiom, add it to docs/idioms.md with the game as its source.

## Style
- Docs describe the current state only. Write plainly and briefly, in the existing docs' manner.
- In the .TXT, comment each word with its stack effect, as the existing games do: `"N: ( -- n )  ..."`.
- The repository is under the PolyForm Noncommercial License 1.0.0, copyright Robb Bates. New programs come under it too.
