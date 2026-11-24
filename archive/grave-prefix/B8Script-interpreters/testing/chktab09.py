"""Check the dispatch layout of an unchecked 6809 build, which the assembler can't.

usage: chktab09.py LISTING...

PTAB holds one byte per handler: the low byte of its distance from PTAB. The
dispatcher adds 256 for the first NPG1 entries, so those handlers must start
256-511 bytes past PTAB, and the rest 0-255 bytes past it. (NPG1 is worked
out by the assembler from where ] \\ [ @ ? landed.)

In both builds the grave's table, GTAB, holds each handler's distance from the
address after its own entry in one byte, so every handler must start within
255 bytes of it.
"""
import re, sys

def check(lst):
    text = open(lst, errors='replace').read()
    sym = {m.group(1): int(m.group(2), 16)
           for m in re.finditer(r'^([A-Z_0-9.]+):\s+([0-9A-F]{4}) DEFINED', text, re.M)}
    # the grave's table (both builds): each handler's distance from the
    # address after its entry, which must fit in a byte
    gbad = []
    for m in re.finditer(r'^([0-9A-F]{4})\s+([0-9A-F]{2})\s+FCB\s+(G_\w+)-\$-1', text, re.I | re.M):
        at, byte, n = int(m.group(1), 16), int(m.group(2), 16), m.group(3).upper()
        if sym[n] - at - 1 != byte:
            gbad.append(f'{n} is {sym[n] - at - 1} bytes past its table entry: more than a byte holds')
    if 'NPG1' not in sym:
        print(f'{lst.split("/")[-1]:28} {"ok " if not gbad else "BAD"}  (whole-address table: no layout rules but the grave\'s)')
        for b in gbad:
            print('   ', b)
        return len(gbad)
    ptab, npg1 = sym['PTAB'], sym['NPG1']
    names = re.findall(r'\bFCB\s+\((H_\w+)-PTAB\)\s*&\s*0FFh', text, re.I)
    bad = gbad
    if len(names) != 32:
        bad.append(f'{len(names)} table entries found, not 32')
    for i, n in enumerate(names):
        off = sym[n.upper()] - ptab
        lo = 256 if i < npg1 else 0
        if not lo <= off <= lo + 255:
            bad.append(f'entry {i:2} {n} is {off} bytes past PTAB: must be {lo}-{lo + 255}')
    far = max(sym[n.upper()] - ptab for n in names[:npg1])
    near = max(sym[n.upper()] - ptab for n in names[npg1:])
    print(f'{lst.split("/")[-1]:28} {"ok" if not bad else "BAD"}   NPG1={npg1}  first range to +{near}, second to +{far} ({511 - far} to spare)')
    for b in bad:
        print('   ', b)
    return len(bad)

if __name__ == '__main__':
    sys.exit(1 if sum(check(f) for f in sys.argv[1:]) else 0)
