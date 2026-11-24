"""Check every 6502 branch in an asm80 listing against its target.

usage: chkbr6502.py LISTING...

asm80 lets some bad 6502 branches through; this works each branch's target
out from its offset byte and compares it with the label's address.
"""
import re, sys

def check(lst):
    lines = open(lst, errors='replace').read().splitlines()
    sym = {}
    for l in lines:
        m = re.match(r'^([A-Z_0-9.]+):\s+([0-9A-F]{4}) DEFINED', l)
        if m: sym[m.group(1)] = int(m.group(2), 16)
    bad = n = 0
    for l in lines:
        m = re.match(r'^([0-9A-F]{4})\s+([0-9A-F]{2}) ([0-9A-F]{2})\s+(?:\w+:)?\s*(BNE|BEQ|BPL|BMI|BCC|BCS|BVC|BVS)\s+(\w+)', l)
        if m:
            a = int(m.group(1), 16); d = int(m.group(3), 16); d -= 256 if d > 127 else 0
            t = sym.get(m.group(5).upper())
            if t is not None:
                n += 1
                if a + 2 + d != t:
                    print('BAD', l); bad += 1
    print(f'{lst.split("/")[-1]:28} {"ok " if not bad else "BAD"}  {n} branches, {bad} bad')
    return bad + (n == 0)

if __name__ == '__main__':
    sys.exit(1 if sum(check(f) for f in sys.argv[1:]) else 0)
