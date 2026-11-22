"""A strict checker for the Windows builds' hand-laid PE files.

usage: chkpe.py FILE.EXE...

Every rule the PE/COFF specification gives for an i386 console image that
the loader reads is checked, conservatively (no trick that depends on a
Windows version is accepted): the DOS header's e_lfanew, the PE signature,
the COFF header (i386, executable, relocations stripped, not a DLL), the
PE32 optional header (alignments, ImageBase, sizes rounded as they must
be, subsystem and its version, stack and heap sizes, no DYNAMICBASE, 16
data directories), the section table (aligned, in order, no overlap, inside
the file and the image), the entry point (inside the raw data of an
executable code section) and the import table (well formed, kernel32.dll
only, every function one kernel32 exports, lookup table and IAT alike, the
IAT directory covering the IAT). Prints OK or every problem found, and a
line of sizes. parse() is also used by harness_win32.py.
"""
import struct, sys

# The kernel32 functions a build may import. All are kernel32 exports on
# every Windows NT version since 3.51 (and in Windows 95 too), except
# CreateWaitableTimerExW, which needs Windows Vista: the builds import it, so
# they start on Vista and later (its high-resolution flag needs Windows 10
# 1803; earlier versions refuse the flag and the builds use plain waits).
KERNEL32 = {
    'GetStdHandle', 'GetConsoleMode', 'SetConsoleMode', 'GetCommandLineA',
    'CreateFileA', 'ReadFile', 'WriteFile', 'CloseHandle',
    'WaitForSingleObject', 'ReadConsoleInputA', 'PeekConsoleInputA',
    'WaitForMultipleObjects', 'CreateWaitableTimerExW', 'SetWaitableTimer',
    'GetNumberOfConsoleInputEvents', 'GetTickCount', 'ExitProcess', 'Sleep',
    'FlushFileBuffers', 'GetLastError', 'SetFilePointer', 'GetFileSize',
}

IMAGE_SCN_CNT_CODE = 0x20
IMAGE_SCN_CNT_INITIALIZED_DATA = 0x40
IMAGE_SCN_CNT_UNINITIALIZED_DATA = 0x80
IMAGE_SCN_MEM_EXECUTE = 0x20000000
IMAGE_SCN_MEM_READ = 0x40000000
IMAGE_SCN_MEM_WRITE = 0x80000000


class PE:
    pass


def rup(v, a):
    return (v + a - 1) // a * a


def parse(path):
    """Read a PE32 file into a PE object: the header fields used here, the
    sections, the data directories and the imports (dll, [(name, iat_rva)]).
    Raises ValueError on anything too broken to go on with."""
    d = open(path, 'rb').read()
    p = PE()
    p.data = d
    if d[:2] != b'MZ':
        raise ValueError('no MZ signature')
    p.lfanew = struct.unpack_from('<I', d, 0x3C)[0]
    o = p.lfanew
    if d[o:o + 4] != b'PE\0\0':
        raise ValueError('no PE signature at e_lfanew')
    (p.machine, p.nsect, p.timestamp, p.symptr, p.nsyms, p.optsize,
     p.chars) = struct.unpack_from('<HHIIIHH', d, o + 4)
    oh = o + 24
    p.opt_off = oh
    f = struct.unpack_from('<HBBIIIIIIIIIHHHHHHIIIIHHIIIIII', d, oh)
    (p.magic, p.lmaj, p.lmin, p.size_code, p.size_init, p.size_uninit, p.entry,
     p.base_code, p.base_data, p.image_base, p.sect_align, p.file_align,
     p.os_maj, p.os_min, p.img_maj, p.img_min, p.sub_maj, p.sub_min, p.win32ver,
     p.size_image, p.size_headers, p.checksum, p.subsystem, p.dll_chars,
     p.stack_res, p.stack_com, p.heap_res, p.heap_com, p.loader_flags,
     p.ndirs) = f
    p.dirs = [struct.unpack_from('<II', d, oh + 96 + 8 * i) for i in range(min(p.ndirs, 16))]
    p.sections = []
    so = oh + p.optsize
    p.sect_off = so
    for i in range(p.nsect):
        name, vs, va, rs, rp, rel, ln, nrel, nln, ch = struct.unpack_from('<8sIIIIIIHHI', d, so + 40 * i)
        p.sections.append(dict(name=name.rstrip(b'\0'), vsize=vs, va=va, rsize=rs, rptr=rp,
                               relptr=rel, lnptr=ln, nrel=nrel, nln=nln, chars=ch))
    p.headers_end = so + 40 * p.nsect
    return p


def rva2off(p, rva, n=1):
    """The file offset of n bytes at rva, or None if they are not all in one
    section's raw data (or in the headers)."""
    if rva + n <= p.size_headers:
        return rva
    for s in p.sections:
        if s['va'] <= rva and rva + n <= s['va'] + min(s['rsize'], rup(s['vsize'], 1)):
            return s['rptr'] + rva - s['va']
    return None


def cstr(p, rva, what, errs):
    off = rva2off(p, rva)
    if off is None:
        errs.append(f'{what}: RVA {rva:#x} is not in the file')
        return None
    end = p.data.find(b'\0', off)
    if end < 0:
        errs.append(f'{what}: no NUL')
        return None
    s = p.data[off:end]
    if not s or any(c < 0x20 or c > 0x7E for c in s):
        errs.append(f'{what}: not a plain ASCII name: {s!r}')
    if rva2off(p, rva, end - off + 1) is None:
        errs.append(f'{what}: runs out of its section')
    return s.decode('latin-1')


def imports(p, errs):
    """Check the import directory; return [(dll, [(name, iat_rva)])]."""
    rva, size = p.dirs[1]
    out = []
    if not rva:
        errs.append('no import directory')
        return out
    if rva % 4:
        errs.append('the import directory is not 4-aligned')
    i = 0
    while True:
        off = rva2off(p, rva + 20 * i, 20)
        if off is None:
            errs.append('the import directory runs out of the raw data')
            return out
        oft, ts, fwd, name, ft = struct.unpack_from('<IIIII', p.data, off)
        if not any((oft, ts, fwd, name, ft)):
            break
        dll = cstr(p, name, 'DLL name', errs)
        if ts or fwd:
            errs.append(f'{dll}: TimeDateStamp/ForwarderChain not 0 (a bound import)')
        if not oft or not ft:
            errs.append(f'{dll}: no import lookup table or no IAT')
        if ft % 4 or oft % 4:
            errs.append(f'{dll}: lookup table or IAT not 4-aligned')
        funcs, k = [], 0
        while True:
            lo, io = rva2off(p, oft + 4 * k, 4), rva2off(p, ft + 4 * k, 4)
            if lo is None or io is None:
                errs.append(f'{dll}: the lookup table or the IAT runs out of the raw data')
                break
            le, ie = struct.unpack_from('<I', p.data, lo)[0], struct.unpack_from('<I', p.data, io)[0]
            if le != ie:
                errs.append(f'{dll}: entry {k}: lookup table {le:#x} and IAT {ie:#x} differ')
            if le == 0:
                break
            if le & 0x80000000:
                errs.append(f'{dll}: entry {k} imports by ordinal')
            else:
                if le % 2:
                    errs.append(f'{dll}: hint/name entry {le:#x} not 2-aligned')
                if rva2off(p, le, 2) is None:
                    errs.append(f'{dll}: hint/name entry {le:#x} not in the file')
                else:
                    funcs.append((cstr(p, le + 2, f'{dll} entry {k}', errs), ft + 4 * k))
            k += 1
        out.append((dll, funcs))
        i += 1
    if size < 20 * (i + 1):
        errs.append(f'import directory size {size} is less than its {i + 1} entries')
    return out


def check(path):
    errs = []
    try:
        p = parse(path)
    except (ValueError, struct.error) as e:
        print(f'{path}: FAIL: {e}')
        return 1
    d = p.data
    E = errs.append
    # DOS and COFF headers
    if p.lfanew % 8 or p.lfanew < 0x40 or p.lfanew + 24 + 224 > len(d):
        E(f'e_lfanew {p.lfanew:#x} is odd or out of place')
    if p.machine != 0x14C:
        E(f'Machine {p.machine:#x}, not i386')
    if p.nsect < 1 or p.nsect > 2:
        E(f'{p.nsect} sections (one or two are expected)')
    if p.symptr or p.nsyms:
        E('a COFF symbol table in an image')
    if p.optsize != 224:
        E(f'SizeOfOptionalHeader {p.optsize}, not 224')
    for bit, what in ((0x1, 'RELOCS_STRIPPED'), (0x2, 'EXECUTABLE_IMAGE'), (0x100, '32BIT_MACHINE')):
        if not p.chars & bit:
            E(f'Characteristics lack {what}')
    if p.chars & 0x2000:
        E('Characteristics say DLL')
    if p.chars & ~0x010F & 0xFFFF:
        E(f'unexpected Characteristics bits {p.chars:#x}')
    # optional header
    if p.magic != 0x10B:
        E(f'optional header magic {p.magic:#x}, not PE32')
    if p.image_base != 0x400000:
        E(f'ImageBase {p.image_base:#x}, not 400000h')
    if p.image_base % 0x10000:
        E('ImageBase not a multiple of 64K')
    if p.sect_align != 0x1000:
        E(f'SectionAlignment {p.sect_align:#x}, not 1000h')
    if p.file_align != 0x200:
        E(f'FileAlignment {p.file_align:#x}, not 200h')
    if (p.os_maj, p.os_min) < (4, 0):
        E('MajorOperatingSystemVersion below 4.0')
    if (p.sub_maj, p.sub_min) < (4, 0):
        E('subsystem version below 4.0')
    if p.win32ver:
        E('Win32VersionValue not 0')
    if p.subsystem != 3:
        E(f'Subsystem {p.subsystem}, not the console (3)')
    if p.dll_chars & 0x40:
        E('DYNAMICBASE is set, but there are no relocations')
    if p.dll_chars:
        E(f'DllCharacteristics {p.dll_chars:#x} (none expected)')
    if p.loader_flags:
        E('LoaderFlags not 0')
    if p.ndirs != 16:
        E(f'NumberOfRvaAndSizes {p.ndirs}, not 16')
    if not (0x10000 <= p.stack_res <= 0x1000000 and 0x1000 <= p.stack_com <= p.stack_res
            and p.stack_com % 0x1000 == 0 and p.stack_res % 0x1000 == 0):
        E(f'stack reserve/commit {p.stack_res:#x}/{p.stack_com:#x} not sensible')
    if not (0x1000 <= p.heap_res <= 0x1000000 and 0x1000 <= p.heap_com <= p.heap_res):
        E(f'heap reserve/commit {p.heap_res:#x}/{p.heap_com:#x} not sensible')
    if p.size_headers % p.file_align or p.size_headers < p.headers_end:
        E(f'SizeOfHeaders {p.size_headers:#x} not rounded, or less than the headers ({p.headers_end:#x})')
    if p.size_headers > p.sect_align:
        E('SizeOfHeaders larger than one SectionAlignment')
    if any(d[p.headers_end:p.size_headers]):
        E('bytes after the section table, inside SizeOfHeaders, are not zero')
    for i, (rva, size) in enumerate(p.dirs):
        if i not in (1, 12) and (rva or size):
            E(f'data directory {i} is used ({rva:#x}, {size:#x})')
    if p.dirs[5] != (0, 0):
        E('a relocation directory')
    # sections
    va = rup(p.size_headers, p.sect_align)
    rp = p.size_headers
    code = init = uninit = 0
    for s in p.sections:
        n = s['name'].decode('latin-1')
        if s['va'] != va:
            E(f'section {n}: VirtualAddress {s["va"]:#x}, expected {va:#x} (in order, no gaps)')
        if s['rptr'] % p.file_align or s['rsize'] % p.file_align:
            E(f'section {n}: raw pointer or size not a multiple of FileAlignment')
        if s['rsize'] and s['rptr'] < rp:
            E(f'section {n}: raw data overlaps what comes before it')
        if s['rptr'] + s['rsize'] > len(d):
            E(f'section {n}: raw data past the end of the file')
        if s['vsize'] == 0:
            E(f'section {n}: VirtualSize 0')
        if s['rsize'] > rup(s['vsize'], p.file_align):
            E(f'section {n}: raw size larger than the rounded VirtualSize')
        if s['relptr'] or s['lnptr'] or s['nrel'] or s['nln']:
            E(f'section {n}: relocations or line numbers in an image')
        ch = s['chars']
        if ch & ~(IMAGE_SCN_CNT_CODE | IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_CNT_UNINITIALIZED_DATA |
                  IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE):
            E(f'section {n}: unexpected Characteristics {ch:#x}')
        if not ch & IMAGE_SCN_MEM_READ:
            E(f'section {n}: not readable')
        if ch & IMAGE_SCN_CNT_CODE:
            code += s['rsize']
        if ch & IMAGE_SCN_CNT_INITIALIZED_DATA:
            init += s['rsize']
        va = rup(s['va'] + s['vsize'], p.sect_align)
        if s['rsize']:
            rp = s['rptr'] + s['rsize']
    if p.size_image != va:
        E(f'SizeOfImage {p.size_image:#x}, expected {va:#x}')
    if len(d) != rp:
        E(f'the file is {len(d):#x} bytes, but the raw data ends at {rp:#x}')
    if p.size_code != code:
        E(f'SizeOfCode {p.size_code:#x}, the code sections hold {code:#x}')
    if p.size_init != init:
        E(f'SizeOfInitializedData {p.size_init:#x}, the sections hold {init:#x}')
    cs = [s for s in p.sections if s['chars'] & IMAGE_SCN_CNT_CODE]
    if cs and p.base_code != cs[0]['va']:
        E('BaseOfCode is not the first code section')
    # the entry point: in the raw data of an executable code section
    es = [s for s in p.sections if s['va'] <= p.entry < s['va'] + s['rsize']]
    if not es:
        E(f'the entry point {p.entry:#x} is not in any section\'s raw data')
    elif not (es[0]['chars'] & IMAGE_SCN_CNT_CODE and es[0]['chars'] & IMAGE_SCN_MEM_EXECUTE):
        E('the entry point is not in an executable code section')
    # imports
    imp = imports(p, errs)
    if [dll.lower() for dll, _ in imp] != ['kernel32.dll']:
        E(f'imports from {[dll for dll, _ in imp]}, not kernel32.dll alone')
    names = [n for _, fs in imp for n, _ in fs]
    for n in names:
        if n not in KERNEL32:
            E(f'imports {n}, which is not a kernel32 function this checker knows')
    if len(set(names)) != len(names):
        E('a function is imported twice')
    rva, size = p.dirs[12]
    if imp and imp[0][1]:
        first, last = imp[0][1][0][1], imp[0][1][-1][1]
        if not (rva <= first and last + 8 <= rva + size):
            E(f'the IAT directory ({rva:#x}, {size}) does not cover the IAT {first:#x}-{last + 8:#x}')
    raw = sum(s['rsize'] for s in p.sections)
    print(f'{path}: {"OK" if not errs else "FAIL"}  {len(d)} bytes: headers {p.size_headers}, '
          f'raw data {raw}; imports {", ".join(names)}')
    for e in errs:
        print('   ', e)
    return 1 if errs else 0


if __name__ == '__main__':
    sys.exit(1 if sum(check(f) for f in sys.argv[1:]) else 0)
