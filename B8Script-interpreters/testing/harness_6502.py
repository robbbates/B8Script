import os
"""Run a 6502 B8Script build in py65.

The image is ROM at E000h (the reset entry is `start`), the program text is
loaded at PROG (from the listing) and NUL-terminated, and KEY/CONOUT/EXIT are
traps: pc is checked before each step, and the routine is simulated and an RTS
performed. KEY returns a waiting key in A, or 0, with the Z flag matching A.
"""
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from py65.devices.mpu6502 import MPU
from harness_z80 import load_hex, symbols


class Run:
    def __init__(self, hexf, lst, prog, inp=b'', brk_at=None, maxsteps=4_000_000_000):
        self.sy = symbols(lst)
        org, img = load_hex(hexf)
        self.img_size = len(img)
        m = self.m = MPU()
        mem = self.mem = m.memory
        for i, b in enumerate(img):
            mem[org + i] = b
        p = self.sy['PROG']
        for i, b in enumerate(prog + b'\0'):
            mem[p + i] = b
        self.inp = list(inp)
        self.out = bytearray()
        self.ended = None
        self.brk_at = brk_at
        self.maxsteps = maxsteps
        m.pc = self.sy['START']
        m.sp = 0xFF

    def key_ready(self):
        if self.brk_at is not None and len(self.out) >= self.brk_at:
            self.inp.insert(0, 3)
            self.brk_at = None
        return bool(self.inp)

    def ret(self):
        m = self.m
        mem = self.mem
        sp = m.sp
        lo = mem[0x100 + ((sp + 1) & 0xFF)]
        hi = mem[0x100 + ((sp + 2) & 0xFF)]
        m.sp = (sp + 2) & 0xFF
        m.pc = (((hi << 8) | lo) + 1) & 0xFFFF

    def run(self):
        m = self.m
        sy = self.sy
        key, cout, ext = sy['KEY'], sy['CONOUT'], sy['EXIT']
        traps = {key, cout, ext}
        step = m.step
        out = self.out
        n = 0
        idle = 0
        while True:
            pc = m.pc
            if pc in traps:
                if pc == cout:
                    out.append(m.a); idle = 0; self.ret()
                elif pc == key:
                    if self.key_ready():
                        m.a = self.inp.pop(0); idle = 0
                    else:
                        # a program polling for a key that will never come
                        # (e.g. Tiny BASIC's 0? after its input ran out)
                        m.a = 0; idle += 1
                        if idle > 20000:
                            self.ended = 'needkey'; break
                    # the host routine's contract: Z (and N) follow A
                    m.p = (m.p & 0x7D) | (0x02 if m.a == 0 else 0) | (m.a & 0x80)
                    self.ret()
                else:
                    self.ended = 'exit'; break
                continue
            step()
            n += 1
            if n > self.maxsteps:
                self.ended = 'timeout'; break
        return bytes(out)
