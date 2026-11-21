"""Run a 6809 B8Script build in the MC6809 emulator (pure Python, slow).

The image is ROM at F000h (taken from the hex file), the program text is
loaded at PROG (from the listing) and NUL-terminated. KEY, CONOUT and EXIT
are traps: when the PC reaches one, the harness does the job and simulates
an RTS. KEY returns a waiting key in A, or 0, with the Z flag matching A.
Execution starts at the symbol `start`.
"""
import os, sys, logging
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
logging.disable(logging.CRITICAL)
from MC6809.components.cpu6809 import CPU
from MC6809.components.memory import Memory
from MC6809.core.configs import BaseConfig
from harness_z80 import load_hex, symbols


class Cfg(BaseConfig):
    RAM_START = 0x8000
    RAM_END = 0xEFFF
    ROM_START = 0xF000
    ROM_END = 0xFFFF


class Run:
    def __init__(self, hexf, lst, prog, inp=b'', maxops=2_000_000_000, brk_at=None):
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
        self.brk_at = brk_at    # inject Ctrl-C once the output reaches this many bytes
        self.cpu.program_counter.set(self.sy['START'])

    def _sex(self, opcode):
        cpu = self.cpu
        cpu.accu_a.set(0xFF if cpu.accu_b.value & 0x80 else 0x00)
        cpu.clear_NZ()
        cpu.update_NZ_16(cpu.accu_d.value)

    def key_ready(self):
        if self.brk_at is not None and len(self.out) >= self.brk_at:
            self.inp.insert(0, 3)
            self.brk_at = None
        return bool(self.inp)

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
        n = 0
        idle = 0
        while n < self.maxops:
            step()
            n += 1
            t = traps.get(pc.value)
            if t is None:
                continue
            if t == 'out':
                self.out.append(a.value); idle = 0; self.rts()
            elif t == 'key':
                if self.key_ready():
                    a.set(self.inp.pop(0)); idle = 0
                else:
                    # a program polling for a key that will never come
                    a.set(0); idle += 1
                    if idle > 20000:
                        self.ended = 'needkey'; break
                # the host routine's contract: Z (and N) follow A
                v = a.value
                cpu.set_cc((cpu.get_cc_value() & 0xF3) | (0x04 if v == 0 else 0) | (0x08 if v & 0x80 else 0))
                self.rts()
            else:
                self.ended = 'exit'; break
        else:
            self.ended = 'timeout'
        return bytes(self.out)
