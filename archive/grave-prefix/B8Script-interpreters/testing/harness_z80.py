"""Run a Z80 or 8080 B8Script build in an emulator.

generic: the image is ROM at 0000h, the program text is loaded at PROG (taken
from the listing) and NUL-terminated, and KEY/CONOUT/EXIT are traps. KEY
returns a waiting key in A, or 0, with the zero flag matching A. A build with
ANSI = 0 also has CONAT, CONCLS, CONEOL and CONCUR, which are traps too.
cpm: the image is a .COM at 0100h; BDOS 6, 10, 15, 16, 19, 20, 21, 22 and
26 are emulated. `files` is the disk: a dict of 11-character names (as in an
FCB) to contents, and it holds what the build wrote when the run is over.
If it is not given, the program is the one file on it, PROG.B8S, which is
the name on the command line.
editor: a generic image built with EDITOR = 1. No program is loaded (the RAM
at PROG starts as junk, as after power-on) and everything goes in through
KEY. The run ends as 'exit' when the editor is left (LEAVE).
cpm-editor: a .COM built with EDITOR = 1; the program is the file it loads.
In both editor modes the input is a list of chunks: the next chunk is typed
only when the machine has been left waiting for a key, as a person would, and
the run ends when it waits with no chunks left.

Keys are typed as a person types them: only when the program is waiting for
one. Every build looks at the keyboard now and then for the break key, and a
key it finds then is held, the newest winning (the spec); a queue of keys
handed over as fast as they are read would mostly be lost. So a key from the
input is given only when the machine asks twice within GAP clock ticks, which
is a program sitting in a key loop ('?', a line read, the editor), not the
break check, whose looks are far apart. Keys to be pressed while the program
is busy are given at once: `brk_at` presses Ctrl-C, and `timed` is a list of
(n, keys): the keys are pressed once n characters have been printed.
BDOS 10 is modelled as CP/M does it: Ctrl-C as the first key of a line is a
warm boot.
"""
import re
import z80

# A build with ANSI = 0 calls four routines of the machine's for the console
# codes. The machine here answers each by printing what a build with ANSI = 1
# sends, so the output of the two can be compared with the same tests.
CONHOOKS = ('CONAT', 'CONCLS', 'CONEOL', 'CONCUR')
CONCLS, CONEOL = b'\x1b[H\x1b[J', b'\x1b[K'


def conat(row, col):
    return b'\x1b[%d;%dH' % ((row + 1) & 0xFFFF, (col + 1) & 0xFFFF)


def concur(on):
    return b'\x1b[?25h' if on else b'\x1b[?25l'


TRAP = 0xFFF0          # BDOS lives here in the cpm runs
WBOOT = 0xFFE0
IDLE = 20000         # empty KEY polls in a row before a run counts as waiting for input
GAP = 3000           # clock ticks: two looks at the keyboard closer than this are a key loop


def load_hex(path):
    mem = {}
    for line in open(path):
        line = line.strip()
        if not line.startswith(':'):
            continue
        b = bytes.fromhex(line[1:])
        n, addr, typ = b[0], (b[1] << 8) | b[2], b[3]
        if typ == 0:
            for i in range(n):
                mem[addr + i] = b[4 + i]
    lo, hi = min(mem), max(mem)
    img = bytearray(hi - lo + 1)
    for a, v in mem.items():
        img[a - lo] = v
    return lo, bytes(img)


def symbols(lst):
    sy = {}
    for line in open(lst):
        m = re.match(r'^([A-Z_0-9.]+):\s+([0-9A-F]{4}) DEFINED', line)
        if m:
            sy[m.group(1)] = int(m.group(2), 16)
    return sy


def plat(lst, cpm=False):
    """A build's own addresses, for ref.py: where the program text, the
    letter cells and the line buffer are, and the heap limit. (In the CP/M
    runs the limit is the page of the BDOS entry, which is TRAP here.)"""
    sy = symbols(lst)
    return dict(prog_at=sy['PROG'], let=sy['LET'], linebuf=sy['LINEBUF'],
                heaplim=(TRAP & 0xFF00) if cpm else sy['HEAPLIM'] << 8, seed=sy['SEED'])


class Run:
    def __init__(self, hexf, lst, prog, inp=b'', cpu='z80', mode='generic',
                 maxticks=4_000_000_000, brk_at=None, timed=(), files=None):
        self.m = z80.I8080Machine() if cpu == '8080' else z80.Z80Machine()
        self.sy = symbols(lst)
        org, img = load_hex(hexf)
        self.img_size = len(img)
        self.m.set_memory_block(org, img)
        self.stages = []
        if mode in ('editor', 'cpm-editor'):
            self.stages, inp = [bytes(c) for c in inp], b''
            self.mode = mode = 'editor' if mode == 'editor' else 'cpm'
        self.timed = list(timed)
        self.now = 0           # clock ticks so far
        self.last_look = -GAP  # when the keyboard was last looked at
        self.pressed = []      # keys pressed while the program is busy: given at once
        self.looks = 0         # how many times the keyboard was looked at
        self.inp = list(inp)
        self.out = bytearray()
        self.mode = mode
        self.prog = prog
        self.maxticks = maxticks
        self.ended = None
        self.brk_at = brk_at   # inject Ctrl-C once the output reaches this many bytes
        self.idle = 0          # empty key polls in a row (CP/M runs)
        if mode == 'generic':
            p = self.sy['PROG']
            self.m.set_memory_block(p, prog + b'\0')
            for k in ('KEY', 'CONOUT', 'EXIT') + CONHOOKS:
                if k in self.sy:
                    self.m.set_breakpoint(self.sy[k])
            self.m.pc = 0
        elif mode == 'editor':
            self.m.set_memory_block(self.sy['PROG'], b'\xAA' * 2048)
            for k in ('KEY', 'CONOUT', 'LEAVE') + CONHOOKS:
                if k in self.sy:
                    self.m.set_breakpoint(self.sy[k])
            self.m.pc = 0
        else:
            # page zero: JP WBOOT at 0, JP BDOS at 5
            self.m.set_memory_block(0, bytes([0xC3, WBOOT & 255, WBOOT >> 8, 0, 0,
                                              0xC3, TRAP & 255, TRAP >> 8]))
            self.m.set_breakpoint(TRAP)
            self.m.set_breakpoint(WBOOT)
            fcb = bytearray(36)
            fcb[1:12] = b'PROG    B8S'
            self.m.set_memory_block(0x5C, bytes(fcb))
            self.files = {b'PROG    B8S': prog} if files is None else files
            self.cur = None        # the file that is open
            self.fpos = 0
            self.dma = 0x80
            self.m.sp = 0xFF00
            self.m.pc = 0x100

    def mem(self, a):
        return self.m.memory[a & 0xFFFF]

    def ret(self):
        sp = self.m.sp
        self.m.pc = self.mem(sp) | (self.mem(sp + 1) << 8)
        self.m.sp = (sp + 2) & 0xFFFF

    def key(self):
        """The key that a look at the keyboard finds now, or 0."""
        self.looks += 1
        if self.brk_at is not None and len(self.out) >= self.brk_at:
            self.pressed.append(3)
            self.brk_at = None
        while self.timed and len(self.out) >= self.timed[0][0]:
            k = self.timed.pop(0)[1]
            self.pressed += list(k) if isinstance(k, (bytes, list, tuple)) else [k]
        waiting = self.now - self.last_look < GAP
        self.last_look = self.now
        if self.pressed:
            return self.pressed.pop(0)
        if self.inp and waiting:
            return self.inp.pop(0)
        return 0

    def key_ready(self):
        """For the line reader of BDOS 10, which waits for its keys."""
        if self.pressed:
            self.inp.insert(0, self.pressed.pop(0))
        return bool(self.inp)

    def run(self):
        m = self.m
        total = 0
        idle = 0
        while True:
            m.ticks_to_stop = 20_000_000
            m.run()
            total += 20_000_000 - m.ticks_to_stop
            self.now = total
            if total > self.maxticks:
                self.ended = 'timeout'
                break
            pc = m.pc
            if self.mode in ('generic', 'editor'):
                sy = self.sy
                if pc == sy['CONOUT']:
                    self.out.append(m.a); idle = 0; self.ret()
                elif pc == sy['KEY']:
                    m.a = self.key()
                    if m.a:
                        idle = 0
                    elif self.inp:
                        pass                    # the key comes at the next look
                    else:
                        # a program polling for a key that will never come
                        idle += 1
                        if idle > IDLE and self.stages:
                            self.inp = list(self.stages.pop(0)); idle = 0
                        elif idle > IDLE:
                            self.ended = 'needkey'; break
                    # the host routine's contract: Z (and S) follow A
                    m.f = (m.f & 0x3F) | (0x40 if m.a == 0 else 0) | (m.a & 0x80)
                    self.ret()
                elif pc == (sy['EXIT'] if self.mode == 'generic' else sy.get('LEAVE')):
                    self.ended = 'exit'; break
                elif pc == sy.get('CONAT'):         # row in DE, column in HL
                    self.out += conat(m.de, m.hl); idle = 0; self.ret()
                elif pc == sy.get('CONCLS'):
                    self.out += CONCLS; idle = 0; self.ret()
                elif pc == sy.get('CONEOL'):
                    self.out += CONEOL; idle = 0; self.ret()
                elif pc == sy.get('CONCUR'):        # off if A = 0
                    self.out += concur(m.a); idle = 0; self.ret()
                # anything else: the tick budget ran out; carry on
            else:
                if pc == WBOOT:
                    self.ended = 'exit'; break
                if pc != TRAP:
                    continue
                if not self.bdos():
                    break
                self.ret()
        return bytes(self.out)

    def bdos(self):
        m = self.m
        f = m.c
        if f == 6:
            if m.e == 0xFF:
                m.a = self.key()
                if m.a:
                    self.idle = 0
                elif self.inp:
                    pass                        # the key comes at the next look
                else:
                    # a program polling for a key that will never come
                    self.idle += 1
                    if self.idle > IDLE and self.stages:
                        self.inp = list(self.stages.pop(0)); self.idle = 0
                    elif self.idle > IDLE:
                        self.ended = 'needkey'; return False
            else:
                self.out.append(m.e); self.idle = 0
        elif f == 10:
            de = m.de
            mx = self.mem(de)
            buf = bytearray()
            while True:
                if not self.key_ready():
                    if not self.stages:
                        self.ended = 'needkey'; return False
                    self.inp = list(self.stages.pop(0))
                    continue
                c = self.inp.pop(0)
                if c == 3 and not buf:
                    self.ended = 'exit'; return False
                if c in (13, 10):
                    break
                if c in (8, 127):
                    if buf:
                        buf.pop(); self.out += b'\x08 \x08'
                elif c >= 32:
                    buf.append(c); self.out.append(c)
                    if len(buf) == mx:
                        break
            self.out.append(13)
            m.set_memory_block(de + 1, bytes([len(buf)]) + bytes(buf))
        elif f in (15, 19, 22):                 # open, delete, make
            name = bytes(self.mem(m.de + 1 + i) for i in range(11))
            if f == 22:
                self.files[name] = b''
            found = name in self.files
            if f == 19:
                self.files.pop(name, None)
            self.cur, self.fpos = (name if found and f != 19 else None), 0
            m.a = 0 if found else 0xFF
        elif f == 16:                           # close
            m.a = 0
        elif f == 26:
            self.dma = m.de
        elif f == 20:                           # read a record
            file = self.files.get(self.cur, b'')
            if self.fpos >= len(file):
                m.a = 1
            else:
                rec = file[self.fpos:self.fpos + 128]
                rec = rec + b'\x1a' * (128 - len(rec))
                m.set_memory_block(self.dma, rec)
                self.fpos += 128
                m.a = 0
        elif f == 21:                           # write a record
            self.files[self.cur] += bytes(self.mem(self.dma + i) for i in range(128))
            m.a = 0
        elif f == 9:
            a = m.de
            while self.mem(a) != ord('$'):
                self.out.append(self.mem(a)); a += 1
        elif f == 2:
            self.out.append(m.e)
        else:
            self.ended = 'bdos %d' % f
            return False
        m.h, m.l = 0, m.a     # BDOS returns A in L too
        return True
