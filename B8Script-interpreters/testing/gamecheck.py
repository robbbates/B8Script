"""Run every game in games/ (at the root of the repository), both the stripped NAME.B8S and the commented
NAME.TXT, on every build under DIR for a short while and compare what it
prints with the reference interpreter.

usage: gamecheck.py OUTDIR      (OUTDIR holds z80/, 8080/, 6502/, 6809/ from build.sh,
                                 and win32/ from build_win32.sh)

The same keys are typed at each game. A run is cut off after a set amount of
work, so only the output up to the shorter of the two runs is compared.

A NAME.TXT listed in DOCS_ONLY is documentation only: it need not run (it may not
fit in memory), so only its NAME.B8S is run. test_games.py checks that the .B8S
is the .TXT stripped.
"""
import re, sys, os, glob
here = os.path.dirname(os.path.abspath(__file__))
GAMES = os.path.normpath(os.path.join(here, '..', '..', 'games'))   # games/ at the root of the repository
PROGS = os.path.normpath(os.path.join(here, '..', '..', 'programs'))   # and programs/
sys.path.insert(0, here)
from ref import Ref
import harness_z80, harness_6502, harness_6809, harness_win32

INP = b'y12345 nswe\rabc\r3\r7\r' * 20
DOCS_ONLY = {'IDOL.TXT', 'MON.B8S', 'MON.TXT'}   # (MON shows memory, which differs: test_programs.py)
LONG = {'IDOL.B8S': 10}     # a big game: more work before the cut-off, so it gets past its start
out = sys.argv[1]
bad = 0
for cpu in ('z80', '8080', '6502', '6809', 'win32'):
    for hexf in sorted(glob.glob(f'{out}/{cpu}/*.hex') + glob.glob(f'{out}/{cpu}/*.EXE')):
        base = hexf[:-4]
        name = os.path.basename(base)
        if '-ed' in name or re.fullmatch(r'B8SU?[SF]?E', name):               # the editor builds have their own test
            continue
        cpm = '-cpm' in name
        short = []
        for g in sorted(glob.glob(f'{GAMES}/*.B8S') + glob.glob(f'{GAMES}/*.TXT') + glob.glob(f'{PROGS}/*.B8S') + glob.glob(f'{PROGS}/*.TXT')):
            if os.path.basename(g) in DOCS_ONLY:
                continue
            prog = open(g, 'rb').read()
            x = LONG.get(os.path.basename(g), 1)
            exp = Ref(prog, INP, cpm=cpm, retbyte={'6502': 0x60, '6809': 0x39, 'win32': 0xC3}.get(cpu, 0xC9)).run(300_000 * x)
            if cpu in ('z80', '8080'):
                r = harness_z80.Run(base + '.hex', base + '.lst', prog, INP, cpu=cpu,
                                    mode='cpm' if cpm else 'generic', maxticks=150_000_000 * x)
            elif cpu == '6502':
                r = harness_6502.Run(base + '.hex', base + '.lst', prog, INP, maxsteps=3_000_000 * x)
            elif cpu == 'win32':
                r = harness_win32.Run(hexf, prog, INP, maxinstr=30_000_000 * x)
            else:
                r = harness_6809.Run(base + ".hex", base + ".lst", prog, INP, maxops=3_000_000 * x)
            got = r.run()
            k = min(len(got), len(exp))
            if got[:k] != exp[:k] or k < 20:
                bad += 1
                d = next((i for i in range(k) if got[i] != exp[i]), k)
                print(f'  {name}: {os.path.basename(g)} differs at byte {d} of {k}: got {got[max(0,d-20):d+20]!r} exp {exp[max(0,d-20):d+20]!r}')
            short.append(k)
            if x > 1:
                print(f'    {os.path.basename(g)}: {k} bytes of output compared')
        print(f'{name:24} {len(short)} programs, {min(short)}-{max(short)} bytes of output compared')
print('games:', 'all match' if not bad else f'{bad} DIFFER')
sys.exit(1 if bad else 0)
