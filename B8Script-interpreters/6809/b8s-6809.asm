; =============================================================================
;  B8Script interpreter for the Motorola 6809
;  Spec: docs/b8script.md (2026-10-09) plus the 2026-11-20 changes:
;        [x stores in a variable, "[ " pushes an anonymous block, any other
;        character after [ is an error, the heap pointer lives at z10+.
;  Follows the design of the Z80 interpreter (z80/b8s-z80.asm).
;
;  Two builds, selected by the CHECKED line below (CPM is always 0: the 6809
;  has no CP/M; the line is kept only so that build.sh works):
;    CHECKED  0 = no checks (spec: "B8Script checks nothing")
;             1 = stops on stack overrun, Ctrl-C, heap past the limit, a store
;                 outside the program's own space, and a bad character after [
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
;    A B X are scratch. Every handler is entered by JSR [A,X] and ends in RTS
;    (one byte); the handlers that push or pop the return stack first throw
;    the dispatcher's return address away (LEAS 2,S) and end in BRA next.
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
;                 `start` (F003h); the image does not contain it.
;    FF00h-FF0Bh  the console routines (CONIN, CONOUT, CONST, EXIT) are
;                 supplied by the system and need no space here.
;
;  The stacks sit below the letter page, so "the program's own space" (what
;  the checked build lets ! and . write) is the single range LET..HEAPLIM*256.
; -----------------------------------------------------------------------------

; ---- generic machine: edit these to suit -----------------------------------
CONIN   EQU     0FF00h          ; wait for a key, return it in A
CONOUT  EQU     0FF03h          ; print the character in A
CONST   EQU     0FF06h          ; A = 0 if no key is waiting, else nonzero
EXIT    EQU     0FF09h          ; where to go when the program ends
;   All three console routines are called with JSR. They may change A and CC
;   and must preserve B, X, Y, U and DP.
RSPAGE  EQU     80h
DSPAGE  EQU     81h
LETPAGE EQU     82h
PROG    EQU     8300h           ; where the loader puts the program text
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)

MSLOOP  EQU     20              ; n? inner loop count for about 1 ms; tune it
                                ; for your clock and CONST (about 50 cycles each)
CAP     EQU     127             ; -n? reads at most this many characters

; letter-page layout (direct-page offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     7Ch             ; z10+, the heap pointer (little-endian)
KEYBUF  EQU     34h             ; gap after Z: a key held back by the break check
MAXV    EQU     35h             ; the line length limit during -n?
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSTOP   EQU     RSPAGE*256+100h ; empty return stack
DSTOP   EQU     DSPAGE*256+100h ; empty data stack

        ORG     0F000h

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
h_def:  LDA     ,Y+
        TFR     A,B
        ANDB    #0DFh           ; fold case
        SUBB    #'A'
        CMPB    #26
        BHS     def2            ; not a letter
        SUBA    #'A'            ; 0-25 or 32-57: lowercase lands 64 bytes up
        JSR     cellx
        TFR     Y,D
        STB     ,X              ; little-endian
        STA     1,X
        BRA     skip
def2:
        IF      CHECKED
        CMPA    #' '
        LBNE     e_brack         ; anything but a letter or a space
        ENDIF
        PSHU    Y               ; an anonymous block: push its address
        ; fall into skip

; skip: read past text to the closer at this level, and return it in A.
; Brackets of both kinds count together; strings are stepped over whole. A
; NUL first ends the program (for '\' with no closer; anything else that runs
; into the NUL had unbalanced brackets anyway).
skip:   CLRB                    ; B = nesting level
sk1:    LDA     ,Y+
        BEQ     fin
        CMPA    #22h
        BNE     sk2
        BSR     skipstr
        BRA     sk1
sk2:    CMPA    #'('
        BEQ     sk3
        CMPA    #'['
        BEQ     sk3
        CMPA    #')'
        BEQ     sk4
        CMPA    #']'
        BNE     sk1
sk4:    DECB
        BPL     sk1
        RTS                     ; the closer at this level
sk3:    INCB
        BRA     sk1

; 22h pushes the address of the text after it and skips the string.
h_str:  PSHU    Y
; skipstr: IP is inside a string; step past its closing quote. '>' escapes
; the next character, so '>"' does not end it.
skipstr:LDA     ,Y+
        CMPA    #'>'
        BNE     ss1
        LEAY    1,Y
        BRA     skipstr
ss1:    CMPA    #22h
        BNE     skipstr
        RTS


; =============================================================================
;  Handlers that use the return stack. The dispatcher's return address is on
;  top of S when they start; they discard it (LEAS 2,S) and finish with
;  BRA next, or leave it and finish with RTS when they don't touch S.
; =============================================================================

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: LDD     ,U++
        BEQ     skip            ; tail call: skip ends in RTS
        LEAS    2,S
        PSHS    Y
        BRA     next

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on.
h_close:LDD     ,U++
        BEQ     rdrop
        IF      CHECKED
        JSR     chkbrk          ; Ctrl-C is checked at every loop-back
        ENDIF
        LDY     2,S             ; the block start, under the return address
        RTS
rdrop:  LEAS    4,S             ; the return address and the block start
        BRA     next

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
h_break:LDD     ,U++
        BNE     brk1
        RTS
brk1:   BSR     skip
        CMPA    #')'
        BEQ     rdrop
        ; fall into ']'

; ']' returns: pop an address and jump to it.
h_ret:  LEAS    2,S
        PULS    Y
        IF      CHECKED
        JSR     chkbrk          ; ... and at every word return
        ENDIF
        BRA     next

; '{' ( n -- ) R: ( -- n )
h_tor:  LDD     ,U++
        LEAS    2,S
        PSHS    D
        BRA     next

; '}' ( -- n ) R: ( n -- )
h_fromr:LEAS    2,S
        PULS    D
        PSHU    D
        BRA     next


fin:    JMP     EXIT            ; the program has ended

; =============================================================================
;  Startup
; =============================================================================
start:  LDS     #RSTOP
        LDU     #DSTOP
        LDA     #LETPAGE
        TFR     A,DP
        LDY     #PROG           ; the heap starts after the program's NUL
sc:     TST     ,Y+
        BNE     sc
        TFR     Y,D
        STB     <HEAP
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
        LBNE    e_stack
        LEAX    -1,S
        TFR     X,D
        CMPA    #RSPAGE
        LBNE    e_rstack
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
        BLO     p3a             ; 3Ah-40h: index 15-21
        SUBA    #11h            ; A = c - 41h
        CMPA    #1Ah
        BLO     upper           ; 41h-5Ah: A = letter index 0-25
        CMPA    #20h
        BLO     p5b             ; 5Bh-60h: index 22-27
        CMPA    #3Ah
        BLO     lower           ; 61h-7Ah: A = 20h-39h (cell +64 bytes)
        CMPA    #3Eh
        BHS     next            ; 7Fh-FFh: ignored
        SUBA    #23h            ; 7Bh-7Eh: with the ADDA below, index 28-31
p3a:    ADDA    #5              ; 3Ah-40h: index 15-21
punct:  ASLA                    ; PTAB entries are 2 bytes; A <= 62
        LDX     #PTAB
        JSR     [A,X]           ; the handler ends in RTS
        BRA     next
p5b:    SUBA    #4
        BRA     punct

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


; =============================================================================
;  Dispatch table: one handler per punctuation character, in code order.
; =============================================================================
PTAB:   FDB     h_store         ; !
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
        FDB     drop            ; ;
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

; rdnum: read decimal digits at IP and push the value; IP is left on the
; first non-digit. Values wrap at 16 bits, as the spec says. The running
; value lives in the new top cell: V = V*10 + digit.
rdnum:  CLRA
        CLRB
        PSHU    D
rd1:    LDA     ,Y
        SUBA    #'0'
        CMPA    #10
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
;  Arithmetic and logic. Effects are ( NOS TOS -- result ).
; =============================================================================
; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BLO     negnum
        LDD     2,U
        SUBD    ,U++
        STD     ,U
        RTS
; absx: negate the cell at X if it is negative. negt: negate the top cell.
; negx: negate the cell at X.
absx:   TST     ,X
        BPL     ab9
        BRA     negx
negnum: BSR     rdnum           ; a negative literal: read it, then negate
negt:   TFR     U,X
negx:   LDD     ,X
        NEGA
        NEGB
        SBCA    #0
        STD     ,X
ab9:    RTS

; '/' ( a b -- q r ): truncates toward zero; r takes a's sign.
; b = 0 gives q = 0, r = a. b = 2 takes a fast shift, as the spec requires.
h_div:  LDD     ,U
        BEQ     div0
        CMPD    #2
        BEQ     div2
        LDA     2,U
        PSHS    A               ; a's sign: for r
        EORA    ,U
        PSHS    A               ; a xor b: for q
        LEAX    2,U
        BSR     absx            ; |a|
        TFR     U,X
        BSR     absx            ; |b|
        BSR     udiv
        LEAX    2,U
        TST     ,S+
        BPL     dv1
        BSR     negx            ; q's sign
dv1:    TFR     U,X
        TST     ,S+
        BPL     ab9
        BRA     negx            ; r's sign
div0:   LDD     2,U             ; q = 0, r = a
        STD     ,U
        CLR     2,U
        CLR     3,U
        RTS
div2:   LDD     2,U             ; a / 2: add 1 if a is negative, then shift
        PSHS    D               ; a, for the remainder
        BPL     d2a
        ADDD    #1
d2a:    ASRA
        RORB
        STD     2,U             ; q
        ASLB
        ROLA                    ; 2q
        NEGA
        NEGB
        SBCA    #0              ; -2q
        ADDD    ,S++            ; r = a - 2q
        STD     ,U
        RTS


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

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  TST     ,U
        BPL     pdec
        LDA     #'-'
        JSR     CONOUT
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
        ADDA    #'0'
        JMP     CONOUT


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

h_add:  LDD     ,U++
        ADDD    ,U
        BRA     st

h_and:  LDD     ,U++
        ANDA    ,U
        ANDB    1,U
        BRA     st

h_or:   LDD     ,U++
        ORA     ,U
        ORB     1,U
        BRA     st

h_xor:  LDD     ,U++
        EORA    ,U
        EORB    1,U
        BRA     st

h_not:  COM     ,U
        COM     1,U
        RTS

; Signed compares: a-b, then a branch to put -1 or 0 on the stack.
cmp:    LDD     2,U
        CMPD    ,U++
        RTS

h_lt:   BSR     cmp
        BLT     true
false:  CLRA
        CLRB
        BRA     st
h_gt:   BSR     cmp
        BGT     true
        BRA     false
h_eq:   BSR     cmp
        BNE     false
true:   LDD     #-1
st:     STD     ,U
        RTS

; =============================================================================
;  Stack
; =============================================================================
h_dup:  LDD     ,U
        PSHU    D
        RTS

h_swap: PULU    D,X
        PSHU    D
        PSHU    X
        RTS

; =============================================================================
;  Storage. The cells in RAM are little-endian: the byte order is swapped
;  between the stack (big-endian) and memory.
; =============================================================================
h_fetch:LDX     ,U              ; '@'
        LDB     ,X
        LDA     1,X
        BRA     st

h_cfetch:LDX    ,U              ; ','
        LDB     ,X
        CLRA
        BRA     st

h_store:LDX     ,U++            ; '!' ( n addr -- )
        IF      CHECKED
        BSR     chkst           ; both bytes must be in the program's space
        LEAX    1,X
        BSR     chkst
        LEAX    -1,X
        ENDIF
        PULU    D
        STB     ,X              ; little-endian
        STA     1,X
        RTS

h_cstore:LDX    ,U++            ; '.' ( c addr -- )
        IF      CHECKED
        BSR     chkst
        ENDIF
        PULU    D
        STB     ,X
        RTS

; '_' ( n -- addr ): the heap pointer moves up by n; TOS is the old pointer.
h_alloc:LDB     <HEAP
        LDA     <HEAP+1
        TFR     D,X             ; the old pointer
        ADDD    ,U
        IF      CHECKED
        LBCS     e_heap          ; a negative count wraps: too big
        CMPD    #HEAPLIM*256
        LBHS     e_heap
        ENDIF
        STB     <HEAP
        STA     <HEAP+1
        STX     ,U
        RTS

        IF      CHECKED
; chkst: stop unless X is in the program's own space: from the letter page
; up to HEAPLIM, so the interpreter's stacks and whatever lies above the
; limit are safe. Memory above the heap top but below the limit is the
; program's own: Tiny BASIC keeps its lines there. Keeps every register.
chkst:  CMPX    #LET
        LBLO     e_store
        CMPX    #HEAPLIM*256
        LBHS     e_store
        RTS
        ENDIF

; =============================================================================
;  Flow control helpers
; =============================================================================


; =============================================================================
;  Console
; =============================================================================


; '$' prints the string at TOS, decoding escapes: '>' plus a character from
; 40h-7Fh clears its bit 6 (>M is CR, >` is space); plus anything lower gives
; that character itself.
h_print:LDX     ,U
pr0:    LDA     ,X+
        CMPA    #22h
        BEQ     drop
        CMPA    #'>'
        BNE     pr1
        LDA     ,X+
        CMPA    #40h
        BLO     pr1
        ANDA    #0BFh
pr1:    BSR     putc
        BRA     pr0

h_emit: LDA     1,U             ; "'"
        BSR     putc
drop:   LEAU    2,U             ; ';'
        RTS


; =============================================================================
;  Console layer: getk returns a waiting key in A (zero flag clear), or
;  A = 0 with the zero flag set when none is waiting. It keeps B, X, Y, U.
; =============================================================================
getk:
        IF      CHECKED
        LDA     <KEYBUF         ; a key held back by the break check
        BEQ     gk1
        CLR     <KEYBUF
        TSTA
        RTS
gk1:
        ENDIF
        JSR     CONST
        TSTA
        BEQ     gk9
        JSR     CONIN
        TSTA
gk9:    RTS
        IF      CHECKED
; chkbrk: a waiting key is read now; Ctrl-C stops the program, anything
; else is held for the next '?'.
chkbrk: LDA     <KEYBUF
        BNE     cb9             ; one key is already held
        BSR     getk
        BEQ     cb9
        CMPA    #3
        LBEQ     e_break
        STA     <KEYBUF
cb9:    RTS
        ENDIF

putc:   JMP     CONOUT

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters (capped at CAP) with echo
h_key:  LDX     ,U
        BMI     line
kt1:    LDB     #MSLOOP         ; one millisecond, roughly
kt2:    BSR     getk
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

line:   CLRA
        CLRB
        SUBD    ,U              ; D = the count
        CMPD    #CAP
        BLS     ln1
        LDB     #CAP
ln1:    STB     <MAXV
        LDX     #LINEBUF
        CLRB                    ; B = length
        ; Backspace and DEL erase, CR ends (stored, not echoed), other
        ; control keys are ignored, and a full line takes only those.
ln2:    BSR     getk
        BEQ     ln2
        CMPA    #13
        BEQ     ln5
        CMPA    #8
        BEQ     ln4
        CMPA    #7Fh
        BEQ     ln4
        CMPA    #' '
        BLO     ln2
        CMPB    <MAXV
        BHS     ln2             ; full
        STA     ,X+
        INCB
        BSR     putc
        BRA     ln2
ln4:    TSTB
        BEQ     ln2
        DECB
        LEAX    -1,X
        LDA     #8
        BSR     putc
        LDA     #' '
        BSR     putc
        LDA     #8
        BSR     putc
        BRA     ln2
ln5:    STA     ,X              ; A = 13
        LDD     #LINEBUF
        STD     ,U
        RTS

; =============================================================================
;  Machine code: the grave
; =============================================================================
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
hx1:    ASLA
        ASLA
        ASLA
        ASLA
        IF      CHECKED
        JSR     chkst
        ENDIF
        STA     ,X              ; the high nibble; an odd digit is overwritten
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

; hexc: read the character at IP. If it is a hex digit (0-9, A-F, a-f), return
; its value 0-15 in A with carry set and step over it; otherwise return with
; carry clear and the IP unchanged.
hexc:   LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BLO     hv1             ; C = 1
        ANDA    #0DFh
        SUBA    #11h
        CMPA    #6
        BHS     hv9             ; C = 0
        ADDA    #10
        CMPA    #16             ; C = 1
hv1:    LEAY    1,Y             ; (LEAY leaves the carry alone)
hv9:    RTS


; =============================================================================
;  Checked build: break key and error reports
; =============================================================================
        IF      CHECKED

e_stack:BSR     error
        FCB     "stac", 'k'+80h
e_rstack:BSR    error
        FCB     "retur", 'n'+80h
e_break:BSR     error
        FCB     "brea", 'k'+80h
e_heap: BSR     error
        FCB     "hea", 'p'+80h
e_store:BSR     error
        FCB     "stor", 'e'+80h
e_brack:BSR     error
        FCB     '['+80h
; error: print CR LF, the word after the BSR (last character has bit 7
; set), " at " and the offset of the reading position in the program.
error:  PULS    X               ; X -> the word
        LDS     #RSTOP          ; the stacks may be wrecked: start clean
        LDU     #DSTOP
        PSHS    X
        LDX     #crlf
        BSR     puts7
        PULS    X
        BSR     puts7
        LDX     #aat
        BSR     puts7
        TFR     Y,D
        SUBD    #PROG+1         ; the character just read
        PSHU    D
        JSR     pdec
        JMP     EXIT
; puts7: print the characters at X up to one with bit 7 set (inclusive)
puts7:  LDA     ,X+
        PSHS    A
        ANDA    #7Fh
        JSR     CONOUT
        TST     ,S+
        BPL     puts7
        RTS
crlf:   FCB     13, 10+80h
aat:    FCB     " at", ' '+80h
        ENDIF
imgend:

