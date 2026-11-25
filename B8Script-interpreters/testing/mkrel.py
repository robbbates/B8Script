"""Copy finished builds from out/ into the release folders next to the sources.

usage: mkrel.py [OUTDIR]   (after build.sh and build_win32.sh have filled
                           OUTDIR/z80, OUTDIR/8080, ...; OUTDIR defaults to out)

Each CPU's folder has three, one for each setting of SPEED: small/ (0),
base/ (1) and fast/ (2). Into each go the ROM images (.bin), the CP/M programs
(.COM, Z80 and 8080) or the Windows programs (.EXE), each with its listing
(.lst) under the same name:

  CP/M and Windows   B8S, then S (small) or F (fast), then E with the line
                     editor, then U if unchecked: B8S.COM is the base
                     runner, checked; B8SSEU.COM the small editor, unchecked
  ROM images         b8s-CPU-TIER-rom, then -zp (the zero-page 6502
                     interpreter), -editor, -unchecked, and the address it
                     starts at: b8s-z80-base-rom-0000.bin
"""
import os, shutil, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from harness_z80 import load_hex

TIERS = (('small', 'S'), ('base', ''), ('fast', 'F'))
CPUS = {            # folder: (source stems, ROM origin by tier, has CP/M)
    'z80': (('b8s-z80',), {'small': '0000', 'base': '0000', 'fast': '0000'}, True),
    '8080': (('b8s-8080',), {'small': '0000', 'base': '0000', 'fast': '0000'}, True),
    '6502': (('b8s-6502', 'b8s-6502-zp'), {'small': 'E000', 'base': 'E000', 'fast': 'E000'}, False),
    '6809': (('b8s-6809',), {'small': 'F000', 'base': 'F000', 'fast': 'E000'}, False),
}
out = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else f'{here}/out'


def copy(src, dst, data, lst, label):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, 'wb').write(data)
    shutil.copy(lst, dst[:dst.rindex('.')] + '.lst')
    print(f'{label:28} {len(data):5} bytes -> {os.path.relpath(dst, here + "/..")}')


for cpu, (stems, orgs, cpm) in CPUS.items():
    for tier, t in TIERS:
        dst = f'{here}/../{cpu}/{tier}'
        for stem in stems:
            zp = '-zp' if stem.endswith('-zp') else ''
            for ed in ('', '-ed'):
                for chk in ('-chk', ''):
                    unc = '' if chk else '-unchecked'
                    builds = [(f'gen{ed}', f'b8s-{cpu}-{tier}-rom{zp}{"-editor" if ed else ""}{unc}-{orgs[tier]}.bin')]
                    if cpm:
                        builds.append((f'cpm{ed}', f'B8S{t}{"E" if ed else ""}{"" if chk else "U"}.COM'))
                    for kind, name in builds:
                        kind = kind.replace('gen-ed', 'ed')
                        base = f'{out}/{cpu}/{stem}-{tier}-{kind}{chk}'
                        if os.path.exists(base + '.hex'):
                            lo, img = load_hex(base + '.hex')
                            copy(base, f'{dst}/{name}', bytes(img), base + '.lst', f'{cpu} {tier} {kind}{chk}')
# Windows: the .EXE files and their listings, as they are named already
for tier, t in TIERS:
    for e in ('', 'E'):
        for u in ('', 'U'):
            name = f'B8S{t}{e}{u}'
            src = f'{out}/win32/{name}'
            if os.path.exists(src + '.EXE'):
                copy(src, f'{here}/../win32/{tier}/{name}.EXE', open(src + '.EXE', 'rb').read(), src + '.lst', f'win32 {tier} {name}')
