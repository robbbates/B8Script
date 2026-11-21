"""Run a Z80 or 8080 B8Script build in an emulator.

generic: the image is ROM at 0000h, the program text is loaded at PROG (taken
from the listing) and NUL-terminated, and KEY/CONOUT/EXIT are traps. KEY
returns a waiting key in A, or 0, with the zero flag matching A.
cpm: the image is a .COM at 0100h; BDOS 6, 10, 15, 20 and 26 are emulated,
and the program is the 'file' that fn 15/20 read.
editor: a generic image built with EDITOR = 1. No program is loaded (the RAM
at PROG starts as junk, as after power-on) and everything goes in through KEY.
The input is a list of chunks: the next chunk is typed only when the machine
has been left waiting for a key, as a person would, and the run ends when it
waits with no chunks left. `timed` is a list of (n, key): the key is pressed
once n characters have been printed.
"""
import re
import z80

TRAP = 0xFFF0          # BDOS lives here in the cpm runs
WBOOT = 0xFFE0
IDLE = 20000         # empty KEY polls in a row before a run counts as waiting for input


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


class Run:
    def __init__(self, hexf, lst, prog, inp=b'', cpu='z80', mode='generic',
                 maxticks=4_000_000_000, brk_at=None, timed=()):
        self.m = z80.I8080Machine() if cpu == '8080' else z80.Z80Machine()
        self.sy = symbols(lst)
        org, img = load_hex(hexf)
        self.img_size = len(img)
        self.m.set_memory_block(org, img)
        self.stages = []
        if mode == 'editor':
            self.stages, inp = [bytes(c) for c in inp], b''
        self.timed = list(timed)
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
            for k in ('KEY', 'CONOUT', 'EXIT'):
                self.m.set_breakpoint(self.sy[k])
            self.m.pc = 0
        elif mode == 'editor':
            self.m.set_memory_block(self.sy['PROG'], b'\xAA' * 2048)
            for k in ('KEY', 'CONOUT'):
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
            self.file = prog
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

    def key_ready(self):
        if self.brk_at is not None and len(self.out) >= self.brk_at:
            self.inp.insert(0, 3)
            self.brk_at = None
        if self.timed and len(self.out) >= self.timed[0][0]:
            self.inp.append(self.timed.pop(0)[1])
        return bool(self.inp)

    def run(self):
        m = self.m
        total = 0
        idle = 0
        while True:
            m.ticks_to_stop = 20_000_000
            m.run()
            total += 20_000_000 - m.ticks_to_stop
            if total > self.maxticks:
                self.ended = 'timeout'
                break
            pc = m.pc
            if self.mode in ('generic', 'editor'):
                sy = self.sy
                if pc == sy['CONOUT']:
                    self.out.append(m.a); idle = 0; self.ret()
                elif pc == sy['KEY']:
                    if self.key_ready():
                        m.a = self.inp.pop(0); idle = 0
                    else:
                        # a program polling for a key that will never come
                        m.a = 0; idle += 1
                        if idle > IDLE and self.stages:
                            self.inp = list(self.stages.pop(0)); idle = 0
                        elif idle > IDLE:
                            self.ended = 'needkey'; break
                    # the host routine's contract: Z (and S) follow A
                    m.f = (m.f & 0x3F) | (0x40 if m.a == 0 else 0) | (m.a & 0x80)
                    self.ret()
                elif pc == sy['EXIT'] and self.mode == 'generic':
                    self.ended = 'exit'; break
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
                if self.key_ready():
                    m.a = self.inp.pop(0); self.idle = 0
                else:
                    # a program polling for a key that will never come
                    m.a = 0; self.idle += 1
                    if self.idle > IDLE:
                        self.ended = 'needkey'; return False
            else:
                self.out.append(m.e); self.idle = 0
        elif f == 10:
            de = m.de
            mx = self.mem(de)
            buf = bytearray()
            while True:
                if not self.key_ready():
                    self.ended = 'needkey'; return False
                c = self.inp.pop(0)
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
        elif f == 15:
            m.a = 0
        elif f == 26:
            self.dma = m.de
        elif f == 20:
            if self.fpos >= len(self.file):
                m.a = 1
            else:
                rec = self.file[self.fpos:self.fpos + 128]
                rec = rec + b'\x1a' * (128 - len(rec))
                m.set_memory_block(self.dma, rec)
                self.fpos += 128
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
