"""Strip a B8Script program of its comments and white space.

usage: b8strip.py SRC [OUT]        write the stripped program to OUT (or print it)
       b8strip.py --same A B       check that A and B hold the same code: equal
                                   once both are stripped (exit 1 if not)

A comment is a string dropped at once: '"text";', with white space allowed
between the closing quote and the ';'. It pushes an address and drops it, so
it does nothing, and taking it out changes nothing (unless a program works
out addresses inside its own text, which none of the games does).

White space is space, the other control characters and DEL. All of it goes,
except one space wherever taking it out would join two things into something
else. Only four characters look at the character after them, and digits
join into numbers, so a space is kept:
  - between two digits: '12 34' is two numbers, '1234' one;
  - after a '-' with a digit next: '5- 3' subtracts 3, '5-3' pushes 5 and -3;
  - after a '[' : '[ ' is an anonymous block, and '[' before a letter would
    define that letter;
  - after a grave with a hex character next: '` b' executes, '`b' would load
    hex; and after a hex load, before a hex character, which it would load.
A comment taken out counts as white space, so '5"c";3' becomes '5 3'.

Strings are kept exactly as they are, '/' escapes and all.
"""
import sys

HEX = b'0123456789ABCDEFabcdef'
DIG = b'0123456789'
QUOTE, SEMI, MINUS, OPEN, GRAVE, SLASH = 0x22, 0x3B, 0x2D, 0x5B, 0x60, 0x2F


def blank(c):
    return c <= 32 or c == 127


def string_end(src, i):
    """src[i] is an opening quote: the index just past the closing quote."""
    j = i + 1
    while j < len(src) and src[j] != QUOTE:
        j += 2 if src[j] == SLASH else 1
    return j + 1


def strip(src):
    out = bytearray()
    gap = False            # white space or a comment since the last character kept
    inhex = False          # the last characters kept were a hex load
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if blank(c):
            gap = True
            i += 1
            continue
        if c == QUOTE:
            j = string_end(src, i)
            k = j
            while k < n and blank(src[k]):
                k += 1
            if k < n and src[k] == SEMI:           # a comment: drop it and its ';'
                gap = True
                i = k + 1
                continue
        if gap and out:
            p = out[-1]
            if ((p in DIG and c in DIG) or (p == MINUS and c in DIG) or p == OPEN
                    or (p == GRAVE and c in HEX) or (inhex and c in HEX)):
                out.append(32)
        gap = False
        if c == QUOTE:
            out += src[i:j]
            inhex = False
            i = j
            continue
        # a hex load is a grave followed at once by a hex character, and runs
        # on while the characters that follow at once are hex
        p = out[-1] if out else 32
        inhex = c in HEX and (p == GRAVE or (inhex and p != 32))
        out.append(c)
        i += 1
    return bytes(out)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == '--same':
        x, y = (strip(open(f, 'rb').read()) for f in a[1:3])
        if x == y:
            print(f'same code: {a[1]} and {a[2]} ({len(x)} bytes stripped)')
            sys.exit(0)
        d = next((k for k in range(min(len(x), len(y))) if x[k] != y[k]), min(len(x), len(y)))
        print(f'DIFFERENT CODE at stripped byte {d}:\n  {a[1]}: {x[max(0, d-30):d+30]!r}\n  {a[2]}: {y[max(0, d-30):d+30]!r}')
        sys.exit(1)
    s = strip(open(a[0], 'rb').read())
    if len(a) > 1:
        open(a[1], 'wb').write(s)
    else:
        sys.stdout.buffer.write(s)
