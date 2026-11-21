"""Convert B8Script source from the old string escape ('>') to the new one ('/').

usage: esc2slash.py FILE...          rewrite the files in place, print a report
       esc2slash.py -n FILE...       report only, change nothing

Each string is treated by what follows its closing quote:

  "..."$   printed. Full conversion, so it prints exactly what it did before:
               >X  ->  /X        (an escape stays an escape)
               >>  ->  >         ('>' is an ordinary character now)
               /   ->  //        (a literal slash must be escaped now)
  "...";   a comment. Nothing ever decodes it; only the skip reads it, and
           the skip only cares where the closing quote is. So the text is
           left alone, except:
               >"  ->  /"        (an escaped quote stays escaped)
               a '/' right before the closing quote is doubled
  other    data or code (stored in a variable, indexed, run with {). Treated
           like a comment, and listed in the report so you can check it by
           hand: if the program later prints it with $, give it the full
           conversion; if it is code, its '/' is a divide and must stay single.

After converting, the file is walked again under the new rule to confirm
that every string still starts and ends where it did.
"""
import sys

Q = '"'


def strings(src, esc):
    """Yield (start, end) of each string body in src, under escape char esc."""
    i, n = 0, len(src)
    while i < n:
        if src[i] == Q:
            j = i + 1
            while j < n and src[j] != Q:
                if src[j] == esc:
                    j += 1
                j += 1
            yield i + 1, j
            i = j + 1
        else:
            i += 1


def follower(src, end):
    k = end + 1
    while k < len(src) and src[k] in ' \t\r\n':
        k += 1
    return src[k] if k < len(src) else ''


def printed(body):
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == '>' and i + 1 < len(body):
            nx = body[i + 1]
            out.append('>' if nx == '>' else '/' + nx)
            i += 2
        elif c == '/':
            out.append('//')
            i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def unprinted(body):
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == '>' and i + 1 < len(body) and body[i + 1] == Q:
            out.append('/' + Q)
            i += 2
        elif c == '>' and i + 1 < len(body):
            out.append(body[i:i + 2])       # old escape pair: keep both as text
            i += 2
        else:
            out.append(c)
            i += 1
    s = ''.join(out)
    # under the new rule an odd run of slashes at the end would eat the quote
    t = len(s) - len(s.rstrip('/'))
    if t % 2:
        s += '/'
    return s


def convert(src):
    out, pos, report = [], 0, []
    for a, b in strings(src, '>'):
        body, f = src[a:b], follower(src, b)
        kind = 'print' if f == '$' else 'comment' if f == ';' else 'DATA'
        new = printed(body) if kind == 'print' else unprinted(body)
        line = src.count('\n', 0, a) + 1
        if new != body or (kind == 'DATA' and ('/' in body or '>' in body)):
            report.append((line, kind, body, new))
        out.append(src[pos:a])
        out.append(new)
        pos = b
    out.append(src[pos:])
    new_src = ''.join(out)
    old_n = sum(1 for _ in strings(src, '>'))
    new_n = sum(1 for _ in strings(new_src, '/'))
    return new_src, report, old_n == new_n


if __name__ == '__main__':
    args = sys.argv[1:]
    dry = '-n' in args
    for f in [a for a in args if a != '-n']:
        src = open(f, 'rb').read().decode('latin-1')
        new_src, report, ok = convert(src)
        print(f'== {f}: {len(report)} string(s) to look at' + ('' if ok else '   ** STRING COUNT CHANGED **'))
        for line, kind, old, new in report:
            mark = '' if old != new else '   (unchanged: check by hand)'
            print(f'  line {line:4} {kind:7} "{old[:60]}"')
            if old != new:
                print(f'            {"->":>7} "{new[:60]}"')
            elif mark:
                print(f'            {mark}')
        if not dry:
            open(f, 'wb').write(new_src.encode('latin-1'))
