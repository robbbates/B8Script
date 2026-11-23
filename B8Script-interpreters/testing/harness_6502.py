import os
"""Run a 6502 B8Script build in py65.

The image is ROM at E000h (the reset entry is `start`), the program text is
loaded at PROG (from the listing) and NUL-terminated, and KEY/CONOUT/EXIT are
traps: pc is checked before each step, and the routine is simulated and an RTS
performed. KEY returns a waiting key in A, or 0, with the Z flag matching A.

Input is typed as a person types: a key of the input is given only when the
program is waiting for one, that is when it looks at the keyboard twice
within GAP instructions (a key loop). A look now and then (the break check)
finds nothing, so it can't eat the input. `timed` is a list of (n, keys):
once n characters have been printed those keys are pressed, and they are
given at the very next looks, whatever the program is doing. `looks` counts
the calls of KEY.
"""
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from py65.devices.mpu6502 import MPU
from harness_z80 import load_hex, symbols

GAP = 1000      # instructions: two looks at the keyboard closer than this are
                # a key loop. One pass of the interpreter's key loops is about
                # a dozen; 256 loop-backs, the break check's rate, are
                # thousands.


from harness_z80 import CONHOOKS, CONCLS, CONEOL, conat, concur

class Run:
    def __init__(self, hexf, lst, prog, inp=b'', brk_at=None, maxsteps=4_000_000_000, timed=()):
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
        self.timed = list(timed)
        self.pressed = []       # keys pressed while the program is busy: given at once
        self.looks = 0
        self.now = 0            # instructions so far
        self.last_look = -GAP
        self.out = bytearray()
        self.ended = None
        self.brk_at = brk_at
        self.maxsteps = maxsteps
        m.pc = self.sy['START']
        m.sp = 0xFF

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
        # a build with ANSI = 0 calls four routines of the machine's for the
        # console codes: each is answered with what a build with ANSI = 1 prints
        hooks = {sy[k]: k for k in CONHOOKS if k in sy}
        traps |= set(hooks)
        step = m.step
        out = self.out
        n = 0
        idle = 0
        while True:
            pc = m.pc
            if pc in traps:
                if pc == cout:
                    out.append(m.a); idle = 0; self.ret()
                elif pc in hooks:
                    h = hooks[pc]
                    out += (conat(m.y, m.a) if h == 'CONAT' else CONCLS if h == 'CONCLS'
                            else CONEOL if h == 'CONEOL' else concur(m.a))
                    idle = 0; self.ret()
                elif pc == key:
                    self.now = n
                    m.a = self.key()
                    if m.a:
                        idle = 0
                    elif self.inp:
                        pass                    # the key comes at a later look
                    else:
                        # a program polling for a key that will never come
                        # (e.g. Tiny BASIC's 0? after its input ran out)
                        idle += 1
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
