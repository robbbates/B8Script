"""Tests for the web player's interpreter, web/b8s.js, run under Node (web_run.js).

usage: test_web.py [-v]

b8s.js follows ref.py step for step, so every run must print exactly what
ref.py prints, byte for byte, and stop with the same error (if any):
  - the suite (SUITE, LOOSE and CHK), unchecked and checked, and ERRS;
  - Tiny BASIC's session from run_tests.py;
  - the programs' runs from test_programs.py (PI to 250 digits among them);
  - the scripted games of test_games.py (both versions) and test_tweets.py;
  - every game and program, briefly, with gamecheck.py's keys.
It also checks that web/b8script.html was built from the sources as they are (web/build.py).
The page itself (the screen, the keys) is checked by test_page.js."""
import sys, os, json, base64, subprocess, glob
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from ref import Ref
from tests import SUITE, LOOSE, CHK, ERRS
import test_games, test_tweets, test_programs

ROOT = os.path.normpath(os.path.join(here, '..', '..'))
verbose = '-v' in sys.argv
node = subprocess.Popen(['node', os.path.join(here, 'web_run.js')], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, text=True)


def js(prog, inp, checked=False, play=False, steps=5_000_000):
    q = dict(prog=base64.b64encode(prog).decode(), inp=base64.b64encode(inp).decode(),
             checked=checked, play=play, steps=steps)
    node.stdin.write(json.dumps(q) + '\n')
    node.stdin.flush()
    a = json.loads(node.stdout.readline())
    return base64.b64decode(a['out']), a['error']


bad = 0
count = 0


def same(name, prog, inp, checked=False, play=False, steps=5_000_000, ref=None):
    """ref is the reference run's class (Ref, or a Play of test_games/test_tweets)."""
    global bad, count
    r = (ref or Ref)(prog, inp, checked=checked)
    exp = r.run(steps)
    got, err = js(prog, inp, checked, play, steps)
    ok = got == exp and err == r.error
    count += 1
    bad += not ok
    if not ok:
        d = next((i for i in range(min(len(got), len(exp))) if got[i] != exp[i]), min(len(got), len(exp)))
        print(f'FAIL  {name}: error {err} (ref {r.error}); differs at byte {d} of {len(exp)}\n'
              f'      got {got[max(0, d - 40):d + 40]!r}\n      exp {exp[max(0, d - 40):d + 40]!r}')
    elif verbose:
        print(f'ok    {name}')


def section(what):
    print(f'{what}: {count - section.start} runs')
    section.start = count


section.start = 0
for n, p, i in SUITE + LOOSE:
    same(n, p, i)
for n, p, i in SUITE + CHK:
    same(n + ' (checked)', p, i, checked=True)
for n, p, i, _ in ERRS:
    same(n, p, i, checked=True)
section('the suite')

tb = open(os.path.join(ROOT, 'programs', 'TINYBAS.B8S'), 'rb').read()
same('tinybasic', tb, b'10 FOR I=1 TO 5\r20 PRINT I*I;" ";\r30 NEXT I\r40 PRINT\r50 IF 3>2 THEN PRINT "YES"\r'
     b'60 GOSUB 100\r70 END\r100 PRINT "SUB",RND(1),ABS(-7)\r110 RETURN\rLIST\rRUN\r'
     b'200 LET A=7*(3+4)/2\r210 PRINT A,A-50,-A\rRUN 200\rBYE\r', steps=200_000_000)
for p, i in test_programs.RUNS + [('PI.B8S', b'250\r'), ('PI.B8S', b'999\r'), ('SIEVE.B8S', b'2\r')]:
    same(f'{p} {i[:12]!r}', test_programs.prog(p), i, steps=400_000_000)
section('Tiny BASIC and the programs')

for game, what, keys, texts in test_games.TESTS:
    for ext in ('.B8S', '.TXT'):
        f = os.path.join(test_games.GAMES, game + ext)
        if os.path.exists(f) and game + ext not in test_games.DOCS_ONLY:
            same(f'{game}{ext} {what}', open(f, 'rb').read(), keys, checked=True, play=True,
                 steps=20_000_000, ref=test_games.Play)
for folder, tests in test_tweets.TESTS.items():
    for game, what, keys, texts, end in tests:
        same(f'{folder}/{game} {what}', open(test_tweets.path(folder, game), 'rb').read(), keys,
             checked=True, play=True, steps=200_000_000, ref=test_tweets.Play)
section('the scripted games')

INP = b'y12345 nswe\rabc\r3\r7\r' * 20
for g in sorted(glob.glob(f'{ROOT}/games/*.B8S') + glob.glob(f'{ROOT}/games/*.TXT') + glob.glob(f'{ROOT}/games/*/*.B8S') + glob.glob(f'{ROOT}/games/*/*.TXT')
                + glob.glob(f'{ROOT}/programs/*.B8S') + glob.glob(f'{ROOT}/programs/*.TXT')):
    if os.path.basename(g) == 'IDOL.TXT':        # documentation only
        continue
    same(os.path.relpath(g, ROOT), open(g, 'rb').read(), INP, steps=3_000_000)
section('every game and program, briefly')

b = subprocess.run([sys.executable, os.path.join(ROOT, 'web', 'build.py'), '--check'], capture_output=True, text=True)
print(b.stdout.strip())
bad += b.returncode != 0
print('web:', 'all pass' if not bad else f'{bad} FAILED', f'({count} runs)')
sys.exit(1 if bad else 0)
