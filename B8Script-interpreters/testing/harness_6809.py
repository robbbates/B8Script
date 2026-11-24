"""Run a 6809 B8Script build in the MC6809 emulator (pure Python, slow).

The image is ROM at F000h (taken from the hex file), the program text is
loaded at PROG (from the listing) and NUL-terminated. KEY, CONOUT and EXIT
are traps: when the PC reaches one, the harness does the job and simulates
an RTS. KEY returns a waiting key in A, or 0, with the Z flag matching A.
Each spoils what its contract lets it change (CONOUT: A and CC; KEY: V and
C), so that an interpreter that relies on more is caught.
In a build with ANSI = 0, CONCLS, CONEOL, CONCUR and CONAT (the console
escapes of '$') are traps too: each adds to the output the ANSI sequence an
ANSI = 1 build sends, so both are compared with ref.py's output unchanged,
and then spoils A, B, X and CC, which the contract lets it change.
Execution starts at the symbol `start`.

Keys are typed as a person types them: only when the program is waiting for
one. Every build looks at the keyboard now and then for the break key, and a
key it finds then is held, the newest winning (the spec); a queue of keys
handed over as fast as they are read would mostly be lost. So a key from the
input is given only when KEY is called twice within GAP emulated
instructions, which is a program sitting in a key loop ('?', a line read),
not the break check, whose looks are hundreds of characters apart. Keys to
be pressed while the program is busy are given at once: `brk_at` presses
Ctrl-C once that many characters have been printed, and `timed` is a list of
(n, keys): the keys are pressed once n characters have been printed.
`looks` counts the calls of KEY.
"""
import os, sys, logging
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
logging.disable(logging.CRITICAL)
from MC6809.components.cpu6809 import CPU
from MC6809.components.memory import Memory
from MC6809.core.configs import BaseConfig
from harness_z80 import load_hex, symbols

GAP = 1000           # instructions: two looks at the keyboard closer than this
                     # are a key loop (one pass of one is about a dozen; 256
                     # loop-backs or word calls are many thousands)
IDLE = 20000         # empty looks in a row before a run counts as waiting
CONS = ('CONCLS', 'CONEOL', 'CONCUR', 'CONAT')   # the console routines (ANSI = 0)


class Cfg(BaseConfig):
    RAM_START = 0x8000
    RAM_END = 0xEFFF
    ROM_START = 0xF000
    ROM_END = 0xFFFF


class Run:
    def __init__(self, hexf, lst, prog, inp=b'', maxops=2_000_000_000, brk_at=None, timed=()):
        self.sy = symbols(lst)
        cfg = Cfg({"verbosity": None, "trace": None})
        self.mem = Memory(cfg)
        self.cpu = CPU(self.mem, cfg)
        # MC6809 0.9.0 gets SEX wrong: it clears A for a positive B but never
        # sets it to FFh for a negative one. Put the real instruction in.
        cycles, _ = self.cpu.opcode_dict[0x1D]
        self.cpu.opcode_dict[0x1D] = (cycles, self._sex)
        org, img = load_hex(hexf)
        self.img_size = len(img)
        self.mem.load(org, img)
        self.mem.load(self.sy['PROG'], prog + b'\0')
        self.inp = list(inp)
        self.out = bytearray()
        self.ended = None
        self.maxops = maxops
        self.brk_at = brk_at    # press Ctrl-C once the output reaches this many bytes
        self.timed = list(timed)
        self.pressed = []       # keys pressed: given at the next looks, gap or no gap
        self.looks = 0          # how many times KEY was called
        self.now = 0            # instructions run so far
        self.last_look = -GAP
        self.cpu.program_counter.set(self.sy['START'])

    def _sex(self, opcode):
        cpu = self.cpu
        cpu.accu_a.set(0xFF if cpu.accu_b.value & 0x80 else 0x00)
        cpu.clear_NZ()
        cpu.update_NZ_16(cpu.accu_d.value)

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

    def console(self, k):
        """One of the machine's console routines, modelled as the ANSI
        sequence it stands for. CONCUR: show if A is not 0. CONAT: row X,
        column D, from 0. Then A, B, X and CC are spoiled."""
        cpu = self.cpu
        if k == 'CONCLS':
            self.out += b'\x1b[H\x1b[J'
        elif k == 'CONEOL':
            self.out += b'\x1b[K'
        elif k == 'CONCUR':
            self.out += b'\x1b[?25h' if cpu.accu_a.value else b'\x1b[?25l'
        else:
            row, col = cpu.index_x.value, cpu.accu_d.value
            self.out += b'\x1b[%d;%dH' % ((row + 1) & 0xFFFF, (col + 1) & 0xFFFF)
        cpu.accu_d.set(0xA55A)
        cpu.index_x.set(0x5AA5)
        cpu.set_cc(cpu.get_cc_value() ^ 0x0F)

    def rts(self):
        cpu = self.cpu
        sp = cpu.system_stack_pointer.value
        m = self.mem._mem
        cpu.program_counter.set((m[sp] << 8) | m[(sp + 1) & 0xFFFF])
        cpu.system_stack_pointer.set((sp + 2) & 0xFFFF)

    def run(self):
        cpu = self.cpu
        sy = self.sy
        step = cpu.get_and_call_next_op
        pc = cpu.program_counter
        a = cpu.accu_a
        traps = {sy['KEY']: 'key', sy['CONOUT']: 'out', sy['EXIT']: 'exit'}
        traps.update({sy[k]: k for k in CONS if k in sy})
        n = 0
        idle = 0
        while n < self.maxops:
            step()
            n += 1
            self.now = n
            t = traps.get(pc.value)
            if t is None:
                continue
            if t == 'out':
                # CONOUT may change A and CC: spoil them
                self.out.append(a.value); idle = 0
                a.set(0xEE)
                cpu.set_cc(cpu.get_cc_value() ^ 0x0F)
                self.rts()
            elif t == 'key':
                a.set(self.key())
                if a.value or self.inp or self.timed or self.pressed:
                    idle = 0
                else:
                    # a program polling for a key that will never come
                    idle += 1
                    if idle > IDLE:
                        self.ended = 'needkey'; break
                # the host routine's contract: Z (and N) follow A; it may
                # change the rest of CC, so V and C are spoiled
                v = a.value
                cpu.set_cc(((cpu.get_cc_value() ^ 0x03) & 0xF3) | (0x04 if v == 0 else 0) | (0x08 if v & 0x80 else 0))
                self.rts()
            elif t == 'exit':
                self.ended = 'exit'; break
            else:
                self.console(t); idle = 0; self.rts()
        else:
            self.ended = 'timeout'
        return bytes(self.out)
