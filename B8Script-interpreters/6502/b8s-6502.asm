; =============================================================================
;  B8Script interpreter for the 6502 (NMOS opcodes only)
;  Spec: docs/b8script.md (2026-11-23). -n? does no more editing than
;        Backspace. Ctrl-C stops every build (see the console layer); the
;        break-off cell is BRKOFF, $047B.
;  Design follows the Z80 interpreter; see b8s-z80.asm for the common ideas.
;
;  This interpreter keeps the data stack in pages 2 and 3 (252 cells) and
;  uses 10 bytes of zero page ($00-$09). b8s-6502-zp.asm is a smaller interpreter that
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
ANSI    EQU     1               ; 1 = the console codes send ANSI sequences;
                                ; 0 = they call CONAT, CONCLS, CONEOL, CONCUR

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
        IF      1-CHECKED
KEYBUF  EQU     07h             ; a key held back by the break check (0: none)
        ENDIF
        IF      CHECKED
PLACE   EQU     06h             ; 06-07 (T2 and $07) the address of the
                                ;   character being run, for the error report:
                                ;   no handler of the checked build uses T2.
                                ;   (Machine code may change T2: that matters
                                ;   only if it also leaves a stack overrun,
                                ;   whose report then shows a wrong place.)
RSV     EQU     LET+35h         ; S as it was before this character
KEYBUF  EQU     LET+7Ah         ; a key held back by the break check (0: none)
; The error report runs after the program, so it may use the zero page that
; machine code has ($0A-$0F):
CL      EQU     0Ah             ; 0A-0B the column being reported
        ENDIF

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
;               are in the gaps: RSV at +35, PEND at +38, KEYBUF (the held
;               key; $07 in the unchecked build) at +7A; and every build's:
;               CDOWN at +79, BRKOFF (the break-off cell) at +7B.
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
        IF      1-ANSI
; With ANSI = 0 the console codes call these four instead of sending ANSI
; sequences. All must preserve X.
CONAT   EQU     0FF0Ch          ; `@  cursor to row Y, column A, both from 0
CONCLS  EQU     0FF0Fh          ; `^  clear the screen and home the cursor
CONEOL  EQU     0FF12h          ; `_  clear from the cursor to the end of the line
CONCUR  EQU     0FF15h          ; `?  cursor off if A = 0 (the Z flag is set
                                ;     to match), on if not
        ENDIF
DSL     EQU     0200h           ; data stack, low bytes
DSH     EQU     0300h           ; data stack, high bytes
DSE     EQU     0FCh            ; X when the data stack is empty
LETPAGE EQU     04h
LET     EQU     LETPAGE*256
PROG    EQU     0500h           ; where the loader puts the program text
PROG1   EQU     PROG+1
HEAPLIM EQU     0E0h            ; the heap must stay below E000h (a page)
HEAP    EQU     LET+7Ch         ; the heap pointer (the heap top)
SEED    EQU     LET+76h         ; the random seed: the cell whose address `.
                                ;   gives. Nothing sets it at the start but
                                ;   the checked build's clearing
CDOWN   EQU     LET+79h         ; the break check's countdown (see pnext)
BRKOFF  EQU     LET+7Bh         ; the break-off cell: a program that stores a
                                ;   non-zero byte here gets Ctrl-C as a key
PEND    EQU     LET+38h         ; checked: the program's end, where the heap
                                ;   starts: it may not be released below it
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSLIM   EQU     20h             ; lowest S allowed (checked build)
MSLOOP  EQU     40              ; n? inner loop count for about 1 ms; tune it
                                ;   (each pass calls KEY once; the wait for a
                                ;   second Ctrl-C uses it too: 250 ms)
CWAIT   EQU     250*MSLOOP/256  ; (that wait, in 256s)

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
        IF      1-CHECKED
        STA     KEYBUF          ; (A = 0) no key held, the break key on
        STA     BRKOFF
        ENDIF
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
; -----------------------------------------------------------------------------
;  The break key. A running program reads the keyboard only through getk
;  (for '?') and pnext (the break check), which between them give the break
;  key its rules:
;    - Ctrl-C (03h) stops the program: silently to EXIT in the unchecked
;      build, with the report (B) in the checked one;
;    - any other key that the break check reads is held in KEYBUF for the
;      next '?', and a newer one takes its place;
;    - '?' (getk) takes the held key first;
;    - a program that has stored a non-zero byte at BRKOFF gets Ctrl-C as a
;      key like any other, but two of them within about 250 ms still stop it.
;  KEY is the host's: a waiting key in A, or A = 0 with the zero flag set.
; -----------------------------------------------------------------------------
; pnext: the break check, then (falling through) next. A word call, a true
; '(' and a true ')' end here, but the keyboard is looked at only once in 256
; of them: CDOWN counts them down. A key found is held; a Ctrl-C goes on to ctlc. (Startup
; falls in here too, which does no harm.)
pnext:  DEC     CDOWN
        BNE     next
        JSR     KEY
        BEQ     next            ; no key
        STA     KEYBUF          ; held for the next '?'
        JSR     chk3            ; (Ctrl-C: back only if the break key is off)
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
        IF      CHECKED
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
ejmp:   JMP     error
        ENDIF

; The handlers that work on the return stack sit here, where short branches
; reach next and pnext.

; '{' TOS to the return stack, '}' return stack to TOS
h_tor:  PLA
        PLA
        LDA     TH
        PHA
        LDA     TL
        PHA
        JSR     drop
        BNE     next            ; always

h_fromr:PLA
        PLA
        JSR     push
        PLA
        STA     TL
        PLA
        STA     TH
        BCC     next            ; always: the carry is clear on the way in

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on. It shares ']'s code: with the carry clear, as
; it is here, the address popped is pushed back.
h_close:JSR     flag
        BEQ     rdrop
        DB      24h             ; (BIT zp: steps over the SEC)
; ']' returns: pull an address and jump to it.
h_ret:  SEC
        PLA
        PLA                     ; drop the step frame
        PLA
        STA     IP
        PLA
        STA     IP+1
        BCS     next
        PHA                     ; ')': keep the block start
        LDA     IP
        PHA
        BCC     pnext           ; always: a loop-back, with the break check

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns.
h_break:JSR     flag
        BEQ     gk9             ; (an RTS)
        IF      CHECKED
        LDA     #0              ; \ takes either closer
        ENDIF
        JSR     skip
        CMP     #')'
        BNE     h_ret
rdrop:  PLA
        PLA
        PLA
        PLA                     ; (the block start's high byte: never 0)
        BNE     next            ; always

; getk: a key for '?' in A (zero flag clear), or A = 0 with the zero flag
; set when there is none. Keeps X and Y. The held key goes first, and is
; taken out of KEYBUF.
getk:   LDA     KEYBUF
        BEQ     gk1
        PHA
        LDA     #0
        STA     KEYBUF
        PLA
        RTS
gk1:    JSR     KEY
        BEQ     gk9
; chk3: a key in A (not 0). A Ctrl-C goes on to ctlc, which gives the 03h
; back if it comes back at all.
chk3:   CMP     #3
        BEQ     ctlc
gk9:    RTS

; ctlc: Ctrl-C has been read. If the break key is on, that is the end. If
; the program has turned it off, wait about 250 ms (about 250 times MSLOOP
; looks: D0 counts the 256s, D1 runs on from whatever it holds) for one more
; key: a second Ctrl-C is the end too; any other key is held (the newest
; wins). Returns A = 03h with the zero flag clear. Keeps X and Y.
ctlc:   LDA     BRKOFF
        BEQ     cbreak
        LDA     #CWAIT+1
        STA     D0
ct2:    JSR     KEY
        BNE     ct3
        DEC     D1
        BNE     ct2
        DEC     D0
        BNE     ct2
        BEQ     ct9             ; always: none came
ct3:    CMP     #3
        BEQ     cbreak
        STA     KEYBUF
ct9:    LDA     #3
        RTS
        IF      1-CHECKED
cbreak  EQU     endprog         ; the unchecked build stops without a word
        ENDIF
        IF      CHECKED
cbreak  EQU     e_break         ; the checked build reports B
        ENDIF

        IF      CHECKED
e_break:LDA     #'B'            ; Ctrl-C (the stacks as they stand)
        DB      2Ch
e_resv: LDA     #'X'            ; a reserved byte, 80h-FFh
ejmp3:  JMP     error
        ENDIF
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
        BNE     ejmp3           ; always
        ENDIF

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
nxt:    JMP     pnext


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
        BNE     ejmp2           ; always
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
        STA     D1              ; depth
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
sk4:    DEC     D1
        BPL     sk1
        IF      CHECKED
        CMP     T0
        BEQ     e_nest          ; the wrong kind
        ENDIF
        RTS                     ; the closer at this level
sk3:    INC     D1
        BNE     sk1
        IF      CHECKED
sknul:  LDA     T0
        BNE     e_nest          ; ( and [ stop with N
        JMP     EXIT            ; \ ends the program
e_nest: LDA     #'N'            ; a skip from ( or [ found the wrong closer
        DB      2Ch             ;   or the end: the place is the opener
e_quote:LDA     #'Q'            ; a string from 22h runs into the end
ejmp2:  JMP     error
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
rh1:    BCC     incip           ; always: the carry is clear
rh9:    RTS

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
        JSR     chk2            ; both bytes must be in the program's space
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
h_lt:   JSR     scmp
        INX                     ; (keeps the carry; never leaves X at 0)
        BNE     bool            ; always
; scmp: the carry clear if NOS < TOS (signed). `< and `> use it too.
scmp:   LDA     DSL,X
        CMP     TL
        LDA     DSH,X
        SBC     TH
        BVS     lt1
        EOR     #80h
lt1:    ASL
        RTS

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
e_zero: LDA     #'Z'            ; divide by zero
        DB      2Ch             ; (BIT abs: hides the next instruction)
e_heap: LDA     #'H'            ; heap past the limit or below the program
        DB      2Ch
e_store:LDA     #'O'            ; a store outside the program's space
        JMP     error

; chk2: stop unless the cell at TOS, both its bytes, is in the program's own
; space: the page of addr+1 (CMP sets the carry if addr ends in FFh), then of
; addr. '!' and the grave's `+ and `- use it. Keeps Y.
chk2:   LDA     TL
        CMP     #0FFh
        LDA     TH
        ADC     #0
        JSR     chkst
        LDA     TH
; chkst: stop unless the page in A is in the program's own space, from the
; letter page up to the heap limit. Keeps Y.
chkst:  CMP     #LETPAGE
        BCC     e_store
        CMP     #HEAPLIM
        BCS     e_store
        RTS
        ENDIF

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
        BNE     pdrop           ; always (drop leaves Z clear): the address
pr0:
        ENDIF
        JSR     tosget
        CMP     #22h
        BEQ     pdrop
        IF      CHECKED
        TAY                     ; (Y is free here)
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
        JMP     e_quote         ; $ ran into the end
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
        INC     SEED            ; a millisecond with no key stirs the random
        BNE     kt5             ;   seed by one: how long a key takes to come
        INC     SEED+1          ;   is the one thing here that is not the
kt5:                            ;   same every time
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
;  The grave
; =============================================================================
; The grave is a prefix: with the character after it, it is one command.
; GCH holds the characters and GLO, beside it, the low byte of each one's
; handler (less 1, for the RTS trick). The high byte is worked out: the
; handlers lie in the order of the table and take up less than a page, so
; they start in one page or in two, and GK is the place in the table where
; the second page begins (the assembler works it out, and chktab6502.py
; checks it). A handler starts with Y = its place in the table, and ends in
; RTS. A character that is not in the table is unsafe: the unchecked build
; does nothing, the checked build stops with W.
;
;    `!  ( addr -- )        call the machine code at addr: see the contract
;                           in the header
;    `$  ( addr -- addr' )  the hex loader: pairs of hex digits are stored
;                           from addr until a non-hex character; then a RTS
;                           (60h) is written and its address is left. An odd
;                           last digit is consumed and dropped.
;    `'  ( -- )             new line: CR LF
;    `+  ( addr -- n )      add 1 to the cell at addr and leave its new value
;    `,  ( n -- r )         a random number from 0 to n-1 (n is 1 to 32767)
;    `-  ( addr -- n )      subtract 1 from the cell at addr, the same way
;    `.  ( -- addr )        the address of the random seed
;    `<  ( a b -- n )       the smaller of the two (signed)
;    `>  ( a b -- n )       the larger
;    `?  ( flag -- )        the cursor off (0) or on
;    `@  ( row col -- )     the cursor to that row and column, both from 0
;    `^  ( -- )             clear the screen and home the cursor
;    `_  ( -- )             clear from the cursor to the end of the line
h_grave:
        IF      CHECKED
        INC     PLACE           ; the place of anything that goes wrong in
        BNE     gr0             ;   one of these is the character after the
        INC     PLACE+1         ;   grave
gr0:
        ENDIF
        JSR     getc
        LDY     #GLO-GCH-1
gr1:    CMP     GCH,Y
        BEQ     gr2
        DEY
        BPL     gr1
        IF      1-CHECKED
        RTS                     ; no such code
        ENDIF
        IF      CHECKED
        JMP     eb1             ; no such code: W
        ENDIF
gr2:    CPY     #GK             ; carry: the second page
        LDA     #GQ0
        ADC     #0
        PHA
        LDA     GLO,Y
        PHA
        RTS                     ; to the handler

; (The order matters: '-' just before '+', '<' at an odd place and '>' at
; the even one after it, and the handlers in the same order in memory.)
GCH:    DB      '$','!',27h
GMINUS: DB      '-','+','.',',','<','>','?','@','^','_'
GLO:    DB      (g_hex-1) & 0FFh
        DB      (exec-1) & 0FFh
        DB      (g_nl-1) & 0FFh
        DB      (g_inc-1) & 0FFh
        DB      (g_inc-1) & 0FFh
        DB      (g_seed-1) & 0FFh
        DB      (g_rnd-1) & 0FFh
        DB      (g_min-1) & 0FFh
        DB      (g_min-1) & 0FFh
        DB      (g_cur-1) & 0FFh
        DB      (g_at-1) & 0FFh
        DB      (g_cls-1) & 0FFh
        DB      (g_eol-1) & 0FFh
; The page of each handler, and GK: 13 less the table entries whose handler
; is in the second page. (One division to a line: asm80 only rounds down
; when it stores a value.)
GQ0     EQU     (g_hex-1)/256
GQ1     EQU     (exec-1)/256
GQ2     EQU     (g_nl-1)/256
GQ3     EQU     (g_inc-1)/256
GQ5     EQU     (g_seed-1)/256
GQ6     EQU     (g_rnd-1)/256
GQ7     EQU     (g_min-1)/256
GQ9     EQU     (g_cur-1)/256
GQ10    EQU     (g_at-1)/256
GQ11    EQU     (g_cls-1)/256
GQ12    EQU     (g_eol-1)/256
GK      EQU     13+12*GQ0-GQ1-GQ2-GQ3-GQ3-GQ5-GQ6-GQ7-GQ7-GQ9-GQ10-GQ11-GQ12

; `$ (never checked: the spec says so)
g_hex:  JSR     rdhex
        BCS     hx2
        ASL
        ASL
        ASL
        ASL
        STA     T0
        JSR     rdhex
        BCS     hx2             ; odd digit: already consumed, dropped
        ORA     T0
        STA     (TL),Y          ; Y is 0 after rdhex
        JSR     inctos
        BCC     g_hex           ; always (rdhex left the carry clear)
hx2:    LDA     #60h
        STA     (TL),Y
        RTS

; `!
exec:   LDA     TL
        STA     T0
        LDA     TH
        STA     T1
        JSR     drop            ; the address is consumed
        JMP     (T0)

g_nl:   LDA     #13
        JSR     CONOUT
        LDA     #10
        JMP     CONOUT

; `+ and `-: one routine. It adds 0000h with the carry set, or FFFFh with it
; clear: SBC turns the carry into that 00 or FF and leaves the carry as it
; was. Then '@' fetches the new value.
g_inc:
        IF      CHECKED
        JSR     chk2            ; both bytes must be in the program's space
        ENDIF
        CPY     #GMINUS-GCH+1   ; carry: '+'
        LDA     #0
        SBC     #0
        STA     T1
        LDY     #0
        ADC     (TL),Y
        STA     (TL),Y
        INY
        LDA     T1
        ADC     (TL),Y
        STA     (TL),Y
        JMP     h_fetch

; `. pushes the address of the random seed.
g_seed: LDA     #<SEED
        LDY     #>SEED
        JMP     pushay

; `, ( n -- r ). The seed goes one step on: seed * 261 + 1, which takes
; every 16-bit value in turn. The high bits of such a seed are the good ones
; and the low ones repeat soon, so the high byte is folded into the low
; (EOR) before the remainder of dividing by n is taken.
; n must be 1 to 32767: the checked build stops with Z on anything less
; than 1.
g_rnd:
        IF      CHECKED
        LDA     TH
        BMI     gr9
        ORA     TL
        BNE     gr8
gr9:    JMP     e_zero
gr8:
        ENDIF
        LDA     SEED
        LDY     SEED+1
        JSR     pushay          ; the seed,
        LDA     #05h            ;   and 261 (0105h) on top of it
        LDY     #01h
        JSR     pushay
        JSR     h_mul           ; TOS = seed * 261, and n is under it again
        JSR     inctos
        LDA     TL
        STA     SEED
        LDA     TH
        STA     SEED+1
        EOR     TL
        STA     TL
        LDA     DSL,X
        STA     D0
        LDA     DSH,X
        STA     D1              ; D = n
        JSR     udiv            ; the remainder goes where n was,
        JMP     drop            ;   and comes up as TOS

; `< and `>: one routine. scmp leaves the carry clear if a < b. Y is odd for
; '<' and even for '>' (their places in the table), so the low bit of Y plus
; the carry is set when a, the cell below, is the one to keep.
g_min:  JSR     scmp
        TYA
        ADC     #0
        LSR
        BCC     gm1
        JMP     drop            ; a
gm1:    INX                     ; b
        RTS

        IF      ANSI
; `? ( flag -- ): ESC [ ? 2 5 l hides the cursor, ESC [ ? 2 5 h shows it.
g_cur:  LDY     #4
gc1:    LDA     GQ25,Y
        JSR     CONOUT
        DEY
        BPL     gc1
        JSR     flag
        BEQ     gc2
        LDA     #'h'
        DB      2Ch             ; (BIT abs: hides the next instruction)
gc2:    LDA     #'l'
        JMP     CONOUT
GQ25:   DB      '5','2','?','[',27      ; (printed from the end)

; `@ ( row col -- ): ESC [ row+1 ; col+1 H. (ANSI counts from 1.)
g_at:   JSR     csi
        JSR     h_swap          ; the row on top
        JSR     pinc
        LDA     #';'
        JSR     CONOUT
        JSR     pinc
        LDA     #'H'
        JMP     CONOUT
; pinc: print TOS + 1, unsigned, and drop it
pinc:   JSR     inctos
        JMP     pn1

; csi: print ESC [, which starts every ANSI sequence. Keeps X and Y.
csi:    LDA     #27
        JSR     CONOUT
        LDA     #'['
        JMP     CONOUT

; `^: ESC [ H homes the cursor, and ESC [ J clears from there to the end of
; the screen. `_: ESC [ K clears to the end of the line.
g_cls:  LDY     #'H'
        JSR     csiy
        LDY     #'J'
        DB      2Ch             ; (BIT abs: hides the next instruction)
g_eol:  LDY     #'K'
; csiy: print ESC [ and the character in Y
csiy:   JSR     csi
        TYA
        JMP     CONOUT
        ENDIF
        IF      1-ANSI
; With ANSI = 0 the machine's own routines do the work (see the equates).
g_cur:  JSR     flag            ; A = 0 and Z set: off
        JMP     CONCUR
g_at:   LDY     DSL,X           ; Y = the row
        LDA     TL              ; A = the column
        JSR     CONAT
        INX
        JMP     drop
g_cls:  JMP     CONCLS
g_eol:  JMP     CONEOL
        ENDIF




        IF      CHECKED
; =============================================================================
;  Checked build: the error report
; =============================================================================

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
        LDA     CL
        LDY     CL+1
        JSR     prnum           ; the column
        LDY     #M_NL-MSG
        JSR     prs
        LDY     #0              ; the text at the place
er1:    LDA     (PLACE),Y
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
        JSR     prnum8
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
        JSR     prnum8
        LDY     #M_NL-MSG
        JSR     prs
        JMP     EXIT

; prnum: print the number A (low), Y (high), signed, keeping the data stack.
; prnum8: the same for A alone, 0-255.
prnum8: LDY     #0
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

; lcol: the line (D0/D1) and the column (CL) of the place, both from 1. A
; place below the program is in the -n? line buffer: line 0, and the column
; is the place in the buffer. Otherwise IP (free now: the program has
; stopped) runs from PROG to the place, counting LFs; CL keeps where the
; last line started, and the column is the place minus that, plus 1.
lcol:   LDA     #0
        STA     D1
        STA     D0
        LDA     #<LINEBUF
        STA     CL
        LDA     #>LINEBUF
        STA     CL+1
        LDA     PLACE
        CMP     #<PROG
        LDA     PLACE+1
        SBC     #>PROG
        BCC     lc9             ; below the program: line 0
        INC     D0
        JSR     rstip
lc3:    LDA     IP              ; a line starts here
        STA     CL
        LDA     IP+1
        STA     CL+1
lc1:    LDA     IP
        CMP     PLACE
        LDA     IP+1
        SBC     PLACE+1
        BCS     lc9             ; at the place
        JSR     getc
        CMP     #10
        BNE     lc1
        INC     D0              ; an LF: a new line starts after it
        BNE     lc3
        INC     D1
        BNE     lc3             ; always
lc9:    LDA     PLACE
        SEC
        SBC     CL
        STA     CL
        LDA     PLACE+1
        SBC     CL+1
        STA     CL+1
        INC     CL              ; + 1
        BNE     lc8
        INC     CL+1
lc8:    RTS
        ENDIF
