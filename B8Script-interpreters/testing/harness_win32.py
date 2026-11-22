"""Run a Windows B8Script build (a PE32 .EXE) in Unicorn, as Windows would.

The .EXE is loaded as the Windows loader does it: the headers and the
section's raw data are mapped at ImageBase, the rest of the image is zero,
and every import address table entry is filled in with the address of a
trap: a `RET n` (stdcall: the callee pops its n bytes of arguments) whose
first byte is hooked, so that the kernel32 function is done in Python just
before the RET runs. The functions modelled are the ones the builds import
(chkpe.py lists them): GetStdHandle, GetConsoleMode, SetConsoleMode,
GetCommandLineA, CreateFileA, ReadFile, WriteFile, CloseHandle,
WaitForSingleObject, ReadConsoleInputA, GetTickCount, ExitProcess. Anything
else the program calls, or a fault, ends the run. (The builds no longer
import GetTickCount; it is kept here for a build that may.)

Run(exe, prog, inp, timed=(), mode='runner', files=None, cmdline=None)
  mode 'runner': the program is the file PROG.B8S, named on the command
      line; `inp` is the keys.
  mode 'editor': `inp` is a list of chunks: the next is typed only when the
      editor (or a program it runs) is waiting for a key with no keys left,
      as a person would. The file named on the command line is PROG.B8S;
      `files` is the disk (it holds what was written when the run is over).
  .run() returns the output: what was written to standard output and
  standard error, in one stream, in order. .handles says, byte for byte,
  which handle each byte went to ('out' or 'err'). .ended is 'exit'
  (ExitProcess), 'needkey' (waiting for a key with none left), 'timeout'
  or 'fault ...'. .looks counts the looks at the keyboard (waits on the
  input handle). .modes lists the SetConsoleMode calls.

Keys are typed as a person types them: a key of the input is given only
when the program waits for one, which is a wait on the input handle with a
time other than 0 (a look, with time 0, is the break check, which must not
eat the input). `timed` is a list of (n, keys): once n characters have been
printed those keys are pressed, and they are given at the next look,
whatever the program is doing. Each key arrives as a key-down event with
its character, and then a key-up event, which the program must pass over.
Bytes 91h and 93h in the input stand for the left and right arrow keys:
key events with no character and the virtual keys 25h and 27h.

Time: the clock counts emulated work (IPMS instructions are a millisecond,
measured CHUNK instructions at a time), plus the time that the waits
spend: a wait with no key to give takes all of its time at once. A timed
wait that finds a key (or a key-up event) returns at once, so n?, the
250 ms window for a second Ctrl-C and the editor's 5 ms Esc wait behave as
on the Z80 harness. With `console=False` the input is not a
console (GetConsoleMode fails) and the keys are read with ReadFile, ending
with the end of the input.
"""
import os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from unicorn import Uc, UcError, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE, UC_PROT_ALL
from unicorn.x86_const import UC_X86_REG_EAX, UC_X86_REG_ESP, UC_X86_REG_EIP
import chkpe

ARGS = {'GetStdHandle': 1, 'GetConsoleMode': 2, 'SetConsoleMode': 2, 'GetCommandLineA': 0,
        'CreateFileA': 7, 'ReadFile': 5, 'WriteFile': 5, 'CloseHandle': 1,
        'WaitForSingleObject': 2, 'ReadConsoleInputA': 4, 'GetTickCount': 0, 'ExitProcess': 1}
TRAP = 0x7FF00000          # the trap page: function i at TRAP + 16 * i
CMDLINE = 0x7FF10000       # the command line string
STACK_TOP = 0x00300000     # the thread's stack: 1 MB below this
HIN, HOUT, HERR = 0x100, 0x104, 0x108
INFINITE = 0xFFFFFFFF
IPMS = 10000               # instructions per emulated millisecond
CHUNK = 10000              # instructions run between looks at the clock
IDLE = 2000                # timed waits in a row with no key before a run counts as waiting


def symbols(mapf):
    """The symbols of a NASM map file: name -> value."""
    sy = {}
    for line in open(mapf):
        m = re.match(r'^\s*([0-9A-F]+)\s+(?:[0-9A-F]+\s+)?([A-Za-z_.$?@][\w.$?@]*)\s*$', line)
        if m:
            sy.setdefault(m.group(2), int(m.group(1), 16))
    return sy


def plat(mapf):
    """A build's own addresses, for ref.py (all B8Script addresses)."""
    sy = symbols(mapf)
    return dict(prog_at=sy['PROG'], let=sy['LET'], linebuf=sy['LINEBUF'], heaplim=sy['HEAPLIM'] << 8)


def keyrec(c, down):
    """An INPUT_RECORD for a key event."""
    if c == 0x91:
        vk, ch = 0x25, 0
    elif c == 0x93:
        vk, ch = 0x27, 0
    else:
        vk, ch = (c & 0x5F if 0x61 <= c <= 0x7A else c), c
    return struct.pack('<HHIHHHBBI', 1, 0, 1 if down else 0, 1, vk, 0, ch, 0, 0)


class Run:
    def __init__(self, exe, prog=b'', inp=b'', timed=(), mode='runner', files=None, cmdline=None,
                 maxinstr=3_000_000_000, console=True, brk_at=None):
        self.pe = chkpe.parse(exe)
        self.mode = mode
        self.stages = []
        if mode == 'editor':
            self.stages, inp = [bytes(c) for c in inp], b''
        self.inp = list(inp)
        self.timed = list(timed)
        self.brk_at = brk_at
        self.pressed = []
        self.events = []           # INPUT_RECORDs waiting to be read
        self.out = bytearray()
        self.handles = []
        self.looks = 0
        self.modes = []
        self.ended = None
        self.idle = 0
        self.icount = 0            # instructions run before this chunk
        self.waited = 0            # ms spent in waits
        self.maxinstr = maxinstr
        self.console = console
        if files is None:
            files = {b'PROG.B8S': prog} if mode == 'runner' else {}
        self.files = files
        self.open = {}             # handle -> [name, position, writing]
        self.nexth = 0x200
        exename = os.path.basename(exe).encode()
        self.cmdline = cmdline if cmdline is not None else exename + b' PROG.B8S'

        u = self.u = Uc(UC_ARCH_X86, UC_MODE_32)
        p = self.pe
        u.mem_map(p.image_base, p.size_image, UC_PROT_ALL)
        u.mem_write(p.image_base, p.data[:p.size_headers])
        for s in p.sections:
            u.mem_write(p.image_base + s['va'], p.data[s['rptr']:s['rptr'] + s['rsize']])
        u.mem_map(TRAP, 0x1000, UC_PROT_ALL)
        u.mem_map(CMDLINE, 0x1000, UC_PROT_ALL)
        u.mem_write(CMDLINE, self.cmdline + b'\0')
        u.mem_map(STACK_TOP - 0x100000, 0x100000, UC_PROT_ALL)
        # the imports: each IAT entry gets its trap
        errs = []
        self.traps = {}
        for dll, funcs in chkpe.imports(p, errs):
            for i, (name, iat) in enumerate(funcs):
                if name not in ARGS:
                    raise ValueError(f'{name} is not modelled')
                a = TRAP + 16 * len(self.traps)
                self.traps[a] = name
                u.mem_write(a, bytes([0xC2]) + struct.pack('<H', 4 * ARGS[name]))
                u.mem_write(p.image_base + iat, struct.pack('<I', a))
        u.hook_add(UC_HOOK_CODE, self.api, begin=TRAP, end=TRAP + 0xFFF)
        # the entry point is called by the thread's start: returning from it
        # would end the thread (modelled as ExitProcess)
        a = TRAP + 16 * len(self.traps)
        self.traps[a] = 'ExitProcess'
        u.mem_write(a, b'\xC3')
        esp = STACK_TOP - 0x40
        u.mem_write(esp, struct.pack('<II', a, 0))
        u.reg_write(UC_X86_REG_ESP, esp)
        self.eip = p.image_base + p.entry

    # ---- memory and arguments ----
    def rd(self, a, n):
        return bytes(self.u.mem_read(a, n))

    def wr(self, a, b):
        self.u.mem_write(a, bytes(b))

    def d(self, a):
        return struct.unpack('<I', self.rd(a, 4))[0]

    def cstr(self, a):
        s = bytearray()
        while True:
            c = self.rd(a, 1)[0]
            if not c:
                return bytes(s)
            s.append(c)
            a += 1

    def now(self):
        return (self.icount // IPMS + self.waited) & 0xFFFFFFFF

    def find(self, name):
        for k in self.files:
            if k.lower() == name.lower():
                return k
        return None

    # ---- the keyboard ----
    def look(self, t):
        """A wait on the input handle for t ms: True if an event is there."""
        self.looks += 1
        if self.brk_at is not None and len(self.out) >= self.brk_at:
            self.pressed.append(3)
            self.brk_at = None
        while self.timed and len(self.out) >= self.timed[0][0]:
            k = self.timed.pop(0)[1]
            self.pressed += list(k) if isinstance(k, (bytes, list, tuple)) else [k]
        if self.events:
            return True
        if self.pressed:
            self.press(self.pressed.pop(0))
            return True
        if t == 0:
            return False
        if not self.inp and t == INFINITE and self.stages:
            self.inp = list(self.stages.pop(0))
        if self.inp:
            self.press(self.inp.pop(0))
            return True
        if t == INFINITE:
            self.stop('needkey')
            return False
        self.waited += t
        self.idle += 1
        if self.idle > IDLE:
            if self.stages:
                self.inp = list(self.stages.pop(0))
                self.idle = 0
            else:
                self.stop('needkey')
        return False

    def press(self, c):
        self.idle = 0
        self.events += [keyrec(c, True), keyrec(c, False)]

    def stop(self, why):
        self.ended = why
        self.u.emu_stop()

    # ---- kernel32 ----
    def api(self, u, addr, size, _):
        name = self.traps.get(addr)
        if name is None:
            return
        esp = u.reg_read(UC_X86_REG_ESP)
        a = [self.d(esp + 4 + 4 * i) for i in range(ARGS.get(name, 0))]
        r = getattr(self, 'k_' + name)(*a)
        u.reg_write(UC_X86_REG_EAX, (r or 0) & 0xFFFFFFFF)

    def k_GetStdHandle(self, n):
        return {0xFFFFFFF6: HIN, 0xFFFFFFF5: HOUT, 0xFFFFFFF4: HERR}.get(n, 0xFFFFFFFF)

    def k_GetConsoleMode(self, h, p):
        if h != HIN or not self.console:
            return 0
        self.wr(p, struct.pack('<I', 0x1F7))
        return 1

    def k_SetConsoleMode(self, h, m):
        self.modes.append((h, m))
        return 1 if h == HIN and self.console else 0

    def k_GetCommandLineA(self):
        return CMDLINE

    def k_CreateFileA(self, pname, access, share, sec, disp, flags, tmpl):
        name = self.cstr(pname)
        k = self.find(name)
        if disp == 3 and access == 0x80000000:          # OPEN_EXISTING, read
            if k is None:
                return 0xFFFFFFFF
            w = False
        elif disp == 2 and access == 0x40000000:        # CREATE_ALWAYS, write
            if not name:
                return 0xFFFFFFFF
            k = k if k is not None else name
            self.files[k] = b''
            w = True
        else:
            self.stop(f'fault CreateFileA({name!r}, {access:#x}, disp {disp})')
            return 0xFFFFFFFF
        h = self.nexth
        self.nexth += 4
        self.open[h] = [k, 0, w]
        return h

    def k_CloseHandle(self, h):
        return 1 if self.open.pop(h, None) is not None else 0

    def k_ReadFile(self, h, buf, n, pcnt, ov):
        if pcnt:
            self.wr(pcnt, struct.pack('<I', 0))
        if h == HIN and not self.console:
            self.looks += 1
            if not self.inp and self.stages:
                self.inp = list(self.stages.pop(0))
            got = bytes(self.inp[:n])
            del self.inp[:n]
        elif h in self.open and not self.open[h][2]:
            f = self.open[h]
            data = self.files[f[0]]
            got = data[f[1]:f[1] + n]
            f[1] += len(got)
        else:
            return 0
        self.wr(buf, got)
        self.wr(pcnt, struct.pack('<I', len(got)))
        return 1

    def k_WriteFile(self, h, buf, n, pcnt, ov):
        b = self.rd(buf, n)
        if h in (HOUT, HERR):
            self.out += b
            self.handles += ['out' if h == HOUT else 'err'] * n
            self.idle = 0
        elif h in self.open and self.open[h][2]:
            self.files[self.open[h][0]] += b
        else:
            if pcnt:
                self.wr(pcnt, struct.pack('<I', 0))
            return 0
        if pcnt:
            self.wr(pcnt, struct.pack('<I', n))
        return 1

    def k_WaitForSingleObject(self, h, t):
        if h != HIN:
            self.stop(f'fault WaitForSingleObject({h:#x})')
            return 0xFFFFFFFF
        return 0 if self.look(t) else 0x102

    def k_ReadConsoleInputA(self, h, buf, n, pcnt):
        if not self.events:                 # (never: only after a wait said so)
            self.stop('fault ReadConsoleInputA with no event')
            return 0
        self.wr(buf, self.events.pop(0))
        self.wr(pcnt, struct.pack('<I', 1))
        return 1

    def k_GetTickCount(self):
        return self.now()

    def k_ExitProcess(self, code=0):
        self.stop('exit')

    # ---- running ----
    def run(self):
        u = self.u
        while self.ended is None:
            try:
                u.emu_start(self.eip, 0xFFFFFFFF, count=CHUNK)
            except UcError as e:
                self.ended = f'fault {e} at {u.reg_read(UC_X86_REG_EIP):#x}'
                break
            self.eip = u.reg_read(UC_X86_REG_EIP)
            self.icount += CHUNK
            if self.icount > self.maxinstr and self.ended is None:
                self.ended = 'timeout'
        return bytes(self.out)
