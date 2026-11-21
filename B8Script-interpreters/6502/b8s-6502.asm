; =============================================================================
;  B8Script interpreter for the 6502 (NMOS opcodes only)
;  Spec: docs/b8script.md (2026-10-09) plus the 2026-11-20 changes:
;        [x stores in a variable, "[ " pushes an anonymous block, any other
;        character after [ is an error, the heap pointer lives at z10+.
;        The string escape is '/' (it was '>').
;        '/' leaves ( r q ), the quotient on top; dividing by zero is not
;        checked. -n? does no more editing than Backspace.
;  Design follows the Z80 interpreter; see b8s-z80.asm for the common ideas.
;
;  Two switches, set in the EQU lines below:
;    ZPSTACK  0 = the data stack is in pages 2 and 3: 252 cells
;             1 = the data stack is in zero page: 112 cells, and a smaller
;                 interpreter, because every stack access is a byte shorter.
;                 The memory map and the machine-code contract differ: see
;                 below.
;    CHECKED  0 = no checks (spec: "B8Script checks nothing")
;             1 = stops on stack overrun, Ctrl-C, heap past the limit, a store
;                 outside the program's own space, and a bad character after [,
;                 printing a letter and the place, like  S @ 245
;
;  Assembler: asm80, C6502 mode.
; =============================================================================

ZPSTACK EQU     0               ; 1 = data stack in zero page
CHECKED EQU     0               ; 1 = checked build

; -----------------------------------------------------------------------------
;  Registers and zero page
;
;    IP      zero-page pointer to the next program character (16 bits)
;    TL/TH   the top data-stack cell (TOS) lives in zero page, not in memory
;    X       data-stack index. The stack is two byte-planes, grows down, and
;            holds everything under TOS: NOS is DSL,X (low) and DSH,X (high).
;            The stack never leaves its planes because X is 8 bits.
;    S       the hardware stack is the RETURN stack: a word call or "(" pushes
;            the reading position (high byte first, then low) and "]" or ")"
;            pulls it. 100 entries (200 bytes) fit with room to spare.
;    Y, A    scratch. Y is 0 after peek/getc, and the zero-page indirect reads
;            (IP),Y rely on that.
;
;  Dispatch: step is called with JSR, so a handler ends with a plain RTS and
;  lands on "JMP next" in the loop. Punctuation goes through PTAB with the
;  RTS trick (push handler-1, RTS). Handlers that use the return stack ( ( ) \
;  ] { } and word calls ) first pull the 2-byte JSR frame off (PLA PLA) and end
;  with JMP next instead.
;
;  Every punctuation handler starts with the carry clear (the range sort in
;  step leaves it so). Several of them count on that, where the comments say.
;
;  Machine-code contract (the grave): the code at TOS is entered as a
;  subroutine, by JMP (T0) with the loop's return address on the hardware
;  stack, so it ends with RTS (60h, which the hex loader appends). On entry
;  TL/TH ($02/$03) hold the new TOS (the address is already consumed) and X is
;  the data-stack index: NOS is DSL,X (low) and DSH,X (high), which is
;  $0200,X and $0300,X, or $10,X and $80,X when the stack is in zero page.
;  To push: DEX, store TL/TH at DSL,X/DSH,X, then set TL/TH. To drop: load
;  TL/TH from DSL,X/DSH,X and INX. The code may change A, Y, X (it is the
;  stack index, so it must stay consistent on return) and zero page $04-$06
;  and $08-$09; it must keep IP ($00/$01) and the hardware stack balanced. On
;  return TL/TH are the TOS. Zero page $0A-$0F is free for the code's own use.
; -----------------------------------------------------------------------------
IP      EQU     00h             ; 00-01 reading position
TL      EQU     02h             ; TOS low
TH      EQU     03h             ; TOS high
T0      EQU     04h             ; scratch
T1      EQU     05h
T2      EQU     06h
D0      EQU     08h             ; divisor (division, number printing)
D1      EQU     09h

; -----------------------------------------------------------------------------
;  Memory map
;
;    0000-00FF  zero page: the variables above; with ZPSTACK = 1 also the data
;               stack: low bytes at 10-7F, high bytes at 80-EF (X = 70 when
;               empty: 112 cells)
;    0100-01FF  hardware stack = return stack, S starts at FF
;    0200       with ZPSTACK = 0: DSL, data stack, low bytes (X = FC when
;    0300       empty: 252 cells) and DSH, high bytes. With ZPSTACK = 1 these
;               two pages are not used.
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
        IF      ZPSTACK
DSL     EQU     10h             ; data stack, low bytes
DSH     EQU     80h             ; data stack, high bytes
DSE     EQU     70h             ; X when the data stack is empty
        ENDIF
        IFN     ZPSTACK
DSL     EQU     0200h
DSH     EQU     0300h
DSE     EQU     0FCh
        ENDIF
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

        ORG     0E000h

; =============================================================================
;  Startup: find the NUL, the heap starts after it
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

; =============================================================================
;  The inner loop
; =============================================================================
next:
        IF      CHECKED
        ; Both stacks are checked once per character. The data stack has
        ; overrun when X is above DSE (an overflow wraps X to FF, an underflow
        ; moves it up; no handler moves X by more than 2). The return stack
        ; has when S is below RSLIM (an underflow wraps S to 00-03).
        CPX     #DSE+1
        BCS     e_stack
        TXA                     ; TSX trashes X: keep it in A
        TSX
        CPX     #RSLIM
        TAX                     ; TAX leaves the carry alone
        BCC     e_rstack
        ENDIF
        JSR     step
        JMP     next

; step: read one character and sort it by range.
;    00h          end of program
;    01h-20h, 7Fh-FFh   ignored
;    30h-39h      digit: read a whole number
;    41h-5Ah      A-Z: call the word in that letter's cell
;    61h-7Ah      a-z: push the address of that letter's cell
;    the rest     punctuation: jump through PTAB, 32 entries, in code order
; Every way out of the sort has the carry clear, except "ignored".
step:   JSR     getc            ; flags follow A
        BEQ     endprog
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
punct:  ASL                     ; (the index is small: the carry stays clear)
        TAY
        LDA     PTAB+1,Y
        PHA
        LDA     PTAB,Y
        PHA
ign:    RTS                     ; RTS trick: goes to the handler. Reached
                                ; directly, it just ends an ignored character.
endprog:JMP     EXIT
        IF      CHECKED
e_stack:LDA     #'S'            ; data stack over or under
        DB      2Ch             ; (BIT abs: hides the next instruction)
e_rstack:LDA    #'R'            ; return stack over or under
        JMP     error
        ENDIF

; Digits: the first one is in A; read the rest of the number.
digit:  TAY
        JSR     push
        STY     TL
        LDA     #0
        STA     TH
        JMP     rdnum

; a-z: push the cell's address (the cell is the variable)
lower:  ASL
        TAY
        JSR     push
        STY     TL
        LDA     #>LET
        STA     TH
        RTS

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

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  ASL
        TAY
        SEC
        BCS     pushn           ; always

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything below 'A' as the space, and anything
; from 'A' up as a letter.)
h_def:  JSR     getc
        IF      CHECKED
        CMP     #' '
        BEQ     def2
        ENDIF
        SEC
        SBC     #'A'            ; 0-25 or 32-57: lowercase lands 64 bytes up
        IF      1-CHECKED
        BCC     def2
        ENDIF
        IF      CHECKED
        TAY
        AND     #0DFh           ; fold case: 0-25 only for a letter
        CMP     #26
        BCS     e_brack         ; anything but a letter or a space
        TYA
        ENDIF
        ASL
        TAY                     ; Y -> the cell
        LDA     IP
        STA     LET,Y
        LDA     IP+1
        STA     LET+1,Y
        BNE     skip            ; always: no program is in page zero
def2:   JSR     puship          ; an anonymous block: push its address

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
        IF      CHECKED
e_brack:LDA     #'D'            ; bad character after [
        JMP     error
        ENDIF

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

; =============================================================================
;  Dispatch table: one handler per punctuation character, in code order.
;  Entries are handler-1 for the RTS trick.
; =============================================================================
PTAB:   DW      h_store-1       ; !
        DW      h_str-1         ; "
        DW      h_num-1         ; #
        DW      h_print-1       ; $
        DW      h_swap-1        ; %
        DW      h_and-1         ; &
        DW      h_emit-1        ; '
        DW      h_open-1        ; (
        DW      h_close-1       ; )
        DW      h_mul-1         ; *
        DW      h_add-1         ; +
        DW      h_cfetch-1      ; ,
        DW      h_sub-1         ; -
        DW      h_cstore-1      ; .
        DW      h_div-1         ; /
        DW      push-1          ; :
        DW      drop-1          ; ;
        DW      h_lt-1          ; <
        DW      h_eq-1          ; =
        DW      h_gt-1          ; >
        DW      h_key-1         ; ?
        DW      h_fetch-1       ; @
        DW      h_def-1         ; [
        DW      h_break-1       ; \
        DW      h_ret-1         ; ]
        DW      h_xor-1         ; ^
        DW      h_alloc-1       ; _
        DW      h_grave-1       ; `
        DW      h_tor-1         ; {
        DW      h_or-1          ; |
        DW      h_fromr-1       ; }
        DW      h_not-1         ; ~

; rdnum: TOS = TOS*10 + digit for each digit at IP. Wraps at 16 bits. The
; test is at the bottom so the loop closes with a branch. Returns with the
; carry set.
rd1:    JSR     incip           ; (keeps A = the digit)
        ASL     TL
        ROL     TH              ; x2
        CLC
        ADC     TL
        STA     T0
        LDA     TH
        ADC     #0
        STA     T1              ; T = x2 + digit
        ASL     TL
        ROL     TH
        ASL     TL
        ROL     TH              ; x8
        CLC
        LDA     TL
        ADC     T0
        STA     TL
        LDA     TH
        ADC     T1
        STA     TH              ; x8 + x2 + digit
rdnum:  JSR     isdig
        BCC     rd1
        RTS

; isdig: A = the character at IP minus '0'; the carry is clear if it is a
; digit. Y = 0.
isdig:  JSR     peek
        SEC
        SBC     #'0'
        CMP     #10
        RTS

; =============================================================================
;  Reading the program
;    peek: A = the character at IP, IP unchanged, Y = 0
;    getc: the same, then IP moves on; flags follow A
;    incip: IP moves on; keeps A, the carry and Y
; =============================================================================
peek:   LDY     #0
        LDA     (IP),Y
        RTS
getc:   JSR     peek
incip:  INC     IP
        BNE     ic1
        INC     IP+1
ic1:    ORA     #0
        RTS

; rstip: point IP at the start of the program
rstip:  LDA     #<PROG
        STA     IP
        LDA     #>PROG
        STA     IP+1
        RTS

; =============================================================================
;  Stack
; =============================================================================
puship: JSR     push            ; push the reading position
        LDA     IP
        STA     TL
        LDA     IP+1
        STA     TH
        RTS

push:   DEX                     ; ':' and every push
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        RTS

; flag: pops TOS and returns with Z set if it was 0. Keeps the carry.
flag:   LDA     TL
        ORA     TH
        JSR     drop
        TAY                     ; (drop's INX changed the flags)
        RTS

; '!' ( n addr -- ) is '.' plus the high byte. Both end in drop.
h_store:
        IF      CHECKED
        LDA     TL              ; both bytes must be in the program's space:
        ADC     #1              ; check the page of addr+1 (the carry is
        LDA     TH              ; clear on the way in)
        ADC     #0
        JSR     chkst
        ENDIF
        LDA     DSH,X
        LDY     #1
        STA     (TL),Y
h_cstore:                       ; '.' ( c addr -- )
        IF      CHECKED
        LDA     TH
        JSR     chkst
        ENDIF
        LDA     DSL,X
        LDY     #0
        STA     (TL),Y
        INX                     ; falls into drop

; drop: ';' and every drop. It works through Y, so A and the carry are kept;
; it returns with Z clear.
drop:   LDY     DSL,X
        STY     TL
        LDY     DSH,X
        STY     TH
        INX
        RTS

; '{' TOS to the return stack, '}' return stack to TOS
h_tor:  PLA
        PLA
        LDA     TH
        PHA
        LDA     TL
        PHA
        JSR     drop
        BNE     nxt2            ; always

h_fromr:PLA
        PLA
        JSR     push
        PLA
        STA     TL
        PLA
        STA     TH
nxt2:   JMP     next

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on. It shares ']'s code: with the carry clear, as
; it is here, the address popped is pushed back.
h_close:JSR     flag
        BEQ     rdrop
        DB      24h             ; (BIT zp: steps over the SEC)
; ']' returns: pull an address and jump to it.
h_ret:  SEC
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

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns.
h_break:JSR     flag
        BEQ     ab9
        JSR     skip
        CMP     #')'
        BNE     h_ret
rdrop:  PLA
        PLA
        PLA
        PLA
        JMP     next

; =============================================================================
;  Arithmetic and logic. Effects are ( NOS TOS -- result ).
; =============================================================================
; The logic operators leave the carry as they found it, clear, so they can
; branch to fin.
h_and:  LDA     DSL,X
        AND     TL
        STA     TL
        LDA     DSH,X
        AND     TH
        BCC     fin             ; always

h_or:   LDA     DSL,X
        ORA     TL
        STA     TL
        LDA     DSH,X
        ORA     TH
        BCC     fin             ; always

h_xor:  LDA     DSL,X
        EOR     TL
        STA     TL
        LDA     DSH,X
        EOR     TH
        BCC     fin             ; always

; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  JSR     isdig
        BCC     negnum
sub1:   JSR     neg             ; a - b = a + (-b)
h_add:  CLC
        LDA     DSL,X
        ADC     TL
        STA     TL
        LDA     DSH,X
        ADC     TH              ; falls into fin

; fin: finish a two-operand op: A = the high byte of the result
fin:    STA     TH
        INX
        RTS

negnum: LDA     #0              ; a number from 0 (the digit routine's start)
        JSR     digit           ; (comes back with the carry set)
        BCS     neg             ; always: the number, negated

; '~': -x - 1, which is neg with the carry clear, as it is here
h_not:  BCC     neg1            ; always

; absv: TOS = |TOS|.  negm: TOS = -TOS if the N flag is set.
absv:   LDA     TH
negm:   BPL     ab9
; neg: TOS = -TOS
neg:    SEC
neg1:   LDA     #0
        SBC     TL
        STA     TL
        LDA     #0
        SBC     TH
        STA     TH
ab9:    RTS

; Signed compares: a - b sets N and V; N xor V is "a < b". The carry ends up
; clear for true, and bool turns it into -1 (true) or 0 (both pop NOS first).
h_gt:   JSR     h_swap          ; a > b is b < a
h_lt:   LDA     DSL,X
        CMP     TL
        LDA     DSH,X
        SBC     TH
        BVS     lt1
        EOR     #80h
lt1:    ASL
        INX                     ; (keeps the carry; never leaves X at 0)
        BNE     bool            ; always

h_eq:   JSR     sub1            ; a - b: zero if equal; A = its high byte
        ORA     TL
        CMP     #1              ; carry clear if A = 0
bool:   LDA     #0
        ADC     #0FFh           ; carry clear: FF, set: 00
        STA     TL
        STA     TH
        RTS

; '*': the classic shift-right multiply. The multiplier leaves TH:TL from the
; bottom while the product comes in at the top, through A:T0 above it; after
; 16 rounds TH:TL hold the low 16 bits, which are all that is kept.
h_mul:  LDY     #16
        STY     T1              ; the round count
        LDA     #0
        STA     T0              ; A:T0 = the upper half
        LSR     TH
        ROR     TL              ; the first multiplier bit
ml1:    BCC     ml2
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X           ; upper half += the multiplicand
ml2:    ROR
        ROR     T0
        ROR     TH
        ROR     TL              ; everything one place right; next bit out
        DEC     T1
        BNE     ml1
        INX                     ; drop the multiplicand
        RTS

h_swap: LDY     DSL,X           ; '%'
        LDA     TL
        STA     DSL,X
        STY     TL
        LDY     DSH,X
        LDA     TH
        STA     DSH,X
        STY     TH
        RTS

; '/' ( a b -- r q ): the quotient is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Dividing by zero is not checked: it returns two cells of no meaning.
h_div:  LDA     DSH,X
        PHA                     ; a's sign: for r
        EOR     TH
        PHA                     ; a xor b: for q
        JSR     absv
        LDA     TL
        STA     D0
        LDA     TH
        STA     D1              ; D = |b|
        LDA     DSL,X
        STA     TL
        LDA     DSH,X
        STA     TH
        JSR     absv            ; TOS = |a|
        JSR     udiv            ; TOS = q, NOS = r
        PLA
        JSR     negm            ; q's sign
        PLA
        BPL     ud9             ; r's sign:
        JSR     h_swap          ;   bring r up,
        JSR     neg             ;   negate it,
        JMP     h_swap          ;   and put it back

; udiv: unsigned TOS / D (D <= 8000h). TOS becomes the quotient and the NOS
; cell the remainder (whatever was there is lost).
udiv:   LDA     #0
        STA     DSL,X
        STA     DSH,X
        LDY     #16
ud1:    ASL     TL
        ROL     TH
        ROL     DSL,X
        ROL     DSH,X
        SEC
        LDA     DSL,X
        SBC     D0
        STA     T0
        LDA     DSH,X
        SBC     D1
        BCC     ud2
        STA     DSH,X
        LDA     T0
        STA     DSL,X
        INC     TL              ; the quotient bit (TL's bit 0 is free)
ud2:    DEY
        BNE     ud1
ud9:    RTS

; =============================================================================
;  Storage
; =============================================================================
; '_' ( n -- addr ): the heap pointer moves up by n; TOS is the old pointer.
; (The carry is clear on the way in.)
h_alloc:LDA     HEAP
        TAY
        ADC     TL
        STA     HEAP
        STY     TL
        LDA     HEAP+1
        TAY
        ADC     TH
        IF      CHECKED
        BCS     e_heap          ; a negative count wraps: too big
        CMP     #HEAPLIM
        BCS     e_heap          ; the new top must stay below the limit page
        ENDIF
        STA     HEAP+1
        STY     TH
        RTS
        IF      CHECKED
e_heap: LDA     #'H'            ; heap past the limit
        DB      2Ch             ; (BIT abs: hides the next instruction)
e_store:LDA     #'W'            ; write outside the program's space
        JMP     error

; chkst: stop unless the page in A is in the program's own space, from the
; letter page up to the heap limit. Keeps Y.
chkst:  CMP     #LETPAGE
        BCC     e_store
        CMP     #HEAPLIM
        BCS     e_store
        RTS
        ENDIF

; =============================================================================
;  Console
; =============================================================================

; tosget: A = the byte at TOS, and TOS moves on.  inctos: TOS moves on.
tosget: LDY     #0
        LDA     (TL),Y
inctos: INC     TL
        BNE     tg1
        INC     TH
tg1:    RTS

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

h_emit: LDA     TL              ; "'"
        JSR     CONOUT
pdrop:  JMP     drop

; '#' prints TOS as a signed decimal number, with no space after it. The
; digits are divided off and held on the hardware stack, ended by a 0. udiv
; leaves each remainder in the NOS cell, so a spare cell is opened for it.
h_num:  LDA     TH
        BPL     pn1
        LDA     #'-'
        JSR     CONOUT
        JSR     neg
pn1:    DEX                     ; the spare cell
        LDA     #10
        STA     D0
        LDA     #0
        STA     D1
        PHA                     ; the end marker
pn2:    JSR     udiv
        LDA     DSL,X
        ORA     #'0'
        PHA
        LDA     TL
        ORA     TH
        BNE     pn2
        INX
pn3:    PLA
        BEQ     pdrop
        JSR     CONOUT
        JMP     pn3

h_fetch:LDY     #1              ; '@'
        LDA     (TL),Y
        PHA                     ; the high byte, while ',' gets the low one
        JSR     h_cfetch
        PLA
        STA     TH
        RTS

h_cfetch:                       ; ','
        LDY     #0
        LDA     (TL),Y
cf2:    STA     TL              ; TOS = A (Y = 0)
        STY     TH
        RTS

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. n is not
;          checked: the buffer holds 127 characters and the CR, so a
;          program must ask for 127 or fewer.
h_key:  LDA     TH
        BMI     line
kt1:    LDY     #MSLOOP         ; one millisecond, roughly
kt2:    JSR     getk
        BNE     kt3
        DEY
        BNE     kt2
        LDA     TL              ; count the millisecond off:
        BNE     kt4
        LDA     TH
        BEQ     kt1             ; 0? never counts down: it waits
        DEC     TH
kt4:    DEC     TL
        BNE     kt1
        LDA     TH
        BNE     kt1             ; A = 0 if the time ran out
kt3:    LDY     #0
        BEQ     cf2             ; always: TOS = A

; Backspace takes the last character back (and is echoed as it is), CR ends
; (stored, not echoed), every other key is stored and echoed until the line
; is full. Y = the length so far; TL = the most allowed.
line:   JSR     neg             ; TL = the count
        LDY     #0
        BEQ     ln2             ; always
ln3:    JSR     CONOUT
ln2:    JSR     getk
        BEQ     ln2
        CMP     #13
        BEQ     ln5
        CMP     #8
        BEQ     ln4
        CPY     TL
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
        STA     TL
        LDA     #>LINEBUF
        STA     TH
        RTS

; =============================================================================
;  Machine code: the grave
; =============================================================================
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
        STA     T0
        LDA     TH
        JSR     chkst
        LDA     T0
        ENDIF
        STA     (TL),Y          ; Y is 0 after rdhex
        JSR     inctos
        JSR     rdhex
        BCC     hx1
hx2:
        IF      CHECKED
        LDA     TH
        JSR     chkst
        ENDIF
        LDA     #60h
        STA     (TL),Y
        RTS

exec:   LDA     TL
        STA     T0
        LDA     TH
        STA     T1
        JSR     drop            ; the address is consumed
        JMP     (T0)

; rdhex: if IP is at a hex digit (0-9, A-F, a-f), return its value in A with
; the carry clear and IP moved on; otherwise the carry is set and IP stays.
; Y = 0.
rdhex:  JSR     isdig
        BCC     rh1
        AND     #0DFh
        SBC     #11h            ; (the carry is set)
        CMP     #6
        BCS     rh9
        ADC     #10
rh1:    JMP     incip
rh9:    RTS

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
        ENDIF

; =============================================================================
;  Checked build: break key and error reports
; =============================================================================
        IF      CHECKED
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
error:  LDX     #DSE            ; (the number printer uses a data cell)
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
        STA     TL
        LDA     IP+1
        SBC     #>PROG1
        STA     TH
        JSR     h_num
        JMP     endprog
        ENDIF
