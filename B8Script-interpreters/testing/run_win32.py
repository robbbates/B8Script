"""Run every Windows build in a folder (from build_win32.sh) through the suite.

usage: run_win32.py [DIR] [-v] [--nogames]     (DIR defaults to out/win32)

The runners (B8SWIN, B8SWINC) go through run_tests.check(): the whole
suite, the machine-code tests below, LOOSE or CHK, Tiny BASIC, ERRS and the
break-key tests with the count of looks. The editor builds (B8SWINE,
B8SWINEC) are typed at by test_editor.py's sessions, plus a session of
their own for the arrow keys as Windows sends them. Then a few things only
Windows has: the report goes to the standard error handle and the program's
output to standard output, the console's input mode is put back at the
end, input that is not a console is read with ReadFile, and a program on
the command line in quotes, or no program at all.
"""
import sys, os, glob, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_win32 import Run, plat, symbols, HIN, HOUT
import tests
from run_tests import check
import test_editor

# Machine-code tests: x86 code, entered by CALL with the cells above the
# return address, a dword each (see h_grave in the source). The loader
# writes the RET (C3h).
#   mcdouble: POP EDX / POP EAX / ADD EAX,EAX / PUSH EAX / PUSH EDX: doubles
#             the top cell.
#   mcpush:   POP EDX / PUSH 7 / PUSH EDX: pushes 7.
#   mcarena:  POP EDX / MOV EAX,EBX / MOV AX,016Eh / MOV AX,[EAX] / PUSH EAX
#             / PUSH EDX: EBX's high word is the arena's, so this fetches
#             variable x (at 016Eh).
#   mcjunk:   POP EDX / PUSH 0FFFF016Eh / PUSH EDX: a cell with a high word
#             of junk becomes x's address all the same (only the low word
#             counts).
tests.MC['win32'] = [
    ('mcdouble', b'8_:d! `5A5801C05052 ; 21 d@` #', b'', b'42'),
    ('mcpush', b'8_:d! `5A6A0752 ; 5 d@` # #', b'', b'75'),
    ('mcarena', b'1234x! 16_:d! `5A89D866B86E01668B005052 ; d@` #', b'', b'1234'),
    ('mcjunk', b'99x! 16_:d! `5A686E01FFFF52 ; 3 d@` @# #', b'', b'993'),
]


def windows_only(exe, checked, editor, verbose):
    """Return the number of failures."""
    fails = 0

    def ok(cond, what, r=None):
        nonlocal fails
        if not cond:
            fails += 1
            print(f'  FAIL {what}' + (f': ended={r.ended} out={bytes(r.out)[-120:]!r}' if r else ''))
        elif verbose:
            print('  ok  ', what)

    mode = 'editor' if editor else 'runner'
    if not editor:
        # output to standard output, the report to standard error
        r = Run(exe, b'"abc"$ 1 0/', b'')
        o = r.run()
        k = o.find(b'\r\nErr') if checked else len(o)
        ok(o.startswith(b'abc') and r.handles[:k] == ['out'] * k and r.handles[k:] == ['err'] * (len(o) - k)
           and (k < len(o)) == checked, 'the program writes to stdout, the report to stderr', r)
        # the console's mode is put back at the end, also after a break
        for p, timed in ((b'1 2+#', ()), (b'1(1)', [(0, b'\x03')])):
            r = Run(exe, p, b'', timed=timed)
            r.run()
            ok(r.modes[0] == (HIN, 0) and r.modes[-1] == (HIN, 0x1F7) and r.ended == 'exit',
               f'the input mode is raw, then put back ({p!r})', r)
        # ANSI sequences: virtual terminal processing is turned on for the
        # output, once, at the start (a redirected output just fails the call)
        for oc in (True, False):
            r = Run(exe, b'"/[[2J/[[Hhi"$', b'', outcon=oc)
            o = r.run()
            ok(o == b'\x1b[2J\x1b[Hhi' and [x for x in r.modes if x[0] == HOUT] == [(HOUT, 7)]
               and r.modes[0] == (HIN, 0) and r.ended == 'exit',
               f'VT processing asked for on the output (output a console: {oc})', r)
        # timed waits: the high-resolution timer, set once per wait, so 51
        # waits of 20 ms take about 1 s. Without it (Windows before 10 1803)
        # plain waits end on the 15.625 ms tick: about 31 ms each, 1.6 s.
        # A key ends the wait at once either way
        for hires in (True, False):
            r = Run(exe, b'20?# 1 1( 20?; 1+:51<); 7#', b'', hires=hires)
            o = r.run()
            ms = r.waited
            ok(o == b'07' and ((1000 <= ms <= 1060) if hires else (1550 <= ms <= 1650))
               and (r.timerwaits >= 51) == hires
               and (r.calls.get('SetWaitableTimer', 0) >= 51) == hires,
               f'51 waits of 20 ms (timer: {hires}, waited {ms} ms)', r)
            r = Run(exe, b'1000?#', b'', timed=[(0, b'k')], hires=hires)
            o = r.run()
            ok(o == b'107' and r.waited < 5, f'a key ends a timed wait at once (timer: {hires})', r)
        # input that is not a console: bytes from ReadFile, and the end of
        # it ends the program; the break check does not read it
        r = Run(exe, b'0?# 0i! 1( i@1+:i! 3000<) 0?# -9?; 0?# 0?# "no"$', b'AB12\rC', console=False)
        o = r.run()
        ok(o == b'65661267' and r.ended == 'exit', 'input from a pipe', r)
        # the file named in quotes, and no file at all
        r = Run(exe, b'"q"$', b'', cmdline=b'"C:\\B8 dir\\B8SWIN.EXE"  "PROG.B8S"')
        ok(r.run() == b'q' and r.ended == 'exit', 'a quoted command line', r)
        r = Run(exe, b'"q"$', b'', cmdline=b'B8SWIN.EXE')
        ok(r.run() == b'' and r.ended == 'exit', 'no file named', r)
        r = Run(exe, b'"q"$', b'', cmdline=b'B8SWIN.EXE NOSUCH.B8S')
        ok(r.run() == b'' and r.ended == 'exit', 'no such file', r)
    else:
        # the arrow keys as Windows sends them (key events with no
        # character): left 91h, right 93h in the harness's input
        steps = [b'1 "ac"$\x91\x91\x91b\x93\x93\x93\r', b'\x0c', b'\x07']
        r = Run(exe, b'', steps, mode='editor', files={})
        o = r.run()
        ok(o.endswith(b'1 "abc"$\r\n\r\nabc') and r.ended == 'needkey', 'the arrow keys (virtual keys)', r)
        # the console's mode is put back when the editor is left
        r = Run(exe, b'', [b'\x18'], mode='editor', files={})
        r.run()
        ok(r.modes[0] == (HIN, 0) and r.modes[-1] == (HIN, 0x1F7) and (HOUT, 7) in r.modes
           and r.ended == 'exit', 'the input mode is put back at ^X; VT output on', r)
        if checked:
            r = Run(exe, b'', [b' "abc"$ 1 0/\r'], mode='editor', files={})
            o = r.run()
            k = o.find(b'\r\nErr')
            j = o.find(b'Rtn 0\r\n') + 7
            ok(k > 0 and set(r.handles[k:j]) == {'err'} and set(r.handles[:k]) == {'out'},
               'the editor\'s report goes to stderr, the echo to stdout', r)
    return fails


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    d = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out/win32')
    verbose = '-v' in sys.argv
    games = '--nogames' not in sys.argv
    total = 0
    for exe in sorted(glob.glob(d + '/*.EXE')):
        name = os.path.basename(exe)[:-4]
        mapf = exe[:-4] + '.map'
        checked = name.endswith('C')
        editor = name.startswith('B8SWINE')
        if editor:
            total += test_editor.check_editor(exe[:-4], verbose=verbose, target=test_editor.win32_target(exe))
        else:
            def runner(p, i, timed=None, exe=exe):
                r = Run(exe, p, i, timed=timed or ())
                o = r.run()
                runner.last = r
                return o, r.ended
            total += check(runner, name, 'win32', False, checked, 0xC3, games=games,
                           verbose=verbose, plat=plat(mapf))
        f = windows_only(exe, checked, editor, verbose)
        print(f'{name}: Windows: {"PASS" if not f else str(f) + " FAILED"}')
        total += f
    sys.exit(1 if total else 0)


if __name__ == '__main__':
    main()
