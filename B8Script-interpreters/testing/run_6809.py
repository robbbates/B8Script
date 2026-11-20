"""Run the full B8Script test suite on the 6809 builds in a directory.
usage: run_6809.py DIR [-v] [-nogames]"""
import sys, os, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tests
from run_tests import check
from harness_6809 import Run

# machine-code test: double the top data cell. Entered by JSR with U at the
# top cell (big-endian): PULU D; ASLB; ROLA; PSHU D; RTS (the loader's RTS)
tests.MC['6809'] = [
    ('mcdouble', b'8_:d! `370658493606 ; 21 d@` #', b'', b'42'),
    # push a constant: LDD #7; PSHU D; RTS
    ('mcpush', b'8_:d! `CC00073606 ; d@` #', b'', b'7'),
]

d = sys.argv[1]
verbose = '-v' in sys.argv
games = '-nogames' not in sys.argv
only = [a for a in sys.argv[2:] if not a.startswith('-')]
total = 0
for hexf in sorted(glob.glob(d + '/*.hex')):
    base = hexf[:-4]
    if only and not any(o in base for o in only):
        continue
    checked = base.endswith('-chk')
    def runner(p, i, brk=None, base=base):
        r = Run(base + '.hex', base + '.lst', p, i, brk_at=brk)
        o = r.run()
        return o, r.ended
    total += check(runner, os.path.basename(base), '6809', False, checked, 0x39,
                   games=games, verbose=verbose)
sys.exit(1 if total else 0)
