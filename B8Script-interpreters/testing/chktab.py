"""Check the layout rules of a Z80 or 8080 build that the assembler can't.

usage: chktab.py LISTING...

- The RST routines sit at their vectors (image start + 08h, 18h, 20h, 28h, 30h).
- PTAB does not cross a page.
- PTAB holds only the low byte of each handler's address, so every handler
  must start in the page the dispatcher expects: the first NPG1 entries in
  the image's second page, the rest in its first. (NPG1 is worked out by
  the assembler from where ] \\ [ @ landed.)
"""
import re, sys

def check(lst):
    text = open(lst, errors='replace').read()
    sym = {m.group(1): int(m.group(2), 16)
           for m in re.finditer(r'^([A-Z_0-9.]+):\s+([0-9A-F]{4}) DEFINED', text, re.M)}
    base = sym['BASE']
    bad = []
    for name, off in (('RPOP', 0x08), ('RST18', 0x18), ('NEG16', 0x20), ('RST28', 0x28), ('RST30', 0x30)):
        if sym.get(name) != base + off:
            bad.append(f'{name} is at {sym.get(name, 0):04X}h, not {base + off:04X}h')
    if sym['PTAB'] >> 8 != (sym['PTABEND'] - 1) >> 8:
        bad.append('PTAB crosses a page')
    # (only lines that assembled to a byte: the table is a macro, and its
    # definition is in the listing too)
    names = re.findall(r'^[0-9A-F]{4}\s+[0-9A-F]{2}\s.*\bDB\s+(H_\w+)\s*&\s*0FFh', text, re.I | re.M)
    if len(names) != 32:
        bad.append(f'{len(names)} table entries found, not 32')
    npg1 = sym['NPG1']
    for i, n in enumerate(names):
        a = sym[n.upper()]
        want = (base >> 8) + (1 if i < npg1 else 0)
        if a >> 8 != want:
            bad.append(f'entry {i:2} {n} is at {a:04X}h: must be in page {want:02X}h')
    last = max(sym[n.upper()] for n in names[:npg1])
    room = ((base >> 8) + 2) * 256 - 1 - last
    first = min(sym[n.upper()] for n in names[:npg1])
    print(f'{lst.split("/")[-1]:28} {"ok" if not bad else "BAD"}   NPG1={npg1}  second-page handlers {first:04X}h-{last:04X}h ({room} to spare)')
    for b in bad:
        print('   ', b)
    return len(bad)

if __name__ == '__main__':
    sys.exit(1 if sum(check(f) for f in sys.argv[1:]) else 0)
