; =============================================================================
;  B8Script interpreter for the Z80
;  Spec: docs/b8script.md (2026-11-21).
;
;  Three switches, set in the EQU lines below:
;    CPM      0 = generic ROM build (KEY/CONOUT at fixed addresses)
;             1 = CP/M 2.2 .COM file: loads the file named on the command line
;    EDITOR   1 = with a small line editor built in (see the end of this
;                 file). It goes with either setting of the other two.
;    CHECKED  0 = no checks (spec: the programmer is responsible)
;             1 = starts with every variable at 0 and every word undefined,
;                 and stops on every error in the spec's table (and Ctrl-C)
;                 with a four-line report: the letter and the place as line
;                 and column, the text there, and both stacks. See `error`.
;
;  Assembler: asm80 (https://maly.github.io/asm80-node/), Z80 mode.
; =============================================================================

CPM     EQU     0               ; 1 = CP/M .COM build
CHECKED EQU     0               ; 1 = checked build
EDITOR  EQU     0               ; 1 = with the line editor
EDGEN   EQU     EDITOR*(1-CPM)  ; (the generic build with the editor)
TABP0   EQU     EDGEN*(1-CHECKED) ; (the build with its table in page zero)

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
BASE    EQU     0100h           ; where the image starts
        ENDIF
        IF      CPM*(1-EDITOR)
EXIT    EQU     0000h           ; warm boot
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
HEAP    EQU     LET+7Ch         ; the heap pointer
RSAVE   EQU     LET+34h         ; gap after Z: return stack pointer, saved
KEYBUF  EQU     LET+36h         ;   around machine code; a held-back key;
NPEND   EQU     LET+38h         ;   minus the address of the program's end
                                ;   (the heap's first byte), for the checked '_'
LBHDR   EQU     LET+7Eh         ; CP/M BDOS 10 header: max, count
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
        IF      (1-CPM)*(1-EDITOR)*CHECKED
        XOR     A               ; 00  reset. (This byte, AFh, is also what an
        ENDIF                   ;     undefined word runs into: see e_hi.)
        IF      1-EDGEN
        LD      SP,DSTOP        ; 00  reset, or the start of the .COM file
        ENDIF
        IF      (1-CPM)*(1-EDITOR)*(1-CHECKED)
        LD      BC,PROG         ; 03  the IP
        JR      st0             ; 06  (the rest of the startup is close by)
        ENDIF
        IF      (1-CPM)*(1-EDITOR)*CHECKED
        JR      init            ; 04  (the rest of the startup is close by)
        DW      0               ; 06  spare
        ENDIF
        IF      EDGEN
        XOR     A               ; 00  reset: no program yet
        LD      (PROG),A
        ENDIF
        IF      EDGEN*(1-CHECKED)
        JP      edit            ; 04
        ENDIF
        IF      EDGEN*CHECKED
        JP      init            ; 04  (and no key held back)
        ENDIF
        IF      EDGEN
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
        IF      1-CHECKED
        JR      NC,next0        ; 7Fh-FFh: ignored
        ENDIF
        IF      CHECKED
        JR      Z,next0         ; 7Fh, DEL: ignored
        JP      NC,e_hi         ; 80h-FFh: reserved
        ENDIF
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
        LD      D,PTAB / 256    ; (0 if the table is in page zero)
        CP      (PTAB & 0FFh) + NPG1 ; carry: one of the first NPG1
        LD      A,(DE)
        LD      E,A             ; the handler's low byte
        IF      (1-CPM)*(1-TABP0)
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
; A checked build first clears the lower half of the letter page (A = 0):
; every variable starts at 0, every word cell holds 0000h, the address an
; undefined word is caught at (see e_hi), and no key is held back.
        IF      (1-CPM)*(1-EDITOR)*CHECKED
init:   LD      HL,LET
ini1:   LD      (HL),A
        INC     L
        JP      P,ini1          ; +00h to +7Fh
        LD      BC,PROG         ; the IP
        ENDIF
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
        ENDIF
        IF      CHECKED*(1-EDITOR)
        RST     20h             ; minus the heap's first address: '_' may not
        LD      (NPEND),HL      ;   release below it
        ENDIF
        IF      1-EDITOR
        EXX
        LD      HL,RSTOP        ; the return stack is empty
        EXX
        RST     30h             ; (its return address is thrown away)
        ENDIF

; In the unchecked generic editor build the table is here, in the first
; page, which saves loading D twice. (The other builds have no room for it
; here: theirs is further down.)
        IF      TABP0
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

; '_' ( n -- addr ): the heap pointer moves by n, a signed count (the add is
; the same either way); TOS is the old pointer.
h_alloc:LD      DE,(HEAP)
        IF      CHECKED*CPM
        LD      A,H             ; the count's sign, for chkhp
        ENDIF
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
hx1:    LD      (HL),A          ; the high digit goes in first ...
        CALL    hexc
        JR      NC,hx2          ; odd digit: consumed, and the RET below
        RLD                     ;   overwrites it
        INC     HL              ; ... and RLD shifts it up under the low one
        CALL    hexc
        JR      C,hx1
hx2:    LD      (HL),0C9h       ; (never range-checked: the spec says so)
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
; (The unchecked build takes anything that is not a letter as the space; the
; checked build stops on it.)
h_def:  LD      A,(BC)
        INC     BC
        SUB     'A'             ; a letter gives 0-25 or 32-57: lowercase
        LD      E,A             ;   lands 64 bytes up
        AND     0DFh            ; fold case
        CP      26
        JR      NC,def2         ; not a letter
        SLA     E
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
        CP      ' '-'A'+256
        JP      NZ,e_brack      ; anything but a letter or a space
        ENDIF
        PUSH    HL              ; an anonymous block: push its address
        LD      H,B
        LD      L,C
skipnx:
        IF      CHECKED
        DEC     BC              ; back onto the letter, so that skip finds its
        ENDIF                   ;   opener, the '[', just before where it starts
skipo:  CALL    skip
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
        JR      Z,skipo
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

; '/' ( a b -- q r ): the remainder is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Dividing by zero returns two cells of no meaning; the checked build
; stops on it.
h_div:
        IF      CHECKED
        LD      A,H
        OR      L
        JP      Z,e_zero
        ENDIF
        POP     DE              ; DE = a, HL = b
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
        POP     BC
        PUSH    DE              ; q under r
        RST     30h

; ---- stack and storage -----------------------------------------------------

h_dup:  PUSH    HL              ; ':'
        RST     30h

h_swap: EX      (SP),HL         ; '%'
        RST     30h

; (The checked build tests the address before it takes the value off the
; stack, so that an error report shows both.)
h_cstore:                       ; '.' ( c addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        POP     DE
        LD      (HL),E
h_drop: RST     18h             ; ';' is this one byte

h_store:                        ; '!' ( n addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        POP     DE
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
        IF      CHECKED
        OR      A               ; 0: the text ran out before the closing quote
        JP      Z,e_quote
        ENDIF
        RST     30h

; '$' prints the string at TOS, decoding escapes: '/' plus a character
; clears that character's bit 6 (/M is CR, /` is space; '/' and '"' have no
; bit 6, so // and /" give themselves).
        IF      1-CHECKED
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
        ENDIF
        IF      CHECKED
; (The checked build has the loop as a routine, prstr, which the error
; report uses too. The address is kept on the stack meanwhile: a report
; shows the stack as it was before the '$'.)
h_print:PUSH    HL
        CALL    prstr
        POP     DE
        RST     18h
        ENDIF

h_emit: LD      A,L             ; "'"
        RST     28h
pr9:    RST     18h

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  PUSH    BC
        CALL    psgn
        POP     BC
        RST     18h

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. The buffer
;          holds 127 characters and the CR: a bigger count is taken as 127.
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
line:   LD      DE,127          ; TOS is minus the count: adding 127 carries
        ADD     HL,DE           ;   only for 1 to 127, and leaves 127 - count
        SBC     A,A
        AND     L               ; (0 for a count that is too big)
        XOR     127             ; A = the count, 127 at most
        ENDIF
        IF      CPM*EDITOR
        CALL    rdline          ; (the editor calls rdline too)
        LD      L,LINEBUF & 0FFh
        RST     30h
; rdline: read a line of at most A characters; HL -> the CR that ends it
rdline:
        ENDIF
        IF      CPM
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
        ENDIF
        IF      CPM*(1-EDITOR)
        LD      L,LINEBUF & 0FFh
        RST     30h
        ENDIF
        IF      CPM*EDITOR
        RET
        ENDIF
        IFN     CPM
        ; Generic: Backspace takes the last character back (and is echoed as
        ; it is), CR ends (stored, not echoed), every other key is stored and
        ; echoed until the line is full. The line buffer starts at offset 80h
        ; of its page, so L alone is the place in the line: D holds the L of
        ; a full line.
        ENDIF
        IFN     CPM
line:   LD      DE,127          ; TOS is minus the count: adding 127 carries
        ADD     HL,DE           ;   only for 1 to 127, and leaves 127 - count
        SBC     A,A
        AND     L               ; (0 for a count that is too big)
        CPL
        LD      D,A             ; D = the L of a full line: 80h + count, FFh
        ENDIF                   ;   at most
        IF      EDGEN
        CALL    rdline          ; (the editor calls rdline too)
        LD      L,LINEBUF & 0FFh
        RST     30h
; rdline: read a line that is full when L reaches D; HL -> the CR that ends it
rdline:
        ENDIF
        IFN     CPM
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
        IF      EDGEN
        RET
        ENDIF

; =============================================================================
;  More routines (no handler starts past this point)
; =============================================================================

; udiv: unsigned HL / DE (DE <= 8000h). Returns HL = quotient, DE = remainder.
; Uses A, BC; the caller saves the IP. The dividend shifts up through A:C
; while the quotient bits arrive at the bottom of C.
; Dividing by 2 is one shift (the spec wants that fast).
udiv:   LD      A,E
        XOR     2
        OR      D
        JR      NZ,udv0
        SRL     H
        RR      L               ; the quotient
        ADC     A,A
        LD      E,A             ; the remainder: the bit that fell out (D is 0)
        RET
udv0:   LD      A,H
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
        IF      1-CHECKED
ss0:    INC     BC
skipstr:LD      A,(BC)
        INC     BC
        CP      '/'
        JR      Z,ss0
        CP      22h
        JR      NZ,skipstr
        RET
        ENDIF
        IF      CHECKED
; The checked build never steps over a NUL: if the text runs out first it
; returns A = 0 with the IP on the NUL.
skipstr:LD      A,(BC)
        OR      A
        RET     Z
        INC     BC
        CP      22h
        RET     Z
        CP      '/'
        JR      NZ,skipstr
        LD      A,(BC)          ; the escaped character
        OR      A
        RET     Z
        INC     BC
        JR      skipstr
        ENDIF

; skip: read past text to the closer at this level, and return A = 0 if it
; was ')' and 2 if it was ']'. Brackets of both kinds count together;
; strings are stepped over whole. A NUL first ends the program (for '\' with
; no closer; anything else that runs into the NUL had unbalanced brackets
; anyway). D counts the open levels, starting at 1 for the one we are in:
; skip sets it to 0 and falls through the INC that an opener comes back to.
;
; The checked build also looks at the character the skip was started by,
; which is always the one just before where it starts: '(' must end at ')',
; '[' at ']', and neither may run into the NUL (N); a string with no closing
; quote counts as running into it. '\' takes either closer. IX keeps the
; place where the skip started, for the report.
skip:
        IF      CHECKED
        PUSH    BC
        POP     IX
        DEC     BC
        LD      A,(BC)
        INC     BC
        LD      E,A             ; E = the opener: ( [ or \
        ENDIF
        LD      D,0
sk3:    INC     D               ; an opener: one deeper
sk1:    LD      A,(BC)
        IF      1-CHECKED
        INC     BC
        OR      A
        JP      Z,endprog
        ENDIF
        IF      CHECKED
        OR      A
        JR      Z,sk6           ; (the IP stays on the NUL)
        INC     BC
        ENDIF
        CP      22h
        CALL    Z,skipstr       ; leaves A = 22h, which matches nothing below
        SUB     '('             ;   (or 0, and then the NUL is read next)
        JR      Z,sk3
        DEC     A               ; ')'
        JR      Z,sk4
        SUB     '['-')'
        JR      Z,sk3
        CP      ']'-'['
        JR      NZ,sk1
sk4:    DEC     D
        IF      1-CHECKED
        RET     Z               ; the closer at this level
        JR      sk1
        ENDIF
        IF      CHECKED
        JR      NZ,sk1
        LD      D,A             ; the closer at this level: 0 or 2. Bit 1 of the
        XOR     E               ;   opener is 0 for '(' and 1 for '[', and only
        AND     6               ;   '\' has bit 2: so this is 2 for the wrong
        CP      2               ;   closer, and only then
        LD      A,D
        RET     NZ
        JR      sk7
sk6:    BIT     2,E             ; the text ran out:
        JP      NZ,endprog      ;   '\' with no closer ends the program
sk7:    PUSH    IX              ; N. The place is the opener
        POP     BC
        LD      A,'N'
        JP      errp            ; (errp drops skip's return address)
        ENDIF

; psgn: print HL as a signed number. Uses BC.
psgn:   BIT     7,H
        JR      Z,pdec
        LD      A,'-'
        RST     28h
        RST     20h
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
        IF      1-TABP0
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
; chkst: stop unless HL is in the program's own space: from the letter page
; up to the heap limit (the OS, or HEAPLIM), so the interpreter's stacks and
; whatever lies above the limit are safe. Memory above the heap top but
; below the limit is the program's own: Tiny BASIC keeps its lines there.
; It is the page of HL + 1 that is tested, so that one test serves both
; bytes of a cell: the last byte below the limit can't be stored to with '.'.
; Keeps HL and BC.
chkst:  INC     HL
        LD      A,H
        DEC     HL
        CP      LETPAGE
        JR      C,chs1
        ENDIF
        IF      CHECKED*(1-CPM)
        CP      HEAPLIM
        RET     C
        ENDIF
        IF      CHECKED*CPM
        LD      E,A
        LD      A,(0007h)       ; the BDOS page is the heap limit
        DEC     A
        CP      E
        RET     NC
        ENDIF
        IF      CHECKED
chs1:   JP      e_store

; chkhp: HL = the new heap top, DE = the old one, the carry is from adding
; the count. Stop if the top is not below the limit page, or is below the
; program's end.
chkhp:
        ENDIF
        IF      CHECKED*CPM
        ; With this much room a top that wrapped round can land back in
        ; range, so the add is tested too: growing (A, the count's high
        ; byte, is positive) must not carry, and releasing must.
        RRA                     ; the carry comes in above the sign:
        ADD     A,40h           ;   bit 7 = carry XOR sign
        ADD     A,A
        JR      C,e_heap
        LD      A,(0007h)
        DEC     A
        CP      H
        JR      C,e_heap
        ENDIF
        IF      CHECKED*(1-CPM)
        ; (Here the program's space is under 32K, so a top that wrapped
        ; round always falls outside it.)
        LD      A,H
        CP      HEAPLIM
        JR      NC,e_heap
        ENDIF
        IF      CHECKED
        PUSH    DE
        EX      DE,HL
        LD      HL,(NPEND)
        ADD     HL,DE           ; carry: at or above the program's end
        EX      DE,HL
        POP     DE
        RET     C
e_heap: OR      A               ; put the count back in TOS for the report
        SBC     HL,DE
        JP      e_heap1

; prstr: print the string at HL, to its closing quote, decoding '/' (this is
; '$', and the error report's texts). A NUL first is an error: Q.
prstr:  LD      A,(HL)
        INC     HL
        CP      22h
        RET     Z
        OR      A
        JR      Z,e_dollar
        CP      '/'
        JR      NZ,prs1
        LD      A,(HL)
        INC     HL
        AND     0BFh
prs1:   RST     28h
        JR      prstr
e_dollar:POP    DE              ; '$' ran into a NUL: drop the return address,
        POP     HL              ;   and put the string's address back in TOS
        LD      A,'Q'
        JP      error

; pmsg: print the text that follows the CALL, to its closing quote. Keeps HL.
; pnl: the same, on a new line.
pnl:    LD      A,13
        RST     28h
        LD      A,10
        RST     28h
pmsg:   EX      (SP),HL
        CALL    prstr
        EX      (SP),HL
        RET

; chkstk: both stacks are checked once per character, not in every handler.
; The data stack is right when SP lies in the 256 bytes below DSTOP: adding
; the constant carries if it is above (cells were popped that were never
; pushed), and leaves a high byte of FFh if it is in range. Errors are found
; a character late at most: the bytes above DSTOP and the guard band below
; the page take what happens meanwhile. DE is free between characters.
chkstk: EX      DE,HL
        LD      HL,(1-DSTOP)&0FFFFh ; (SP is 2 lower here: the call)
        ADD     HL,SP
        EX      DE,HL
        JR      C,e_under
        INC     D
        JR      NZ,e_over
        EXX                     ; the return stack: in its page (or it has
        LD      A,H             ;   overflowed), and not above its empty
        CP      RSPAGE          ;   position (an underflow stays inside the
        LD      A,L             ;   page, in the guard band)
        EXX
        JR      NZ,e_rover
        CP      RSTOP&0FFh+1
        RET     C
        EXX                     ; return stack underflow: it counts as empty
        LD      HL,RSTOP
        EXX
        LD      A,'r'
        JR      errp
e_rover:LD      A,'R'           ; return stack overflow
        DB      11h             ; (LD DE,nn hides the next entry)
e_over: LD      A,'S'           ; data stack overflow
        JR      errp
e_under:LD      SP,DSTOP        ; data stack underflow: it counts as empty
        LD      A,'s'
        JR      error

; chkbrk: a waiting key is read now; Ctrl-C stops the program, anything
; else is held for the next '?'.
chkbrk: CALL    getk
        RET     Z
        CP      3
        JR      Z,e_break
        LD      (KEYBUF),A
        RET

; e_hi: the inner loop read a reserved byte, 80h-FFh: X. But a word cell that
; was never defined still holds 0000h, and the byte there is a reserved one
; in every build (AFh or C3h): if the IP is in page zero, this was a call of
; an undefined word. The call is undone, so the place is the call itself.
e_hi:   INC     B
        DJNZ    e_resv          ; (B is as it was, and is not 0)
        RST     08h
        LD      B,D
        LD      C,E
        LD      A,'U'
        JR      error
; Error entries. Each loads its letter and then hides the next entry inside
; a 3-byte LD DE,nn (the 11h), so they all fall through to `error`.
e_break:LD      A,'B'           ; Ctrl-C (found inside chkbrk)
        DB      11h
e_heap1:LD      A,'H'           ; heap (found inside chkhp)
        DB      11h
e_store:LD      A,'O'           ; a store outside the program's space (chkst)
; errp: an error found inside a routine: drop its return address first.
errp:   POP     DE
        JR      error
e_quote:LD      B,H             ; an unclosed string: HL is its address, one
        LD      C,L             ;   past the opening quote, which is the place
        LD      A,'Q'
        DB      11h
e_resv: LD      A,'X'           ; a reserved byte outside a string
        DB      11h
e_zero: LD      A,'Z'           ; dividing by zero
        DB      11h
e_brack:LD      A,'W'           ; bad character after [

; error: the report, then the end. A = the letter, BC = one past the place,
; HL = TOS, and both stacks as the report is to show them:
;
;   Err X @ line,col
;   up to 16 characters of the text from the place
;   Stk n: the top 8 cells at most, bottom to top
;   Rtn n
error:  PUSH    HL              ; now the whole data stack is in memory
        LD      E,A
        CALL    pnl
        DB      "Err ",22h
        LD      A,E
        RST     28h
        CALL    pmsg
        DB      " @ ",22h
        DEC     BC              ; BC = the place
        ; The line and column. A place below the program is in the line
        ; buffer: line 0. Otherwise count the LFs from the program's start;
        ; DE = the line's number, HL = where it starts.
        LD      HL,LINEBUF
        LD      DE,0
        LD      A,B
        CP      PROG/256
        JR      C,er3
        INC     H
        LD      L,E             ; HL = PROG
er1:    INC     DE              ; a new line starts at HL
        PUSH    HL
er2:    LD      A,L
        SUB     C
        LD      A,H
        SBC     A,B
        JR      NC,er2x         ; reached the place
        LD      A,(HL)
        INC     HL
        CP      10
        JR      NZ,er2
        POP     AF
        JR      er1
er2x:   POP     HL
er3:    PUSH    BC
        PUSH    HL
        EX      DE,HL
        CALL    pdec            ; the line
        LD      A,','
        RST     28h
        POP     DE
        POP     HL
        PUSH    HL
        OR      A
        SBC     HL,DE
        INC     HL
        CALL    pdec            ; the column
        CALL    pnl
        DB      22h
        POP     HL              ; the text, as it is: 16 characters, or fewer
        LD      B,16            ;   if the line or the program ends first
er4:    LD      A,(HL)
        INC     HL
        OR      A
        JR      Z,er5
        CP      13
        JR      Z,er5
        CP      10
        JR      Z,er5
        ENDIF
        IF      CHECKED*CPM
        CP      1Ah             ; (the ^Z that pads a file's last record ends
        JR      Z,er5           ;   the text too: some terminals clear the
        ENDIF                   ;   screen on it)
        IF      CHECKED
        RST     28h
        DJNZ    er4
er5:    CALL    pnl
        DB      "Stk ",22h
        LD      HL,DSTOP-2      ; (the cell at DSTOP-2 was pushed with the
        OR      A               ;   first value and holds nothing)
        SBC     HL,SP
        CALL    phalf           ; the depth
        LD      A,':'
        RST     28h
        LD      A,C
        CP      9
        JR      C,er6
        CALL    pmsg
        DB      " ...",22h
        LD      C,8
er6:    LD      H,0             ; C = the number of cells to show
        LD      L,C
        ADD     HL,HL
        ADD     HL,SP           ; HL -> just above the deepest of them
        INC     C
er7:    DEC     C
        JR      Z,er8
        DEC     HL
        LD      D,(HL)
        DEC     HL
        LD      E,(HL)
        PUSH    HL
        PUSH    BC
        LD      A,' '
        RST     28h
        EX      DE,HL
        CALL    psgn
        POP     BC
        POP     HL
        JR      er7
er8:    CALL    pnl
        DB      "Rtn ",22h
        EXX
        PUSH    HL
        EXX
        POP     DE
        LD      HL,RSTOP
        OR      A
        SBC     HL,DE
        CALL    phalf
        CALL    pnl
        DB      22h
        JP      endprog
; phalf: print half of HL, and leave it in C
phalf:  SRL     H
        RR      L
        PUSH    HL
        CALL    pdec
        POP     BC
        RET
        ENDIF

; =============================================================================
;  The line editor (EDITOR = 1)
;
;  The interpreter starts here, and a program that ends comes back here. Type
;  a line and press Return:
;
;    n text    put the text in as line n; the lines from n on move down.
;              A number past the end, or 0, adds the line at the end.
;    n         take line n out
;    0         run the program
;    -n        list the program from line n on (-1 lists all of it). Any key
;              stops the list until another key is pressed; Ctrl-C ends it.
;    anything else is run at once, as B8Script. (Start such a line with a
;    space if it would begin with a digit or a minus sign.)
;
;  Lines are counted, not numbered: the text holds no line numbers, and the
;  list shows each line's place. There can be 65535 lines. A typed line holds
;  125 characters, the line number and the one character after it included;
;  that character is not stored. The text is kept as it is typed, each line
;  ending in CR LF, at PROG. Nothing is checked.
;
;  With CPM = 1 the file named on the command line is the program to start
;  with (no file, or no such file: no program). Lines are read by BDOS 10, so
;  its editing keys work, and Ctrl-C as the first key of a line goes back to
;  CP/M. Nothing is written back: there is no command to save.
;
;  With CHECKED = 1 a program that is stopped (an error, or Ctrl-C) prints
;  its report and comes back here, with both stacks empty. The place is a
;  line and column of the program; in a line typed here it is line 0.
;
;  Things to know:
;    - Reset empties the program (generic builds).
;    - Words and variables last from one line to the next. A word's address
;      points into the program, so run the program again after editing it.
;    - Nothing is printed between a program's output and what is typed next.
;    - A line run at once sits in the line buffer, which -n? also reads into:
;      a line that calls -n? and carries on afterwards runs what was typed.
;      (The stored program never comes back to the line, so it may.)
; =============================================================================
        IF      EDGEN*CHECKED
; Reset (A = 0): clear the lower half of the letter page. Every variable
; starts at 0, every word cell holds 0000h, the address an undefined word is
; caught at (see e_hi), and no key is held back.
init:   LD      HL,LET
ini1:   LD      (HL),A
        INC     L
        JP      P,ini1          ; +00h to +7Fh
        JR      edit
        ENDIF
        IF      EDITOR
; -n: list from line n. DE = the number of the line at HL.
list:   INC     BC
        CALL    rdnum           ; HL = n
        PUSH    HL
        CALL    find
        POP     DE
li1:    LD      A,(HL)
        OR      A
        JR      Z,edit          ; the end of the text
        CALL    getk
        JR      Z,li3           ; no key: carry on
        CP      3
        JR      Z,edit          ; Ctrl-C
li2:    CALL    getk            ; any other key: wait for one more
        JR      Z,li2
        CP      3
        JR      Z,edit
li3:    PUSH    HL
        PUSH    DE
        EX      DE,HL
        CALL    pdec            ; the line's number,
        LD      A,' '
        RST     28h             ;   a space,
        POP     DE
        POP     HL
        INC     DE
        CALL    prl             ;   and the line
        JR      li1

; Take line n (in HL) out: copy everything after it down over it.
del:    CALL    find
        LD      D,H
        LD      E,L
        CALL    nxl             ; HL -> the next line
de1:    LD      A,(HL)
        LD      (DE),A
        INC     HL
        INC     DE
        OR      A
        JR      NZ,de1          ; and fall into the editor

edit:   LD      SP,DSTOP
        ENDIF
        IF      EDITOR*CPM*CHECKED
        ; A key that the break check held back while a program ran is let
        ; go: BDOS 10 would not see it, and it would turn up in the next
        ; program that asked for a key. (This also serves at the start.)
        XOR     A
        LD      (KEYBUF),A
        ENDIF
        IF      EDGEN
        LD      D,0FDh          ; 125 characters at most
        ENDIF
        IF      EDITOR*CPM
        LD      A,125
        ENDIF
        IF      EDITOR
        CALL    rdline          ; HL -> the CR that ended the line
        INC     L
        LD      (HL),10         ; a LF after it,
        DEC     L
        CALL    prl             ; (print the CR LF: a new line)
        LD      (HL),0          ;   and a NUL after that
        PUSH    HL              ; the end of what was typed
        LD      BC,LINEBUF
        LD      A,(BC)
        CP      '-'
        JR      Z,list
        CALL    rdnum           ; HL = the number it starts with, BC -> after
        LD      A,C             ; C is still 80h if there was no number:
        ADD     A,A             ;   only then is twice it 0
        JR      Z,st0           ; no number: run the line where it is
        LD      A,(BC)
        SUB     13
        JR      NZ,ins          ; text follows the number
        OR      H               ; the number alone:
        OR      L
        JR      NZ,del          ;   not 0: take that line out
        LD      BC,PROG         ;   0: run the program

; st0: start running at BC. The heap starts after the stored program's NUL.
st0:    POP     HL              ; (the end of what was typed: the stack is empty)
        LD      HL,PROG
        XOR     A
st1:    CP      (HL)
        INC     HL
        JR      NZ,st1
        LD      (HEAP),HL
        ENDIF
        IF      EDITOR*CHECKED
        RST     20h             ; minus the heap's first address: '_' may not
        LD      (NPEND),HL      ;   release below it
        ENDIF
        IF      EDITOR
        EXX
        LD      HL,RSTOP        ; the return stack is empty
        EXX
        RST     30h             ; (its return address is thrown away)

; Put the typed text in as line n (in HL): open a gap of its length there,
; CR and LF included, and copy it in.
ins:    CALL    find            ; HL -> where it goes
        INC     BC              ; step over the one character after the number
        POP     DE              ; the end of what was typed
        LD      A,E
        SUB     C               ; A = the length of the text, with its CR LF
        PUSH    BC              ; the text
        LD      C,A
        LD      B,0
        PUSH    BC              ; its length
        LD      D,H
        LD      E,L             ; DE = where it goes
        XOR     A
        LD      C,A             ; BC = 0: CPIR looks as far as it needs to
        CPIR                    ; HL -> one past the program's NUL
        SBC     HL,DE           ; the number of bytes to move up, NUL included
        LD      B,H
        LD      C,L
        ADD     HL,DE
        DEC     HL              ; HL -> the NUL
        EX      DE,HL
        EX      (SP),HL         ; HL = the length; where it goes is kept
        PUSH    HL
        ADD     HL,DE           ; the NUL's new place
        EX      DE,HL
        LDDR                    ; move the rest of the program up
        POP     BC              ; the length
        POP     DE              ; where it goes
        POP     HL              ; the text
        LDIR
        JR      edit

; find: HL = a line number. Returns HL -> that line, or -> the NUL at the end
; of the text if there are fewer lines (or the number is 0). Keeps BC.
find:   EX      DE,HL
        LD      HL,PROG
fi1:    DEC     DE
        LD      A,D
        OR      E
        RET     Z
        CALL    nxl
        JR      NZ,fi1
        RET

; nxl: step HL over one line, to just past its LF (and return not-zero), or
; stop at the NUL that ends the text (and return zero).
nxl:    LD      A,(HL)
        OR      A
        RET     Z
        INC     HL
        CP      10
        JR      NZ,nxl
        OR      A
        RET

; prl: print the line at HL, to its LF; HL -> just past it.
prl:    LD      A,(HL)
        RST     28h
        LD      A,(HL)
        INC     HL
        CP      10
        JR      NZ,prl
        RET
        ENDIF

; =============================================================================
;  CP/M startup (the generic build starts at address 0: see st0)
; =============================================================================
        IF      CPM
        ; The RAM pages follow the image; the heap may grow to the BDOS.
start:
        ENDIF
        IF      CPM*CHECKED
        ; Clear the lower half of the letter page: every variable starts at
        ; 0, every word cell holds 0000h, the address an undefined word is
        ; caught at (see e_hi: the byte there is CP/M's JP, C3h), and no key
        ; is held back.
        LD      HL,LET
        XOR     A
ini1:   LD      (HL),A
        INC     L
        JP      P,ini1          ; +00h to +7Fh
        ENDIF
        IF      CPM
        LD      HL,vecs         ; the RST routines go down into page zero
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
ld2:
        ENDIF
        IF      CPM*(1-EDITOR)
        LD      (HL),0          ; the end of the file counts as NUL
        INC     HL              ; the heap starts after it
        LD      BC,PROG         ; the IP
        JP      st2
        ENDIF
        IF      CPM*EDITOR
        ; The editor wants the text to end where the file's text ends: at
        ; the first ^Z (1Ah), which pads a text file's last record. One more
        ; goes after the last record, so the search always stops. And every
        ; line must end in LF: a last line without one is given a CR LF.
        LD      (HL),1Ah
        LD      HL,PROG-1
        LD      A,10            ; (a file with no text needs nothing added)
tr1:    INC     HL
        LD      E,A             ; E = the character before this one
        LD      A,(HL)
        CP      1Ah
        JR      NZ,tr1
        LD      A,E
        CP      10
        JR      Z,tr2
        LD      (HL),13
        INC     HL
        LD      (HL),10
        INC     HL
tr2:    LD      (HL),0
        JP      edit
        ENDIF

        IF      CPM
; RAM pages, after the image
RSPAGE  EQU     (imgend + 255) / 256
DSPAGE  EQU     RSPAGE + 1
LETPAGE EQU     RSPAGE + 2
PROG    EQU     LETPAGE*256 + 256
        ENDIF
imgend:
