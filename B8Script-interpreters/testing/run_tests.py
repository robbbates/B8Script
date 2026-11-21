import sys, os, re
sys.path.insert(0, os.path.dirname(__file__))
from ref import Ref
from tests import SUITE, MC, ERRS, LOOSE

def expected(prog, inp, cpm, retbyte):
    return Ref(prog, inp, cpm=cpm, retbyte=retbyte).run(50_000_000)

def check(runner, name, cpu, cpm, checked, retbyte, games=True, verbose=False):
    fails = 0
    cases = list(SUITE) + [(n, p, i) for n, p, i, _ in MC.get(cpu, [])]
    if not checked:
        cases += LOOSE
    for n, p, i in cases:
        exp = dict((k, e) for k, _, _, e in MC.get(cpu, [])).get(n) or expected(p, i, cpm, retbyte)
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
        exp = Ref(g, inp).run(200_000_000)
        out, ended = runner(g, inp)
        # Tiny BASIC reads its own lines with 0?, so CP/M output matches too
        if out != exp:
            fails += 1
            print(f'  FAIL tinybasic: ended={ended}\n    got {out[-300:]!r}\n    exp {exp[-300:]!r}')
    if checked:
        for n, p, code, at in ERRS:
            out, ended = runner(p, b'')
            # (after a wrecked return stack the place is garbage, and the 6502
            # prints it signed, so a minus sign is allowed)
            m = re.search(rb'(.) @ (-?\d+)$', out)
            if (not m or m.group(1) != code or b'no' in out or ended != 'exit'
                    or (at is not None and int(m.group(2)) != at)):
                fails += 1
                print(f'  FAIL {n}: got {out[-80:]!r} ended={ended}')
            elif verbose:
                print('  ok', n, out[-12:])
        out, ended = runner(b'1( 1)', b'', brk=0)
        if not re.search(rb'^B @ \d+$', out):
            fails += 1
            print(f'  FAIL e_break: got {out[-80:]!r} ended={ended}')
    print(f'{name}: {"PASS" if not fails else str(fails)+" FAILED"}')
    return fails
