"""Convert B8Script source from the old divide ( a b -- q r ) to the new one
( a b -- r q ), where the quotient is on top.

usage: divswap.py FILE...        rewrite the files in place, print a report
       divswap.py -n FILE...     report only, change nothing

Outside strings, every '/' becomes '/%' (divide, then swap: the old order),
and a '/%%' that this makes is cancelled to '/'. So:

    /;    (old: quotient)   ->  /%;
    /%;   (old: remainder)  ->  /;
    /     (both results)    ->  /%

The program then behaves exactly as before. Strings are left alone; any
string that is not printed or a comment and holds a '/' is listed, because
if it is code (run with {) its divides need the same change by hand.
"""
import re, sys

Q, ESC = '"', '/'


def pieces(src):
    """Yield (is_string, text, follower) for alternating code and string runs."""
    i, n, start = 0, len(src), 0
    while i < n:
        if src[i] == Q:
            j = i + 1
            while j < n and src[j] != Q:
                if src[j] == ESC:
                    j += 1
                j += 1
            k = j + 1
            while k < n and src[k] in ' \t\r\n':
                k += 1
            yield False, src[start:i], ''
            yield True, src[i:j + 1], src[k] if k < n else ''
            i = start = j + 1
        else:
            i += 1
    yield False, src[start:], ''


def convert(src):
    out, report, sites, line = [], [], 0, 1
    for is_str, text, f in pieces(src):
        if is_str:
            if f not in '$;' and '/' in text:
                report.append((line, text))
        else:
            sites += text.count('/')
            text = text.replace('/', '/%')
            text = re.sub(r'/%(\s*)%', r'/\1', text)
        out.append(text)
        line += text.count('\n')
    return ''.join(out), report, sites


if __name__ == '__main__':
    args = sys.argv[1:]
    dry = '-n' in args
    for f in [a for a in args if a != '-n']:
        src = open(f, 'rb').read().decode('latin-1')
        new, report, sites = convert(src)
        print(f'== {f}: {sites} divide(s) converted')
        for line, text in report:
            print(f'  line {line:4} data string with a slash, check by hand: {text[:60]}')
        if not dry:
            open(f, 'wb').write(new.encode('latin-1'))
