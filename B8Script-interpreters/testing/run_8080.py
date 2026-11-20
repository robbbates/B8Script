import sys, os, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tests
from harness_z80 import Run
from run_tests import check
d = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else 'out/8080'
verbose = '-v' in sys.argv
only = [a for a in sys.argv[2:] if not a.startswith('-')]
total = 0
for hexf in sorted(glob.glob(d + '/*.hex')):
    base = hexf[:-4]
    if only and not any(base.endswith(o) for o in only):
        continue
    cpm = '-cpm' in base
    checked = base.endswith('-chk')
    def runner(p, i, brk=None, base=base, cpm=cpm):
        r = Run(base + '.hex', base + '.lst', p, i, cpu='8080', mode='cpm' if cpm else 'generic', brk_at=brk)
        o = r.run()
        return o, r.ended
    total += check(runner, os.path.basename(base), '8080', cpm, checked, 0xC9, verbose=verbose)
sys.exit(1 if total else 0)
