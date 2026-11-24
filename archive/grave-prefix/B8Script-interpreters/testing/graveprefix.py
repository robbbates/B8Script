"""Convert older B8Script programs to the grave as a prefix (the 2026-11-23 spec).

usage: graveprefix.py [-n] FILE...      -n: report only, change nothing

In the older language a grave did one of two things, chosen by the character
after it, and the screen was driven by ANSI escape sequences printed as
strings. Now a grave and the character after it are one command. This
rewrites what can be rewritten without knowing the program:

  `41C9      ->  `$41C9          the hex loader has its own character
  x@`        ->  x@`!            and so has the call of machine code
  x@1+:x!    ->  x`+             add 1 to a variable, leave the new value
  x@1+x!     ->  x`+;            the same, nothing left (and 1- gives `-)
  "/[[2J/[[H"$   ->  `^          clear the screen and home the cursor
  "/[[H/[[2J"$   ->  `^
  "/[[K"$        ->  `_          clear to the end of the line
  "/[[?25l"$     ->  0`?         cursor off
  "/[[?25h"$     ->  1`?         cursor on
  "/[[H"$        ->  0 0`@       cursor to the top left
  "/[[5;10H"$    ->  4 9`@       rows and columns now count from 0
  13'10'         ->  `'          new line

Everything else is left alone and listed, for you to look at:
  - a string that holds an escape sequence among other text, or one this
    script doesn't know (colours, ESC [2K, ESC [J alone): take the sequence
    out of the string and use the console codes;
  - a cursor word that prints ESC [ row ; col H itself, such as
    [Y27'91'%#59'#72']: make it [Y`@], and take 1 from every row and
    column it is called with, since `@ counts from 0;
  - a random number word, such as [R r@75*74+:r! 256/;255& %M]: n`, gives a
    number from 0 to n-1 by itself, and a key wait stirs its seed, so the
    word, the seed variable and any loop that counts while it waits for a
    key can go. The numbers drawn will not be the ones drawn before.

Strings and comments are never changed, except the whole-string forms above.
A program that works addresses out inside its own text will need more care.
"""
import re
import sys

HEX = b'0123456789ABCDEFabcdef'
QUOTE, SLASH, GRAVE = 0x22, 0x2F, 0x60

# a printed string that is exactly one known sequence: what replaces it
WHOLE = {
    b'/[[2J/[[H': b'`^', b'/[[H/[[2J': b'`^', b'/[[H/[[J': b'`^',
    b'/[[K': b'`_', b'/[[0K': b'`_',
    b'/[[?25l': b'0`?', b'/[[?25h': b'1`?',
    b'/[[H': b'0 0`@', b'/[[1;1H': b'0 0`@',
}
AT = re.compile(rb'/\[\[(\d+);(\d+)H\Z')
INC = re.compile(rb'([a-z])@1([+-])(:?)\1!')
NEWLINE = re.compile(rb"(?<![0-9])13'10'")
CURSOR_WORD = re.compile(rb"27'91'%#59'#72'")
RANDOM_WORD = re.compile(rb'\[[A-Z][^\]]*75\*74\+[^\]]*\]')


def string_end(src, i):
    """src[i] is an opening quote: the index just past the closing quote."""
    j = i + 1
    while j < len(src) and src[j] != QUOTE:
        j += 2 if src[j] == SLASH else 1
    return j + 1


def code(seg, notes, line):
    """Rewrite a stretch of code that holds no string."""
    out = bytearray()
    i = 0
    while i < len(seg):
        c = seg[i]
        if c == GRAVE:
            nx = seg[i + 1] if i + 1 < len(seg) else 32
            out += b'`$' if nx in HEX else b'`!'
            i += 1
            continue
        out.append(c)
        i += 1
    seg = bytes(out)
    seg = INC.sub(lambda m: m.group(1) + b'`' + m.group(2) + (b'' if m.group(3) else b';'), seg)
    seg = NEWLINE.sub(b"`'", seg)
    if CURSOR_WORD.search(seg):
        notes.append((line, b'a cursor word: make it `@ and count rows and columns from 0'))
    if RANDOM_WORD.search(seg):
        notes.append((line, b'a random number word: n`, can replace it'))
    return seg


def convert(src):
    out = bytearray()
    notes = []
    i = 0
    while i < len(src):
        j = src.find(b'"', i)
        if j < 0:
            j = len(src)
        line = src.count(b'\n', 0, i) + 1
        out += code(src[i:j], notes, line)
        if j >= len(src):
            break
        k = string_end(src, j)
        body = src[j + 1:k - 1]
        line = src.count(b'\n', 0, j) + 1
        printed = src[k:k + 1] == b'$'
        m = AT.match(body)
        if printed and body in WHOLE:
            out += WHOLE[body]
            k += 1
        elif printed and m:
            out += b'%d %d`@' % (max(int(m.group(1)), 1) - 1, max(int(m.group(2)), 1) - 1)
            k += 1
        else:
            if b'/[[' in body and not src[k:].lstrip().startswith(b';'):
                notes.append((line, b'an escape sequence in a string: ' + src[j:k][:60]))
            out += src[j:k]
        i = k
    return bytes(out), notes


if __name__ == '__main__':
    args = sys.argv[1:]
    dry = '-n' in args
    for path in (a for a in args if a != '-n'):
        src = open(path, 'rb').read()
        new, notes = convert(src)
        print(f'{path}: {len(src)} -> {len(new)} bytes' + (' (not written)' if dry else ''))
        for line, text in notes:
            print(f'  line {line}: {text.decode("latin-1")}')
        if not dry and new != src:
            open(path, 'wb').write(new)
