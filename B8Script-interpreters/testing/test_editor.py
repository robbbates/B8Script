"""Test the Z80 build that has the line editor (EDITOR = 1).

usage: test_editor.py DIR      (DIR holds b8s-z80-ed.hex and .lst, from
                                VARIANTS='0 0 0 1' ./build.sh Z80 ../z80/b8s-z80.asm DIR)

Each session is a list of steps, typed one after the other, each when the
editor is waiting:
    b'...'                  a line (Return is added)
    (b'...', b'keys')       a line, and the keys that the code it runs reads
    (b'-n', [(k, a, b)])    a list command; after k lines of it have been
                            printed key a is pressed, and then, unless a was
                            Ctrl-C, key b (None: no key, the list stays held)
The expected output comes from a small model of the editor here, with ref.py
running whatever a line runs.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_z80 import Run
from ref import Ref

LET, LINEBUF, PROG = 0x8200, 0x8280, 0x8300


def model(steps):
    """Return (expected output, chunks to type, timed keys) for a session."""
    prog, out, cells = [], bytearray(), bytes(0x7C)     # (the tests only read cells they have set)
    chunks, timed = [], []
    for step in steps:
        keys, extra = step if isinstance(step, tuple) else (step, b'')
        more = extra if isinstance(extra, bytes) else b''
        events = list(extra) if isinstance(extra, list) else []
        chunks.append(keys + b'\r' + more)
        typed = bytearray()                 # what the line reader keeps
        for c in keys:
            if c == 8:
                if typed:
                    typed.pop(); out.append(8)
            elif len(typed) < 125:
                typed.append(c); out.append(c)
        typed = bytes(typed)
        out += b'\r\n'
        minus = typed[:1] == b'-'
        digits = 1 if minus else 0
        while digits < len(typed) and typed[digits:digits + 1].isdigit():
            digits += 1
        n = int(typed[minus:digits] or b'0') & 0xFFFF
        if minus:                           # list from line n
            done = 0
            for i in range(n - 1 if n else len(prog), len(prog)):
                if events and events[0][0] == done:
                    _, a, b = events.pop(0)
                    timed.append((len(out), a))
                    if a == 3:
                        break
                    if b is None:           # held for good
                        break
                    chunks.append(bytes([b]))
                    if b == 3:
                        break
                out += b'%d ' % (i + 1) + prog[i]
                done += 1
            assert not events, 'a key was set for a line the list never reached'
        elif digits and typed[digits:]:     # put a line in; the character after the number is not stored
            prog.insert(min(n - 1, len(prog)) if n else len(prog), typed[digits + 1:] + b'\r\n')
        elif digits and n:                  # take a line out
            del prog[n - 1:n]
        else:                               # run the program (0) or the line
            stored = b''.join(prog)
            text = stored if digits else typed + b'\r\n'
            r = Ref(text, more, prog_at=PROG if digits else LINEBUF, let=LET, linebuf=LINEBUF)
            r.m[PROG:PROG + len(stored) + 1] = stored + b'\0'
            r.m[LET:LET + 0x7C] = cells     # words and variables last from line to line
            r.w(r.heapcell, PROG + len(stored) + 1)
            out += r.run(2_000_000)
            cells = bytes(r.m[LET:LET + 0x7C])
    return bytes(out), chunks, timed


SESSIONS = {
    'enter, list, run': [b'1 "Hi"$', b'2 2 3+#', b'-1', b'0'],
    'direct mode': [b' 7 6*#', b'"x"$ 1 2+#', b' [S:*] 9S#', b' -5 3*#'],
    'insert in the middle and at the ends': [
        b'1 "b"$', b'1 "a"$', b'9 "d"$', b'3 "c"$', b'-1', b'0'],
    'delete': [b'1 1#', b'2 2#', b'3 3#', b'4 4#', b'-1', b'2', b'-1', b'1', b'-1', b'9', b'2', b'-1',
               b'0', b'1', b'-1', b'1', b'-1', b'1', b'0'],
    'append with 0, list an empty program': [b'-1', b'0 5#', b'0 6#', b'-1', b'0'],
    'list from a line': [b'0 %d#' % i for i in range(1, 13)] + [
        b'-5', b'-12', b'-13', b'-0', b'-', b'-65535', b'-65536', b'-65541', b'-2x', b'0'],
    'a program with words, a loop and the heap': [
        b'1 [F :1>( :1-F* 0)]', b'2 1i! 1( i@F# 32\' i@1+:i! 8<)',
        b'3 4_x! 258x@! x@,# x@1+,#', b'-1', b'0', b'0'],
    'long lines and many of them': (
        [b'%d %s' % (i + 1, b'"' + bytes([65 + i % 26]) * 100 + b'"$') for i in range(20)]
        + [b'5', b'5', b'7 "new"$', b'-1', b'0']),
    'lines of every length, put in at every place': (
        [b'%d %s' % (1 + i * 7 % (i + 1), b'"' + b'%d' % i + b'.' * (i * 5 % 110) + b'"$') for i in range(40)]
        + [b'-1', b'0', b'3', b'30', b'1', b'-1', b'0']),
    'a line of the full 125 characters': [b'1 ' + b'x' * 140, b'-1', b'2 "' + b'y' * 119 + b'"$', b'-1'],
    'the character after the line number': [
        b'1 5#', b'2 7 8+#', b'3x9#', b'2 ', b'-1', b'0', b'2', b'-1', b'1  1#', b'-1'],
    'Backspace while typing': [b'\x08\x081 "abX\x08c"$', b'2 9#\x08\x08\x08\x08\x08\x08\x08 5 5*#', b'-1', b'0'],
    'run, then use what the program defined': [b'1 "one"$', b'2 [W "w"$]', b'0', b' W 33536{] W', b' W'],
    '300 lines': [b'0 %d#' % i for i in range(300)] + [b'-1', b'128 "at 128"$', b'100', b'-250', b'299', b'-290', b'0'],
    'a program that reads a line and a key': [
        b'1 -9? ,\' 0?\' "."$', (b'0', b'hello\rk'), b' 1#', (b' 33536{] 2#', b'\rZ'), b'-1'],
    'hold the list and let it go': [b'0 %d#' % i for i in range(9)] + [
        (b'-1', [(3, 32, 32)]), (b'-1', [(0, 120, 13), (4, 32, 32), (5, 13, 120)]), b'-8'],
    'Ctrl-C ends the list': [b'0 %d#' % i for i in range(9)] + [
        (b'-1', [(4, 3, None)]), (b'-2', [(2, 32, 3)]), (b'-1', [(0, 3, None)]), b' 5#', b'-9'],
}


def check_editor(base, verbose=True):
    """Run every session against base.hex/.lst; return the number that failed."""
    fails = 0
    for name, steps in SESSIONS.items():
        exp, chunks, timed = model(steps)
        r = Run(base + '.hex', base + '.lst', b'', chunks, cpu='z80', mode='editor', timed=timed)
        got = r.run()
        ok = got == exp and r.ended == 'needkey' and not r.stages and not r.timed
        fails += not ok
        if verbose or not ok:
            print(f'  {"ok  " if ok else "FAIL"} {name}')
        if not ok:
            k = next((i for i in range(min(len(got), len(exp))) if got[i] != exp[i]), min(len(got), len(exp)))
            print(f'     ended={r.ended}; first difference at byte {k} of {len(got)}/{len(exp)}')
            print(f'     got {got[max(0, k - 40):k + 60]!r}')
            print(f'     exp {exp[max(0, k - 40):k + 60]!r}')
    print(f'{os.path.basename(base)}:', 'PASS' if not fails else f'{fails} FAILED')
    return fails


if __name__ == '__main__':
    sys.exit(1 if check_editor(os.path.join(sys.argv[1], 'b8s-z80-ed')) else 0)
