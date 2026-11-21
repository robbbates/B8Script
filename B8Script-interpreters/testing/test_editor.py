"""Test the Z80 build that has the line editor (EDITOR = 1).

usage: test_editor.py DIR      (DIR holds b8s-z80-ed.hex and .lst, from
                                VARIANTS='0 0 0 1' ./build.sh Z80 ../z80/b8s-z80.asm DIR)

Each session is a list of typed lines; an entry can also be a pair (line, keys
that the code it runs will read). The expected output comes from a small model
of the editor here, with ref.py running whatever a line runs.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_z80 import Run
from ref import Ref

LET, LINEBUF, PROG = 0x8200, 0x8280, 0x8300


def model(lines):
    """What the editor should print for these typed lines."""
    prog, out, cells = [], bytearray(), bytes(0x7C)    # (the test only reads cells it has set)
    for keys in lines:
        keys, more = keys if isinstance(keys, tuple) else (keys, b'')
        typed = bytearray()                 # what the line reader keeps
        for c in keys:
            if c == 8:
                if typed:
                    typed.pop(); out.append(8)
            elif len(typed) < 125:
                typed.append(c); out.append(c)
        typed = bytes(typed)
        out += b'\r\n'
        digits = 0
        while digits < len(typed) and typed[digits:digits + 1].isdigit():
            digits += 1
        if digits == 0:                     # run it
            text = typed + b'\r\n'
            stored = b''.join(prog)
            r = Ref(text, more, prog_at=LINEBUF, let=LET, linebuf=LINEBUF)
            r.m[PROG:PROG + len(stored) + 1] = stored + b'\0'
            r.m[LET:LET + 0x7C] = cells         # words and variables last from line to line
            r.w(r.heapcell, PROG + len(stored) + 1)
            out += r.run(2_000_000)
            cells = bytes(r.m[LET:LET + 0x7C])
            continue
        n = int(typed[:digits]) & 0xFF
        rest = typed[digits:]
        if n == 0:
            for ln in prog[:128]:
                out += ln
            at = len(prog)
        else:
            at = min(n - 1, len(prog))
        if rest:
            prog.insert(at, rest + b'\r\n')
        elif at < len(prog):
            del prog[at]
    return bytes(out)


SESSIONS = {
    'enter, list, run': [b'1 "Hi"$', b'2 2 3+#', b'0', b' 33536{]'],
    'direct mode': [b' 7 6*#', b'"x"$ 1 2+#', b' [S:*] 9S#'],
    'insert in the middle and at the ends': [
        b'1 "b"$', b'1 "a"$', b'9 "d"$', b'3 "c"$', b'0', b' 33536{]'],
    'delete': [b'1 1#', b'2 2#', b'3 3#', b'4 4#', b'0', b'2', b'0', b'1', b'0', b'9', b'2', b'0',
               b' 33536{]', b'1', b'0', b'1', b'0'],
    'append with 0, list an empty program': [b'0', b'0 5#', b'0 6#', b'0', b' 33536{]'],
    'a program with words, a loop and the heap': [
        b'1 [F :1>( :1-F* 0)]', b'2 1i! 1( i@F# 32\' i@1+:i! 8<)',
        b'3 4_x! 258x@! x@,# x@1+,#', b'0', b' 33536{]', b' 33536{]'],
    'long lines and many of them': (
        [b'%d %s' % (i + 1, b'"' + bytes([65 + i % 26]) * 100 + b'"$') for i in range(20)]
        + [b'5', b'5', b'7 "new"$', b'0', b' 33536{]']),
    'a line of the full 125 characters': [b'1 ' + b'x' * 140, b'0'],
    'Backspace while typing': [b'\x08\x081 "abX\x08c"$', b'2 9#\x08\x08\x08\x08\x08\x08\x08 5 5*#', b'0', b' 33536{]'],
    'run, then use what the program defined': [b'1 "one"$', b'2 [W "w"$]', b' 33536{]', b' W 33536{] W', b' W'],
    '140 lines: the list shows the first 128': (
        [b'0 %d#' % i for i in range(140)] + [b'0', b'128 "at 128"$', b'100', b'0']),
    'a program that reads a line and a key': [
        b'1 -9? ,\' 0?\' "."$', (b' 33536{]', b'hello\rk'), b' 1#', (b' 33536{] 2#', b'\rZ'), b'0'],
}


def check_editor(base, verbose=True):
    """Run every session against base.hex/.lst; return the number that failed."""
    fails = 0
    for name, lines in SESSIONS.items():
        inp = b''.join(ln + b'\r' if isinstance(ln, bytes) else ln[0] + b'\r' + ln[1] for ln in lines)
        r = Run(base + '.hex', base + '.lst', b'', inp, cpu='z80', mode='editor')
        got = r.run()
        exp = model(lines)
        ok = got == exp and r.ended == 'needkey'
        fails += not ok
        if verbose or not ok:
            print(f'  {"ok  " if ok else "FAIL"} {name}')
        if not ok:
            k = next((i for i in range(min(len(got), len(exp))) if got[i] != exp[i]), min(len(got), len(exp)))
            print(f'     ended={r.ended}; first difference at byte {k}')
            print(f'     got {got[max(0, k - 40):k + 60]!r}')
            print(f'     exp {exp[max(0, k - 40):k + 60]!r}')
    print(f'{os.path.basename(base)}:', 'PASS' if not fails else f'{fails} FAILED')
    return fails


if __name__ == '__main__':
    sys.exit(1 if check_editor(os.path.join(sys.argv[1], 'b8s-z80-ed')) else 0)
