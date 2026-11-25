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
NAMES = [('z80/b8s-z80-cpm', 'B8SZ80.COM'), ('z80/b8s-z80-cpm-chk', 'B8SZ80C.COM'),
         ('z80/b8s-z80-cpm-ed', 'B8SZ80E.COM'), ('z80/b8s-z80-cpm-ed-chk', 'B8SZ80EC.COM'),
         ('8080/b8s-8080-cpm', 'B8S8080.COM'), ('8080/b8s-8080-cpm-chk', 'B8S8080C.COM'),
         ('z80/b8s-z80-quick-cpm', 'B8SZ80Q.COM'), ('z80/b8s-z80-quick-cpm-chk', 'B8SZ80QC.COM'),
         ('z80/b8s-z80-quick-cpm-ed', 'B8SZ80QE.COM'), ('z80/b8s-z80-quick-cpm-ed-chk', 'B8SZ80QEC.COM'),
         ('z80/b8s-z80-fast-cpm', 'B8SZ80F.COM'), ('z80/b8s-z80-fast-cpm-chk', 'B8SZ80FC.COM'),
         ('8080/b8s-8080-quick-cpm', 'B8S8080Q.COM'), ('8080/b8s-8080-quick-cpm-chk', 'B8S8080QC.COM'),
         ('8080/b8s-8080-fast-cpm', 'B8S8080F.COM'), ('8080/b8s-8080-fast-cpm-chk', 'B8S8080FC.COM')]
print(f'{"file":13} {"offset":>7} {"address":>8} {"value":>6} {"SAVE pages":>11} {"last address":>13}')
for base, name in NAMES:
    lst = os.path.join(out, base + '.lst')
    if not os.path.exists(lst):
        continue
    text = open(lst, errors='replace').read()
    m = re.search(r'^([0-9A-F]{4})\s+([0-9A-F]{2}) ([0-9A-F]{2})\s+KT1:', text, re.M)
    hexf = os.path.join(out, base + '.hex')
    top = max(int(l[3:7], 16) + int(l[1:3], 16) for l in open(hexf) if l.startswith(':') and l[7:9] == '00')
    a = int(m.group(1), 16) + 1
    print(f'{name:13} {a - 0x100:6X}h {a:7X}h {int(m.group(3), 16):6} {(top - 0x100 + 255) // 256:11} {top - 1:12X}h')
