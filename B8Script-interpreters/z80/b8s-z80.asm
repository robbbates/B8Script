; =============================================================================
;  B8Script interpreter for the Z80
;  Spec: docs/b8script.md (2026-10-09) plus the 2026-11-20 changes:
;        [x stores in a variable, "[ " pushes an anonymous block, any other
;        character after [ is an error, the heap pointer lives at z10+.
;        The string escape is '/' (it was '>').
;
;  Two switches, set in the two EQU lines below:
;    CPM      0 = generic ROM build (KEY/CONOUT at fixed addresses)
;             1 = CP/M 2.2 .COM file: loads the file named on the command line
;    CHECKED  0 = no checks (spec: "B8Script checks nothing")
;             1 = stops on stack overrun, Ctrl-C, heap past the limit, a store
;                 outside the program's own space, and a bad character after [,
;                 printing a letter and the place, like  S @ 245
;
;  Assembler: asm80 (https://maly.github.io/asm80-node/), Z80 mode.
; =============================================================================

CPM     EQU     0               ; 1 = CP/M .COM build
CHECKED EQU     0               ; 1 = checked build

; -----------------------------------------------------------------------------
;  Register use, everywhere in the interpreter
;
;    BC   IP: the address of the next program character to read
;    HL   TOS: the top data-stack cell is kept here, not in memory
;    SP   the data stack: (SP) is NOS, the cell under TOS. The data stack is
;         the Z80's own stack, which is what the spec's machine-code contract
;         needs ("the data cells above the return address").
;    HL'  return-stack pointer (the alternate HL). Entries are 2 bytes; the
;         stack grows down. Only rpush and rpop (and the checks) touch it.
;    A DE scratch. Every handler is entered with HL = TOS and may use A, DE.
;
;  A handler ends with RST 10h ("next character") or RST 08h ("drop, then
;  next"), one byte each instead of a three-byte JP. An RST is a CALL, so the
;  first thing each stub does is POP DE to throw the return address away.
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
        ENDIF
        IFN     CPM
; ---- generic machine: edit these to suit -----------------------------------
KEY     EQU     0FF06h          ; a waiting key in A, or A = 0 if none is
                                ;   waiting. The zero flag must match A
                                ;   (end the routine with OR A / RET).
CONOUT  EQU     0FF03h          ; print the character in A
EXIT    EQU     0FF09h          ; where to go when the program ends
;   KEY and CONOUT must preserve BC, DE, HL and HL'.
RSPAGE  EQU     80h             ; 8000h return stack
DSPAGE  EQU     81h             ; 8100h data stack
LETPAGE EQU     82h             ; 8200h letter cells and line buffer
PROG    EQU     8300h           ; where the loader puts the program text
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)
        ENDIF

MSLOOP  EQU     40              ; n? inner loop count for about 1 ms: each pass
                                ; calls getk once, so tune it for your clock
                                ; and your CONST routine

; letter-page layout (offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     LET+7Ch         ; z10+, the heap pointer
RSAVE   EQU     LET+34h         ; gap after Z: return stack pointer, saved
KEYBUF  EQU     LET+36h         ;   around machine code; a held-back key;
SPTMP   EQU     LET+38h         ;   scratch for the SP check;
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
        JP      start
        ENDIF
        IFN     CPM
        ORG     0000h
        JP      start           ; 0000h reset
endprog:
        JP      EXIT            ; 0003h the program has ended
h_dup:  PUSH    HL              ; 0006h ':' (two-byte handlers fill the gaps)
        RST     10h
; ---- RST 08h: drop TOS, then next ------------------------------------------
        POP     DE              ; 0008h discard the RST's return address
drop_next:
        POP     HL              ; new TOS = NOS
        JR      next0
h_swap: EX      (SP),HL         ; 000Ch '%'
        RST     10h
        DB      0,0             ; 000Eh spare
; ---- RST 10h: next character ------------------------------------------------
        POP     DE              ; 0010h discard the RST's return address
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
        LD      (SPTMP),SP
        LD      A,(SPTMP+1)
        CP      DSPAGE
        JP      NZ,e_stack
        EXX                     ; the return stack: in its page, and not
        LD      A,L             ;   above its empty position (an underflow
        CP      RSTOP&0FFh+1    ;   would stay inside the page, in the
        LD      A,H             ;   guard band)
        EXX
        JP      NC,e_rstack
        CP      RSPAGE
        JP      NZ,e_rstack
        ENDIF
        LD      A,(BC)
        INC     BC
        SUB     21h             ; A = c - 21h
        JR      C,ctl           ; c < 21h: NUL ends, the rest are ignored
        CP      0Fh
        JR      C,punct         ; 21h-2Fh: PTAB index 0-14
        SUB     0Fh             ; A = c - 30h
        CP      0Ah
        JR      C,digit         ; 30h-39h
        CP      11h
        JR      NC,ab40
        ADD     A,5             ; 3Ah-40h: index 15-21
        JR      punct
ab40:   SUB     11h             ; A = c - 41h
        CP      1Ah
        JR      C,upper         ; 41h-5Ah: A = letter index 0-25
        CP      20h
        JR      NC,ab60
        SUB     4               ; 5Bh-60h: index 22-27
        JR      punct
ab60:   CP      3Ah
        JR      C,lower         ; 61h-7Ah: A = 20h-39h (cell +64 bytes)
        CP      3Eh
        JR      NC,next0        ; 7Fh-FFh: ignored
        SUB     1Eh             ; 7Bh-7Eh: index 28-31

; Punctuation: HL holds TOS, so it is parked in DE while the table is read.
; PTAB never crosses a page (checked at assembly), so only L needs adding.
punct:  EX      DE,HL           ; DE = TOS
        ADD     A,A
        ADD     A,PTAB & 0FFh
        LD      L,A
        LD      H,PTAB / 256
        LD      A,(HL)
        INC     L
        LD      H,(HL)
        LD      L,A             ; HL = handler
        EX      DE,HL           ; HL = TOS, DE = handler
        PUSH    DE              ; jump to it; the stack is balanced again
        RET                     ;   when the handler starts

ctl:    ADD     A,21h           ; back to c; zero only for NUL
        JR      NZ,next0
        JP      endprog


; a-z: push the cell's address (the cell is the variable)
lower:  PUSH    HL
        ADD     A,A
        LD      L,A
        LD      H,LETPAGE
        RST     10h

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  PUSH    HL              ; keep TOS
        ADD     A,A
        LD      L,A
        LD      H,LETPAGE       ; HL -> cell
        LD      E,(HL)
        INC     L
        LD      D,(HL)          ; DE = the word's body
        POP     HL              ; TOS back
        CALL    rpush           ; push the return address (IP)
        LD      B,D
        LD      C,E             ; IP = body
        RST     10h

; Digits: step back onto the first digit and read the whole number.
digit:  PUSH    HL
        DEC     BC
        CALL    rdnum
        RST     10h

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
rdnum:  LD      HL,0
rdn1:   LD      A,(BC)
        SUB     '0'
        CP      10
        RET     NC
        INC     BC
        LD      D,H
        LD      E,L
        ADD     HL,HL
        ADD     HL,HL
        ADD     HL,DE
        ADD     HL,HL           ; HL * 10
        LD      E,A
        LD      D,0
        ADD     HL,DE
        JR      rdn1

; =============================================================================
;  Return stack. rpush pushes BC (nearly always the IP); rpop pops into DE.
;  HL' is the pointer. Both go through the Z80 stack to cross between the
;  register sets.
; =============================================================================
rpush:  PUSH    BC
        EXX
        POP     DE
        DEC     HL
        LD      (HL),D
        DEC     HL
        LD      (HL),E
        EXX
        RET

rpop:   EXX
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        INC     HL
        PUSH    DE
        EXX
        POP     DE
        RET

; =============================================================================
;  Arithmetic and logic. Effects are ( NOS TOS -- result ).
; =============================================================================
h_add:  POP     DE
        ADD     HL,DE
        RST     10h

; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  LD      A,(BC)
        SUB     '0'
        CP      10
        JR      C,negnum
        CALL    neg16           ; a - b = a + (-b)
        POP     DE
        ADD     HL,DE
        RST     10h
negnum: PUSH    HL
        CALL    rdnum
        CALL    neg16
        RST     10h

; neg16: HL = -HL (keeps BC, DE)
neg16:  XOR     A
        SUB     L
        LD      L,A
        SBC     A,A
        SUB     H
        LD      H,A
        RET

; '*': shift-and-add, 16 rounds; only the low 16 bits are kept.
h_mul:  POP     DE              ; DE = multiplicand
        PUSH    BC
        LD      B,H
        LD      C,L             ; BC = multiplier
        LD      HL,0
        LD      A,16
mul1:   ADD     HL,HL
        SLA     C
        RL      B
        JR      NC,mul2
        ADD     HL,DE
mul2:   DEC     A
        JR      NZ,mul1
        POP     BC
        RST     10h

; '/' ( a b -- r q ): the quotient is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Dividing by zero is not checked: it returns two cells of no meaning.
h_div:  POP     DE              ; DE = a, HL = b
        PUSH    BC              ; free BC for udiv
        LD      A,D
        XOR     H
        PUSH    AF              ; S flag = sign of q
        LD      A,D
        OR      A
        PUSH    AF              ; S flag = sign of a (for r)
        BIT     7,H
        CALL    NZ,neg16        ; HL = |b|
        EX      DE,HL
        BIT     7,H
        CALL    NZ,neg16        ; HL = |a|, DE = |b|
        CALL    udiv            ; BC = q, HL = r
        POP     AF
        CALL    M,neg16         ; r's sign
        EX      DE,HL           ; DE = r
        LD      H,B
        LD      L,C             ; HL = q
        POP     AF
        CALL    M,neg16         ; q's sign
        POP     BC
        PUSH    DE              ; r under q
        RST     10h

; udiv: unsigned HL / DE. Returns BC = quotient, HL = remainder.
; Uses A, BC; the caller saves the IP.
udiv:   LD      B,H
        LD      C,L
        LD      HL,0
        LD      A,16
udv1:   SLA     C
        RL      B
        ADC     HL,HL
        SBC     HL,DE           ; carry is clear here: the remainder
        JR      NC,udv2         ;   always fits in 16 bits
        ADD     HL,DE
        JR      udv3
udv2:   INC     C
udv3:   DEC     A
        JR      NZ,udv1
        RET

h_and:  POP     DE
        LD      A,H
        AND     D
        LD      H,A
        LD      A,L
        AND     E
        LD      L,A
        RST     10h

h_or:   POP     DE
        LD      A,H
        OR      D
        LD      H,A
        LD      A,L
        OR      E
        LD      L,A
        RST     10h

h_xor:  POP     DE
        LD      A,H
        XOR     D
        LD      H,A
        LD      A,L
        XOR     E
        LD      L,A
        RST     10h

h_not:  CALL    neg16           ; ~x = -x - 1
        DEC     HL
        RST     10h

; Signed compares. Flipping both sign bits turns a signed compare into an
; unsigned one; SBC HL,HL then turns the carry into -1 or 0 with no branch.
h_gt:   POP     DE              ; a > b  is  b < a: HL = b, DE = a
        JR      cmp
h_lt:   POP     DE              ; a < b: HL = a, DE = b
        EX      DE,HL
cmp:    LD      A,H
        XOR     80h
        LD      H,A
        LD      A,D
        XOR     80h
        LD      D,A
        OR      A
        SBC     HL,DE           ; carry if HL < DE
        SBC     HL,HL
        RST     10h

h_eq:   POP     DE
        OR      A
        SBC     HL,DE
        LD      HL,0
        JR      NZ,eq1
        DEC     HL
eq1:    RST     10h

; =============================================================================
;  Stack
; =============================================================================
        IF      CPM             ; (the generic build has these in page zero)
h_dup:  PUSH    HL
        RST     10h
h_swap: EX      (SP),HL
        RST     10h
        ENDIF

h_tor:  PUSH    BC              ; '{' TOS to the return stack
        LD      B,H
        LD      C,L
        CALL    rpush
        POP     BC
        RST     08h

h_fromr:PUSH    HL              ; '}' return stack to TOS
        CALL    rpop
        EX      DE,HL
        RST     10h

; =============================================================================
;  Storage
; =============================================================================
h_fetch:LD      E,(HL)          ; '@'
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        RST     10h

h_store:POP     DE              ; '!' ( n addr -- )
        IF      CHECKED
        INC     HL              ; both bytes must be in the program's space
        CALL    chkst
        DEC     HL
        ENDIF
        LD      (HL),E
        INC     HL
        LD      (HL),D
        RST     08h


h_cstore:POP    DE              ; '.' ( c addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        LD      (HL),E
        RST     08h

; '_' ( n -- addr ): the heap pointer moves up by n; TOS is the old pointer.
h_alloc:EX      DE,HL
        LD      HL,(HEAP)
        PUSH    HL
        ADD     HL,DE
        IF      CHECKED
        JP      C,e_heap        ; a negative count wraps: too big
        LD      A,(HLIM)
        DEC     A
        CP      H
        JP      C,e_heap        ; the new top must stay below the limit page
        ENDIF
        LD      (HEAP),HL
        POP     HL
        RST     10h

        IF      CHECKED
; chkst: stop unless HL is in the program's own space: from the letter page
; up to the heap limit (the OS, or HEAPLIM), so the interpreter's stacks and
; whatever lies above the limit are safe. Memory above the heap top but
; below the limit is the program's own: Tiny BASIC keeps its lines there.
; Keeps every register.
chkst:  PUSH    AF
        LD      A,H
        CP      LETPAGE
        JR      C,chk1
        LD      A,(HLIM)
        DEC     A
        CP      H
chk1:   JP      C,e_store
        POP     AF
        RET
        ENDIF

; =============================================================================
;  Flow control
; =============================================================================

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: LD      A,H
        OR      L
        POP     HL
        JR      Z,skipnx
        CALL    rpush           ; the block starts at the IP
        RST     10h
skipnx: CALL    skip
        RST     10h

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on.
h_close:LD      A,H
        OR      L
        POP     HL
        JR      Z,rdrop
        IF      CHECKED
        CALL    chkbrk          ; Ctrl-C is checked at every loop-back
        ENDIF
        CALL    rpop            ; peek: pop the block start ...
        LD      B,D
        LD      C,E
        CALL    rpush           ; ... and push it back
        RST     10h
rdrop:  CALL    rpop
        RST     10h

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
h_break:LD      A,H
        OR      L
        POP     HL
        JR      Z,brk1
        CALL    skip
        CP      ')'
        JR      Z,rdrop
        JR      h_ret
brk1:   RST     10h

; ']' returns: pop an address and jump to it.
h_ret:  CALL    rpop
        LD      B,D
        LD      C,E
        IF      CHECKED
        CALL    chkbrk          ; ... and at every word return
        ENDIF
        RST     10h

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
h_def:  LD      A,(BC)
        INC     BC
        LD      E,A
        AND     0DFh            ; fold case
        SUB     'A'
        CP      26
        JR      NC,def2         ; not a letter
        LD      A,E
        SUB     'A'             ; 0-25 or 32-57: lowercase lands 64 bytes up
        ADD     A,A
        LD      E,A
        LD      D,LETPAGE       ; DE -> cell
        LD      A,C
        LD      (DE),A
        INC     E
        LD      A,B
        LD      (DE),A
        JR      skipnx
def2:
        IF      CHECKED
        LD      A,E
        CP      ' '
        JP      NZ,e_brack      ; anything but a letter or a space
        ENDIF
        PUSH    HL              ; an anonymous block: push its address
        LD      H,B
        LD      L,C
        JR      skipnx

; skip: read past text to the closer at this level, and return it in A.
; Brackets of both kinds count together; strings are stepped over whole. A
; NUL first ends the program (for '\' with no closer; anything else that runs
; into the NUL had unbalanced brackets anyway).
skip:   LD      D,0
sk1:    LD      A,(BC)
        INC     BC
        OR      A
        JP      Z,endprog
        CP      22h
        JR      NZ,sk2
        CALL    skipstr
        JR      sk1
sk2:    CP      '('
        JR      Z,sk3
        CP      '['
        JR      Z,sk3
        CP      ')'
        JR      Z,sk4
        CP      ']'
        JR      NZ,sk1
sk4:    INC     D
        DEC     D
        RET     Z               ; the closer at this level
        DEC     D
        JR      sk1
sk3:    INC     D
        JR      sk1

; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it.
skipstr:LD      A,(BC)
        INC     BC
        CP      '/'
        JR      NZ,ss1
        INC     BC
        JR      skipstr
ss1:    CP      22h
        JR      NZ,skipstr
        RET

; =============================================================================
;  Console
; =============================================================================

; 22h pushes the address of the text after it and skips the string.
h_str:  PUSH    HL
        LD      H,B
        LD      L,C
        CALL    skipstr
        RST     10h

; '$' prints the string at TOS, decoding escapes: '/' plus a character from
; 40h-7Fh clears its bit 6 (/M is CR, /` is space); plus anything lower gives
; that character itself.
h_print:LD      A,(HL)
        INC     HL
        CP      22h
        JR      Z,prdone
        CP      '/'
        JR      NZ,pr1
        LD      A,(HL)
        INC     HL
        CP      40h
        JR      C,pr1
        AND     0BFh
pr1:    CALL    putc
        JR      h_print
prdone: RST     08h

h_emit: LD      A,L             ; "'"
        CALL    putc
        RST     08h

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  BIT     7,H
        JR      Z,num1
        LD      A,'-'
        CALL    putc
        CALL    neg16
num1:   PUSH    BC
        CALL    pdec
        POP     BC
        RST     08h
; pdec: print HL unsigned, by recursion on HL / 10 (the stack holds digits)
pdec:   LD      DE,10
        CALL    udiv            ; BC = HL / 10, HL = digit
        LD      A,L
        PUSH    AF
        LD      H,B
        LD      L,C
        LD      A,H
        OR      L
        CALL    NZ,pdec
        POP     AF
        ADD     A,'0'
        JP      putc

h_cfetch:LD     A,(HL)          ; ',' shares '?'s ending: A becomes TOS
        JR      kt3

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. n is not
;          checked: the buffer holds 127 characters and the CR, so a
;          program must ask for 127 or fewer.
h_key:  BIT     7,H
        JR      NZ,line
kt1:    LD      DE,MSLOOP       ; one millisecond, roughly
kt2:    CALL    getk
        JR      NZ,kt3
        DEC     DE
        LD      A,D
        OR      E
        JR      NZ,kt2
        LD      A,H             ; 0? never counts down: it waits
        OR      L
        JR      Z,kt1
        DEC     HL
        LD      A,H
        OR      L
        JR      NZ,kt1          ; A = 0 if the time ran out
kt3:    LD      L,A
        LD      H,0
        RST     10h

        IF      CPM
        ; CP/M: BDOS 10 does the editing (the spec allows the platform's
        ; own line editor). It doesn't store the CR, so it is added here.
line:   XOR     A
        SUB     L               ; A = the count (TOS is minus the count)
        LD      (LBHDR),A
        PUSH    BC
        EXX
        PUSH    HL
        EXX
        LD      DE,LBHDR
        LD      C,10
        CALL    BDOS
        EXX
        POP     HL
        EXX
        POP     BC
        LD      HL,LBHDR+1
        LD      E,(HL)          ; count
        LD      D,0
        INC     HL              ; HL = LINEBUF
        PUSH    HL
        ADD     HL,DE
        LD      (HL),13
        POP     HL
        RST     10h
        ENDIF
        IFN     CPM
        ; Generic: Backspace takes the last character back (and is echoed as
        ; it is), CR ends (stored, not echoed), every other key is stored and
        ; echoed until the line is full. The line buffer starts at offset 80h
        ; of its page, so L alone is the place in the line: D holds the L of
        ; a full line.
line:   LD      A,LINEBUF & 0FFh
        SUB     L               ; (TOS is minus the count)
        LD      D,A             ; D = the L of a full line
        LD      HL,LINEBUF
ln2:    CALL    getk
        JR      Z,ln2
        CP      13
        JR      Z,ln5
        CP      8
        JR      Z,ln4
        LD      E,A
        LD      A,L
        CP      D
        JR      Z,ln2           ; full
        LD      (HL),E
        INC     L
        LD      A,E
ln3:    CALL    putc
        JR      ln2
ln4:    DEC     L               ; Backspace: one back, and echo it,
        JP      M,ln3           ;   unless the line was empty (L left the
        INC     L               ;   upper half of the page)
        JR      ln2
ln5:    LD      (HL),A          ; the CR
        LD      L,LINEBUF & 0FFh
        RST     10h
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
h_grave:LD      A,(BC)
        CALL    hexval
        JR      C,exec
hx1:    LD      A,(BC)
        CALL    hexval
        JR      C,hx2
        INC     BC
        IF      CHECKED
        CALL    chkst
        ENDIF
        LD      (HL),A          ; the high digit goes in first ...
        LD      A,(BC)
        CALL    hexval
        JR      C,hx2           ; odd digit: consumed, and the RET below
        INC     BC              ;   overwrites it
        RLD                     ; ... and RLD shifts it up under the low one
        INC     HL
        JR      hx1
hx2:
        IF      CHECKED
        CALL    chkst
        ENDIF
        LD      (HL),0C9h
        RST     10h

exec:   EXX
        LD      (RSAVE),HL      ; machine code may change the alternates
        EXX
        LD      DE,exret
        PUSH    DE
        JP      (HL)
exret:  EXX
        LD      HL,(RSAVE)
        EXX
        POP     HL
        RST     10h

; hexval: A = a character; returns its value 0-15 with carry clear, or
; carry set if it isn't a hex digit (0-9, A-F, a-f).
hexval: SUB     '0'
        CP      10
        CCF
        RET     NC
        AND     0DFh
        SUB     11h
        CP      6
        CCF
        RET     C
        ADD     A,10
        RET

; =============================================================================
;  Console layer: getk returns a waiting key in A (zero flag clear), or
;  A = 0 with the zero flag set when none is waiting. putc prints A.
;  Both keep BC, DE, HL and HL'. In the generic build they are the host's
;  KEY and CONOUT routines themselves.
; =============================================================================
        IF      (1-CPM)*(1-CHECKED)
getk    EQU     KEY             ; the host's routine does the whole job
        ENDIF
        IF      CHECKED
getk:   LD      A,(KEYBUF)      ; a key held back by the break check
        OR      A
        JR      Z,gk1
        PUSH    AF
        XOR     A
        LD      (KEYBUF),A
        POP     AF
        RET
        ENDIF
        IF      (1-CPM)*CHECKED
gk1:    JP      KEY
        ENDIF
        IF      CPM*(1-CHECKED)
getk:
        ENDIF
        IF      CPM
gk1:    LD      A,0FFh          ; BDOS 6 with E = FFh: a key, or 0
        CALL    putc
        OR      A
        RET
; putc: BDOS 6 for every character. BDOS 2 would check for ^S while
; printing and could swallow a key that BDOS 6 then never sees.
putc:   PUSH    BC
        PUSH    DE
        PUSH    HL
        EXX
        PUSH    HL
        EXX
        LD      E,A
        LD      C,6
        CALL    BDOS
        EXX
        POP     HL
        EXX
        POP     HL
        POP     DE
        POP     BC
        RET
        ENDIF
        IFN     CPM
putc    EQU     CONOUT
        ENDIF

; =============================================================================
;  Checked build: break key and error reports
; =============================================================================
        IF      CHECKED
; chkbrk: a waiting key is read now; Ctrl-C stops the program, anything
; else is held for the next '?'.
chkbrk: LD      A,(KEYBUF)
        OR      A
        RET     NZ              ; one key is already held
        CALL    getk
        RET     Z
        CP      3
        JR      Z,e_break
        LD      (KEYBUF),A
        RET

; Error entries. Each loads its letter and then hides the next entry inside
; a 3-byte LD HL,nn (the 21h), so they all fall through to `error`.
e_stack:LD      A,'S'           ; data stack over or under
        DB      21h
e_rstack:LD     A,'R'           ; return stack over or under
        DB      21h
e_break:LD      A,'B'           ; Ctrl-C
        DB      21h
e_heap: LD      A,'H'           ; heap past the limit
        DB      21h
e_store:LD      A,'W'           ; write outside the program's space
        DB      21h
e_brack:LD      A,'D'           ; bad character after [
; error: print the letter in A, " @ " and the offset in the program of the
; character just read, then end. For example: S @ 245
error:  LD      SP,DSTOP        ; the stacks may be wrecked: start clean
        CALL    putc
        LD      A,' '
        CALL    putc
        LD      A,'@'
        CALL    putc
        LD      A,' '
        CALL    putc
        LD      HL,(0-PROG-1)&0FFFFh ; minus the address of the character
        ADD     HL,BC           ;   just read: HL = its offset
        CALL    pdec
        JP      endprog
        ENDIF


; =============================================================================
;  Startup
; =============================================================================
start:
        IF      CPM
        ; CP/M: the RAM pages follow the image; the heap may grow to the BDOS
        LD      SP,DSTOP
        LD      HL,stubs        ; RST 08h and RST 10h stubs into page zero
        LD      DE,0008h
        LD      BC,13
        LDIR
        LD      DE,005Ch        ; open the file named on the command line
        LD      C,15
        CALL    BDOS
        INC     A
        JP      Z,0             ; no such file: back to CP/M
        LD      DE,PROG
ld1:    PUSH    DE
        LD      C,26            ; set the DMA address
        CALL    BDOS
        LD      DE,005Ch
        LD      C,20            ; read the next 128 bytes
        CALL    BDOS
        POP     HL
        LD      DE,128
        ADD     HL,DE
        EX      DE,HL
        OR      A
        JR      Z,ld1
        LD      HL,-128         ; the failed read left nothing: back up
        ADD     HL,DE
        LD      (HL),0          ; the end of the file counts as NUL
        INC     HL
        LD      (HEAP),HL
        LD      A,(0007h)       ; the BDOS page is the heap limit
        LD      (HLIM),A
        ENDIF
        IFN     CPM
        LD      SP,DSTOP
        LD      HL,PROG         ; the heap starts after the program's NUL
        XOR     A
        LD      B,A
        LD      C,A
        CPIR
        LD      (HEAP),HL
        ENDIF
        IF      (1-CPM)*CHECKED
        LD      A,HEAPLIM
        LD      (HLIM),A
        ENDIF
        EXX
        LD      HL,RSTOP
        EXX
        IF      CHECKED
        XOR     A
        LD      (KEYBUF),A
        ENDIF
        LD      BC,PROG
        JP      next0

        IF      CPM
stubs:  POP     DE              ; 0008h: drop, then next
        POP     HL
        JP      next0
        DB      0,0,0
        POP     DE              ; 0010h: next
        JP      next0
endprog EQU     0               ; warm boot
drop_next EQU   0009h
; RAM pages, after the image
RSPAGE  EQU     (imgend + 255) / 256
DSPAGE  EQU     RSPAGE + 1
LETPAGE EQU     RSPAGE + 2
PROG    EQU     LETPAGE*256 + 256
        ENDIF
imgend:
