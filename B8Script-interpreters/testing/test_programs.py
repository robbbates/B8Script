"""Tests for the programs in programs/ that are not Tiny BASIC: SIEVE, PI, MANDEL, MON.

usage: test_programs.py            check them on ref.py
       test_programs.py OUT        and on every build in OUT (as built by build.sh)

ref.py's output is checked against models written here in Python: SIEVE's count of
1899, PI's digits (themselves checked against Machin's formula), MANDEL's picture
with the same 16-bit arithmetic, MON's lines. Then every build must print what
ref.py prints. MON's start-up line names the heap top, which differs between
builds, so its first line is left out; its R command runs one RET of the build's
CPU, which ref.py can't, so that part is checked by the build alone."""
import re, sys, os, glob
here = os.path.dirname(os.path.abspath(__file__))
PROGS = os.path.normpath(os.path.join(here, '..', '..', 'programs'))
sys.path.insert(0, here)
from ref import Ref


def tdiv(a, b):                         # '/' truncates toward zero
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def pi_digits(n):
    """The spigot of Rabinowitz and Wagon, as PI.TXT does it."""
    L = n * 10 // 3 + 1
    a = [2] * L
    out = []; nines = 0; pre = -1
    for _ in range(n):
        q = 0
        for i in range(L, 0, -1):
            x = 10 * a[i - 1] + q * i
            assert x < 32768                # it must fit in a cell
            a[i - 1] = x % (2 * i - 1)
            q = x // (2 * i - 1)
        a[0] = q % 10; q //= 10
        if q == 9:
            nines += 1
        elif q == 10:
            out.append(pre + 1); out += [0] * nines; pre = 0; nines = 0
        else:
            if pre >= 0:
                out.append(pre)
            pre = q
            out += [9] * nines; nines = 0
    out.append(pre)
    return ''.join(map(str, out))


def machin(n):
    s = 10 ** (n + 10)
    def at(x):
        t = s // x; r = t; k = 1; sg = -1
        while t:
            t //= x * x; r += sg * (t // (2 * k + 1)); sg = -sg; k += 1
        return r
    return str(4 * (4 * at(5) - at(239)))[:n]


def pi_text(n):
    d = pi_digits(n + 5)[:n]
    assert d == machin(n)
    out = ''
    for c, ch in enumerate(d):
        if c > 1 and (c - 1) % 10 == 0:
            out += '\r\n  ' if (c - 1) % 50 == 0 else ' '
        out += ch + ('.' if c == 0 else '')
    return (out + '\r\n').encode()


def mandel_text():
    shades = '  .,:;-~=+*xo%#&@'
    out = ''
    for r in range(22):
        v = r * 7 - 77
        for c in range(78):
            u = tdiv(c * 5, 2) - 141
            x = y = k = 0
            while True:
                if ((x + 128) & 32767) >= 257 or ((y + 128) & 32767) >= 257:
                    break
                a = tdiv(x * x, 64); b = tdiv(y * y, 64)
                if a + b > 256:
                    break
                y = tdiv(x * y, 32) + v; x = a - b + u; k += 1
                if k >= 16:
                    break
            out += shades[k]
        out += '\r\n'
    return out.encode()


# MON: bytes stored, shown, a range of them last (a key stops a range, so nothing
# may follow it), all at C000h, which is free memory on every build.
MON_IN = (b'C000: 48 49 0D ff 7e 41 00 01 02 03 04 05\r'
          b': 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11\r: 20 21 22 23 24 25 26 27 28 29 2A 2B\r'
          b'C000\r\r?\rc002.c005\rC000.C021\r')
MON_OUT = [b'*C000: 48 49 0D ff 7e 41 00 01 02 03 04 05', b'*: 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11',
           b'*: 20 21 22 23 24 25 26 27 28 29 2A 2B', b'*C000',
           b'C000: 48 49 0D FF 7E 41 00 01 02 03 04 05 06 07 08 09  HI..~A..........',
           b'*', b'C010: 0A 0B 0C 0D 0E 0F 10 11 20 21 22 23 24 25 26 27  ........ !"#$%&\'',
           b'*?', b'  XXXX  XXXX.YYYY  XXXX: hh hh  : hh  XXXXR  Return: next 16  Q: quit',
           b'*c002.c005', b'C002: 0D FF 7E 41                                      ..~A',
           b'*C000.C021', b'C000: 48 49 0D FF 7E 41 00 01 02 03 04 05 06 07 08 09  HI..~A..........',
           b'C010: 0A 0B 0C 0D 0E 0F 10 11 20 21 22 23 24 25 26 27  ........ !"#$%&\'',
           b'C020: 28 29                                            ()', b'*']

RUNS = [('SIEVE.B8S', b'1\r'), ('PI.B8S', b'60\r'), ('MANDEL.B8S', b''), ('MON.B8S', MON_IN)]


def prog(name):
    return open(os.path.join(PROGS, name), 'rb').read()


def check_ref():
    bad = 0
    def ok(what, cond):
        nonlocal bad
        bad += not cond
        print(f'{"PASS" if cond else "FAIL"}  {what}')
    o = Ref(prog('SIEVE.B8S'), b'2\r').run(50_000_000)
    ok('SIEVE  two passes, 1899 primes', o.endswith(b'Passes? 2\r\n..\r\n1899 primes\r\n'))
    for n in (1, 7, 50, 250):
        o = Ref(prog('PI.B8S'), b'%d\r' % n).run(400_000_000)
        ok(f'PI     {n} digits', o.split(b'\r\n', 1)[1] == pi_text(n))
    o = Ref(prog('PI.B8S'), b'999\r').run(400_000_000)
    ok('PI     999 is taken as 250', o.split(b'\r\n', 1)[1] == pi_text(250))
    ok('MANDEL the picture', Ref(prog('MANDEL.B8S'), b'').run(100_000_000) == mandel_text())
    o = Ref(prog('MON.B8S'), MON_IN).run(50_000_000).split(b'\r\n')
    ok('MON    store, show, help, ranges', o[2:] == MON_OUT)
    o = Ref(prog('MON.B8S'), b'q\r').run(5_000_000)
    ok('MON    Q quits', o.endswith(b'*q\r\n'))
    return bad


def runner(cpu, base, cpm):
    ret = {'6502': 0x60, '6809': 0x39, 'win32': 0xC3}.get(cpu, 0xC9)
    def run(p, inp):
        if cpu in ('z80', '8080'):
            r = harness_z80.Run(base + '.hex', base + '.lst', p, inp, cpu=cpu, mode='cpm' if cpm else 'generic',
                                maxticks=20_000_000_000)
        elif cpu == '6502':
            r = harness_6502.Run(base + '.hex', base + '.lst', p, inp, maxsteps=400_000_000)
        elif cpu == '6809':
            r = harness_6809.Run(base + '.hex', base + '.lst', p, inp, maxops=400_000_000)
        else:
            r = harness_win32.Run(base + '.EXE', p, inp, maxinstr=4_000_000_000)
        return r.run()
    return run, ret


def check_builds(out):
    global harness_z80, harness_6502, harness_6809, harness_win32
    import harness_z80, harness_6502, harness_6809, harness_win32
    bad = 0
    for cpu in ('z80', '8080', '6502', '6809', 'win32'):
        for f in sorted(glob.glob(f'{out}/{cpu}/*.hex') + glob.glob(f'{out}/{cpu}/*.EXE')):
            base, name = f[:-4], os.path.basename(f[:-4])
            if '-ed' in name or re.fullmatch(r'B8S[SF]?EU?', name):      # the editors run no file
                continue
            cpm = '-cpm' in name
            run, ret = runner(cpu, base, cpm)
            fails = []
            for p, inp in RUNS:
                exp = Ref(prog(p), inp, cpm=cpm).run(400_000_000)
                got = run(prog(p), inp)
                if p == 'MON.B8S':
                    exp, got = exp.split(b'\r\n', 1)[1], got.split(b'\r\n', 1)[1]
                if got != exp:
                    fails.append(p)
            # R: one RET, then the monitor goes on
            got = run(prog('MON.B8S'), b'C000: %02X\rC000R\rC000\r' % ret)
            if b'*C000R\r\n*C000\r\nC000: %02X' % ret not in got:
                fails.append('MON R')
            bad += len(fails)
            print(f'{name:24} {"PASS" if not fails else "FAIL: " + ", ".join(fails)}', flush=True)
    return bad


if __name__ == '__main__':
    bad = check_ref()
    if len(sys.argv) > 1:
        bad += check_builds(sys.argv[1])
    print('programs:', 'all pass' if not bad else f'{bad} FAILED')
    sys.exit(1 if bad else 0)
