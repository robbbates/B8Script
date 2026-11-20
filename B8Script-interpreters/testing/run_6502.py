import sys, os, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_6502 import Run
import tests
from run_tests import check

# Machine-code tests (6502 contract: TOS in zero page $02/$03, data stack
# through X at $0200,X / $0300,X, ends in RTS = 60h which the loader writes).
#  mcdouble: ASL $02 / ROL $03: doubles TOS.
#  mcpush:   DEX / LDA $02 / STA $0200,X / LDA $03 / STA $0300,X /
#            LDA #7 / STA $02 / LDA #0 / STA $03: pushes 7 over TOS.
tests.MC['6502'] = [
    ('mcdouble', b'8_:d! `06022603 ; 21 d@` #', b'', b'42'),
    ('mcpush', b'20_:d! `CA A502 9D0002 A503 9D0003 A907 8502 A900 8503 ; 5 d@` # #', b'', b'75'),
]
# the loader reads hex pairs only, so no spaces inside the pair stream
tests.MC['6502'][1] = ('mcpush', b'20_:d! `CAA5029D0002A5039D0003A9078502A9008503 ; 5 d@` # #', b'', b'75')

games = '--nogames' not in sys.argv
verbose = '-v' in sys.argv
d = [a for a in sys.argv[1:] if not a.startswith('-')][0]
total = 0
for hexf in sorted(glob.glob(d + '/*.hex')):
    base = hexf[:-4]
    checked = base.endswith('-chk')
    def runner(p, i, brk=None, base=base):
        r = Run(base + '.hex', base + '.lst', p, i, brk_at=brk)
        o = r.run()
        return o, r.ended
    total += check(runner, os.path.basename(base), '6502', False, checked, 0x60,
                   games=games, verbose=verbose)
sys.exit(1 if total else 0)
