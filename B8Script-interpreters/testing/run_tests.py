"""check(): run one build against the whole suite.

runner(prog, input, brk=None) runs a program on the build and returns
(output, how it ended). plat holds the build's own addresses for ref.py
(prog_at, let, linebuf, heaplim), so that what a checked build reports can be
compared exactly: a place, a heap limit, an address on the stack.
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
        g = open(os.path.join(os.path.dirname(__file__), 'games/TINYBAS.B8S'), 'rb').read()
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
        # Ctrl-C: a break is reported like an error. Its place and the stacks
        # are wherever the program was when the key was noticed
        out, ended = runner(b'1( 1)', b'', brk=0)
        if not re.fullmatch(rb'\r\nErr B @ 1,\d\r\n[^\r\n\0]{0,16}\r\nStk \d+:[ \-\d.]*\r\nRtn \d+\r\n', out) or ended != 'exit':
            fails += 1
            print(f'  FAIL e_break: got {out[-80:]!r} ended={ended}')
    print(f'{name}: {"PASS" if not fails else str(fails)+" FAILED"}')
    return fails
