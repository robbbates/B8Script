; =============================================================================
;  B8Script interpreter for the 6502 (NMOS opcodes only), with the data stack
;  in zero page
;  Spec: docs/b8script.md (2026-10-09) plus the 2026-11-20 changes:
;        [x stores in a variable, "[ " pushes an anonymous block, any other
;        character after [ is an error, the heap pointer lives at z10+.
;        The string escape is '/' (it was '>').
;        Dividing by zero is not checked. -n? does no more editing than
;        Backspace.
;
;  This is the smaller of the two 6502 interpreters. b8s-6502.asm keeps the
;  data stack in pages 2 and 3 (252 cells) and leaves zero page almost free;
;  this one keeps it in zero page (112 cells), where the 6502's short
;  addressing modes make nearly every handler smaller. The language is the
;  same; the memory map and the machine-code contract differ.
;
;  One switch, set in the EQU line below:
;    CHECKED  0 = no checks (spec: "B8Script checks nothing")
;             1 = stops on stack overrun, Ctrl-C, heap past the limit, a store
;                 outside the program's own space, and a bad character after [,
;                 printing a letter and the place, like  S @ 245
;
;  Assembler: asm80, C6502 mode.
; =============================================================================

CHECKED EQU     0               ; 1 = checked build

; -----------------------------------------------------------------------------
;  Registers and zero page
;
;    IP      zero-page pointer to the next program character (16 bits)
;    X       the data-stack pointer. Every cell is two bytes in zero page, low
;            byte first: the top cell (TOS) is 0,X and 1,X, the one under it
;            (NOS) 2,X and 3,X. The stack grows down: a push is DEX DEX, a
;            drop INX INX. A cell that holds an address is used where it is,
;            with (0,X): nothing is copied to a pointer first.
;    $FE,X   the two bytes under the top cell (zero-page indexing wraps, so
;    $FF,X   this is -2,X and -1,X): free memory, used as scratch.
;    S       the hardware stack is the RETURN stack: a word call or "(" pushes
;            the reading position (high byte first, then low) and "]" or ")"
;            pulls it. 100 entries (200 bytes) fit with room to spare.
;    Y, A    scratch. Y is 0 after peek/getc.
;
;  Dispatch: step is called with JSR, so a handler ends with a plain RTS and
;  lands on "JMP next" in the loop. Handlers that use the return stack ( ( ) \
;  ] { } and word calls ) first pull the 2-byte JSR frame off (PLA PLA) and end
;  with JMP next instead.
;
;  PTAB holds one byte per punctuation character: the low byte of its
;  handler's address, less 1 (the dispatcher pushes an address and "returns"
;  to it). The high byte comes from the character: the handlers of the first
;  N1 characters start in the image's first page, those of the characters from
;  N1 up to N2 in its second, and the rest in its third. The layout below
;  keeps to that, and testing/chktab6502.py checks it in every build.
;
;  Every punctuation handler starts with the carry clear (the dispatcher
;  leaves it so). Several of them count on that, where the comments say.
;
;  Machine-code contract (the grave): the code at TOS is entered as a
;  subroutine, by JMP (T0) with the loop's return address on the hardware
;  stack, so it ends with RTS (60h, which the hex loader appends). On entry the
;  address has been dropped and X is the data-stack pointer: TOS is 0,X (low)
;  and 1,X (high), NOS is 2,X and 3,X. To push: DEX, DEX, then store at 0,X
;  and 1,X. To drop: INX, INX. The code may change A and Y, and X as the
;  stack pointer; it must keep IP ($00/$01) and leave the hardware stack
;  balanced. Zero page $02, $03, $07 and $0A-$0D are free for its own use.
; -----------------------------------------------------------------------------
IP      EQU     00h             ; 00-01 reading position
T0      EQU     04h             ; scratch
T1      EQU     05h
T2      EQU     06h
D0      EQU     08h             ; divisor (division, number printing)
D1      EQU     09h

; -----------------------------------------------------------------------------
;  Memory map
;
;    0000-000F  the variables above, and scratch
;    0010-00EF  the data stack: 112 cells. X = F0 when it is empty. (0E and
;               0F are the scratch under the top cell when it is full.)
;    0100-01FF  hardware stack = return stack, S starts at FF
;    0400       LET  letter cells: A..Z at +00..+33, a..z at +40..+73 (a word
;               cell is 64 bytes below its variable), heap pointer at +7C
;               (= z10+), KEYBUF at +34, the -n? line buffer at +80..+FF
;    0500       PROG the program text, NUL-terminated; the heap follows
;    E000       the interpreter (ROM)
;
;  The stacks sit below the letter page, so "the program's own space" (what
;  the checked build lets ! and . write) is the page range LETPAGE..HEAPLIM-1.
; -----------------------------------------------------------------------------
KEY     EQU     0FF06h          ; a waiting key in A, or A = 0 if none is
                                ;   waiting. The Z flag must match A (it does
                                ;   if the routine ends with LDA / RTS).
CONOUT  EQU     0FF03h          ; print the character in A
EXIT    EQU     0FF09h          ; where to go when the program ends
;   KEY and CONOUT must preserve X and Y.
DSE     EQU     0F0h            ; X when the data stack is empty
DSFULL  EQU     10h             ; X when it is full
LETPAGE EQU     04h
LET     EQU     LETPAGE*256
PROG    EQU     0500h           ; where the loader puts the program text
PROG1   EQU     PROG+1
HEAPLIM EQU     0E0h            ; the heap must stay below E000h (a page)
HEAP    EQU     LET+7Ch         ; z10+, the heap pointer
KEYBUF  EQU     LET+34h         ; a key held back by the break check
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSLIM   EQU     20h             ; lowest S allowed (checked build)
MSLOOP  EQU     40              ; n? inner loop count for about 1 ms; tune it

BASE    EQU     0E000h          ; where the image starts: a multiple of 512
HALFPG  EQU     BASE/512        ; (the dispatcher doubles this to get a page)
N1      EQU     8               ; ! " # $ % & ' (  start in the first page,
N2      EQU     21              ; ) * + , - . / : ; < = > ?  in the second,
                                ; @ [ \ ] ^ _ ` { | } ~  in the third

; udiv: unsigned TOS / D (D <= 8000h). TOS becomes the quotient; the
; remainder is left in the scratch under it, at $FE,X and $FF,X.
; Dividing by 2 is one shift (the spec wants that fast).
; (A macro, because the two builds need it in different places: the
; unchecked build uses it to fill the first page.)
.macro  UDIV
udiv:   LDA     #0
        STA     0FEh,X
        STA     0FFh,X
        LDA     D0
        EOR     #2
        ORA     D1
        BNE     ud0
        LSR     1,X
        ROR     0,X             ; the quotient
        ROL     0FEh,X          ; the remainder: the bit that fell out
        RTS
ud0:    LDY     #16
ud1:    ASL     0,X
        ROL     1,X
        ROL     0FEh,X
        ROL     0FFh,X
        SEC
        LDA     0FEh,X
        SBC     D0
        STA     T0
        LDA     0FFh,X
        SBC     D1
        BCC     ud2
        STA     0FFh,X
        LDA     T0
        STA     0FEh,X
        INC     0,X             ; the quotient bit (bit 0 is free)
ud2:    DEY
        BNE     ud1
        RTS
.endm

        ORG     BASE

; =============================================================================
;  Page 1 of 3. Startup: find the NUL, the heap starts after it
; =============================================================================
start:  LDX     #0FFh
        TXS                     ; return stack empty
        JSR     rstip
st1:    JSR     getc
        BNE     st1             ; IP ends just past the NUL
        IF      CHECKED
        STA     KEYBUF          ; (A = 0) no key held back
        ENDIF
        LDA     IP
        STA     HEAP
        LDA     IP+1
        STA     HEAP+1
        JSR     rstip
        LDX     #DSE

; ---- the inner loop ---------------------------------------------------------
next:
        IF      CHECKED
        ; Both stacks are checked once per character. No handler moves X by
        ; more than 4, so X is caught before it wraps; an overrun by a cell
        ; or two writes on the scratch bytes below the stack. The return
        ; stack has overrun when S is below RSLIM (an underflow wraps S to
        ; 00-03).
        CPX     #DSE+1
        BCS     e_stack
        CPX     #DSFULL
        BCC     e_stack
        TXA                     ; TSX trashes X: keep it in A
        TSX
        CPX     #RSLIM
        TAX                     ; TAX leaves the carry alone
        BCC     e_rstack
        ENDIF
        JSR     step
        JMP     next
        IF      CHECKED
e_stack:LDA     #'S'            ; data stack over or under
        DB      2Ch             ; (BIT abs: hides the next instruction)
e_rstack:LDA    #'R'            ; return stack over or under
        JMP     error
        ENDIF

; ---- handlers of ! " # $ % & ' ( : they must start in this page -------------

; '$' prints the string at TOS, decoding escapes: '/' plus a character
; clears that character's bit 6 (/M is CR, /` is space; '/' and '"' have no
; bit 6, so // and /" give themselves).
h_print:JSR     tosget
        CMP     #22h
        BEQ     pdrop
        CMP     #'/'
        BNE     pr1
        JSR     tosget
        AND     #0BFh
pr1:    JSR     CONOUT
        JMP     h_print

h_emit: LDA     0,X             ; "'"
        JSR     CONOUT
pdrop:  INX                     ; a drop for this page's handlers
        INX
        RTS

; '#' prints TOS as a signed decimal number, with no space after it. The
; digits are divided off and held on the hardware stack, ended by a 0. udiv
; leaves each remainder in the scratch under the top cell.
h_num:  LDA     1,X
        BPL     pn1
        LDA     #'-'
        JSR     CONOUT
        JSR     neg
pn1:    LDA     #10
        STA     D0
        LDA     #0
        STA     D1
        PHA                     ; the end marker
pn2:    JSR     udiv
        LDA     0FEh,X
        ORA     #'0'
        PHA
        LDA     0,X
        ORA     1,X
        BNE     pn2
pn3:    PLA
        BEQ     pdrop
        JSR     CONOUT
        JMP     pn3

; '!' ( n addr -- ): the low byte, then '.'s ending for the high byte.
h_store:LDA     2,X
        IF      CHECKED
        JSR     chkst
        ENDIF
        STA     (0,X)
        JSR     inctos
        LDA     3,X
        JMP     st9

h_swap: LDA     0,X             ; '%'
        LDY     2,X
        STY     0,X
        STA     2,X
        LDA     1,X
        LDY     3,X
        STY     1,X
        STA     3,X
        RTS

; '&', and '|' and '^' further down: one byte of the result goes into NOS,
; and X moves up one. Done twice, that is both bytes, and NOS has become TOS.
h_and:  JSR     an1
an1:    LDA     0,X
        AND     2,X
        STA     2,X
        INX
        RTS

; 22h pushes the address of the text after it and skips the string.
h_str:  JSR     puship
; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it. Returns with Z set, A = 22h.
skipstr:JSR     getc
        CMP     #'/'
        BEQ     ss0
        CMP     #22h
        BNE     skipstr
        RTS
ss0:    JSR     incip
        BNE     skipstr         ; A is '/' here

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: JSR     flag            ; (keeps the carry clear)
        BEQ     skip
; pushn: take the step frame off, push the reading position on the return
; stack, and go on. With the carry set (a word call) the reading position
; then becomes the address in the letter cell at LET,Y.
pushn:  PLA
        PLA                     ; drop the step frame
        LDA     IP+1
        PHA
        LDA     IP
        PHA
        BCC     nxt
        LDA     LET,Y
        STA     IP
        LDA     LET+1,Y
        STA     IP+1
nxt:    JMP     next

; ---- no handler starts between here and the next heading: these routines
; ---- fill the space up to the page boundary and past it ---------------------

; skip: read past text to the closer at this level, and return it in A.
; Brackets of both kinds count together; strings are stepped over whole. A
; NUL first ends the program.
skip:   LDA     #0
        STA     T2              ; depth
sk1:    JSR     getc
        BEQ     endprog
        CMP     #22h
        BNE     sk2
        JSR     skipstr         ; leaves A = 22h, which matches nothing below
sk2:    CMP     #'('
        BEQ     sk3
        CMP     #'['
        BEQ     sk3
        CMP     #')'
        BEQ     sk4
        CMP     #']'
        BNE     sk1
sk4:    DEC     T2
        BPL     sk1
        RTS                     ; the closer at this level
sk3:    INC     T2
        BNE     sk1
endprog:JMP     EXIT

        IF      1-CHECKED
        UDIV
        ENDIF

; absv: TOS = |TOS|.  negm: TOS = -TOS if the N flag is set.
absv:   LDA     1,X
negm:   BPL     ab9
; neg: TOS = -TOS
neg:    SEC
neg1:   LDA     #0
        SBC     0,X
        STA     0,X
        LDA     #0
        SBC     1,X
        STA     1,X
ab9:    RTS

; =============================================================================
;  Page 2 of 3: handlers of ) * + , - . / : ; < = > ?
; =============================================================================

h_dup:  LDA     0,X             ; ':'
        LDY     1,X
        JMP     pushay

; '.' ( c addr -- ), and the end of '!': store A at TOS, drop both cells.
h_cstore:LDA    2,X
st9:
        IF      CHECKED
        JSR     chkst
        ENDIF
        STA     (0,X)
        INX
        INX
drop:   INX                     ; ';'
        INX
        RTS

; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  JSR     isdig
        BCC     negnum
sub1:   JSR     neg             ; a - b = a + (-b)
        CLC
; '+': one byte at a time, as the logic operators do; the carry goes across.
; It ends with A = the high byte of the sum.
h_add:  JSR     ad1
ad1:    LDA     0,X
        ADC     2,X
        STA     2,X
        INX
        RTS

negnum: LDA     #0              ; a number from 0 (the digit routine's start)
        JSR     digit           ; (comes back with the carry set)
        BCS     neg             ; always: the number, negated

; Signed compares: a - b sets N and V; N xor V is "a < b". The carry ends up
; clear for true, and bool turns it into -1 (true) or 0.
h_gt:   JSR     h_swap          ; a > b is b < a
h_lt:   LDA     2,X
        CMP     0,X
        LDA     3,X
        SBC     1,X
        BVS     lt1
        EOR     #80h
lt1:    ASL
        INX
        INX                     ; (keeps the carry; X is never 0)
        BNE     bool            ; always

h_eq:   JSR     sub1            ; a - b: zero if equal; A = its high byte
        ORA     0,X
        CMP     #1              ; carry clear if A = 0
bool:   LDA     #0
        ADC     #0FFh           ; carry clear: FF, set: 00
        STA     0,X
        STA     1,X
        RTS

; '*': the classic shift-right multiply. The multiplier is the NOS cell: it
; leaves from the bottom while the product comes in at the top, through
; A:T0 above it; after 16 rounds the cell holds the low 16 bits, which are
; all that is kept. Dropping TOS (the multiplicand) leaves it on top.
h_mul:  LDY     #16             ; the round count
        LDA     #0
        STA     T0              ; A:T0 = the upper half
        LSR     3,X
        ROR     2,X             ; the first multiplier bit
ml1:    BCC     ml2
        STA     T1
        CLC
        LDA     T0
        ADC     0,X
        STA     T0
        LDA     T1
        ADC     1,X             ; upper half += the multiplicand
ml2:    ROR
        ROR     T0
        ROR     3,X
        ROR     2,X             ; everything one place right; next bit out
        DEY
        BNE     ml1
        INX
        INX
        RTS

; '/' ( a b -- q r ): the remainder is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Dividing by zero is not checked: it returns two cells of no meaning.
; b's cell is dropped once D holds |b|; udiv then leaves the remainder just
; where that cell was, so stepping X back down makes it the top cell.
h_div:  LDA     3,X
        PHA                     ; a's sign: for r
        EOR     1,X
        PHA                     ; a xor b: for q
        JSR     absv
        LDA     0,X
        STA     D0
        LDA     1,X
        STA     D1              ; D = |b|
        INX
        INX
        JSR     absv            ; TOS = |a|
        JSR     udiv            ; TOS = q
        PLA
        JSR     negm            ; q's sign
        DEX
        DEX                     ; r on top
        PLA
        JMP     negm            ; r's sign

h_cfetch:LDA    (0,X)           ; ','
seta:   STA     0,X             ; TOS = A
        LDA     #0
        STA     1,X
        RTS

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on. It uses ']'s code, entered past its SEC: with the
; carry clear, as it is here, the address popped is pushed back.
h_close:JSR     flag
        BEQ     rdrop
        BNE     ret1            ; always

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. The buffer
;          holds 127 characters and the CR: a bigger count is taken as 127.
h_key:  LDA     1,X
        BMI     line
kt1:    LDY     #MSLOOP         ; one millisecond, roughly
kt2:    JSR     getk
        BNE     seta
        DEY
        BNE     kt2
        LDA     0,X             ; count the millisecond off:
        BNE     kt4
        LDA     1,X
        BEQ     kt1             ; 0? never counts down: it waits
        DEC     1,X
kt4:    DEC     0,X
        BNE     kt1
        LDA     1,X
        BNE     kt1
        BEQ     seta            ; always: the time ran out, A = 0

; ---- no handler starts between here and the next heading --------------------

; Backspace takes the last character back (and is echoed as it is), CR ends
; (stored, not echoed), every other key is stored and echoed until the line
; is full. Y = the length so far; T0 = the most allowed.
line:   JSR     neg             ; TOS = the count, and A = its high byte
        BNE     ln0
        LDA     0,X
        BPL     ln1
ln0:    LDA     #127            ; more than 127 is taken as 127
ln1:    STA     T0
        LDY     #0
        BEQ     ln2             ; always
ln3:    JSR     CONOUT
ln2:    JSR     getk
        BEQ     ln2
        CMP     #13
        BEQ     ln5
        CMP     #8
        BEQ     ln4
        CPY     T0
        BCS     ln2             ; full
        STA     LINEBUF,Y
        INY
        BNE     ln3             ; always: echo it
ln4:    DEY                     ; Backspace: one back, and echo it,
        BPL     ln3
        INY                     ;   unless the line was empty
        BEQ     ln2             ; always
ln5:    STA     LINEBUF,Y       ; A = CR
        LDA     #<LINEBUF
        LDY     #>LINEBUF
        JMP     setay           ; TOS = the line's address

; =============================================================================
;  Page 3 of 3: handlers of @ [ \ ] ^ _ ` { | } ~
; =============================================================================

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns.
h_break:JSR     flag
        BEQ     tg1             ; (an RTS)
        JSR     skip
        CMP     #')'
        BNE     h_ret
rdrop:  PLA
        PLA
        PLA
        PLA                     ; (the block start's high byte: never 0)
        BNE     nxt2            ; always

; ']' returns: pull an address and jump to it. ')' comes in at ret1 with the
; carry clear, and then the address is pushed back.
h_ret:  SEC
ret1:
        IF      CHECKED
        JSR     chkbrk          ; Ctrl-C is checked at every loop-back and
        ENDIF                   ;   every word return (it keeps the carry)
        PLA
        PLA                     ; drop the step frame
        PLA
        STA     IP
        PLA
        STA     IP+1
        BCS     nxt2
        PHA                     ; ')': keep the block start
        LDA     IP
        PHA
        BCC     nxt2            ; always

; '{' TOS to the return stack, '}' return stack to TOS
h_tor:  PLA
        PLA
        LDA     1,X
        PHA
        LDA     0,X
        PHA
        INX
        INX
        BNE     nxt2            ; always: X is never 0

h_fromr:PLA
        PLA
        DEX
        DEX
        PLA
        STA     0,X
        PLA
        STA     1,X
nxt2:   JMP     next

; '~': -x - 1, which is neg with the carry clear, as it is here
h_not:  JMP     neg1

h_xor:  JSR     xr1
xr1:    LDA     0,X
        EOR     2,X
        STA     2,X
        INX
        RTS

h_or:   JSR     or1
or1:    LDA     0,X
        ORA     2,X
        STA     2,X
        INX
        RTS

h_fetch:LDA     (0,X)           ; '@'
        TAY
        JSR     inctos
        LDA     (0,X)
        STA     1,X
        STY     0,X
        RTS

; tosget: A = the byte at TOS, and TOS moves on.  inctos: TOS moves on.
tosget: LDA     (0,X)
inctos: INC     0,X
        BNE     tg1
        INC     1,X
tg1:    RTS

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything that is not a letter as the space; the
; checked build stops on it.)
        IF      CHECKED
def1:   CPY     #' '-'A'+256
        BEQ     def2
e_brack:LDA     #'D'            ; anything but a letter or a space
        JMP     error
        ENDIF
h_def:  JSR     getc
        SEC
        SBC     #'A'            ; a letter gives 0-25 or 32-57: lowercase
        TAY                     ;   lands 64 bytes up
        AND     #0DFh           ; fold case: 0-25 only for a letter
        CMP     #26
        IF      1-CHECKED
        BCS     def2            ; not a letter
        ENDIF
        IF      CHECKED
        BCS     def1
        ENDIF
        TYA
        ASL
        TAY                     ; Y -> the cell
        LDA     IP
        STA     LET,Y
        LDA     IP+1
        STA     LET+1,Y
        BNE     dsk             ; always: no program is in page zero
def2:   JSR     puship          ; an anonymous block: push its address
dsk:    JMP     skip

; '_' ( n -- addr ): the heap pointer moves up by n; TOS is the old pointer.
; (The carry is clear on the way in.)
h_alloc:LDA     HEAP
        TAY
        ADC     0,X
        STA     HEAP
        STY     0,X
        LDA     HEAP+1
        TAY
        ADC     1,X
        IF      CHECKED
        BCS     e_heap          ; a negative count wraps: too big
        CMP     #HEAPLIM
        BCS     e_heap          ; the new top must stay below the limit page
        ENDIF
        STA     HEAP+1
        STY     1,X
        RTS
        IF      CHECKED
e_heap: LDA     #'H'            ; heap past the limit
        DB      2Ch             ; (BIT abs: hides the next instruction)
e_store:LDA     #'W'            ; write outside the program's space
        JMP     error

; chkst: stop unless the address in the top cell is in the program's own
; space, from the letter page up to the heap limit. Keeps A and Y.
chkst:  PHA
        LDA     1,X
        CMP     #LETPAGE
        BCC     e_store
        CMP     #HEAPLIM
        BCS     e_store
        PLA
        RTS
        ENDIF

; ---- machine code: the grave (the last handler: its body may leave the page)
; '`' plus a hex digit loads bytes: ( addr -- addr' ). Pairs of hex digits
; are stored from addr until a non-hex character; then a RET (60h) is
; written and its address is left. An odd last digit is consumed and dropped.
; '`' plus anything else calls the machine code at TOS: ( addr -- ); see the
; contract in the header.
h_grave:JSR     rdhex
        BCS     exec
hx1:    ASL
        ASL
        ASL
        ASL
        STA     T0
        JSR     rdhex
        BCS     hx2             ; odd digit: already consumed, dropped
        ORA     T0
        IF      CHECKED
        JSR     chkst
        ENDIF
        STA     (0,X)
        JSR     inctos
        JSR     rdhex
        BCC     hx1
hx2:    LDA     #60h
        IF      CHECKED
        JSR     chkst
        ENDIF
        STA     (0,X)
        RTS

exec:   LDA     0,X
        STA     T0
        LDA     1,X
        STA     T1
        INX                     ; the address is consumed
        INX
        JMP     (T0)

; =============================================================================
;  The rest: no handler starts past this point
; =============================================================================

        IF      CHECKED
        UDIV
        ENDIF

; step: read one character and sort it by range.
;    00h          end of program
;    01h-20h, 7Fh-FFh   ignored
;    30h-39h      digit: read a whole number
;    41h-5Ah      A-Z: call the word in that letter's cell
;    61h-7Ah      a-z: push the address of that letter's cell
;    the rest     punctuation: jump through PTAB, 32 entries, in code order
step:   JSR     getc            ; flags follow A
        BEQ     endp
        SEC
        SBC     #21h            ; A = c - 21h
        BCC     ign             ; 01h-20h
        CMP     #0Fh
        BCC     punct           ; 21h-2Fh: index 0-14
        SBC     #0Fh            ; (carry set) A = c - 30h
        CMP     #10
        BCC     digit
        CMP     #11h
        BCC     p3a             ; 3Ah-40h
        SBC     #11h            ; (carry set) A = c - 41h
        CMP     #1Ah
        BCC     upper           ; 41h-5Ah
        CMP     #20h
        BCC     p5b             ; 5Bh-60h
        CMP     #3Ah
        BCC     lower           ; 61h-7Ah: A = 20h-39h
        CMP     #3Eh
        BCS     ign             ; 7Fh-FFh
        ; The three adjustments below chain. Each ADC adds the carry the one
        ; before it left, which the constants allow for.
        SBC     #1Ah            ; 7Bh-7Eh: (carry clear: -1Bh) index 28-31
p5b:    ADC     #0F6h           ; 5Bh-60h: -10 (-9 when chained), index 22-27
p3a:    ADC     #5              ; 3Ah-40h: +5 (+6 when chained), index 15-21
; Punctuation: A = the index. The handler's page is the first, plus one if
; the index is N1 or more, plus one more if it is N2 or more.
punct:  CMP     #N1
        TAY
        LDA     #HALFPG
        ROL                     ; the first page, or the second (carry clear)
        CPY     #N2
        ADC     #0              ; ... or the third (and the carry is clear)
        PHA
        LDA     PTAB,Y
        PHA
ign:    RTS                     ; RTS trick: goes to the handler. Reached
                                ; directly, it just ends an ignored character.
endp:   JMP     EXIT            ; the program has ended

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  ASL
        TAY
        SEC
        JMP     pushn

puship: LDA     IP              ; push the reading position
        LDY     IP+1
        BNE     pushay          ; always: no program is in page zero

; a-z: push the cell's address (the cell is the variable)
lower:  ASL
        LDY     #>LET
; pushay: push a cell: A = its low byte, Y = its high byte
pushay: DEX
        DEX
setay:  STA     0,X             ; setay: TOS = A (low), Y (high)
        STY     1,X
        RTS

; flag: pops TOS and returns with Z set if it was 0. Keeps the carry.
flag:   INX
        INX
        LDA     0FEh,X
        ORA     0FFh,X
        RTS

; =============================================================================
;  Dispatch table: the low byte of (handler - 1) for each punctuation
;  character, in code order.
; =============================================================================
PTAB:   DB      (h_store-1) & 0FFh      ; !
        DB      (h_str-1) & 0FFh        ; "
        DB      (h_num-1) & 0FFh        ; #
        DB      (h_print-1) & 0FFh      ; $
        DB      (h_swap-1) & 0FFh       ; %
        DB      (h_and-1) & 0FFh        ; &
        DB      (h_emit-1) & 0FFh       ; '
        DB      (h_open-1) & 0FFh       ; (
        DB      (h_close-1) & 0FFh      ; )
        DB      (h_mul-1) & 0FFh        ; *
        DB      (h_add-1) & 0FFh        ; +
        DB      (h_cfetch-1) & 0FFh     ; ,
        DB      (h_sub-1) & 0FFh        ; -
        DB      (h_cstore-1) & 0FFh     ; .
        DB      (h_div-1) & 0FFh        ; /
        DB      (h_dup-1) & 0FFh        ; :
        DB      (drop-1) & 0FFh         ; ;
        DB      (h_lt-1) & 0FFh         ; <
        DB      (h_eq-1) & 0FFh         ; =
        DB      (h_gt-1) & 0FFh         ; >
        DB      (h_key-1) & 0FFh        ; ?
        DB      (h_fetch-1) & 0FFh      ; @
        DB      (h_def-1) & 0FFh        ; [
        DB      (h_break-1) & 0FFh      ; \
        DB      (h_ret-1) & 0FFh        ; ]
        DB      (h_xor-1) & 0FFh        ; ^
        DB      (h_alloc-1) & 0FFh      ; _
        DB      (h_grave-1) & 0FFh      ; `
        DB      (h_tor-1) & 0FFh        ; {
        DB      (h_or-1) & 0FFh         ; |
        DB      (h_fromr-1) & 0FFh      ; }
        DB      (h_not-1) & 0FFh        ; ~

; Digits: the first one is in A; read the rest of the number.
digit:  LDY     #0
        JSR     pushay
; rdnum: TOS = TOS*10 + digit for each digit at IP. Wraps at 16 bits.
; Returns with the carry set.
rdnum:  JSR     isdig
        BCS     ic9             ; (an RTS)
        JSR     incip           ; (keeps A = the digit)
        ASL     0,X
        ROL     1,X             ; x2
        CLC
        ADC     0,X
        STA     T0
        LDA     1,X
        ADC     #0
        STA     T1              ; T = x2 + digit
        ASL     0,X
        ROL     1,X
        ASL     0,X
        ROL     1,X             ; x8
        CLC
        LDA     0,X
        ADC     T0
        STA     0,X
        LDA     1,X
        ADC     T1
        STA     1,X             ; x8 + x2 + digit
        JMP     rdnum

; isdig: A = the character at IP minus '0'; the carry is clear if it is a
; digit. Y = 0.
isdig:  JSR     peek
        SEC
        SBC     #'0'
        CMP     #10
        RTS

; rdhex: if IP is at a hex digit (0-9, A-F, a-f), return its value in A with
; the carry clear and IP moved on; otherwise the carry is set and IP stays.
rdhex:  JSR     isdig
        BCC     incip
        AND     #0DFh
        SBC     #11h            ; (the carry is set)
        CMP     #6
        BCS     ic9
        ADC     #10
        BNE     incip           ; always

; Reading the program
;    peek: A = the character at IP, IP unchanged, Y = 0
;    getc: the same, then IP moves on; flags follow A
;    incip: IP moves on; keeps A, the carry and Y
getc:   JSR     peek
incip:  INC     IP
        BNE     ic1
        INC     IP+1
ic1:    ORA     #0
ic9:    RTS
peek:   LDY     #0
        LDA     (IP),Y
        RTS

; rstip: point IP at the start of the program
rstip:  LDA     #<PROG
        STA     IP
        LDA     #>PROG
        STA     IP+1
        RTS

; =============================================================================
;  Console layer: getk returns a waiting key in A (zero flag clear), or
;  A = 0 with the zero flag set when none is waiting. CONOUT prints A.
;  Both keep X and Y. In the unchecked build getk is the host's KEY itself.
; =============================================================================
        IF      1-CHECKED
getk    EQU     KEY             ; the host's routine does the whole job
        ENDIF
        IF      CHECKED
getk:   LDA     KEYBUF          ; a key held back by the break check
        BEQ     gk1
        PHA
        LDA     #0
        STA     KEYBUF
        PLA
        RTS
gk1:    JMP     KEY

; =============================================================================
;  Checked build: break key and error reports
; =============================================================================
; chkbrk: a waiting key is read now; Ctrl-C stops the program, anything
; else is held for the next '?'. Keeps the flags.
chkbrk: PHP
        JSR     getk
        BEQ     cb9
        CMP     #3
        BEQ     e_break
        STA     KEYBUF
cb9:    PLP
        RTS
e_break:LDA     #'B'            ; Ctrl-C
; error: print the letter in A, " @ " and the offset in the program of the
; character just read, then end. For example: S @ 245
; The hardware stack is left as it is: it wraps inside its page, so the
; calls below work whatever state it is in.
error:  LDX     #DSE-2          ; one cell, for the number
        JSR     CONOUT
        LDA     #' '
        JSR     CONOUT
        LDA     #'@'
        JSR     CONOUT
        LDA     #' '
        JSR     CONOUT
        LDA     IP
        SEC
        SBC     #<PROG1         ; the character just read
        STA     0,X
        LDA     IP+1
        SBC     #>PROG1
        STA     1,X
        JSR     h_num
        JMP     endp
        ENDIF
