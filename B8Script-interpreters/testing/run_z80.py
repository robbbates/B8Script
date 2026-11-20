import sys, os, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_z80 import Run
from run_tests import check
cpu = sys.argv[1]            # z80 or 8080
d = sys.argv[2]               # folder of .hex/.lst builds
verbose = '-v' in sys.argv
total = 0
for hexf in sorted(glob.glob(d + '/*.hex')):
    base = hexf[:-4]
    cpm = '-cpm' in base
    checked = base.endswith('-chk')
    def runner(p, i, brk=None, base=base, cpm=cpm):
        r = Run(base + '.hex', base + '.lst', p, i, cpu=cpu, mode='cpm' if cpm else 'generic', brk_at=brk)
        o = r.run()
        return o, r.ended
    total += check(runner, os.path.basename(base), cpu, cpm, checked, 0xC9, verbose=verbose)
sys.exit(1 if total else 0)
