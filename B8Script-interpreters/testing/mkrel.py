"""Copy finished builds from out/ into the release folders next to the sources.

usage: mkrel.py [OUTDIR]   (after build.sh has filled OUTDIR/z80, OUTDIR/8080,
                           ...; OUTDIR defaults to out)

For each CPU it writes the ROM images (.bin), the CP/M programs (.COM, Z80
and 8080 only) and the listings (.lst), under the names the README uses;
for Windows (OUTDIR/win32, from build_win32.sh) the four .EXE files and
their listings.
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
# The Z80 builds with QUICK = 1 go in their own folder, quick/
src, dst = f'{out}/z80', f'{here}/../quick'
for variant, name in (('quick-gen', 'b8s-z80-quick-rom-0000.bin'), ('quick-gen-chk', 'b8s-z80-quick-rom-checked-0000.bin'),
                      ('quick-ed', 'b8s-z80-quick-rom-editor-0000.bin'), ('quick-ed-chk', 'b8s-z80-quick-rom-editor-checked-0000.bin'),
                      ('quick-cpm', 'B8SZ80Q.COM'), ('quick-cpm-chk', 'B8SZ80QC.COM'),
                      ('quick-cpm-ed', 'B8SZ80QE.COM'), ('quick-cpm-ed-chk', 'B8SZ80QEC.COM')):
    base = f'{src}/b8s-z80-{variant}'
    if not os.path.exists(base + '.hex'):
        continue
    os.makedirs(dst, exist_ok=True)
    lo, img = load_hex(base + '.hex')
    open(f'{dst}/{name}', 'wb').write(bytes(img))
    shutil.copy(base + '.lst', f'{dst}/b8s-z80-{variant}.lst')
    print(f'quick {variant:16} {len(img):5} bytes -> quick/{name}')
# The Z80's speed builds go in their own folder, fast/
src, dst = f'{out}/z80', f'{here}/../fast'
for variant, name in (('fast-gen', 'b8s-z80-fast-rom-0000.bin'), ('fast-gen-chk', 'b8s-z80-fast-rom-checked-0000.bin'),
                      ('fast-cpm', 'B8SZ80F.COM'), ('fast-cpm-chk', 'B8SZ80FC.COM')):
    base = f'{src}/b8s-z80-{variant}'
    if not os.path.exists(base + '.hex'):
        continue
    os.makedirs(dst, exist_ok=True)
    lo, img = load_hex(base + '.hex')
    open(f'{dst}/{name}', 'wb').write(bytes(img))
    shutil.copy(base + '.lst', f'{dst}/b8s-z80-{variant}.lst')
    print(f'fast  {variant:12} {len(img):5} bytes -> fast/{name}')
# Windows: the .EXE files and their listings, as they are
src, dst = f'{out}/win32', f'{here}/../win32'
for name in ('B8SWIN', 'B8SWINC', 'B8SWINE', 'B8SWINEC'):
    if os.path.exists(f'{src}/{name}.EXE'):
        shutil.copy(f'{src}/{name}.EXE', f'{dst}/{name}.EXE')
        shutil.copy(f'{src}/{name}.lst', f'{dst}/{name}.lst')
        print(f'win32 {name:10} {os.path.getsize(src + "/" + name + ".EXE"):5} bytes -> {name}.EXE')
