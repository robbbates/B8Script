"""Copy finished builds from out/ into the release folders next to the sources.

usage: mkrel.py [OUTDIR]   (after build.sh has filled OUTDIR/z80, OUTDIR/8080,
                           ...; OUTDIR defaults to out)

For each CPU it writes the ROM images (.bin), the CP/M programs (.COM, Z80
and 8080 only) and the listings (.lst), under the names the README uses.
"""
import os, shutil, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from harness_z80 import load_hex

CPUS = {            # folder: (ROM origin, CP/M file stem or None)
    'z80': ('0000', 'B8SZ80'),
    '8080': ('0000', 'B8S8080'),
    '6502': ('E000', None),
    '6809': ('F000', None),
}
out = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else f'{here}/out'
for cpu, (org, com) in CPUS.items():
    src, dst = f'{out}/{cpu}', f'{here}/../{cpu}'
    if not os.path.isdir(src):
        continue
    for variant, name in (('gen', f'b8s-{cpu}-rom-{org}.bin'),
                          ('gen-chk', f'b8s-{cpu}-rom-checked-{org}.bin'),
                          ('cpm', com and com + '.COM'),
                          ('cpm-chk', com and com + 'C.COM')):
        base = f'{src}/b8s-{cpu}-{variant}'
        if not name or not os.path.exists(base + '.hex'):
            continue
        lo, img = load_hex(base + '.hex')
        open(f'{dst}/{name}', 'wb').write(bytes(img))
        shutil.copy(base + '.lst', f'{dst}/b8s-{cpu}-{variant}.lst')
        print(f'{cpu:5} {variant:8} {len(img):5} bytes -> {name}')
