; =============================================================================
;  B8Script interpreter for the Intel 8080
;  Spec: docs/b8script.md (2026-11-24).
;  Design follows the Z80 interpreter (z80/b8s-z80.asm), with 8080 opcodes
;  only.
;
;  Three switches, set in the EQU lines below:
;    CPM      0 = generic ROM build (KEY/CONOUT at fixed addresses)
;             1 = CP/M 2.2 .COM file: loads the file named on the command line
;    CHECKED  0 = no checks (spec: the programmer is responsible)
;             1 = starts with every variable at 0 and every word undefined,
;                 and stops on every error in the spec's table (and Ctrl-C)
;                 with a four-line report: the letter and the place as line
;                 and column, the text there, and both stacks. See `error`.
;    ANSI     what the console escapes of '$' (/{ /} /| /` /~) do:
;             1 = send ANSI (VT100) sequences through CONOUT
;             0 = call the machine's own routines CONCLS, CONEOL, CONCUR and
;                 CONAT (see the equates). The CP/M builds always send ANSI.
;
;  In every build Ctrl-C stops a running program (an unchecked build stops
;  without a word): see the console layer for the rules, the held key and
;  the break-off cell.
;
;  Assembler: asm80 (https://maly.github.io/asm80-node/), I8080 mode.
; =============================================================================

CPM     EQU     0               ; 1 = CP/M .COM build
CHECKED EQU     1               ; 1 = checked build
ANSI    EQU     1               ; 1 = the console escapes send ANSI sequences
ANS     EQU     ANSI+CPM-ANSI*CPM ; (CP/M: always ANSI)

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
;    DSPAGE   data stack, 127 cells (the top four bytes of the page are spare,
;             so a full stack runs two bytes into the page below)
;    LETPAGE  letter cells: A..Z at +00h..+33h, a..z at +40h..+73h (so a word
;             cell is always 64 bytes below its variable), the heap pointer at
;             +7Ch, interpreter variables in the gaps, and the -n? line buffer
;             at +80h..+FFh
;    PROG     the program text, NUL-terminated; the heap starts after the NUL
;
;  The stacks sit below the letter page, so "the program's own space" (what
;  the checked build lets ! and . write) is the single range from the letter
;  page up to the heap limit. Each stack has a guard band: the data stack can
;  overrun by a cell or two (and the calls made while it is full, the error
;  report's included) into the top 32 bytes of the return-stack page, which
;  are never used, and the return stack by one entry into the page below it.
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
        ENDIF
        IF      1-ANS
; With ANSI = 0 the console escapes call these. All four must keep BC;
; CONCLS, CONEOL and CONCUR also DE and HL.
CONCLS  EQU     0FF0Ch          ; /{  clear the screen, the cursor to the top left
CONEOL  EQU     0FF0Fh          ; /}  clear from the cursor to the end of the line
CONCUR  EQU     0FF12h          ; /| and /`  show the cursor if A is not 0, hide
                                ;     it if A = 0
CONAT   EQU     0FF15h          ; /~  the cursor to row HL, column DE, both
                                ;     counted from 0. May change A, DE and HL
        ENDIF
        IFN     CPM
RSPAGE  EQU     80h             ; 8000h return stack
DSPAGE  EQU     81h             ; 8100h data stack
LETPAGE EQU     82h             ; 8200h letter cells and line buffer
PROG    EQU     8300h           ; where the loader puts the program text
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)
BASE    EQU     0000h           ; where the image starts
        ENDIF

MSLOOP  EQU     40              ; n? inner loop count for about 1 ms (1-255;
                                ; the wait for a second Ctrl-C uses it too):
                                ; each pass calls getk once, so tune it for
                                ; your clock and your KEY routine

; letter-page layout (offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     LET+7Ch         ; the heap pointer
RSP     EQU     LET+34h         ; gap after Z: the return stack pointer;
BRKCNT  EQU     LET+36h         ;   the break check's countdown;
NPEND   EQU     LET+38h         ;   minus the address of the program's end
                                ;   (the heap's first byte), for the checked '_';
PSAVE   EQU     LET+3Ah         ;   the checked build: the address '$' prints
                                ;   from, for a report
KEYBUF  EQU     LET+7Ah         ; gap after z: a key read by the break check and
                                ;   held for the next '?' (0: none);
BRKOFF  EQU     LET+7Bh         ;   the break-off cell: a program that stores a
                                ;   non-zero byte here gets Ctrl-C as a key
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSTOP   EQU     RSPAGE*256+0E0h ; empty return stack: the 32 bytes above it
                                ; take calls made while the data stack is full
DSTOP   EQU     DSPAGE*256+0FCh ; empty data stack. The four bytes above it
                                ; are spare: a character can pop two cells
                                ; too many before the checked build sees it,
                                ; and the next call must not land on the
                                ; letter cells.

; =============================================================================
;  The first 49 bytes: the entry, then the RST routines, with small handlers
;  and routines filling the gaps between them. Generic: this IS page zero.
;  CP/M: it is the start of the .COM file, and 0108h-0133h is also copied to
;  page zero (see the header).
; =============================================================================
        ORG     BASE
        IF      1-(1-CPM)*CHECKED
        LXI     SP,DSTOP        ; 00  reset, or the start of the .COM file
        ENDIF
        JMP     start           ; In the checked generic build this is at 0000h
                                ;   (and `start` sets SP): its first byte, C3h,
                                ;   is what an undefined word runs into, as
                                ;   CP/M's own JMP at 0000h is in a .COM: e_hi.
        IF      (1-CPM)*CHECKED
        DB      0,0,0           ; 03  spare
        ENDIF
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
        IF      CHECKED
        JZ      next0           ; 7Fh, DEL: ignored
        JNC     e_hi            ; 80h-FFh: reserved
        ENDIF
        IF      1-CHECKED
        JNC     next0           ; 7Fh-FFh: ignored
        ENDIF
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

; '_' ( n -- addr ): the heap pointer moves by n, a signed count (the add is
; the same either way); TOS is the old pointer.
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
;
; The break key is looked at here, so at every word call and loop-back (and
; block entry and '{'), but only one time in 256: BRKCNT counts them. Reading
; the keyboard can be slow (it is a BDOS call under CP/M).
rpushd: LHLD    RSP
        DCX     H
        MOV     M,D
        DCX     H
        MOV     M,E
        SHLD    RSP
        LXI     H,BRKCNT
        DCR     M
        POP     H               ; (keeps the flags)
        CZ      pollk
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
        MOV     M,A
        INX     H
        CALL    hexc
        JC      hx1
hx2:    MVI     M,0C9h          ; (never range-checked: the spec says so)
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
skipnx:
        IF      CHECKED
        DCX     B               ; back onto the letter, so that skip finds its
        ENDIF                   ;   opener, the '[', just before where it starts
skipo:  CALL    skip
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
        JZ      skipo
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
; of a. Dividing by zero returns two cells of no meaning; the checked build
; stops on it.
h_div:
        IF      CHECKED
        MOV     A,H
        ORA     L
        JZ      e_zero
        ENDIF
        POP     D               ; DE = a, HL = b
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

; (The checked build tests the address before it takes the value off the
; stack, so that an error report shows both.)
h_store:                        ; '!' ( n addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        POP     D
        MOV     M,E
        INX     H
        MOV     M,D
        RST     3

h_cstore:                       ; '.' ( c addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        POP     D
        MOV     M,E
        RST     3

; ---- console ---------------------------------------------------------------

; 22h pushes the address of the text after it and skips the string.
h_str:  PUSH    H
        MOV     H,B
        MOV     L,C
        CALL    skipstr
        IF      CHECKED
        ORA     A               ; 0: the text ran out before the closing quote
        JZ      e_quote
        ENDIF
        RST     6

; '$' prints the string at TOS, decoding escapes: '/' plus a character from
; 60h to 7Eh is one of the escapes at pesc; '/' plus any other character
; clears that character's bit 6 (/M is CR, /? is DEL's '?'; '/' and '"' have
; no bit 6, so // and /" give themselves).
        IF      1-CHECKED
h_print:MOV     A,M
        INX     H
        CPI     22h
        JZ      h_drop
        CPI     '/'
        JNZ     pr1
        MOV     A,M
        INX     H
        CPI     60h
        JC      pr0
        CPI     7Fh
        JC      pesc
pr0:    ANI     0BFh
pr1:    RST     5
        JMP     h_print
PRLOOP  EQU     h_print         ; (where the escapes go back to)
PRAGAIN EQU     h_print         ; (and where /~ goes back to)
        ENDIF
        IF      CHECKED
; (The checked build has the loop as a routine, prstr, which the error
; report uses too. The address is kept meanwhile, for a report: it shows
; the stack as it was before the '$'. /~ comes back to hp1.)
h_print:SHLD    PSAVE
hp1:    CALL    prstr
        RST     3
        ENDIF

h_emit: MOV     A,L             ; "'"
        RST     5
h_drop: RST     3               ; ';' is this one byte

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  PUSH    B
        CALL    psgn
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

        ; Backspace takes the last character back (and is echoed as
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

; psgn: print HL as a signed number. Uses BC.
psgn:   MOV     A,H
        ORA     A
        JP      pdec
        MVI     A,'-'
        RST     5
        RST     4
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

;-----------------------------------------------------------------------------
; pesc: the escapes of '$'. A = the character after the '/', 60h to 7Eh, and
; HL points past it. Each goes back into the loop that prints the string
; (PRLOOP), but /~ has the stack to see to, and goes back by PRAGAIN.
;    /a-/z   print the variable, as '#' does
;    /{      clear the screen, the cursor to the top left
;    /}      clear from the cursor to the end of the line
;    /|  /`  show the cursor, hide it
;    /~      ( row col -- ) the cursor to that row and column, from 0
pesc:   CPI     7Eh
        JZ      pat
        LXI     D,PRLOOP        ; the others return into the loop
        PUSH    D
        SUI     7Bh             ; { 0, | 1, } 2, and no borrow
        JNC     pcon
        ADI     1Ah             ; a-z: 0-25, and a carry; `: FFh, and none
        JNC     phide
        ADD     A               ; the variable's cell
        ADI     40h
        PUSH    H
        PUSH    B
        MOV     L,A
        MVI     H,LETPAGE
        MOV     A,M
        INR     L
        MOV     H,M
        MOV     L,A
        CALL    psgn
        POP     B
        POP     H
        RET

; /~ ( row col addr -- ): the two cells under the string's address go. In
; the checked build '$' is the routine prstr: its own return address goes
; first, and hp1 calls it again afterwards; and chkstk looks first that
; there is a column at least (with less, it is s). With a column but no row
; it is s after the '$', as for any other character: the spare bytes above
; the stack take what is written meanwhile.
pat:
        IF      CHECKED
        POP     D
        CALL    chkstk
        ENDIF
        POP     D               ; DE = the column
        XTHL                    ; HL = the row; the text pointer is kept
        IF      1-ANS
        CALL    CONAT
        POP     H
        JMP     PRAGAIN

; With ANSI = 0 the machine's routines do the rest.
phide:  XRA     A               ; /`  (A = 0: hide)
        JMP     CONCUR
pcon:   JZ      CONCLS          ; /{
        CPI     2
        JZ      CONEOL          ; /}
        JMP     CONCUR          ; /|  (A = 1: show)
        ENDIF
        IF      ANS
        PUSH    B               ; (pdec uses BC)
        PUSH    D
        CALL    csi             ; ESC [ row+1 ; col+1 H (ANSI counts from 1)
        INX     H
        CALL    pdec
        MVI     A,';'
        RST     5
        POP     H
        INX     H
        CALL    pdec
        MVI     A,'H'
        RST     5
        POP     B
        POP     H
        JMP     PRAGAIN

; With ANSI = 1 they are sequences. The carry is clear on the way in.
pcon:   DCR     A
        JZ      pshow           ; /|
        MVI     A,'K'
        JP      csia            ; /}  ESC [ K
        MVI     A,'H'           ; /{  ESC [ H ESC [ J
        CALL    csia
        MVI     A,'J'
        JMP     csia
pshow:  MVI     E,'h'           ; /|  ESC [ ? 2 5 h
        DB      0DAh            ; (JC nn: with no carry it steps over two bytes)
phide:  MVI     E,'l'           ; /`  ESC [ ? 2 5 l
        MVI     A,'?'
        CALL    csia
        MVI     A,'2'
        RST     5
        MVI     A,'5'
        RST     5
        MOV     A,E
        RST     5
        RET

; csia: ESC [ and then A. csi: ESC [. Both keep all but A.
csia:   PUSH    PSW
        CALL    csi
        POP     PSW
        RST     5
        RET
csi:    MVI     A,27
        RST     5
        MVI     A,'['
        RST     5
        RET
        ENDIF

; skip: read past text to the closer at this level, and return A = 0 if it
; was ')' and 2 if it was ']'. Brackets of both kinds count together;
; strings are stepped over whole. A NUL first ends the program (for '\' with
; no closer; anything else that runs into the NUL had unbalanced brackets
; anyway). D counts the open levels, starting at 1 for the one we are in:
; skip sets it to 0 and falls through the INR that an opener comes back to.
;
; The checked build also looks at the character the skip was started by,
; which is always the one just before where it starts: '(' must end at ')',
; '[' at ']', and neither may run into the NUL (N); a string with no closing
; quote counts as running into it. '\' takes either closer. The place where
; the skip started is kept on the stack, for the report.
skip:
        IF      CHECKED
        PUSH    B
        DCX     B
        LDAX    B
        INX     B
        MOV     E,A             ; E = the opener: ( [ or \
        ENDIF
        MVI     D,0
sk3:    INR     D               ; an opener: one deeper
sk1:    LDAX    B
        IF      1-CHECKED
        INX     B
        ORA     A
        JZ      endprog
        ENDIF
        IF      CHECKED
        ORA     A
        JZ      sk6             ; (the IP stays on the NUL)
        INX     B
        ENDIF
        CPI     22h
        CZ      skipstr         ; leaves A = 22h, which matches nothing below
        SUI     '('             ;   (or 0, and then the NUL is read next)
        JZ      sk3
        DCR     A               ; ')'
        JZ      sk4
        SUI     '['-')'
        JZ      sk3
        CPI     ']'-'['
        JNZ     sk1
sk4:    DCR     D
        IF      1-CHECKED
        RZ                      ; the closer at this level
        JMP     sk1
        ENDIF
        IF      CHECKED
        JNZ     sk1
        MOV     D,A             ; the closer at this level: 0 or 2. Bit 1 of the
        XRA     E               ;   opener is 0 for '(' and 1 for '[', and only
        ANI     6               ;   '\' has bit 2: so this is 2 for the wrong
        CPI     2               ;   closer, and only then
        MOV     A,D
        POP     D               ; (where the skip started)
        RNZ
        MOV     B,D             ; N. The place is the opener
        MOV     C,E
        JMP     sk7
sk6:    MOV     A,E             ; the text ran out:
        ANI     4
        JNZ     endprog         ;   '\' with no closer ends the program
        POP     B
sk7:    MVI     A,'N'
        JMP     errp            ; (errp drops skip's return address)
        ENDIF

; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it. Leaves A = 22h.
        IF      1-CHECKED
ss0:    INX     B
skipstr:LDAX    B
        INX     B
        CPI     '/'
        JZ      ss0
        CPI     22h
        JNZ     skipstr
        RET
        ENDIF
        IF      CHECKED
; The checked build never steps over a NUL: if the text runs out first it
; returns A = 0 with the IP on the NUL.
skipstr:LDAX    B
        ORA     A
        RZ
        INX     B
        CPI     22h
        RZ
        CPI     '/'
        JNZ     skipstr
        LDAX    B               ; the escaped character
        ORA     A
        RZ
        INX     B
        JMP     skipstr
        ENDIF

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
;  Console layer. rawk is the host's key routine: a waiting key in A (zero
;  flag clear), or A = 0 with the zero flag set when none is waiting. putc
;  (RST 5) prints A. Both keep BC, DE and HL. In the generic build they are
;  the host's KEY and CONOUT routines themselves.
;
;  A running program reads the keyboard only through getk and pollk, which
;  between them give the break key its rules:
;    - Ctrl-C stops the program;
;    - any other key that the break check reads is held in KEYBUF for the
;      next '?', and a newer one takes its place;
;    - '?' (getk) takes the held key first;
;    - a program that has stored a non-zero byte at BRKOFF gets Ctrl-C as a
;      key like any other, but two of them within about 250 ms still stop it.
;  Both are called straight from a handler, never from a routine under one:
;  the checked build's report counts on finding one return address above the
;  data stack, and TOS in HL.
; =============================================================================
        IFN     CPM
rawk    EQU     KEY
        ENDIF
; pollk: the break check (see rpushd).
pollk:  CALL    rawk
        RZ                      ; no key
        STA     KEYBUF          ; held for the next '?'
pk1:    CPI     3               ; (getk joins here)
        RNZ
; ctlc: Ctrl-C has been read. If the break key is on, that is the end. If
; the program has turned it off, wait about 250 ms for one more key: a
; second Ctrl-C is the end too; any other key is held (the newest wins),
; and the Ctrl-C goes to the program: returns A = 3, zero flag clear.
ctlc:   LDA     BRKOFF
        ORA     A
        JZ      brk
        PUSH    D
        LXI     D,250*MSLOOP
ct1:    CALL    rawk
        JNZ     ct2
        DCX     D
        MOV     A,D
        ORA     E
        JNZ     ct1
ct2:    POP     D               ; A = the second key, or 0 if none came
        CPI     3
        JZ      brk
        ORA     A
        JZ      ct3
        STA     KEYBUF
ct3:    MVI     A,3
        ORA     A
        RET
; getk: a key for '?', or A = 0 and the zero flag if there is none.
getk:   PUSH    H               ; a held key goes first, and is taken out of
        LXI     H,KEYBUF        ;   the buffer
        MOV     A,M
        MVI     M,0
        POP     H
        ORA     A
        RNZ
        CALL    rawk
        RZ
        JMP     pk1             ; Ctrl-C? If not, that is the key
        IF      1-CHECKED
brk     EQU     endprog         ; the unchecked build stops without a word;
        ENDIF
        IF      CHECKED
brk     EQU     e_break         ;   the checked build reports B
        ENDIF
        IF      CPM
rawk:   MVI     A,0FFh          ; BDOS 6 with E = FFh: a key, or 0
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
; chkhp: HL = the new heap top, DE = the count, the carry is from adding
; it, and the old top is on the stack under the return address. Stop if the
; new top is not below the limit page, or is below the program's end.
chkhp:
        ENDIF
        IF      CHECKED*CPM
        ; With this much room a top that wrapped round can land back in
        ; range, so the add is tested too: growing must not carry, and
        ; releasing must.
        MOV     A,D
        RAR                     ; the carry comes in above the count's sign:
        ADI     40h             ;   bit 7 = carry XOR sign
        ADD     A
        JC      e_heap
        LDA     0007h
        DCR     A
        CMP     H
        JC      e_heap
        ENDIF
        IF      CHECKED*(1-CPM)
        ; (Here the program's space is under 32K, so a top that wrapped
        ; round always falls outside it.)
        MOV     A,H
        CPI     HEAPLIM
        JNC     e_heap
        ENDIF
        IF      CHECKED
        XCHG
        PUSH    H               ; the count
        LHLD    NPEND
        DAD     D               ; carry: at or above the program's end
        POP     H
        XCHG
        RC
e_heap: XCHG                    ; put the count back in TOS for the report,
        POP     D               ;   and drop the return address (errp drops
        MVI     A,'H'           ;   the old top)
        JMP     errp

; chkst: stop unless HL is in the program's own space: from the letter page
; up to the heap limit (the OS, or HEAPLIM), so the interpreter's stacks and
; whatever lies above the limit are safe. Memory above the heap top but
; below the limit is the program's own: Tiny BASIC keeps its lines there.
; It is the page of HL + 1 that is tested, so that one test serves both
; bytes of a cell: the last byte below the limit can't be stored to with '.'.
; Keeps HL and BC. It runs on into its own error entry.
chkst:  INX     H
        MOV     A,H
        DCX     H
        CPI     LETPAGE
        JC      e_store
        ENDIF
        IF      CHECKED*(1-CPM)
        CPI     HEAPLIM
        RC
        ENDIF
        IF      CHECKED*CPM
        MOV     E,A
        LDA     0007h           ; the BDOS page is the heap limit
        DCR     A
        CMP     E
        RNC
        ENDIF
        IF      CHECKED
; Two error entries for errors found inside a routine: the first hides the
; second inside a 3-byte LXI D (the 11h); errp then drops the routine's
; return address.
e_store:MVI     A,'O'           ; a store outside the program's space
        DB      11h
e_break:MVI     A,'B'           ; Ctrl-C (found inside pollk or getk)
        JMP     errp

; prstr: print the string at HL, to its closing quote, decoding '/' (this is
; '$', and the error report's texts). A NUL first is an error: Q.
prstr:  MOV     A,M
        INX     H
        CPI     22h
        RZ
        ORA     A
        JZ      e_dollar
        CPI     '/'
        JNZ     prs1
        MOV     A,M
        INX     H
        CPI     60h
        JC      prs0
        CPI     7Fh
        JC      pesc
prs0:   ANI     0BFh
prs1:   RST     5
        JMP     prstr
PRLOOP  EQU     prstr           ; (where the escapes go back to)
PRAGAIN EQU     hp1             ; (and where /~ goes back to)
e_dollar:POP    D               ; '$' ran into a NUL: drop the return address,
        LHLD    PSAVE           ;   and put the string's address back in TOS
        MVI     A,'Q'
        JMP     error

; pmsg: print the text that follows the CALL, to its closing quote. Keeps HL.
; pnl: the same, on a new line.
pnl:    MVI     A,13
        RST     5
        MVI     A,10
        RST     5
pmsg:   XTHL
        CALL    prstr
        XTHL
        RET

; chkstk: both stacks are checked once per character, not in every handler.
; The data stack is right when SP lies in the 256 bytes below DSTOP: adding
; the constant carries if it is above (cells were popped that were never
; pushed), and leaves a high byte of FFh if it is in range. Errors are found
; a character late at most: the bytes above DSTOP and the guard band below
; the page take what happens meanwhile.
chkstk: XCHG                    ; DE = TOS (HL is needed for the pointers)
        LXI     H,(1-DSTOP)&0FFFFh ; (SP is 2 lower here: the call)
        DAD     SP
        JC      e_under
        INR     H
        JNZ     e_over
        LHLD    RSP             ; the return stack: in its page (or it has
        MOV     A,H             ;   overflowed), and not above its empty
        CPI     RSPAGE          ;   position (an underflow stays inside the
        JNZ     e_rover         ;   page, in the guard band)
        MOV     A,L
        CPI     RSTOP&0FFh+1
        JNC     e_runder
        XCHG                    ; TOS back
        RET
e_runder:LXI    H,RSTOP         ; return stack underflow: it counts as empty
        SHLD    RSP
        MVI     A,'r'
        DB      21h             ; (LXI H hides the next entry; HL is free)
e_rover:MVI     A,'R'           ; return stack overflow
        DB      21h
e_over: MVI     A,'S'           ; data stack overflow
        XCHG                    ; TOS back
        JMP     errp
e_under:LXI     SP,DSTOP        ; data stack underflow: it counts as empty
        MVI     A,'s'
        JMP     error

; e_hi: the inner loop read a reserved byte, 80h-FFh: X. But a word cell that
; was never defined still holds 0000h, and the byte there is a JMP, C3h, in
; every build: if the IP is in page zero, this was a call of an undefined
; word. The call is undone, so the place is the call itself.
e_hi:   INR     B
        DCR     B
        JNZ     e_resv
        PUSH    H
        RST     1
        MOV     B,H
        MOV     C,L
        POP     H
        MVI     A,'U'
        JMP     error
; Error entries. Each loads its letter and then hides the next entry inside
; a 3-byte LXI D (the 11h), so they all fall through to `error`.
e_quote:MOV     B,H             ; an unclosed string: HL is its address, one
        MOV     C,L             ;   past the opening quote, which is the place
        MVI     A,'Q'
        DB      11h
e_resv: MVI     A,'X'           ; a reserved byte outside a string
        DB      11h
e_zero: MVI     A,'Z'           ; dividing by zero
        DB      11h
e_brack:MVI     A,'W'           ; bad character after [
        DB      0FEh            ; (CPI hides the one byte of errp)
; errp: an error found inside a routine: drop its return address first.
errp:   POP     D

; error: the report, then the end. A = the letter, BC = one past the place,
; HL = TOS, and both stacks as the report is to show them:
;
;   Err X @ line,col
;   up to 16 characters of the text from the place
;   Stk n: the top 8 cells at most, bottom to top
;   Rtn n
error:  PUSH    H               ; now the whole data stack is in memory
        MOV     E,A
        CALL    pnl
        DB      "Err ",22h
        MOV     A,E
        RST     5
        CALL    pmsg
        DB      " @ ",22h
        DCX     B               ; BC = the place
        ; The line and column. A place below the program is in the line
        ; buffer: line 0. Otherwise count the LFs from the program's start;
        ; DE = the line's number, HL = where it starts.
        LXI     H,LINEBUF
        LXI     D,0
        MOV     A,B
        CPI     PROG/256
        JC      er3
        INR     H
        MOV     L,E             ; HL = PROG
er1:    INX     D               ; a new line starts at HL
        PUSH    H
er2:    MOV     A,L
        SUB     C
        MOV     A,H
        SBB     B
        JNC     er2x            ; reached the place
        MOV     A,M
        INX     H
        CPI     10
        JNZ     er2
        POP     PSW
        JMP     er1
er2x:   POP     H
er3:    PUSH    B
        PUSH    H
        XCHG
        CALL    pdec            ; the line
        MVI     A,','
        RST     5
        POP     D
        POP     H
        PUSH    H
        CALL    sub16
        INX     H
        CALL    pdec            ; the column
        CALL    pnl
        DB      22h
        POP     H               ; the text, as it is: 16 characters, or fewer
        MVI     B,16            ;   if the line or the program ends first
er4:    MOV     A,M
        INX     H
        ORA     A
        JZ      er5
        CPI     13
        JZ      er5
        CPI     10
        JZ      er5
        ENDIF
        IF      CHECKED*CPM
        CPI     1Ah             ; (the ^Z that pads a file's last record ends
        JZ      er5             ;   the text too: some terminals clear the
        ENDIF                   ;   screen on it)
        IF      CHECKED
        RST     5
        DCR     B
        JNZ     er4
er5:    CALL    pnl
        DB      "Stk ",22h
        LXI     H,(2-DSTOP)&0FFFFh ; SP - (DSTOP-2) is minus twice the depth
        DAD     SP              ;   (the cell at DSTOP-2 was pushed with the
        RST     4               ;   first value and holds nothing)
        MOV     A,H
        CALL    phal2           ; the depth
        MVI     A,':'
        RST     5
        MOV     A,C
        CPI     9
        JC      er6
        CALL    pmsg
        DB      " ...",22h
        MVI     C,8
er6:    MVI     H,0             ; C = the number of cells to show
        MOV     L,C
        DAD     H
        DAD     SP              ; HL -> just above the deepest of them
        INR     C
er7:    DCR     C
        JZ      er8
        DCX     H
        MOV     D,M
        DCX     H
        MOV     E,M
        PUSH    H
        PUSH    B
        MVI     A,' '
        RST     5
        XCHG
        CALL    psgn
        POP     B
        POP     H
        JMP     er7
er8:    CALL    pnl
        DB      "Rtn ",22h
        LHLD    RSP
        XCHG
        LXI     H,RSTOP
        CALL    phalf
        CALL    pnl
        DB      22h
        JMP     endprog
; phalf: print half of HL - DE, and leave it in BC
phalf:  CALL    sub16
phal2:  ORA     A               ; (A = H; this clears the carry)
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A
        PUSH    H
        CALL    pdec
        POP     B
        RET
; sub16: HL = HL - DE. Leaves A = H.
sub16:  MOV     A,L
        SUB     E
        MOV     L,A
        MOV     A,H
        SBB     D
        MOV     H,A
        RET
        ENDIF

; =============================================================================
;  Startup
; =============================================================================
start:
        IF      (1-CPM)*CHECKED
        LXI     SP,DSTOP
        ENDIF
        IF      CHECKED
        ; Clear the lower half of the letter page: every variable starts at
        ; 0, every word cell holds 0000h, the address an undefined word is
        ; caught at (see e_hi), and no key is held back.
        LXI     H,LET
        XRA     A
ini1:   MOV     M,A
        INR     L
        JP      ini1            ; +00h to +7Fh
        ENDIF
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
        IF      CHECKED
        RST     4               ; minus the heap's first address: '_' may not
        SHLD    NPEND           ;   release below it
        ENDIF
        LXI     H,RSTOP         ; the return stack is empty
        SHLD    RSP
        IF      (1-CHECKED)*(1-CPM)
        MOV     H,A             ; (A = 0, from the search for the NUL) no key
        MOV     L,A             ;   is held, and the break key is on (the
        ENDIF                   ;   checked build has cleared these)
        IF      (1-CHECKED)*CPM
        LXI     H,0
        ENDIF
        IF      1-CHECKED
        SHLD    KEYBUF
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
