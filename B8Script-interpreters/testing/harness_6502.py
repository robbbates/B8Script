import os
"""Run a 6502 B8Script build in py65.

The image is ROM at E000h (the reset entry is `start`), the program text is
loaded at PROG (from the listing) and NUL-terminated, and CONIN/CONOUT/CONST/
EXIT are traps: pc is checked before each step, and the routine is simulated
and an RTS performed.
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
        cin, cout, cst, ext = sy['CONIN'], sy['CONOUT'], sy['CONST'], sy['EXIT']
        traps = {cin, cout, cst, ext}
        step = m.step
        out = self.out
        n = 0
        idle = 0
        while True:
            pc = m.pc
            if pc in traps:
                if pc == cout:
                    out.append(m.a); idle = 0; self.ret()
                elif pc == cst:
                    if self.key_ready():
                        m.a = 0xFF; idle = 0
                    else:
                        # a program polling for a key that will never come
                        # (e.g. Tiny BASIC's 0? after its input ran out)
                        m.a = 0; idle += 1
                        if idle > 100000:
                            self.ended = 'needkey'; break
                    self.ret()
                elif pc == cin:
                    if not self.key_ready():
                        self.ended = 'needkey'; break
                    m.a = self.inp.pop(0); self.ret()
                else:
                    self.ended = 'exit'; break
                continue
            step()
            n += 1
            if n > self.maxsteps:
                self.ended = 'timeout'; break
        return bytes(out)
