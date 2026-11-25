# B8Script for Beginners: A Stack of Fun

Nov 22, 2026 · @ROB8S

**Contents**

- [Welcome](#welcome)
- [Lesson 1: The stack, or how to think backwards](#lesson-1-the-stack-or-how-to-think-backwards)
- [Lesson 2: Making it talk](#lesson-2-making-it-talk)
- [Lesson 3: Juggling the stack](#lesson-3-juggling-the-stack)
- [Lesson 4: Variables, or boxes with names](#lesson-4-variables-or-boxes-with-names)
- [Lesson 5: Making decisions](#lesson-5-making-decisions)
- [Lesson 6: Going round in circles (on purpose)](#lesson-6-going-round-in-circles-on-purpose)
- [Lesson 7: Teaching B8Script new words](#lesson-7-teaching-b8script-new-words)
- [Lesson 8: Listening to the keyboard](#lesson-8-listening-to-the-keyboard)
- [Final project: Guess the number](#final-project-guess-the-number)
- [Cheat sheet](#cheat-sheet)
- [Answers to the challenges](#answers-to-the-challenges)

## Welcome

B8Script is a tiny programming language where every command is a single character, and you can learn its basics in an afternoon. It was made for little 8-bit computers with 64 KB of memory, so its smallest build fits in under a kilobyte on a Z80. It's also great fun on a modern PC.

You don't need any programming experience. You do need a willingness to read things a bit backwards at first. By the end you'll have written a guessing game.

**How this tutorial works.** Each lesson shows some code, tells you what it prints, and explains why. Then there's a **Challenge**. Answers are at the end, but try first: puzzling it out is the fun part.

### Getting B8Script running

The interpreters live in this repo, in the [`B8Script-interpreters`](../B8Script-interpreters) folder. On Windows, the easiest one to learn with is **`B8SE.EXE`**, in the `win32/base` folder:

- the **E** means it has a line editor, so you can type a line and it runs straight away;
- it's a *checked* build, so when you make a mistake it tells you what went wrong instead of doing something strange. (An unchecked build has a **U** right after the `B8S` of its name: `B8SU.EXE`.)

Open a command window in that folder and type `B8SE`. Now you can type B8Script and press Enter to run it.

**One catch: start lines with a space.** In the editor, a line that begins with a digit is treated as a line number for a stored program. So when you try `2 3+#`, type it as ` 2 3+#`, with a space in front. Spaces are ignored by B8Script, so this costs nothing.

You can also write a program in any text editor, save it as `HELLO.B8S`, and run it with `B8S HELLO.B8S`. On other machines (CP/M, a 6502 or Z80 homebrew), see the appendices in the [spec](b8script.md).

If a program runs away and won't stop, press **Ctrl-C**. That works in every version.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Lesson 1: The stack, or how to think backwards

B8Script keeps its numbers on a **stack**, like a stack of pancakes. You can only put a pancake on top, and you can only take one off the top.

A number in your program goes onto the stack. An operator like `+` takes the top two off, adds them, and puts the answer back. So instead of writing `2 + 3`, you write the numbers first and the operator after:

```text
2 3+#
```

This prints `5`. The `#` takes the top number off the stack and prints it. Here's what happens, one character at a time:

| Character | What it does | Stack afterwards (top on the right) |
| --- | --- | --- |
| `2` | Push 2 | 2 |
| (space) | Nothing: spaces just separate numbers | 2 |
| `3` | Push 3 | 2 3 |
| `+` | Take 3 and 2, push 5 | 5 |
| `#` | Take 5 and print it | (empty) |

Putting the operator after its numbers is called **postfix** notation, or Reverse Polish Notation. Old HP calculators work this way, and so does the language Forth.

### Why bother?

Postfix never needs brackets or rules about what goes first. In ordinary maths, `(2 + 3) × 4` and `2 + 3 × 4` give different answers, and you need brackets to say which you mean. In postfix, the order you write things *is* the order they happen:

| Ordinary maths | B8Script | Prints |
| --- | --- | --- |
| (2 + 3) × 4 | `2 3+4*#` | 20 |
| 2 + (3 × 4) | `2 3 4*+#` | 14 |
| 10 − 4 | `10 4-#` | 6 |

In the second line, `2 3 4` piles up three numbers. `*` multiplies the top two (3 × 4 = 12), leaving `2 12`, then `+` adds those.

Note that `10 4-` means 10 − 4, not 4 − 10. The numbers keep the order you wrote them in. The four maths operators are `+` `-` `*` and `/`, and we'll meet `/` properly in Lesson 3.

**Challenge 1.** Write B8Script that prints the answer to (7 + 5) × (10 − 6). Hint: work out each bracket, leaving both answers on the stack, then multiply.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Lesson 2: Making it talk

Three characters print things: `#` prints a number, `$` prints a string and `'` prints a single character.

### Strings

Every programmer's first program:

```text
"Hello, world!/M/J"$
```

The `"` marks the start and end of some text. When B8Script meets it, it puts the text's **address** (where it lives in memory) on the stack. Then `$` takes that address and prints the text.

The `/M/J` at the end is a new line. A slash followed by a capital letter makes a special control character: `/M` returns the cursor to the start of the line and `/J` moves it down one. Together they start a new line, like pressing Enter. (A slash and a *small* letter does something else, which Lesson 4 shows.)

Because slash is special in strings, a real slash has to be written twice. `"either//or"$` prints `either/or`. A quote mark inside a string is `/"`.

### Numbers and words together

```text
"The answer is "$ 6 7*#
```

This prints `The answer is 42`. Note the space inside the string before the closing quote: `#` doesn't add any spaces of its own.

### Single characters

Every letter has a number code: A is 65, B is 66, and so on; lowercase a is 97. The `'` prints the character for a code:

```text
72'105'33'
```

This prints `Hi!`, because 72 is H, 105 is i and 33 is the exclamation mark.

### Comments

B8Script has no special comment character. Instead, write a string and throw it away with `;` (which drops the top of the stack, as we'll see in Lesson 3):

```text
"This is a note to myself";
```

**Challenge 2.** Print `3 + 4 = 7`, letting B8Script work out the 7. Then try it on two lines, with the sum on the first line and `Easy!` on the second.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Lesson 3: Juggling the stack

Sometimes the numbers on the stack are in the wrong order, or you need one twice. Three characters rearrange the pancakes:

| Char | Name | Stack before → after | Example | Prints |
| --- | --- | --- | --- | --- |
| `:` | dup (copy the top) | `a` → `a a` | `5:*#` | 25 |
| `;` | drop (throw the top away) | `a b` → `a` | `1 2;#` | 1 |
| `%` | swap (swap the top two) | `a b` → `b a` | `10 3%-#` | −7 |

`5:*` squares a number: copy it, then multiply it by itself. `10 3%-` swaps to `3 10` before subtracting, so it works out 3 − 10.

### The minus trap

This is the one thing that catches everybody. The minus sign has two jobs:

- **directly before a digit**, it makes a negative number: `-5` is minus five;
- **anywhere else**, it subtracts.

So watch what happens when you leave out a space:

| You write | B8Script sees | Result |
| --- | --- | --- |
| `20 5- 3*#` | 20, 5, subtract (15), 3, multiply | prints 45 |
| `20 5-3*#` | 20, 5, **−3**, multiply (5 × −3) | prints −15, and the 20 is left lying around |

The rule: **if a number comes straight after a minus you mean to subtract, put a space after the minus.** Writing `5- 3` is safe; `5-3` is two numbers, 5 and −3.

### Division gives you two answers

`/` divides, and leaves both the answer and the remainder, with the remainder on top:

```text
17 5/#" "$#
```

This prints `2 3`. 17 ÷ 5 is 3 remainder 2, and the remainder is on top, so it's printed first. Usually you want just one of them:

| You want | Write | `17 5` gives |
| --- | --- | --- |
| Just the answer | `/;` (divide, drop the remainder) | 3 |
| Just the remainder | `/%;` (divide, swap, drop the answer) | 2 |

All B8Script numbers are whole numbers from −32768 to 32767; there are no fractions. Go past the end and they wrap round, like a car's odometer: 32767 + 1 gives −32768.

**Challenge 3.** Using `:` and no variables, print the cube of 6 (6 × 6 × 6). Bonus: is 100 divisible by 7? Print the remainder to find out.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Lesson 4: Variables, or boxes with names

The stack is great for quick sums, but sometimes you want to keep a number for later. B8Script gives you 26 **variables**, named by the lowercase letters `a` to `z`. Think of them as 26 labelled boxes.

Two characters use them:

- `!` (store) puts a number in a box;
- `@` (fetch) gets a copy of the number out.

```text
7x! x@#
```

This prints `7`. Read it as "7, into box x, store" and then "box x, fetch, print".

The letter on its own doesn't give you the number; it gives you *which box*. That's why you always see `x@` to read and `x!` to write. Forgetting the `@` is a classic mistake, and it prints a number that seems to come from nowhere: the box's address, not what's in it.

### Changing a variable

To change a variable, fetch it, do the sum, and store it back:

```text
100m! m@25-m! "Coins: "$ m@#
```

This starts with 100 coins, spends 25, and prints `Coins: 75`. The `m@25-m!` part reads as "fetch m, push 25, subtract, store in m".

### Variables inside strings

Printing a variable between two pieces of text is so common that strings have a shortcut for it: a slash and the variable's letter, inside the string, prints that variable's number right there.

```text
100m! m@25-m! "You have /m coins left./M/J"$
```

This prints `You have 75 coins left.` It is the same as `"You have "$ m@# " coins left./M/J"$`, just shorter. The value is read when `$` prints the string, so if m changes and you print the same string again, you see the new number.

Two catches. It only works for a plain variable: to print a sum, or anything worked out on the stack, use `#` between two strings. And a slash before a small letter always means a variable, so a slash meant as a slash is written twice: `"y//n"` prints `y/n`.

Adding one to a counter is so common that you'll see `i@1+i!` everywhere. Remember it; the loops in Lesson 6 use it.

**Store before you read.** A variable starts out holding whatever junk was in memory, so always give it a value before you use it. The checked builds set them all to 0, but the unchecked builds don't.

**Challenge 4.** A rectangle is 12 wide and 7 high. Store those in `w` and `h`, then print `Area: 84` by working it out from the variables. Then print `12 by 7` using the shortcut.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Lesson 5: Making decisions

Programs get interesting when they can choose. First, B8Script needs a way to ask questions.

### True and false are numbers

The comparisons `<` (less than), `>` (greater than) and `=` (equal) take two numbers and leave an answer:

| Code | Question | Prints |
| --- | --- | --- |
| `3 5<#` | Is 3 less than 5? | −1 (true) |
| `3 5>#` | Is 3 greater than 5? | 0 (false) |
| `4 4=#` | Is 4 equal to 4? | −1 (true) |

**0 means false, and anything else means true.** Comparisons give −1 for true. To flip true and false, use `0=` ("is it zero?").

### If

Round brackets make a **block**. The `(` takes the top of the stack: if it's true, the code inside runs; if it's false, the whole block is skipped.

```text
7a! a@5>( "Big!"$ 0)
```

This prints `Big!`. Try it with `3a!` instead and it prints nothing.

What's the `0` before the `)`? The closing bracket also takes a number from the stack, and asks "go round again?" For an *if*, the answer is always no, so you write `0)`. Lesson 6 says yes.

### If-else

To do one thing or the other, you need the answer twice: once for the *then* block and once, flipped, for the *else* block.

```text
3a! a@5>:{( "Big"$ 0)}0=( "Small"$ 0)
```

This prints `Small`. Step by step:

1. `a@5>` asks whether a is greater than 5.
2. `:` copies the answer, and `{` tucks the copy away safely on a second, hidden stack.
3. `( "Big"$ 0)` runs only if the answer was true.
4. `}` brings the copy back, `0=` flips it, and `( "Small"$ 0)` runs only if the original answer was false.

The hidden stack is called the **return stack**. B8Script uses it to remember where blocks start, so always pair `{` with `}` in the same block, and don't jump out of the block between them.

**Challenge 5.** Store a temperature in `t`. Print `Freezing!` if it's below 0, and `Not freezing` otherwise. Test it with 10 and with −5 (that's `-5t!`).

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Lesson 6: Going round in circles (on purpose)

A loop is the same round brackets as an *if*, with one change: the closing `)` gets a true answer when you want to go round again. That's the whole trick. One kind of bracket does both jobs.

- `1(` means "always go in".
- `flag)` means "go back to the `(` if the flag is true, otherwise carry on".

### Counting up

```text
1i! 1( i@# " "$ i@1+:i! 11<)
```

This prints `1 2 3 4 5 6 7 8 9 10`. Reading it piece by piece:

| Piece | Meaning |
| --- | --- |
| `1i!` | Start the counter i at 1 |
| `1(` | Enter the loop |
| `i@# " "$` | Print i and a space |
| `i@1+` | Work out i + 1 |
| `:i!` | Copy it and store the copy back in i, leaving the new value on the stack |
| `11<)` | Is the new value less than 11? If so, go round again |

The `:i!` trick is worth remembering: it stores a value and keeps it for the test.

### Counting down, with no variable at all

You can keep the counter on the stack instead:

```text
10 1( :# " "$ 1-: ); "Liftoff!"$
```

This prints `10 9 8 7 6 5 4 3 2 1 Liftoff!`. Each time round, `:#` prints a copy of the counter, `1-` takes one off, and `:` copies it for `)` to test. When the counter reaches 0, which is false, the loop ends. The leftover 0 is then thrown away by `;`.

### Breaking out

The backslash `\` means "if true, leave this block now". It's handy when the test belongs in the middle of the loop:

```text
0n! 1( n@1+:n!# " "$ n@5=\ 1)
```

This prints `1 2 3 4 5`. The `1)` at the end would loop forever, but `n@5=\` jumps out once n reaches 5.

A program that loops forever by mistake is no disaster: press **Ctrl-C**.

**Challenge 6.** Print the five times table: `5 10 15` and so on, up to `50`. Then, for a harder one, print only the even numbers from 2 to 20. Hint: the remainder of an even number divided by 2 is 0.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Lesson 7: Teaching B8Script new words

The uppercase letters `A` to `Z` are yours to define. Each one can become a new command, called a **word**. Square brackets define it:

```text
[S:*] 7S#
```

This prints `49`. `[S:*]` means "from now on, S means `:*`" (copy and multiply, which squares a number). After that, `7S` squares 7.

A word takes its inputs from the stack and leaves its results there, just like `+` does. That's why words fit together so neatly.

### A word with a loop inside

```text
[B 1( "*"$ 1-: );] 5B "/M/J"$ 3B
```

B prints a bar of stars as long as the number you give it:

```text
*****
***
```

It's the countdown loop from Lesson 6, printing a star each time instead of the number.

### A word that uses itself

A word can call itself. Here's the factorial (7! = 7 × 6 × 5 × 4 × 3 × 2 × 1), straight from the spec:

```text
[F :1>( :1-F* 0)] 7F#
```

This prints `5040`. In words: if the number is more than 1, multiply it by the factorial of one less. Each F calls a smaller F, until it reaches 1 and the answers multiply back up.

### Rules for words

- Define a word before you use it. Running the definition again replaces it.
- `]` means "done, go back to whoever called me". A `\` inside a word can leave early.
- Words that use only the stack are the safest. If a word stores into a variable, it can wreck a variable that the code calling it was using.

**Challenge 7.** Define a word `C` that cubes a number, using your word `S` inside it. Then define `L` to print a new line, and use both to print the cubes of 2 and 3 on separate lines.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Lesson 8: Listening to the keyboard

The question mark `?` reads the keyboard. The number you give it says how long to wait:

| Code | What it does |
| --- | --- |
| `0?` | Wait for a key, then push its code |
| `20?` | Wait up to about 20 milliseconds; push the key's code, or 0 if nothing was pressed. Great for games that keep moving |
| `-72?` | Read a whole typed line, up to 72 characters, and push its address |

`?` doesn't show the key on the screen, so print it yourself if you want it seen:

```text
"Press a key: "$ 0? :' " is code "$ #
```

Press A and it prints `Press a key: A is code 65`. The `:` copies the code so you can print it twice: once as a character with `'`, once as a number with `#`.

### Reading a number

To read a number someone types, you take one key at a time and build the number up. This is one of the spec's ready-made idioms:

```text
[N0v!1(0?:48<\48-:#v@10*+v!1);v@]
```

That looks like a cat walked across the keyboard, so here it is slowly:

| Piece | Meaning |
| --- | --- |
| `0v!` | The number so far, v, starts at 0 |
| `1(` | Loop: |
| `0?` | wait for a key |
| `:48<\` | if its code is below 48 (the code for 0), leave the loop: Enter is 13 |
| `48-` | turn the digit's code into its value: 0 is code 48, 1 is 49 |
| `:#` | show the digit on screen |
| `v@10*+v!` | v becomes v × 10 + the digit |
| `1)` | and go round again |
| `;v@` | Throw away the Enter key, and leave the number on the stack |

Now you can use it:

```text
"Pick a number: "$ N "/M/JDouble that is "$ :+#
```

Type 21 and press Enter, and it prints `Double that is 42`. (`:+` doubles: copy, then add the number to itself.)

**Challenge 8.** Ask for two numbers with N and print their total. Then make it friendlier: if the total is over 100, also print `Wow, that's a lot!`

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Final project: Guess the number

You now know enough to read a real game. This one is from the B8Script spec: the computer picks a number from 1 to 99, and you guess it with hints of "higher" and "lower". Save it in a text editor as `GUESS.B8S` and run it with `B8S GUESS.B8S`.

```text
[M/%;]
0r! [K 0 1( ; r@1+ 100M r! 1? :0=)]
[N 0v! 1( K :48<\ 48- :# v@10*+v! 1) ; v@]
"Guess my number from 1 to 99. Press a key to start./M/J"$ K;
r@99M1+s! 0t!
1( "/M/JYour guess: "$ N g! t@1+t!
   g@s@<( "  higher"$ 0)
   g@s@>( "  lower"$ 0)
   g@s@=0=)
"/M/JGot it in /t tries!/M/J"$
```

Ten lines, and every piece is something you've met. Here's how it works.

**Line 1: `[M/%;]`** defines M, "modulo": divide and keep only the remainder. `27 10M` gives 7.

**Line 2: K, a key reader that rolls dice.** B8Script has no random numbers, so this game makes its own from *you*. K is a loop that keeps adding 1 to r, wrapping round at 100, and checks for a key with the quick `1?` each time round. It spins thousands of times a second, so the exact moment you press a key leaves r at an unpredictable number. When a key arrives, `:0=` is false, the loop ends, and the key is left on the stack.

**Line 3: N** is the number reader from Lesson 8, but it waits with K instead of `0?`. So the dice keep rolling while you type.

**Line 4** prints the welcome and waits for a key with K. The `;` throws the key away: only the time you took mattered.

**Line 5** makes the secret number. `r@99M` gives 0 to 98, and `1+` makes it 1 to 99. It goes in s. The guess counter t starts at 0.

**Lines 6 to 9: the main loop.** Read a guess into g and add 1 to the count. If the guess is too low, say higher; if too high, say lower. The last line, `g@s@=0=)`, is the loop's test: go round again while the guess is *not* equal to the secret.

**Line 10** celebrates, with the number of tries: `/t` prints t inside the string.

### Make it yours

- Make it 1 to 999. You'll need to change three numbers. (Which three?)
- Give it a limit: after 7 wrong guesses, print `Out of guesses! It was` and the number. Hint: the guess-checking loop can end on a test made with `|`, which is true if either side is true.
- Add `"/{"$` at the start to clear the screen first. A slash and `{` inside a string clears the screen and puts the cursor at the top left; the spec's *Console* chapter has the others, such as `/~` to put the cursor anywhere.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Cheat sheet

Every character this tutorial used. In the *Stack* column, the left side is what the character takes and the right side is what it leaves, with the top on the right.

| Char | Does | Stack |
| --- | --- | --- |
| `0`–`9` | A number (`-` straight before a digit makes it negative) | → n |
| `+` `-` `*` | Add, subtract, multiply | a b → result |
| `/` | Divide: answer, then remainder on top | a b → answer remainder |
| `<` `>` `=` | Compare: −1 for true, 0 for false | a b → flag |
| `:` | Dup: copy the top | a → a a |
| `;` | Drop: throw the top away | a → |
| `%` | Swap the top two | a b → b a |
| `{` `}` | Park a value on the return stack, and get it back | a → / → a |
| `a`–`z` | A variable's address | → addr |
| `!` `@` | Store into, fetch from a variable | n addr → / addr → n |
| `"text"` | A string's address | → addr |
| `$` | Print a string (`/M/J` is a new line, `//` a slash, `/x` the variable x, `/{` clears the screen) | addr → |
| `#` | Print a number | n → |
| `'` | Print a character from its code | code → |
| `?` | Read the keyboard: `0?` waits for a key, `20?` waits briefly, `-72?` reads a line | n → key |
| `(` | Enter the block if true, skip it if false | flag → |
| `)` | Go back to the `(` if true, carry on if false | flag → |
| `\` | Leave the block or word now, if true | flag → |
| `[X ... ]` | Define word X | |
| `A`–`Z` | Run a word you defined | |

**Handy patterns**

| Pattern | Code |
| --- | --- |
| If | `flag( ... 0)` |
| If-else | `flag:{( ... 0)}0=( ... 0)` |
| Loop while | `1( ... flag)` |
| Loop with a break | `1( ... flag\ ... 1)` |
| Add 1 to i | `i@1+i!` |
| Remainder | `/%;` |
| Comment | `"any text";` |

There's much more in the full [spec](b8script.md): the heap, machine code with the grave character, screen control and a large Idioms section. The spec's Programs chapter, with Conway's Life and Star Trek, makes great reading once these lessons feel easy.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)

## Answers to the challenges

No peeking until you've tried! There's usually more than one right answer; if yours prints the right thing, it's right.

**1.** `7 5+10 6-*#` prints 48. The first bracket leaves 12, the second leaves 4 beside it, and `*` multiplies them.

**2.** `"3 + 4 = "$ 3 4+#` and, on two lines, `"3 + 4 = "$ 3 4+# "/M/JEasy!"$`

**3.** `6::**#` prints 216: two copies make three 6s, then two multiplies. For the bonus, `100 7/%;#` prints 2, so no, 100 isn't divisible by 7.

**4.** `12w! 7h! "Area: "$ w@h@*#`, and then `"/M/J/w by /h"$`. The area needs `#`, because it is worked out on the stack; w and h are plain variables, so the shortcut prints them.

**5.**

```text
10t! t@0<:{( "Freezing!"$ 0)}0=( "Not freezing"$ 0)
```

Change the start to `-5t!` for the freezing test.

**6.** The five times table: `1i! 1( i@5*# " "$ i@1+:i! 11<)`

Even numbers, using the remainder:

```text
1i! 1( i@2/%;0=( i@# " "$ 0) i@1+:i! 21<)
```

Or the sneaky way, counting in twos: `2i! 1( i@# " "$ i@2+:i! 21<)`. Sneaky is allowed.

**7.**

```text
[S:*] [C:S*] [L"/M/J"$] 2C# L 3C#
```

This prints 8 and then 27. C copies the number, squares the copy with S, then multiplies: n × n² = n³.

**8.** With N already defined:

```text
"First: "$ N "/M/JSecond: "$ N + :t! "/M/JTotal: "$ #
t@100>( "/M/JWow, that's a lot!"$ 0)
```

`:t!` keeps a copy of the total in t, so it can still be tested after `#` has printed it.

**Guess the number, 1 to 999.** Change `100M` in K to `1000M`, `r@99M` to `r@999M`, and the 99 in the welcome message to 999.

**Guess the number, with a limit.** Replace the last two lines of the game with these:

```text
   g@s@= t@7= | 0=)
g@s@=:{( "/M/JGot it in /t tries!/M/J"$ 0)}
0=( "/M/JOut of guesses! It was /s/M/J"$ 0)
```

The loop now ends when the guess is right *or* the seventh guess is used up. Afterwards an if-else decides which message you've earned.

[↑ Back to top](#b8script-for-beginners-a-stack-of-fun)
