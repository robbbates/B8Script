; =============================================================================
;  B8Script interpreter for the Intel 8080
;  Spec: docs/b8script.md (2026-10-09) plus the 2026-11-20 changes:
;        [x stores in a variable, "[ " pushes an anonymous block, any other
;        character after [ is an error, the heap pointer lives at z10+.
;  A port of the Z80 interpreter (z80/b8s-z80.asm); same behaviour, same
;  memory map, same switches.
;
;  Two switches, set in the two EQU lines below:
;    CPM      0 = generic ROM build (CONIN/CONOUT/CONST at fixed addresses)
;             1 = CP/M 2.2 .COM file: loads the file named on the command line
;    CHECKED  0 = no checks (spec: "B8Script checks nothing")
;             1 = stops on stack overrun, Ctrl-C, heap past the limit, a store
;                 outside the program's own space, and a bad character after [
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
;  is the RAM word RSP. Only rpush and rpop (and the checks) touch it; both
;  destroy HL, so each caller makes sure TOS is parked or dead first.
;
;  (asm80 wants the vector number: RST 1 = RST 08h, RST 2 = RST 10h.)
;  A handler ends with RST 10h ("next character") or RST 08h ("drop, then
;  next"), one byte each instead of a three-byte JMP. An RST is a CALL, so the
;  first thing each stub does is POP D to throw the return address away.
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
;  the checked build lets ! and . write) is the single range LETPAGE..heap top.
; -----------------------------------------------------------------------------

        IF      CPM
BDOS    EQU     0005h
        ENDIF
        IFN     CPM
; ---- generic machine: edit these to suit -----------------------------------
CONIN   EQU     0FF00h          ; wait for a key, return it in A
CONOUT  EQU     0FF03h          ; print the character in A
CONST   EQU     0FF06h          ; A = 0 if no key is waiting, else nonzero
EXIT    EQU     0FF09h          ; where to go when the program ends
;   All three console routines must preserve BC, DE and HL.
RSPAGE  EQU     80h             ; 8000h return stack
DSPAGE  EQU     81h             ; 8100h data stack
LETPAGE EQU     82h             ; 8200h letter cells and line buffer
PROG    EQU     8300h           ; where the loader puts the program text
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)
        ENDIF

MSLOOP  EQU     40              ; n? inner loop count for about 1 ms; tune it
                                ; for your clock and CONST (~100 states each)
CAP     EQU     127             ; -n? reads at most this many characters

; letter-page layout (offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     LET+7Ch         ; z10+, the heap pointer
RSP      EQU     LET+34h         ; gap after Z: the return stack pointer;
KEYBUF  EQU     LET+36h         ;   a held-back key;
HLIM    EQU     LET+3Ah         ;   high byte of the heap limit
LBHDR   EQU     LET+7Eh         ; CP/M BDOS 10 header: max, count
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSTOP   EQU     RSPAGE*256+0E0h ; empty return stack: the 32 bytes above it
                                ; take calls made while the data stack is full
DSTOP   EQU     DSPAGE*256+0FEh ; empty data stack

; =============================================================================
;  Page zero (generic ROM) or the start of the .COM file (CP/M)
; =============================================================================
        IF      CPM
        ORG     0100h
        JMP     start
        ENDIF
        IFN     CPM
        ORG     0000h
        LXI     SP,DSTOP        ; 0000h reset: the stack first,
        JMP     start           ;   then the rest of the startup
h_swap: XTHL                    ; 0006h the two-byte handlers fill the gaps
        RST     2               ;   between the vectors
; ---- RST 08h: drop TOS, then next ------------------------------------------
        POP     D               ; 0008h discard the RST's return address
drop_next:
        POP     H               ; new TOS = NOS
        JMP     next0
h_dup:  PUSH    H               ; 000Dh
        RST     2
        DB      0               ; 000Fh spare
; ---- RST 10h: next character ------------------------------------------------
        POP     D               ; 0010h discard the RST's return address
        ENDIF

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
        ; Both stacks are checked once per character, not in every handler.
        ; Each stack lives in one page, so it has overrun exactly when the
        ; pointer's high byte has left that page. Errors are caught one cell
        ; late at most; the page below each stack is a guard band.
        XCHG                    ; DE = TOS (HL is needed for the pointers)
        LXI     H,0
        DAD     SP
        MOV     A,H
        CPI     DSPAGE
        JNZ     e_stack
        LHLD    RSP              ; the return stack: in its page, and not
        MOV     A,L             ;   above its empty position (an underflow
        CPI     RSTOP&0FFh+1    ;   would stay inside the page, in the
        JNC     e_rstack        ;   guard band)
        MOV     A,H
        CPI     RSPAGE
        JNZ     e_rstack
        XCHG                    ; TOS back
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
        JNC     ab40
        ADI     5               ; 3Ah-40h: index 15-21
        JMP     punct
ab40:   SUI     11h             ; A = c - 41h
        CPI     1Ah
        JC      upper           ; 41h-5Ah: A = letter index 0-25
        CPI     20h
        JNC     ab60
        SUI     4               ; 5Bh-60h: index 22-27
        JMP     punct
ab60:   CPI     3Ah
        JC      lower           ; 61h-7Ah: A = 20h-39h (cell +64 bytes)
        CPI     3Eh
        JNC     next0           ; 7Fh-FFh: ignored
        SUI     1Eh             ; 7Bh-7Eh: index 28-31

; Punctuation: HL holds TOS, so it is parked on the stack while the table is
; read, then swapped for the handler's address: XTHL puts TOS back in HL and
; leaves the address on the stack for RET to jump to. The stack is balanced
; again when the handler starts. PTAB never crosses a page (checked in the
; listing), so only L needs adding.
punct:  PUSH    H
        ADD     A
        ADI     PTAB & 0FFh
        MOV     L,A
        MVI     H,PTAB / 256
        MOV     A,M
        INX     H
        MOV     H,M
        MOV     L,A             ; HL = handler
        XTHL
        RET

ctl:    ADI     21h             ; back to c; zero only for NUL
        JNZ     next0
        IF      CPM
        JMP     endprog
        ENDIF
        IFN     CPM
endprog:
        JMP     EXIT            ; the program has ended
        ENDIF

; a-z: push the cell's address (the cell is the variable)
lower:  PUSH    H
        ADD     A
        MOV     L,A
        MVI     H,LETPAGE
        RST     2

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  PUSH    H               ; keep TOS
        ADD     A
        MOV     L,A
        MVI     H,LETPAGE       ; HL -> cell
        MOV     D,B
        MOV     E,C             ; DE = return address
        MOV     C,M
        INX     H
        MOV     B,M             ; IP = the word's body
        CALL    rpush
        POP     H               ; TOS back
        RST     2

; Digits: step back onto the first digit and read the whole number.
digit:  PUSH    H
        DCX     B
        CALL    rdnum
        RST     2

; =============================================================================
;  Dispatch table: one handler per punctuation character, in code order.
;  It sits right after the inner loop so that it can't cross a page (the
;  loop only adds to the low byte of its address).
; =============================================================================
PTAB:   DW      h_store         ; !
        DW      h_str           ; "
        DW      h_num           ; #
        DW      h_print         ; $
        DW      h_swap          ; %
        DW      h_and           ; &
        DW      h_emit          ; '
        DW      h_open          ; (
        DW      h_close         ; )
        DW      h_mul           ; *
        DW      h_add           ; +
        DW      h_cfetch        ; ,
        DW      h_sub           ; -
        DW      h_cstore        ; .
        DW      h_div           ; /
        DW      h_dup           ; :
        DW      drop_next       ; ;
        DW      h_lt            ; <
        DW      h_eq            ; =
        DW      h_gt            ; >
        DW      h_key           ; ?
        DW      h_fetch         ; @
        DW      h_def           ; [
        DW      h_break         ; \
        DW      h_ret           ; ]
        DW      h_xor           ; ^
        DW      h_alloc         ; _
        DW      h_grave         ; `
        DW      h_tor           ; {
        DW      h_or            ; |
        DW      h_fromr         ; }
        DW      h_not           ; ~
PTABEND:

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

; =============================================================================
;  Return stack. rpush pushes DE; rpop pops into HL. RSP is the pointer (a RAM
;  word, growing down). Both destroy HL; rpush also keeps DE, rpop clobbers DE.
; =============================================================================
rpush:  LHLD    RSP
        DCX     H
        MOV     M,D
        DCX     H
        MOV     M,E
        SHLD    RSP
        RET

rpop:   LHLD    RSP
        MOV     E,M
        INX     H
        MOV     D,M
        INX     H
        SHLD    RSP
        XCHG
        RET

; =============================================================================
;  Arithmetic and logic. Effects are ( NOS TOS -- result ).
; =============================================================================
h_add:  POP     D
        DAD     D
        RST     2

; '-' has two jobs: directly before a digit it starts a negative number.
; Otherwise a - b is a + (-b): neg16 and DAD are shorter than a byte-wise SUB/SBB.
h_sub:  LDAX    B
        SUI     '0'
        CPI     10
        JC      negnum
        POP     D
        CALL    neg16
        DAD     D
        RST     2
negnum: PUSH    H
        CALL    rdnum
        CALL    neg16
        RST     2

; neg16: HL = -HL (keeps BC, DE)
neg16:  XRA     A
        SUB     L
        MOV     L,A
        SBB     A
        SUB     H
        MOV     H,A
        RET

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
        RST     2

; '/' ( a b -- q r ): truncates toward zero; r takes a's sign.
; b = 0 gives q = 0, r = a. b = 2 takes a fast shift, as the spec requires.
h_div:  POP     D               ; DE = a, HL = b
        MOV     A,H
        ORA     L
        JNZ     div1
        PUSH    H               ; q = 0
        XCHG                    ; r = a
        RST     2
div1:   DCX     H               ; b = 2 exactly?
        DCX     H
        MOV     A,H
        ORA     L
        INX     H               ; (INX leaves the flags alone)
        INX     H
        JNZ     divg
        ; a / 2: add 1 if a is negative, then shift right arithmetically
        MOV     H,D
        MOV     L,E
        MOV     A,D
        RAL                     ; carry = sign of a
        JNC     div2
        INX     H
div2:   MOV     A,H
        RAL                     ; carry = sign (of a, after the +1)
        MOV     A,H
        RAR                     ; arithmetic shift right, H
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A             ; HL = q
        PUSH    H
        DAD     H               ; 2q
        CALL    neg16
        DAD     D               ; r = a - 2q
        RST     2
divg:   PUSH    B
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
        RST     2

; udiv: unsigned HL / DE (DE <= 8000h). Returns HL = quotient, BC = remainder.
; Uses A, BC; the caller saves the IP. HL holds the dividend and, as its bits
; leave at the top, the quotient bits arrive at the bottom. The loop counter
; lives on the stack, since A is busy with the shifts.
udiv:   LXI     B,0
        MVI     A,16
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

h_and:  POP     D
        MOV     A,H
        ANA     D
        MOV     H,A
        MOV     A,L
        ANA     E
        MOV     L,A
        RST     2

h_or:   POP     D
        MOV     A,H
        ORA     D
        MOV     H,A
        MOV     A,L
        ORA     E
        MOV     L,A
        RST     2

h_xor:  POP     D
        MOV     A,H
        XRA     D
        MOV     H,A
        MOV     A,L
        XRA     E
        MOV     L,A
        RST     2

; ~x is -x - 1: shorter than complementing both bytes.
h_not:  CALL    neg16
        DCX     H
        RST     2

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
        RST     2

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
        RST     2

; =============================================================================
;  Stack
; =============================================================================
        IF      CPM
h_swap: XTHL
        RST     2
        ENDIF

h_tor:  XCHG                    ; '{' TOS to the return stack
        CALL    rpush
        RST     1

h_fromr:PUSH    H               ; '}' return stack to TOS
        CALL    rpop
        RST     2

; =============================================================================
;  Storage
; =============================================================================
h_fetch:MOV     E,M             ; '@'
        INX     H
        MOV     D,M
        XCHG
        RST     2

h_store:POP     D               ; '!' ( n addr -- )
        IF      CHECKED
        INX     H               ; both bytes must be in the program's space
        CALL    chkst
        DCX     H
        ENDIF
        MOV     M,E
        INX     H
        MOV     M,D
        RST     1

h_cfetch:MOV    L,M             ; ','
        MVI     H,0
        RST     2

h_cstore:POP    D               ; '.' ( c addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        MOV     M,E
        RST     1

; '_' ( n -- addr ): the heap pointer moves up by n; TOS is the old pointer.
h_alloc:XCHG
        LHLD    HEAP
        PUSH    H
        DAD     D
        IF      CHECKED
        JC      e_heap          ; a negative count wraps: too big
        LDA     HLIM
        DCR     A
        CMP     H
        JC      e_heap          ; the new top must stay below the limit page
        ENDIF
        SHLD    HEAP
        POP     H
        RST     2

        IF      CHECKED
; chkst: stop unless HL is in the program's own space: from the letter page
; up to the heap limit (the OS, or HEAPLIM), so the interpreter's stacks and
; whatever lies above the limit are safe. Memory above the heap top but
; below the limit is the program's own: Tiny BASIC keeps its lines there.
; Keeps every register.
chkst:  PUSH    PSW
        MOV     A,H
        CPI     LETPAGE
        JC      chk1
        LDA     HLIM
        DCR     A
        CMP     H
chk1:   JC      e_store
        POP     PSW
        RET
        ENDIF

; =============================================================================
;  Flow control
; =============================================================================

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: MOV     A,H
        ORA     L
        JZ      op_f
        MOV     D,B
        MOV     E,C
        CALL    rpush           ; (HL, the flag, is dead here)
        RST     1               ; = POP H, RST 2: the flag is dead, so drop it
op_f:   POP     H
skipnx: CALL    skip
        RST     2

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on.
h_close:MOV     A,H
        ORA     L
        JZ      rdrop
        IF      CHECKED
        CALL    chkbrk          ; Ctrl-C is checked at every loop-back
        ENDIF
        LHLD    RSP              ; peek the block start
        MOV     C,M
        INX     H
        MOV     B,M
        POP     H
        RST     2
rdrop:  CALL    rpop            ; (HL, the flag, is dead: NOS is next)
        RST     1

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
h_break:MOV     A,H
        ORA     L
        JNZ     brk1
        RST     1
brk1:   CALL    skip
        CPI     ')'
        JZ      rdrop
        POP     H               ; and fall into ']'

; ']' returns: pop an address and jump to it.
h_ret:  PUSH    H
        CALL    rpop
        MOV     B,H
        MOV     C,L
        POP     H
        IF      CHECKED
        CALL    chkbrk          ; ... and at every word return
        ENDIF
        RST     2

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
h_def:  LDAX    B
        INX     B
        MOV     E,A
        ANI     0DFh            ; fold case
        SUI     'A'
        CPI     26
        JNC     def2            ; not a letter
        MOV     A,E
        SUI     'A'             ; 0-25 or 32-57: lowercase lands 64 bytes up
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
        CPI     ' '
        JNZ     e_brack         ; anything but a letter or a space
        ENDIF
        PUSH    H               ; an anonymous block: push its address
        MOV     H,B
        MOV     L,C
        JMP     skipnx

; skip: read past text to the closer at this level, and return it in A.
; Brackets of both kinds count together; strings are stepped over whole. A
; NUL first ends the program (for '\' with no closer; anything else that runs
; into the NUL had unbalanced brackets anyway). D counts the open levels,
; starting at 1 for the one we are in.
skip:   MVI     D,1
sk1:    LDAX    B
        INX     B
        ORA     A
        JZ      endprog
        CPI     22h
        CZ      skipstr         ; leaves A = 22h, which matches nothing below
        CPI     '('
        JZ      sk3
        CPI     '['
        JZ      sk3
        CPI     ')'
        JZ      sk4
        CPI     ']'
        JNZ     sk1
sk4:    DCR     D
        RZ                      ; the closer at this level
        JMP     sk1
sk3:    INR     D               ; an opener: one deeper (the DCR below makes
        INR     D               ;   it +1 net, and can't reach zero)
        JMP     sk4

; skipstr: IP is inside a string; step past its closing quote. '>' escapes
; the next character, so '>"' does not end it.
ss0:    INX     B
skipstr:LDAX    B
        INX     B
        CPI     '>'
        JZ      ss0
        CPI     22h
        JNZ     skipstr
        RET

; =============================================================================
;  Console
; =============================================================================

; 22h pushes the address of the text after it and skips the string.
h_str:  PUSH    H
        MOV     H,B
        MOV     L,C
        CALL    skipstr
        RST     2

; '$' prints the string at TOS, decoding escapes: '>' plus a character from
; 40h-7Fh clears its bit 6 (>M is CR, >` is space); plus anything lower gives
; that character itself.
h_print:MOV     A,M
        INX     H
        CPI     22h
        JZ      prdone
        CPI     '>'
        JNZ     pr1
        MOV     A,M
        INX     H
        CPI     40h
        JC      pr1
        ANI     0BFh
pr1:    CALL    putc
        JMP     h_print
prdone: RST     1

h_emit: MOV     A,L             ; "'"
        CALL    putc
        RST     1

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  MOV     A,H
        ORA     A
        JP      num1
        MVI     A,'-'
        CALL    putc
        CALL    neg16
num1:   PUSH    B
        CALL    pdec
        POP     B
        RST     1
; pdec: print HL unsigned, by recursion on HL / 10 (the stack holds digits)
pdec:   LXI     D,10
        CALL    udiv            ; HL = HL / 10, BC = digit
        MOV     A,C
        PUSH    PSW
        MOV     A,H
        ORA     L
        CNZ     pdec
        POP     PSW
        ADI     '0'
        JMP     putc

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters (capped at CAP) with echo
h_key:  MOV     A,H
        ORA     A
        JM      line
        ORA     L
        JNZ     kt1
kw:
        IF      (1-CPM)*(1-CHECKED)
        CALL    CONIN           ; 0?: wait (the generic console can block)
        ENDIF
        IF      1-(1-CPM)*(1-CHECKED)
        CALL    getk            ; 0?: wait
        JZ      kw
        ENDIF
kt3:    MOV     L,A
        MVI     H,0
        RST     2
kt1:    LXI     D,MSLOOP        ; one millisecond, roughly
kt2:    CALL    getk
        JNZ     kt3
        DCX     D
        MOV     A,D
        ORA     E
        JNZ     kt2
        DCX     H
        MOV     A,H
        ORA     L
        JNZ     kt1
        RST     2             ; time ran out: HL is already 0

line:   CALL    neg16           ; HL = the count
        MOV     A,H
        ORA     A
        JNZ     ln0
        MOV     A,L
        CPI     CAP+1
        JC      ln1
ln0:    MVI     A,CAP
ln1:
        IF      CPM
        ; CP/M: BDOS 10 does the editing (the spec allows the platform's
        ; own line editor). It doesn't store the CR, so it is added here.
        STA     LBHDR
        PUSH    B
        LXI     D,LBHDR
        MVI     C,10
        CALL    BDOS
        POP     B
        LXI     H,LBHDR+1
        MOV     A,M             ; count (0-127)
        INX     H               ; HL = LINEBUF, whose low byte is 80h:
        PUSH    H
        ADD     L               ;   adding the count to L can't carry
        MOV     L,A
        MVI     M,13
        POP     H
        RST     2
        ENDIF
        IFN     CPM
        ; Generic: Backspace and DEL erase, CR ends (stored, not echoed),
        ; other control keys are ignored, and a full line takes only those.
        PUSH    B
        MOV     C,A             ; C = max
        MVI     B,0             ; B = length
        LXI     H,LINEBUF
        ENDIF
ln2:
        IF      (1-CPM)*(1-CHECKED)
        CALL    CONIN           ; (the generic console can block)
        ENDIF
        IF      (1-CPM)*CHECKED
        CALL    getk
        JZ      ln2
        ENDIF
        IFN     CPM
        CPI     13
        JZ      ln5
        CPI     8
        JZ      ln4
        CPI     7Fh
        JZ      ln4
        CPI     ' '
        JC      ln2
        MOV     E,A
        MOV     A,B
        CMP     C
        JNC     ln2             ; full
        MOV     M,E
        INX     H
        INR     B
        MOV     A,E
ln3:    CALL    putc
        JMP     ln2
ln4:    MOV     A,B
        ORA     A
        JZ      ln2
        DCR     B
        DCX     H
        MVI     A,8
        CALL    putc
        MVI     A,' '
        CALL    putc
        MVI     A,8
        JMP     ln3
ln5:    MVI     M,13
        POP     B
        LXI     H,LINEBUF
        RST     2
        ENDIF

; =============================================================================
;  Machine code: the grave
; =============================================================================
; '`' plus a hex digit loads bytes: ( addr -- addr' ). Pairs of hex digits
; are stored from addr until a non-hex character; then a RET (C9h) is
; written and its address is left. An odd last digit is consumed and dropped.
; '`' plus anything else calls the machine code at TOS: ( addr -- ). The
; code is entered by CALL with the data stack above the return address; it
; must keep BC, and on return the top cell becomes the new TOS.
h_grave:LDAX    B
        CALL    hexval
        JC      exec
hx1:    LDAX    B
        CALL    hexval
        JC      hx2
        INX     B
        ADD     A
        ADD     A
        ADD     A
        ADD     A
        MOV     D,A
        LDAX    B
        CALL    hexval
        JC      hx2             ; odd digit: already consumed, dropped
        INX     B
        ORA     D
        IF      CHECKED
        CALL    chkst
        ENDIF
        MOV     M,A
        INX     H
        JMP     hx1
hx2:
        IF      CHECKED
        CALL    chkst
        ENDIF
        MVI     M,0C9h
        RST     2

exec:   CALL    exjmp           ; the code returns here, with its top cell on
        POP     H               ;   the stack: that becomes the new TOS
        RST     2
exjmp:  PCHL

; hexval: A = a character; returns its value 0-15 with carry clear, or
; carry set if it isn't a hex digit (0-9, A-F, a-f).
hexval: SUI     '0'
        CPI     10
        CMC
        RNC
        ANI     0DFh
        SUI     11h
        CPI     6
        CMC
        RC
        ADI     10
        RET

; =============================================================================
;  Console layer: getk returns a waiting key in A (zero flag clear), or
;  A = 0 with the zero flag set when none is waiting. putc prints A.
;  Both keep BC, DE and HL.
; =============================================================================
getk:
        IF      CHECKED
        LDA     KEYBUF          ; a key held back by the break check
        ORA     A
        JZ      gk1
        PUSH    PSW
        XRA     A
        STA     KEYBUF
        POP     PSW
        RET
gk1:
        ENDIF
        IF      CPM
        MVI     A,0FFh          ; BDOS 6 with E = FFh: a key, or 0
        JMP     putc            ; (which ends with ORA A, for the zero flag)
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
        ORA     A
        RET
        ENDIF
        IFN     CPM
        CALL    CONST
        ORA     A
        RZ
        CALL    CONIN
        ORA     A
        RET
putc    EQU     CONOUT
        ENDIF

; =============================================================================
;  Checked build: break key and error reports
; =============================================================================
        IF      CHECKED
; chkbrk: a waiting key is read now; Ctrl-C stops the program, anything
; else is held for the next '?'.
chkbrk: LDA     KEYBUF
        ORA     A
        RNZ                     ; one key is already held
        CALL    getk
        RZ
        CPI     3
        JZ      e_break
        STA     KEYBUF
        RET

e_stack:CALL    error
        DB      "stac", 'k'+80h
e_rstack:CALL   error
        DB      "retur", 'n'+80h
e_break:CALL    error
        DB      "brea", 'k'+80h
e_heap: CALL    error
        DB      "hea", 'p'+80h
e_store:CALL    error
        DB      "stor", 'e'+80h
e_brack:CALL    error
        DB      '['+80h
; error: print CR LF, the word after the CALL (last character has bit 7
; set), " at " and the offset of the reading position in the program.
error:  POP     D               ; DE -> the word
        LXI     SP,DSTOP        ; the stacks may be wrecked: start clean
        LXI     H,er1
        CALL    prs
        XCHG
        CALL    prs             ; the word
        LXI     H,er2
        CALL    prs
        LXI     H,(0-PROG-1)&0FFFFh
        DAD     B               ; IP - (PROG+1): the character just read
        CALL    pdec
        JMP     endprog
; prs: print the string at HL, whose last character has bit 7 set
prs:    MOV     A,M
        INX     H
        PUSH    PSW
        ANI     7Fh
        CALL    putc
        POP     PSW
        RAL
        JNC     prs
        RET
er1:    DB      13, 10+80h
er2:    DB      " at", ' '+80h
        ENDIF


; =============================================================================
;  Startup
; =============================================================================
start:
        IF      CPM
        LXI     SP,DSTOP
        ; CP/M: the RAM pages follow the image; the heap may grow to the BDOS
        LXI     H,stubs         ; RST 08h and RST 10h stubs into page zero
        LXI     D,0008h
        MVI     B,12
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
        INX     H
        SHLD    HEAP
        LDA     0007h           ; the BDOS page is the heap limit
        STA     HLIM
        ENDIF
        IFN     CPM
        LXI     H,PROG          ; the heap starts after the program's NUL
fnul:   MOV     A,M
        INX     H
        ORA     A
        JNZ     fnul
        SHLD    HEAP
        ENDIF
        IF      (1-CPM)*CHECKED
        MVI     A,HEAPLIM
        STA     HLIM
        ENDIF
        LXI     H,RSTOP
        SHLD    RSP
        IF      CHECKED
        XRA     A
        STA     KEYBUF
        ENDIF
        LXI     B,PROG
        JMP     next0

        IF      CPM
stubs:  POP     D               ; 0008h: drop, then next
        POP     H
        JMP     next0
h_dup   EQU     000Dh
        PUSH    H               ; 000Dh: dup
        RST     2
        DB      0
        POP     D               ; 0010h: next
        JMP     next0
endprog EQU     0               ; warm boot
drop_next EQU   0009h
; RAM pages, after the image
RSPAGE  EQU     (imgend + 255) / 256
DSPAGE  EQU     RSPAGE + 1
LETPAGE EQU     RSPAGE + 2
PROG    EQU     LETPAGE*256 + 256
        ENDIF
imgend:
