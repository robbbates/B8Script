; =============================================================================
;  B8Script interpreter for the Motorola 6809
;  Spec: docs/b8script.md (2026-10-09) plus the 2026-11-20 changes:
;        [x stores in a variable, "[ " pushes an anonymous block, any other
;        character after [ is an error, the heap pointer lives at z10+.
;        The string escape is '/' (it was '>').
;        Dividing by zero is not checked. -n? does no more editing than
;        Backspace.
;  Follows the design of the Z80 interpreter (z80/b8s-z80.asm).
;
;  Two builds, selected by the CHECKED line below (CPM is always 0: the 6809
;  has no CP/M; the line is kept only so that build.sh works):
;    CHECKED  0 = no checks (spec: "B8Script checks nothing")
;             1 = stops on stack overrun, Ctrl-C, heap past the limit, a store
;                 outside the program's own space, and a bad character after [,
;                 printing a letter and the place, like  S @ 245
;
;  Assembler: asm80, M6809 mode.
; =============================================================================

CPM     EQU     0               ; always 0 (no CP/M on the 6809)
CHECKED EQU     0               ; 1 = checked build

; -----------------------------------------------------------------------------
;  Register use, everywhere in the interpreter
;
;    Y    IP: the address of the next program character to read
;    U    the data stack pointer. The stack grows down and U points at the
;         top cell (TOS); nothing is cached in a register, because every
;         dispatch needs A, B and X as scratch. Cells are big-endian here.
;         (Only the stacks are big-endian: cells in RAM that the program can
;         see - variables, the heap pointer, anything @ and ! reach - are
;         little-endian, as the spec says, so @ and ! swap the bytes.)
;    S    the return stack. A word call is a plain push of Y. Entries are
;         2 bytes, big-endian. Handlers are called with JSR, so the return
;         address of the dispatcher is on top of S while a handler runs.
;    DP   the letter page, so the letter-page variables below cost 2-byte
;         direct addressing. Nothing else may change DP.
;    A B X are scratch. Every handler is entered by JSR and ends in RTS (one
;    byte). A handler that pushes or pops the return stack first pulls the
;    dispatcher's return address into X (PULS X) and ends with JMP ,X.
;
;  Dispatch (unchecked build). PTAB holds one byte per punctuation character:
;  the low byte of the handler's distance from PTAB. The handlers of the last
;  characters (in code order) start within 256 bytes after PTAB, the handlers
;  of the first NPG1 characters in the 256 bytes after that. The assembler
;  works NPG1 out from where five handlers landed, and testing/chktab09.py
;  checks the layout. The checked build is bigger than that reach, so its
;  table holds whole addresses instead.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
;  Memory map. Everything the interpreter writes is in four RAM areas:
;
;    8000h-80FFh  return stack, 127 entries; empty = 8100h; S stays inside
;    8100h-81FFh  data stack, 127 cells; empty = 8200h; U stays inside
;    8200h-82FFh  letter page (LET): A..Z at +00h..+33h, a..z at +40h..+73h
;                 (a word cell is always 64 bytes below its variable), the
;                 heap pointer at +7Ch (= z10+), interpreter variables in the
;                 gaps, and the -n? line buffer at +80h..+FFh
;    8300h-       PROG, the program text, NUL-terminated; the heap starts
;                 after the NUL and grows to HEAPLIM*256 (F000h)
;    F000h-       this image (ROM). The reset vector (FFFEh) must point to
;                 `start` (see the listing); the image does not contain it.
;    FF03h-FF0Bh  the console routines (CONOUT, KEY) and EXIT are supplied
;                 by the system and need no space here.
;
;  The stacks sit below the letter page, so "the program's own space" (what
;  the checked build lets ! and . write) is the single range LET..HEAPLIM*256.
; -----------------------------------------------------------------------------

; ---- generic machine: edit these to suit -----------------------------------
KEY     EQU     0FF06h          ; a waiting key in A, or A = 0 if none is
                                ;   waiting. The Z flag must match A (end the
                                ;   routine with TSTA / RTS, or a plain LDA).
CONOUT  EQU     0FF03h          ; print the character in A
EXIT    EQU     0FF09h          ; where to go when the program ends
;   Both are called with JSR. They may change A and CC and must preserve
;   B, X, Y, U and DP.
RSPAGE  EQU     80h
DSPAGE  EQU     81h
LETPAGE EQU     82h
PROG    EQU     8300h           ; where the loader puts the program text
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)

MSLOOP  EQU     20              ; n? inner loop count for about 1 ms; tune it
                                ; for your clock and your KEY routine

; letter-page layout (direct-page offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     7Ch             ; z10+, the heap pointer (little-endian)
KEYBUF  EQU     34h             ; gap after Z: a key held back by the break check
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSTOP   EQU     RSPAGE*256+100h ; empty return stack
DSTOP   EQU     DSPAGE*256+100h ; empty data stack

        ORG     0F000h

; =============================================================================
;  Checked build: the error report. It is here, ahead of the inner loop, so
;  that the loop's stack checks reach it with short branches.
; =============================================================================
        IF      CHECKED
; Error entries. Each loads its letter and then hides the next entry inside
; a 3-byte CMPX # (the 8Ch), so they all fall through to `error`.
e_stack:LDA     #'S'            ; data stack over or under
        FCB     8Ch
e_rstack:LDA    #'R'            ; return stack over or under
        FCB     8Ch
e_break:LDA     #'B'            ; Ctrl-C
        FCB     8Ch
e_heap: LDA     #'H'            ; heap past the limit
        FCB     8Ch
e_store:LDA     #'W'            ; write outside the program's space
        FCB     8Ch
e_brack:LDA     #'D'            ; bad character after [
; error: print the letter in A, " @ " and the offset in the program of the
; character just read, then end. For example: S @ 245
error:  LDS     #RSTOP          ; the stacks may be wrecked: start clean
        LDU     #DSTOP
        JSR     CONOUT
        LDA     #' '
        JSR     CONOUT
        LDA     #'@'
        JSR     CONOUT
        LDA     #' '
        JSR     CONOUT
        TFR     Y,D
        SUBD    #PROG+1         ; the character just read
        PSHU    D
        JSR     pdec            ; and fall into fin
        ENDIF

fin:    JMP     EXIT            ; the program has ended

; =============================================================================
;  Startup
; =============================================================================
start:  LDS     #RSTOP
        LDU     #DSTOP
        LDA     #LETPAGE
        TFR     A,DP
        LDX     #PROG           ; the heap starts after the program's NUL
sc:     LDA     ,X+
        BNE     sc
        TFR     X,D
        STB     <HEAP           ; (little-endian)
        STA     <HEAP+1
        IF      CHECKED
        CLR     <KEYBUF
        ENDIF
        LDY     #PROG

; =============================================================================
;  The inner loop: read one character and sort it by range.
;
;    00h          end of program
;    01h-20h, 7Fh-FFh   ignored (control, space, DEL, high bytes)
;    30h-39h      digit: read a whole number
;    41h-5Ah      A-Z: call the word in that letter's cell
;    61h-7Ah      a-z: push the address of that letter's cell
;    the rest     punctuation: JSR through PTAB, 32 entries, in code order
; =============================================================================
next:
        IF      CHECKED
        ; Both stacks are checked once per character, not in every handler.
        ; Each stack lives in one page, and "empty" is the first address of
        ; the page above, so a stack is in range exactly when the address
        ; one below its pointer is in the page (127 entries or cells).
        LEAX    -1,U
        TFR     X,D
        CMPA    #DSPAGE
        BNE     e_stack
        LEAX    -1,S
        TFR     X,D
        CMPA    #RSPAGE
        BNE     e_rstack
        ENDIF
        LDA     ,Y+
        BEQ     fin             ; NUL ends the program
        SUBA    #21h            ; A = c - 21h
        BLO     next            ; 01h-20h ignored
        CMPA    #0Fh
        BLO     punct           ; 21h-2Fh: PTAB index 0-14
        SUBA    #0Fh            ; A = c - 30h
        CMPA    #0Ah
        BLO     digit           ; 30h-39h
        CMPA    #11h
        BLO     p3a             ; 3Ah-40h
        SUBA    #11h            ; A = c - 41h
        CMPA    #1Ah
        BLO     upper           ; 41h-5Ah: A = letter index 0-25
        CMPA    #20h
        BLO     p5b             ; 5Bh-60h
        CMPA    #3Ah
        BLO     lower           ; 61h-7Ah: A = 20h-39h (cell +64 bytes)
        CMPA    #3Eh
        BHS     next            ; 7Fh-FFh: ignored
        SUBA    #1Ah            ; 7Bh-7Eh: -1Eh in all, index 28-31
p5b:    SUBA    #9              ; 5Bh-60h: -4 in all, index 22-27
p3a:    ADDA    #5              ; 3Ah-40h: index 15-21
; Punctuation: A = the PTAB index.
punct:  LDX     #PTAB
        IF      1-CHECKED
        ; The handler is at PTAB + D, where B is the table byte and A is 1
        ; for the first NPG1 characters, 0 for the rest.
        LDB     A,X
        CMPA    #NPG1           ; carry: one of the first NPG1
        LDA     #0              ; (leaves the carry alone)
        ROLA
        JSR     D,X             ; the handler ends in RTS
        ENDIF
        IF      CHECKED
        ASLA                    ; the table holds whole addresses
        JSR     [A,X]
        ENDIF
        BRA     next

; Digits: step back onto the first digit and read the whole number.
digit:  LEAY    -1,Y
        BSR     rdnum
        BRA     next

; a-z: push the cell's address (the cell is the variable)
lower:  BSR     cellx
        PSHU    X
        BRA     next

; A-Z: call the word. The IP (the address after the letter) goes on the
; return stack, and the IP becomes the address in the letter's cell.
upper:  BSR     cellx
        PSHS    Y
        LDB     ,X
        LDA     1,X
        TFR     D,Y
        BRA     next

; cellx: A = letter index (0-25, or 32-57 for lowercase) -> X = cell address
cellx:  ASLA
        LDX     #LET
        LEAX    A,X
        RTS

; isdig: A = the character at IP minus '0'; the carry is set if it is a digit
isdig:  LDA     ,Y
        SUBA    #'0'
        CMPA    #10
ab9:    RTS

; rdnum: read decimal digits at IP and push the value; IP is left on the
; first non-digit. Values wrap at 16 bits, as the spec says. The running
; value lives in the new top cell: V = V*10 + digit.
rdnum:  CLRA
        CLRB
        PSHU    D
rd1:    BSR     isdig
        BHS     ab9
        LEAY    1,Y
        PSHS    A
        LDD     ,U
        ASLB
        ROLA
        ASLB
        ROLA
        ADDD    ,U              ; 5V
        ASLB
        ROLA                    ; 10V
        ADDB    ,S+
        ADCA    #0
        STD     ,U
        BRA     rd1

; =============================================================================
;  Dispatch table, in code order.
;
;  Unchecked build: one byte per character, the low byte of the handler's
;  distance from PTAB. NPG1 is how many characters, from the start, have
;  handlers more than 255 bytes past PTAB. ] \ [ @ ? sit where the two ranges
;  meet (in falling code order for this), and which side each lands on is
;  worked out here. (One division to a line: asm80 only rounds down when it
;  stores a value.)
;
;  Checked build: it has more code than the two ranges hold, so its table
;  holds whole addresses and there are no rules about where handlers go.
; =============================================================================
        IF      1-CHECKED
PGRET   EQU     (h_ret-PTAB)/256        ; 0 = first range, 1 = second
PGBRK   EQU     (h_break-PTAB)/256
PGDEF   EQU     (h_def-PTAB)/256
PGFET   EQU     (h_fetch-PTAB)/256
PGKEY   EQU     (h_key-PTAB)/256
NPG1    EQU     20 + PGKEY + PGFET + PGDEF + PGBRK + PGRET
        ENDIF
PTAB:
        IF      1-CHECKED
        FCB     (h_store-PTAB) & 0FFh ; !
        FCB     (h_str-PTAB) & 0FFh   ; "
        FCB     (h_num-PTAB) & 0FFh   ; #
        FCB     (h_print-PTAB) & 0FFh ; $
        FCB     (h_swap-PTAB) & 0FFh  ; %
        FCB     (h_and-PTAB) & 0FFh   ; &
        FCB     (h_emit-PTAB) & 0FFh  ; '
        FCB     (h_open-PTAB) & 0FFh  ; (
        FCB     (h_close-PTAB) & 0FFh ; )
        FCB     (h_mul-PTAB) & 0FFh   ; *
        FCB     (h_add-PTAB) & 0FFh   ; +
        FCB     (h_cfetch-PTAB) & 0FFh; ,
        FCB     (h_sub-PTAB) & 0FFh   ; -
        FCB     (h_cstore-PTAB) & 0FFh; .
        FCB     (h_div-PTAB) & 0FFh   ; /
        FCB     (h_dup-PTAB) & 0FFh   ; :
        FCB     (h_drop-PTAB) & 0FFh  ; ;
        FCB     (h_lt-PTAB) & 0FFh    ; <
        FCB     (h_eq-PTAB) & 0FFh    ; =
        FCB     (h_gt-PTAB) & 0FFh    ; >
        FCB     (h_key-PTAB) & 0FFh   ; ?
        FCB     (h_fetch-PTAB) & 0FFh ; @
        FCB     (h_def-PTAB) & 0FFh   ; [
        FCB     (h_break-PTAB) & 0FFh ; \
        FCB     (h_ret-PTAB) & 0FFh   ; ]
        FCB     (h_xor-PTAB) & 0FFh   ; ^
        FCB     (h_alloc-PTAB) & 0FFh ; _
        FCB     (h_grave-PTAB) & 0FFh ; `
        FCB     (h_tor-PTAB) & 0FFh   ; {
        FCB     (h_or-PTAB) & 0FFh    ; |
        FCB     (h_fromr-PTAB) & 0FFh ; }
        FCB     (h_not-PTAB) & 0FFh   ; ~
        ENDIF
        IF      CHECKED
        FDB     h_store         ; !
        FDB     h_str           ; "
        FDB     h_num           ; #
        FDB     h_print         ; $
        FDB     h_swap          ; %
        FDB     h_and           ; &
        FDB     h_emit          ; '
        FDB     h_open          ; (
        FDB     h_close         ; )
        FDB     h_mul           ; *
        FDB     h_add           ; +
        FDB     h_cfetch        ; ,
        FDB     h_sub           ; -
        FDB     h_cstore        ; .
        FDB     h_div           ; /
        FDB     h_dup           ; :
        FDB     h_drop          ; ;
        FDB     h_lt            ; <
        FDB     h_eq            ; =
        FDB     h_gt            ; >
        FDB     h_key           ; ?
        FDB     h_fetch         ; @
        FDB     h_def           ; [
        FDB     h_break         ; \
        FDB     h_ret           ; ]
        FDB     h_xor           ; ^
        FDB     h_alloc         ; _
        FDB     h_grave         ; `
        FDB     h_tor           ; {
        FDB     h_or            ; |
        FDB     h_fromr         ; }
        FDB     h_not           ; ~
        ENDIF
PTABEND:

; =============================================================================
;  Handlers that must start in the first range (within 255 bytes of PTAB)
;  in the unchecked build: ^ _ ` { | } ~
; =============================================================================
h_or:   LDD     ,U++
        ORA     ,U
        ORB     1,U
        BRA     st0

h_xor:  LDD     ,U++
        EORA    ,U
        EORB    1,U
st0:    STD     ,U
        RTS

h_not:  COM     ,U
        COM     1,U
        RTS

; '{' ( n -- ) R: ( -- n )     The dispatcher's return address comes off the
; return stack first (PULS X) and is jumped to at the end.
h_tor:  PULS    X
        PULU    D
        PSHS    D
        JMP     ,X

; '}' ( -- n ) R: ( n -- )
h_fromr:PULS    X
        PULS    D
        PSHU    D
        JMP     ,X

; '_' ( n -- addr ): the heap pointer moves up by n; TOS is the old pointer.
h_alloc:LDB     <HEAP
        LDA     <HEAP+1
        TFR     D,X             ; the old pointer
        ADDD    ,U
        IF      CHECKED
        LBCS    e_heap          ; a negative count wraps: too big
        CMPA    #HEAPLIM
        LBHS    e_heap          ; the new top must stay below the limit page
        ENDIF
        STB     <HEAP
        STA     <HEAP+1
        STX     ,U
        RTS

; ---- machine code: the grave -----------------------------------------------
; '`' plus a hex digit loads bytes: ( addr -- addr' ). Pairs of hex digits
; are stored from addr until a non-hex character; then a RTS (39h) is
; written and its address is left. An odd last digit is consumed and dropped.
; '`' plus anything else calls the machine code at TOS: ( addr -- ). The
; code is entered by JSR (the dispatcher's own), with the address already
; popped: U points at the top data cell (big-endian, 2 bytes, stack grows
; down) and the return address is on top of S. The code may pop and push
; data cells by changing U; on return the cell at ,U is the new TOS. It must
; keep Y (the interpreter's reading position), DP and S (balanced), and
; return with RTS. A, B, X, CC may change.
h_grave:BSR     hexc            ; the digit after the grave, if any
        BCC     exec
        LDX     ,U
hx1:    LDB     #16
        MUL                     ; B = the digit, moved up to the high half
        IF      CHECKED
        JSR     chkst
        ENDIF
        STB     ,X              ; (an odd digit is overwritten by the RTS)
        BSR     hexc
        BCC     hx2             ; odd digit: already consumed, dropped
        ORA     ,X
        STA     ,X+
        BSR     hexc
        BCS     hx1
hx2:
        IF      CHECKED
        JSR     chkst
        ENDIF
        LDA     #39h            ; RTS
        STA     ,X
        STX     ,U
        RTS
exec:   LDX     ,U++
        JMP     ,X              ; the code's RTS returns to the dispatcher

; hexc: if the character at IP is a hex digit (0-9, A-F, a-f), step over it
; and return its value in A with the carry set; otherwise leave the IP and
; return with the carry clear.
hexc:   JSR     isdig
        BLO     hv1             ; C = 1
        ANDA    #0DFh
        SUBA    #11h
        CMPA    #6
        BHS     hv9             ; C = 0
        SUBA    #0F6h           ; + 10, and sets the carry
hv1:    LEAY    1,Y             ; (LEAY leaves the carry alone)
hv9:    RTS

        IF      1-CHECKED
getk    EQU     KEY             ; the host's routine does the whole job
        ENDIF

; ---- where the two ranges meet ---------------------------------------------
; The first range ends somewhere among the next five handlers, ] \ [ @ ?
; (they are in falling code order for this): NPG1 follows. Every handler
; below them must start in the second range, and every one above in the
; first.

; ']' returns: pop an address and jump to it. (PULS X,Y: the dispatcher's
; return address into X, then the saved IP into Y.)
h_ret:
        IF      CHECKED
        JSR     chkbrk          ; Ctrl-C is checked at every word return
        ENDIF
        PULS    X,Y
        JMP     ,X

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
h_break:LDD     ,U++
        BEQ     sk9             ; false: nothing to do
        BSR     skip
        TSTA                    ; skip returns 0 for ')'
        BNE     h_ret
rdrop:  PULS    D,X             ; the return address and the block start
        TFR     D,PC            ; back to the dispatcher

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything below 'A' as the space, and anything
; from 'A' up as a letter.)
h_def:  LDA     ,Y+
        IF      CHECKED
        CMPA    #' '
        BEQ     def2
        TFR     A,B
        ANDB    #0DFh           ; fold case
        SUBB    #'A'
        CMPB    #26
        LBHS    e_brack         ; anything but a letter or a space
        ENDIF
        SUBA    #'A'            ; 0-25 or 32-57: lowercase lands 64 bytes up
        IF      1-CHECKED
        BLO     def2
        ENDIF
        JSR     cellx
        TFR     Y,D
        STB     ,X              ; little-endian
        STA     1,X
        FCB     8Ch             ; (CMPX #: steps over the PSHU)
def2:   PSHU    Y               ; an anonymous block: push its address
        ; fall into skip

; skip: read past text to the closer at this level, and return A = 0 if it
; was ')' and 2 if it was ']'. Brackets of both kinds count together;
; strings are stepped over whole. A NUL first ends the program (for '\' with
; no closer; anything else that runs into the NUL had unbalanced brackets
; anyway). B counts the open levels.
skip:   CLRB
sk1:    LDA     ,Y+
        LBEQ    fin
        CMPA    #22h
        BNE     sk2
        BSR     skipstr         ; leaves A = 22h, which matches nothing below
sk2:    SUBA    #'('
        BEQ     sk3
        DECA                    ; ')'
        BEQ     sk4
        SUBA    #'['-')'
        BEQ     sk3
        CMPA    #']'-'['
        BNE     sk1
sk4:    DECB
        BPL     sk1
sk9:    RTS                     ; the closer at this level
sk3:    INCB
        BRA     sk1

h_fetch:LDX     ,U              ; '@' (the cell in memory is little-endian)
        LDA     1,X
        BRA     cf1

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. n is not
;          checked: the buffer holds 127 characters and the CR, so a
;          program must ask for 127 or fewer.
h_key:  LDX     ,U
        BMI     line
kt1:    LDB     #MSLOOP         ; one millisecond, roughly
kt2:    JSR     getk
        BNE     kt3
        DECB
        BNE     kt2
        LEAX    -1,X
        BNE     kt1             ; A = 0 if the time ran out
        LDX     ,U              ; 0?: the countdown from 0 took 65536 ms;
        BEQ     kt1             ;   run it again, until a key comes
kt3:    CLR     ,U
        STA     1,U
        RTS

; Backspace takes the last character back (and is echoed as it is), CR ends
; (stored, not echoed), every other key is stored and echoed until the line
; is full. B = the length so far; the low byte of the top cell becomes the
; most allowed (it holds minus the count on entry).
line:   NEG     1,U
        LDX     #LINEBUF
        CLRB
ln2:    JSR     getk
        BEQ     ln2
        CMPA    #13
        BEQ     ln5
        CMPA    #8
        BEQ     ln4
        CMPB    1,U
        BHS     ln2             ; full
        STA     B,X
        INCB
ln3:    JSR     CONOUT
        BRA     ln2
ln4:    TSTB                    ; Backspace: nothing to take back?
        BEQ     ln2
        DECB
        BRA     ln3             ; echo it
ln5:    STA     B,X             ; A = 13
        STX     ,U
        RTS

; =============================================================================
;  Handlers that must start in the second range (unchecked build).
; =============================================================================

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: LDD     ,U++
        BEQ     skip            ; tail call: skip ends in RTS
        PULS    X
        PSHS    Y
        JMP     ,X

; 22h pushes the address of the text after it and skips the string.
h_str:  PSHU    Y
        FCB     8Ch             ; (CMPX #: steps over the LEAY)
; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it. Leaves A = 22h.
ss0:    LEAY    1,Y
skipstr:LDA     ,Y+
        CMPA    #'/'
        BEQ     ss0
        CMPA    #22h
        BNE     skipstr
        RTS

h_cfetch:LDX    ,U              ; ','
        CLRA
cf1:    LDB     ,X
        STD     ,U
        RTS

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on.
h_close:LDD     ,U++
        LBEQ    rdrop
        IF      CHECKED
        JSR     chkbrk          ; Ctrl-C is checked at every loop-back
        ENDIF
        LDY     2,S             ; the block start, under the return address
        RTS

; ---- arithmetic and logic: ( NOS TOS -- result ) ---------------------------

; '*': three 8x8 multiplies; only the low 16 bits are kept.
; a = ah:al at 2,U.  b = bh:bl at ,U.
h_mul:  LDA     3,U
        LDB     ,U
        MUL                     ; al*bh
        STB     ,U              ; (bh is no longer needed)
        LDA     2,U
        LDB     1,U
        MUL                     ; ah*bl
        ADDB    ,U
        STB     ,U              ; the cross terms, low byte
        LDA     3,U
        LDB     1,U
        MUL                     ; al*bl
        ADDA    ,U
        LEAU    2,U
        STD     ,U
        RTS

; Signed compares: a-b, then a branch to put -1 or 0 on the stack.
h_gt:   BSR     h_swap          ; a > b is b < a
h_lt:   BSR     cmp
        BLT     true
false:  CLRB
        FCB     8Ch             ; (CMPX #: steps over the LDB)
true:   LDB     #0FFh
        SEX                     ; D = 0000 or FFFF
        STD     ,U
        RTS

h_eq:   BSR     cmp
        BEQ     true
        BRA     false

cmp:    LDD     2,U
        CMPD    ,U++
        RTS

h_emit: LDA     1,U             ; "'"
        BSR     putc
h_drop: LEAU    2,U             ; ';'
        RTS

; '$' prints the string at TOS, decoding escapes: '/' plus a character
; clears that character's bit 6 (/M is CR, /` is space; '/' and '"' have no
; bit 6, so // and /" give themselves).
h_print:LDX     ,U
pr0:    LDA     ,X+
        CMPA    #22h
        BEQ     h_drop
        CMPA    #'/'
        BNE     pr1
        LDA     ,X+
        ANDA    #0BFh
pr1:    BSR     putc
        BRA     pr0

; '!' ( n addr -- ) is '.' with the high byte stored first. The cell in
; memory is little-endian.
h_store:LDX     ,U
        IF      CHECKED
        LEAX    1,X             ; both bytes must be in the program's space
        JSR     chkst
        LEAX    -1,X
        ENDIF
        LDA     2,U
        STA     1,X
        FCB     8Ch             ; (CMPX #: steps over the LDX)
h_cstore:LDX    ,U              ; '.' ( c addr -- )
        IF      CHECKED
        JSR     chkst
        ENDIF
        LEAU    2,U
        PULU    D
        STB     ,X
        RTS


; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  TST     ,U
        BPL     pdec
        LDA     #'-'
        BSR     putc
        BSR     negt
; pdec: print the top cell as unsigned and drop it, by recursion on /10
pdec:   LDD     #10
        PSHU    D
        BSR     udiv            ; NOS = quotient, TOS = digit
        PULU    D               ; the digit
        PSHS    B
        LDD     ,U
        BEQ     pd1
        BSR     pdec
        BRA     pd2
pd1:    LEAU    2,U             ; drop the zero quotient
pd2:    PULS    A
        ADDA    #'0'            ; and fall into putc

putc:   JMP     CONOUT


; ---- stack and storage -----------------------------------------------------

h_swap: PULU    D,X             ; '%'
        PSHU    D
        PSHU    X
        RTS

h_dup:  LDD     ,U              ; ':'
        PSHU    D
        RTS

h_and:  LDD     ,U++
        ANDA    ,U
        ANDB    1,U
        BRA     st

h_add:  LDD     ,U++
        ADDD    ,U
st:     STD     ,U
        RTS


; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  JSR     isdig
        BLO     negnum
        LDD     2,U
        SUBD    ,U++
        BRA     st

; ---- the tail ---------------------------------------------------------------
; '/' is the last handler, so what follows its first byte may lie past the
; second range: the divide itself and the routines after it.

; '/' ( a b -- q r ): the remainder is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Dividing by zero is not checked: it returns two cells of no meaning.
h_div:  LDA     2,U
        PSHS    A               ; a's sign: for r
        EORA    ,U
        PSHS    A               ; a xor b: for q
        LEAX    2,U
        BSR     absx            ; |a|
        TFR     U,X
        BSR     absx            ; |b|
        BSR     udiv            ; NOS = q, TOS = r
        LEAX    2,U
        TST     ,S+
        BPL     dv1
        BSR     negx            ; q's sign
dv1:    TST     ,S+
        BPL     ng9
        BRA     negt            ; r's sign

negnum: JSR     rdnum           ; a negative literal: read it, then negate
negt:   TFR     U,X
negx:   LDD     ,X              ; negx: negate the cell at X
        NEGA
        NEGB
        SBCA    #0
        STD     ,X
ng9:    RTS
absx:   TST     ,X              ; absx: negate the cell at X if negative
        BPL     ng9
        BRA     negx


; udiv: unsigned divide, in place. The dividend is the NOS cell and the
; divisor the TOS cell, both <= 8000h; the NOS cell becomes the quotient and
; the TOS cell the remainder. The remainder is built in D (always < the
; divisor, so 2R+1 fits in 16 bits).
udiv:   LDX     #16
        CLRA
        CLRB
ud1:    ASL     3,U
        ROL     2,U             ; the dividend's top bit ...
        ROLB
        ROLA                    ; ... into the remainder
        CMPD    ,U
        BLO     ud2
        SUBD    ,U
        INC     3,U             ; a quotient bit
ud2:    LEAX    -1,X
        BNE     ud1
        STD     ,U
        RTS

        IF      CHECKED
; chkst: stop unless X is in the program's own space: from the letter page
; up to HEAPLIM, so the interpreter's stacks and whatever lies above the
; limit are safe. Memory above the heap top but below the limit is the
; program's own: Tiny BASIC keeps its lines there. Keeps every register.
chkst:  CMPX    #LET
        BLO     cs9
        CMPX    #HEAPLIM*256
        BLO     gk9             ; in range: return
cs9:    JMP     e_store

; chkbrk: a waiting key is read now; Ctrl-C stops the program, anything
; else is held for the next '?'.
chkbrk: BSR     getk
        BEQ     gk9
        CMPA    #3
        LBEQ    e_break
        STA     <KEYBUF
        RTS

; getk: a key held back by the break check goes first; then the host's KEY.
getk:   LDA     <KEYBUF
        BEQ     gk1
        CLR     <KEYBUF
        TSTA
gk9:    RTS
gk1:    JMP     KEY
        ENDIF
imgend:
