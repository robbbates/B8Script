; =============================================================================
;  B8Script interpreter for the Z80
;  Spec: docs/b8script.md (2026-10-09) plus the 2026-11-20 changes:
;        [x stores in a variable, "[ " pushes an anonymous block, any other
;        character after [ is an error, the heap pointer lives at z10+.
;        The string escape is '/' (it was '>').
;        '/' leaves ( r q ), the quotient on top; dividing by zero is not
;        checked. -n? does no more editing than Backspace.
;
;  Three switches, set in the EQU lines below:
;    CPM      0 = generic ROM build (KEY/CONOUT at fixed addresses)
;             1 = CP/M 2.2 .COM file: loads the file named on the command line
;    EDITOR   1 = generic build with a small line editor built in (see the
;                 end of this file). It needs CPM = 0 and CHECKED = 0.
;    CHECKED  0 = no checks (spec: "B8Script checks nothing")
;             1 = stops on stack overrun, Ctrl-C, heap past the limit, a store
;                 outside the program's own space, and a bad character after [,
;                 printing a letter and the place, like  S @ 245
;
;  Assembler: asm80 (https://maly.github.io/asm80-node/), Z80 mode.
; =============================================================================

CPM     EQU     0               ; 1 = CP/M .COM build
CHECKED EQU     0               ; 1 = checked build
EDITOR  EQU     0               ; 1 = with the line editor (generic only)

; -----------------------------------------------------------------------------
;  Register use, everywhere in the interpreter
;
;    BC   IP: the address of the next program character to read
;    HL   TOS: the top data-stack cell is kept here, not in memory
;    SP   the data stack: (SP) is NOS, the cell under TOS. The data stack is
;         the Z80's own stack, which is what the spec's machine-code contract
;         needs ("the data cells above the return address").
;    HL'  return-stack pointer (the alternate HL). Entries are 2 bytes; the
;         stack grows down. Only rpop and rpushn (and the checks) touch it.
;    A DE scratch. Every handler is entered with HL = TOS and may use A, DE.
;
;  One-byte calls. The routines used most are reached with RST, one byte
;  instead of three:
;
;    RST 08h  rpop    pop the return stack into DE
;    RST 18h  drop    drop TOS, then next character     (ends a handler)
;    RST 20h  neg16   HL = -HL
;    RST 28h  putc    print A
;    RST 30h  next    next character                    (ends a handler)
;
;  RST 18h and RST 30h never return: an RST is a CALL, so the first thing
;  each of them does is POP DE to throw the return address away.
;
;  The CP/M build can't own page zero, so the block from `vecs` to `vecend`
;  (image addresses 0108h-0133h) is copied to 0008h-0033h when it starts. The
;  code in that block is written to work at either place.
;
;  Dispatch. PTAB holds one byte per punctuation character: the low byte of
;  its handler's address. The high byte is worked out from the character:
;  the handlers of the first NPG1 characters (in code order) start in the
;  image's second page, the rest in its first. The layout below keeps to
;  that, and testing/chktab.py checks it in every build.
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
                                ;   (end the routine with OR A / RET).
CONOUT  EQU     0FF03h          ; print the character in A
;   KEY and CONOUT must preserve BC, DE, HL and HL'.
RSPAGE  EQU     80h             ; 8000h return stack
DSPAGE  EQU     81h             ; 8100h data stack
LETPAGE EQU     82h             ; 8200h letter cells and line buffer
PROG    EQU     8300h           ; where the loader puts the program text
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)
BASE    EQU     0000h           ; where the image starts
        ENDIF
        IF      (1-CPM)*(1-EDITOR)
EXIT    EQU     0FF09h          ; where to go when the program ends
        ENDIF
        IF      EDITOR
EXIT    EQU     edit            ; a program that ends goes back to the editor
        ENDIF

MSLOOP  EQU     40              ; n? inner loop count for about 1 ms (1-255):
                                ; each pass calls getk once, so tune it for
                                ; your clock and your KEY routine

; letter-page layout (offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     LET+7Ch         ; z10+, the heap pointer
RSAVE   EQU     LET+34h         ; gap after Z: return stack pointer, saved
KEYBUF  EQU     LET+36h         ;   around machine code; a held-back key;
SPTMP   EQU     LET+38h         ;   scratch for the SP check
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
        IF      1-EDITOR
        LD      SP,DSTOP        ; 00  reset, or the start of the .COM file
        ENDIF
        IF      (1-CPM)*(1-EDITOR)
        LD      BC,PROG         ; 03  the IP
        JR      st0             ; 06  (the rest of the startup is close by)
        ENDIF
        IF      EDITOR
        XOR     A               ; 00  reset: no program yet
        LD      (PROG),A
        JP      edit            ; 04
        NOP                     ; 07  spare
        ENDIF
        IF      CPM
        JP      start           ; 03
        DW      0               ; 06  spare
        ENDIF
vecs:
; ---- RST 08h: rpop: pop the return stack into DE ---------------------------
rpop:   EXX                     ; 08
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        INC     HL
        PUSH    DE              ; across to the main registers
        EXX
        POP     DE
        RET                     ; 10  (so RST 10h is not used)
; ctl: the inner loop comes here for characters below 21h. A = c - 21h.
ctl:    ADD     A,21h           ; 11  back to c; zero only for NUL
        JR      NZ,next0        ;     the rest are ignored
endprog:JP      EXIT            ;     the program has ended
; ---- RST 18h: drop TOS, then next ------------------------------------------
rst18:  POP     DE              ; 18  discard the RST's return address
        POP     HL              ;     new TOS = NOS
        JR      nx
h_fromr:PUSH    HL              ; 1C  '}' return stack to TOS
        RST     08h
        EX      DE,HL
        RST     30h
; ---- RST 20h: neg16: HL = -HL (keeps BC, DE) -------------------------------
neg16:  XOR     A               ; 20
        SUB     L
        LD      L,A
        SBC     A,A
        SUB     H
        LD      H,A
        RET
        NOP                     ; 27  spare
; ---- RST 28h: putc: print A (keeps BC, DE, HL, HL') ------------------------
rst28:
        IFN     CPM
putc:   JP      CONOUT          ; 28
        ENDIF
        IF      CPM
        JP      putc            ; 28
        ENDIF
jphl:   JP      (HL)            ; 2B  (for the machine-code call)
h_tor:  EX      (SP),HL         ; 2C  '{' TOS to the return stack: the new TOS
        JP      rpushn          ;     comes up, the old one goes across
; ---- RST 30h: next character -----------------------------------------------
rst30:  POP     DE              ; 30  discard the RST's return address
nx:
        IF      CPM
        JP      next0           ; (this copy runs in page zero)
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
        JR      C,p3a           ; 3Ah-40h
        SUB     11h             ; A = c - 41h
        CP      1Ah
        JR      C,upper         ; 41h-5Ah: A = letter index 0-25
        CP      20h
        JR      C,p5b           ; 5Bh-60h
        CP      3Ah
        JR      C,lower         ; 61h-7Ah: A = 20h-39h (cell +64 bytes)
        CP      3Eh
        JR      NC,next0        ; 7Fh-FFh: ignored
        SUB     1Ah             ; 7Bh-7Eh: -1Eh in all, index 28-31
p5b:    SUB     9               ; 5Bh-60h: -4 in all, index 22-27
p3a:    ADD     A,5             ; 3Ah-40h: index 15-21

.macro  PTABLE
        DB      h_store & 0FFh  ; !
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
.endm

; Punctuation: A = the PTAB index. The handler starts with HL = TOS,
; untouched, and A, DE free.
punct:  ADD     A,PTAB & 0FFh   ; PTAB never crosses a page
        LD      E,A
        LD      D,PTAB / 256    ; (0 in the editor build)
        CP      (PTAB & 0FFh) + NPG1 ; carry: one of the first NPG1
        LD      A,(DE)
        LD      E,A             ; the handler's low byte
        IF      (1-CPM)*(1-EDITOR)
        LD      D,0
        ENDIF
        IFN     CPM
        RL      D               ; its page: 0 + carry
        ENDIF
        IF      CPM
        LD      D,1
        JR      NC,pu1
        INC     D               ; its page: 1 + carry
pu1:
        ENDIF
        PUSH    DE              ; jump to it; the stack is balanced again
        RET                     ;   when the handler starts

; The rest of the startup: here so that the generic reset code can reach it
; with JR. st0: find the program's NUL; the heap starts after it.
; (The editor build has its own copy of this, next to the editor.)
        IF      (1-CPM)*(1-EDITOR)
st0:    LD      H,B
        LD      L,C
        XOR     A
st1:    CP      (HL)
        INC     HL
        JR      NZ,st1
        ENDIF
        IF      1-EDITOR
st2:    LD      (HEAP),HL
        EXX
        LD      HL,RSTOP        ; the return stack is empty
        EXX
        ENDIF
        IF      CHECKED*(1-EDITOR)
        XOR     A
        LD      (KEYBUF),A      ; no key held back
        ENDIF
        IF      1-EDITOR
        RST     30h             ; (its return address is thrown away)
        ENDIF

; In the editor build the table is here, in the first page, which saves
; loading D twice. (The other builds have no room for it here: theirs is
; further down.)
        IF      EDITOR
PTAB:
        PTABLE
PTABEND:
        ENDIF

; =============================================================================
;  Handlers that must start in the image's first page: ^ _ ` | ~
;  ({ and } are up among the RST routines.) The machine-code call, exec,
;  is here too: it belongs to '`' and makes the page come out right.
; =============================================================================
h_xor:  POP     DE
        LD      A,H
        XOR     D
        LD      H,A
        LD      A,L
        XOR     E
        LD      L,A
        RST     30h

h_or:   POP     DE
        LD      A,H
        OR      D
        LD      H,A
        LD      A,L
        OR      E
        LD      L,A
        RST     30h

h_not:  RST     20h             ; ~x = -x - 1
        DEC     HL
        RST     30h

; '_' ( n -- addr ): the heap pointer moves up by n; TOS is the old pointer.
h_alloc:LD      DE,(HEAP)
        ADD     HL,DE           ; the new top
        IF      CHECKED
        CALL    chkhp
        ENDIF
        LD      (HEAP),HL
        EX      DE,HL
        RST     30h

exec:   EXX
        LD      (RSAVE),HL      ; machine code may change the alternates
        EXX
        CALL    jphl
        EXX
        LD      HL,(RSAVE)
        EXX
        POP     HL
        RST     30h

; ---- the letters and digits (here, in the middle, so that the inner loop's
; ---- short jumps reach them, and the handlers after them reach rpushn) ------

; Digits: step back onto the first digit and read the whole number.
digit:  PUSH    HL
        DEC     BC
        CALL    rdnum
        RST     30h

; a-z: push the cell's address (the cell is the variable)
lower:  PUSH    HL
        ADD     A,A
        LD      L,A
        LD      H,LETPAGE
        RST     30h

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  PUSH    BC              ; the return address, for rpushn
        EX      DE,HL           ; park TOS
        ADD     A,A
        LD      L,A
        LD      H,LETPAGE       ; HL -> cell
        LD      C,(HL)
        INC     L
        LD      B,(HL)          ; IP = the word's body
        EX      DE,HL           ; TOS back, and fall into rpushn

; rpushn: move the top cell of the data stack (in memory) to the return
; stack, then next. Everything that pushes the return stack ends here.
rpushn:
        IF      CHECKED
        CALL    chkbrk          ; Ctrl-C is checked at every word call, block
        ENDIF                   ;   entry, loop-back and '{'
        EXX
        POP     DE
        DEC     HL
        LD      (HL),D
        DEC     HL
        LD      (HL),E
        EXX
        RST     30h

; ---- machine code: the grave -----------------------------------------------
; '`' plus a hex digit loads bytes: ( addr -- addr' ). Pairs of hex digits
; are stored from addr until a non-hex character; then a RET (C9h) is
; written and its address is left. An odd last digit is consumed and dropped.
; '`' plus anything else calls the machine code at TOS: ( addr -- ). The
; code is entered by CALL with the data stack above the return address; it
; must keep BC, and on return the top cell becomes the new TOS.
h_grave:CALL    hexc
        JR      NC,exec
hx1:
        IF      CHECKED
        CALL    chkst
        ENDIF
        LD      (HL),A          ; the high digit goes in first ...
        CALL    hexc
        JR      NC,hx2          ; odd digit: consumed, and the RET below
        RLD                     ;   overwrites it
        INC     HL              ; ... and RLD shifts it up under the low one
        CALL    hexc
        JR      C,hx1
hx2:
        IF      CHECKED
        CALL    chkst
        ENDIF
        LD      (HL),0C9h
        RST     30h

; ---- where the two pages meet ----------------------------------------------
; The first page ends somewhere among the next four handlers, ] \ [ @ (they
; are in falling code order for this), and where exactly differs between the
; builds: NPG1 follows. Every handler below these four must start in the
; second page, and every one above in the first; chktab.py checks both.

; ']' returns: pop an address and jump to it.
h_ret:  RST     08h
        LD      B,D
        LD      C,E
brk1:   RST     30h

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
h_break:LD      A,H
        OR      L
        POP     HL
        JR      Z,brk1
        CALL    skip
        OR      A               ; skip returns 0 for ')'
        JR      NZ,h_ret
rdrop:  RST     08h
        RST     30h

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything below 'A' as the space, and anything
; from 'A' up as a letter.)
h_def:  LD      A,(BC)
        INC     BC
        IF      CHECKED
        CP      ' '
        JR      Z,def2
        LD      E,A
        AND     0DFh            ; fold case
        SUB     'A'
        CP      26
        JP      NC,e_brack      ; anything but a letter or a space
        LD      A,E
        ENDIF
        SUB     'A'             ; 0-25 or 32-57: lowercase lands 64 bytes up
        IF      1-CHECKED
        JR      C,def2
        ENDIF
        ADD     A,A
        LD      E,A
        LD      D,LETPAGE       ; DE -> cell
        LD      A,C
        LD      (DE),A
        INC     E
        LD      A,B
        LD      (DE),A
        JR      skipnx
def2:   PUSH    HL              ; an anonymous block: push its address
        LD      H,B
        LD      L,C
skipnx: CALL    skip
        RST     30h

h_fetch:LD      E,(HL)          ; '@'
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        RST     30h


; =============================================================================
;  Handlers that must start in the image's second page.
;  '?' is the last (with ',' inside it), so its long tail may run past that
;  page.
; =============================================================================

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: LD      A,H
        OR      L
        POP     HL
        JR      Z,skipnx
        PUSH    BC              ; the block starts at the IP
        JR      rpushn

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on.
h_close:LD      A,H
        OR      L
        POP     HL
        JR      Z,rdrop
        RST     08h             ; pop the block start ...
        LD      B,D
        LD      C,E
        PUSH    BC
        JR      rpushn          ; ... and push it back

; ---- arithmetic and logic: ( NOS TOS -- result ) ---------------------------

; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  LD      A,(BC)
        SUB     '0'
        CP      10
        JR      C,negnum
        RST     20h             ; a - b = a + (-b): fall into '+'
h_add:  POP     DE
        ADD     HL,DE
        RST     30h
negnum: PUSH    HL              ; a negative number: read it, negate it
        CALL    rdnum
        RST     20h
        RST     30h

h_and:  POP     DE
        LD      A,H
        AND     D
        LD      H,A
        LD      A,L
        AND     E
        LD      L,A
        RST     30h


; Signed compares. Both are "HL < DE" for the right pair: '<' swaps the two
; cells first. Flipping both sign bits turns a signed compare into an
; unsigned one (and XOR clears the carry for SBC); SBC HL,HL then turns the
; carry into -1 or 0 with no branch.
h_lt:   EX      (SP),HL         ; a < b: HL = a, and b is popped next
h_gt:   POP     DE              ; a > b  is  b < a: HL = b, DE = a
        LD      A,H
        XOR     80h
        LD      H,A
        LD      A,D
        XOR     80h
        LD      D,A
        SBC     HL,DE           ; carry if HL < DE
tf:     SBC     HL,HL           ; carry -> -1 or 0
        RST     30h

h_eq:   POP     DE
        OR      A
        SBC     HL,DE
        LD      A,H
        OR      L
        CP      1               ; carry only if a - b = 0
        JR      tf

; '*': shift-and-add, 16 rounds; only the low 16 bits are kept. The
; multiplier shifts up through A:C.
h_mul:  POP     DE              ; DE = multiplicand
        PUSH    BC
        LD      A,H
        LD      C,L             ; A:C = multiplier
        LD      HL,0
        LD      B,16
mul1:   ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mul2
        ADD     HL,DE
mul2:   DJNZ    mul1
        POP     BC
        RST     30h

; '/' ( a b -- r q ): the quotient is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Dividing by zero is not checked: it returns two cells of no meaning.
h_div:  POP     DE              ; DE = a, HL = b
        PUSH    BC              ; free BC for udiv
        PUSH    DE              ; a, for r's sign
        LD      A,D
        XOR     H
        PUSH    AF              ; S flag = sign of q
        BIT     7,H
        CALL    NZ,neg16        ; HL = |b|
        EX      DE,HL
        BIT     7,H
        CALL    NZ,neg16        ; HL = |a|, DE = |b|
        CALL    udiv            ; HL = q, DE = r
        POP     AF
        CALL    M,neg16         ; q's sign
        EX      DE,HL           ; HL = r, DE = q
        POP     AF              ; A = a's high byte
        OR      A
        CALL    M,neg16         ; r's sign
        EX      DE,HL           ; HL = q, DE = r
        POP     BC
        PUSH    DE              ; r under q
        RST     30h

; ---- stack and storage -----------------------------------------------------

h_dup:  PUSH    HL              ; ':'
        RST     30h

h_swap: EX      (SP),HL         ; '%'
        RST     30h

h_cstore:POP    DE              ; '.' ( c addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        LD      (HL),E
h_drop: RST     18h             ; ';' is this one byte

h_store:POP     DE              ; '!' ( n addr -- )
        IF      CHECKED
        INC     HL              ; both bytes must be in the program's space
        CALL    chkst
        DEC     HL
        ENDIF
        LD      (HL),E
        INC     HL
        LD      (HL),D
        RST     18h


; ---- console ---------------------------------------------------------------

; 22h pushes the address of the text after it and skips the string.
h_str:  PUSH    HL
        LD      H,B
        LD      L,C
        CALL    skipstr
        RST     30h

; '$' prints the string at TOS, decoding escapes: '/' plus a character
; clears that character's bit 6 (/M is CR, /` is space; '/' and '"' have no
; bit 6, so // and /" give themselves).
h_print:LD      A,(HL)
        INC     HL
        CP      22h
        JR      Z,pr9
        CP      '/'
        JR      NZ,pr1
        LD      A,(HL)
        INC     HL
        AND     0BFh
pr1:    RST     28h
        JR      h_print

h_emit: LD      A,L             ; "'"
        RST     28h
pr9:    RST     18h

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  BIT     7,H
        JR      Z,num1
        LD      A,'-'
        RST     28h
        RST     20h
num1:   PUSH    BC
        CALL    pdec
        POP     BC
        RST     18h

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. n is not
;          checked: the buffer holds 127 characters and the CR, so a
;          program must ask for 127 or fewer.
h_key:  BIT     7,H
        JR      NZ,line
kt1:    LD      E,MSLOOP        ; one millisecond, roughly
kt2:    CALL    getk
        JR      NZ,kt3
        DEC     E
        JR      NZ,kt2
        LD      A,H             ; 0? never counts down: it waits
        OR      L
        JR      Z,kt1
        DEC     HL
        LD      A,H
        OR      L
        JR      NZ,kt1          ; A = 0 if the time ran out
        DB      0FEh            ; (CP n: steps over the one byte of ',')
h_cfetch:LD     A,(HL)          ; ',' shares '?'s ending: A becomes TOS
kt3:    LD      L,A
        LD      H,0
        RST     30h

        IF      CPM
        ; CP/M: BDOS 10 does the editing (the spec allows the platform's
        ; own line editor). It doesn't store the CR, so it is added here.
line:   XOR     A
        SUB     L               ; A = the count (TOS is minus the count)
        LD      (LBHDR),A
        LD      DE,LBHDR
        LD      A,10
        CALL    bdosx
        LD      HL,LBHDR+1
        LD      A,(HL)          ; the count typed (0-127)
        INC     L               ; HL = LINEBUF, whose low byte is 80h:
        ADD     A,L             ;   adding the count to L can't carry
        LD      L,A
        LD      (HL),13
        LD      L,LINEBUF & 0FFh
        RST     30h
        ENDIF
        IFN     CPM
        ; Generic: Backspace takes the last character back (and is echoed as
        ; it is), CR ends (stored, not echoed), every other key is stored and
        ; echoed until the line is full. The line buffer starts at offset 80h
        ; of its page, so L alone is the place in the line: D holds the L of
        ; a full line.
        ENDIF
        IF      EDITOR
line:   CALL    rdline          ; (the editor calls rdline too)
        LD      L,LINEBUF & 0FFh
        RST     30h
; rdline: read a line of at most -L characters; HL -> the CR that ends it
rdline:
        ENDIF
        IF      (1-CPM)*(1-EDITOR)
line:
        ENDIF
        IFN     CPM
        LD      A,LINEBUF & 0FFh
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
ln3:    RST     28h
        JR      ln2
ln4:    DEC     L               ; Backspace: one back, and echo it,
        JP      M,ln3           ;   unless the line was empty (L left the
        INC     L               ;   upper half of the page)
        JR      ln2
ln5:    LD      (HL),A          ; the CR
        ENDIF
        IF      (1-CPM)*(1-EDITOR)
        LD      L,LINEBUF & 0FFh
        RST     30h
        ENDIF
        IF      EDITOR
        RET
        ENDIF

; =============================================================================
;  More routines (no handler starts past this point)
; =============================================================================

; udiv: unsigned HL / DE (DE <= 8000h). Returns HL = quotient, DE = remainder.
; Uses A, BC; the caller saves the IP. The dividend shifts up through A:C
; while the quotient bits arrive at the bottom of C.
udiv:   LD      A,H
        LD      C,L
        LD      HL,0
        LD      B,16
udv1:   SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE           ; carry is clear here: the remainder
        JR      NC,udv2         ;   always fits in 16 bits
        ADD     HL,DE           ; too much: put it back, and cancel the
        DEC     C               ;   INC below
udv2:   INC     C               ; a quotient bit
        DJNZ    udv1
        EX      DE,HL           ; DE = remainder
        LD      H,A
        LD      L,C             ; HL = quotient
        RET

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

; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it. Leaves A = 22h.
ss0:    INC     BC
skipstr:LD      A,(BC)
        INC     BC
        CP      '/'
        JR      Z,ss0
        CP      22h
        JR      NZ,skipstr
        RET

; skip: read past text to the closer at this level, and return A = 0 if it
; was ')' and 2 if it was ']'. Brackets of both kinds count together;
; strings are stepped over whole. A NUL first ends the program (for '\' with
; no closer; anything else that runs into the NUL had unbalanced brackets
; anyway). D counts the open levels, starting at 1 for the one we are in:
; skip sets it to 0 and falls through the INC that an opener comes back to.
skip:   LD      D,0
sk3:    INC     D               ; an opener: one deeper
sk1:    LD      A,(BC)
        INC     BC
        OR      A
        JP      Z,endprog
        CP      22h
        CALL    Z,skipstr       ; leaves A = 22h, which matches nothing below
        SUB     '('
        JR      Z,sk3
        DEC     A               ; ')'
        JR      Z,sk4
        SUB     '['-')'
        JR      Z,sk3
        CP      ']'-'['
        JR      NZ,sk1
sk4:    DEC     D
        RET     Z               ; the closer at this level
        JR      sk1

; pdec: print HL unsigned, by recursion on HL / 10 (the stack holds digits).
; Uses BC.
pdec:   LD      DE,10
        CALL    udiv            ; HL = HL / 10, E = the last digit
        LD      A,E
        PUSH    AF
        LD      A,H
        OR      L
        CALL    NZ,pdec
        POP     AF
        ADD     A,'0'
        RST     28h
        RET

; hexc: if the character at IP is a hex digit (0-9, A-F, a-f), step over it
; and return its value in A with the carry set; otherwise leave the IP and
; return with the carry clear.
hexc:   LD      A,(BC)
        SUB     '0'
        CP      10
        JR      C,hc1
        AND     0DFh
        SUB     11h
        CP      6
        RET     NC
        SUB     0F6h            ; + 10, and sets the carry
hc1:    INC     BC
        RET

; =============================================================================
;  Dispatch table: the low byte of each handler's address, in code order
;  (the table itself is the macro PTABLE, defined above the dispatcher).
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
        IF      1-EDITOR
PTAB:
        PTABLE
PTABEND:
        ENDIF

; =============================================================================
;  Console layer: getk returns a waiting key in A (zero flag clear), or
;  A = 0 with the zero flag set when none is waiting. putc (RST 28h) prints
;  A. Both keep BC, DE, HL and HL'. In the generic build they are the host's
;  KEY and CONOUT routines themselves.
; =============================================================================
        IF      (1-CPM)*(1-CHECKED)
getk    EQU     KEY             ; the host's routine does the whole job
        ENDIF
        IF      CHECKED
getk:   PUSH    HL              ; a key held back by the break check goes
        LD      HL,KEYBUF       ;   first, and is taken out of the buffer
        LD      A,(HL)
        LD      (HL),0
        POP     HL
        OR      A
        RET     NZ
        ENDIF
        IF      (1-CPM)*CHECKED
        JP      KEY
        ENDIF
        IF      CPM*(1-CHECKED)
getk:
        ENDIF
        IF      CPM
        LD      A,0FFh          ; BDOS 6 with E = FFh: a key, or 0
; putc: BDOS 6 for every character. BDOS 2 would check for ^S while
; printing and could swallow a key that BDOS 6 then never sees.
putc:   PUSH    DE
        PUSH    HL
        LD      E,A
        LD      A,6
        CALL    bdosx
        POP     HL
        POP     DE
        OR      A               ; (for getk)
        RET
; bdosx: call BDOS function A with DE, keeping BC and HL'
bdosx:  PUSH    BC
        EXX
        PUSH    HL
        EXX
        LD      C,A
        CALL    BDOS
        EXX
        POP     HL
        EXX
        POP     BC
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
chkstk: LD      (SPTMP),SP
        LD      A,(SPTMP+1)
        CP      DSPAGE
        JR      NZ,e_stack
        EXX                     ; the return stack: in its page, and not
        LD      A,L             ;   above its empty position (an underflow
        CP      RSTOP&0FFh+1    ;   would stay inside the page, in the
        LD      A,H             ;   guard band)
        EXX
        JR      NC,e_rstack
        CP      RSPAGE
        RET     Z
        JR      e_rstack

; chkbrk: a waiting key is read now; Ctrl-C stops the program, anything
; else is held for the next '?'.
chkbrk: CALL    getk
        RET     Z
        CP      3
        JR      Z,e_break
        LD      (KEYBUF),A
        RET

; chkst: stop unless HL is in the program's own space: from the letter page
; up to the heap limit (the OS, or HEAPLIM), so the interpreter's stacks and
; whatever lies above the limit are safe. Memory above the heap top but
; below the limit is the program's own: Tiny BASIC keeps its lines there.
; Keeps every register.
chkst:  PUSH    AF
        LD      A,H
        CP      LETPAGE
        JR      C,e_store
        ENDIF
        IF      CHECKED*(1-CPM)
        CP      HEAPLIM
        JR      NC,e_store
        ENDIF
        IF      CHECKED*CPM
        LD      A,(0007h)       ; the BDOS page is the heap limit
        DEC     A
        CP      H
        JR      C,e_store
        ENDIF
        IF      CHECKED
        POP     AF
        RET

; chkhp: stop if working out the new heap top carried (a negative count
; wraps: too big), or if the new top in HL is not below the limit page.
chkhp:  JR      C,e_heap
        ENDIF
        IF      CHECKED*(1-CPM)
        LD      A,H
        CP      HEAPLIM
        RET     C
        ENDIF
        IF      CHECKED*CPM
        LD      A,(0007h)
        DEC     A
        CP      H
        RET     NC
        ENDIF
        IF      CHECKED
; Error entries. Each loads its letter and then hides the next entry inside
; a 3-byte LD HL,nn (the 21h), so they all fall through to `error`.
e_heap: LD      A,'H'           ; heap past the limit
        DB      21h
e_store:LD      A,'W'           ; write outside the program's space
        DB      21h
e_stack:LD      A,'S'           ; data stack over or under
        DB      21h
e_rstack:LD     A,'R'           ; return stack over or under
        DB      21h
e_break:LD      A,'B'           ; Ctrl-C
        DB      21h
e_brack:LD      A,'D'           ; bad character after [
; error: print the letter in A, " @ " and the offset in the program of the
; character just read, then end. For example: S @ 245
error:  LD      SP,DSTOP        ; the stacks may be wrecked: start clean
        RST     28h
        LD      A,' '
        RST     28h
        LD      A,'@'
        RST     28h
        LD      A,' '
        RST     28h
        LD      HL,(0-PROG-1)&0FFFFh ; minus the address of the character
        ADD     HL,BC           ;   just read: HL = its offset
        CALL    pdec
        JP      endprog
        ENDIF

; =============================================================================
;  The line editor (EDITOR = 1)
;
;  The interpreter starts here, and a program that ends comes back here. Type
;  a line and press Return:
;
;    n text    put the text in as line n; the lines from n on move down.
;              A number past the end adds the line at the end.
;    n         take line n out
;    0         list the program
;    anything that does not start with a digit is run at once, as B8Script
;
;  To run the program, jump to it from such a line:  33536{]   (33536 is
;  PROG, 8300h). Lines are counted, not numbered: there are no line numbers in
;  the text. Line numbers go from 1 to 128, a line holds 125 characters, and
;  nothing is checked. The text is stored as it is typed, each line ending in
;  CR LF, at PROG; the space after the line number is stored too.
;
;  A line is put in one character at a time, each one rippling the rest of
;  the program up by a byte: small code, but slow in a long program.
;
;  Things to know:
;    - Reset empties the program.
;    - The list shows no line numbers and only the first 128 lines. A line
;      number above 128 lists part of the program on its way to the line.
;    - Words and variables last from one line to the next. A word's address
;      points into the program, so run the program again after editing it.
;    - Nothing is printed between a program's output and what is typed next.
;    - A line run at once sits in the line buffer, which -n? also reads into:
;      a line that calls -n? and carries on afterwards runs what was typed.
;      (A program started with {] never comes back to the line, so it may.)
; =============================================================================
        IF      EDITOR
; a line number came first: L = the number, BC -> what follows it
ed1:    LD      D,L             ; D counts down to the line wanted. From 0 it
        LD      HL,PROG         ;   wraps to FFh: bit 7 of D makes nxl list.
f1:     DEC     D
        JR      Z,found
        CALL    nxl             ; step over one line
        OR      A
        JR      NZ,f1           ; (A = 0: that was the end of the text)
found:  LD      A,(BC)          ; HL -> line n, or the end of the text
        CP      13
        JR      Z,del           ; nothing after the number: take the line out
; Put the typed text in at HL: CR, LF and all, up to the NUL after them.
ins:    LD      A,(BC)
        INC     BC
        OR      A
        JR      Z,edit
        PUSH    HL
        LD      D,A             ; D = the byte to put down
in1:    LD      A,(HL)          ; pick up the byte that was there,
        LD      (HL),D          ;   put ours down,
        INC     HL
        LD      D,A             ;   and carry the old one on,
        OR      A
        JR      NZ,in1          ;   until the NUL has been moved
        LD      (HL),A          ; the new NUL
        POP     HL
        INC     HL
        JR      ins
; Take the line at HL out: copy everything after it down over it.
del:    PUSH    HL
        CALL    nxl             ; HL -> the next line (D is 0 here: no listing)
        POP     DE
de1:    LD      A,(HL)
        LD      (DE),A
        INC     HL
        INC     DE
        OR      A
        JR      NZ,de1          ; and fall into the editor

edit:   LD      SP,DSTOP
        LD      L,83h           ; (minus 125)
        CALL    rdline          ; HL -> the CR that ended the line
        INC     L
        LD      (HL),10         ; a LF after it,
        DEC     L               ; (D is FDh after rdline: bit 7 is set, so
        CALL    nxl             ;   nxl echoes the CR LF as a new line)
        LD      (HL),0          ;   and a NUL after that
        LD      BC,LINEBUF
        CALL    rdnum           ; HL = the number it starts with, BC -> after
        LD      A,C             ; C is still 80h if there was no number:
        ADD     A,A             ;   only then is twice it 0
        JR      NZ,ed1          ; there was a number
        ; No number: run the line where it is (BC = LINEBUF).
; st0: start running at BC. The heap starts after the stored program's NUL.
st0:    LD      HL,PROG
        XOR     A
st1:    CP      (HL)
        INC     HL
        JR      NZ,st1
        LD      (HEAP),HL
        EXX
        LD      HL,RSTOP        ; the return stack is empty
        EXX
        RST     30h             ; (its return address is thrown away)

; nxl: step HL over one line, to just past its LF, and return A = 10; or stop
; at the NUL that ends the text and return A = 0. If bit 7 of D is set, print
; the line on the way.
nxl:    LD      A,(HL)
        OR      A
        RET     Z
        BIT     7,D
        JR      Z,nx2
        RST     28h
nx2:    LD      A,(HL)
        INC     HL
        CP      10
        JR      NZ,nxl
        RET
        ENDIF

; =============================================================================
;  CP/M startup (the generic build starts at address 0: see st0)
; =============================================================================
        IF      CPM
        ; The RAM pages follow the image; the heap may grow to the BDOS.
start:  LD      HL,vecs         ; the RST routines go down into page zero
        LD      DE,0008h
        LD      BC,vecend-vecs
        LDIR
        LD      DE,005Ch        ; open the file named on the command line
        LD      C,15            ; (no such file: the first read fails too,
        CALL    BDOS            ;   and the program is empty)
        LD      DE,PROG
ld1:    PUSH    DE
        LD      C,26            ; set the DMA address
        CALL    BDOS
        LD      DE,005Ch
        LD      C,20            ; read the next 128 bytes
        CALL    BDOS
        POP     HL              ; HL = the address this record went to
        OR      A
        JR      NZ,ld2
        LD      DE,128
        ADD     HL,DE
        EX      DE,HL
        JR      ld1
ld2:    LD      (HL),0          ; the end of the file counts as NUL
        INC     HL              ; the heap starts after it
        LD      BC,PROG         ; the IP
        JP      st2
        ENDIF

        IF      CPM
; RAM pages, after the image
RSPAGE  EQU     (imgend + 255) / 256
DSPAGE  EQU     RSPAGE + 1
LETPAGE EQU     RSPAGE + 2
PROG    EQU     LETPAGE*256 + 256
        ENDIF
imgend:
