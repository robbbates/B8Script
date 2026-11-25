"""Copy finished builds from out/ into the release folders next to the sources.

usage: mkrel.py [OUTDIR]   (after build.sh has filled OUTDIR/z80, OUTDIR/8080,
                           ...; OUTDIR defaults to out)

For each CPU it writes the ROM images (.bin), the CP/M programs (.COM, Z80
and 8080 only) and the listings (.lst), under the names the README uses;
for Windows (OUTDIR/win32, from build_win32.sh) the .EXE files and their
listings. The QUICK builds go in ../quick and the FAST builds in ../fast.
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
                          ('ed', f'b8s-{cpu}-rom-editor-{org}.bin'),
                          ('ed-chk', f'b8s-{cpu}-rom-editor-checked-{org}.bin'),
                          ('cpm-ed', com and com + 'E.COM'),
                          ('cpm-ed-chk', com and com + 'EC.COM'),
                          ('zp-gen', f'b8s-{cpu}-rom-zp-{org}.bin'),
                          ('zp-gen-chk', f'b8s-{cpu}-rom-zp-checked-{org}.bin'),
                          ('cpm', com and com + '.COM'),
                          ('cpm-chk', com and com + 'C.COM')):
        base = f'{src}/b8s-{cpu}-{variant}'
        if not name or not os.path.exists(base + '.hex'):
            continue
        lo, img = load_hex(base + '.hex')
        open(f'{dst}/{name}', 'wb').write(bytes(img))
        shutil.copy(base + '.lst', f'{dst}/b8s-{cpu}-{variant}.lst')
        print(f'{cpu:5} {variant:10} {len(img):5} bytes -> {name}')
# The builds with QUICK = 1 go in quick/, and the speed builds (FAST = 1) in fast/,
# named as above with -quick or -fast after the CPU (B8SZ80Q.COM, B8SZ80F.COM, ...).
SPEED = {           # folder: (source stems, ROM origin with QUICK, with FAST, CP/M stem or None)
    'z80': (('b8s-z80',), '0000', '0000', 'B8SZ80'),
    '8080': (('b8s-8080',), '0000', '0000', 'B8S8080'),
    '6502': (('b8s-6502', 'b8s-6502-zp'), 'E000', 'E000', None),
    '6809': (('b8s-6809',), 'F000', 'E000', None),
}
for cpu, (stems, qorg, forg, com) in SPEED.items():
    for kind, org, letter in (('quick', qorg, 'Q'), ('fast', forg, 'F')):
        src, dst = f'{out}/{cpu}', f'{here}/../{kind}'
        for stem in stems:
            zp = stem[len(f'b8s-{cpu}'):].lstrip('-')
            rom = f'b8s-{cpu}-{kind}-rom-' + (zp + '-' if zp else '')
            for variant, name in (('gen', f'{rom}{org}.bin'), ('gen-chk', f'{rom}checked-{org}.bin'),
                                  ('ed', f'{rom}editor-{org}.bin'), ('ed-chk', f'{rom}editor-checked-{org}.bin'),
                                  ('cpm', com and f'{com}{letter}.COM'), ('cpm-chk', com and f'{com}{letter}C.COM'),
                                  ('cpm-ed', com and f'{com}{letter}E.COM'), ('cpm-ed-chk', com and f'{com}{letter}EC.COM')):
                base = f'{src}/{stem}-{kind}-{variant}'
                if not name or not os.path.exists(base + '.hex'):
                    continue
                os.makedirs(dst, exist_ok=True)
                lo, img = load_hex(base + '.hex')
                open(f'{dst}/{name}', 'wb').write(bytes(img))
                shutil.copy(base + '.lst', f'{dst}/{stem}-{kind}-{variant}.lst')
                print(f'{kind:5} {cpu:5} {variant:10} {len(img):5} bytes -> {kind}/{name}')
# Windows: the .EXE files and their listings, as they are
src, dst = f'{out}/win32', f'{here}/../win32'
for name in ('B8SWIN', 'B8SWINC', 'B8SWINE', 'B8SWINEC'):
    if os.path.exists(f'{src}/{name}.EXE'):
        shutil.copy(f'{src}/{name}.EXE', f'{dst}/{name}.EXE')
        shutil.copy(f'{src}/{name}.lst', f'{dst}/{name}.lst')
        print(f'win32 {name:10} {os.path.getsize(src + "/" + name + ".EXE"):5} bytes -> {name}.EXE')
for kind, letter in (('quick', 'Q'), ('fast', 'F')):
    for suffix in ('', 'C', 'E', 'EC'):
        name = f'B8SWIN{letter}{suffix}'
        if os.path.exists(f'{src}/{name}.EXE'):
            shutil.copy(f'{src}/{name}.EXE', f'{here}/../{kind}/{name}.EXE')
            shutil.copy(f'{src}/{name}.lst', f'{here}/../{kind}/{name}.lst')
            print(f'{kind:5} win32 {name:10} {os.path.getsize(src + "/" + name + ".EXE"):5} bytes -> {kind}/{name}.EXE')
