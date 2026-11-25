; =============================================================================
;  B8Script interpreter for 32-bit Windows (x86, console subsystem)
;  Spec: docs/b8script.md (2026-11-24).
;
;  Assembler: NASM 2.16, flat binary output: the PE header is laid out by
;  hand at the top of this file, so the output IS the .EXE:
;
;      nasm -f bin -DCHECKED=1 -o B8S.EXE b8s-win32.asm
;      nasm -f bin -o B8SU.EXE b8s-win32.asm
;      nasm -f bin -DEDITOR=1 -DCHECKED=1 -o B8SE.EXE b8s-win32.asm
;      nasm -f bin -DEDITOR=1 -o B8SEU.EXE b8s-win32.asm
;
;  Those are the base builds. Add -DSPEED=0 for the small ones (B8SS.EXE,
;  B8SSU.EXE, B8SSE.EXE, B8SSEU.EXE) or -DSPEED=2 for the fast ones (B8SF*).
;
;  Three switches (the defaults below, or -D on the command line):
;    CHECKED  0 = no checks (spec: the programmer is responsible)
;             1 = starts with every variable at 0 and every word undefined,
;                 and stops on every error in the spec's table (and Ctrl-C)
;                 with the four-line report, on the standard error handle.
;    EDITOR   0 = a runner: B8S PROG.B8S loads the file, runs it, exits
;             1 = the line editor of the spec's suggested standard (the same
;                 editor as the Z80's, key for key); the file named on the
;                 command line is the program to start with.
;    SPEED    0 = small: the smallest build
;             1 = base, the default: the speed-ups that cost few bytes: a
;                 skip cache, a faster skip, '/' by a power of two as shifts,
;                 and (unchecked) a variable then '@' or '!' in one step (see
;                 "Speed-ups")
;             2 = fast: base, and a 256-entry jump table besides, with no
;                 size limit (see "The fast build")
;             Each goes with either setting of the other two.
;
;  In every build Ctrl-C stops a running program (an unchecked runner stops
;  without a word): see the console layer for the rules, the held key and
;  the break-off cell.
;
;  The console escapes of '$' (/{ /} /| /` /~) always send ANSI (VT100)
;  sequences: the output's console mode asks for them to be obeyed (see
;  the startup).
; =============================================================================

%ifndef CHECKED
%define CHECKED 0
%endif
%ifndef EDITOR
%define EDITOR  0
%endif
%ifndef SPEED
%define SPEED   1               ; 0 = small, 1 = base, 2 = fast
%endif
%assign FAST    SPEED/2         ; (1: the fast build)
%assign SBASE   SPEED-FAST*2    ; (1: the base build)
%if SBASE || FAST
 %define QK     1               ; (the speed-ups: base, or the fast build)
%else
 %define QK     0
%endif
%if QK && !CHECKED && !FAST
 %define SBASEU 1               ; (and those that only the unchecked base
%else                           ;   builds take; the fast build has its own)
 %define SBASEU 0
%endif

; -----------------------------------------------------------------------------
;  The machine model
;
;  B8Script is defined for a 64 KB machine with 16-bit cells, and that is what
;  runs here. The 64 KB arena sits at ARENA (00410000h), a multiple of 64 KB,
;  inside the image (its last 64 KB of uninitialised space): the B8Script
;  address a is the byte at ARENA + a. Because the arena is 64 KB aligned,
;  "ARENA + a" is simply a 32-bit register whose high word is 0041h and whose
;  low word is a. Every cell the interpreter keeps in a 32-bit register or
;  stack slot is kept in that form, so it is at once the 16-bit cell (its low
;  word) and a pointer to that cell's address:
;
;    EBX  TOS. 16-bit operations work on BX; EBX's high word is always 0041h,
;         so [EBX] is the byte TOS points at.
;    ESI  IP: a pointer to the next program character (LODSB reads it).
;    ESP  the data stack: one dword per cell, low word the cell, high word
;         0041h. [ESP] is NOS. It is the thread's own stack (the API calls
;         push their arguments below it). V_DSTOP holds ESP for the empty
;         stack.
;    EDI  the return stack pointer: dword entries (IP values and cells parked
;         with '{', all in the same form), growing down from RSTOP. A pop is
;         MOV r,[EDI] / SCASD (SCASD only steps EDI on by 4).
;    EBP  the address of `next`: every handler ends with JMP EBP (2 bytes),
;         and the interpreter's own variables, the import address table
;         and the pointers to the routines called most (see CALLP) lie
;         within 127 bytes of `next`, so [EBP+d8] reaches them in 3-byte
;         instructions. (V() below names them.)
;    EAX ECX EDX  scratch. (The Windows API keeps EBX, ESI, EDI and EBP.)
;
;  Memory map of the arena (B8Script addresses):
;    0000h-00FFh  page zero: unused, and left zero. An undefined word's cell
;                 holds 0000h, so calling it runs into the NUL at 0000h; the
;                 checked build sees that the IP is 0001h there and reports U.
;    0100h        the letter page: A-Z at +00h..+33h, a-z at +40h..+73h (a
;                 word's cell is 64 bytes below its variable's), the held key
;                 at +7Ah, the break-off cell at +7Bh, the heap pointer at +7Ch,
;                 and the -n? line buffer at +80h..+FFh (127 characters and CR;
;                 the editor's input line uses it too)
;    0200h        PROG: the program text, ending in NUL; the heap starts after
;                 the NUL and may grow up to the heap limit, FF00h
;    FF00h-FFFFh  above the limit: not the program's (unused)
;  The stacks are outside the arena: the return stack is 112 entries below
;  RSTOP (in the image's uninitialised space below the arena) and the data
;  stack is the thread's stack (127 cells in the checked builds, as deep as
;  the 1 MB stack reserve allows in the others). The base and fast builds
;  keep their skip cache (64 entries, 512 bytes) after the interpreter's
;  variables, in the image's uninitialised space below NAMEBUF.
;
;  The whole image (code, arena) is one section, readable, writable and
;  executable, so machine code can run in the arena (see h_grave).
; -----------------------------------------------------------------------------

IB      equ     400000h         ; ImageBase
SECTVA  equ     1000h           ; the section's RVA
ARENA   equ     410000h         ; the 64 KB B8Script memory (RVA 10000h)
IMGSIZE equ     20000h          ; SizeOfImage: the arena is its last 64 KB

LET     equ     0100h           ; the letter page (a B8Script address)
HELD    equ     LET+7Ah         ; a key read by the break check, held for the
                                ;   next '?' (0: none)
BRKOFF  equ     LET+7Bh         ; the break-off cell: a non-zero byte here
                                ;   makes Ctrl-C a key like any other
HEAP    equ     LET+7Ch         ; the heap pointer (a cell)
LINEBUF equ     LET+80h         ; the -n? line buffer
PROG    equ     0200h           ; the program text
HEAPLIM equ     0FFh            ; the heap limit, as a page: FF00h
LIMIT   equ     HEAPLIM*256
MAXFILE equ     LIMIT-PROG-3    ; the most a file may bring (room for CR LF NUL)

RSTOP   equ     IB+0FF00h       ; the empty return stack (it grows down)
RSMAX   equ     112             ; return stack entries (checked builds)
DSMAX   equ     127             ; data stack cells (checked builds)
NAMEBUF equ     IB+0F000h       ; the file's name, as typed (up to 3.5 KB)
%if QK
NSKC    equ     64              ; the skip cache's entries (base)
%endif

; -----------------------------------------------------------------------------
;  The PE header, by the documented rules: a 64-byte DOS header whose
;  e_lfanew points at the PE signature, the COFF header, the PE32 optional
;  header with its 16 data directories, and one section header. Then zeros
;  up to SizeOfHeaders (200h, one FileAlignment).
; -----------------------------------------------------------------------------
        bits    32
        section hdr start=0 vstart=IB
        dw      'MZ'                    ; e_magic
        times   3Ch-($-$$) db 0
        dd      pe-IB                   ; e_lfanew
pe:     db      'PE',0,0
        dw      14Ch                    ; Machine: i386
        dw      1                       ; NumberOfSections
        dd      0                       ; TimeDateStamp
        dd      0, 0                    ; no COFF symbols
        dw      opthdr_end-opthdr       ; SizeOfOptionalHeader (224)
        dw      010Fh                   ; RELOCS_STRIPPED, EXECUTABLE_IMAGE,
                                        ;   LINE_NUMS_STRIPPED,
                                        ;   LOCAL_SYMS_STRIPPED, 32BIT_MACHINE
opthdr: dw      10Bh                    ; PE32
        db      1, 0                    ; linker version
        dd      RAWSIZE                 ; SizeOfCode
        dd      RAWSIZE                 ; SizeOfInitializedData
        dd      0                       ; SizeOfUninitializedData
        dd      start-IB                ; AddressOfEntryPoint
        dd      SECTVA                  ; BaseOfCode
        dd      SECTVA                  ; BaseOfData
        dd      IB                      ; ImageBase
        dd      1000h                   ; SectionAlignment
        dd      200h                    ; FileAlignment
        dw      4, 0                    ; OS version 4.0
        dw      0, 0                    ; image version
        dw      4, 0                    ; subsystem version 4.0
        dd      0                       ; Win32VersionValue
        dd      IMGSIZE                 ; SizeOfImage
        dd      200h                    ; SizeOfHeaders
        dd      0                       ; CheckSum
        dw      3                       ; Subsystem: Windows console
        dw      0                       ; DllCharacteristics: none
        dd      100000h, 1000h          ; stack reserve, commit
        dd      100000h, 1000h          ; heap reserve, commit
        dd      0                       ; LoaderFlags
        dd      16                      ; NumberOfRvaAndSizes
        dd      0, 0                    ; 0 export
        dd      idesc-IB, idesc_end-idesc ; 1 import
        times   10*2 dd 0               ; 2-11
        dd      iat-IB, iat_end-iat     ; 12 IAT
        times   3*2 dd 0                ; 13-15
opthdr_end:
        db      '.text',0,0,0           ; the one section
        dd      IMGSIZE-SECTVA          ; VirtualSize: code, then zeros up to
                                        ;   the arena's end
        dd      SECTVA                  ; VirtualAddress
        dd      RAWSIZE                 ; SizeOfRawData
        dd      200h                    ; PointerToRawData
        dd      0, 0                    ; no relocations, no line numbers
        dw      0, 0
        dd      0E0000060h              ; code, initialised data, execute,
                                        ;   read, write
        times   200h-($-$$) db 0

; =============================================================================
;  The code
; =============================================================================
        section text start=200h vstart=IB+SECTVA
tstart:
%define V(x) ebp+(x)-next               ; a variable or IAT slot near `next`

; The routines called from many places are called through a pointer near
; `next` (CALL [EBP+d8], 3 bytes, instead of 5): the pointers are at ptrs,
; after the IAT. P_x says whether routine x has one in this build.
%define P_putc  1
%define P_waitk EDITOR
%define P_ekey  EDITOR
%define P_rdnum EDITOR
%define P_find  EDITOR
%define P_pmsg  CHECKED
%define P_pdec  CHECKED
%define P_hexc  1
%macro  CALLP 1
 %if P_%1
        call    [V(p_%1)]
 %else
        call    %1
 %endif
%endmacro
%macro  JMPP 1
 %if P_%1
        jmp     [V(p_%1)]
 %else
        jmp     %1
 %endif
%endmacro
%define NEXTJ   jmp ebp                 ; (how DIVCODE ends: the fast build's
                                        ;   own '/' has the dispatcher there)

; NEXTF (the fast build): the dispatcher. It is `next`, and it is inline at
; the end of the fast build's own handlers, so they never jump back to it.
; Every handler is entered with EAX = its character, zero-extended. NEXTD is
; the one after a digit: through dtabd, where a digit goes on with the number.
%macro  NEXTF 0
%if CHECKED
        call    chkstk                  ; both stacks, once per character
%endif
        movzx   eax,byte [esi]
        inc     esi
        jmp     [dtab+eax*4]
%endmacro
%macro  NEXTD 0
        movzx   eax,byte [esi]
        inc     esi
        jmp     [dtabd+eax*4]
%endmacro

; run0: start running at ESI. The heap starts after the stored program's
; NUL. TOS is popped: the data stack is as the last line left it. (The
; runner's startup runs on into it; in the editor builds it follows ^G.)
%macro  RUN0CODE 0
run0:   mov     edx,ARENA+PROG
.st1:   inc     edx
        cmp     byte [edx-1],0
        jne     .st1
        mov     [ARENA+HEAP],dx
%if CHECKED
        movzx   eax,dx                  ; '_' may not release below this
        mov     [V(v_npend)],eax
%endif
%if QK
        lea     eax,[edx-(ARENA+PROG)]  ; the text's length, NUL included: only
        mov     [v_tlen],eax            ;   skips that start inside it are kept
        push    edi                     ; the skip cache is emptied (a start of
        mov     edi,skc                 ;   0 matches no skip: every IP is in
        mov     ecx,2*NSKC              ;   the arena)
        xor     eax,eax
        rep     stosd
        pop     edi
%endif
        pop     ebx
        jmp     ebp
%endmacro

; ---- startup ----------------------------------------------------------------
; The data stack starts empty; the cell pushed here stands for TOS, as when
; the editor has the stack in memory: the run starts by popping it.
start:  mov     ebp,next
        mov     esi,ARENA+PROG
        mov     [V(v_dstop)],esp
        push    esi                     ; (the cell that stands for TOS)
        push    -10                     ; STD_INPUT_HANDLE
        call    [V(iat_GetStdHandle)]
        mov     [V(v_hin)],eax
        xchg    eax,edi                 ; (EDI = the input handle, for now)
        ; ANSI escape sequences: the output mode becomes processed output,
        ; wrap at the end of a line and virtual terminal processing (1+2+4),
        ; so the console obeys ESC [ ... as a terminal does. 1+2 is the
        ; console's usual output mode. On Windows before 10, or when the
        ; output is not a console, the call fails and nothing changes. The
        ; mode is left on at the end, which does no harm. (The arguments
        ; are pushed now, and the call made after the input's two.)
        push    7
        push    -11                     ; STD_OUTPUT_HANDLE
        call    [V(iat_GetStdHandle)]
        mov     [V(v_outh)],eax
        push    eax
        ; Raw keys: no echo, no line editing, Ctrl-C as a key (mode 0). If
        ; the input is not a console, GetConsoleMode fails, and the keys are
        ; read as bytes with ReadFile (see waitk).
        lea     ecx,[V(v_mode)]
        push    ecx
        push    edi
        call    [V(iat_GetConsoleMode)]
        mov     [V(v_iscon)],al
        push    0
        push    edi
        call    [V(iat_SetConsoleMode)]
        call    [V(iat_SetConsoleMode)] ; (the output's, pushed above)
        ; A high-resolution waitable timer for the timed waits of '?' (Windows
        ; 10 1803 and later). A plain wait only ends on the system's tick,
        ; every 15.6 ms, so 1? would take about 16 ms. Older Windows refuses
        ; the flag; then v_htm is 0 and the waits are plain ones.
        push    1F0003h                 ; TIMER_ALL_ACCESS
        push    2                       ; CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
        push    0
        push    0
        call    [V(iat_CreateWaitableTimerExW)]
        mov     [V(v_htm)],eax
        ; The command line: the program's own name, then the file's.
        call    [V(iat_GetCommandLineA)]
        xchg    eax,esi
        call    token
        call    token
        call    load                    ; (no file, or no such file: no text)
%if EDITOR
        mov     eax,6835323Fh           ; ESC [ ? 2 5 h: the editor shows the
        call    pseq                    ;   cursor when it starts, as after an
        jmp     edit                    ;   error or a break (edit0)
%else
        mov     edi,RSTOP               ; the return stack is empty
        mov     esi,ARENA+PROG          ; the IP
        RUN0CODE                        ; (on into run0)
%endif

; token: copy the next word of the command line at ESI to NAMEBUF, ending
; in NUL. A word is ended by a space, or is in double quotes. ESI is left
; after it (on the NUL at the end of the line, so another token is empty).
token:  mov     edi,NAMEBUF
.sp:    lodsb
        cmp     al,' '
        je      .sp
        mov     ah,' '
        cmp     al,22h
        jne     .ch
        mov     ah,al                   ; a quoted word ends at the quote
        lodsb
.ch:    test    al,al
        jz      .nul
        cmp     al,ah
        je      .end
        stosb
        lodsb
        jmp     .ch
.nul:   dec     esi
.end:   mov     byte [edi],0
        ret

; load: read the file named in NAMEBUF into PROG, and end the text with a
; NUL. No such file (or no name): no text, since ReadFile on the failed
; handle reads nothing (it sets the count to 0 first). The editor's ^R
; (cread) runs on into it, after setname.
%if EDITOR
cread:  call    setname
%endif
load:   xor     eax,eax
        push    eax                     ; hTemplateFile
        push    eax                     ; dwFlagsAndAttributes
        push    3                       ; OPEN_EXISTING
        push    eax                     ; lpSecurityAttributes
        push    1                       ; FILE_SHARE_READ
        push    80000000h               ; GENERIC_READ
        push    NAMEBUF
        call    [V(iat_CreateFileA)]
        push    eax                     ; (for CloseHandle)
        push    0
        lea     ecx,[V(v_cnt)]
        push    ecx
        push    MAXFILE
        push    ARENA+PROG
        push    eax
        call    [V(iat_ReadFile)]
%if EDITOR
        call    [V(iat_CloseHandle)]
%else
        pop     eax                     ; (the handle stays open)
%endif
        mov     eax,[V(v_cnt)]
        mov     byte [ARENA+PROG+eax],0 ; the end of the file counts as NUL
%if EDITOR
        ; The editor's text ends at the file's first ^Z (as in the CP/M
        ; builds) or NUL, and every line must end in LF: a last line
        ; without one is given a CR LF.
        mov     esi,ARENA+PROG
        mov     al,10                   ; (a file with no text needs nothing)
.ld1:   mov     ah,al                   ; AH = the character before
        lodsb
        cmp     al,1Ah
        je      .ld2
        test    al,al
        jnz     .ld1
.ld2:   dec     esi
        cmp     ah,10
        je      .ld3
        mov     word [esi],0A0Dh
        inc     esi
        inc     esi
.ld3:   mov     byte [esi],0
%endif
        ret


; ---- before the window: what its handlers jump to, within a short jump --
; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  mov     edx,esi
        mov     si,[ARENA+LET+eax*2]

; rpush: push EDX on the return stack, then next. Everything that pushes the
; return stack ends here, and the true ')' comes to rpoll.
;
; The break key is looked at here, so at every word call and loop-back (and
; block entry and '{'), but only one time in 256: V_PCNT counts them.
rpush:  sub     edi,4
        mov     [edi],edx
rpoll:  dec     byte [V(v_pcnt)]
        jnz     .rp1
        call    pollk
.rp1:   jmp     ebp

; negnum, for '-'
negnum: push    ebx
        CALLP   rdnum
        neg     bx
        jmp     ebp


; '_' ( n -- addr ): the heap pointer moves by n, a signed count; TOS is
; the old pointer. The checked build stops with H if the new top is not
; below the limit or is below the program's end (done in 32 bits, so a top
; that wraps round is caught too).
%macro  ALLOCCODE 0
alloc1: movzx   edx,word [ARENA+HEAP]
%if CHECKED
        movsx   eax,bx
        add     eax,edx
        cmp     eax,LIMIT
        jae     e_heap
        cmp     eax,[V(v_npend)]
        jb      e_heap
%endif
        add     [ARENA+HEAP],bx
        mov     bx,dx
        jmp     ebp
%endmacro

; '/' ( a b -- q r ): truncates toward zero, and r takes a's sign: x86's
; IDIV does exactly that. It is done in 32 bits, so that -32768 / -1 (whose
; quotient, 32768, does not fit in 16) wraps as the spec says instead of
; faulting. Dividing by 0 skips the IDIV in an unchecked build (two cells of
; no meaning: a and its sign); the checked build stops with Z. (The handler
; itself in an unchecked build; in a checked or base one its body, div1;
; the fast build's fs_div is another copy.)
%macro  DIVCODE 0
%if CHECKED
        test    bx,bx
        jz      e_zero
%endif
        pop     eax
        movsx   ecx,bx
%if QK
        lea     edx,[ecx-1]             ; (base: b a power of two? See DIVQ)
        test    edx,ecx
        jz      %%p
%%o:
%endif
        cwde
        cdq
%if CHECKED=0
        jecxz   %%z
%endif
        idiv    ecx
%%z:    mov     bx,ax
        push    ebx                     ; q
        mov     bx,dx                   ; r on top
        NEXTJ
%if QK
%%p:    DIVQ    %%o, %%z
%endif
%endmacro

; DIVQ (base): '/' by a power of two, 2^k with k from 0 to 14, is shifts,
; with IDIV's results: |a| >> k and |a| & (b - 1), both negated if a < 0
; (-32768 is its own |a|, as an unsigned 16 bits). EAX = a (its low word),
; ECX = b, EDX = b - 1. (A power of two or 0: an unchecked build divides by
; 0 the regular way, at %1.) On to %2 with AX = q and DX = r. Shifts cost
; more instructions than one IDIV, but far fewer cycles: IDIV takes 20 to
; 40 (12 on the newest), the shifts a handful.
%macro  DIVQ 2
%if CHECKED=0
        jecxz   %1
%endif
        bsf     ecx,ecx                 ; k
        test    ax,ax
        js      %%n
        and     dx,ax                   ; r
        shr     ax,cl                   ; q
        jmp     %2
%%n:    neg     ax                      ; |a|
        and     dx,ax
        shr     ax,cl
        neg     ax                      ; q
        neg     dx                      ; r
        jmp     %2
%endmacro

; PRLOOPCODE: the loop of '$' (h_print; in a checked build the routine
; prstr). It prints from EBX to the closing quote.
%macro  PRLOOPCODE 0
%%pr:   mov     al,[ebx]
        inc     ebx
        cmp     al,22h
%if CHECKED
        je      %%pr9
        test    al,al
        jz      e_dollar                ; a NUL first: Q
%else
        je      h_drop
%endif
        cmp     al,'/'
        jne     prput
        movzx   eax,byte [ebx]
        inc     ebx
        cmp     al,60h
        jb      %%pr0
        cmp     al,7Fh
        jb      pesc
%%pr0:  and     al,0BFh
prput:  CALLP   putc                    ; (/~ comes here with its 'H')
        jmp     %%pr
%if CHECKED
%%pr9:  ret
%endif
%endmacro

; PESCCODE: prstr (checked builds) and the escapes of '$'. (After the
; bodies of '[' and '`' in an unchecked build, so that h_print's loop
; reaches pesc; after the report in a checked one.)
%macro  PESCCODE 0
%if CHECKED
; prstr: print the string at EBX, to its closing quote, decoding '/' (this
; is '$', and the texts of the report). EBX is left past the quote. A NUL
; first is an error: Q.
prstr:  PRLOOPCODE
PRLOOP  equ     prstr                   ; (where the escapes go back to)
%else
PRLOOP  equ     h_print
%endif

; /~ ( row col addr -- ): the two cells under the string's address go.
; It comes before pesc: from there the short jumps reach h_print's loop.
; In a checked build the loop is the routine prstr: its return address
; goes, and hp1 calls it again afterwards. There each /~ first looks that
; its two cells are there, and is s if not, before it prints anything.
pat:
%if CHECKED
        pop     eax
        lea     eax,[esp+8]             ; ESP + 8 at the empty mark or above:
        cmp     eax,[V(v_dstop)]        ;   the row or the column isn't there
        jae     e_under
%endif
        call    pcsi
        pop     eax                     ; the column
        xchg    eax,[esp]               ; the row (the column waits)
        call    psgn1
        mov     al,';'
        CALLP   putc
        pop     eax
        call    psgn1
        mov     al,'H'
%if CHECKED
        CALLP   putc
        jmp     hp1
%else
        jmp     prput
%endif

; pesc: the escapes of '$'. EAX = the character after the '/', 60h to 7Eh,
; and EBX points past it. Each goes back into the loop (PRLOOP), but /~ has
; the stack to see to.
;    /a-/z   print the variable, as '#' does
;    /{      clear the screen, the cursor to the top left: ESC [ H ESC [ J
;    /}      clear from the cursor to the end of the line: ESC [ K
;    /|  /`  show the cursor, hide it: ESC [ ? 2 5 h, ESC [ ? 2 5 l
;    /~      ( row col -- ) the cursor to that row and column, from 0:
;            ESC [ row+1 ; col+1 H
pesc:   cmp     al,7Eh
        je      pat
        push    PRLOOP                  ; (the others return into the loop)
        cmp     al,7Bh
        jae     pcon
        cmp     al,60h
        je      phide
        mov     ax,[ARENA+LET-2*41h+eax*2]  ; a-z: the variable's cell (as in
        jmp     psgn                    ;   `lower`)
pcon:   mov     eax,[ptails-4*7Bh+eax*4] ; { | }
pseq:   push    eax                     ; ESC [ and then the bytes of EAX
        call    pcsi
        pop     eax
        jmp     pch
phide:  mov     eax,6C35323Fh           ; ? 2 5 l
        jmp     pseq
ptails: dd      4A5B1B48h               ; {  H ESC [ J
        dd      6835323Fh               ; |  ? 2 5 h
        dd      4Bh                     ; }  K
; pcsi: print ESC [. pch: print the bytes of EAX, from the low one up to the
; last that is not 0 (at least one). Both use EAX.
pcsi:   mov     eax,5B1Bh
pch:    CALLP   putc
        shr     eax,8
        jnz     pch
        ret
%endmacro

; =============================================================================
;  Punctuation handlers. PTAB holds one byte per character: its handler's
;  distance from hbase, so every handler starts in the 256 bytes from hbase
;  (PT checks it). Only the starts must be there: the last handler, '$',
;  runs on past the window, and '[', '`' (and '_' in a checked build, and
;  '/' in a checked or base one) are stubs that jump to their bodies after
;  it. Each handler starts
;  with EBX = TOS and EAX, ECX, EDX free, and ends with JMP EBP.
;  (Two other layouts were tried: handlers 2-aligned with the table holding
;  half the distance, which costs a NOP after every handler of odd length,
;  about 22 bytes; and the Z80's two 256-byte windows, whose dispatcher is 7
;  bytes longer and whose handlers must be in table order, which costs near
;  jumps.)
; =============================================================================
hbase:
; ']' returns: pop an address and jump to it.
h_ret:  mov     esi,[edi]
rdrop:  scasd                           ; drop the return stack's top
nx:     jmp     ebp

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
h_break:test    bx,bx
        pop     ebx
        jz      nx
        call    skip
        test    al,al                   ; skip returns 0 for ')'
        jnz     h_ret
        jmp     rdrop

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on. The loop-back looks at the break key.
h_close:test    bx,bx
        pop     ebx
        jz      rdrop
        mov     esi,[edi]
        jmp     rpoll

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: test    bx,bx
        pop     ebx
        jz      skipo
        mov     edx,esi
        jmp     rpush

; '{' TOS to the return stack, '}' back.
h_tor:  mov     edx,ebx
        pop     ebx
        jmp     rpush
h_fromr:push    ebx
        mov     ebx,[edi]
        jmp     rdrop

; '@' fetches a cell.
h_fetch:mov     bx,[ebx]
        jmp     ebp

; ---- arithmetic and logic: ( NOS TOS -- result ) ---------------------------
; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  mov     al,[esi]
        sub     al,'0'
        cmp     al,10
        jb      negnum
        neg     bx                      ; a - b = a + (-b): on into '+'
h_add:  pop     edx
        add     bx,dx
        jmp     ebp

h_and:  pop     edx
        and     bx,dx
        jmp     ebp
h_or:   pop     edx
        or      bx,dx
        jmp     ebp
h_xor:  pop     edx
        xor     bx,dx
        jmp     ebp
h_not:  not     bx
        jmp     ebp
h_mul:  pop     edx
        imul    bx,dx                   ; the low 16 bits, signed or not
        jmp     ebp

; Signed compares. '<' swaps the two cells and is then '>': a > b is b < a.
; Flipping both sign bits turns the signed compare into an unsigned one, and
; SBB turns the carry into -1 or 0 with no branch.
h_lt:   xchg    ebx,[esp]
h_gt:   pop     edx                     ; DX = a, BX = b
        xor     bh,80h
        xor     dh,80h
        cmp     bx,dx                   ; carry if b < a
tf:     sbb     bx,bx
        jmp     ebp
h_eq:   pop     edx
        sub     bx,dx
        cmp     bx,1                    ; carry only if a - b = 0
        jmp     tf


%if CHECKED || QK
h_div:  jmp     div1                    ; ('/': its body is after the window)
%else
h_div:  DIVCODE
%endif

; ---- stack and storage -----------------------------------------------------
h_dup:  push    ebx
        jmp     ebp
h_swap: xchg    ebx,[esp]
        jmp     ebp

; (The checked build tests the address before it takes the value off the
; stack, so that the report shows both.)
h_cstore:
%if CHECKED
        call    chkst1
%endif
        pop     edx
        mov     [ebx],dl
        jmp     short h_drop
h_store:
%if CHECKED
        call    chkst2
%endif
        pop     edx
        mov     [ebx],dx
h_drop: pop     ebx
        jmp     ebp

; ---- console ---------------------------------------------------------------
; '"' pushes the address of the text after it and skips the string.
h_str:  push    ebx
        mov     ebx,esi
        call    skipstr
%if CHECKED
        test    al,al                   ; 0: the text ran out first
        jz      e_quote
%endif
        jmp     ebp

; "'" emits the low byte; '#' prints TOS as a signed number.
h_emit: mov     al,bl
        CALLP   putc
        jmp     h_drop
h_num:  mov     eax,ebx
        call    psgn
        jmp     h_drop

; ',' fetches a byte. It shares the end of '?'.
h_cfetch:mov    al,[ebx]
kt3:    mov     bl,al
        mov     bh,0
        jmp     ebp


; '[' and '`' (and '_' in a checked build): their bodies are after '$',
; the last handler, outside the window.
h_def:  jmp     short def1
h_grave:jmp     short grave1
%if CHECKED
h_alloc:jmp     short alloc1
%else
h_alloc:ALLOCCODE
%endif

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters (127 at most), with echo
h_key:  test    bh,bh
        js      line
        movzx   ecx,bx                  ; the wait in ms (0: for ever)
        call    getk
        jmp     kt3

; '$' prints the string at TOS, decoding escapes: '/' plus a character from
; 60h to 7Eh is one of the escapes at pesc; '/' plus any other character
; clears that character's bit 6 (/M is CR, /? is DEL's '?'; '/' and '"'
; have no bit 6, so // and /" give themselves). EBX itself steps along the
; string. It is the last handler: it runs on past the window.
%if CHECKED
; (The checked build has the loop as a routine, prstr, which the report's
; texts use too. The address is kept at V_STR meanwhile, for a Q report: it
; shows the stack as before the '$'. /~ comes back to hp1.)
h_print:mov     [V(v_str)],ebx
hp1:    call    prstr
        jmp     h_drop
%else
h_print:PRLOOPCODE
%endif


; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything that is not a letter as the space; the
; checked build stops on it with W.)
def1:   xor     eax,eax
        lodsb
        sub     al,'A'                  ; a letter gives 0-25 or 32-57:
        mov     edx,eax                 ;   lowercase lands 64 bytes up
        and     al,0DFh                 ; (fold case)
        cmp     al,26
        jae     .nl
        mov     [ARENA+LET+edx*2],si
        jmp     short .sk
.nl:
%if CHECKED
        cmp     dl,' '-'A'
        jne     e_brack                 ; anything but a letter or a space
%endif
        push    ebx                     ; an anonymous block: its address
        mov     ebx,esi
.sk:
%if CHECKED
        dec     esi                     ; back onto the letter: skip finds its
%endif                                  ;   opener, '[', just before it
skipo:  call    skip
        jmp     ebp

%if CHECKED
        ALLOCCODE
%endif

; ---- machine code: the grave -----------------------------------------------
; '`' plus a hex digit loads bytes: ( addr -- addr' ). Pairs of hex digits
; are stored from addr until a non-hex character; then a RET (C3h) is
; written and its address is left. An odd last digit is consumed and its
; byte is overwritten by the RET. (Never range-checked: the spec says so.)
; '`' plus anything else calls the machine code at TOS: ( addr -- ).
;
; The machine-code contract: the code is entered by CALL, with the return
; address at [ESP] and the data stack above it: [ESP+4] is the top cell
; (the one under the address, which was consumed), [ESP+8] the next, one
; dword per cell, the cell in the low word. EBX holds the code's own
; address (ARENA + addr), and its high word is the arena's (0041h): a
; B8Script address a is the byte at ARENA + a. The code may push and pop
; dwords, and may change EAX, EBX, ECX, EDX and the flags; it must keep
; ESI, EDI and EBP, leave the direction flag clear, and return with RET
; (C3h, which the loader writes). On return the dword on top of the stack
; becomes TOS. Only the low word of each cell counts: the interpreter puts
; the arena's high word back into every cell on the stack.
grave1: CALLP   hexc
        jnc     .ex
.hx1:   mov     [ebx],al                ; the high digit goes in first ...
        CALLP   hexc
        jnc     .hx2                    ; odd digit: consumed, and the RET
        shl     byte [ebx],4            ;   overwrites it
        or      [ebx],al                ; ... and the low one joins it
        inc     ebx
        CALLP   hexc
        jc      .hx1
.hx2:   mov     byte [ebx],0C3h
        jmp     ebp
.ex:    call    ebx
        mov     eax,esp                 ; (the stack holds one cell at least,
.ex1:   mov     word [eax+2],ARENA>>16  ;   the one that stands for TOS)
        add     eax,4
        cmp     eax,[V(v_dstop)]
        jb      .ex1
        pop     ebx
        jmp     ebp

%if CHECKED=0
        PESCCODE
%endif

%if CHECKED || QK
div1:   DIVCODE
%endif

; ---- Speed-ups (base builds) ---------------------------------------------
; base takes what pays on x86 of the Z80's base: the skip cache and the
; faster skip (at skip), '/' by a power of two as shifts (DIVQ), and in the
; unchecked build a variable then '@' or '!' in one step (here). The Z80's
; '*' in 8 rounds has nothing to do here: x86 has IMUL. Nor has its true
; ')': this ')' reads the block start where it is in every build.
%if SBASEU
; a-z, in the unchecked base build: a variable followed by '@' or '!' is
; fetched or stored in the same step (x@ is the commonest pair in most
; programs). (A checked build checks the stacks between the two, so it keeps
; them apart.)
lower:  lea     edx,[ARENA+LET+eax*2]   ; EDX -> the cell
        mov     al,[esi]
        cmp     al,'@'
        je      .lw1
        cmp     al,'!'
        je      .lw2
        push    ebx                     ; neither: push the cell's address
        mov     ebx,edx
        jmp     ebp
.lw1:   inc     esi                     ; x@: TOS = the cell's value
        push    ebx
        mov     bx,[edx]
        jmp     ebp
.lw2:   inc     esi                     ; x!: the cell = TOS, and NOS comes up
        mov     [edx],bx
        pop     ebx
        jmp     ebp
%endif

; =============================================================================
;  Checked build: the checks and the error report (here, so that the
;  handlers' bodies above reach the error entries with short jumps)
; =============================================================================
%if CHECKED
e_zero: mov     al,'Z'                  ; dividing by zero
        jmp     error
e_heap: mov     al,'H'                  ; the heap
        jmp     error

; chkst1, chkst2: stop with O unless the 1 or 2 bytes at TOS are in the
; program's space: from the letter page up to the heap limit. Memory above
; the heap top but below the limit is the program's own: Tiny BASIC keeps
; its lines there.
chkst2: mov     eax,ebx
        sub     ax,LET
        cmp     ax,LIMIT-LET-1
        jmp     short chs1
chkst1: mov     eax,ebx
        sub     ax,LET
        cmp     ax,LIMIT-LET
chs1:   jae     e_store
        ret

; chkstk: both stacks are checked once per character, not in every handler.
; A character can pop a cell or two too many, or push one too many, before
; it is seen here: the data stack has the caller's frame above it and the
; thread's stack below, and the return stack has the image's spare space on
; both sides.
chkstk: lea     eax,[esp+4]
        sub     eax,[V(v_dstop)]        ; minus 4 x the depth
        jg      e_under
        cmp     eax,-4*DSMAX
        jl      e_over
        cmp     di,RSTOP & 0FFFFh       ; (the return stack is in one 64K: only
        ja      e_rund                  ;   the low word changes)
        cmp     di,(RSTOP-4*RSMAX) & 0FFFFh
        jb      e_rover
        ret
e_under:mov     esp,[V(v_dstop)]        ; data stack underflow: it counts as
        mov     al,'s'                  ;   empty
        jmp     short error
e_rund: mov     edi,RSTOP               ; return stack underflow: the same.
        or      esi,ARENA               ;   (A ']' or ')' may have taken an IP
        mov     al,'r'                  ;   of 0 from below the stack: keep the
                                        ;   place readable)
        jmp     short errp
e_rover:mov     al,'R'
        jmp     short errp
e_over: mov     al,'S'
        jmp     short errp
e_break:mov     al,'B'                  ; Ctrl-C (inside pollk or getk)
        jmp     short errp
e_store:mov     al,'O'                  ; a store outside the program's space
        jmp     short errp
; e_dollar: '$' ran into a NUL: Q, with the string's address TOS again. But
; if its /~ escapes took cells that weren't there, that is s (as the next
; character's check would have said).
e_dollar:pop    edx                     ; prstr's return address
        cmp     esp,[V(v_dstop)]        ; (ESP = v_dstop: the cell that stands
        jae     e_under                 ;   for TOS was taken too)
        mov     ebx,[V(v_str)]
        mov     al,'Q'
        jmp     short error
; errp: an error found inside a routine: drop its return address first.
errp:   pop     edx
        jmp     short error
e_quote:mov     esi,ebx                 ; an unclosed string: its address, one
        mov     al,'Q'                  ;   past the quote, is the place
        jmp     short error
e_brack:mov     al,'W'                  ; bad character after [

; error: the report, then the end. AL = the letter, ESI = one past the
; place, EBX = TOS, and both stacks as the report is to show them:
;
;   Err X @ line,col
;   D:n: the top 8 cells at most, bottom to top
;   R:n
;
; It goes to the standard error handle. (The letter is written into the
; text of the first line. The texts end at a quote; prstr prints them, and
; their CR LF are the bytes themselves.)
error:  push    ebx                     ; now the whole data stack is in memory
        mov     [erlet],al
        push    -12                     ; STD_ERROR_HANDLE
        call    [V(iat_GetStdHandle)]
        mov     [V(v_outh)],eax
        CALLP   pmsg
        db      13,10,'Err '
erlet:  db      'X @ ',22h
        dec     esi                     ; ESI = the place
        ; The line and column. A place below the program is in the line
        ; buffer: line 0. Otherwise count the LFs from the program's start;
        ; ECX = the line's number, EDX = where it starts.
        xor     ecx,ecx
        mov     edx,ARENA+LINEBUF
        cmp     si,PROG
        jb      .er3
        mov     dx,PROG
        mov     eax,edx
.er1:   inc     ecx                     ; a new line starts at EAX
        mov     edx,eax
.er2:   cmp     eax,esi
        jae     .er3                    ; reached the place
        inc     eax
        cmp     byte [eax-1],10
        jne     .er2
        jmp     .er1
.er3:   push    edx
        xchg    eax,ecx
        CALLP   pdec                    ; the line
        mov     al,','
        CALLP   putc
        pop     edx
        mov     eax,esi
        sub     eax,edx
        movzx   eax,ax
        inc     eax
        CALLP   pdec                    ; the column
        ; D:n: the top 8 cells at most, bottom to top
        ; R:n
        ; The depth is 1 less than the dwords down to V_DSTOP (the cell
        ; that stands for TOS when the stack is empty).
        CALLP   pmsg
        db      13,10,'D:',22h
        mov     eax,[V(v_dstop)]
        sub     eax,esp
        shr     eax,2
        dec     eax
        push    eax
        CALLP   pdec                    ; the depth
        mov     al,':'
        CALLP   putc
        pop     ecx
        cmp     ecx,9
        jb      .ps1
        CALLP   pmsg
        db      ' ...',22h
        push    8
        pop     ecx
.ps1:   jecxz   .ps3                    ; ECX = the number of cells to show
.ps2:   mov     al,' '
        CALLP   putc
        mov     eax,[esp+ecx*4-4]
        push    ecx
        call    psgn
        pop     ecx
        loop    .ps2
.ps3:   CALLP   pmsg
        db      13,10,'R:',22h
        mov     eax,RSTOP
        sub     eax,edi
        shr     eax,2
        CALLP   pdec
        CALLP   pmsg
        db      13,10,22h
 %if EDITOR
        jmp     edit0                   ; back to the editor, stacks cleared
 %else
        jmp     exit
 %endif
%endif


%if CHECKED
        PESCCODE
%endif

; psgn: print the low word of EAX as a signed number (psgn1: of EAX + 1).
; pdec: print EAX unsigned, by recursion on EAX / 10 (the stack holds the
; digits). All use EAX, ECX and EDX.
psgn1:  inc     eax
psgn:   cwde
        test    eax,eax
        jns     pdec
        push    eax
        mov     al,'-'
        CALLP   putc
        pop     eax
        neg     eax
pdec:   xor     edx,edx
        push    10
        pop     ecx
        div     ecx
        push    edx
        test    eax,eax
        jz      .pd1
        call    pdec
.pd1:   pop     eax
        add     al,'0'                  ; (on into putc)

; =============================================================================
;  Console layer
;
;  putc prints AL. waitk is the host's key routine: it waits up to EAX ms
;  (0: just a look; -1: for ever) for a key, and returns it in AL with the
;  zero flag clear, or AL = 0 with the zero flag set if none came. Both keep
;  every register but EAX (putc keeps EAX too).
;
;  A running program reads the keyboard only through getk and pollk, which
;  between them give the break key its rules:
;    - Ctrl-C stops the program;
;    - any other key that the break check reads is held at HELD for the
;      next '?', and a newer one takes its place;
;    - '?' (getk) takes the held key first;
;    - a program that has stored a non-zero byte at BRKOFF gets Ctrl-C as a
;      key like any other, but two of them within about 250 ms still stop it.
;  Both are called straight from a handler (or from rpoll), never from a
;  routine under one: the checked build's report counts on finding one
;  return address above the data stack.
; =============================================================================

; putc: WriteFile to the output handle (standard output; the checked
; report switches it to standard error), one byte. PUSHAD saves everything;
; the byte is AL in the saved EAX, and the count goes in the slot of the
; saved ESP, which POPAD ignores.
putc:   pushad
        lea     ecx,[esp+12]
        lea     edx,[esp+28]
        push    0                       ; lpOverlapped
        push    ecx                     ; lpNumberOfBytesWritten
        push    1
        push    edx
        push    dword [V(v_outh)]
        call    [V(iat_WriteFile)]
        popad
        ret

; waitk. At a console: a wait on the input handle for the time (EAX: 0
; just looks, -1 is INFINITE), then ReadConsoleInputA for one event. The
; wait is WaitForMultipleObjects, on v_hin alone or on v_hin and v_htm,
; which follow each other. A timed wait (1 ms or more) sets the
; high-resolution timer once for the whole time and waits for the input or
; the timer, with no time of its own; without the timer it is a plain wait
; on the input for the time, which starts again with its whole time after
; each event passed over. Only key-down events count: their character,
; or for the left and right arrow keys (virtual keys 25h and 27h, which
; have none) 1Ch and 1Eh, which the editor takes for them (a typed ^B or ^F
; does nothing there). Anything else is passed over.
; Input that is not a console (a pipe or a file) is read a byte at a time
; with ReadFile, and only by a wait that is not just a look (a look would
; eat the input); at its end the interpreter exits.
waitk:  pushad
        xchg    eax,ebx                 ; EBX = the time
        push    1
        pop     esi                     ; ESI = the handles: the input
        mov     edi,[V(v_htm)]          ; the timer, if there is one
        lea     eax,[ebx-1]
        cmp     eax,7FFFFFFEh
        jae     .wk1                    ; 1 ms or more, and not INFINITE,
        test    edi,edi                 ;   uses it
        jz      .wk1
        imul    eax,ebx,-10000          ; relative, in 100 ns units
        cdq
        push    edx
        push    eax                     ; the due time, 64 bits
        mov     ecx,esp
        xor     edx,edx
        push    edx                     ; fResume
        push    edx                     ; lpArgToCompletionRoutine
        push    edx                     ; pfnCompletionRoutine
        push    edx                     ; lPeriod
        push    ecx                     ; lpDueTime
        push    edi
        call    [V(iat_SetWaitableTimer)]
        pop     eax
        pop     eax
        inc     esi                     ; the input and the timer,
        or      ebx,-1                  ;   INFINITE: the timer ends it
.wk1:   cmp     byte [V(v_iscon)],0
        je      .wk6
        push    ebx                     ; the time
        push    0                       ; any one of them
        lea     eax,[V(v_hin)]
        push    eax
        push    esi
        call    [V(iat_WaitForMultipleObjects)]
        test    eax,eax
        jnz     .wk8                    ; the timer, or WAIT_TIMEOUT: no key
        lea     eax,[V(v_cnt)]
        push    eax
        push    1
        lea     eax,[V(v_rec)]
        push    eax
        push    dword [V(v_hin)]
        call    [V(iat_ReadConsoleInputA)]
        cmp     byte [V(v_rec)],1       ; KEY_EVENT
        jne     .wk1
        cmp     byte [V(v_rec)+4],0     ; bKeyDown
        je      .wk1
        mov     al,[V(v_rec)+14]        ; uChar.AsciiChar
        test    al,al
        jnz     .wk9
        mov     al,[V(v_rec)+10]        ; wVirtualKeyCode
        sub     al,25h                  ; VK_LEFT 0, VK_RIGHT 2
        test    al,0FDh
        jnz     .wk1                    ; anything else: passed over
        add     al,1Ch                  ; 1Ch, 1Eh
        jmp     .wk9
.wk6:   test    ebx,ebx                 ; not a console: a look finds nothing
        jz      .wk8
        push    0
        lea     eax,[V(v_cnt)]
        push    eax
        push    1
        lea     eax,[V(v_rec)]
        push    eax
        push    dword [V(v_hin)]
        call    [V(iat_ReadFile)]
        cmp     dword [V(v_cnt)],0
        je      exit                    ; the end of the input
        mov     al,[V(v_rec)]
        jmp     .wk9
.wk8:   xor     eax,eax
.wk9:   mov     [esp+28],eax            ; (POPAD gives it back in EAX)
        popad
        test    al,al
        ret

; endprog: the inner loop read the NUL that ends the program. In the checked
; build an IP of 0001h means the NUL at 0000h, where every undefined word's
; cell points: U, with the call undone, so the place is the call itself.
%if CHECKED
endprog:cmp     si,1                    ; (ESI is in the arena)
        jne     .ep1
        mov     esi,[edi]
        scasd
        mov     al,'U'
        jmp     error
.ep1:
 %if EDITOR
        jmp     edend
 %endif                                 ; (the runner: on into exit)
%elif EDITOR
endprog equ     edend
%else
endprog equ     exit
%endif

; exit: put the console's input mode back as it was, and leave.
exit:   push    dword [V(v_mode)]
        push    dword [V(v_hin)]
        call    [V(iat_SetConsoleMode)]
        push    0
        call    [V(iat_ExitProcess)]

; getk: a key for '?', waiting up to ECX ms (0: for ever); or AL = 0 and
; the zero flag if none came. A held key goes first, and is taken out.
; Keeps ECX and EDX.
getk:   xor     eax,eax
        xchg    al,[ARENA+HELD]
        test    al,al
        jnz     gk9
        mov     eax,ecx
        test    eax,eax
        jnz     .gk1
        dec     eax                     ; (-1: INFINITE)
.gk1:   CALLP   waitk
        jnz     pk1                     ; Ctrl-C? If not, that is the key
gk9:    ret
; pollk: the break check (see rpoll).
pollk:  xor     eax,eax
        CALLP   waitk
        jz      gk9                     ; no key
        mov     [ARENA+HELD],al         ; held for the next '?'
pk1:    cmp     al,3
        jne     gk9
; ctlc: Ctrl-C has been read. If the break key is on, that is the end. If
; the program has turned it off, wait about 250 ms for one more key: a
; second Ctrl-C is the end too; any other key is held (the newest wins),
; and the Ctrl-C goes to the program: returns AL = 3, zero flag clear.
ctlc:   cmp     byte [ARENA+BRKOFF],0
.ct0:   jz      brk
        xor     eax,eax
        mov     al,250
        CALLP   waitk
        cmp     al,3
        je      .ct0                    ; (the zero flag takes the JZ there)
        test    al,al
        jz      .ct3
        mov     [ARENA+HELD],al
.ct3:   mov     al,3
        test    al,al
        ret

%if CHECKED=0
 %if EDITOR
brk     equ     edit0                   ; the editor: back, both stacks cleared
 %else
brk     equ     exit                    ; the runner stops without a word
 %endif
%else
brk     equ     e_break                 ; the checked build reports B
%endif
%if EDITOR
SKEND   equ     skend                   ; a program that ends goes back to the
%else                                   ;   editor, also when it ends inside skip
SKEND   equ     exit
%endif

; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it. Leaves AL = 22h.
%if CHECKED=0
ss0:    inc     esi
skipstr:lodsb
        cmp     al,'/'
        je      ss0
        cmp     al,22h
        jne     skipstr
        ret
%else
; The checked build never steps over a NUL: if the text runs out first it
; returns AL = 0 with the IP on the NUL.
skipstr:mov     al,[esi]
        test    al,al
        jz      .ss9
        inc     esi
        cmp     al,22h
        je      .ss9
        cmp     al,'/'
        jne     skipstr
        mov     al,[esi]                ; the escaped character
        test    al,al
        jz      .ss9
        inc     esi
        jmp     skipstr
.ss9:   ret
%endif

; skip: read past text to the closer at this level, and return AL = 0 if it
; was ')' and 2 if it was ']'. Brackets of both kinds count together;
; strings are stepped over whole. A NUL first ends the program (for '\' with
; no closer; anything else that runs into the NUL had unbalanced brackets
; anyway). ECX counts the open levels, from 1 for the one we are in.
;
; The checked build also looks at the character the skip was started by,
; which is always the one just before where it starts: '(' must end at ')',
; '[' at ']', and neither may run into the NUL (N); a string with no closing
; quote counts as running into it. '\' takes either closer. V_SKAT keeps the
; place where the skip started, for the report.
%if QK == 0
skip:
%if CHECKED
        mov     [V(v_skat)],esi
        mov     ah,[esi-1]              ; AH = the opener: ( [ or backslash
%endif
        xor     ecx,ecx
.sk3:   inc     ecx                     ; an opener: one deeper
.sk1:
%if CHECKED
        mov     al,[esi]
        test    al,al
        jz      .sk6                    ; (the IP stays on the NUL)
        inc     esi
%else
        lodsb
        test    al,al
        jz      SKEND                   ; (the end of the program)
%endif
        cmp     al,22h
        jne     .sk2
        call    skipstr                 ; leaves AL = 22h, which matches
.sk2:   sub     al,'('                  ;   nothing below (or 0: then the
        jz      .sk3                    ;   NUL is read next)
        dec     al                      ; ')'
        jz      .sk4
        sub     al,'['-')'
        jz      .sk3
        cmp     al,']'-'['
        jne     .sk1
.sk4:   dec     ecx
        jnz     .sk1
%if CHECKED
        xor     ah,al                   ; the closer at this level: 0 or 2. Bit
        and     ah,6                    ;   1 of the opener is 0 for '(' and 1
        cmp     ah,2                    ;   for '[', and only the backslash has
        je      .sk7                    ;   bit 2: so this is 2 for the wrong
                                        ;   closer, and only then
        ret
.sk6:   test    ah,4                    ; the text ran out:
        jnz     SKEND                   ;   '\' with no closer ends the program
.sk7:   mov     esi,[V(v_skat)]         ; N. The place is the opener
        mov     al,'N'
        jmp     errp                    ; (errp drops skip's return address)
%else
        ret
%endif
%else
; The skip cache (base). Nearly every skip is one that has happened before
; (a loop skips the same false block on every pass), so the first scan from
; each place is remembered: 64 entries of {start, end} at skc, found by the
; start's low 6 bits. Only skips that start inside the program text are kept
; (the line buffer changes, and so may the heap); the cache is emptied
; whenever a run starts (run0). A program that changes its own text while it
; runs is not looked after. A hit returns AL = 0 for ')' and not 0 for ']'.
skip:   mov     ecx,esi
        and     ecx,NSKC-1
        cmp     [skc+ecx*8],esi
        jne     .sk0
        mov     esi,[skc+ecx*8+4]       ; a hit: the IP is past the closer
        mov     al,[esi-1]
        sub     al,')'
        ret
; The scan. EDX = where it starts (the cache's key, and in the checked build
; the place for N; the opener is the character before it).
%if FAST
; (The fast build: a table of the six characters that count, NUL " ( ) [ ],
; so the rest cost a load and a test each.)
.sk0:   mov     edx,esi
        xor     eax,eax                 ; (EAX indexes the table)
        xor     ecx,ecx
.sk3:   inc     ecx                     ; an opener: one deeper
.sk1:   lodsb
        test    byte [sktab+eax],1
        jz      .sk1
        cmp     al,'('
        je      .sk3
        cmp     al,'['
        je      .sk3
        cmp     al,')'
        je      .skc
        cmp     al,22h
        je      .skq
        test    al,al
        jz      .skn
        mov     al,2                    ; ]
        jmp     short .sk4
%else
; (Two range tests rule out most characters, '^' and up and '*' to 'Z',
; before the six that count, NUL " ( ) [ ], are looked for.)
.sk0:   mov     edx,esi
        xor     ecx,ecx
.sk3:   inc     ecx                     ; an opener: one deeper
.sk1:   lodsb
        cmp     al,5Eh
        jae     .sk1                    ; ^ _ ` a-z { | } ~ and 7Fh-FFh: nothing
        cmp     al,2Ah
        jb      .sk5
        cmp     al,5Bh
        jb      .sk1                    ; * to Z: nothing
        sub     al,5Ch                  ; [ -1, backslash 0, ] 1
        jz      .sk1                    ; (backslash is nothing here)
        jc      .sk3                    ; [
        mov     al,2                    ; ]
        jmp     short .sk4
.sk5:   cmp     al,28h
        je      .sk3                    ; (
        ja      .skc                    ; )
        cmp     al,22h
        je      .skq
        test    al,al
        jnz     .sk1                    ; the rest below '*': nothing
        jmp     short .skn
%endif
.skc:   mov     al,0                    ; )
.sk4:   dec     ecx                     ; a closer: AL = 0 for ')', 2 for ']'
        jnz     .sk1
%if CHECKED
        mov     ah,[edx-1]              ; the closer at this level (as above):
        xor     ah,al                   ;   2 here means the wrong closer
        and     ah,6
        cmp     ah,2
        je      .sk7
%endif
        lea     ecx,[edx-(ARENA+PROG)]  ; remember it, if it started inside the
        cmp     ecx,[v_tlen]            ;   program text
        jae     .sk9
        and     ecx,NSKC-1              ; (PROG is a multiple of 64: the same
        mov     [skc+ecx*8],edx         ;   entry as the lookup's)
        mov     [skc+ecx*8+4],esi
.sk9:   ret
.skq:   call    skipstr                 ; a string: stepped over whole
        jmp     .sk1
.skn:                                   ; NUL: the text ran out
%if CHECKED
        dec     esi                     ; (the IP stays on the NUL)
        test    byte [edx-1],4
        jnz     SKEND                   ; '\' with no closer ends the program
.sk7:   mov     esi,edx                 ; N. The place is the opener
        mov     al,'N'
        jmp     errp                    ; (errp drops skip's return address)
%else
        jmp     SKEND                   ; (the end of the program)
%endif
%endif

; -n?: Backspace takes the last character back (and is echoed as it is),
; CR ends (stored, not echoed), every other key is stored and echoed until
; the line is full. The buffer is at offset 80h of the letter page, so DL
; alone is the place in the line; BL is the DL of a full line.
line:   neg     bx                      ; the count (8000h for -32768)
        cmp     bx,127
        jbe     .ln1
        mov     bl,127
.ln1:   add     bl,80h
        mov     edx,ARENA+LINEBUF
        xor     ecx,ecx                 ; getk waits for ever
.ln2:   call    getk
        cmp     al,13
        je      .ln5
        cmp     al,8
        je      .ln4
        cmp     dl,bl
        je      .ln2                    ; full
        mov     [edx],al
        inc     edx
.ln3:   CALLP   putc
        jmp     .ln2
.ln4:   dec     dl                      ; Backspace: one back, and echo it,
        js      .ln3                    ;   unless the line was empty (DL left
        inc     dl                      ;   the upper half of the page)
        jmp     .ln2
.ln5:   mov     [edx],al                ; the CR
        mov     bx,LINEBUF
        jmp     ebp

; =============================================================================
;  Routines
; =============================================================================

; hexc: if the character at IP is a hex digit (0-9, A-F, a-f), step over it
; and return its value in AL with the carry set; otherwise leave the IP and
; return with the carry clear.
hexc:   mov     al,[esi]
        sub     al,'0'
        cmp     al,10
        jb      .hc1
        and     al,0DFh
        sub     al,11h
        cmp     al,6
        jae     .hc2
        sub     al,0F6h                 ; + 10, and sets the carry
.hc1:   inc     esi
.hc2:   ret

; rdnum: read decimal digits at IP into BX (and DX); IP is left on the
; first non-digit. Values wrap at 16 bits, as the spec says.
rdnum:  xor     edx,edx
.rn1:   movzx   eax,byte [esi]
        sub     al,'0'
        cmp     al,10
        jae     .rn2
        inc     esi
        imul    edx,edx,10
        add     edx,eax
        jmp     .rn1
.rn2:   mov     bx,dx
        ret


%if CHECKED
; pmsg: print the text that follows the CALL, to its closing quote (through
; prstr), and carry on after it. Uses EBX.
pmsg:   pop     ebx
        call    prstr
        jmp     ebx
%endif


; =============================================================================
;  The line editor (EDITOR = 1)
;
;  The interpreter starts here, and a program that ends comes back here.
;  There is no prompt. It follows the spec's suggested standard for a line
;  editor (docs/b8script.md, Environments), and is the Z80's editor, key for
;  key. Type a line and press Return:
;
;    n text    put the text in as line n; the lines from n on move down. A
;              number past the end (or 0) adds the line at the end.
;    n         take line n out
;    anything else is run at once, as B8Script. (Start such a line with a
;    space if it would begin with a digit.)
;
;  A command key ends the line too, and takes what was typed as its argument:
;
;    ^G        run the program
;    n ^L      list from line n (no number: all of it). Any key holds the
;              list until another key is pressed; Ctrl-C ends it.
;    n ^E      put line n in the input line; Return puts it back, changed
;    name ^R   read the file of that name (no name: the current one: the
;              one from the command line, or the last one typed)
;    name ^W   write the program to that file (no name: the current one)
;    ^N        new: no program
;    ^X        leave
;
;  Any other control key does nothing.
;
;  In the line: the left and right arrow keys move the cursor (^B and ^F do
;  nothing);
;  a character goes in at the cursor; Backspace and DEL take out the one
;  before it; Esc drops the line (after Esc it waits 5 ms for a '[': Esc [ C
;  and Esc [ D are right and left too). Only CR, LF, BS and printing
;  characters are sent to the terminal.
;
;  Lines are counted, not numbered. A typed line holds 125 characters; the
;  one character after a line number separates it from the text and is not
;  stored. The text is kept as typed, each line ending in CR LF, at PROG. A
;  file is read up to its first ^Z, and a last line with no line end is
;  given one; it is written as it is, with no padding.
;
;  What lasts from one line to the next: the program, the words, the
;  variables and the data stack (TOS is kept pushed while the editor runs).
;  An error or a break clears both stacks. The return stack starts empty for
;  every line.
;
;  Registers in the editor: EBX = the cursor, EDX = the end of the line
;  (pointers into the line buffer); EDI is free (edit resets it).
; =============================================================================
%if EDITOR
; ^E: line n goes into the input line, to be changed. V_EDLN remembers
; which line it was: Return puts the text back in its place.
cedln:  CALLP   rdnum
        xchg    eax,edx                 ; (find and V_EDLN use only the low
        push    eax                     ;   word)
        CALLP   find                    ; EDI -> the line, or the NUL
        pop     eax
        cmp     byte [edi],0
        je      .ce9
        mov     [V(v_edln)],eax
        mov     ebx,ARENA+LINEBUF
.ce1:   mov     al,[edi]                ; copy it, and show it, up to its CR
        cmp     al,13                   ;   (or LF)
        je      .ce2
        cmp     al,10
        je      .ce2
        mov     [ebx],al
        CALLP   putc
        inc     edi
        inc     ebx
        cmp     bl,0FDh                 ; (a longer line is cut at 125)
        jne     .ce1
.ce2:   mov     edx,ebx                 ; the cursor is at the line's end
        pop     eax                     ; (not back to edit: on with the line)
        jmp     ed1
.ce9:   ret

; right arrow: one to the right, by printing the character there
right:  cmp     ebx,edx
        je      ed1                     ; at the end
        mov     al,[ebx]
        inc     ebx
        jmp     short lf1

; Esc: alone it drops the line. An arrow key sends Esc [ and a letter, so
; wait about 5 ms for a second key: after a '[' read on to the letter that
; ends the sequence, and act on C (right) and D (left).
esc:    push    5
        pop     eax
        CALLP   waitk
        jnz     .es2
        call    fin                     ; no second key: the line is dropped
        jmp     edit
.es2:   cmp     al,'['
        jne     ed1                     ; not a sequence known here
.es3:   CALLP   ekey
        cmp     al,40h
        jb      .es3                    ; (its parameters)
        sub     al,'C'
        je      right
        dec     al                      ; 'D'?
        jne     ed1                     ; no: on into left
; left arrow: the cursor goes one to the left
left:   cmp     bl,80h
        je      ed1                     ; at the start
        dec     ebx
        mov     al,8
lf1:    CALLP   putc
        jmp     ed1

; edit0: an error or a break: both stacks are cleared, and the cursor is
;   shown, in case the program had hidden it and could not show it again.
; skend: a program that ended inside skip: its return address goes.
; edend: a program that ended: TOS joins the rest of the data stack.
edit0:  mov     esp,[V(v_dstop)]
 %if CHECKED
        push    -11                     ; the report went to stderr: back to
        call    [V(iat_GetStdHandle)]   ;   stdout
        mov     [V(v_outh)],eax
        mov     ebx,esi                 ; (the report's texts moved EBX out of
 %endif                                 ;   the arena: the cell for TOS)
        mov     eax,6835323Fh           ; ESC [ ? 2 5 h: show the cursor
        call    pseq
        db      3Ch                     ; (CMP AL,n: steps over the POP)
skend:  pop     eax
edend:  push    ebx
; edit: start a new input line.
edit:   mov     edi,RSTOP               ; the return stack is empty
        xor     eax,eax
        mov     [ARENA+HELD],ax         ; no key is held, and the break key is on
        mov     [V(v_edln)],eax         ; no line is being edited
        mov     ebx,ARENA+LINEBUF       ; EBX = the cursor,
        mov     edx,ebx                 ;   EDX = the end of the line
ed1:    CALLP   ekey
        cmp     al,7Fh
        je      bsp                     ; DEL
        cmp     al,' '
        jae     insc
        cmp     al,9
        je      insc                    ; Tab is text
        cmp     al,8
        je      bsp
        cmp     al,1Ch
        je      left                    ; the left arrow key (see waitk)
        cmp     al,1Eh
        je      right                   ; the right arrow key
        cmp     al,1Bh
        je      esc
        push    edi                     ; a command key? Look it up
        mov     edi,ckeys
        push    NCMD
        pop     ecx
        repne   scasb
        pop     edi
        jne     ed1                     ; no: the key is ignored
        push    edit                    ; the command returns to edit
        mov     eax,ebp                 ; the command's address (the high word
        mov     ax,[ctabr+ecx*2]        ;   is next's): fin returns to it
        push    eax
; fin: end the input line: CR LF and a NUL after it, and a new line on the
; terminal. Leaves ESI -> the line.
fin:    mov     word [edx],0A0Dh
        mov     esi,edx
        call    prl                     ; (prints the CR LF)
        mov     byte [esi],0
        mov     esi,ARENA+LINEBUF
        ret

; Backspace, DEL: the character before the cursor goes. The cursor moves
; left, the rest of the line moves down over it, and the last place (now a
; space) is printed over along with the rest.
bsp:    cmp     bl,80h
        je      ed1                     ; at the start
        dec     ebx
        mov     al,8
        CALLP   putc
        mov     ecx,ebx
.bs1:   mov     al,[ecx+1]
        mov     [ecx],al
        inc     ecx
        cmp     ecx,edx
        jne     .bs1
        mov     byte [ecx-1],' '
        dec     edx
        jmp     short ic2
; A character goes in at the cursor: it ripples up through the rest of the
; line, the cursor moves on, and the rest is printed again.
insc:   cmp     dl,0FDh
        je      ed1                     ; the line is full: 125 characters
        CALLP   putc
        mov     ecx,ebx
.ic1:   xchg    al,[ecx]
        inc     ecx
        cmp     ecx,edx
        jbe     .ic1
        inc     ebx
        inc     edx
        mov     ecx,edx
; ic2: print the line from the cursor to ECX, and bring the cursor back
; with backspaces. Nothing at all if the cursor is at ECX.
ic2:    mov     esi,ebx
.ta1:   cmp     esi,ecx
        je      .ta2
        lodsb
        CALLP   putc
        jmp     .ta1
.ta2:   cmp     esi,ebx
        je      .ta3
        mov     al,8
        CALLP   putc
        dec     esi
        jmp     .ta2
.ta3:   jmp     ed1

; ekey: wait for a key
ekey:   or      eax,-1
        JMPP    waitk

; The command keys, and where each goes (after fin, which returns to the
; command; the command returns to edit, which is under it on the stack).
; REPNE SCASB leaves ECX = the number of keys after the one found, so the
; table is backwards. (The addresses are kept as their low words: the code
; is all in the one 64 KB as `next`.)
ckeys:  db      13, 7, 12, 5, 18, 23, 14, 24
NCMD    equ     $-ckeys
ctabr:  dw      exit-IB                 ; ^X
        dw      cnew-IB                 ; ^N
        dw      cwrite-IB               ; ^W
        dw      cread-IB                ; ^R
        dw      cedln-IB                ; ^E
        dw      clist-IB                ; ^L
        dw      crun-IB                 ; ^G
        dw      cret-IB                 ; Return

; ^N: no program
cnew:   mov     byte [ARENA+PROG],0
        ret

; delln: take line EAX out: copy everything after it down over it. Keeps ESI.
delln:  push    esi
        CALLP   find
        push    edi
        call    nxl                     ; EDI -> the next line
        mov     esi,edi
        pop     edi
.de1:   lodsb
        stosb
        test    al,al
        jnz     .de1
        pop     esi
        ret

; Return. If ^E put a line here, the text goes back in its place. If not:
; a number and text is a line to put in, a number alone a line to take out,
; and anything else is run where it is.
cret:   push    edx                     ; the end of what was typed
        mov     eax,[V(v_edln)]
        test    eax,eax
        jz      .cr1
        push    eax
        call    delln
        pop     eax
        jmp     short ins
.cr1:   CALLP   rdnum                   ; DX = the number it starts with
        mov     eax,esi                 ; ESI's low byte is still 80h if there
        cmp     al,80h                  ;   was no number:
        je      runln                   ;   then run the line
        xchg    eax,edx
        cmp     byte [esi],13
        jne     .cr2
        pop     edx                     ; the number alone: take that line out
        jmp     delln
.cr2:   inc     esi                     ; step over the one character after it

; Put the text at ESI in as line EAX: open a gap of its length there, CR
; and LF included, and copy it in.
ins:    CALLP   find                    ; EDI -> where it goes
        pop     ecx                     ; the end of what was typed
        inc     ecx
        inc     ecx
        sub     ecx,esi                 ; the length, with its CR LF
        push    esi                     ; the text
        push    ecx                     ; its length
        push    edi                     ; where it goes
        mov     esi,edi
.in1:   lodsb                           ; find the program's NUL
        test    al,al
        jnz     .in1
        dec     esi
        mov     ecx,esi
        sub     ecx,edi
        inc     ecx                     ; the bytes to move up, NUL included
        mov     edi,esi
        add     edi,[esp+4]             ; the NUL's new place
        std
        rep     movsb                   ; move the rest of the program up
        cld
        pop     edi
        pop     ecx
        pop     esi
        rep     movsb
        ret

; ^G: run the program. runln: run the typed line (ESI -> it).
crun:   mov     esi,ARENA+PROG
        db      3Ch                     ; (CMP AL,n: steps over the POP)
runln:  pop     eax                     ; (the end of what was typed)
        pop     eax                     ; (the return to edit: a program that
                                        ;   ends goes to edend)
        RUN0CODE

; ^L: list from line n. EDX = the number of the line at ESI.
clist:  CALLP   rdnum                   ; DX = n, or 0 if there was none:
        movzx   eax,dx
        test    eax,eax
        jnz     .li0
        inc     eax                     ;   then from line 1
.li0:   push    eax
        CALLP   find
        pop     edx
        mov     esi,edi
.li1:   cmp     byte [esi],0
        je      .li9                    ; the end of the text
        xor     eax,eax
        CALLP   waitk
        jz      .li3                    ; no key: carry on
        cmp     al,3
        je      .li9                    ; Ctrl-C ends the list,
        CALLP   ekey                    ;   any other key holds it until the
        cmp     al,3                    ;   next (and a Ctrl-C then ends it)
.li9:   je      fi9
.li3:   push    edx
        xchg    eax,edx
        CALLP   pdec                    ; the line's number,
        mov     al,' '
        CALLP   putc                    ;   a space,
        pop     edx
        inc     edx
        call    prl                     ;   and the line
        jmp     .li1

; find: EAX = a line number. Returns EDI -> that line, or -> the NUL at the
; end of the text if there are fewer lines (or the number is 0). Keeps ESI.
find:   xchg    eax,ecx
        mov     edi,ARENA+PROG
.fi1:   dec     cx
        jz      fi9
        call    nxl
        jnz     .fi1
fi9:    ret

; nxl: step EDI over one line, to just past its LF (and return not-zero),
; or stop at the NUL that ends the text (and return zero).
nxl:    mov     al,[edi]
        test    al,al
        jz      .nx1
        inc     edi
        cmp     al,10
        jne     nxl
        test    al,al
.nx1:   ret

; prl: print the line at ESI, to its LF; ESI -> just past it.
prl:    lodsb
        CALLP   putc
        cmp     al,10
        jne     prl
        ret

; ^R: read the file (cread, at load). ^W: write the file (made anew, or
; emptied first). A name typed before the key is the file's name from now
; on. (A file that can't be made or written is not noticed: nothing is
; written.)
cwrite: call    setname
        mov     edi,ARENA+PROG
        xor     eax,eax
        or      ecx,-1
        repne   scasb
        not     ecx
        dec     ecx                     ; the length of the text
        push    ecx
        push    eax                     ; hTemplateFile
        push    eax                     ; dwFlagsAndAttributes
        push    2                       ; CREATE_ALWAYS
        push    eax                     ; lpSecurityAttributes
        push    eax                     ; no sharing
        push    40000000h               ; GENERIC_WRITE
        push    NAMEBUF
        call    [V(iat_CreateFileA)]
        pop     ecx
        push    eax                     ; (for CloseHandle)
        push    0
        lea     edx,[V(v_cnt)]
        push    edx
        push    ecx
        push    ARENA+PROG
        push    eax
        call    [V(iat_WriteFile)]
        call    [V(iat_CloseHandle)]
        ret

; setname: if a name was typed (the line does not start with its CR), it is
; the file's name from now on, as typed (a Windows path).
setname:mov     esi,ARENA+LINEBUF
        cmp     byte [esi],13
        je      .sn2
        mov     edi,NAMEBUF
.sn1:   lodsb
        stosb
        cmp     al,13
        jne     .sn1
        mov     byte [edi-1],0          ; (the CR becomes the NUL)
.sn2:   ret
%endif

; The dispatch table: each handler's distance from hbase (an error if it
; is not in the window).
%macro  PT 1
        db      (%1-hbase) & 0FFh
        times   -((%1-hbase) > 255) db 0
%endmacro
%if FAST == 0
ptab:   PT h_store      ; !
        PT h_str        ; "
        PT h_num        ; #
        PT h_print      ; $
        PT h_swap       ; %
        PT h_and        ; &
        PT h_emit       ; '
        PT h_open       ; (
        PT h_close      ; )
        PT h_mul        ; *
        PT h_add        ; +
        PT h_cfetch     ; ,
        PT h_sub        ; -
        PT h_cstore     ; .
        PT h_div        ; /
        PT h_dup        ; :
        PT h_drop       ; ;
        PT h_lt         ; <
        PT h_eq         ; =
        PT h_gt         ; >
        PT h_key        ; ?
        PT h_fetch      ; @
        PT h_def        ; [
        PT h_break      ; backslash
        PT h_ret        ; ]
        PT h_xor        ; ^
        PT h_alloc      ; _
        PT h_grave      ; `
        PT h_tor        ; {
        PT h_or         ; |
        PT h_fromr      ; }
        PT h_not        ; ~
%else
; =============================================================================
;  The fast build (SPEED = 2)
;
;  The inner loop is a table of 256 handlers, one per character, and the
;  dispatcher (NEXTF: MOVZX EAX,BYTE [ESI] / INC ESI / JMP [dtab+EAX*4]) is
;  `next` and is inline at the end of the fast build's own handlers. Those
;  are: one per letter and digit, which knows its cell or its value, and the
;  commonest punctuation (fs_). The rest of the table is the shared
;  handlers, which end with JMP EBP, into `next`.
;
;  A digit's handler pushes its value; the character after it goes through
;  dtabd, which is dtab but for the digits: those go on with the number
;  (fdm). (In the checked build anything else in dtabd is fdx, which goes back
;  through `next`, for its check of the stacks once the number is read.)
; =============================================================================
%assign i 0
%rep 10
fd%[i]: push    ebx                     ; 0-9: a number starts
        mov     ebx,ARENA+i
        NEXTD
%assign i i+1
%endrep
fdm:    imul    bx,bx,10                ; another digit (EAX = it)
        sub     al,'0'
        add     bx,ax
        NEXTD
%if CHECKED
fdx:    dec     esi                     ; the number has ended: the character
        jmp     ebp                     ;   after it goes through next
%endif

; A-Z: call the word. The return address goes on the return stack, the IP
; becomes the word's body, and the break key is looked at as at rpush.
%assign i 0
%rep 26
fu%[i]: sub     edi,4
        mov     [edi],esi
        mov     si,[ARENA+LET+2*i]
        dec     byte [V(v_pcnt)]
        jz      fpoll
        NEXTF
%assign i i+1
%endrep
fpoll:  call    pollk                   ; (one time in 256)
        jmp     ebp

; a-z: push the cell's address. In the unchecked build a variable followed
; by '@' or '!' is fetched or stored in the same step.
%assign i 0
%rep 26
%if CHECKED
fv%[i]: push    ebx
        mov     ebx,ARENA+LET+40h+2*i
        NEXTF
%else
fv%[i]: cmp     byte [esi],'@'
        jne     .v1
        push    ebx                     ; x@
        mov     bx,[ARENA+LET+40h+2*i]
        inc     esi
        NEXTF
.v1:    cmp     byte [esi],'!'
        jne     .v2
        mov     [ARENA+LET+40h+2*i],bx  ; x!
        pop     ebx
        inc     esi
        NEXTF
.v2:    push    ebx
        mov     ebx,ARENA+LET+40h+2*i
        NEXTF
%endif
%assign i i+1
%endrep

; The commonest punctuation, written for the fast build (as the shared
; handlers, but with the dispatcher inline; and '%' without XCHG with
; memory, which is locked, and slow).
fs_add: pop     edx                     ; +
        add     bx,dx
        NEXTF
fs_sub: mov     al,[esi]                ; -
        sub     al,'0'
        cmp     al,10
        jb      negnum                  ; (a negative number)
        pop     edx
        sub     dx,bx
        mov     bx,dx
        NEXTF
fs_mul: pop     edx                     ; *
        imul    bx,dx
        NEXTF
%undef  NEXTJ
%define NEXTJ   NEXTF
fs_div: DIVCODE                         ; /
%undef  NEXTJ
%define NEXTJ   jmp ebp
fs_and: pop     edx                     ; &
        and     bx,dx
        NEXTF
fs_or:  pop     edx                     ; |
        or      bx,dx
        NEXTF
fs_xor: pop     edx                     ; ^
        xor     bx,dx
        NEXTF
fs_not: not     bx                      ; ~
        NEXTF
fs_lt:  pop     edx                     ; <  (DX = a, BX = b: carry if a < b)
        xor     dh,80h
        xor     bh,80h
        cmp     dx,bx
        sbb     bx,bx
        NEXTF
fs_gt:  pop     edx                     ; >  (carry if b < a)
        xor     dh,80h
        xor     bh,80h
        cmp     bx,dx
        sbb     bx,bx
        NEXTF
fs_eq:  pop     edx                     ; =
        sub     bx,dx
        cmp     bx,1
        sbb     bx,bx
        NEXTF
fs_dup: push    ebx                     ; :
        NEXTF
fs_drop:pop     ebx                     ; ;
        NEXTF
fs_swap:pop     edx                     ; %
        push    ebx
        mov     ebx,edx
        NEXTF
fs_fet: mov     bx,[ebx]                ; @
        NEXTF
fs_cfet:mov     bl,[ebx]                ; ,
        mov     bh,0
        NEXTF
fs_store:                               ; !
%if CHECKED
        call    chkst2
%endif
        pop     edx
        mov     [ebx],dx
        pop     ebx
        NEXTF
fs_cstore:                              ; .
%if CHECKED
        call    chkst1
%endif
        pop     edx
        mov     [ebx],dl
        pop     ebx
        NEXTF
fs_open:test    bx,bx                   ; (
        pop     ebx
        jz      .op1
        sub     edi,4                   ; the block start
        mov     [edi],esi
        dec     byte [V(v_pcnt)]
        jz      fpoll
        NEXTF
.op1:   call    skip
        NEXTF
fs_close:test   bx,bx                   ; )
        pop     ebx
        jz      .cl1
        mov     esi,[edi]               ; the block start, read where it is
        dec     byte [V(v_pcnt)]
        jz      fpoll
        NEXTF
.cl1:   add     edi,4
        NEXTF
fs_ret: mov     esi,[edi]               ; ]
        add     edi,4
        NEXTF
fs_break:test   bx,bx                   ; backslash
        pop     ebx
        jz      .br2
        call    skip
        test    al,al                   ; ')': the block start goes; ']' returns
        jz      .br1
        mov     esi,[edi]
.br1:   add     edi,4
.br2:   NEXTF
fs_tor: sub     edi,4                   ; {
        mov     [edi],ebx
        pop     ebx
        dec     byte [V(v_pcnt)]
        jz      fpoll
        NEXTF
fs_fromr:push   ebx                     ; }
        mov     ebx,[edi]
        add     edi,4
        NEXTF
fign:   NEXTF                           ; control characters, space, DEL (and
                                        ;   80h-FFh unchecked): nothing

; The tables. The punctuation's handlers, by character:
%define FP_33   fs_store                ; !
%define FP_34   h_str                   ; "
%define FP_35   h_num                   ; #
%define FP_36   h_print                 ; $
%define FP_37   fs_swap                 ; %
%define FP_38   fs_and                  ; &
%define FP_39   h_emit                  ; '
%define FP_40   fs_open                 ; (
%define FP_41   fs_close                ; )
%define FP_42   fs_mul                  ; *
%define FP_43   fs_add                  ; +
%define FP_44   fs_cfet                 ; ,
%define FP_45   fs_sub                  ; -
%define FP_46   fs_cstore               ; .
%define FP_47   fs_div                  ; /
%define FP_58   fs_dup                  ; :
%define FP_59   fs_drop                 ; ;
%define FP_60   fs_lt                   ; <
%define FP_61   fs_eq                   ; =
%define FP_62   fs_gt                   ; >
%define FP_63   h_key                   ; ?
%define FP_64   fs_fet                  ; @
%define FP_91   h_def                   ; [
%define FP_92   fs_break                ; backslash
%define FP_93   fs_ret                  ; ]
%define FP_94   fs_xor                  ; ^
%define FP_95   h_alloc                 ; _
%define FP_96   h_grave                 ; `
%define FP_123  fs_tor                  ; {
%define FP_124  fs_or                   ; |
%define FP_125  fs_fromr                ; }
%define FP_126  fs_not                  ; ~
; DENT c, after: the entry for character c in dtab (after 0) or dtabd (1)
%macro  DENT 2
 %assign c %1
 %if c >= 30h && c <= 39h
  %if %2
        dd      fdm
  %else
   %assign d c-30h
        dd      fd%[d]
  %endif
 %elif %2 && CHECKED
        dd      fdx
 %elif c == 0
        dd      endprog                 ; NUL: the end of the program
 %elif c < 21h || c == 7Fh
        dd      fign
 %elif c >= 80h
  %if CHECKED
        dd      e_hi                    ; reserved (X)
  %else
        dd      fign
  %endif
 %elif c >= 41h && c <= 5Ah
  %assign d c-41h
        dd      fu%[d]
 %elif c >= 61h && c <= 7Ah
  %assign d c-61h
        dd      fv%[d]
 %else
        dd      FP_%[c]
 %endif
%endmacro
        align   4, db 0
dtab:
%assign j 0
%rep 256
        DENT    j, 0
%assign j j+1
%endrep
dtabd:
%assign j 0
%rep 256
        DENT    j, 1
%assign j j+1
%endrep
; sktab: for skip, 1 for the six characters that count there
sktab:
%assign j 0
%rep 256
 %if j == 0 || j == 22h || j == 28h || j == 29h || j == 5Bh || j == 5Dh
        db      1
 %else
        db      0
 %endif
%assign j j+1
%endrep
%endif

; =============================================================================
;  The imports: kernel32.dll only. An import directory entry, the import
;  lookup table, the hint/name entries and the DLL's name; then the import
;  address table, which the loader fills in, right below `next` (with the
;  routine pointers after it), so that CALL [EBP+d8] reaches it.
; =============================================================================
%macro  IMPORTS 1
        IMP     GetStdHandle
        IMP     GetConsoleMode
        IMP     SetConsoleMode
        IMP     GetCommandLineA
        IMP     CreateFileA
        IMP     ReadFile
        IMP     WriteFile
%if EDITOR
        IMP     CloseHandle             ; (a runner leaves its file open)
%endif
        IMP     WaitForMultipleObjects
        IMP     CreateWaitableTimerExW
        IMP     SetWaitableTimer
        IMP     ReadConsoleInputA
        IMP     ExitProcess
%endmacro
        align   4, db 0
idesc:  dd      ilt-IB                  ; OriginalFirstThunk: the lookup table
        dd      0                       ; TimeDateStamp
        dd      0                       ; ForwarderChain
        dd      dllname-IB              ; Name
        dd      iat-IB                  ; FirstThunk: the IAT
        times   20 db 0                 ; the null entry that ends the list
idesc_end:
%macro  IMP 1
        dd      hn_%1-IB
%endmacro
ilt:    IMPORTS 0
        dd      0
%macro  IMP 1
hn_%1:  dw      0                       ; hint
        db      %str(%1),0
        align   2, db 0
%endmacro
        IMPORTS 0
dllname:db      'KERNEL32.dll',0
        align   4, db 0
%macro  IMP 1
iat_%1: dd      hn_%1-IB
%endmacro
iat:    IMPORTS 0
        dd      0
iat_end:

; The pointers for CALLP (see the top).
%macro  PTR 1
 %if P_%1
p_%1:   dd      %1
 %endif
%endmacro
ptrs:   PTR     putc
        PTR     waitk
        PTR     ekey
        PTR     rdnum
        PTR     find
        PTR     pmsg
        PTR     pdec
        PTR     hexc

; =============================================================================
;  The inner loop: read one character and sort it by range.
;
;    00h          end of program
;    01h-20h, 7Fh-FFh   ignored (control, space, DEL, high bytes; the checked
;                 build stops on 80h-FFh: X)
;    30h-39h      digit: read a whole number
;    41h-5Ah      A-Z: call the word in that letter's cell
;    61h-7Ah      a-z: push the address of that letter's cell
;    the rest     punctuation: jump through PTAB, 32 entries
;
;  (The fast build has none of this: `next` is its table's dispatcher. See
;  "The fast build".)
; =============================================================================
%if FAST == 0
; Digits: step back onto the first digit and read the whole number.
digit:  push    ebx
        dec     esi
        CALLP   rdnum
        jmp     ebp

 %if SBASEU == 0
; a-z: push the cell's address (the cell is the variable). (The unchecked
; base build does x@ and x! in one step: its `lower` is after the window.)
lower:  push    ebx
        lea     ebx,[ARENA+LET+eax*2]
        jmp     ebp
 %endif
; (digit, lower and ctl are here, before next, to keep the variables after
; next in reach)
ctl:    add     al,21h                  ; back to c; zero only for NUL
        jnz     next                    ; the rest are ignored
        jmp     endprog
%endif
%if CHECKED
e_hi:   mov     al,'X'                  ; a reserved byte outside a string
        jmp     error
%endif
%if FAST
next:   NEXTF                           ; (the fast build: through the table)
%else
next:
%if CHECKED
        call    chkstk                  ; both stacks, once per character
%endif
        xor     eax,eax
        lodsb
        sub     al,21h                  ; AL = c - 21h
        jb      ctl                     ; c < 21h: NUL ends, the rest are ignored
        cmp     al,0Fh
        jb      punct                   ; 21h-2Fh: PTAB index 0-14
        sub     al,0Fh                  ; AL = c - 30h
        cmp     al,0Ah
        jb      digit                   ; 30h-39h
        cmp     al,11h
        jb      p3a                     ; 3Ah-40h
        sub     al,11h                  ; AL = c - 41h
        cmp     al,1Ah
        jb      upper                   ; 41h-5Ah: AL = letter index 0-25
        cmp     al,20h
        jb      p5b                     ; 5Bh-60h
        cmp     al,3Ah
        jb      lower                   ; 61h-7Ah: AL = 20h-39h (cell +64 bytes)
        cmp     al,3Eh
%if CHECKED
        je      next                    ; 7Fh, DEL: ignored
        jae     e_hi                    ; 80h-FFh: reserved
%else
        jae     next                    ; 7Fh-FFh: ignored
%endif
        sub     al,1Ah                  ; 7Bh-7Eh: -1Eh in all, index 28-31
p5b:    sub     al,9                    ; 5Bh-60h: -4 in all, index 22-27
p3a:    add     al,5                    ; 3Ah-40h: index 15-21
punct:  mov     al,[ptab+eax]
        lea     eax,[hbase+eax]
        jmp     eax
%endif

codeend:

rawend:
RAWSIZE equ     (rawend-tstart+1FFh) & ~1FFh
        times   (-(rawend-tstart)) & 1FFh db 0

; ---- the interpreter's variables, after the code (zero at the start) -------
; They are in the zeros that pad the section to its FileAlignment, or past
; them in the uninitialised part: within 127 bytes of `next` either way.
        absolute rawend
v_cnt:  resd    1               ; a count for ReadFile and the like
v_hin:  resd    1               ; the standard input handle
v_htm:  resd    1               ; the timer, or 0 (must follow v_hin)
v_outh: resd    1               ; the handle putc writes to
v_dstop:resd    1               ; ESP for the empty data stack
v_iscon:resb    1               ; non-zero if the input is a console
v_pcnt: resb    1               ; the break key's countdown
v_mode: resd    1               ; the console's input mode at the start
%if CHECKED
v_npend:resd    1               ; the heap's first address (checked '_')
v_skat: resd    1               ; where the skip started (checked N)
v_str:  resd    1               ; the address '$' prints from (checked Q)
%endif
%if EDITOR
v_edln: resd    1               ; the editor: the line ^E put in the input
%endif
v_rec:  resb    20              ; an INPUT_RECORD; ReadFile's byte. (Last:
                                ;   only its first 15 bytes need be in reach)
        times   -((v_rec+15-next) > 127) db 0   ; (an error if out of reach)
        times   -((next-iat) > 128) db 0
%if QK
v_tlen: resd    1               ; the program text's length, NUL included
        alignb  8
skc:    resd    2*NSKC          ; the skip cache: {start, end}, 64 of them
        times   -((skc+8*NSKC-tstart) > NAMEBUF-(IB+SECTVA)) db 0
%endif
