"""Reference B8Script interpreter, written from docs/b8script.md (2026-11-23).

Used only to produce expected output for the test suite. It models memory, the
letter cells (packed layout: A at LET, a at LET+64), the heap pointer and the
random seed (cells of the interpreter's own, in the letter page), the line
buffer, and console input as a byte queue.

The console codes (`@ `^ `_ `?) print what a build with ANSI = 1 sends: the
ANSI sequences. The seed is stirred as the builds stir it under test: a timed
wait that runs out adds its count (one for every millisecond waited), and a
key that is there at once adds nothing.

With checked=True it behaves as a checked build: variables start at 0, words
start undefined, and every error in the spec's table stops the program with
the four-line report (see report() for what the stack lines show).
"""
import sys

CR = 13


class NeedKey(Exception):
    """0? (or a line read) found no more scripted input: the test ends here."""


class Err(Exception):
    """A checked build's error: the letter and the address of the place."""
    def __init__(self, code, place):
        self.code, self.place = code, place


DS_MAX, RS_MAX = 250, 120      # only so that a runaway test ends: the real
                               # sizes differ from build to build


class Ref:
    def __init__(self, prog, inp=b'', prog_at=0x9000, let=0x8000, linebuf=0x8100,
                 heaplim=0xE000, retbyte=0xC9, cpm=False, checked=False, filepad=None,
                 seed=None):
        self.m = bytearray(65536)
        if cpm if filepad is None else filepad:
            # the program is a CP/M file: its last record is padded with ^Z,
            # and the NUL goes after the last record (control characters are
            # ignored, so only the heap's first address and a report's text
            # line can show it)
            prog = prog + b'\x1a' * (-len(prog) % 128)
        self.m[prog_at:prog_at + len(prog)] = prog
        self.m[prog_at + len(prog)] = 0
        self.ip = prog_at
        self.prog_at = prog_at
        self.let = let
        self.lb = linebuf
        self.heaplim = heaplim
        self.retbyte = retbyte
        self.cpm = cpm
        self.checked = checked
        self.heapcell = let + 0x7C
        self.seedcell = let + 0x76 if seed is None else seed   # the random seed: `.
        self.progend = prog_at + len(prog) + 1      # the first byte after the NUL
        self.w(self.heapcell, self.progend)
        self.undef = set(range(0x41, 0x5B)) if checked else set()
        self.at = prog_at                           # where the character being run is
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
        """Step past the closing quote. False if the text ran out first."""
        while True:
            c = self.ch()
            if c == ord('/'):
                c = self.ch()
                if c:
                    continue
            if c == 0:
                return False
            if c == ord('"'):
                return True

    def skip(self, opener):
        """Skip to the closer at this level; return it. Brackets of both kinds
        count together; strings are stepped over whole. opener is the
        character that started the skip: a ( must end at ) and a [ at ], and
        neither may run into the NUL (N, reported at the opener). A \\ takes
        either closer, and with none the program ends."""
        d = 0
        at = self.at
        while True:
            c = self.ch()
            if c == ord('"') and not self.skip_string():
                c = 0
            if c == 0:
                if opener == ord('\\') or not self.checked:
                    raise StopIteration
                raise Err('N', at)
            elif c in b'([':
                d += 1
            elif c in b')]':
                if d == 0:
                    if self.checked and chr(opener) + chr(c) in ('(]', '[)'):
                        raise Err('N', at)
                    return c
                d -= 1

    def key(self):
        if not self.inp:
            raise NeedKey
        return self.inp.pop(0)

    def readline(self, n):
        """-n?: read a line of at most n characters, and 127 at the very most.
        Generic builds: Backspace takes one character back and is echoed as
        it is; every other key but CR is stored and echoed while there is
        room. CP/M builds: BDOS 10 does the editing (Backspace and DEL erase
        with BS, space, BS; other control keys are ignored; a full line ends
        by itself; CR is echoed)."""
        buf = bytearray()
        n = min(n, 127)
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

    def linecol(self, place):
        """The line and column of an address, both from 1. Anything below the
        program text is taken to be in the line buffer: line 0."""
        if place < self.prog_at:
            return 0, ((place - self.lb) & 0xFFFF) + 1
        start = self.prog_at
        line = 1
        for a in range(self.prog_at, place):
            if self.m[a] == 10:
                line += 1
                start = a + 1
        return line, place - start + 1

    def report(self, code, place):
        """The error report. The stack lines show the stacks as they were
        before the failing character ran. Three kinds of error can't do that:
        a stack overrun (S s R r) is found after the character has run; an N
        or a Q from an unclosed string is found after the opener took its
        flag or pushed its address; and a break comes when it comes."""
        o = self.out
        line, col = self.linecol(place)
        o += b'\r\nErr %c @ %d,%d\r\n' % (ord(code), line, col)
        for a in range(place, place + 16):
            if self.m[a & 0xFFFF] in (0, 10, 13) or (self.cpm and self.m[a & 0xFFFF] == 26):
                break
            o.append(self.m[a & 0xFFFF])
        o += b'\r\nStk %d:' % len(self.ds)
        if len(self.ds) > 8:
            o += b' ...'
        for v in self.ds[-8:]:
            o += b' %d' % self.s(v)
        o += b'\r\nRtn %d\r\n' % len(self.rs)

    def run(self, maxsteps=5_000_000):
        self.error = None
        try:
            for _ in range(maxsteps):
                self.at = self.ip
                try:
                    self.step()
                    if self.checked and len(self.ds) > DS_MAX:
                        raise Err('S', self.at)
                    if self.checked and len(self.rs) > RS_MAX:
                        raise Err('R', self.at)
                except IndexError:          # a pop from an empty stack
                    if not self.checked:
                        raise
                    if self.under == 's':
                        self.ds = []
                    else:
                        self.rs = []
                    raise Err(self.under, self.at)
        except (StopIteration, NeedKey):
            pass
        except Err as e:
            self.error = e.code
            self.report(e.code, e.place)
        return bytes(self.out)

    def rpop(self):
        self.under = 'r'
        v = self.rs.pop()
        self.under = 's'
        return v

    def store_ok(self, a, n):
        """May ! or . write n bytes at a? Only inside the program's space."""
        return not self.checked or (self.let <= a and a + n <= self.heaplim)

    def step(self):
        self.under = 's'
        c = self.ch()
        if c == 0:
            raise StopIteration
        if c >= 128 and self.checked:
            raise Err('X', self.at)
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
            if c in self.undef:
                raise Err('U', self.at)
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
            if self.checked and len(self.ds) > 1 and self.ds[-1] == 0:
                raise Err('Z', self.at)
            b = self.s(p()); a = self.s(p())
            if b == 0:
                q, r = 0, a     # undefined in the interpreters: tests must not rely on it
            else:
                q = abs(a) // abs(b)
                if (a < 0) != (b < 0):
                    q = -q
                r = a - q * b
            P(q); P(r)          # ( a b -- q r ): the remainder is on top
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
            P(self.rpop())
        elif C == '@':
            P(self.r(p()))
        elif C == '!':
            if len(self.ds) > 1 and not self.store_ok(self.ds[-1], 2):
                raise Err('O', self.at)
            a = p(); v = p(); self.w(a, v)
        elif C == ',':
            P(self.m[p()])
        elif C == '.':
            if len(self.ds) > 1 and not self.store_ok(self.ds[-1], 1):
                raise Err('O', self.at)
            a = p(); v = p(); self.m[a] = v & 0xFF
        elif C == '_':
            # the count is signed: a negative one releases
            h = self.r(self.heapcell)
            if self.checked and self.ds and not self.progend <= h + self.s(self.ds[-1]) < self.heaplim:
                raise Err('H', self.at)
            n = p()
            P(h); self.w(self.heapcell, h + n)
        elif C == '(':
            if p():
                self.rs.append(self.ip)
            else:
                self.skip(c)
        elif C == ')':
            if p():
                self.under = 'r'
                self.ip = self.rs[-1]
            else:
                self.rpop()
        elif C == '\\':
            if p():
                k = self.skip(c)
                if k == ord(')'):
                    self.rpop()
                else:
                    self.ip = self.rpop()
        elif C == '[':
            n = self.ch()
            if (n | 0x20) in range(0x61, 0x7B):     # an ASCII letter
                self.w(self.cell(n), self.ip)
                self.undef.discard(n)
            elif n != 32 and self.checked:
                raise Err('W', self.ip - 1)         # the place is the bad character
            else:
                P(self.ip)
            self.skip(c)
        elif C == ']':
            self.ip = self.rpop()
        elif C == '"':
            P(self.ip)
            if not self.skip_string():
                if self.checked:
                    raise Err('Q', self.at)
                raise StopIteration
        elif C == '$':
            a = self.ds[-1]
            while True:
                c = self.m[a]; a += 1
                if c == ord('"'):
                    break
                if c == ord('/'):
                    c = self.m[a]; a += 1
                    c &= 0xBF                       # the escape: clear bit 6
                elif c == 0 and self.checked:
                    raise Err('Q', self.at)
                self.emit(c)
            p()
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
                    k = self.inp.pop(0) if self.inp else 0
                    if k == 0:      # the wait ran out: a millisecond stirs the seed by one
                        self.w(self.seedcell, self.r(self.seedcell) + n)
                    P(k)
            else:
                P(self.readline(-n))
        elif C == '`':
            self.grave()

    def grave(self):
        """The grave is a prefix: with the character after it, it is one
        command. A character with no meaning there is unsafe: a checked build
        stops with W at that character, and this model of an unchecked one
        does nothing. The place of any error in a grave command is the
        character after the grave."""
        P, p = self.push, self.pop
        HEX = '0123456789ABCDEFabcdef'
        c = self.m[self.ip]
        C = chr(c)
        if C not in "$!+-@^_?,.'<>":
            if self.checked:
                raise Err('W', self.ip)
            if c:
                self.ip += 1
            return
        self.ip += 1
        if C == '$':                                # the hex loader
            a = p()
            while True:
                h = chr(self.m[self.ip])
                if h not in HEX:
                    break
                self.ip += 1
                l = chr(self.m[self.ip])
                if l not in HEX:
                    break
                self.ip += 1
                self.m[a] = int(h + l, 16); a += 1
            self.m[a] = self.retbyte
            P(a)
        elif C == '!':
            raise RuntimeError('machine code execute: not modelled')
        elif C in '+-':                             # ( addr -- n )
            if self.ds and not self.store_ok(self.ds[-1], 2):
                raise Err('O', self.ip - 1)
            a = p()
            self.w(a, self.r(a) + (1 if C == '+' else -1))
            P(self.r(a))
        elif C == '@':                              # ( row col -- ), from 0
            col = p(); row = p()
            self.out += b'\x1b[%d;%dH' % ((row + 1) & 0xFFFF, (col + 1) & 0xFFFF)
        elif C == '^':
            self.out += b'\x1b[H\x1b[J'
        elif C == '_':
            self.out += b'\x1b[K'
        elif C == '?':                              # ( flag -- )
            self.out += b'\x1b[?25h' if p() else b'\x1b[?25l'
        elif C == ',':                              # ( n -- r ), 0 to n-1
            if self.checked and self.ds and (self.ds[-1] - 1) & 0x8000:
                raise Err('Z', self.ip - 1)
            n = p()
            x = (self.r(self.seedcell) * 261 + 1) & 0xFFFF
            self.w(self.seedcell, x)
            x ^= x >> 8
            P(x % n if n else 0)                    # 0: undefined in the interpreters
        elif C == '.':
            P(self.seedcell)
        elif C == "'":
            self.out += b'\r\n'
        elif C in '<>':                             # min, max
            b = self.s(p()); a = self.s(p())
            P(min(a, b) if C == '<' else max(a, b))


def run(prog, inp=b'', **kw):
    return Ref(prog, inp, **kw).run()


if __name__ == '__main__':
    src = open(sys.argv[1], 'rb').read()
    inp = sys.argv[2].encode().decode('unicode_escape').encode('latin-1') if len(sys.argv) > 2 else b''
    sys.stdout.buffer.write(run(src, inp))
