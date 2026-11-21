; =============================================================================
;  B8Script interpreter for the Intel 8080
;  Spec: docs/b8script.md (2026-10-09) plus the 2026-11-20 changes:
;        [x stores in a variable, "[ " pushes an anonymous block, any other
;        character after [ is an error, the heap pointer lives at z10+.
;        The string escape is '/' (it was '>').
;        Dividing by zero is not checked. -n? does no more editing than
;        Backspace.
;  Design follows the Z80 interpreter (z80/b8s-z80.asm), with 8080 opcodes
;  only.
;
;  Two switches, set in the two EQU lines below:
;    CPM      0 = generic ROM build (KEY/CONOUT at fixed addresses)
;             1 = CP/M 2.2 .COM file: loads the file named on the command line
;    CHECKED  0 = no checks (spec: "B8Script checks nothing")
;             1 = stops on stack overrun, Ctrl-C, heap past the limit, a store
;                 outside the program's own space, and a bad character after [,
;                 printing a letter and the place, like  S @ 245
;
;  Assembler: asm80 (https://maly.github.io/asm80-node/), I8080 mode.
; =============================================================================

CPM     EQU     0               ; 1 = CP/M .COM build
CHECKED EQU     0               ; 1 = checked build

; -----------------------------------------------------------------------------
;  Register use, everywhere in the interpreter
;
;    BC   IP: the address of the next program character to read
;    HL   TOS: the top data-stack cell is kept here, not in memory
;    SP   the data stack: (SP) is NOS, the cell under TOS. The data stack is
;         the 8080's own stack, which is what the spec's machine-code contract
;         needs ("the data cells above the return address").
;    A DE scratch. Every handler is entered with HL = TOS and may use A, DE.
;
;  The return stack pointer has no register (the 8080 has no spare pair): it
;  is the RAM word RSP. Only rpop, rpushd and ')' (and the checks) touch it.
;
;  One-byte calls. The routines used most are reached with RST, one byte
;  instead of three. (asm80 wants the vector number: RST 1 = RST 08h.)
;
;    RST 1  08h  rpop    pop the return stack into HL
;    RST 3  18h  drop    drop TOS, then next character     (ends a handler)
;    RST 4  20h  neg16   HL = -HL
;    RST 5  28h  putc    print A
;    RST 6  30h  next    next character                    (ends a handler)
;
;  RST 3 and RST 6 never return: an RST is a CALL, so the first thing each
;  of them does is POP D to throw the return address away.
;
;  The CP/M build can't own page zero, so the block from `vecs` to `vecend`
;  (image addresses 0108h-0133h) is copied to 0008h-0033h when it starts. The
;  code in that block has no jumps inside itself, so it works at either place.
;
;  Dispatch. PTAB holds one byte per punctuation character: the low byte of
;  its handler's address. The high byte is worked out from the character:
;  the handlers of the first NPG1 characters (in code order) start in the
;  image's second page, the rest in its first. The layout below keeps to
;  that, and testing/chktab.py checks it in every build.
;
;  What the 8080 lacks, and what replaces it: no JR (JMP/Jcc), no DJNZ, no
;  SBC HL (byte-wise SUB/SBB, or negate and DAD), no shifts on register pairs
;  (DAD H doubles; RAL/RAR through A), no LDIR/CPIR (small loops).
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
;  Memory map. Everything the interpreter writes is in four RAM pages:
;
;    RSPAGE   return stack, 112 entries (the pointer stays inside this page)
;    DSPAGE   data stack, 127 cells (SP stays inside this page)
;    LETPAGE  letter cells: A..Z at +00h..+33h, a..z at +40h..+73h (so a word
;             cell is always 64 bytes below its variable), the heap pointer at
;             +7Ch (= z10+), interpreter variables in the gaps, and the -n?
;             line buffer at +80h..+FFh
;    PROG     the program text, NUL-terminated; the heap starts after the NUL
;
;  The stacks sit below the letter page, so "the program's own space" (what
;  the checked build lets ! and . write) is the single range from the letter
;  page up to the heap limit. Each stack's page has a guard band: the data
;  stack can overrun by a cell or two (and the calls made while it is full)
;  into the top 32 bytes of the return-stack page, which are never used, and
;  the return stack by one entry into the page below it.
; -----------------------------------------------------------------------------

        IF      CPM
BDOS    EQU     0005h
EXIT    EQU     0000h           ; warm boot
BASE    EQU     0100h           ; where the image starts
        ENDIF
        IFN     CPM
; ---- generic machine: edit these to suit -----------------------------------
KEY     EQU     0FF06h          ; a waiting key in A, or A = 0 if none is
                                ;   waiting. The zero flag must match A
                                ;   (end the routine with ORA A / RET).
CONOUT  EQU     0FF03h          ; print the character in A
EXIT    EQU     0FF09h          ; where to go when the program ends
;   KEY and CONOUT must preserve BC, DE and HL.
RSPAGE  EQU     80h             ; 8000h return stack
DSPAGE  EQU     81h             ; 8100h data stack
LETPAGE EQU     82h             ; 8200h letter cells and line buffer
PROG    EQU     8300h           ; where the loader puts the program text
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)
BASE    EQU     0000h           ; where the image starts
        ENDIF

MSLOOP  EQU     40              ; n? inner loop count for about 1 ms (1-255):
                                ; each pass calls getk once, so tune it for
                                ; your clock and your KEY routine

; letter-page layout (offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     LET+7Ch         ; z10+, the heap pointer
RSP     EQU     LET+34h         ; gap after Z: the return stack pointer;
KEYBUF  EQU     LET+36h         ;   a held-back key
LBHDR   EQU     LET+7Eh         ; CP/M BDOS 10 header: max, count
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSTOP   EQU     RSPAGE*256+0E0h ; empty return stack: the 32 bytes above it
                                ; take calls made while the data stack is full
DSTOP   EQU     DSPAGE*256+0FEh ; empty data stack

; =============================================================================
;  The first 49 bytes: the entry, then the RST routines, with small handlers
;  and routines filling the gaps between them. Generic: this IS page zero.
;  CP/M: it is the start of the .COM file, and 0108h-0133h is also copied to
;  page zero (see the header).
; =============================================================================
        ORG     BASE
        LXI     SP,DSTOP        ; 00  reset, or the start of the .COM file
        JMP     start
rdrop:  RST     1               ; 06  drop the top of the return stack, then
        RST     3               ;     drop TOS (a spent flag) and go on
vecs:
; ---- RST 1: rpop: pop the return stack into HL (DE is lost) -----------------
rpop:   LHLD    RSP             ; 08
        MOV     E,M
        INX     H
        MOV     D,M
        INX     H
        SHLD    RSP
        XCHG
        RET                     ; 13  (so RST 2 is not used)
h_tor:  XCHG                    ; 14  '{' TOS to the return stack; rpushd
        JMP     rpushd          ;     brings up the new TOS
; ---- RST 3: drop TOS, then next ---------------------------------------------
rst18:  POP     D               ; 18  discard the RST's return address
        POP     H               ;     new TOS = NOS
        JMP     next0
h_fromr:PUSH    H               ; 1D  '}' return stack to TOS
        RST     1
        RST     6
; ---- RST 4: neg16: HL = -HL (keeps BC, DE) ----------------------------------
neg16:  XRA     A               ; 20
        SUB     L
        MOV     L,A
        SBB     A
        SUB     H
        MOV     H,A
        RET
jphl:   PCHL                    ; 27  (for the machine-code call)
; ---- RST 5: putc: print A (keeps BC, DE, HL) --------------------------------
rst28:
        IFN     CPM
putc:   JMP     CONOUT          ; 28
        ENDIF
        IF      CPM
        JMP     putc            ; 28
        ENDIF
; exec: '`' with no hex digit after it: call the machine code at TOS. It
; returns here, with its top cell on the stack: that becomes the new TOS.
exec:   CALL    jphl            ; 2B
        POP     H
        RST     6
; ---- RST 6: next character --------------------------------------------------
rst30:  POP     D               ; 30  discard the RST's return address
        IF      CPM
        JMP     next0           ; (this copy runs in page zero)
        ENDIF
vecend:

; =============================================================================
;  The inner loop: read one character and sort it by range.
;
;    00h          end of program
;    01h-20h, 7Fh-FFh   ignored (control, space, DEL, high bytes)
;    30h-39h      digit: read a whole number
;    41h-5Ah      A-Z: call the word in that letter's cell
;    61h-7Ah      a-z: push the address of that letter's cell
;    the rest     punctuation: jump through PTAB, 32 entries, in code order
; =============================================================================
next0:
        IF      CHECKED
        CALL    chkstk          ; both stacks are checked once per character
        ENDIF
        LDAX    B
        INX     B
        SUI     21h             ; A = c - 21h
        JC      ctl             ; c < 21h: NUL ends, the rest are ignored
        CPI     0Fh
        JC      punct           ; 21h-2Fh: PTAB index 0-14
        SUI     0Fh             ; A = c - 30h
        CPI     0Ah
        JC      digit           ; 30h-39h
        CPI     11h
        JC      p3a             ; 3Ah-40h
        SUI     11h             ; A = c - 41h
        CPI     1Ah
        JC      upper           ; 41h-5Ah: A = letter index 0-25
        CPI     20h
        JC      p5b             ; 5Bh-60h
        CPI     3Ah
        JC      lower           ; 61h-7Ah: A = 20h-39h (cell +64 bytes)
        CPI     3Eh
        JNC     next0           ; 7Fh-FFh: ignored
        SUI     1Ah             ; 7Bh-7Eh: -1Eh in all, index 28-31
p5b:    SUI     9               ; 5Bh-60h: -4 in all, index 22-27
p3a:    ADI     5               ; 3Ah-40h: index 15-21

; Punctuation: A = the PTAB index. The handler starts with HL = TOS,
; untouched, and A, DE free.
punct:  ADI     PTAB & 0FFh     ; PTAB never crosses a page
        MOV     E,A
        MVI     D,PTAB / 256
        CPI     (PTAB & 0FFh) + NPG1 ; carry: one of the first NPG1
        LDAX    D
        MOV     E,A             ; the handler's low byte
        IFN     CPM
        MVI     A,0
        RAL                     ; its page: 0 + carry
        ENDIF
        IF      CPM
        MVI     A,1
        ACI     0               ; its page: 1 + carry
        ENDIF
        MOV     D,A
        PUSH    D               ; jump to it; the stack is balanced again
        RET                     ;   when the handler starts

; ctl: characters below 21h. A = c - 21h.
ctl:    ADI     21h             ; back to c; zero only for NUL
        JNZ     next0           ; the rest are ignored
endprog:JMP     EXIT            ; the program has ended

; =============================================================================
;  Handlers that must start in the image's first page: ^ _ ` | ~
;  ({ and } are up among the RST routines.)
; =============================================================================
h_xor:  POP     D
        MOV     A,H
        XRA     D
        MOV     H,A
        MOV     A,L
        XRA     E
        MOV     L,A
        RST     6

h_or:   POP     D
        MOV     A,H
        ORA     D
        MOV     H,A
        MOV     A,L
        ORA     E
        MOV     L,A
        RST     6

h_not:  RST     4               ; ~x = -x - 1
        DCX     H
        RST     6

; '_' ( n -- addr ): the heap pointer moves up by n; TOS is the old pointer.
h_alloc:XCHG
        LHLD    HEAP
        PUSH    H
        DAD     D               ; the new top
        IF      CHECKED
        CALL    chkhp
        ENDIF
        SHLD    HEAP
        POP     H
        RST     6

; ---- the letters and digits --------------------------------------------------

; a-z: push the cell's address (the cell is the variable)
lower:  PUSH    H
        ADD     A
        MOV     L,A
        MVI     H,LETPAGE
        RST     6

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  PUSH    H               ; keep TOS: rpushd pops it back
        ADD     A
        MOV     L,A
        MVI     H,LETPAGE       ; HL -> cell
        MOV     D,B
        MOV     E,C             ; DE = the return address
        MOV     C,M
        INX     H
        MOV     B,M             ; IP = the word's body, and fall into rpushd

; rpushd: push DE on the return stack, then pop TOS off the data stack and
; go on. Every push of the return stack ends here: for a word call the cell
; popped is the TOS that upper parked; for '(' and '{' it is the cell under
; the one that was used up.
rpushd:
        IF      CHECKED
        CALL    chkbrk          ; Ctrl-C is checked at every word call, block
        ENDIF                   ;   entry, loop-back and '{'
        LHLD    RSP
        DCX     H
        MOV     M,D
        DCX     H
        MOV     M,E
        SHLD    RSP
        POP     H
        RST     6

; ---- machine code: the grave -----------------------------------------------
; '`' plus a hex digit loads bytes: ( addr -- addr' ). Pairs of hex digits
; are stored from addr until a non-hex character; then a RET (C9h) is
; written and its address is left. An odd last digit is consumed and dropped.
; '`' plus anything else calls the machine code at TOS: ( addr -- ). The
; code is entered by CALL with the data stack above the return address; it
; must keep BC, and on return the top cell becomes the new TOS.
h_grave:CALL    hexc
        JNC     exec
hx1:    ADD     A
        ADD     A
        ADD     A
        ADD     A
        MOV     D,A             ; the high digit
        CALL    hexc
        JNC     hx2             ; odd digit: consumed and dropped
        ORA     D
        IF      CHECKED
        CALL    chkst
        ENDIF
        MOV     M,A
        INX     H
        CALL    hexc
        JC      hx1
hx2:
        IF      CHECKED
        CALL    chkst
        ENDIF
        MVI     M,0C9h
        RST     6

; ---- where the two pages meet ----------------------------------------------
; The first page ends somewhere among the next four handlers, ] \ [ @ (they
; are in falling code order for this), and where exactly differs between the
; builds: NPG1 follows. Every handler below these four must start in the
; second page, and every one above in the first; chktab.py checks both.

; ']' returns: pop an address and jump to it. TOS is parked on the stack
; while rpop uses HL, and the drop at the end brings it back.
h_ret:  PUSH    H
ret2:   RST     1
        MOV     B,H
        MOV     C,L
        RST     3

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
; The flag stays in HL as the spent cell that rdrop and ret2 drop.
h_break:MOV     A,H
        ORA     L
        JZ      h_drop          ; false: just drop the flag
        CALL    skip
        ORA     A               ; skip returns 0 for ')'
        JNZ     ret2
        JMP     rdrop

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything that is not a letter as the space; the
; checked build stops on it.)
h_def:  LDAX    B
        INX     B
        SUI     'A'             ; a letter gives 0-25 or 32-57: lowercase
        MOV     E,A             ;   lands 64 bytes up
        ANI     0DFh            ; fold case
        CPI     26
        JNC     def2            ; not a letter
        MOV     A,E
        ADD     A
        MOV     E,A
        MVI     D,LETPAGE       ; DE -> cell
        MOV     A,C
        STAX    D
        INR     E
        MOV     A,B
        STAX    D
        JMP     skipnx
def2:
        IF      CHECKED
        MOV     A,E
        CPI     ' '-'A'+256
        JNZ     e_brack         ; anything but a letter or a space
        ENDIF
        PUSH    H               ; an anonymous block: push its address
        MOV     H,B
        MOV     L,C
skipnx: CALL    skip
        RST     6

h_fetch:MOV     E,M             ; '@'
        INX     H
        MOV     D,M
        XCHG
        RST     6

; =============================================================================
;  Handlers that must start in the image's second page.
;  '?' is the last (with ',' inside it in the unchecked build), so its long
;  tail may run past that page.
; =============================================================================

; ---- flow control ----------------------------------------------------------

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: MOV     A,H
        ORA     L
        POP     H
        JZ      skipnx
        PUSH    H               ; (rpushd pops it again)
        MOV     D,B
        MOV     E,C             ; the block starts at the IP
        JMP     rpushd

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on.
h_close:MOV     A,H
        ORA     L
        JZ      rdrop
        RST     1               ; pop the block start ...
        MOV     B,H
        MOV     C,L             ; ... jump to it ...
        XCHG
        JMP     rpushd          ; ... and push it back (which drops the flag)

; ---- arithmetic and logic: ( NOS TOS -- result ) ---------------------------

; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  LDAX    B
        SUI     '0'
        CPI     10
        JC      negnum
        RST     4               ; a - b = a + (-b): fall into '+'
h_add:  POP     D
        DAD     D
        RST     6

h_and:  POP     D
        MOV     A,H
        ANA     D
        MOV     H,A
        MOV     A,L
        ANA     E
        MOV     L,A
        RST     6

; Signed compares. Both are "DE < HL" for the right pair: > swaps the two
; cells first (XTHL), < doesn't. There is no overflow flag, so the signed
; answer is the unsigned borrow of DE - HL, flipped when the signs differ.
; SBB A turns a carry into -1 or 0 with no branch.
h_gt:   XTHL                    ; a > b  is  b < a
h_lt:   POP     D               ; a < b: DE = a, HL = b
        MOV     A,E
        SUB     L
        MOV     A,D
        SBB     H
        SBB     A               ; A = -1 if DE < HL unsigned
        MOV     L,A
        MOV     A,H
        XRA     D
        RAL                     ; carry = the signs differ
        SBB     A
        XRA     L               ; flip when they do
        MOV     H,A
        MOV     L,A
        RST     6

h_eq:   POP     D
        MOV     A,L
        XRA     E
        MOV     L,A
        MOV     A,H
        XRA     D
        ORA     L               ; zero if equal
        SUI     1               ; carry only for zero
        SBB     A
        MOV     H,A
        MOV     L,A
        RST     6

; '*': shift-and-add on the multiplier's low bit, so it stops as soon as the
; multiplier is used up; only the low 16 bits are kept.
h_mul:  POP     D               ; DE = multiplicand
        PUSH    B
        MOV     B,H
        MOV     C,L             ; BC = multiplier
        LXI     H,0
mul1:   MOV     A,B
        ORA     A               ; clear carry
        RAR
        MOV     B,A
        MOV     A,C
        RAR
        MOV     C,A             ; BC >> 1, carry = the bit shifted out
        JNC     mul2
        DAD     D
mul2:   XCHG
        DAD     H               ; multiplicand << 1
        XCHG
        MOV     A,B
        ORA     C
        JNZ     mul1
        POP     B
        RST     6

; '/' ( a b -- q r ): the remainder is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Dividing by zero is not checked: it returns two cells of no meaning.
h_div:  POP     D               ; DE = a, HL = b
        PUSH    B
        MOV     A,D
        ORA     A
        PUSH    PSW             ; S flag = sign of a (for r)
        XRA     H
        PUSH    PSW             ; S flag = sign of q
        MOV     A,H
        ORA     A
        CM      neg16           ; HL = |b|
        XCHG
        MOV     A,H
        ORA     A
        CM      neg16           ; HL = |a|, DE = |b|
        CALL    udiv            ; HL = q, BC = r
        POP     PSW
        CM      neg16           ; q's sign
        XCHG                    ; DE = q
        MOV     H,B
        MOV     L,C             ; HL = r
        POP     PSW
        CM      neg16           ; r's sign
        POP     B
        PUSH    D               ; q under r
        RST     6

; ---- stack and storage -----------------------------------------------------

h_dup:  PUSH    H               ; ':'
        RST     6

h_swap: XTHL                    ; '%'
        RST     6

h_store:POP     D               ; '!' ( n addr -- )
        IF      CHECKED
        INX     H               ; both bytes must be in the program's space
        CALL    chkst
        DCX     H
        ENDIF
        MOV     M,E
        INX     H
        MOV     M,D
        RST     3

h_cstore:POP    D               ; '.' ( c addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        MOV     M,E
        RST     3

; ---- console ---------------------------------------------------------------

; 22h pushes the address of the text after it and skips the string.
h_str:  PUSH    H
        MOV     H,B
        MOV     L,C
        CALL    skipstr
        RST     6

; '$' prints the string at TOS, decoding escapes: '/' plus a character
; clears that character's bit 6 (/M is CR, /` is space; '/' and '"' have no
; bit 6, so // and /" give themselves).
h_print:MOV     A,M
        INX     H
        CPI     22h
        JZ      h_drop
        CPI     '/'
        JNZ     pr1
        MOV     A,M
        INX     H
        ANI     0BFh
pr1:    RST     5
        JMP     h_print

h_emit: MOV     A,L             ; "'"
        RST     5
h_drop: RST     3               ; ';' is this one byte

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  MOV     A,H
        ORA     A
        JP      num1
        MVI     A,'-'
        RST     5
        RST     4
num1:   PUSH    B
        CALL    pdec
        POP     B
        RST     3

        IF      CHECKED         ; (the checked build has no room to start ','
h_cfetch:MOV    L,M             ;   as late as the unchecked one does: see
        MVI     H,0             ;   the end of '?')
        RST     6
        ENDIF

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. The buffer
;          holds 127 characters and the CR: a bigger count is taken as 127.
h_key:  MOV     A,H
        ORA     A
        JM      line
kt1:    MVI     E,MSLOOP        ; one millisecond, roughly
kt2:    CALL    getk
        JNZ     kt3
        DCR     E
        JNZ     kt2
        MOV     A,H             ; 0? never counts down: it waits
        ORA     L
        JZ      kt1
        DCX     H
        MOV     A,H
        ORA     L
        JNZ     kt1             ; A = 0 if the time ran out
        IF      1-CHECKED
        DB      0FEh            ; (CPI: steps over the one byte of ',')
h_cfetch:MOV    A,M             ; ',' shares '?'s ending: A becomes TOS
        ENDIF
kt3:    MOV     L,A
        MVI     H,0
        RST     6

        IF      CPM
        ; CP/M: BDOS 10 does the editing (the spec allows the platform's
        ; own line editor). It doesn't store the CR, so it is added here.
line:   LXI     D,127           ; TOS is minus the count: adding 127 carries
        DAD     D               ;   only for 1 to 127, and leaves 127 - count
        SBB     A
        ANA     L               ; (0 for a count that is too big)
        XRI     127             ; A = the count, 127 at most
        STA     LBHDR
        PUSH    B
        LXI     D,LBHDR
        MVI     C,10
        CALL    BDOS
        POP     B
        LXI     H,LBHDR+1
        MOV     A,M             ; the count typed (0-127)
        INR     L               ; HL = LINEBUF, whose low byte is 80h:
        ADD     L               ;   adding the count to L can't carry
        MOV     L,A
        MVI     M,13
        MVI     L,LINEBUF & 0FFh
        RST     6
        ENDIF
        IFN     CPM
        ; Generic: Backspace takes the last character back (and is echoed as
        ; it is), CR ends (stored, not echoed), every other key is stored and
        ; echoed until the line is full. The line buffer starts at offset 80h
        ; of its page, so L alone is the place in the line: D holds the L of
        ; a full line.
line:   LXI     D,127           ; TOS is minus the count: adding 127 carries
        DAD     D               ;   only for 1 to 127, and leaves 127 - count
        SBB     A
        ANA     L               ; (0 for a count that is too big)
        CMA
        MOV     D,A             ; D = the L of a full line: 80h + count, FFh
                                ;   at most
        LXI     H,LINEBUF
ln2:    CALL    getk
        JZ      ln2
        CPI     13
        JZ      ln5
        CPI     8
        JZ      ln4
        MOV     E,A
        MOV     A,L
        CMP     D
        JZ      ln2             ; full
        MOV     M,E
        INR     L
        MOV     A,E
ln3:    RST     5
        JMP     ln2
ln4:    DCR     L               ; Backspace: one back, and echo it,
        JM      ln3             ;   unless the line was empty (L left the
        INR     L               ;   upper half of the page)
        JMP     ln2
ln5:    MOV     M,A             ; the CR
        MVI     L,LINEBUF & 0FFh
        RST     6
        ENDIF

; =============================================================================
;  Dispatch table: the low byte of each handler's address, in code order.
;  It must not cross a page (the dispatcher only adds to its low byte).
; =============================================================================
; The handlers of the first NPG1 characters start in the image's second page.
; ] \ [ @ sit where the two pages meet, and which side each lands on
; differs between the builds, so the count is worked out here.
; (One division to a line: asm80 only rounds down when it stores a value.)
PGRET   EQU     (h_ret-BASE)/256        ; 0 = first page, 1 = second
PGBRK   EQU     (h_break-BASE)/256
PGDEF   EQU     (h_def-BASE)/256
PGFET   EQU     (h_fetch-BASE)/256
NPG1    EQU     21 + PGFET + PGDEF + PGBRK + PGRET
PTAB:   DB      h_store & 0FFh  ; !
        DB      h_str & 0FFh    ; "
        DB      h_num & 0FFh    ; #
        DB      h_print & 0FFh  ; $
        DB      h_swap & 0FFh   ; %
        DB      h_and & 0FFh    ; &
        DB      h_emit & 0FFh   ; '
        DB      h_open & 0FFh   ; (
        DB      h_close & 0FFh  ; )
        DB      h_mul & 0FFh    ; *
        DB      h_add & 0FFh    ; +
        DB      h_cfetch & 0FFh ; ,
        DB      h_sub & 0FFh    ; -
        DB      h_cstore & 0FFh ; .
        DB      h_div & 0FFh    ; /
        DB      h_dup & 0FFh    ; :
        DB      h_drop & 0FFh   ; ;
        DB      h_lt & 0FFh     ; <
        DB      h_eq & 0FFh     ; =
        DB      h_gt & 0FFh     ; >
        DB      h_key & 0FFh    ; ?
        DB      h_fetch & 0FFh  ; @
        DB      h_def & 0FFh    ; [
        DB      h_break & 0FFh  ; \
        DB      h_ret & 0FFh    ; ]
        DB      h_xor & 0FFh    ; ^
        DB      h_alloc & 0FFh  ; _
        DB      h_grave & 0FFh  ; `
        DB      h_tor & 0FFh    ; {
        DB      h_or & 0FFh     ; |
        DB      h_fromr & 0FFh  ; }
        DB      h_not & 0FFh    ; ~
PTABEND:

; =============================================================================
;  Routines (no handler starts past this point)
; =============================================================================

; Digits: step back onto the first digit and read the whole number.
digit:  PUSH    H
        DCX     B
        CALL    rdnum
        RST     6

; negnum: '-' directly before a digit: read the number, negate it.
negnum: PUSH    H
        CALL    rdnum
        RST     4
        RST     6

; rdnum: read decimal digits at IP into HL; IP is left on the first
; non-digit. Values wrap at 16 bits, as the spec says.
rdnum:  LXI     H,0
rdn1:   LDAX    B
        SUI     '0'
        CPI     10
        RNC
        INX     B
        MOV     D,H
        MOV     E,L
        DAD     H
        DAD     H
        DAD     D
        DAD     H               ; HL * 10
        MOV     E,A
        MVI     D,0
        DAD     D
        JMP     rdn1

; udiv: unsigned HL / DE (DE <= 8000h). Returns HL = quotient, BC = remainder.
; Uses A, BC; the caller saves the IP. HL holds the dividend and, as its bits
; leave at the top, the quotient bits arrive at the bottom. The loop counter
; lives on the stack, since A is busy with the shifts.
; Dividing by 2 is one shift (the spec wants that fast).
udiv:   LXI     B,0
        MOV     A,E
        XRI     2
        ORA     D
        JNZ     udv0
        ORA     H               ; A was 0, and the carry is clear
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A             ; the quotient
        MOV     A,B
        RAL
        MOV     C,A             ; the remainder: the bit that fell out
        RET
udv0:   MVI     A,16
        PUSH    PSW
udv1:   DAD     H               ; next dividend bit into the carry
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      udv2
        MOV     B,A             ; BC - DE (high byte; A holds it)
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
udv2:   POP     PSW
        DCR     A
        PUSH    PSW
        JNZ     udv1
        POP     PSW
        RET

; pdec: print HL unsigned, by recursion on HL / 10 (the stack holds digits).
; Uses BC.
pdec:   LXI     D,10
        CALL    udiv            ; HL = HL / 10, C = the last digit
        MOV     A,C
        PUSH    PSW
        MOV     A,H
        ORA     L
        CNZ     pdec
        POP     PSW
        ADI     '0'
        RST     5
        RET

; skip: read past text to the closer at this level, and return A = 0 if it
; was ')' and 2 if it was ']'. Brackets of both kinds count together;
; strings are stepped over whole. A NUL first ends the program (for '\' with
; no closer; anything else that runs into the NUL had unbalanced brackets
; anyway). D counts the open levels, starting at 1 for the one we are in:
; skip sets it to 0 and falls through the INR that an opener comes back to.
skip:   MVI     D,0
sk3:    INR     D               ; an opener: one deeper
sk1:    LDAX    B
        INX     B
        ORA     A
        JZ      endprog
        CPI     22h
        CZ      skipstr         ; leaves A = 22h, which matches nothing below
        SUI     '('
        JZ      sk3
        DCR     A               ; ')'
        JZ      sk4
        SUI     '['-')'
        JZ      sk3
        CPI     ']'-'['
        JNZ     sk1
sk4:    DCR     D
        RZ                      ; the closer at this level
        JMP     sk1

; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it. Leaves A = 22h.
ss0:    INX     B
skipstr:LDAX    B
        INX     B
        CPI     '/'
        JZ      ss0
        CPI     22h
        JNZ     skipstr
        RET

; hexc: if the character at IP is a hex digit (0-9, A-F, a-f), step over it
; and return its value in A with the carry set; otherwise leave the IP and
; return with the carry clear.
hexc:   LDAX    B
        SUI     '0'
        CPI     10
        JC      hc1
        ANI     0DFh
        SUI     11h
        CPI     6
        RNC
        SUI     0F6h            ; + 10, and sets the carry
hc1:    INX     B
        RET

; =============================================================================
;  Console layer: getk returns a waiting key in A (zero flag clear), or
;  A = 0 with the zero flag set when none is waiting. putc (RST 5) prints A.
;  Both keep BC, DE and HL. In the generic build they are the host's KEY and
;  CONOUT routines themselves.
; =============================================================================
        IF      (1-CPM)*(1-CHECKED)
getk    EQU     KEY             ; the host's routine does the whole job
        ENDIF
        IF      CHECKED
getk:   PUSH    H               ; a key held back by the break check goes
        LXI     H,KEYBUF        ;   first, and is taken out of the buffer
        MOV     A,M
        MVI     M,0
        POP     H
        ORA     A
        RNZ
        ENDIF
        IF      (1-CPM)*CHECKED
        JMP     KEY
        ENDIF
        IF      CPM*(1-CHECKED)
getk:
        ENDIF
        IF      CPM
        MVI     A,0FFh          ; BDOS 6 with E = FFh: a key, or 0
; putc: BDOS 6 for every character. BDOS 2 would check for ^S while
; printing and could swallow a key that BDOS 6 then never sees.
putc:   PUSH    B
        PUSH    D
        PUSH    H
        MOV     E,A
        MVI     C,6
        CALL    BDOS
        POP     H
        POP     D
        POP     B
        ORA     A               ; (for getk)
        RET
        ENDIF

; =============================================================================
;  Checked build: the checks and the error report
; =============================================================================
        IF      CHECKED
; chkstk: both stacks are checked once per character, not in every handler.
; Each stack lives in one page, so it has overrun exactly when the pointer's
; high byte has left that page. Errors are caught one cell late at most; the
; page below each stack is a guard band. (The call itself is on the data
; stack, but in the same page whenever the stack is in range.)
chkstk: XCHG                    ; DE = TOS (HL is needed for the pointers)
        LXI     H,0
        DAD     SP
        MOV     A,H
        CPI     DSPAGE
        JNZ     e_stack
        LHLD    RSP             ; the return stack: in its page, and not
        MOV     A,L             ;   above its empty position (an underflow
        CPI     RSTOP&0FFh+1    ;   would stay inside the page, in the
        JNC     e_rstack        ;   guard band)
        MOV     A,H
        CPI     RSPAGE
        JNZ     e_rstack
        XCHG                    ; TOS back
        RET

; chkbrk: a waiting key is read now; Ctrl-C stops the program, anything
; else is held for the next '?'. Keeps BC, DE, HL.
chkbrk: CALL    getk
        RZ
        CPI     3
        JZ      e_break
        STA     KEYBUF
        RET

; chkst: stop unless HL is in the program's own space: from the letter page
; up to the heap limit (the OS, or HEAPLIM), so the interpreter's stacks and
; whatever lies above the limit are safe. Memory above the heap top but
; below the limit is the program's own: Tiny BASIC keeps its lines there.
; Keeps every register.
chkst:  PUSH    PSW
        MOV     A,H
        CPI     LETPAGE
        JC      e_store
        ENDIF
        IF      CHECKED*(1-CPM)
        CPI     HEAPLIM
        JNC     e_store
        ENDIF
        IF      CHECKED*CPM
        LDA     0007h           ; the BDOS page is the heap limit
        DCR     A
        CMP     H
        JC      e_store
        ENDIF
        IF      CHECKED
        POP     PSW
        RET

; chkhp: stop if working out the new heap top carried (a negative count
; wraps: too big), or if the new top in HL is not below the limit page.
chkhp:  JC      e_heap
        ENDIF
        IF      CHECKED*(1-CPM)
        MOV     A,H
        CPI     HEAPLIM
        RC
        ENDIF
        IF      CHECKED*CPM
        LDA     0007h
        DCR     A
        CMP     H
        RNC
        ENDIF
        IF      CHECKED
; Error entries. Each loads its letter and then hides the next entry inside
; a 3-byte LXI H (the 21h), so they all fall through to `error`.
e_heap: MVI     A,'H'           ; heap past the limit
        DB      21h
e_store:MVI     A,'W'           ; write outside the program's space
        DB      21h
e_stack:MVI     A,'S'           ; data stack over or under
        DB      21h
e_rstack:MVI    A,'R'           ; return stack over or under
        DB      21h
e_break:MVI     A,'B'           ; Ctrl-C
        DB      21h
e_brack:MVI     A,'D'           ; bad character after [
; error: print the letter in A, " @ " and the offset in the program of the
; character just read, then end. For example: S @ 245
error:  LXI     SP,DSTOP        ; the stacks may be wrecked: start clean
        RST     5
        MVI     A,' '
        RST     5
        MVI     A,'@'
        RST     5
        MVI     A,' '
        RST     5
        LXI     H,(0-PROG-1)&0FFFFh ; minus the address of the character
        DAD     B               ;   just read: HL = its offset
        CALL    pdec
        JMP     endprog
        ENDIF

; =============================================================================
;  Startup
; =============================================================================
start:
        IF      CPM
        ; CP/M: the RAM pages follow the image; the heap may grow to the BDOS
        LXI     H,vecs          ; the RST routines go down into page zero
        LXI     D,0008h
        MVI     B,vecend-vecs
cpy:    MOV     A,M
        STAX    D
        INX     H
        INX     D
        DCR     B
        JNZ     cpy
        LXI     D,005Ch         ; open the file named on the command line
        MVI     C,15            ; (no such file: the first read fails too,
        CALL    BDOS            ;   and the program is empty)
        LXI     D,PROG
ld1:    PUSH    D
        MVI     C,26            ; set the DMA address
        CALL    BDOS
        LXI     D,005Ch
        MVI     C,20            ; read the next 128 bytes
        CALL    BDOS
        POP     H               ; HL = the address this record went to
        ORA     A
        JNZ     ld2
        LXI     D,128
        DAD     D
        XCHG
        JMP     ld1
ld2:    MVI     M,0             ; the end of the file counts as NUL
        INX     H               ; the heap starts after it
        ENDIF
        IFN     CPM
        LXI     H,PROG          ; the heap starts after the program's NUL
fnul:   MOV     A,M
        INX     H
        ORA     A
        JNZ     fnul
        ENDIF
        SHLD    HEAP
        LXI     H,RSTOP         ; the return stack is empty
        SHLD    RSP
        IF      CHECKED
        XRA     A
        STA     KEYBUF          ; no key held back
        ENDIF
        LXI     B,PROG          ; the IP
        RST     6               ; (its return address is thrown away)

        IF      CPM
; RAM pages, after the image
RSPAGE  EQU     (imgend + 255) / 256
DSPAGE  EQU     RSPAGE + 1
LETPAGE EQU     RSPAGE + 2
PROG    EQU     LETPAGE*256 + 256
        ENDIF
imgend:
