"""Tests for the CP/M file programs in programs/cpm/: HEXDUMP and LEDIT.

usage: test_cpm.py            check the guards on ref.py
       test_cpm.py OUT        and run both programs, .B8S and .TXT, on every CP/M
                              runner in OUT (as built by build.sh), and the guards
                              on every generic Z80 and 8080 build there

The programs call the BDOS through machine code, which ref.py can't run, so on
ref.py (checked) each must print the guard's line and end, as it must on a generic
build. On a CP/M runner the output is checked against a model written here in
Python, byte for byte, and so is the disk afterwards: harness_z80.py's disk holds
the files, and its command tail gives the name after the program's.

A case is (what, the file or None, a name typed at the prompt or None, keys). The
file may instead be a function of the room LEDIT has for its text, for the cases
at the limits of memory; cpmsim.py, under real CP/M, leaves those out."""
import re, sys, os, glob, random
here = os.path.dirname(os.path.abspath(__file__))
CPM = os.path.normpath(os.path.join(here, '..', '..', 'programs', 'cpm'))
sys.path.insert(0, here)
from ref import Ref

GUARD = b'Needs CP/M on a Z80 or 8080.\r\n'
NAME = b'TEST    DAT'            # the file on the disk, as in an FCB


def readline(keys, out, n):
    """-n?: what every build does with the keys used here (ref.py's readline):
    each key but CR is stored and echoed while there is room; CR ends it."""
    buf = bytearray()
    while True:
        c = keys.pop(0)
        if c == 13:
            return bytes(buf)
        if len(buf) < n:
            buf.append(c)
            out.append(c)


# ---- HEXDUMP ----

def hexdump(data, keys, typed=None, room=None):
    """What HEXDUMP prints for a file holding data (None: no such file), given
    the keys, after a name typed at its prompt if typed is given; and the file
    after (HEXDUMP never changes it)."""
    out = b''
    if typed is not None:
        out += b'File: ' + typed + b'\r\n'
    if data is None:
        return out + b'No such file.\r\n', data
    file = data
    data += b'\x1a' * (-len(data) % 128)            # whole records, as CP/M keeps them
    s = len(data) // 128
    if not s:
        return out + b'Empty file.\r\n', file
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
            return out + b'\r\n', file
    raise ValueError('the keys must end with q')


def recs(n, seed):
    """n records of bytes that cover every value."""
    r = random.Random(seed)
    return bytes(r.randrange(256) for _ in range(n * 128))


ALL = bytes(range(256))
HEXDUMP_CASES = [
    ('one record', ALL[:128], None, b'q'),
    ('three records: a last page of one', recs(3, 1), None, b' q'),
    ('next and back across five records', recs(5, 2), None, b' \r\r bbbBQ'),
    ('a file of 519 records', recs(519, 3), None, b'q'),
    ('a file with no ^Z, every byte', ALL * 2, None, b'q'),
    ('an empty file', b'', None, b''),
    ('a missing file', None, None, b''),
    ('the name typed at the prompt', ALL, b'a:test.dat', b'q'),
    ('a missing file typed at the prompt', None, b'nofile.txt', b''),
]


# ---- LEDIT ----

LEDIT_HEAP = 2 + 14 + 25 + 43 + 36 + 36     # what LEDIT allocates before its text


def ledit(data, keys, typed=None, room=None):
    """What LEDIT prints for a file holding data (None: there is none), given the
    keys, after a name typed at its prompt if typed is given; and the file it
    leaves (None: none). room is the memory for the text, from its start to the
    limit, for the cases at the limits (None: plenty)."""
    keys, out = list(keys), bytearray()
    if typed is not None:
        out += b'File: '
        readline(list(typed + b'\r'), out, 14)
        out += b'\r\n'
    disk = data
    if data is None:
        out += b'New file.\r\n'
        text = b''
    else:
        text = data + b'\x1a' * (-len(data) % 128)
        if room is not None and len(text) + 258 > room:   # room for each record and 130
            out += b'File too big.\r\n'
            return bytes(out), disk
        text = text.split(b'\x1a')[0]
        if text and not text.endswith(b'\n'):
            text += b'\r\n'
    lines = re.findall(rb'[^\n]*\n', text)

    def find(n):                    # F: the line's number, clipped
        n = max(n, 1)
        return min(n, len(lines) + 1)

    def num(n):                     # U
        return b' ' * ((n < 1000) + (n < 100) + (n < 10)) + b'%d ' % n

    def insert(n, s):               # T
        if room is not None and len(b''.join(lines)) + len(s) + 130 > room:
            out.extend(b'Out of room.\r\n')
            return False
        lines.insert(find(n) - 1, s + b'\r\n')
        return True

    def write():                    # W
        t = b''.join(lines)
        out.extend(b'Saved.\r\n')
        return t + b'\x1a' * (-len(t) % 128)

    while True:
        out += b'*'
        t = readline(keys, out, 127) + b'\r'
        out += b'\r\n'
        p = n = 0
        h = t[0] in b'0123456789'
        while t[p] in b'0123456789':
            n = (n * 10 + t[p] - 48) & 0xFFFF
            p += 1
        n -= (n & 0x8000) << 1
        c, x = t[p] & 95, t[p + 1:p + 2] == b'\r'
        if h and t[p] == 13:                        # n: take line n out
            k = find(n)
            if k <= len(lines):
                del lines[k - 1]
        elif c == 73 and x:                         # nI, I
            j = find(n if h else 32767)
            while True:
                out += num(j)
                s = readline(keys, out, 127)
                out += b'\r\n'
                if not s:
                    break
                ok = insert(j, s)
                j += 1
                if not ok:
                    break
        elif c == 76 and x:                         # nL, L
            k = find(n if h else 1)
            for i in range(k - 1, min(k + 19, len(lines))):
                out += num(i + 1) + lines[i]
        elif h:                                     # n text
            insert(n, t[p + 1:-1])
        elif c == 87 and x:                         # W
            disk = write()
        elif c == 81 and x:                         # Q
            out += b'Save first (y/n)? '
            k = keys.pop(0)
            out += bytes([k]) + b'\r\n'
            if k | 32 == 121:
                disk = write()
                break
            if k | 32 == 110:
                break
        elif t[p] != 13:
            out += b'?\r\n'
    if keys:
        raise ValueError('keys left over: %r' % bytes(keys))
    return bytes(out), disk


THREE = b'one\r\ntwo\r\nthree\r\n\x1a'


def many(n, seed):
    """n lines of different lengths, as a text file."""
    r = random.Random(seed)
    return b''.join(b'Line %d %s\r\n' % (i + 1, b'abcdefghij' * r.randrange(8)) for i in range(n))


def fits(more):
    """The biggest file that loads (in whole records of two lines), or one record
    more; and on the first, insert lines until there is no room."""
    def f(room):
        r = (room - 258) // 128 + more
        return (b'%062d\r\n' % 0) * (2 * r)
    return f


LEDIT_CASES = [
    ('list, insert, delete and write', THREE, None, b'L\r2 inserted\r1\rL\r2L\rW\rQ\rn'),
    ('insert mode in the middle and at the end', THREE, None, b'2I\rA\rB\r\rI\rC\r\rL\rQ\ry'),
    ('a new file, saved at quit', None, None, b'I\rfirst\rsecond\r\rQ\ry'),
    ('a new file, not saved', None, None, b'I\rx\r\rQ\rn'),
    ('quit cancelled, then not saved', THREE, None, b'1\rQ\rxL\rQ\rN'),
    ('past the end, line 0, and the separator rule', THREE, None,
     b'99 last\r99\r0 first\r5Lunch\r99L\r1L\rQ\rY'),
    ('lower case, unknown commands and empty lines', THREE, None, b'l\r\rx\r1i\rnew\r\rw\rq\rn'),
    ('a typed line longer than 127 characters', THREE, None, b'1 ' + b'z' * 130 + b'\rL\rQ\rn'),
    ('a ^Z mid-file and no last CR LF', b'abc\r\ndef\x1aghi', None, b'L\rW\rQ\rn'),
    ('a whole record with no last CR LF', b'a' * 60 + b'\r\n' + b'b' * 66, None, b'L\rW\rQ\rn'),
    ('an empty file', b'', None, b'L\r3 only\rW\rQ\rn'),
    ('300 lines: edits across many records', many(300, 4), None,
     b'1 top\r150\r140I\rnew 140\rnew 141\r\r250L\r295L\rW\rQ\rn'),
    ('the name typed at the prompt', THREE, b'a:test.dat', b'L\rQ\rn'),
    ('the most that fits, then out of room', fits(0), None,
     b'I\r' + (b'x' * 100 + b'\r') * 3 + b'\rQ\rn'),
    ('one record too many', fits(1), None, b''),
]

PROGRAMS = [('HEXDUMP', HEXDUMP_CASES, hexdump), ('LEDIT', LEDIT_CASES, ledit)]


def check_ref():
    bad = 0
    for name, _, _ in PROGRAMS:
        for p in (name + '.B8S', name + '.TXT'):
            r = Ref(open(os.path.join(CPM, p), 'rb').read(), b'', checked=True)
            o = r.run(5_000_000)
            ok = o == GUARD
            bad += not ok
            print(f'{"PASS" if ok else "FAIL"}  {p:12} ref.py, checked: the guard  {o[-60:]!r}')
    return bad


def room(base, prog):
    """The memory LEDIT has for its text on this build in the harness: from the
    heap top after its allocations (the heap starts after the NUL that follows
    the program's last record) up to the page of the BDOS."""
    import harness_z80
    start = harness_z80.symbols(base + '.lst')['PROG'] + len(prog) + (-len(prog) % 128) + 1
    return (harness_z80.TRAP & 0xFF00) - (start + LEDIT_HEAP)


def check_builds(out):
    import harness_z80
    bad = 0
    for cpu in ('z80', '8080'):
        for f in sorted(glob.glob(f'{out}/{cpu}/*.hex')):
            base, bname = f[:-4], os.path.basename(f[:-4])
            if '-ed' in bname:                          # the editors run no file
                continue
            cpm = '-cpm' in bname
            fails = []
            for name, cases, model in PROGRAMS:
                for p in (name + '.B8S', name + '.TXT'):
                    prog = open(os.path.join(CPM, p), 'rb').read()
                    for what, data, typed, keys in (cases if cpm else [('the guard', None, None, b'')]):
                        rm = room(base, prog) if name == 'LEDIT' else None
                        if callable(data):
                            data = data(rm)
                        files = {b'PROG    B8S': prog}
                        if data is not None:
                            files[NAME] = data
                        tail = b' PROG.B8S' if typed is not None else b' PROG.B8S TEST.DAT'
                        inp = (typed + b'\r' if typed is not None else b'') + keys
                        r = harness_z80.Run(base + '.hex', base + '.lst', prog, inp, cpu=cpu,
                                            mode='cpm' if cpm else 'generic', files=files, tail=tail,
                                            maxticks=4_000_000_000)
                        got = r.run()
                        if cpm:
                            exp, disk = model(data, keys, typed, rm)
                            want = {b'PROG    B8S': prog, **({NAME: disk} if disk is not None else {})}
                        else:
                            exp, want = GUARD, files
                        if got != exp or r.ended != 'exit' or files != want:
                            d = next((i for i in range(min(len(got), len(exp))) if got[i] != exp[i]),
                                     min(len(got), len(exp)))
                            disk = '' if files == want else ', the disk differs: %r' % {
                                k: v[:40] for k, v in files.items() if k != b'PROG    B8S'}
                            fails.append(f'{p}: {what} (ended {r.ended}, differs at byte {d}: '
                                         f'got {got[d:d + 30]!r}, expected {exp[d:d + 30]!r}{disk})')
            bad += len(fails)
            print(f'{bname:24} {"PASS" if not fails else "FAIL"}', flush=True)
            for x in fails:
                print('   ', x)
    return bad


if __name__ == '__main__':
    bad = check_ref()
    if len(sys.argv) > 1:
        bad += check_builds(sys.argv[1])
    print('cpm:', 'all pass' if not bad else f'{bad} FAILED')
    sys.exit(1 if bad else 0)
