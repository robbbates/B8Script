"""Run the CP/M builds under real CP/M 2.2, in z80pack's cpmsim, through a pty.

The harnesses here model the BDOS by hand; this runs Digital Research's own
BDOS and CCP, on a Z80 that traps undocumented opcodes (-u) or on an 8080
(-8), so it catches what the models can't.

Needs: z80pack built (https://github.com/udo-munk/z80pack: make in
z80pack/cpmsim/srcsim), with its cpm22 disks in cpmsim/disks/library, and
cpmtools (apt-get install cpmtools). Set Z80PACK to the z80pack folder.

  python3 cpmsim.py suite [-8] OUTDIR BUILD...   e.g. suite out B8S B8SU
      every program of the suite (but those that need a clock or another
      CPU's machine code) under the named .COM files, each output compared
      byte for byte with ref.py. Keys are typed as a person types them.
  python3 cpmsim.py type [-8] OUTDIR STEP...
      type at CP/M: a STEP is text (\\r for Return, \\x03 for Ctrl-C),
      'wait:SECONDS' or 'expect:TEXT'. Prints all the output.

The .COM files go on drive B, the test programs on drive C (8-inch disks,
64 files each); the run starts at C>. Drive A is the CP/M boot disk, copied
fresh from the library each time.
"""
import os, pty, select, sys, time, subprocess, shutil
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ZP = os.path.join(os.environ.get('Z80PACK', os.path.join(HERE, 'z80pack')), 'cpmsim')
SIM = os.path.join(ZP, 'cpmsim')
FMT = 'ibm-3740'


def coms(cpu8):
    """One CPU's CP/M builds, by the names they are released under: B8S (base,
    checked), B8SU (unchecked), B8SE and B8SEU (with the editor), and the
    same with S for the small builds and F for the fast ones."""
    cpu = '8080' if cpu8 else 'z80'
    d = {}
    for t, tier in (('S', 'small'), ('', 'base'), ('F', 'fast')):
        for e, kind in (('', 'cpm'), ('E', 'cpm-ed')):
            d[f'B8S{t}{e}'] = f'{cpu}/b8s-{cpu}-{tier}-{kind}-chk'
            d[f'B8S{t}{e}U'] = f'{cpu}/b8s-{cpu}-{tier}-{kind}'
    return d


def hex2com(hexf):
    mem = {}
    for line in open(hexf):
        line = line.strip()
        if line.startswith(':'):
            b = bytes.fromhex(line[1:])
            if b[3] == 0:
                a = b[1] << 8 | b[2]
                for i in range(b[0]):
                    mem[a + i] = b[4 + i]
    assert min(mem) == 0x100
    return bytes(mem.get(a, 0) for a in range(0x100, max(mem) + 1))


def blank(name):
    d = os.path.join(ZP, 'disks', name)
    open(d, 'wb').write(b'\xe5' * 256256)     # an empty 8-inch disk: all E5h
    return d


def put(disk, name, data):
    tmp = os.path.join(ZP, 'disks', '_put.tmp')
    open(tmp, 'wb').write(data)
    subprocess.run(['cpmcp', '-f', FMT, disk, tmp, '0:' + name], check=True)
    os.remove(tmp)


def setup(outdir, cpu8):
    shutil.copy(os.path.join(ZP, 'disks', 'library', 'cpm22-1.dsk'), os.path.join(ZP, 'disks', 'drivea.dsk'))
    b = blank('driveb.dsk')
    for com, base in coms(cpu8).items():
        hexf = os.path.join(outdir, base + '.hex')
        if os.path.exists(hexf):
            put(b, com + '.COM', hex2com(hexf))
    return blank('drivec.dsk')


class Sim:
    def __init__(self, cpu8):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(ZP)
            os.execv(SIM, [SIM, '-8' if cpu8 else '-z', '-u'])
        self.out = bytearray()
        self.until(b'A>', 30)
        self.type(b'C:\r')
        self.until(b'C>', 10)

    def pump(self, t):
        r, _, _ = select.select([self.fd], [], [], t)
        if r:
            try:
                d = os.read(self.fd, 65536)
            except OSError:
                return False
            self.out.extend(d)
            return bool(d)
        return True

    def until(self, pat, t, start=0):
        end = time.time() + t
        while time.time() < end:
            if pat in self.out[start:]:
                return True
            if not self.pump(0.05):
                return False
        return False

    def type(self, b):
        for c in b:
            os.write(self.fd, bytes([c]))
            self.pump(0.01)

    def close(self):
        try:
            os.kill(self.pid, 9)
        except OSError:
            pass


def suite(outdir, builds, cpu8):
    from ref import Ref
    from tests import SUITE, CHK, LOOSE
    skip = {'keyt', 'mcdouble'}      # a clock the emulator runs flat out; Z80 machine code
    progs = [t for t in SUITE + CHK + LOOSE if t[0] not in skip]
    c = setup(outdir, cpu8)
    names = {}
    for k, (n, p, i) in enumerate(progs):
        names[n] = 'T%02d.B8S' % k
        put(c, names[n], p)
    fails = 0
    for b in builds:
        checked = not b.endswith('U')
        sim, bad, ran = Sim(cpu8), [], 0
        for n, p, i in progs:
            if (n, p, i) in CHK and not checked or (n, p, i) in LOOSE and checked:
                continue
            ran += 1
            sim.out = bytearray()
            sim.type(b'B:%s %s\r' % (b.encode(), names[n].encode()))
            sim.until(b'\r\n', 5)
            start = sim.out.index(b'\r\n') + 2
            time.sleep(0.3)
            for ch in i:
                sim.type(bytes([ch]))
                time.sleep(0.05)
            ok = sim.until(b'\r\nC>', 30, start) or sim.until(b'C>', 1, start)
            got = bytes(sim.out[start:])
            got = got[:got.rfind(b'C>')] if ok else got
            exp = Ref(p, i, cpm=True, checked=checked).run(50_000_000)
            g = got[:-2] if got.endswith(b'\r\n') else got    # the CCP's new line
            if not ok:
                bad.append((n, 'HUNG', got[-80:]))
                sim.close()
                sim = Sim(cpu8)
            elif g != exp and got != exp:
                bad.append((n, g[-120:], exp[-120:]))
        sim.close()
        print(f'{b}{" (8080)" if cpu8 else ""}: {ran} programs, {len(bad)} differ')
        for x in bad:
            print('   ', x)
        fails += len(bad)
    return fails


def type_steps(outdir, steps, cpu8):
    setup(outdir, cpu8)
    sim = Sim(cpu8)
    mark = len(sim.out)
    for s in steps:
        if s.startswith('wait:'):
            end = time.time() + float(s[5:])
            while time.time() < end and sim.pump(0.05):
                pass
        elif s.startswith('expect:'):
            if sim.until(s[7:].encode(), 30, mark):
                mark = sim.out.index(s[7:].encode(), mark) + len(s[7:])
            else:
                sim.out.extend(b'\n[[TIMEOUT waiting for %s]]\n' % s[7:].encode())
        else:
            sim.type(s.encode().decode('unicode_escape').encode('latin-1'))
    sim.pump(1.0)
    sim.close()
    sys.stdout.write(repr(bytes(sim.out))[2:-1].replace('\\r\\n', '\n') + '\n')


if __name__ == '__main__':
    a = sys.argv[1:]
    cpu8 = '-8' in a
    a = [x for x in a if x != '-8']
    if len(a) < 2 or a[0] not in ('suite', 'type'):
        sys.exit(__doc__)
    if a[0] == 'suite':
        sys.exit(1 if suite(a[1], a[2:], cpu8) else 0)
    type_steps(a[1], a[2:], cpu8)
