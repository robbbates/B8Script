"""Test the Z80 builds that have the line editor (EDITOR = 1).

usage: test_editor.py DIR      (DIR holds the builds named *-ed and *-ed-chk, from
       VARIANTS=$'0 0 1\n0 1 1\n1 0 1\n1 1 1' ./build.sh Z80 ../z80/b8s-z80.asm DIR)

Each session is a list of steps, typed one after the other, each when the
editor is waiting:
    b'...'                  a line (Return is added)
    (b'...', b'keys')       a line, and the keys that the code it runs reads
    (b'-n', [(k, a, b)])    a list command; after k lines of it have been
                            printed key a is pressed, and then, unless a was
                            Ctrl-C, key b (None: no key, the list stays held)
The expected output comes from a small model of the editor here, with ref.py
running whatever a line runs. The CP/M builds read their lines with BDOS 10,
which echoes and edits in its own way; the model follows it.
"""
import sys, os, re, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_z80 import Run, symbols
from ref import Ref


def read_line(queue, cpm, out):
    """Take one typed line off the queue of keys; return what the line reader
    keeps. The echo goes to out."""
    typed = bytearray()
    while True:
        c = queue.pop(0)
        if c == 13:
            break
        if cpm:
            if c in (8, 127):
                if typed:
                    typed.pop(); out += b'\x08 \x08'
            elif c >= 32:
                typed.append(c); out.append(c)
                if len(typed) == 125:       # BDOS 10 ends a full line by itself
                    break
        elif c == 8:
            if typed:
                typed.pop(); out.append(8)
        elif len(typed) < 125:
            typed.append(c); out.append(c)
    if cpm:
        out.append(13)                      # BDOS 10 echoes the CR
    out += b'\r\n'
    return bytes(typed)


def model(steps, sy, cpm, file=b''):
    """Return (expected output, chunks to type, timed keys) for a session."""
    LET, LINEBUF, PROG = sy['LET'], sy['LINEBUF'], sy['PROG']
    text = file.split(b'\x1a')[0]
    if text and not text.endswith(b'\n'):
        text += b'\r\n'                         # the loader ends a last line that has no LF
    prog = [l + b'\n' for l in text.split(b'\n')[:-1]] + ([text.split(b'\n')[-1]] if text.split(b'\n')[-1] else [])
    out, cells = bytearray(), bytes(0x7C)   # (the tests only read cells they have set)
    chunks, timed = [], []
    for step in steps:
        keys, extra = step if isinstance(step, tuple) else (step, b'')
        more = extra if isinstance(extra, bytes) else b''
        events = list(extra) if isinstance(extra, list) else []
        chunks.append(keys + b'\r' + more)
        queue = list(keys + b'\r' + more)
        while queue:
            typed = read_line(queue, cpm, out)
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
                code = stored if digits else typed + b'\r\n'
                r = Ref(code, bytes(queue), prog_at=PROG if digits else LINEBUF, let=LET, linebuf=LINEBUF, cpm=cpm, filepad=False)
                r.m[PROG:PROG + len(stored) + 1] = stored + b'\0'
                r.m[LET:LET + 0x7C] = cells     # words and variables last from line to line
                r.w(r.heapcell, PROG + len(stored) + 1)
                out += r.run(2_000_000)
                cells = bytes(r.m[LET:LET + 0x7C])
                queue = list(r.inp)             # what the code did not read is typed at the editor
    return bytes(out), chunks, timed


def sessions(PROG):
    run = b' %d{]' % PROG                       # the old way to run: jump to the program
    return {

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
    'run, then use what the program defined': [b'1 "one"$', b'2 [W "w"$]', b'0', b' W' + run + b' W', b' W'],
    '300 lines': [b'0 %d#' % i for i in range(300)] + [b'-1', b'128 "at 128"$', b'100', b'-250', b'299', b'-290', b'0'],
    'a program that reads a line and a key': [
        b'1 -9? ,\' 0?\' "."$', (b'0', b'hello\rk'), b' 1#', (b'0', b'\rZ'), b'-1'],
    'hold the list and let it go': [b'0 %d#' % i for i in range(9)] + [
        (b'-1', [(3, 32, 32)]), (b'-1', [(0, 120, 13), (4, 32, 32), (5, 13, 120)]), b'-8'],
    'Ctrl-C ends the list': [b'0 %d#' % i for i in range(9)] + [
        (b'-1', [(4, 3, None)]), (b'-2', [(2, 32, 3)]), (b'-1', [(0, 3, None)]), b' 5#', b'-9'],
}


# CP/M builds only: the file named on the command line is loaded, and Ctrl-C
# as the first key of a line goes back to CP/M.
FILE = b'"one "$\r\n[W "w"$]\r\n2 3*#\r\n'
CPM_SESSIONS = {
    'a file is loaded, listed, run and added to': (FILE, [b'-1', b'0', b' W', b'2 "new "$', b'0 9#', b'-1', b'0']),
    'a file with no text': (b'', [b'-1', b'1 5#', b'-1', b'0']),
    'a file of exactly one record': ((b'1#' + b' ' * 61 + b'\r\n') * 2, [b'-1', b'0', b'0 2#', b'0']),
    'a file whose last line has no CR LF': (b'1#\r\n2#', [b'-1', b'0']),
}

# Checked builds only: the program is stopped, the report is printed, and the
# editor carries on. Each session is (steps, timed keys by count of characters
# printed, the patterns that must follow each other in the output).
def checked_sessions(sy):
    no = b" 88'88'"                             # prints XX: it must never be reached
    def rpt(code, line, col, stk=rb'[^\r]*', rtn=rb'\d+'):
        return rb'\r\nErr %s @ %s,%s\r\n[^\r\n]{0,16}\r\nStk %s\r\nRtn %s\r\n' % (code, line, col, stk, rtn)
    return {
        'data stack': ([b'1 1 2+ ;;' + no, b'0', b' 7#'], [], [rpt(b's', b'1', rb'\d+', b'0:', b'0') + rb' 7#\r+\n7$']),
        'return stack': ([b'1 [R R] R' + no, b'0', b' 7#'], [], [rpt(b'R', b'1', rb'\d+', b'0:') + rb' 7#\r+\n7$']),
        'bad [': ([b'1 [5 1]' + no, b'0', b' 7#'], [], [rb'0\r+\n' + rpt(b'W', b'1', b'2', b'0:', b'0') + rb' 7#\r+\n7$']),
        'store': ([b'1 1 0!' + no, b'0', b' 7#'], [], [rb'0\r+\n' + rpt(b'O', b'1', b'4', b'2: 1 0', b'0') + rb' 7#\r+\n7$']),
        'heap': ([b'1 -1_' + no, b'0', b' 7#'], [], [rb'0\r+\n' + rpt(b'H', b'1', b'3', b'1: -1', b'0') + rb' 7#\r+\n7$']),
        'an error in the second line': ([b'1 1 2', b'2 3 0/' + no, b'0', b' 7#'], [],
                                        [rb'0\r+\n' + rpt(b'Z', b'2', b'4', b'4: 1 2 3 0', b'0') + rb' 7#\r+\n7$']),
        'an undefined word': ([b'1 5 Q' + no, b'0', b' [Q 9#] Q'], [],
                              [rb'0\r+\n' + rpt(b'U', b'1', b'3', b'1: 5', b'0') + rb' \[Q 9#\] Q\r+\n9$']),
        'a typed line is line 0': ([b' 1 0!' + no, b' 7#'], [], [rb'\n' + rpt(b'O', b'0', b'5', b'2: 1 0', b'0') + rb' 7#\r+\n7$']),
        'variables start at 0': ([b' q@# j@#'], [], [rb'\n00$']),
        'Ctrl-C stops a program': ([b'1 1("."$ 1)' + no, b'0', b' 7#', b'-1'], [(40, 3)],
                                   [rb'\.{10,}' + rpt(b'B', b'1', rb'\d+') + rb' 7#\r+\n7-1\r+\n1 1\("\."\$ 1\) 88\'88\'\r\n$']),
        'the stacks are empty again after an error': (
            [b' 1 2 3 4 [R R] R', b' 5 6+#', b' 8#'], [], [rpt(b'R', b'0', rb'\d+', b'4: 1 2 3 4') + rb' 5 6\+#\r+\n11 8#\r+\n8$']),
    }


def check_editor(base, verbose=True):
    """Run every session against base.hex/.lst; return the number that failed."""
    sy = symbols(base + '.lst')
    name = os.path.basename(base)
    cpm, checked = '-cpm' in name, name.endswith('-chk')
    mode = 'cpm-editor' if cpm else 'editor'
    fails = 0

    def report(ok, title, r, got, exp=None):
        nonlocal fails
        fails += not ok
        if verbose or not ok:
            print(f'  {"ok  " if ok else "FAIL"} {title}')
        if ok:
            return
        if exp is None:
            print(f'     ended={r.ended}; got {got[-200:]!r}')
            return
        k = next((i for i in range(min(len(got), len(exp))) if got[i] != exp[i]), min(len(got), len(exp)))
        print(f'     ended={r.ended}; first difference at byte {k} of {len(got)}/{len(exp)}')
        print(f'     got {got[max(0, k - 40):k + 60]!r}')
        print(f'     exp {exp[max(0, k - 40):k + 60]!r}')

    todo = [(t, b'', st) for t, st in sessions(sy['PROG']).items()]
    if cpm:
        todo += [(t, f, st) for t, (f, st) in CPM_SESSIONS.items()]
    for title, file, steps in todo:
        exp, chunks, timed = model(steps, sy, cpm, file)
        r = Run(base + '.hex', base + '.lst', file, chunks, cpu='z80', mode=mode, timed=timed)
        got = r.run()
        report(got == exp and r.ended == 'needkey' and not r.stages and not r.timed, title, r, got, exp)
    if cpm:
        r = Run(base + '.hex', base + '.lst', b'', [b'1 5#\r', b'\x03', b' 6#\r'], cpu='z80', mode=mode)
        got = r.run()
        report(r.ended == 'exit' and r.stages == [b' 6#\r'], 'Ctrl-C at the start of a line leaves', r, got)
    if checked:
        for title, (steps, timed, pats) in checked_sessions(sy).items():
            r = Run(base + '.hex', base + '.lst', b'', [s + b'\r' for s in steps], cpu='z80', mode=mode, timed=timed)
            got = r.run()
            at, ok = 0, r.ended == 'needkey' and b'XX' not in got
            for p in pats:
                m = re.compile(p).search(got, at)
                ok, at = ok and bool(m), m.end() if m else at
            report(ok, 'checked: ' + title, r, got)
    print(f'{name}:', 'PASS' if not fails else f'{fails} FAILED')
    return fails


if __name__ == '__main__':
    builds = sorted(f[:-4] for f in glob.glob(os.path.join(sys.argv[1], '*.hex'))
                    if re.search(r'-ed(-chk)?\.hex$', f))
    sys.exit(1 if sum(check_editor(b, '-v' in sys.argv) for b in builds) else 0)
