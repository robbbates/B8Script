; =============================================================================
;  B8Script interpreter for the 6502 (NMOS opcodes only)
;  Required Notice: Copyright 2026 Robb Bates (https://github.com/robbbates)
;  Licence: PolyForm Noncommercial License 1.0.0 (LICENSE.md at the top of
;  the repository, or https://polyformproject.org/licenses/noncommercial/1.0.0)
;  Spec: docs/b8script.md (2026-11-24). -n? does no more editing than
;        Backspace. Ctrl-C stops every build (see the console layer); the
;        break-off cell is BRKOFF, $047B.
;  Design follows the Z80 interpreter; see b8s-z80.asm for the common ideas.
;
;  This interpreter keeps the data stack in pages 2 and 3 (252 cells) and
;  uses 10 bytes of zero page ($00-$09). b8s-6502-zp.asm is a smaller interpreter that
;  keeps the stack in zero page instead (112 cells); its memory map and
;  machine-code contract differ.
;
;  The switches, set in the EQU lines below:
;    CHECKED  0 = no checks: whatever the spec calls unsafe is not caught
;             1 = a checked build, as in the spec's "Errors and checked
;                 builds": at startup every word cell points at 0000h (see
;                 e_undef) and the variables and the interpreter's cells are
;                 0. It stops with S s R r (stack over/underflow), H (heap),
;                 O (a store outside the program's space), U (undefined
;                 word), Q (no closing quote), W (bad character after [), X
;                 (a reserved byte), Z (divide by zero), N (brackets) or B
;                 (Ctrl-C), printing the spec's three-line report:
;                   Err Z @ 3,4
;                   D:2: 5 0
;                   R:0
;                 and then goes to EXIT.
;    ANSI     what the console escapes of '$' (/{ /} /| /` /~) do:
;             1 = send ANSI (VT100) sequences through CONOUT
;             0 = call the machine's own routines CONCLS, CONEOL, CONCUR and
;                 CONAT (see the equates)
;    SPEED    0 = small: the smallest build
;             1 = base, the default: the speed-ups that cost bytes: a skip
;                 cache, a faster skip, '*' and '/' quicker for small and
;                 power-of-two operands, and more (see "Speed-ups")
;             2 = fast: base and a dispatch table besides, with no size
;                 limit (see "The fast build").
;  The base and fast builds use one more RAM page, for the skip cache: the page
;  at the heap limit, which is DF00h in them (E000h in the others).
;
;  Assembler: asm80, C6502 mode.
; =============================================================================

CHECKED EQU     0               ; 1 = checked build
ANSI    EQU     0               ; 1 = the console escapes send ANSI sequences
SPEED   EQU     1               ; 0 = small, 1 = base, 2 = fast (see "Speed-ups")
FAST    EQU     SPEED/2         ; (1: the fast build)
SBASE   EQU     SPEED-FAST*2    ; (1: the base build)
QK      EQU     SBASE+FAST-SBASE*FAST ; (the speed-ups: base, or the fast build)
SBASEU  EQU     QK*(1-CHECKED)*(1-FAST) ; (and those that only the unchecked
                                ;  builds take; the fast build has its own)

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
;  The fast build (SPEED = 2) dispatches through a full table instead: see
;  "The fast build" at the end.
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
SKL     EQU     T1              ; (QK) 05 and 08: where a skip started, for
SKH     EQU     D0              ;   the skip cache
V       EQU     T0              ; (FAST) 04-05 the dispatcher's jump vector
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
CL      EQU     0Ah             ; 0A-0B where the reported line starts
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
;    DF00       CPAGE (QK builds only): the skip cache, at the heap limit
;    E000       the interpreter (ROM). In the fast build its first two
;               pages are the dispatch table, and start is at E200
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
; With ANSI = 0 the console escapes of '$' call these. All four must keep X;
; they may change A, Y and the flags.
CONCLS  EQU     0FF0Ch          ; /{  clear the screen, the cursor to the top left
CONEOL  EQU     0FF0Fh          ; /}  clear from the cursor to the end of the line
CONCUR  EQU     0FF12h          ; /| and /`  show the cursor if the carry is set,
                                ;     hide it if the carry is clear
CONAT   EQU     0FF15h          ; /~  the cursor to row A, column Y, both
                                ;     counted from 0
        ENDIF
DSL     EQU     0200h           ; data stack, low bytes
DSH     EQU     0300h           ; data stack, high bytes
DSE     EQU     0FCh            ; X when the data stack is empty
LETPAGE EQU     04h
LET     EQU     LETPAGE*256
PROG    EQU     0500h           ; where the loader puts the program text
PROG1   EQU     PROG+1
HEAPLIM EQU     0E0h-QK         ; the heap must stay below E000h (a page);
                                ;   below DF00h in the QK builds, where
CPAGE   EQU     HEAPLIM         ;   DF00h is the skip cache's page: the page
                                ;   at the heap limit, which the heap never reaches
HEAP    EQU     LET+7Ch         ; the heap pointer (the heap top)
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

; The fast build's dispatcher (SPEED = 2; see "The fast build"), inline at
; the end of its own entries. NEXTF reads the next character and jumps
; through the table:
;     LDY #0 / LDA (IP),Y / INC IP / BNE $+4 / INC IP+1 / TAY /
;     LDA DTL,Y / STA V / LDA DTH,Y / STA V+1 / JMP (V)
; NEXTA is the same from INC IP on: the character is already in A, and IP is
; still at it (it skips the LDY and the LDA); NEXTY is the same with the
; character in Y (it skips the TAY too). In the checked build all three are
; JMP fnext, which checks the stacks first. (The bytes are written out with
; DS, because asm80 does not nest an IF in a macro inside another IF; and
; DS takes the addresses as these equates.)
        IF      FAST
ADTL    EQU     DTL
ADTH    EQU     DTH
AFNX    EQU     fnext
        ENDIF
        IF      1-FAST
ADTL    EQU     0
ADTH    EQU     0
AFNX    EQU     0
        ENDIF
.macro  NEXTF
        DS      1-CHECKED,0A0h  ; LDY #0
        DS      1-CHECKED,0
        DS      1-CHECKED,0B1h  ; LDA (IP),Y
        DS      1-CHECKED,IP
        DS      1-CHECKED,0E6h  ; INC IP
        DS      1-CHECKED,IP
        DS      1-CHECKED,0D0h  ; BNE $+4
        DS      1-CHECKED,2
        DS      1-CHECKED,0E6h  ; INC IP+1
        DS      1-CHECKED,IP+1
        DS      1-CHECKED,0A8h  ; TAY
        DS      1-CHECKED,0B9h  ; LDA DTL,Y
        DS      1-CHECKED,ADTL&0FFh
        DS      1-CHECKED,ADTL/256
        DS      1-CHECKED,85h   ; STA V
        DS      1-CHECKED,V
        DS      1-CHECKED,0B9h  ; LDA DTH,Y
        DS      1-CHECKED,ADTH&0FFh
        DS      1-CHECKED,ADTH/256
        DS      1-CHECKED,85h   ; STA V+1
        DS      1-CHECKED,V+1
        DS      1-CHECKED,6Ch   ; JMP (V)
        DS      1-CHECKED,V
        DS      1-CHECKED,0
        DS      CHECKED,4Ch     ; JMP fnext (checked)
        DS      CHECKED,AFNX&0FFh
        DS      CHECKED,AFNX/256
.endm
.macro  NEXTA
        DS      1-CHECKED,0E6h  ; INC IP
        DS      1-CHECKED,IP
        DS      1-CHECKED,0D0h  ; BNE $+4
        DS      1-CHECKED,2
        DS      1-CHECKED,0E6h  ; INC IP+1
        DS      1-CHECKED,IP+1
        DS      1-CHECKED,0A8h  ; TAY
        DS      1-CHECKED,0B9h  ; LDA DTL,Y
        DS      1-CHECKED,ADTL&0FFh
        DS      1-CHECKED,ADTL/256
        DS      1-CHECKED,85h   ; STA V
        DS      1-CHECKED,V
        DS      1-CHECKED,0B9h  ; LDA DTH,Y
        DS      1-CHECKED,ADTH&0FFh
        DS      1-CHECKED,ADTH/256
        DS      1-CHECKED,85h   ; STA V+1
        DS      1-CHECKED,V+1
        DS      1-CHECKED,6Ch   ; JMP (V)
        DS      1-CHECKED,V
        DS      1-CHECKED,0
        DS      CHECKED,4Ch     ; JMP fnext (checked)
        DS      CHECKED,AFNX&0FFh
        DS      CHECKED,AFNX/256
.endm
.macro  NEXTY
        DS      1-CHECKED,0E6h  ; INC IP
        DS      1-CHECKED,IP
        DS      1-CHECKED,0D0h  ; BNE $+4
        DS      1-CHECKED,2
        DS      1-CHECKED,0E6h  ; INC IP+1
        DS      1-CHECKED,IP+1
        DS      1-CHECKED,0B9h  ; LDA DTL,Y
        DS      1-CHECKED,ADTL&0FFh
        DS      1-CHECKED,ADTL/256
        DS      1-CHECKED,85h   ; STA V
        DS      1-CHECKED,V
        DS      1-CHECKED,0B9h  ; LDA DTH,Y
        DS      1-CHECKED,ADTH&0FFh
        DS      1-CHECKED,ADTH/256
        DS      1-CHECKED,85h   ; STA V+1
        DS      1-CHECKED,V+1
        DS      1-CHECKED,6Ch   ; JMP (V)
        DS      1-CHECKED,V
        DS      1-CHECKED,0
        DS      CHECKED,4Ch     ; JMP fnext (checked)
        DS      CHECKED,AFNX&0FFh
        DS      CHECKED,AFNX/256
.endm

FTAB    EQU     0E000h          ; (FAST: the fast build's table, two pages,
        ORG     FTAB+FAST*512   ;   comes first, and the code after it)

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
        IF      QK
        LDA     #0              ; an empty skip cache (a start of 0000h
        TAY                     ;   matches no skip)
skc:    STA     CPAGE*256,Y
        INY
        BNE     skc
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
pkey:   JSR     KEY
        BEQ     next            ; no key
        STA     KEYBUF          ; held for the next '?'
        JSR     chk3            ; (Ctrl-C: back only if the break key is off)
next:
        IF      FAST
        JMP     fnext           ; (the fast build: see "The fast build")
        ENDIF
        IF      CHECKED*(1-FAST)
        ; Both stacks are checked once per character, after it has run. The
        ; return stack has overrun when S is below RSLIM: an overflow leaves
        ; it at 1Eh or 1Fh, an underflow wraps it to 01h (no handler pulls
        ; more than one entry). The data stack has when X is above DSE: an
        ; underflow moves X up to FDh or FEh (no handler moves X by more
        ; than 2, but '$', whose /~ escapes each look first), and an
        ; overflow wraps it from 00h to FFh.
        ; S is kept in RSV, for the report's R: line (an error found inside
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
        IF      1-FAST
        JSR     step
        JMP     next
        ENDIF
        IF      CHECKED
; S/R are overflows, s/r underflows. After an underflow that stack counts as
; empty.
e_rstack:LDA    RSV
        CMP     #10h
        LDA     #'R'
        BCS     ejmp            ; S is 1Eh-1Fh: an overflow
        LDA     #0FFh
        STA     RSV             ; S wrapped to 01h: R:0
        LDA     #'r'
        BNE     ejmp            ; always
e_stack:CPX     #0FFh
        LDA     #'S'
        BCS     ejmp            ; X wrapped from 00h to FFh: an overflow
        LDX     #DSE            ; an underflow: D:0
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
        IF      1-QK
        DB      24h             ; (BIT zp: steps over the SEC)
        ENDIF
        IF      QK
        JMP     closeq          ; (QK: see Speed-ups)
        ENDIF
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
        IF      1-QK
        BNE     next            ; always
        ENDIF
        IF      QK
        JMP     next            ; (closeq moved next out of reach)
        ENDIF

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
        INC     RSV             ; R: does not count the call
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
        IF      1-SBASEU
        BCC     lower           ; 61h-7Ah: A = 20h-39h
        ENDIF
        IF      SBASEU
        BCC     lowq            ; 61h-7Ah: A = 20h-39h
        ENDIF
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

        IF      SBASEU
; a-z, in the unchecked QK builds: a variable followed by '@' or '!' is
; fetched or stored in the same step (x@ is the commonest pair in most
; programs). A checked build checks the stacks between the two, so it keeps
; them apart. (pvar calls lower, which only pushes.)
lowq:   ASL
        STA     T0              ; the cell's offset in the letter page
        LDY     #0
        LDA     (IP),Y
        CMP     #'@'
        BEQ     lwf
        CMP     #'!'
        BEQ     lws
        LDA     T0
        LDY     #>LET
        BNE     pushay          ; always: the address
lwf:    JSR     incip           ; x@: TOS = the cell's value
        JSR     push
        LDY     T0
        LDA     LET,Y
        STA     TL
        LDA     LET+1,Y
        STA     TH
        RTS
lws:    JSR     incip           ; x!: the cell = TOS, and NOS comes up
        LDY     T0
        LDA     TL
        STA     LET,Y
        LDA     TH
        STA     LET+1,Y
        JMP     drop
        ENDIF

        IF      QK
;  ---- Speed-ups (QK builds) ---------------------------------------------
;  The skip cache and the faster skip are at skip, '*' at h_mul and '/' at
;  udiv; x@ and x! (unchecked) at lowq, above.
; A true ')' reads the block start where it is, under the step frame,
; instead of popping it and pushing it back. The break key is looked at as
; pnext would.
closeq: TXA                     ; (TSX trashes X)
        TSX
        LDY     103h,X
        STY     IP
        LDY     104h,X
        STY     IP+1
        TAX
        DEC     CDOWN
        BEQ     cq1
        RTS                     ; into the loop
cq1:    PLA
        PLA                     ; the step frame
        JMP     pkey
        ENDIF




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
        ENDIF
        IF      CHECKED*(1-QK)
        BNE     ejmp2           ; always
        ENDIF
        IF      CHECKED*QK
        JMP     error           ; (the skip cache moved ejmp2 out of reach)
        ENDIF
        IF      CHECKED
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
        IF      1-QK
        LDA     #0
        STA     D1              ; depth
sk1:    JSR     getc
        ENDIF
        IF      (1-QK)*(1-CHECKED)
        BEQ     endprog
        ENDIF
        IF      (1-QK)*CHECKED
        BEQ     sknul
        ENDIF
        IF      1-QK
        CMP     #22h
        BNE     sk2
        JSR     skipstr         ; leaves A = 22h (11h when checked), which
                                ;   matches nothing below
        ENDIF
        IF      (1-QK)*CHECKED
        BEQ     sknul           ; the string ran into the end
        ENDIF
        IF      1-QK
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
        ENDIF
        IF      (1-QK)*CHECKED
        CMP     T0
        BEQ     e_nest          ; the wrong kind
        ENDIF
        IF      1-QK
        RTS                     ; the closer at this level
sk3:    INC     D1
        BNE     sk1
        ENDIF
        IF      QK
; The skip cache (QK builds). Nearly every skip is one that has happened
; before (a loop skips the same false block on every pass), so the first
; scan from each place is remembered: 64 entries of {start, the closer's
; address}, in CPAGE, found by the start's low byte times 4. Only skips that
; start in the program text are kept (the line buffer changes); the cache is
; emptied when the program starts. A program that changes its own text while
; it runs is not looked after.
        LDA     IP+1
        CMP     #>PROG
        BCC     sks             ; below the program text: no cache
        LDA     IP
        ASL
        ASL
        TAY                     ; Y -> the entry
        LDA     IP
        CMP     CPAGE*256,Y
        BNE     sks
        LDA     IP+1
        CMP     CPAGE*256+1,Y
        BNE     sks
        LDA     CPAGE*256+2,Y   ; a hit: the IP goes to the closer, which is
        STA     IP              ;   read
        LDA     CPAGE*256+3,Y
        STA     IP+1
        LDY     #0
        LDA     (IP),Y
        JMP     incip
sks:    LDA     IP
        STA     SKL
        LDA     IP+1
        STA     SKH
        LDY     #0
        STY     D1              ; depth
; The scan reads at IP+Y. Most characters are nothing to it, and two range
; tests rule them out: * to Z, and ^ and up. Only NUL " ( ) [ ] count.
sq1:    LDA     (IP),Y
        INY
        BEQ     sqw
sq2:    CMP     #5Eh
        BCS     sq1             ; ^ _ ` a-z { | } ~ and up: nothing
        CMP     #5Bh
        BCS     sqb             ; [ \ ]
        CMP     #2Ah
        BCS     sq1             ; * to Z: nothing
        CMP     #28h
        BEQ     sqo             ; (
        BCS     sqc             ; )
        CMP     #22h
        BEQ     sqq             ; a string
        CMP     #1
        BCS     sq1             ; the rest below '(': nothing
        ENDIF
        IF      QK*(1-CHECKED)
        JMP     EXIT            ; NUL: the end of the program
        ENDIF
        IF      QK*CHECKED
        JMP     sknul
        ENDIF
        IF      QK
sqw:    INC     IP+1            ; Y went round: on into the next page
        BNE     sq2             ; always
sqq:    JSR     sqip            ; a string: step over it
        JSR     skipstr
        ENDIF
        IF      QK*CHECKED
        BEQ     sknul           ; the string ran into the end
        ENDIF
        IF      QK
        LDY     #0
        BEQ     sq1             ; always
sqo:    INC     D1              ; an opener
        JMP     sq1
sqb:    CMP     #5Ch
        BEQ     sq1             ; '\' is nothing here
        BCC     sqo             ; [
sqc:    DEC     D1              ; ) ]
        BPL     sq1
        JSR     sqip            ; the closer at this level: the IP past it
        ENDIF
        IF      QK*CHECKED
        CMP     T0
        BEQ     e_nest          ; the wrong kind
        ENDIF
        IF      QK
        PHA
        LDA     SKH             ; remember the skip, if it started in the
        CMP     #>PROG          ;   program text
        BCC     sq9
        LDA     SKL
        ASL
        ASL
        TAY
        LDA     SKL
        STA     CPAGE*256,Y
        LDA     SKH
        STA     CPAGE*256+1,Y
        LDA     IP
        SEC
        SBC     #1
        STA     CPAGE*256+2,Y   ; the closer's address
        LDA     IP+1
        SBC     #0
        STA     CPAGE*256+3,Y
sq9:    PLA
        RTS                     ; the closer at this level
; sqip: IP = IP + Y. Keeps A.
sqip:   PHA
        TYA
        CLC
        ADC     IP
        STA     IP
        BCC     sp1
        INC     IP+1
sp1:    PLA
        RTS
        ENDIF
        IF      CHECKED
sknul:  LDA     T0
        BNE     e_nest          ; ( and [ stop with N
        JMP     EXIT            ; \ ends the program
; The end of '$' (h_print): the string's address goes back into TOS; then a
; closing quote drops it, and a NUL (the carry clear) is Q.
pq:     PLA
        STA     TL
        PLA
        STA     TH
        BCS     pdrop
        CPX     #DSE            ; a NUL: Q, unless '$' had nothing on the
        LDA     #'s'            ;   stack at all (X at the empty mark): s
        BCS     ejmp2
e_quote:LDA     #'Q'            ; a string runs into the end
        DB      2Ch             ; (BIT abs: hides the next instruction)
e_nest: LDA     #'N'            ; a skip from ( or [ found the wrong closer
ejmp2:  JMP     error           ;   or the end: the place is the opener
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
;  Console
; =============================================================================

; '$' prints the string at TOS, decoding escapes: '/' plus a character from
; 60h to 7Eh is one of the escapes at pesc; '/' plus any other character
; clears that character's bit 6 (/M is CR, /? is DEL's '?'; '/' and '"' have
; no bit 6, so // and /" give themselves). TOS walks along the string; the
; checked build keeps the address on the hardware stack meanwhile, for a Q
; report (see pq).
        IF      CHECKED
h_print:LDA     TH
        PHA
        LDA     TL
        PHA
        BCC     pr0             ; always: the carry is clear on the way in
        ENDIF
        IF      1-CHECKED
h_print EQU     pr0
        ENDIF
pesc0:  JSR     pesc            ; (an escape, and back into the loop)
pr0:    JSR     tosget
        CMP     #22h
        IF      1-CHECKED
        BEQ     pdrop
        ENDIF
        IF      CHECKED
        BEQ     pq              ; the closing quote, with the carry set
        TAY                     ; (Y is free here)
        BEQ     pq              ; a NUL, with the carry clear
        ENDIF
        CMP     #'/'
        BNE     pr1
        JSR     tosget
        CMP     #60h
        BCC     pr2
        CMP     #7Fh
        BCC     pesc0           ; 60h-7Eh, and the carry is clear
pr2:    AND     #0BFh
pr1:    JSR     CONOUT
        JMP     pr0

h_emit: LDA     TL              ; "'"
        JSR     CONOUT
pdrop:  JMP     drop

; tosget: A = the byte at TOS, and TOS moves on.  inctos: TOS moves on.
tosget: LDY     #0
        LDA     (TL),Y
inctos: INC     TL
        BNE     tg1
        INC     TH
tg1:    RTS

; pesc: the escapes of '$'. A = the character after the '/', 60h to 7Eh, and
; the carry is clear. Each returns into the loop.
;    /a-/z   print the variable, as '#' does
;    /{      clear the screen, the cursor to the top left
;    /}      clear from the cursor to the end of the line
;    /|  /`  show the cursor, hide it
;    /~      ( row col addr -- addr ): the cursor to that row and column,
;            from 0. The two cells under TOS (the string's address) go.
; A - 7Bh sorts them: { 0, | 1, } 2, ~ 3 with the carry set, and ` E5h, a-z
; E6h-FFh with it clear.
        IF      1-ANSI
; With ANSI = 0 the machine's routines do the work.
pesc:   SBC     #7Ah            ; (the carry is clear: - 7Bh)
        BCC     pe1
        BEQ     pcls            ; {
        LSR                     ; | 0, } 1, ~ 1; the carry set for | and ~
        BEQ     pcur            ; |  show: the carry is set
        BCS     pat             ; ~
        JMP     CONEOL          ; }
pcls:   JMP     CONCLS
pe1:    CMP     #0E6h
        BCS     pvar
pcur:   JMP     CONCUR          ; `  hide: the carry is clear
        ENDIF
; /~: the column is NOS, the row the cell under it.
pat:
        IF      CHECKED
        CPX     #DSE-2          ; fewer than two cells under TOS: s
        BCS     e_atu
        ENDIF
        IF      1-ANSI
        LDY     DSL,X           ; the column
        LDA     DSL+1,X         ; the row
        INX
        INX
        JMP     CONAT
        ENDIF
        IF      ANSI
; ESC [ row+1 ; col+1 H (ANSI counts from 1). The row's cell and TOS change
; places first: then '#' prints the row and drops it, prints the column and
; drops it, and TOS is the string's address again.
        INX
        JSR     h_swap
        DEX
        LDY     #M_CSI-MSG
        JSR     prs             ; ESC [
        JSR     inctos
        JSR     h_num           ; the row + 1
        LDA     #';'
        JSR     CONOUT
        JSR     inctos
        JSR     h_num           ; the column + 1
        LDA     #'H'
        JMP     CONOUT
        ENDIF
        IF      CHECKED
e_atu:  JMP     e_stack         ; (X is FAh-FCh: an underflow)
        ENDIF
; a-z: the carry is set. A + 3Ah is the letter - 41h, as step hands it to
; lower: that pushes the variable's address, '@' fetches it, and '#' (next)
; prints it and drops it: TOS is the string's address again.
pvar:   ADC     #39h
        JSR     lower
        JSR     h_fetch

; '#' prints TOS as a signed decimal number, with no space after it. The
; digits are divided off and held on the hardware stack, ended by a 0.
h_num:  LDA     TH
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
        LDA     T0              ; the remainder
        ORA     #'0'
        PHA
        LDA     TL
        ORA     TH
        BNE     pn2
pn3:    PLA
        BEQ     pdrop
        JSR     CONOUT
        JMP     pn3

        IF      ANSI
; With ANSI = 1 they are sequences, each a message at MSG, printed by prs,
; which pesc runs on into. (It sits here, just above prs, for that.)
pesc:   SBC     #7Ah            ; (the carry is clear: - 7Bh). Y is 0, as
                                ;   tosget leaves it, and M_CLS is the first
                                ;   message: Y already points at it
        BCC     pe1
        BEQ     prs             ; {  ESC [ H ESC [ J
        LDY     #M_SHOW-MSG
        LSR                     ; | 0, } 1, ~ 1; the carry set for ~
        BEQ     prs             ; |  ESC [ ? 2 5 h
        BCS     pat             ; ~
        LDY     #M_EOL-MSG      ; }  ESC [ K
        BNE     prs             ; always
pe1:    CMP     #0E6h
        BCS     pvar
        LDY     #M_HIDE-MSG     ; `  ESC [ ? 2 5 l, and on into prs
        ENDIF
        IF      CHECKED+ANSI
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
        ENDIF
        IF      ANSI
M_CLS:  DB      27,'[','H',27,'[','J'+80h ; (the first: pesc counts on it)
M_SHOW: DB      27,'[','?','2','5','h'+80h
M_HIDE: DB      27,'[','?','2','5','l'+80h
M_EOL:  DB      27,'[','K'+80h
M_CSI:  DB      27,'['+80h
        ENDIF
        IF      CHECKED
M_ERR:  DB      13,10,'Err',' '+80h
        DB      ' @',' '+80h
M_NL:   DB      13,10+80h
M_STK:  DB      13,10,'D',':'+80h
M_CD:   DB      ': ..','.'+80h
M_C:    DB      ':'+80h
M_RTN:  DB      13,10,'R',':'+80h
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
        TAY                     ; Y:T0 = x2 + digit
        ASL     TL
        ROL     TH
        ASL     TL
        ROL     TH              ; x8
        CLC
        LDA     TL
        ADC     T0
        STA     TL
        TYA
        ADC     TH
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
        IF      FAST
; (the fast build: as QK below, the rounds unrolled, with Y for the upper
; half's high byte while the low one is added)
h_mul:  LDA     TH
        BEQ     mq8
        LDA     DSH,X
        BEQ     mqs
        JMP     mq16            ; (out of a branch's reach)
mqs:    JSR     h_swap
mq8:    LDA     #0
        STA     T0
        LSR     TL
        BCC     mu0
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mu0:    ROR
        ROR     T0
        ROR     TL
        BCC     mu1
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mu1:    ROR
        ROR     T0
        ROR     TL
        BCC     mu2
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mu2:    ROR
        ROR     T0
        ROR     TL
        BCC     mu3
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mu3:    ROR
        ROR     T0
        ROR     TL
        BCC     mu4
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mu4:    ROR
        ROR     T0
        ROR     TL
        BCC     mu5
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mu5:    ROR
        ROR     T0
        ROR     TL
        BCC     mu6
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mu6:    ROR
        ROR     T0
        ROR     TL
        BCC     mu7
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mu7:    ROR
        ROR     T0
        ROR     TL
        LDA     T0
        STA     TH
        INX
        RTS
mq16:   LDA     #0
        STA     T0
        LSR     TH
        ROR     TL
        BCC     mw0
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw0:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw1
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw1:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw2
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw2:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw3
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw3:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw4
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw4:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw5
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw5:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw6
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw6:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw7
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw7:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw8
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw8:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw9
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw9:    ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw10
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw10:   ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw11
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw11:   ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw12
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw12:   ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw13
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw13:   ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw14
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw14:   ROR
        ROR     T0
        ROR     TH
        ROR     TL
        BCC     mw15
        TAY
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        TYA
        ADC     DSH,X
mw15:   ROR
        ROR     T0
        ROR     TH
        ROR     TL
        INX
        RTS
        ENDIF
        IF      QK*(1-FAST)
; (QK: with an operand below 256, 8 rounds, not 16: that one becomes the
; multiplier, so the product's low byte comes out of TL and its high byte is
; left in T0. Most multiplications have one: a count or a small constant.)
h_mul:  LDA     TH
        BEQ     mq8             ; the multiplier is below 256
        LDA     DSH,X
        BNE     mq16
        JSR     h_swap          ; the multiplicand is: it becomes the multiplier
mq8:    LDY     #8
        LDA     #0
        STA     T0
        LSR     TL
mq1:    BCC     mq2
        STA     T1
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        LDA     T1
        ADC     DSH,X
mq2:    ROR
        ROR     T0
        ROR     TL
        DEY
        BNE     mq1
        LDA     T0
        STA     TH
        INX
        RTS
mq16:
        ENDIF
        IF      1-QK
h_mul:
        ENDIF
        IF      1-FAST
        LDY     #16             ; the round count
        LDA     #0
        STA     T0              ; A:T0 = the upper half
        LSR     TH
        ROR     TL              ; the first multiplier bit
ml1:    BCC     ml2
        STA     T1
        CLC
        LDA     T0
        ADC     DSL,X
        STA     T0
        LDA     T1
        ADC     DSH,X           ; upper half += the multiplicand
ml2:    ROR
        ROR     T0
        ROR     TH
        ROR     TL              ; everything one place right; next bit out
        DEY
        BNE     ml1
        INX                     ; drop the multiplicand
        RTS
        ENDIF

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
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b, r is pushed
; and gets the sign of a. Unchecked, dividing by zero returns two cells of no
; meaning; checked, it stops with Z.
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
        JSR     drop            ; TOS = a
        JSR     absv            ; TOS = |a|
        JSR     udiv            ; TOS = q, T0/T1 = r
        PLA
        JSR     negm            ; q's sign
        LDA     T0
        LDY     T1
        JSR     pushay          ; r on top
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

; chkst: stop unless the page in A is in the program's own space, from the
; letter page up to the heap limit. Keeps Y.
chkst:  CMP     #LETPAGE
        BCC     e_store
        CMP     #HEAPLIM
        BCS     e_store
        RTS
        ENDIF

; udiv: unsigned TOS / D (D <= 8000h). TOS becomes the quotient and T0/T1
; the remainder. The low byte of each trial subtraction waits on the
; hardware stack.
; Dividing by 2 is one shift (the spec wants that fast).
udiv:   LDA     #0
        STA     T0
        STA     T1
        IF      1-QK
        LDA     D0
        EOR     #2
        ORA     D1
        BNE     ud0
        LSR     TH
        ROR     TL              ; the quotient
        ROL     T0              ; the remainder: the bit that fell out
        RTS
        ENDIF
        IF      QK
; (QK: any power of two is shifts: 2, and 32, 64, 256 and the like, which
; fixed point and byte work use all the time.)
        LDY     D0
        LDA     D1
        BNE     uq1             ; 256 and up
        TYA
        BEQ     ud0             ; by 0: the long way (it means nothing anyway)
        DEY
        TYA
        AND     D0
        BNE     ud0             ; not a power of two
        TYA                     ; by 2^k below 256: r = a & (2^k - 1),
        AND     TL
        STA     T0
        LDA     D0              ;   and q = a >> k
        BNE     uq2             ; always
uq1:    TYA
        BNE     ud0             ; not a power of two
        LDY     D1
        DEY
        TYA
        AND     D1
        BNE     ud0             ; not a power of two
        TYA                     ; by 2^k, 256 and up: r = a & (2^k - 1),
        AND     TH
        STA     T1
        LDA     TL
        STA     T0
        LDA     TH              ;   and q = (a >> 8) >> (k - 8)
        STA     TL
        LDA     #0
        STA     TH
        LDA     D1
uq2:    LSR                     ; a bit of 2^k: one shift for each 0 below
        BCS     uq9             ;   the 1
uq3:    LSR     TH
        ROR     TL
        LSR
        BCC     uq3
uq9:    RTS
        ENDIF
        IF      FAST
ud0:                            ; (the fast build: the 16 rounds unrolled)
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv0
        STA     T1
        STY     T0
        INC     TL
uv0:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv1
        STA     T1
        STY     T0
        INC     TL
uv1:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv2
        STA     T1
        STY     T0
        INC     TL
uv2:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv3
        STA     T1
        STY     T0
        INC     TL
uv3:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv4
        STA     T1
        STY     T0
        INC     TL
uv4:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv5
        STA     T1
        STY     T0
        INC     TL
uv5:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv6
        STA     T1
        STY     T0
        INC     TL
uv6:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv7
        STA     T1
        STY     T0
        INC     TL
uv7:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv8
        STA     T1
        STY     T0
        INC     TL
uv8:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv9
        STA     T1
        STY     T0
        INC     TL
uv9:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv10
        STA     T1
        STY     T0
        INC     TL
uv10:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv11
        STA     T1
        STY     T0
        INC     TL
uv11:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv12
        STA     T1
        STY     T0
        INC     TL
uv12:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv13
        STA     T1
        STY     T0
        INC     TL
uv13:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv14
        STA     T1
        STY     T0
        INC     TL
uv14:
        ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        TAY
        LDA     T1
        SBC     D1
        BCC     uv15
        STA     T1
        STY     T0
        INC     TL
uv15:
        RTS
        ENDIF
        IF      1-FAST
ud0:    LDY     #16
ud1:    ASL     TL
        ROL     TH
        ROL     T0
        ROL     T1
        SEC
        LDA     T0
        SBC     D0
        PHA
        LDA     T1
        SBC     D1
        BCC     ud2
        STA     T1
        PLA
        STA     T0
        INC     TL              ; the quotient bit (TL's bit 0 is free)
        DB      24h             ; (BIT zp: steps over the PLA)
ud2:    PLA
        DEY
        BNE     ud1
        RTS
        ENDIF

; =============================================================================
;  Fetches, and the keyboard
; =============================================================================

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
cf2:    STA     TL              ; TOS = A (low), Y (high)
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
        LDY     #>LINEBUF
        BNE     cf2             ; always: TOS = the line's address

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




        IF      CHECKED
; =============================================================================
;  Checked build: the error report
; =============================================================================

; error: the report, then EXIT. A = the letter, PLACE = the place, X = the
; data stack to show, RSV = S for the R: line. Nothing here relies on S: an
; overflowed or underflowed hardware stack wraps inside its page, and only
; its depth is shown.
;   CR LF
;   Err X @ line,col CR LF
;   D:n: [...] and the top 8 cells at most, bottom to top  CR LF
;   R:n CR LF
; The numbers go through '#' (h_num), each pushed over the data stack first
; and popped again by '#', so the stack is shown as it was.
error:  PHA                     ; the letter
        LDY     #M_ERR-MSG
        JSR     prs             ; CR LF "Err "
        PLA
        JSR     CONOUT
        JSR     prs             ; " @ " (it follows M_ERR)
; The line and the column of the place, both from 1. The line is counted in
; a cell pushed over the data stack (TOS). A place below the program is in
; the -n? line buffer: line 0, and the column is the place in the buffer.
; Otherwise IP (free now: the program has stopped) runs from PROG to the
; place, counting LFs; CL keeps where the last line started, and the column
; is the place minus that, plus 1.
        LDA     #<LINEBUF
        STA     CL
        LDA     #>LINEBUF
        STA     CL+1
        LDA     #0
        TAY
        JSR     pushay          ; TOS = the line, 0 so far
        LDA     PLACE
        CMP     #<PROG
        LDA     PLACE+1
        SBC     #>PROG
        BCC     lc9             ; below the program: line 0
        INC     TL
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
        JSR     inctos          ; an LF: a new line starts after it
        BNE     lc3             ; always (Z clear: fewer than 65536 lines)
lc9:    JSR     h_num           ; the line (and it is dropped)
        LDA     #','
        JSR     CONOUT
        SEC
        LDA     PLACE
        SBC     CL
        PHA
        LDA     PLACE+1
        SBC     CL+1
        TAY
        PLA
        JSR     pushay
        JSR     inctos          ; + 1
        JSR     h_num           ; the column
        LDY     #M_STK-MSG
        JSR     prs             ; CR LF "D:"
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
er3:    STA     T2              ; T2 = how many cells to show (the place
                                ;   is no longer needed)
        JSR     prs
        JSR     push            ; TOS into memory with the rest: cell i from
                                ;   the top is at DSL+X+i now
er4:    LDA     T2              ; cells T2-1 down to 0, the top last
        BEQ     er5
        DEC     T2
        LDA     #' '
        JSR     CONOUT
        TXA
        CLC
        ADC     T2
        TAY
        LDA     DSL,Y
        PHA
        LDA     DSH,Y
        TAY
        PLA
        JSR     prnum
        JMP     er4
er5:    LDY     #M_RTN-MSG
        JSR     prs             ; CR LF "R:"
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

        ENDIF

; =============================================================================
;  The fast build (SPEED = 2)
;
;  The inner loop is a table: 256 entries, the low bytes of the handlers'
;  addresses in one page (DTL) and the high bytes in the next (DTH). The
;  dispatcher, NEXTF, is inline at the end of the fast build's own entries,
;  so there is no JSR and no RTS per character:
;      LDY #0 / LDA (IP),Y / INC IP / BNE $+4 / INC IP+1 / TAY /
;      LDA DTL,Y / STA V / LDA DTH,Y / STA V+1 / JMP (V)
;  The letters and digits have one entry each, which knows its cell or its
;  value already; the commonest punctuation is written for the table; the
;  rest reach the ordinary handlers through a thunk (CLC / JSR handler /
;  NEXTF, or JMP fnext for the rare ones), which gives them the step frame
;  and the clear carry they expect.
;  The ordinary handlers that end at next or pnext go to fnext, the same
;  dispatcher. In the checked build NEXTF is JMP fnext, which checks the
;  stacks first, as next does in the other builds.
;  Everything here is read-only: the image can be ROM, as the others are.
;  The table takes the image's first two pages (E000h-E1FFh); the code
;  starts after it.
; =============================================================================
        IF      FAST
; fnext: the dispatcher, after the checks of the checked build
fnext:
        ENDIF
        IF      FAST*CHECKED
        ; (the same checks as next in the other checked builds)
        TXA                     ; TSX trashes X: keep it in A
        TSX
        STX     RSV
        CPX     #RSLIM
        TAX
        BCS     fn1
        JMP     e_rstack
fn1:    CPX     #DSE+1
        BCC     fn3
        JMP     e_stack
fn3:    LDA     IP
        STA     PLACE
        LDA     IP+1
        STA     PLACE+1
        ENDIF
        IF      FAST
        LDY     #0
        LDA     (IP),Y
        INC     IP
        BNE     fn4
        INC     IP+1
fn4:    TAY
        LDA     DTL,Y
        STA     V
        LDA     DTH,Y
        STA     V+1
        JMP     (V)

; fpoll: the break check of pnext, as a subroutine, for the entries that
; look at the keyboard (a word call, a true ( and a true ))
fpoll:  JSR     KEY
        BEQ     fp9             ; no key
        STA     KEYBUF          ; held for the next '?'
        JMP     chk3            ; (Ctrl-C: back only if the break key is off)
fp9:    RTS

; The thunks: the rest of the punctuation, through the ordinary handlers
ft_str: CLC                     ; "
        JSR     h_str
        JMP     fnext           ; (rare enough: the shared dispatcher)
ft_num: CLC                     ; #
        JSR     h_num
        JMP     fnext           ; (rare enough: the shared dispatcher)
ft_prt: CLC                     ; $
        JSR     h_print
        JMP     fnext           ; (rare enough: the shared dispatcher)
ft_emit:CLC                     ; '
        JSR     h_emit
        JMP     fnext           ; (rare enough: the shared dispatcher)
ft_div: CLC                     ; /
        JSR     h_div
        NEXTF
ft_key: CLC                     ; ?
        JSR     h_key
        JMP     fnext           ; (rare enough: the shared dispatcher)
ft_def: CLC                     ; [
        JSR     h_def
        NEXTF
ft_brk: CLC                     ; \
        JSR     h_break
        NEXTF
ft_alc: CLC                     ; _
        JSR     h_alloc
        JMP     fnext           ; (rare enough: the shared dispatcher)
ft_grv: CLC                     ; `
        JSR     h_grave
        JMP     fnext           ; (rare enough: the shared dispatcher)
ft_tor: CLC                     ; {
        JSR     h_tor
        JMP     fnext           ; (rare enough: the shared dispatcher)
ft_frr: CLC                     ; }
        JSR     h_fromr
        JMP     fnext           ; (rare enough: the shared dispatcher)
        ENDIF
        IF      FAST*CHECKED
ft_sto: CLC                     ; ! (checked: it checks the address)
        JSR     h_store
        JMP     fnext
ft_cst: CLC                     ; . (the same)
        JSR     h_cstore
        JMP     fnext
        ENDIF
        IF      FAST

; The commonest punctuation, written for the table
fs_add: CLC                     ; +
        LDA     DSL,X
        ADC     TL
        STA     TL
        LDA     DSH,X
        ADC     TH
        STA     TH
        INX
        NEXTF
fs_sub: LDY     #0              ; -
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fsb1
        CMP     #30h
        BCS     fsb2            ; a digit next: a negative number
fsb1:   SEC
        LDA     DSL,X
        SBC     TL
        STA     TL
        LDA     DSH,X
        SBC     TH
        STA     TH
        INX
        NEXTF
fsb2:   JSR     negnum
        NEXTF
fs_dup: DEX                     ; :
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        NEXTF
fs_drp: LDA     DSL,X           ; ;
        STA     TL
        LDA     DSH,X
        STA     TH
        INX
        NEXTF
fs_swp: LDY     DSL,X           ; %
        LDA     TL
        STA     DSL,X
        STY     TL
        LDY     DSH,X
        LDA     TH
        STA     DSH,X
        STY     TH
        NEXTF
fs_fet: LDY     #1              ; @
        LDA     (TL),Y
        STA     T1
        DEY
        LDA     (TL),Y
        STA     TL
        LDA     T1
        STA     TH
        NEXTF
fs_cft: LDY     #0              ; ,
        LDA     (TL),Y
        STA     TL
        STY     TH
        NEXTF
fs_lt:  LDA     DSL,X           ; < (as h_lt)
        CMP     TL
        LDA     DSH,X
        SBC     TH
        BVS     flt1
        EOR     #80h
flt1:   ASL
        INX
        LDA     #0
        ADC     #0FFh
        STA     TL
        STA     TH
        NEXTF
fs_gt:  LDA     TL              ; > (b < a)
        CMP     DSL,X
        LDA     TH
        SBC     DSH,X
        BVS     fgt1
        EOR     #80h
fgt1:   ASL
        INX
        LDA     #0
        ADC     #0FFh
        STA     TL
        STA     TH
        NEXTF
fs_eq:  LDY     #0              ; =
        LDA     DSL,X
        CMP     TL
        BNE     feq1
        LDA     DSH,X
        CMP     TH
        BNE     feq1
        DEY
feq1:   STY     TL
        STY     TH
        INX
        NEXTF
fs_and: LDA     DSL,X           ; &
        AND     TL
        STA     TL
        LDA     DSH,X
        AND     TH
        STA     TH
        INX
        NEXTF
fs_or:  LDA     DSL,X           ; |
        ORA     TL
        STA     TL
        LDA     DSH,X
        ORA     TH
        STA     TH
        INX
        NEXTF
fs_xor: LDA     DSL,X           ; ^
        EOR     TL
        STA     TL
        LDA     DSH,X
        EOR     TH
        STA     TH
        INX
        NEXTF
fs_not: LDA     TL              ; ~
        EOR     #0FFh
        STA     TL
        LDA     TH
        EOR     #0FFh
        STA     TH
        NEXTF
fs_mul: JSR     h_mul           ; *
        NEXTF
fs_opn: LDA     TL              ; (
        ORA     TH
        LDY     DSL,X
        STY     TL
        LDY     DSH,X
        STY     TH
        INX
        TAY
        BEQ     fop1
        LDA     IP+1            ; true: the block starts at the IP
        PHA
        LDA     IP
        PHA
        DEC     CDOWN
        BNE     fop2
        JSR     fpoll
fop2:   NEXTF
fop1:   JSR     skpo            ; false: skip to the matching )
        NEXTF
fs_cls: LDA     TL              ; )
        ORA     TH
        LDY     DSL,X
        STY     TL
        LDY     DSH,X
        STY     TH
        INX
        TAY
        BEQ     fcl1
        TXA                     ; true: the block start, read where it is
        TSX
        LDY     101h,X
        STY     IP
        LDY     102h,X
        STY     IP+1
        TAX
        DEC     CDOWN
        BNE     fcl2
        JSR     fpoll
fcl2:   NEXTF
fcl1:   PLA                     ; false: drop it
        PLA
        NEXTF
fs_ret: PLA                     ; ]
        STA     IP
        PLA
        STA     IP+1
        NEXTF
        ENDIF
; skpo: a false ( skips (the checked build: ] is the wrong closer for it)
        IF      FAST*CHECKED
skpo:   LDA     #']'
        JMP     skip
        ENDIF
        IF      FAST*(1-CHECKED)
skpo:   JMP     skip
; ! and . (unchecked)
ft_sto: LDY     #0              ; !
        LDA     DSL,X
        STA     (TL),Y
        INY
        LDA     DSH,X
        STA     (TL),Y
        INX
        LDA     DSL,X
        STA     TL
        LDA     DSH,X
        STA     TH
        INX
        NEXTF
ft_cst: LDY     #0              ; .
        LDA     DSL,X
        STA     (TL),Y
        INX
        LDA     DSL,X
        STA     TL
        LDA     DSH,X
        STA     TH
        INX
        NEXTF
        ENDIF
        IF      FAST

; 0-9: push the digit; more digits go on through rdnum. A character that
; is not a digit is dispatched from A, as it has been read already.
fd0:    DEX                     ; 0
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #0
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd0a
        CMP     #30h
        BCC     fd0a
        JMP     fdm             ; more digits
fd0a:   NEXTA
fd1:    DEX                     ; 1
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #1
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd1a
        CMP     #30h
        BCC     fd1a
        JMP     fdm             ; more digits
fd1a:   NEXTA
fd2:    DEX                     ; 2
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #2
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd2a
        CMP     #30h
        BCC     fd2a
        JMP     fdm             ; more digits
fd2a:   NEXTA
fd3:    DEX                     ; 3
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #3
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd3a
        CMP     #30h
        BCC     fd3a
        JMP     fdm             ; more digits
fd3a:   NEXTA
fd4:    DEX                     ; 4
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #4
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd4a
        CMP     #30h
        BCC     fd4a
        JMP     fdm             ; more digits
fd4a:   NEXTA
fd5:    DEX                     ; 5
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #5
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd5a
        CMP     #30h
        BCC     fd5a
        JMP     fdm             ; more digits
fd5a:   NEXTA
fd6:    DEX                     ; 6
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #6
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd6a
        CMP     #30h
        BCC     fd6a
        JMP     fdm             ; more digits
fd6a:   NEXTA
fd7:    DEX                     ; 7
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #7
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd7a
        CMP     #30h
        BCC     fd7a
        JMP     fdm             ; more digits
fd7a:   NEXTA
fd8:    DEX                     ; 8
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #8
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd8a
        CMP     #30h
        BCC     fd8a
        JMP     fdm             ; more digits
fd8a:   NEXTA
fd9:    DEX                     ; 9
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #9
        STA     TL
        LDA     #0
        STA     TH
        TAY
        LDA     (IP),Y
        CMP     #3Ah
        BCS     fd9a
        CMP     #30h
        BCC     fd9a
        JMP     fdm             ; more digits
fd9a:   NEXTA
fdm:    JSR     rdnum           ; more digits
        NEXTF

; A-Z: call the word. The return address goes on the return stack, the
; IP becomes the word's body, and the break key is looked at as pnext would.
fuA:    LDA     IP+1            ; A
        PHA
        LDA     IP
        PHA
        LDA     LET+0
        STA     IP
        LDA     LET+1
        STA     IP+1
        DEC     CDOWN
        BNE     fuAa
        JSR     fpoll
fuAa:   NEXTF
fuB:    LDA     IP+1            ; B
        PHA
        LDA     IP
        PHA
        LDA     LET+2
        STA     IP
        LDA     LET+3
        STA     IP+1
        DEC     CDOWN
        BNE     fuBa
        JSR     fpoll
fuBa:   NEXTF
fuC:    LDA     IP+1            ; C
        PHA
        LDA     IP
        PHA
        LDA     LET+4
        STA     IP
        LDA     LET+5
        STA     IP+1
        DEC     CDOWN
        BNE     fuCa
        JSR     fpoll
fuCa:   NEXTF
fuD:    LDA     IP+1            ; D
        PHA
        LDA     IP
        PHA
        LDA     LET+6
        STA     IP
        LDA     LET+7
        STA     IP+1
        DEC     CDOWN
        BNE     fuDa
        JSR     fpoll
fuDa:   NEXTF
fuE:    LDA     IP+1            ; E
        PHA
        LDA     IP
        PHA
        LDA     LET+8
        STA     IP
        LDA     LET+9
        STA     IP+1
        DEC     CDOWN
        BNE     fuEa
        JSR     fpoll
fuEa:   NEXTF
fuF:    LDA     IP+1            ; F
        PHA
        LDA     IP
        PHA
        LDA     LET+10
        STA     IP
        LDA     LET+11
        STA     IP+1
        DEC     CDOWN
        BNE     fuFa
        JSR     fpoll
fuFa:   NEXTF
fuG:    LDA     IP+1            ; G
        PHA
        LDA     IP
        PHA
        LDA     LET+12
        STA     IP
        LDA     LET+13
        STA     IP+1
        DEC     CDOWN
        BNE     fuGa
        JSR     fpoll
fuGa:   NEXTF
fuH:    LDA     IP+1            ; H
        PHA
        LDA     IP
        PHA
        LDA     LET+14
        STA     IP
        LDA     LET+15
        STA     IP+1
        DEC     CDOWN
        BNE     fuHa
        JSR     fpoll
fuHa:   NEXTF
fuI:    LDA     IP+1            ; I
        PHA
        LDA     IP
        PHA
        LDA     LET+16
        STA     IP
        LDA     LET+17
        STA     IP+1
        DEC     CDOWN
        BNE     fuIa
        JSR     fpoll
fuIa:   NEXTF
fuJ:    LDA     IP+1            ; J
        PHA
        LDA     IP
        PHA
        LDA     LET+18
        STA     IP
        LDA     LET+19
        STA     IP+1
        DEC     CDOWN
        BNE     fuJa
        JSR     fpoll
fuJa:   NEXTF
fuK:    LDA     IP+1            ; K
        PHA
        LDA     IP
        PHA
        LDA     LET+20
        STA     IP
        LDA     LET+21
        STA     IP+1
        DEC     CDOWN
        BNE     fuKa
        JSR     fpoll
fuKa:   NEXTF
fuL:    LDA     IP+1            ; L
        PHA
        LDA     IP
        PHA
        LDA     LET+22
        STA     IP
        LDA     LET+23
        STA     IP+1
        DEC     CDOWN
        BNE     fuLa
        JSR     fpoll
fuLa:   NEXTF
fuM:    LDA     IP+1            ; M
        PHA
        LDA     IP
        PHA
        LDA     LET+24
        STA     IP
        LDA     LET+25
        STA     IP+1
        DEC     CDOWN
        BNE     fuMa
        JSR     fpoll
fuMa:   NEXTF
fuN:    LDA     IP+1            ; N
        PHA
        LDA     IP
        PHA
        LDA     LET+26
        STA     IP
        LDA     LET+27
        STA     IP+1
        DEC     CDOWN
        BNE     fuNa
        JSR     fpoll
fuNa:   NEXTF
fuO:    LDA     IP+1            ; O
        PHA
        LDA     IP
        PHA
        LDA     LET+28
        STA     IP
        LDA     LET+29
        STA     IP+1
        DEC     CDOWN
        BNE     fuOa
        JSR     fpoll
fuOa:   NEXTF
fuP:    LDA     IP+1            ; P
        PHA
        LDA     IP
        PHA
        LDA     LET+30
        STA     IP
        LDA     LET+31
        STA     IP+1
        DEC     CDOWN
        BNE     fuPa
        JSR     fpoll
fuPa:   NEXTF
fuQ:    LDA     IP+1            ; Q
        PHA
        LDA     IP
        PHA
        LDA     LET+32
        STA     IP
        LDA     LET+33
        STA     IP+1
        DEC     CDOWN
        BNE     fuQa
        JSR     fpoll
fuQa:   NEXTF
fuR:    LDA     IP+1            ; R
        PHA
        LDA     IP
        PHA
        LDA     LET+34
        STA     IP
        LDA     LET+35
        STA     IP+1
        DEC     CDOWN
        BNE     fuRa
        JSR     fpoll
fuRa:   NEXTF
fuS:    LDA     IP+1            ; S
        PHA
        LDA     IP
        PHA
        LDA     LET+36
        STA     IP
        LDA     LET+37
        STA     IP+1
        DEC     CDOWN
        BNE     fuSa
        JSR     fpoll
fuSa:   NEXTF
fuT:    LDA     IP+1            ; T
        PHA
        LDA     IP
        PHA
        LDA     LET+38
        STA     IP
        LDA     LET+39
        STA     IP+1
        DEC     CDOWN
        BNE     fuTa
        JSR     fpoll
fuTa:   NEXTF
fuU:    LDA     IP+1            ; U
        PHA
        LDA     IP
        PHA
        LDA     LET+40
        STA     IP
        LDA     LET+41
        STA     IP+1
        DEC     CDOWN
        BNE     fuUa
        JSR     fpoll
fuUa:   NEXTF
fuV:    LDA     IP+1            ; V
        PHA
        LDA     IP
        PHA
        LDA     LET+42
        STA     IP
        LDA     LET+43
        STA     IP+1
        DEC     CDOWN
        BNE     fuVa
        JSR     fpoll
fuVa:   NEXTF
fuW:    LDA     IP+1            ; W
        PHA
        LDA     IP
        PHA
        LDA     LET+44
        STA     IP
        LDA     LET+45
        STA     IP+1
        DEC     CDOWN
        BNE     fuWa
        JSR     fpoll
fuWa:   NEXTF
fuX:    LDA     IP+1            ; X
        PHA
        LDA     IP
        PHA
        LDA     LET+46
        STA     IP
        LDA     LET+47
        STA     IP+1
        DEC     CDOWN
        BNE     fuXa
        JSR     fpoll
fuXa:   NEXTF
fuY:    LDA     IP+1            ; Y
        PHA
        LDA     IP
        PHA
        LDA     LET+48
        STA     IP
        LDA     LET+49
        STA     IP+1
        DEC     CDOWN
        BNE     fuYa
        JSR     fpoll
fuYa:   NEXTF
fuZ:    LDA     IP+1            ; Z
        PHA
        LDA     IP
        PHA
        LDA     LET+50
        STA     IP
        LDA     LET+51
        STA     IP+1
        DEC     CDOWN
        BNE     fuZa
        JSR     fpoll
fuZa:   NEXTF
        ENDIF
        IF      FAST*(1-CHECKED)
; a-z, unchecked: a variable followed by @ or ! is fetched or stored in the
; same step; otherwise its address is pushed, and the character after it,
; read already, is dispatched from A or Y.
fva:    LDY     #0              ; a
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvaf
        CMP     #'!'
        BEQ     fvas
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #40h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvaf:   LDY     #40h
        JMP     fvat
fvas:   LDY     #40h
        JMP     fvst
fvb:    LDY     #0              ; b
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvbf
        CMP     #'!'
        BEQ     fvbs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #42h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvbf:   LDY     #42h
        JMP     fvat
fvbs:   LDY     #42h
        JMP     fvst
fvc:    LDY     #0              ; c
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvcf
        CMP     #'!'
        BEQ     fvcs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #44h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvcf:   LDY     #44h
        JMP     fvat
fvcs:   LDY     #44h
        JMP     fvst
fvd:    LDY     #0              ; d
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvdf
        CMP     #'!'
        BEQ     fvds
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #46h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvdf:   LDY     #46h
        JMP     fvat
fvds:   LDY     #46h
        JMP     fvst
fve:    LDY     #0              ; e
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvef
        CMP     #'!'
        BEQ     fves
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #48h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvef:   LDY     #48h
        JMP     fvat
fves:   LDY     #48h
        JMP     fvst
fvf:    LDY     #0              ; f
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvff
        CMP     #'!'
        BEQ     fvfs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #4Ah
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvff:   LDY     #4Ah
        JMP     fvat
fvfs:   LDY     #4Ah
        JMP     fvst
fvg:    LDY     #0              ; g
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvgf
        CMP     #'!'
        BEQ     fvgs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #4Ch
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvgf:   LDY     #4Ch
        JMP     fvat
fvgs:   LDY     #4Ch
        JMP     fvst
fvh:    LDY     #0              ; h
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvhf
        CMP     #'!'
        BEQ     fvhs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #4Eh
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvhf:   LDY     #4Eh
        JMP     fvat
fvhs:   LDY     #4Eh
        JMP     fvst
fvi:    LDY     #0              ; i
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvif
        CMP     #'!'
        BEQ     fvis
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #50h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvif:   LDY     #50h
        JMP     fvat
fvis:   LDY     #50h
        JMP     fvst
fvj:    LDY     #0              ; j
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvjf
        CMP     #'!'
        BEQ     fvjs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #52h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvjf:   LDY     #52h
        JMP     fvat
fvjs:   LDY     #52h
        JMP     fvst
fvk:    LDY     #0              ; k
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvkf
        CMP     #'!'
        BEQ     fvks
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #54h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvkf:   LDY     #54h
        JMP     fvat
fvks:   LDY     #54h
        JMP     fvst
fvl:    LDY     #0              ; l
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvlf
        CMP     #'!'
        BEQ     fvls
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #56h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvlf:   LDY     #56h
        JMP     fvat
fvls:   LDY     #56h
        JMP     fvst
fvm:    LDY     #0              ; m
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvmf
        CMP     #'!'
        BEQ     fvms
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #58h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvmf:   LDY     #58h
        JMP     fvat
fvms:   LDY     #58h
        JMP     fvst
fvn:    LDY     #0              ; n
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvnf
        CMP     #'!'
        BEQ     fvns
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #5Ah
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvnf:   LDY     #5Ah
        JMP     fvat
fvns:   LDY     #5Ah
        JMP     fvst
fvo:    LDY     #0              ; o
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvof
        CMP     #'!'
        BEQ     fvos
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #5Ch
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvof:   LDY     #5Ch
        JMP     fvat
fvos:   LDY     #5Ch
        JMP     fvst
fvp:    LDY     #0              ; p
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvpf
        CMP     #'!'
        BEQ     fvps
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #5Eh
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvpf:   LDY     #5Eh
        JMP     fvat
fvps:   LDY     #5Eh
        JMP     fvst
fvq:    LDY     #0              ; q
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvqf
        CMP     #'!'
        BEQ     fvqs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #60h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvqf:   LDY     #60h
        JMP     fvat
fvqs:   LDY     #60h
        JMP     fvst
fvr:    LDY     #0              ; r
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvrf
        CMP     #'!'
        BEQ     fvrs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #62h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvrf:   LDY     #62h
        JMP     fvat
fvrs:   LDY     #62h
        JMP     fvst
fvs:    LDY     #0              ; s
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvsf
        CMP     #'!'
        BEQ     fvss
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #64h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvsf:   LDY     #64h
        JMP     fvat
fvss:   LDY     #64h
        JMP     fvst
fvt:    LDY     #0              ; t
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvtf
        CMP     #'!'
        BEQ     fvts
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #66h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvtf:   LDY     #66h
        JMP     fvat
fvts:   LDY     #66h
        JMP     fvst
fvu:    LDY     #0              ; u
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvuf
        CMP     #'!'
        BEQ     fvus
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #68h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvuf:   LDY     #68h
        JMP     fvat
fvus:   LDY     #68h
        JMP     fvst
fvv:    LDY     #0              ; v
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvvf
        CMP     #'!'
        BEQ     fvvs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #6Ah
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvvf:   LDY     #6Ah
        JMP     fvat
fvvs:   LDY     #6Ah
        JMP     fvst
fvw:    LDY     #0              ; w
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvwf
        CMP     #'!'
        BEQ     fvws
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #6Ch
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvwf:   LDY     #6Ch
        JMP     fvat
fvws:   LDY     #6Ch
        JMP     fvst
fvx:    LDY     #0              ; x
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvxf
        CMP     #'!'
        BEQ     fvxs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #6Eh
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvxf:   LDY     #6Eh
        JMP     fvat
fvxs:   LDY     #6Eh
        JMP     fvst
fvy:    LDY     #0              ; y
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvyf
        CMP     #'!'
        BEQ     fvys
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #70h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvyf:   LDY     #70h
        JMP     fvat
fvys:   LDY     #70h
        JMP     fvst
fvz:    LDY     #0              ; z
        LDA     (IP),Y
        CMP     #'@'
        BEQ     fvzf
        CMP     #'!'
        BEQ     fvzs
        TAY                     ; not @ or !: push the address
        DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #72h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTY
fvzf:   LDY     #72h
        JMP     fvat
fvzs:   LDY     #72h
        JMP     fvst
; fvat: x@, and fvst: x!, for the cell at LET+Y. The IP is at the @ or !.
fvat:   INC     IP
        BNE     fva1
        INC     IP+1
fva1:   DEX
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     LET,Y
        STA     TL
        LDA     LET+1,Y
        STA     TH
        NEXTF
fvst:   INC     IP
        BNE     fvs1
        INC     IP+1
fvs1:   LDA     TL
        STA     LET,Y
        LDA     TH
        STA     LET+1,Y
        LDA     DSL,X
        STA     TL
        LDA     DSH,X
        STA     TH
        INX
        NEXTF
fnul    EQU     EXIT            ; NUL: the end of the program
fhi     EQU     fign            ; 80h-FFh: nothing
        ENDIF
        IF      FAST*CHECKED
; a-z, checked: push the cell's address (a checked build checks the stacks
; between the variable and what follows it, so it keeps them apart)
fva:    DEX                     ; a
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #40h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvb:    DEX                     ; b
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #42h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvc:    DEX                     ; c
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #44h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvd:    DEX                     ; d
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #46h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fve:    DEX                     ; e
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #48h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvf:    DEX                     ; f
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #4Ah
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvg:    DEX                     ; g
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #4Ch
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvh:    DEX                     ; h
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #4Eh
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvi:    DEX                     ; i
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #50h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvj:    DEX                     ; j
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #52h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvk:    DEX                     ; k
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #54h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvl:    DEX                     ; l
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #56h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvm:    DEX                     ; m
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #58h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvn:    DEX                     ; n
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #5Ah
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvo:    DEX                     ; o
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #5Ch
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvp:    DEX                     ; p
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #5Eh
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvq:    DEX                     ; q
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #60h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvr:    DEX                     ; r
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #62h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvs:    DEX                     ; s
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #64h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvt:    DEX                     ; t
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #66h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvu:    DEX                     ; u
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #68h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvv:    DEX                     ; v
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #6Ah
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvw:    DEX                     ; w
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #6Ch
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvx:    DEX                     ; x
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #6Eh
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvy:    DEX                     ; y
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #70h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
fvz:    DEX                     ; z
        LDA     TL
        STA     DSL,X
        LDA     TH
        STA     DSH,X
        LDA     #72h
        STA     TL
        LDA     #>LET
        STA     TH
        NEXTF
; NUL: the end of the program, or an undefined word (see e_undef, which
; takes a step frame off first: two bytes are pushed for it)
fnul:   PHA
        PHA
        JMP     endprog
fhi     EQU     e_resv          ; 80h-FFh: reserved (X)
        ENDIF
        IF      FAST
fign:   NEXTF                   ; 01h-20h and DEL: nothing
; the table: low bytes, then high bytes, each a page, in the image's first
; two pages (the code starts after them: see the ORG at start)
        ORG     FTAB
DTL:
        DB      fnul&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh     ; 00h
        DB      fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh     ; 08h
        DB      fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh     ; 10h
        DB      fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh     ; 18h
        DB      fign&0FFh,ft_sto&0FFh,ft_str&0FFh,ft_num&0FFh,ft_prt&0FFh,fs_swp&0FFh,fs_and&0FFh,ft_emit&0FFh; 20h
        DB      fs_opn&0FFh,fs_cls&0FFh,fs_mul&0FFh,fs_add&0FFh,fs_cft&0FFh,fs_sub&0FFh,ft_cst&0FFh,ft_div&0FFh; 28h
        DB      fd0&0FFh,fd1&0FFh,fd2&0FFh,fd3&0FFh,fd4&0FFh,fd5&0FFh,fd6&0FFh,fd7&0FFh             ; 30h
        DB      fd8&0FFh,fd9&0FFh,fs_dup&0FFh,fs_drp&0FFh,fs_lt&0FFh,fs_eq&0FFh,fs_gt&0FFh,ft_key&0FFh; 38h
        DB      fs_fet&0FFh,fuA&0FFh,fuB&0FFh,fuC&0FFh,fuD&0FFh,fuE&0FFh,fuF&0FFh,fuG&0FFh          ; 40h
        DB      fuH&0FFh,fuI&0FFh,fuJ&0FFh,fuK&0FFh,fuL&0FFh,fuM&0FFh,fuN&0FFh,fuO&0FFh             ; 48h
        DB      fuP&0FFh,fuQ&0FFh,fuR&0FFh,fuS&0FFh,fuT&0FFh,fuU&0FFh,fuV&0FFh,fuW&0FFh             ; 50h
        DB      fuX&0FFh,fuY&0FFh,fuZ&0FFh,ft_def&0FFh,ft_brk&0FFh,fs_ret&0FFh,fs_xor&0FFh,ft_alc&0FFh; 58h
        DB      ft_grv&0FFh,fva&0FFh,fvb&0FFh,fvc&0FFh,fvd&0FFh,fve&0FFh,fvf&0FFh,fvg&0FFh          ; 60h
        DB      fvh&0FFh,fvi&0FFh,fvj&0FFh,fvk&0FFh,fvl&0FFh,fvm&0FFh,fvn&0FFh,fvo&0FFh             ; 68h
        DB      fvp&0FFh,fvq&0FFh,fvr&0FFh,fvs&0FFh,fvt&0FFh,fvu&0FFh,fvv&0FFh,fvw&0FFh             ; 70h
        DB      fvx&0FFh,fvy&0FFh,fvz&0FFh,ft_tor&0FFh,fs_or&0FFh,ft_frr&0FFh,fs_not&0FFh,fign&0FFh ; 78h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; 80h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; 88h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; 90h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; 98h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; A0h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; A8h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; B0h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; B8h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; C0h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; C8h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; D0h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; D8h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; E0h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; E8h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; F0h
        DB      fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh,fhi&0FFh             ; F8h
DTH:
        DB      fnul/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256             ; 00h
        DB      fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256             ; 08h
        DB      fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256             ; 10h
        DB      fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256             ; 18h
        DB      fign/256,ft_sto/256,ft_str/256,ft_num/256,ft_prt/256,fs_swp/256,fs_and/256,ft_emit/256; 20h
        DB      fs_opn/256,fs_cls/256,fs_mul/256,fs_add/256,fs_cft/256,fs_sub/256,ft_cst/256,ft_div/256; 28h
        DB      fd0/256,fd1/256,fd2/256,fd3/256,fd4/256,fd5/256,fd6/256,fd7/256                     ; 30h
        DB      fd8/256,fd9/256,fs_dup/256,fs_drp/256,fs_lt/256,fs_eq/256,fs_gt/256,ft_key/256      ; 38h
        DB      fs_fet/256,fuA/256,fuB/256,fuC/256,fuD/256,fuE/256,fuF/256,fuG/256                  ; 40h
        DB      fuH/256,fuI/256,fuJ/256,fuK/256,fuL/256,fuM/256,fuN/256,fuO/256                     ; 48h
        DB      fuP/256,fuQ/256,fuR/256,fuS/256,fuT/256,fuU/256,fuV/256,fuW/256                     ; 50h
        DB      fuX/256,fuY/256,fuZ/256,ft_def/256,ft_brk/256,fs_ret/256,fs_xor/256,ft_alc/256      ; 58h
        DB      ft_grv/256,fva/256,fvb/256,fvc/256,fvd/256,fve/256,fvf/256,fvg/256                  ; 60h
        DB      fvh/256,fvi/256,fvj/256,fvk/256,fvl/256,fvm/256,fvn/256,fvo/256                     ; 68h
        DB      fvp/256,fvq/256,fvr/256,fvs/256,fvt/256,fvu/256,fvv/256,fvw/256                     ; 70h
        DB      fvx/256,fvy/256,fvz/256,ft_tor/256,fs_or/256,ft_frr/256,fs_not/256,fign/256         ; 78h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; 80h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; 88h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; 90h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; 98h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; A0h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; A8h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; B0h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; B8h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; C0h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; C8h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; D0h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; D8h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; E0h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; E8h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; F0h
        DB      fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256,fhi/256                     ; F8h
        ENDIF
; ==== end of the fast build
