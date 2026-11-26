"""Tests for the CP/M file programs in programs/cpm/: HEXDUMP.

usage: test_cpm.py            check the guard on ref.py
       test_cpm.py OUT        and run HEXDUMP, both .B8S and .TXT, on every CP/M
                              runner in OUT (as built by build.sh), and the guard
                              on every generic Z80 and 8080 build there

HEXDUMP calls the BDOS through machine code, which ref.py can't run, so on ref.py
(checked) it must print the guard's line and end, as it must on a generic build.
On a CP/M runner its output is checked against a model written here in Python,
byte for byte. harness_z80.py's disk holds the files, and its command tail gives
the name after the program's."""
import re, sys, os, glob, random
here = os.path.dirname(os.path.abspath(__file__))
CPM = os.path.normpath(os.path.join(here, '..', '..', 'programs', 'cpm'))
sys.path.insert(0, here)
from ref import Ref

GUARD = b'Needs CP/M on a Z80 or 8080.\r\n'
PROGS = ('HEXDUMP.B8S', 'HEXDUMP.TXT')
NAME = b'TEST    COM'           # the file on the disk, as in an FCB


def hexdump(data, keys, typed=None):
    """What HEXDUMP prints for a file holding data (None: no such file), given
    the keys, after a name typed at its prompt if typed is given."""
    out = b''
    if typed is not None:
        out += b'File: ' + typed + b'\r\n'
    if data is None:
        return out + b'No such file.\r\n'
    data += b'\x1a' * (-len(data) % 128)            # whole records, as CP/M keeps them
    s = len(data) // 128
    if not s:
        return out + b'Empty file.\r\n'
    m = (s + 1) // 2

    def page(n):
        p = b'\x1b[1;1H'
        e = 256 if 2 * n - 1 < s else 128
        for i in range(16):
            if i * 16 < e:
                row = data[(n - 1) * 256 + i * 16:][:16]
                p += b'%04X%02X: ' % (n - 1, i * 16) + b''.join(b'%02X ' % c for c in row) + b' '
                p += bytes(c if 32 <= c <= 126 else 46 for c in row)
            else:
                p += b'\x1b[K'
            p += b'\r\n'
        return p + b'\x1b[18;1HPage %d of %d   Space next, b back, q quit\x1b[K' % (n, m)

    out += b'\x1b[H\x1b[J'
    n = 1
    out += page(n)
    for k in keys:
        if k in (32, 13):
            if n < m:
                n += 1
                out += page(n)
        elif k | 32 == 98:
            if n > 1:
                n -= 1
                out += page(n)
        elif k | 32 == 113:
            return out + b'\r\n'
    raise ValueError('the keys must end with q')


def recs(n, seed):
    """n records of bytes that cover every value."""
    r = random.Random(seed)
    return bytes(r.randrange(256) for _ in range(n * 128))


ALL = bytes(range(256))
# (what, the file or None, the name typed at the prompt or None, keys)
CASES = [
    ('one record', ALL[:128], None, b'q'),
    ('three records: a last page of one', recs(3, 1), None, b' q'),
    ('next and back across five records', recs(5, 2), None, b' \r\r bbbBQ'),
    ('a file of 519 records', recs(519, 3), None, b'q'),
    ('a file with no ^Z, every byte', ALL * 2, None, b'q'),
    ('an empty file', b'', None, b''),
    ('a missing file', None, None, b''),
    ('the name typed at the prompt', ALL, b'a:test.com', b'q'),
    ('a missing file typed at the prompt', None, b'nofile.txt', b''),
]


def check_ref():
    bad = 0
    for p in PROGS:
        r = Ref(open(os.path.join(CPM, p), 'rb').read(), b'', checked=True)
        o = r.run(5_000_000)
        ok = o == GUARD
        bad += not ok
        print(f'{"PASS" if ok else "FAIL"}  {p:12} ref.py, checked: the guard  {o[-60:]!r}')
    return bad


def check_builds(out):
    import harness_z80
    bad = 0
    for cpu in ('z80', '8080'):
        for f in sorted(glob.glob(f'{out}/{cpu}/*.hex')):
            base, name = f[:-4], os.path.basename(f[:-4])
            if '-ed' in name:                           # the editors run no file
                continue
            cpm = '-cpm' in name
            fails = []
            for p in PROGS:
                prog = open(os.path.join(CPM, p), 'rb').read()
                cases = CASES if cpm else [('the guard', None, None, b'')]
                for what, data, typed, keys in cases:
                    files = {b'PROG    B8S': prog}
                    if data is not None:
                        files[NAME] = data
                    tail = b' PROG.B8S' if typed is not None else b' PROG.B8S TEST.COM'
                    inp = (typed + b'\r' if typed is not None else b'') + keys
                    r = harness_z80.Run(base + '.hex', base + '.lst', prog, inp, cpu=cpu,
                                        mode='cpm' if cpm else 'generic', files=files, tail=tail,
                                        maxticks=2_000_000_000)
                    got = r.run()
                    exp = hexdump(data, keys, typed) if cpm else GUARD
                    if got != exp or r.ended != 'exit':
                        d = next((i for i in range(min(len(got), len(exp))) if got[i] != exp[i]),
                                 min(len(got), len(exp)))
                        fails.append(f'{p}: {what} (ended {r.ended}, differs at byte {d}: '
                                     f'got {got[d:d + 30]!r}, expected {exp[d:d + 30]!r})')
            bad += len(fails)
            print(f'{name:24} {"PASS" if not fails else "FAIL"}', flush=True)
            for x in fails:
                print('   ', x)
    return bad


if __name__ == '__main__':
    bad = check_ref()
    if len(sys.argv) > 1:
        bad += check_builds(sys.argv[1])
    print('cpm:', 'all pass' if not bad else f'{bad} FAILED')
    sys.exit(1 if bad else 0)
