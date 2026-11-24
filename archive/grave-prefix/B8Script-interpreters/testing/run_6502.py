import sys, os, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_6502 import Run
from harness_z80 import symbols
import tests
from run_tests import check

# Machine-code tests (the loader reads hex pairs only, so no spaces; it
# writes the RTS, 60h, itself). Each interpreter has its own contract:
#  b8s-6502.asm     TOS in zero page $02/$03, the rest of the data stack at
#                   $0200,X (low bytes) and $0300,X (high bytes)
#    mcdouble: ASL $02 / ROL $03: doubles TOS.
#    mcpush:   DEX / LDA $02 / STA $0200,X / LDA $03 / STA $0300,X /
#              LDA #7 / STA $02 / LDA #0 / STA $03: pushes 7 over TOS.
#  b8s-6502-zp.asm  every cell in zero page, TOS at 0,X and 1,X
#    mcdouble: ASL 0,X / ROL 1,X
#    mcpush:   DEX / DEX / LDA #7 / STA 0,X / LDA #0 / STA 1,X
MC = {
    False: [('mcdouble', b'8_:d! `$06022603 ; 21 d@`! #', b'', b'42'),
            ('mcpush', b'20_:d! `$CAA5029D0002A5039D0003A9078502A9008503 ; 5 d@`! # #', b'', b'75')],
    True: [('mcdouble', b'8_:d! `$16003601 ; 21 d@`! #', b'', b'42'),
           ('mcpush', b'20_:d! `$CACAA9079500A9009501 ; 5 d@`! # #', b'', b'75')],
}

games = '--nogames' not in sys.argv
verbose = '-v' in sys.argv
d = [a for a in sys.argv[1:] if not a.startswith('-')][0]
total = 0
for hexf in sorted(glob.glob(d + '/*.hex')):
    base = hexf[:-4]
    checked = '-chk' in base
    tests.MC['6502'] = MC['-zp' in os.path.basename(base)]
    def runner(p, i, timed=None, base=base):
        r = Run(base + '.hex', base + '.lst', p, i, timed=timed or ())
        o = r.run()
        runner.last = r
        return o, r.ended
    # the build's own addresses, so that ref.py can reproduce a checked
    # build's report exactly (places, the heap limit, addresses on the stack)
    sy = symbols(base + '.lst')
    plat = dict(prog_at=sy['PROG'], let=sy['LET'], linebuf=sy['LINEBUF'],
                heaplim=sy['HEAPLIM'] << 8, seed=sy.get('SEED'))
    total += check(runner, os.path.basename(base), '6502', False, checked, 0x60,
                   games=games, verbose=verbose, plat=plat)
sys.exit(1 if total else 0)
