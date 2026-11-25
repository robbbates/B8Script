"""check(): run one build against the whole suite.

runner(prog, input, timed=None) runs a program on the build and returns
(output, how it ended). The input is typed as a person types: a key is given
only when the program is waiting for one. timed is a list of (n, keys): those
keys are pressed, whatever the program is doing, once it has printed n
characters. If the runner keeps its last harness in runner.last, the number
of times the keyboard was looked at (its .looks) is checked too.
plat holds the build's own addresses for ref.py (prog_at, let, linebuf,
heaplim), so that what a checked build reports can be compared exactly: a
place, a heap limit, an address on the stack.
"""
import sys, os, re
sys.path.insert(0, os.path.dirname(__file__))
from ref import Ref
from tests import SUITE, MC, ERRS, LOOSE, CHK

def expected(prog, inp, cpm, retbyte, plat, checked=False):
    return Ref(prog, inp, cpm=cpm, retbyte=retbyte, checked=checked, **plat).run(50_000_000)

def check(runner, name, cpu, cpm, checked, retbyte, games=True, verbose=False, plat=None):
    fails = 0
    plat = plat or {}
    cases = list(SUITE) + [(n, p, i) for n, p, i, _ in MC.get(cpu, [])]
    cases += CHK if checked else LOOSE
    for n, p, i in cases:
        exp = dict((k, e) for k, _, _, e in MC.get(cpu, [])).get(n) or expected(p, i, cpm, retbyte, plat, checked and (n, p, i) in CHK)
        out, ended = runner(p, i)
        if out != exp:
            fails += 1
            print(f'  FAIL {n}: ended={ended}\n    got {out[:200]!r}\n    exp {exp[:200]!r}')
        elif verbose:
            print('  ok', n)
    if games:
        g = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'programs', 'TINYBAS.B8S'), 'rb').read()
        inp = (b'10 FOR I=1 TO 5\r20 PRINT I*I;" ";\r30 NEXT I\r40 PRINT\r50 IF 3>2 THEN PRINT "YES"\r'
               b'60 GOSUB 100\r70 END\r100 PRINT "SUB",RND(1),ABS(-7)\r110 RETURN\rLIST\rRUN\r'
               b'200 LET A=7*(3+4)/2\r210 PRINT A,A-50,-A\rRUN 200\rBYE\r')
        exp = Ref(g, inp, **plat).run(200_000_000)
        out, ended = runner(g, inp)
        # Tiny BASIC reads its own lines with 0?, so CP/M output matches too
        if out != exp:
            fails += 1
            print(f'  FAIL tinybasic: ended={ended}\n    got {out[-300:]!r}\n    exp {exp[-300:]!r}')
    if checked:
        for n, p, i, pat in ERRS:
            out, ended = runner(p, i)
            if pat is None:
                exp = expected(p, i, cpm, retbyte, plat, True)
                ok = out == exp
            else:
                exp = pat
                ok = re.fullmatch(pat, out, re.S) is not None
            if not ok or ended != 'exit':
                fails += 1
                print(f'  FAIL {n}: ended={ended}\n    got {out[-200:]!r}\n    exp {exp[-200:]!r}')
            elif verbose:
                print('  ok', n, out[-40:])
    fails += check_break(runner, checked, plat.get('let', 0x8000) + 0x7B, verbose)
    print(f'{name}: {"PASS" if not fails else str(fails)+" FAILED"}')
    return fails


# The break key (every build). A report for B: its place and the stacks are
# wherever the program was when the key was noticed.
BRPT = rb'\r\nErr B @ \d+,\d+\r\nD:\d+:[ \-\d.]*\r\nR:\d+\r\n'
LOOP = b'0i! 1( i@1+:i! 3000<) '       # busy for 3000 loop-backs: a dozen looks at the keyboard
GOTO = b'[G};{] [L}:{] L x! x@:G'      # an endless loop made of word calls only
CC = b'\x03'

def break_tests(off):
    """(name, program, input, timed keys, output). An output of None means
    the program is stopped: an unchecked build prints nothing and ends, a
    checked one reports B. off is the address of the break-off cell."""
    on = b'1 %d. ' % off                # turn the break key off
    return [
        # Ctrl-C stops a loop, a chain of word calls, and a program waiting for a key
        ('b_loop', b'1( 1)', b'', [(0, CC)], None),
        ('b_calls', GOTO, b'', [(0, CC)], None),
        ('b_wait', b'0?# "no"$', b'', [(0, CC)], None),
        ('b_wait2', b'30000?# "no"$', b'', [(0, CC)], None),
        ('b_line', b'-9?# "no"$', b'ab', [(2, CC)], None),
        # any other key is held for the next ?, the newest wins, and ? takes it first
        ('b_held', LOOP + b'0?#', b'', [(0, b'A')], b'65'),
        ('b_newest', LOOP + b'0?# 1?#', b'', [(0, b'AB')], b'660'),
        ('b_first', LOOP + b'"x"$ 0?# 0?#', b'', [(0, b'A'), (1, b'B')], b'x6566'),
        ('b_typed', LOOP + b'0?# 0?#', b'CD', [], b'6768'),
        # the break-off cell: Ctrl-C is a key like any other ...
        ('b_off', on + LOOP + b'0?#', b'', [(0, CC)], b'3'),
        ('b_offread', on + b'0?# 0?#', b'', [(0, CC + b'A')], b'365'),
        ('b_offnewest', on + LOOP + b'0?# 1?#', b'', [(0, CC + b'A')], b'650'),
        ('b_offslow', on + b'0?# "x"$ 0?#', b'', [(0, CC), (2, CC)], b'3x3'),
        # ... but two of them in quick succession still stop the program
        ('b_offtwice', on + b'1( 1)', b'', [(0, CC + CC)], None),
        ('b_offtwice2', on + b'0?# "no"$', b'', [(0, CC + CC)], None),
        # and the program can turn the break key on again
        ('b_onagain', on + b'0 %d. 1( 1)' % off, b'', [(0, CC)], None),
    ]

def check_break(runner, checked, off, verbose=False):
    fails = 0
    for n, p, i, timed, exp in break_tests(off):
        out, ended = runner(p, i, timed=timed)
        if exp is not None:
            ok = out == exp
        elif checked:
            ok = re.fullmatch(BRPT if n != 'b_line' else b'ab' + BRPT, out, re.S) is not None
        else:
            ok = out == (b'ab' if n == 'b_line' else b'')
        if not ok or ended != 'exit':
            fails += 1
            print(f'  FAIL {n}: ended={ended}\n    got {out[-120:]!r}\n    exp {exp!r}')
        elif verbose:
            print('  ok', n)
    # the keyboard is looked at once in 256 loop-backs or word calls, not every time
    last = getattr(runner, 'last', None)
    if last is not None:
        for n, p in (('b_rate', LOOP), ('b_rate2', b'[W] ' + LOOP.replace(b':i!', b':i! W'))):
            out, ended = runner(p, b'')
            looks = runner.last.looks
            if looks > 30 or ended != 'exit':
                fails += 1
                print(f'  FAIL {n}: the keyboard was looked at {looks} times in 3000 loop-backs; ended={ended}')
            elif verbose:
                print('  ok', n, looks)
    return fails
