"""Check the dispatch layout of a 6502 build that has the one-byte table.

usage: chktab6502.py LISTING...

PTAB holds one byte per handler: the low byte of (handler - 1). The
dispatcher works the high byte out from the character's index: the image's
first page for an index below N1, the second for N1 to N2-1, the third for
the rest. So each handler must start where its index says, which the
assembler can't check. For each page this prints how many bytes are to spare
before its last handler would start too late.
A listing with no N1 has the whole-address table, which has no such rules,
and so has the fast build (SPEED = 2), which dispatches through a full table.
"""
import re, sys

def check(lst):
    text = open(lst, errors='replace').read()
    sym = {m.group(1): int(m.group(2), 16)
           for m in re.finditer(r'^([A-Z_0-9.]+):\s+([0-9A-F]{4}) DEFINED', text, re.M)}
    name = lst.split('/')[-1]
    if sym.get('FAST') == 1:        # the fast build dispatches through a full table: no rules
        print(f'{name:28} ok   (speed build: a full table, no layout rules)')
        return 0
    if 'N1' not in sym:
        print(f'{name:28} ok   (whole-address table: no layout rules)')
        return 0
    base, n1, n2 = sym['BASE'], sym['N1'], sym['N2']
    names = re.findall(r'^[0-9A-F]{4}\s+[0-9A-F]{2}\s.*\bDB\s+\((\w+)-1\)\s*&\s*0FFh', text, re.M | re.I)
    bad = []
    if len(names) != 32:
        bad.append(f'{len(names)} table entries found, not 32')
    if base % 512:
        bad.append(f'BASE is {base:04X}h: it must be a multiple of 512')
    spare = [256, 256, 256]
    for i, n in enumerate(names):
        page = (i >= n1) + (i >= n2)
        off = sym[n.upper()] - 1 - base - 256 * page
        if not 0 <= off <= 255:
            bad.append(f'entry {i:2} {n} starts at {sym[n.upper()]:04X}h: not in page {page + 1} of the image')
        spare[page] = min(spare[page], 255 - off)
    print(f'{name:28} {"ok " if not bad else "BAD"}  N1={n1} N2={n2}  to spare in each page: {spare[0]}, {spare[1]}, {spare[2]}')
    for b in bad:
        print('   ', b)
    return len(bad)

if __name__ == '__main__':
    sys.exit(1 if sum(check(f) for f in sys.argv[1:]) else 0)
