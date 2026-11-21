; =============================================================================
;  B8Script interpreter for the 6502 (NMOS opcodes only)
;  Spec: docs/b8script.md (2026-11-21). -n? does no more editing than
;        Backspace. The break key is checked in the checked build only (at
;        every ')' loop-back and every return).
;  Design follows the Z80 interpreter; see b8s-z80.asm for the common ideas.
;
;  This interpreter keeps the data stack in pages 2 and 3 (252 cells) and
;  uses 10 bytes of zero page. b8s-6502-zp.asm is a smaller interpreter that
;  keeps the stack in zero page instead (112 cells); its memory map and
;  machine-code contract differ.
;
;  One switch, set in the EQU line below:
;    CHECKED  0 = no checks: whatever the spec calls unsafe is not caught
;             1 = a checked build, as in the spec's "Errors and checked
;                 builds": at startup every word cell points at 0000h (see
;                 e_undef) and the variables and the interpreter's cells are
;                 0. It stops with S s R r (stack over/underflow), H (heap),
;                 O (a store outside the program's space), U (undefined
;                 word), Q (no closing quote), W (bad character after [), X
;                 (a reserved byte), Z (divide by zero), N (brackets) or B
;                 (Ctrl-C), printing the spec's four-line report:
;                   Err Z @ 3,4
;                   0/ "no"$
;                   Stk 2: 5 0
;                   Rtn 0
;                 and then goes to EXIT.
;
;  Assembler: asm80, C6502 mode.
; =============================================================================

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
;  $0200,X and $0300,X.
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
RSV     EQU     07h             ; checked: S as it was before this character
; The error report (checked) runs after the program, so it may use the zero
; page that machine code has ($0A-$0F):
P       EQU     0Ah             ; 0A-0B the place being reported
Q       EQU     0Ch             ; 0C-0D a pointer for counting lines

; -----------------------------------------------------------------------------
;  Memory map
;
;    0000-00FF  zero page: the variables above
;    0100-01FF  hardware stack = return stack, S starts at FF
;    0200       DSL, data stack, low bytes (X = FC when empty: 252 cells)
;    0300       DSH, data stack, high bytes
;    0400       LET  letter cells: A..Z at +00..+33, a..z at +40..+73 (a word
;               cell is 64 bytes below its variable), heap pointer at +7C,
;               the -n? line buffer at +80..+FF. The checked build's cells
;               are in the gaps: KEYBUF at +34, PLACE at +36, PEND at +38.
;               (+7A and +7B are kept free.)
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
DSL     EQU     0200h           ; data stack, low bytes
DSH     EQU     0300h           ; data stack, high bytes
DSE     EQU     0FCh            ; X when the data stack is empty
LETPAGE EQU     04h
LET     EQU     LETPAGE*256
PROG    EQU     0500h           ; where the loader puts the program text
PROG1   EQU     PROG+1
HEAPLIM EQU     0E0h            ; the heap must stay below E000h (a page)
HEAP    EQU     LET+7Ch         ; the heap pointer (the heap top)
KEYBUF  EQU     LET+34h         ; a key held back by the break check
PLACE   EQU     LET+36h         ; checked: the address of this character
PEND    EQU     LET+38h         ; checked: the program's end, where the heap
                                ;   starts: it may not be released below it
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
LBM1    EQU     LINEBUF-1       ; (for the error report)
PROGM1  EQU     PROG-1
RSLIM   EQU     20h             ; lowest S allowed (checked build)
MSLOOP  EQU     40              ; n? inner loop count for about 1 ms; tune it

        ORG     0E000h

; =============================================================================
;  Startup: find the NUL, the heap starts after it
; =============================================================================
start:  LDX     #0FFh
        TXS                     ; return stack empty
        IF      CHECKED
        ; The first half of the letter page is zeroed: every variable, every
        ; cell of the interpreter's own (no key held back), and every word
        ; cell, which then points at 0000h: calling an undefined word stops
        ; with U (see e_undef).
        INX
        TXA                     ; A = 0
        LDY     #7Fh
stz:    STA     LET,Y
        DEY
        BPL     stz
        ENDIF
        JSR     rstip
st1:    JSR     getc
        BNE     st1             ; IP ends just past the NUL
        LDA     IP
        STA     HEAP
        IF      CHECKED
        STA     PEND
        ENDIF
        LDA     IP+1
        STA     HEAP+1
        IF      CHECKED
        STA     PEND+1
        ENDIF
        JSR     rstip
        LDX     #DSE

; =============================================================================
;  The inner loop
; =============================================================================
next:
        IF      CHECKED
        ; Both stacks are checked once per character, after it has run. The
        ; return stack has overrun when S is below RSLIM: an overflow leaves
        ; it at 1Eh or 1Fh, an underflow wraps it to 01h (no handler pulls
        ; more than one entry). The data stack has when X is above DSE: an
        ; underflow moves X up to FDh or FEh (no handler moves X by more
        ; than 2), and an overflow wraps it from 00h to FFh.
        ; S is kept in RSV, for the report's Rtn line (an error found inside
        ; a handler has its own calls on the hardware stack), and the place
        ; of the character about to run in PLACE.
        TXA                     ; TSX trashes X: keep it in A
        TSX
        STX     RSV
        CPX     #RSLIM
        TAX                     ; TAX leaves the carry alone
        BCC     e_rstack
        CPX     #DSE+1
        BCS     e_stack
        LDA     IP
        STA     PLACE
        LDA     IP+1
        STA     PLACE+1
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
; Every way out of the sort has the carry clear, except "ignored". A checked
; build stops on 80h-FFh (X) and still ignores DEL.
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
        IF      1-CHECKED
        BCS     ign             ; 7Fh-FFh
        ENDIF
        IF      CHECKED
        BEQ     ign             ; 7Fh
        BCS     e_resv          ; 80h-FFh: reserved
        ENDIF
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
endprog:
        IF      CHECKED
        LDA     IP+1            ; IP in page zero: an undefined word
        BEQ     e_undef
        ENDIF
        JMP     EXIT
        IF      CHECKED
; e_undef: the word cells of undefined words hold 0000h. A call there reads
; the byte at 0000h, which is IP's own low byte: 00h while IP is 0000h, so
; the call reads a NUL with IP in page zero, where no program can be. The
; call is undone first: the step frame and the return address come off the
; hardware stack, and the place is the call letter (the return address - 1).
e_undef:PLA
        PLA                     ; the step frame
        PLA
        SEC
        SBC     #1
        STA     PLACE
        PLA
        SBC     #0
        STA     PLACE+1
        INC     RSV
        INC     RSV             ; Rtn does not count the call
        LDA     #'U'
        BNE     ejmp            ; always
; S/R are overflows, s/r underflows. After an underflow that stack counts as
; empty.
e_rstack:LDA    RSV
        CMP     #10h
        LDA     #'R'
        BCS     ejmp            ; S is 1Eh-1Fh: an overflow
        LDA     #0FFh
        STA     RSV             ; S wrapped to 01h: Rtn 0
        LDA     #'r'
        BNE     ejmp            ; always
e_stack:CPX     #0FFh
        LDA     #'S'
        BCS     ejmp            ; X wrapped from 00h to FFh: an overflow
        LDX     #DSE            ; an underflow: Stk 0
        LDA     #'s'
        DB      2Ch             ; (BIT abs: hides the next instruction)
e_resv: LDA     #'X'            ; a reserved byte, 80h-FFh
ejmp:   JMP     error
        ENDIF

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  ASL
        TAY
        SEC
        BCS     pushn           ; always

; Digits: the first one is in A; read the rest of the number.
digit:  LDY     #0
        JSR     pushay
        JMP     rdnum

; a-z: push the cell's address (the cell is the variable)
lower:  ASL
        LDY     #>LET
        BNE     pushay          ; always

puship: LDA     IP              ; push the reading position
        LDY     IP+1
; pushay: push a cell: A = its low byte, Y = its high byte
pushay: PHA
        JSR     push
        PLA
        STA     TL
        STY     TH
        RTS

push:   DEX                     ; ':' and every push (keeps Y)
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        RTS

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: JSR     flag            ; (keeps the carry clear)
        IF      1-CHECKED
        BEQ     skip
        ENDIF
        IF      CHECKED
        BEQ     skpar
        ENDIF
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


; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything that is not a letter as the space; the
; checked build stops on it.)
        IF      CHECKED
def1:   CPY     #' '-'A'+256
        BEQ     def2
; W: anything but a letter or a space after [. The place is that character,
; one past the [.
        INC     PLACE
        BNE     eb1
        INC     PLACE+1
eb1:    LDA     #'W'
        BNE     ejmp            ; always
; A false ( skips: the wrong closer for it is ].
skpar:  LDA     #']'
        BNE     skip            ; always
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
        BNE     skdef           ; always: no program is in page zero
def2:   JSR     puship          ; an anonymous block: push its address
skdef:
        IF      CHECKED
        LDA     #')'            ; the wrong closer for [
        ENDIF

; skip: read past text to the closer at this level, and return it in A.
; Brackets of both kinds count together; strings are stepped over whole. A
; NUL first ends the program.
; In the checked build A holds, on the way in, the wrong closer for the
; opener that started the skip, kept in T0: ] for (, ) for [, and 0 for \,
; which takes either. Meeting the wrong closer at this level, or the end
; (a NUL, or a string that runs into it), stops with N, except for \,
; which then ends the program as before.
skip:
        IF      CHECKED
        STA     T0
        ENDIF
        LDA     #0
        STA     T2              ; depth
sk1:    JSR     getc
        IF      1-CHECKED
        BEQ     endprog
        ENDIF
        IF      CHECKED
        BEQ     sknul
        ENDIF
        CMP     #22h
        BNE     sk2
        JSR     skipstr         ; leaves A = 22h (11h when checked), which
                                ;   matches nothing below
        IF      CHECKED
        BEQ     sknul           ; the string ran into the end
        ENDIF
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
        IF      CHECKED
        CMP     T0
        BEQ     e_nest          ; the wrong kind
        ENDIF
        RTS                     ; the closer at this level
sk3:    INC     T2
        BNE     sk1
        IF      CHECKED
sknul:  LDA     T0
        BNE     e_nest          ; ( and [ stop with N
        JMP     EXIT            ; \ ends the program
e_nest: LDA     #'N'            ; a skip from ( or [ found the wrong closer
        DB      2Ch             ;   or the end: the place is the opener
e_quote:LDA     #'Q'            ; a string from 22h runs into the end
        JMP     error
        ENDIF

; 22h pushes the address of the text after it and skips the string.
h_str:  JSR     puship
        IF      CHECKED
        JSR     skipstr
        BEQ     e_quote         ; it ran into the end: the place is the 22h
        RTS
        ENDIF
; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it.
; Unchecked, it returns with Z set and A = 22h, and it does not look for the
; end. Checked, it returns with Z clear and A = 11h, or with Z set if the
; text ended first (a NUL, also one just after '/').
        IF      1-CHECKED
skipstr:JSR     getc
        CMP     #'/'
        BEQ     ss0
        CMP     #22h
        BNE     skipstr
        RTS
ss0:    JSR     incip
        BNE     skipstr         ; A is '/' here
        ENDIF
        IF      CHECKED
skipstr:JSR     getc
        BEQ     ss9             ; the end
        CMP     #'/'
        BNE     ss1
        JSR     getc            ; the escaped character
        BNE     skipstr
ss9:    RTS                     ; the end, just after '/'
ss1:    CMP     #22h
        BNE     skipstr
        LSR                     ; A = 11h, Z clear
        RTS
        ENDIF

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
        IF      CHECKED
        LDA     #0              ; \ takes either closer
        ENDIF
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

; '/' ( a b -- q r ): the remainder is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Unchecked, dividing by zero returns two cells of no meaning; checked,
; it stops with Z.
        IF      CHECKED
e_zero: LDA     #'Z'            ; divide by zero, the stack as it was
        JMP     error
        ENDIF
h_div:
        IF      CHECKED
        LDA     TL
        ORA     TH
        BEQ     e_zero
        ENDIF
        LDA     DSH,X
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
        JSR     h_swap          ; r on top
        PLA
        JMP     negm            ; r's sign

; udiv: unsigned TOS / D (D <= 8000h). TOS becomes the quotient and the NOS
; cell the remainder (whatever was there is lost).
; Dividing by 2 is one shift (the spec wants that fast).
udiv:   LDA     #0
        STA     DSL,X
        STA     DSH,X
        LDA     D0
        EOR     #2
        ORA     D1
        BNE     ud0
        LSR     TH
        ROR     TL              ; the quotient
        ROL     DSL,X           ; the remainder: the bit that fell out
        RTS
ud0:    LDY     #16
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
; '_' ( n -- addr ): the heap top moves by n, which is signed: a negative
; count releases. TOS becomes the old top. (The carry is clear on the way in.)
        IF      1-CHECKED
h_alloc:LDA     HEAP
        TAY
        ADC     TL
        STA     HEAP
        STY     TL
        LDA     HEAP+1
        TAY
        ADC     TH
        STA     HEAP+1
        STY     TH
        RTS
        ENDIF
; The checked build works the new top out first, in T0 and Y, and stops with
; H, the count still on the stack, if it is at or past the limit, below the
; program's end, or if the 16-bit add wrapped. A wrap is the V flag of the
; high bytes' add with the old top's sign bit flipped: that makes the old top
; a signed number from -8000h, so the add overflows exactly when the true
; sum leaves 0000h-FFFFh.
        IF      CHECKED
h_alloc:LDA     HEAP
        ADC     TL
        STA     T0
        LDA     HEAP+1
        EOR     #80h
        ADC     TH
        BVS     e_heap          ; wrapped
        EOR     #80h            ; the new top's high byte
        CMP     #HEAPLIM
        BCS     e_heap          ; at or past the limit
        TAY
        LDA     T0
        CMP     PEND
        TYA
        SBC     PEND+1
        BCC     e_heap          ; below the program's end
        LDA     HEAP
        STA     TL
        LDA     T0
        STA     HEAP
        LDA     HEAP+1
        STA     TH
        STY     HEAP+1
        RTS
; Errors found by handlers. The stacks are as they were before the handler.
e_heap: LDA     #'H'            ; heap past the limit or below the program
        DB      2Ch             ; (BIT abs: hides the next instruction)
e_store:LDA     #'O'            ; a store outside the program's space
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
; The checked build walks a copy of TOS along the string, so that the address
; is still there if it stops with Q on a NUL.
h_print:
        IF      CHECKED
        JSR     push            ; the copy
        JSR     pr0
        JMP     drop
pr0:
        ENDIF
        JSR     tosget
        CMP     #22h
        BEQ     pdrop
        IF      CHECKED
        CMP     #0
        BEQ     e_qpr
        ENDIF
        CMP     #'/'
        BNE     pr1
        JSR     tosget
        AND     #0BFh
pr1:    JSR     CONOUT
        IF      1-CHECKED
        JMP     h_print
        ENDIF
        IF      CHECKED
        JMP     pr0
e_qpr:  JSR     drop            ; the copy goes: the address is TOS again
        LDA     #'Q'            ; $ ran into the end
        JMP     error
        ENDIF

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
;   n < 0: read a line of at most -n characters, with echo. The buffer
;          holds 127 characters and the CR: a bigger count is taken as 127.
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
line:   JSR     neg             ; TOS = the count, and A = its high byte
        BNE     ln0
        LDA     TL
        BPL     ln1
ln0:    LDA     #127            ; more than 127 is taken as 127
        STA     TL
ln1:    LDY     #0
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
        STA     (TL),Y          ; Y is 0 after rdhex (never checked)
        JSR     inctos
        JSR     rdhex
        BCC     hx1
hx2:    LDA     #60h
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

; error: the report, then EXIT. A = the letter, PLACE = the place, X = the
; data stack to show, RSV = S for the Rtn line. Nothing here relies on S: an
; overflowed or underflowed hardware stack wraps inside its page, and only
; its depth is shown.
;   CR LF
;   Err X @ line,col CR LF
;   up to 16 characters from the place, raw, up to a CR, LF or NUL  CR LF
;   Stk n: [...] and the top 8 cells at most, bottom to top  CR LF
;   Rtn n CR LF
; The numbers go through '#' (prnum), which pushes them over the data stack
; and pops them again, so the stack is shown as it was.
error:  PHA                     ; the letter
        LDA     PLACE
        STA     P
        LDA     PLACE+1
        STA     P+1
        LDY     #M_ERR-MSG
        JSR     prs             ; CR LF "Err "
        PLA
        JSR     CONOUT
        JSR     prs             ; " @ " (it follows M_ERR)
        JSR     lcol
        LDA     D0
        LDY     D1
        JSR     prnum           ; the line
        LDA     #','
        JSR     CONOUT
        LDA     T1
        LDY     T2
        JSR     prnum           ; the column
        LDY     #M_NL-MSG
        JSR     prs
        LDY     #0              ; the text at the place
er1:    LDA     (P),Y
        BEQ     er2
        CMP     #13
        BEQ     er2
        CMP     #10
        BEQ     er2
        JSR     CONOUT
        INY
        CPY     #16
        BNE     er1
er2:    LDY     #M_STK-MSG
        JSR     prs             ; CR LF "Stk "
        TXA
        EOR     #0FFh
        SEC
        SBC     #0FFh-DSE       ; the depth, DSE - X (FFh, an overflow: 253)
        PHA
        LDY     #0
        JSR     prnum
        PLA
        LDY     #M_C-MSG        ; ":"
        CMP     #9
        BCC     er3
        LDA     #8              ; more than 8: ": ..." and the top 8
        LDY     #M_CD-MSG
er3:    STA     T1              ; T1 = how many cells to show
        JSR     prs
        JSR     push            ; TOS into memory with the rest: cell i from
                                ;   the top is at DSL+X+i now
er4:    LDA     T1              ; cells T1-1 down to 0, the top last
        BEQ     er5
        DEC     T1
        LDA     #' '
        JSR     CONOUT
        TXA
        CLC
        ADC     T1
        TAY
        LDA     DSL,Y
        PHA
        LDA     DSH,Y
        TAY
        PLA
        JSR     prnum
        JMP     er4
er5:    LDY     #M_RTN-MSG
        JSR     prs             ; CR LF "Rtn "
        LDA     RSV
        EOR     #0FFh
        LSR                     ; (FFh - S) / 2 entries
        LDY     #0
        JSR     prnum
        LDY     #M_NL-MSG
        JSR     prs
        JMP     EXIT

; prnum: print the number A (low), Y (high), signed, keeping the data stack
prnum:  JSR     pushay
        JMP     h_num

; prs: print the message at MSG+Y; its last byte has bit 7 set. Y ends just
; past it, at the next message.
prs:    LDA     MSG,Y
        PHA
        AND     #7Fh
        JSR     CONOUT
        INY
        PLA
        BPL     prs
        RTS

MSG:
M_ERR:  DB      13,10,'Err',' '+80h
        DB      ' @',' '+80h
M_NL:   DB      13,10+80h
M_STK:  DB      13,10,'Stk',' '+80h
M_CD:   DB      ': ..','.'+80h
M_C:    DB      ':'+80h
M_RTN:  DB      13,10,'Rtn',' '+80h

; lcol: the line (D0/D1) and the column (T1/T2) of the place at P, both from
; 1. A place below the program is in the -n? line buffer: line 0, and the
; column is the place in the buffer. Otherwise the LFs before the place are
; counted from PROG; T1/T2 holds the address before the line's first
; character (the last LF, or PROG - 1), and the column is P minus that.
lcol:   LDY     #0
        STY     D1
        STY     D0
        LDA     #<LBM1
        STA     T1
        LDA     #>LBM1
        STA     T2
        LDA     P
        CMP     #<PROG
        LDA     P+1
        SBC     #>PROG
        BCC     lc9             ; below the program: line 0
        INC     D0
        LDA     #<PROGM1
        STA     Q
        STA     T1
        LDA     #>PROGM1
        STA     Q+1
        STA     T2
lc1:    INC     Q               ; the next character
        BNE     lc2
        INC     Q+1
lc2:    LDA     Q
        CMP     P
        LDA     Q+1
        SBC     P+1
        BCS     lc9             ; at the place
        LDA     (Q),Y
        CMP     #10
        BNE     lc1
        INC     D0              ; an LF: a new line starts after it
        BNE     lc3
        INC     D1
lc3:    LDA     Q
        STA     T1
        LDA     Q+1
        STA     T2
        BNE     lc1             ; always: no program is in page zero
lc9:    LDA     P
        SEC
        SBC     T1
        STA     T1
        LDA     P+1
        SBC     T2
        STA     T2
        RTS
        ENDIF
