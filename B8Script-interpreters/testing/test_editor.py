"""Test the Z80 builds that have the line editor (EDITOR = 1).

usage: test_editor.py DIR [-v]   (DIR holds the builds named *-ed and *-ed-chk, from
       VARIANTS=$'0 0 1\n0 1 1\n1 0 1\n1 1 1' ./build.sh Z80 ../z80/b8s-z80.asm DIR)

A session is a list of steps. Each step is the keys typed when the editor (or
the program it is running) is next waiting for one:
    b'...'                  those keys, as they are: R() adds the Return
    (b'...', [(k, a, b)])   keys that end in ^L; after k lines of the list
                            have been printed key a is pressed, and then,
                            unless a was Ctrl-C, key b (None: no key, the
                            list stays held)
The expected output comes from a model of the editor here, Ed, which follows
the source key for key, the echo included; ref.py runs whatever the editor
runs. A few sessions can't be modelled (a key pressed while a program is
busy): those are checked against patterns.

check_editor() takes a `target` for builds of other machines (see
win32_target): how it stores files, and how it is run.
Without one it is the Z80's.
"""
import sys, os, re, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_z80 import Run, symbols, TRAP
from ref import Ref

CR, BS, ESC = b'\r', b'\x08', b'\x1b'
G, L, E, RD, WR, N, V, X, B, F, Z = (bytes([c]) for c in (7, 12, 5, 18, 23, 14, 22, 24, 2, 6, 26))
LEFT, RIGHT, UP = ESC + b'[D', ESC + b'[C', ESC + b'[A'


def R(text):
    """A line and its Return."""
    return text + CR


class Left(Exception):
    """^X: the editor was left."""


SHOW = b'\x1b[?25h'     # the cursor shown again (in an ANSI = 0 build, CONCUR)


class Ed:
    """The editor, as the source has it."""

    def __init__(self, sy, cpm, checked, files=None, target=None):
        self.sy, self.cpm, self.checked = sy, cpm, checked
        t = target or {}
        self.disk = t.get('disk', cpm)          # read and write use files
        self.pad = t.get('pad', cpm)            # a written file is padded with ^Z
        self.fname = t.get('fname')             # typed name -> the file's name
        self.lines = []                 # the program: each line with its CR LF
        self.out = bytearray(SHOW)      # the editor shows the cursor when it starts,
        self.ds = []                    #   and after an error or a break (edit0)
                                        # the data stack lasts from line to line
        self.cells = bytes(0x74)        # so do the words and the variables
        self.undef = set(range(0x41, 0x5B)) if checked else set()
        self.files = files if files is not None else {}
        self.name = t.get('default', b'PROG    B8S')     # the file named on the command line
        self.timed = []                 # keys to press while a list is running
        self.chunks = []
        self.heaplim = t.get('heaplim', (TRAP & 0xFF00) if cpm else sy['HEAPLIM'] << 8)
        if self.disk:
            self.load()

    # ---- the program text ----
    def text(self):
        return b''.join(self.lines)

    def set_text(self, t):
        """Take a text in: it ends at the first ^Z, and a last line with no
        line end is given one."""
        t = t.split(b'\x1a')[0]
        if t and not t.endswith(b'\n'):
            t += b'\r\n'
        self.lines = [l + b'\n' for l in t.split(b'\n')[:-1]]

    def key(self, name):
        """The name a file is kept under (the same one, or another way)."""
        return self.fname(self.files, name) if self.fname else name

    def load(self):
        self.set_text(self.files.get(self.key(self.name), b''))

    def setname(self, typed):
        if not typed:
            return
        if self.fname:
            self.name = typed
            return
        name, _, ext = typed.partition(b'.')
        up = lambda s: bytes(c & 0x5F if c >= 0x61 else c for c in s)
        self.name = up(name)[:8].ljust(8) + up(ext)[:3].ljust(3)

    # ---- running ----
    def run(self, typed, queue, stored):
        sy = self.sy
        r = Ref(self.text(), bytes(queue), prog_at=sy['PROG'], let=sy['LET'], linebuf=sy['LINEBUF'],
                heaplim=self.heaplim, checked=self.checked)
        r.m[sy['LINEBUF']:sy['LINEBUF'] + len(typed) + 3] = typed + b'\r\n\0'
        r.m[sy['LET']:sy['LET'] + 0x74] = self.cells
        r.undef, r.ds = self.undef, self.ds
        if not stored:
            r.ip = sy['LINEBUF']
        self.out += r.run(2_000_000)
        if r.error:
            self.out += SHOW
        self.ds = [] if r.error else r.ds       # an error clears the stack
        self.cells = bytes(r.m[sy['LET']:sy['LET'] + 0x74])
        queue[:] = list(r.inp)                  # what the program did not read is typed at the editor

    # ---- typing ----
    def type(self, step):
        keys, events = step if isinstance(step, tuple) else (step, [])
        self.chunks.append(keys)
        queue = list(keys)
        try:
            while queue:
                self.line(queue, events)
        except Left:
            return False
        return True

    def line(self, queue, events):
        """One input line: from its first key to what its last key does."""
        out = self.out
        buf, cur, edln = bytearray(), 0, 0
        while True:
            if not queue:
                self.pending = (buf, cur, edln)     # (the line is carried on in the next step)
                raise NotImplementedError('a step must end where a line ends')
            c = queue.pop(0)
            if c == 27:                             # Esc: alone, or the start of an arrow key
                if not queue:
                    out += b'\r\n'
                    return
                c = queue.pop(0)
                if c != ord('['):
                    continue
                while True:
                    c = queue.pop(0)
                    if c >= 0x40:
                        break
                c = {ord('C'): 'R', ord('D'): 'L'}.get(c, 0)      # an arrow key; ^B and ^F do nothing
            if c in (8, 127):
                if cur:
                    cur -= 1
                    del buf[cur]
                    rest = buf[cur:] + b' '
                    out += b'\x08' + rest + b'\x08' * len(rest)
            elif c == 'L':
                if cur:
                    cur -= 1
                    out.append(8)
            elif c == 'R':
                if cur < len(buf):
                    out.append(buf[cur])
                    cur += 1
            elif c == 9 or (isinstance(c, int) and c >= 32):
                if len(buf) < 125:
                    buf.insert(cur, c)
                    cur += 1
                    rest = buf[cur:]
                    out += bytes([c]) + rest + b'\x08' * len(rest)
            elif c in (13, 7, 12, 5, 18, 23, 14, 24):
                out += b'\r\n'
                typed = bytes(buf)
                digits = 0
                while typed[digits:digits + 1].isdigit():
                    digits += 1
                n = int(typed[:digits] or b'0') & 0xFFFF
                if c == 5:                          # ^E: the line comes into the input line
                    if 0 < n <= len(self.lines):
                        edln = n
                        buf = bytearray(self.lines[n - 1].rstrip(b'\r\n')[:125])
                        cur = len(buf)
                        out += buf
                        continue
                    return
                self.command(c, typed, digits, n, edln, queue, events)
                return

    def command(self, c, typed, digits, n, edln, queue, events):
        out, lines = self.out, self.lines
        if c == 13:
            if edln:                                # the edited line goes back in its place
                lines[edln - 1] = typed + b'\r\n'
            elif not digits:
                self.run(typed, queue, False)
            elif typed[digits:]:                    # the one character after the number is not stored
                lines.insert(min(n - 1, len(lines)) if n else len(lines), typed[digits + 1:] + b'\r\n')
            elif n:
                del lines[n - 1:n]
        elif c == 7:
            self.run(typed, queue, True)
        elif c == 12:
            done = 0
            for i in range(max(n, 1) - 1, len(lines)):
                if events and events[0][0] == done:
                    _, a, b = events.pop(0)
                    self.timed.append((len(out), bytes([a])))
                    if a == 3 or b is None:
                        break
                    self.chunks.append(bytes([b]))
                    if b == 3:
                        break
                out += b'%d ' % (i + 1) + lines[i]
                done += 1
            assert not events, 'a key was set for a line the list never reached'
        elif c == 14:
            del lines[:]
        elif c == 18:
            if self.disk:
                self.setname(typed)
                self.load()
            else:                                   # what is typed until ^Z is the program
                t, prev = bytearray(), 10
                while True:
                    k = queue.pop(0)
                    if k == 26:
                        break
                    if k == 10:
                        if prev == 10:
                            continue
                        k = 13
                    t.append(k)
                    prev = k
                    if k == 13:
                        t.append(10)
                        prev = 10
                self.set_text(bytes(t))
        elif c == 23:
            if self.disk:
                self.setname(typed)
                t = self.text()
                self.files[self.key(self.name)] = t + (b'\x1a' * (-len(t) % 128) if self.pad else b'')
            else:
                out += self.text()
        elif c == 24:
            raise Left


def screen(b):
    """What a terminal shows of some output: only CR, LF and BS move the cursor."""
    rows, r, c = [[]], 0, 0
    for ch in b:
        if ch == 13:
            c = 0
        elif ch == 10:
            r += 1
            if r == len(rows):
                rows.append([])
        elif ch == 8:
            c = max(0, c - 1)
        else:
            row = rows[r]
            row.extend([32] * (c + 1 - len(row)))
            row[c] = ch
            c += 1
    return [bytes(x).rstrip() for x in rows]


def sessions():
    return {

    'enter, list, run': [R(b'1 "Hi"$'), R(b'2 2 3+#'), L, G],
    'run a line at once': [R(b' 7 6*#'), R(b'"x"$ 1 2+#'), R(b' [S:*] 9S#'), R(b'-5 3*#'), R(b'')],
    'insert in the middle and at the ends': [
        R(b'1 "b"$'), R(b'1 "a"$'), R(b'9 "d"$'), R(b'3 "c"$'), L, G],
    'delete': [R(b'1 1#'), R(b'2 2#'), R(b'3 3#'), R(b'4 4#'), L, R(b'2'), L, R(b'1'), L, R(b'9'), R(b'2'), L,
               G, R(b'1'), L, R(b'1'), L, R(b'1'), R(b'0'), G],
    'a number past the end, or 0, adds at the end; list an empty program': [
        L, R(b'0 5#'), R(b'7 6#'), R(b'0 7#'), L, G],
    'list from a line': [R(b'0 %d#' % i) for i in range(1, 13)] + [
        b'5' + L, b'12' + L, b'13' + L, b'0' + L, b'65535' + L, b'65536' + L, b'65541' + L, b'2x' + L, b'x' + L, G],
    'a program with words, a loop and the heap': [
        R(b'1 [F :1>( :1-F* 0)]'), R(b'2 1i! 1( i@F# 32\' i@1+:i! 8<)'),
        R(b'3 4_x! 258x@! x@,# x@1+,#'), L, G, G],
    'long lines and many of them': (
        [R(b'%d %s' % (i + 1, b'"' + bytes([65 + i % 26]) * 100 + b'"$')) for i in range(20)]
        + [R(b'5'), R(b'5'), R(b'7 "new"$'), L, G]),
    'lines of every length, put in at every place': (
        [R(b'%d %s' % (1 + i * 7 % (i + 1), b'"' + b'%d' % i + b'.' * (i * 5 % 110) + b'"$')) for i in range(40)]
        + [L, G, R(b'3'), R(b'30'), R(b'1'), L, G]),
    'a line of the full 125 characters': [R(b'1 ' + b'x' * 140), L, R(b'2 "' + b'y' * 119 + b'"$'), L,
                                         R(b'3 ' + b'z' * 140 + LEFT * 5 + b'QQ' + BS * 3 + b'RRRR'), L],
    'the character after the line number': [
        R(b'1 5#'), R(b'2 7 8+#'), R(b'3x9#'), R(b'2 '), L, G, R(b'2'), L, R(b'1  1#'), L],
    'Backspace and DEL': [R(BS * 2 + b'1 "abX' + BS + b'c"$'), R(b'2 9#' + b'\x7f' * 7 + b' 5 5*#'), L, G],
    'the cursor: insert and delete in the middle': [
        R(b'1 "ac"$' + LEFT * 3 + b'b'), R(b'2 "xyz"$' + LEFT * 9 + b'9' + RIGHT * 3 + b'A' + RIGHT * 9 + b' 1;'),
        R(b'3 12345' + LEFT * 3 + BS * 2 + b'6' + RIGHT + b'\x7f' + b'#'), L, G],
    '^B and ^F do nothing': [R(b'1 "a' + B * 3 + b'c"$' + F), R(b'2 "xy"$' + LEFT + B + b' ' + F), L, G],
    'the arrow keys': [R(b'1 "ac"$' + LEFT * 3 + b'b' + RIGHT + b'!' + LEFT + BS), R(b'2 7#' + UP + ESC + b'[1;5D' + b'7'), L, G],
    'Esc drops the line': [b'1 "gone"$' + ESC, R(b' 5#'), b'' + ESC, R(b'1 6#') , b'2 x' + LEFT + ESC, L],
    'Esc and a key that is no arrow': [R(b' 1' + ESC + b'O2#'), R(b' 3' + ESC + b'[H#')],
    'keys that do nothing': [R(b' 1\x03\x01\n\x0f2#'), R(b'\n\x03\x04 5#')],
    'Tab is text': [R(b'1 \t7\t#'), L, G],
    'run, then use what the program defined': [R(b'1 "one"$'), R(b'2 [W "w"$]'), G, R(b' W'), R(b' W')],
    '300 lines': [R(b'0 %d#' % i) for i in range(300)] + [L, R(b'128 "at 128"$'), R(b'100'), b'250' + L, R(b'299'), b'290' + L, G],
    'a program that reads a line and a key': [
        R(b'1 -9? ,\' 0?\' "."$'), G + b'hello\rk', R(b' 1#'), G + b'\rZ', L],
    'hold the list and let it go': [R(b'0 %d#' % i) for i in range(9)] + [
        (L, [(3, 32, 32)]), (L, [(0, 120, 13), (4, 32, 32), (5, 13, 120)]), b'8' + L],
    'Ctrl-C ends the list': [R(b'0 %d#' % i) for i in range(9)] + [
        (L, [(4, 3, None)]), (b'2' + L, [(2, 32, 3)]), (L, [(0, 3, None)]), R(b' 5#'), b'9' + L],
    'the data stack lasts from line to line': [
        R(b' 1 2 3'), R(b' +#'), R(b'1 10*'), G, R(b' #'), R(b' 4 5'), R(b' #" "$#')],
    'edit a line': [R(b'1 "abc"$'), R(b'2 5#'), b'1' + E + R(LEFT * 3 + b'X'), L, G,
                    b'2' + E + R(BS * 2 + b'77#'), L, G],
    'edit: no such line, a dropped edit, an emptied line': [
        R(b'1 1#'), R(b'2 2#'), b'9' + E, R(b' 7#'), b'0' + E, R(b' 8#'), b'2' + E + b'zzz' + ESC, L,
        b'1' + E + R(BS * 9), L, G, E, R(b' 9#')],
    'edit a line of the full length': [R(b'1 ' + b'x' * 125), b'1' + E + R(BS * 3 + b'abcd'), L],
    'new': [R(b'1 1#'), R(b'2 2#'), N, L, R(b'1 3#'), R(b'2 4#'), L, G, N, L, G],
    'no ^V: the key does nothing': [R(V + b' 6#'), R(b'1 "a"$'), R(b' 5' + V + b'#'), L],
}


# Generic builds: read is a paste that ends at ^Z, write prints the text.
GEN_SESSIONS = {
    'read and write': [RD + b'1#\r\n2#\r\n' + Z, L, G, WR],
    'read: CR alone, LF alone, empty lines, no last line end': [
        RD + b'1#\r2#\r' + Z, L, RD + b'3#\n4#\n\n5#' + Z, L, G, RD + b'\r\n\r\n6#\r\n\r\n' + Z, L, G, RD + Z, L],
    'read replaces the program': [R(b'1 9#'), R(b'2 8#'), RD + b'"new"$' + Z, L, G, WR],
    'leave': [R(b' 5#'), X, R(b' 6#')],
}

# CP/M builds: the file named on the command line is the program to start
# with; read and write use files.
FILE = b'"one "$\r\n[W "w"$]\r\n2 3*#\r\n'
CPM_SESSIONS = {
    'a file is loaded, listed, run and added to': (FILE, [L, G, R(b' W'), R(b'2 "new "$'), R(b'0 9#'), L, G]),
    'a file with no text': (b'', [L, R(b'1 5#'), L, G]),
    'no file at all': (None, [L, R(b'1 5#'), L, G]),
    'a file of exactly one record': ((b'1#' + b' ' * 61 + b'\r\n') * 2, [L, G, R(b'0 2#'), G]),
    'a file whose last line has no CR LF': (b'1#\r\n2#', [L, G]),
    'write, change, read back': (FILE, [R(b'1 "zero "$'), WR, R(b'1'), R(b'1'), L, RD, L, G]),
    'write under a new name, read both': (FILE, [
        R(b'1'), b'new.b8s' + WR, N + N, L, RD, L, b'PROG.B8S' + RD, L, b'new.b8s' + RD, L, WR, b'nosuch' + RD, L]),
    'write a program of several records': (b'', [R(b'0 "%s"$' % (bytes([65 + i]) * 60)) for i in range(7)] + [
        b'BIG' + WR, N + N, L, b'big' + RD, L, G]),
    'write an empty program': (FILE, [N + N, b'EMPTY.TXT' + WR, b'PROG.B8S' + RD, L, b'EMPTY.TXT' + RD, L]),
    'leave': (FILE, [R(b' 5#'), X, R(b' 6#')]),
}

# Checked builds: an error or a break prints its report and comes back to
# the editor, with both stacks cleared.
CHK_SESSIONS = {
    'errors in the program and in a typed line': [
        R(b'1 1 2'), R(b'2 3 0/ "no"$'), G, R(b' 7#'), R(b' 1 0! "no"$'), R(b' 5 Q "no"$'), R(b' [Q 9#] Q'),
        R(b'3 [5 1]'), R(b'2'), G, R(b'1 [R R] 4'), R(b'2 0( 1'), G, R(b' ;')],
    'an error clears the stack': [R(b' 1 2 3'), R(b' 4 0/'), R(b' 7#'), R(b' ;')],
    'variables start at 0 and words undefined': [R(b' q@# j@#'), R(b' 1 2 W "no"$'), R(b' [W 3#]W')],
}

# What can't be modelled: a key pressed while a program is busy. (steps, keys
# by count of characters printed, the patterns that must follow each other in
# the output; checked: None = every build, True or False = only those.)
RPT = rb'\r\nErr B @ %s,\d+\r\nD:\d+:[ \-\d.]*\r\nR:\d+\r\n'
TIMED = {
    'Ctrl-C stops a program (checked)': (True, [R(b'1 1("."$ 1)'), R(b' 1 2 3'), G, R(b' 7#'), L, R(b' ;')], [(40, b'\x03')],
        [rb'\.{10,}' + RPT % b'1' + rb'\x1b\[\?25h 7#\r\n7\r\n1 1\("\."\$ 1\)\r\n', rb' ;\r\n\r\nErr s .*\r\nD:0:\r\nR:0\r\n\x1b\[\?25h']),
    'Ctrl-C stops a program (unchecked)': (False, [R(b'1 1("."$ 1)'), R(b' 1 2 3'), G, R(b' 7#'), L], [(40, b'\x03')],
        [rb'\.{10,}\x1b\[\?25h 7#\r\n7\r\n1 1\("\."\$ 1\)\r\n']),
    'Ctrl-C stops a typed line': (None, [R(b' 1("."$ 1)'), R(b' 8#')], [(40, b'\x03')], [rb'\.{10,}.* 8#\r\n8$']),
    'a key pressed while the program runs is held for it': (
        None, [R(b' 0i! 1( i@1+:i! 3000<) 0?#'), R(b' 6#')], [(28, b'A')], [rb'0\?#\r\n65 6#\r\n6$']),
    'a key held when the program ends is let go': (
        None, [R(b' 0i! 1( i@1+:i! 3000<)'), R(b' 6#')], [(24, b'A')], [rb'3000<\)\r\n 6#\r\n6$']),
    # /~ with an empty stack: the first finds the dummy cell and prints a
    # cursor sequence of no meaning (an underflow is found after the
    # character has run); the next is stopped before anything is written
    # past the stack's spare bytes, so word A survives. Then /~ works.
    'a /~ with nothing under it is s, and word A survives it': (
        True, [R(b'1 [A "a"$]'), G, R(b' "/~/~/~/~/~x"$'), R(b' A'), R(b' 1 2 3 4 "/~/~."$ A')], [],
        [rb'\r\nErr s @ 0,15\r\nD:0:\r\nR:0\r\n\x1b\[\?25h A\r\na 1 2 3 4 "/~/~\."\$ A\r\n'
         rb'\x1b\[4;5H\x1b\[2;3H\.a$']),
    'the break key is on again for the next line': (
        None, [R(b' 1 %d.' % 0), R(b' 1("."$ 1)'), R(b' 8#')], [(60, b'\x03')], [rb'\.{10,}.* 8#\r\n8$']),
}


def win32_target(exe):
    """The Windows editor builds (B8SE.EXE, B8SEU.EXE and the like): files on a
    disk, named as typed (and found whatever their case, as Windows does),
    not padded; ^X ends the process."""
    from harness_win32 import Run as WRun, symbols as wsymbols
    sy = wsymbols(exe[:-4] + '.map')

    def fname(files, name):
        return next((k for k in files if k.lower() == name.lower()), name)
    return dict(sy=sy, cpm=False, disk=True, pad=False,
                checked=not exe[:-4].endswith('U'), default=b'PROG.B8S', fname=fname,
                heaplim=sy['HEAPLIM'] << 8, prog=lambda f: {b'PROG.B8S': f},
                run=lambda steps, timed, files: WRun(exe, b'', steps, mode='editor', timed=timed, files=files))


def check_editor(base, verbose=True, target=None):
    """Run every session against base.hex/.lst; return the number that failed."""
    name = os.path.basename(base)
    if target is None:
        sy = symbols(base + '.lst')
        cpm, checked = '-cpm' in name, name.endswith('-chk')
        mode = 'cpm-editor' if cpm else 'editor'
        disk = cpm
        prog = lambda f: {b'PROG    B8S': f + b'\x1a' * (-len(f) % 128)}
        mkrun = lambda steps, timed, files: Run(base + '.hex', base + '.lst', b'', steps, cpu='z80',
                                                mode=mode, timed=timed, files=files)
    else:
        sy, cpm, checked, disk = target['sy'], target['cpm'], target['checked'], target['disk']
        prog, mkrun = target['prog'], target['run']
    fails = 0

    def report(ok, title, r, got, exp=None):
        nonlocal fails
        fails += not ok
        if verbose or not ok:
            print(f'  {"ok  " if ok else "FAIL"} {title}')
        if ok:
            return
        if exp is None:
            print(f'     ended={r.ended}; got {got[-300:]!r}')
            return
        k = next((i for i in range(min(len(got), len(exp))) if got[i] != exp[i]), min(len(got), len(exp)))
        print(f'     ended={r.ended}; first difference at byte {k} of {len(got)}/{len(exp)}')
        print(f'     got {got[max(0, k - 60):k + 60]!r}')
        print(f'     exp {exp[max(0, k - 60):k + 60]!r}')
        a, b = screen(got), screen(exp)
        j = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), None)
        print('     on the screen: ' + ('the same' if a == b else f'row {j}: got {a[j][:70] if j is not None else None!r} exp {b[j][:70] if j is not None else None!r}'))

    todo = [(t, None, st) for t, st in sessions().items()]
    todo += [(t, f, st) for t, (f, st) in CPM_SESSIONS.items()] if disk else [(t, None, st) for t, st in GEN_SESSIONS.items()]
    if checked:
        todo += [(t, None, st) for t, st in CHK_SESSIONS.items()]
    for title, file, steps in todo:
        files = {} if file is None else prog(file)
        ed = Ed(sy, cpm, checked, dict(files), target)
        left = False
        for step in steps:
            try:
                if not ed.type(step):
                    left = True
                    break
            except Exception:
                print('  (the model failed in:', title, step, ')')
                raise
        exp, timed = bytes(ed.out), ed.timed
        r = mkrun(ed.chunks, timed, dict(files))
        got = r.run()
        ok = got == exp and not r.timed
        ok = ok and (r.ended == 'exit' if left else r.ended == 'needkey' and not r.stages)
        if disk:
            ok = ok and r.files == ed.files
            if r.files != ed.files and got == exp:
                print('     files:', {k: v[:40] for k, v in r.files.items()}, 'exp', {k: v[:40] for k, v in ed.files.items()})
        report(ok, title, r, got, exp)
    for title, (only, steps, timed, pats) in TIMED.items():
        if only is not None and only != checked:
            continue
        steps = [s.replace(b' 1 0.', b' 1 %d.' % (sy['LET'] + 0x7B)) for s in steps]
        timed = [(n + len(SHOW), k) for n, k in timed]   # (the counts are from after the start's SHOW)
        r = mkrun(steps, timed, None)
        got = r.run()
        at, ok = 0, r.ended == 'needkey' and not r.stages
        for p in pats:
            m = re.compile(p, re.S).search(got, at)
            ok, at = ok and bool(m), m.end() if m else at
        report(ok, title, r, got)
    print(f'{name}:', 'PASS' if not fails else f'{fails} FAILED')
    return fails


if __name__ == '__main__':
    builds = sorted(f[:-4] for f in glob.glob(os.path.join(sys.argv[1], '*.hex'))
                    if re.search(r'-ed(-chk)?\.hex$', f))
    sys.exit(1 if sum(check_editor(b, '-v' in sys.argv) for b in builds) else 0)
