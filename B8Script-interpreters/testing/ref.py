"""Reference B8Script interpreter (spec of 2026-10-09 plus the 2026-11-20 changes,
including '/' as the string escape and ( a b -- r q ) for the divide).

Used only to produce expected output for the test suite. It models memory, the
letter cells (packed layout: A at LET, a at LET+64, heap pointer at z+10), the
line buffer, and console input as a byte queue.
"""
import sys

CR = 13


class NeedKey(Exception):
    """0? (or a line read) found no more scripted input: the test ends here."""


class Ref:
    def __init__(self, prog, inp=b'', prog_at=0x9000, let=0x8000, linebuf=0x8100,
                 heaplim=0xE000, retbyte=0xC9, cpm=False):
        self.m = bytearray(65536)
        self.m[prog_at:prog_at + len(prog)] = prog
        self.m[prog_at + len(prog)] = 0
        self.ip = prog_at
        self.prog_at = prog_at
        self.let = let
        self.lb = linebuf
        self.heaplim = heaplim
        self.retbyte = retbyte
        self.cpm = cpm
        self.heapcell = let + 2 * (ord('z') - 0x41) + 10
        self.w(self.heapcell, prog_at + len(prog) + 1)
        self.ds = []
        self.rs = []
        self.inp = list(inp)
        self.out = bytearray()

    # memory
    def w(self, a, v):
        self.m[a & 0xFFFF] = v & 0xFF
        self.m[(a + 1) & 0xFFFF] = (v >> 8) & 0xFF

    def r(self, a):
        return self.m[a & 0xFFFF] | (self.m[(a + 1) & 0xFFFF] << 8)

    def cell(self, c):
        return self.let + 2 * (c - 0x41)

    # stacks
    def push(self, v):
        self.ds.append(v & 0xFFFF)

    def pop(self):
        return self.ds.pop()

    @staticmethod
    def s(v):
        return v - 0x10000 if v & 0x8000 else v

    def ch(self):
        c = self.m[self.ip]
        self.ip = (self.ip + 1) & 0xFFFF
        return c

    def emit(self, c):
        self.out.append(c & 0xFF)

    def skip_string(self):
        while True:
            c = self.ch()
            if c == 0:
                raise StopIteration
            if c == ord('/'):
                self.ch()
            elif c == ord('"'):
                return

    def skip(self):
        """Skip to the closer at this level; return it. Brackets of both kinds
        count together; strings are stepped over whole."""
        d = 0
        while True:
            c = self.ch()
            if c == 0:
                raise StopIteration
            if c == ord('"'):
                self.skip_string()
            elif c in b'([':
                d += 1
            elif c in b')]':
                if d == 0:
                    return c
                d -= 1

    def key(self):
        if not self.inp:
            raise NeedKey
        return self.inp.pop(0)

    def readline(self, n):
        """-n?: read a line of at most n characters; n is not checked.
        Generic builds: Backspace takes one character back and is echoed as
        it is; every other key but CR is stored and echoed while there is
        room. CP/M builds: BDOS 10 does the editing (Backspace and DEL erase
        with BS, space, BS; other control keys are ignored; a full line ends
        by itself; CR is echoed)."""
        buf = bytearray()
        while True:
            c = self.key()
            if c == CR:
                break
            if self.cpm:
                if c in (8, 127):
                    if buf:
                        buf.pop()
                        self.out += b'\x08 \x08'
                elif c >= 32:
                    buf.append(c)
                    self.emit(c)
                    if len(buf) == n:   # BDOS 10 ends a full line by itself
                        break
            elif c == 8:
                if buf:
                    buf.pop()
                    self.emit(8)
            elif len(buf) < n:
                buf.append(c)
                self.emit(c)
        if self.cpm:
            self.emit(CR)
        buf.append(CR)
        self.m[self.lb:self.lb + len(buf)] = buf
        return self.lb

    def pnum(self, v):
        self.out += str(self.s(v)).encode()

    def run(self, maxsteps=5_000_000):
        try:
            for _ in range(maxsteps):
                self.step()
        except (StopIteration, NeedKey):
            pass
        return bytes(self.out)

    def step(self):
        c = self.ch()
        if c == 0:
            raise StopIteration
        if c <= 32 or c >= 127:
            return
        C = chr(c)
        if C.isdigit() or (C == '-' and chr(self.m[self.ip]).isdigit()):
            neg = C == '-'
            if neg:
                c = self.ch()
            v = 0
            while True:
                v = v * 10 + c - 48
                if not chr(self.m[self.ip]).isdigit():
                    break
                c = self.ch()
            self.push(-v if neg else v)
            return
        if 'A' <= C <= 'Z':
            self.rs.append(self.ip)
            self.ip = self.r(self.cell(c))
            return
        if 'a' <= C <= 'z':
            self.push(self.cell(c))
            return
        P, p = self.push, self.pop
        if C == '+':
            b = p(); a = p(); P(a + b)
        elif C == '-':
            b = p(); a = p(); P(a - b)
        elif C == '*':
            b = p(); a = p(); P(a * b)
        elif C == '/':
            b = self.s(p()); a = self.s(p())
            if b == 0:
                q, r = 0, a     # undefined in the interpreters: tests must not rely on it
            else:
                q = abs(a) // abs(b)
                if (a < 0) != (b < 0):
                    q = -q
                r = a - q * b
            P(r); P(q)          # ( a b -- r q ): the quotient is on top
        elif C == '&':
            b = p(); a = p(); P(a & b)
        elif C == '|':
            b = p(); a = p(); P(a | b)
        elif C == '^':
            b = p(); a = p(); P(a ^ b)
        elif C == '~':
            P(~p())
        elif C in '<=>':
            b = self.s(p()); a = self.s(p())
            P(-1 if {'<': a < b, '=': a == b, '>': a > b}[C] else 0)
        elif C == ':':
            a = p(); P(a); P(a)
        elif C == ';':
            p()
        elif C == '%':
            b = p(); a = p(); P(b); P(a)
        elif C == '{':
            self.rs.append(p())
        elif C == '}':
            P(self.rs.pop())
        elif C == '@':
            P(self.r(p()))
        elif C == '!':
            a = p(); v = p(); self.w(a, v)
        elif C == ',':
            P(self.m[p()])
        elif C == '.':
            a = p(); v = p(); self.m[a] = v & 0xFF
        elif C == '_':
            n = p(); h = self.r(self.heapcell)
            P(h); self.w(self.heapcell, h + n)
        elif C == '(':
            if p():
                self.rs.append(self.ip)
            else:
                self.skip()
        elif C == ')':
            if p():
                self.ip = self.rs[-1]
            else:
                self.rs.pop()
        elif C == '\\':
            if p():
                k = self.skip()
                if k == ord(')'):
                    self.rs.pop()
                else:
                    self.ip = self.rs.pop()
        elif C == '[':
            n = self.ch()
            if chr(n).isalpha():
                self.w(self.cell(n), self.ip)
            else:
                P(self.ip)
            self.skip()
        elif C == ']':
            self.ip = self.rs.pop()
        elif C == '"':
            P(self.ip)
            self.skip_string()
        elif C == '$':
            a = p()
            while True:
                c = self.m[a]; a += 1
                if c == ord('"'):
                    break
                if c == ord('/'):
                    c = self.m[a]; a += 1
                    if c >= 0x40:
                        c &= 0xBF
                self.emit(c)
        elif C == "'":
            self.emit(p())
        elif C == '#':
            self.pnum(p())
        elif C == '?':
            n = self.s(p())
            if n >= 0:
                if n == 0:
                    P(self.key())
                else:
                    P(self.inp.pop(0) if self.inp else 0)
            else:
                P(self.readline(-n))
        elif C == '`':
            nx = chr(self.m[self.ip])
            if nx in '0123456789ABCDEFabcdef':
                a = p()
                while True:
                    h = chr(self.m[self.ip])
                    if h not in '0123456789ABCDEFabcdef':
                        break
                    self.ip += 1
                    l = chr(self.m[self.ip])
                    if l not in '0123456789ABCDEFabcdef':
                        break
                    self.ip += 1
                    self.m[a] = int(h + l, 16); a += 1
                self.m[a] = self.retbyte
                P(a)
            else:
                raise RuntimeError('machine code execute: not modelled')


def run(prog, inp=b'', **kw):
    return Ref(prog, inp, **kw).run()


if __name__ == '__main__':
    src = open(sys.argv[1], 'rb').read()
    inp = sys.argv[2].encode().decode('unicode_escape').encode('latin-1') if len(sys.argv) > 2 else b''
    sys.stdout.buffer.write(run(src, inp))
