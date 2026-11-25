"""Where to patch n?'s timing in the CP/M .COM files.

usage: patchinfo.py [OUT]       (OUT: the build folder, default out)

n? counts MSLOOP keyboard checks (BDOS 6 calls) a millisecond. In a .COM
that count is the operand of `LD E,MSLOOP` (MVI E on the 8080) at kt1. This
prints, for each CP/M build, where that byte is: as an offset in the file
(for a hex editor) and as an address once loaded at 0100h (for DDT, SID or
ZSID), with the number of 256-byte pages for CP/M 2.2's SAVE, and the last
address for CP/M 3's SAVE. Run TIMING.B8S to find the value your machine
wants."""
import re, sys, os
out = sys.argv[1] if len(sys.argv) > 1 else 'out'
NAMES = [(f'{cpu}/b8s-{cpu}-{tier}-cpm{ed}{chk}', f'{cpu}/{tier}/B8S{u}{t}{e}.COM')
         for cpu in ('z80', '8080') for tier, t in (('small', 'S'), ('base', ''), ('fast', 'F'))
         for ed, e in (('', ''), ('-ed', 'E')) for chk, u in (('-chk', ''), ('', 'U'))]
print(f'{"file":22} {"offset":>7} {"address":>8} {"value":>6} {"SAVE pages":>11} {"last address":>13}')
for base, name in NAMES:
    lst = os.path.join(out, base + '.lst')
    if not os.path.exists(lst):
        continue
    text = open(lst, errors='replace').read()
    m = re.search(r'^([0-9A-F]{4})\s+([0-9A-F]{2}) ([0-9A-F]{2})\s+KT1:', text, re.M)
    hexf = os.path.join(out, base + '.hex')
    top = max(int(l[3:7], 16) + int(l[1:3], 16) for l in open(hexf) if l.startswith(':') and l[7:9] == '00')
    a = int(m.group(1), 16) + 1
    print(f'{name:22} {a - 0x100:6X}h {a:7X}h {int(m.group(3), 16):6} {(top - 0x100 + 255) // 256:11} {top - 1:12X}h')
