; =============================================================================
;  B8Script interpreter for the Motorola 6809
;  Spec: docs/b8script.md (2026-11-24).
;  Follows the design of the Z80 interpreter (z80/b8s-z80.asm).
;
;  Two switches, in the EQU lines below (CPM is always 0: the 6809 has no
;  CP/M; the line is kept only so that build.sh works):
;    CHECKED  0 = no checks (spec: an unchecked build checks nothing)
;             1 = a checked build: variables start at 0, words start
;                 undefined, and every error in the spec's table stops the
;                 program with the four-line report, then goes to EXIT:
;                   Err X @ line,col
;                   <up to 16 characters of the text at the place>
;                   Stk n: ... v v v      (n = depth, then the top 8 values)
;                   Rtn n
;                 S/s data stack over/underflow, R/r return stack over/
;                 underflow, H heap, O store outside the program's space,
;                 W bad character after [, U undefined word, Q no closing
;                 quote, X reserved byte, Z divide by zero, N unbalanced or
;                 mismatched brackets, B Ctrl-C.
;    ANSI     what the console escapes of '$' (/{ /} /| /` /~) do:
;             1 = send ANSI (VT100) sequences through CONOUT
;             0 = call the machine's own routines CONCLS, CONEOL, CONCUR and
;                 CONAT (see the equates)
;
;  In both builds Ctrl-C stops a running program (the unchecked build goes
;  to EXIT without a word): see the console layer below for the rules, the
;  held key and the break-off cell at 827Bh.
;
;  Assembler: asm80, M6809 mode.
; =============================================================================

CPM     EQU     0               ; always 0 (no CP/M on the 6809)
CHECKED EQU     0               ; 1 = checked build
ANSI    EQU     0               ; 1 = the console escapes send ANSI sequences

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
;    8000h-80FFh  return stack (S); empty = 8100h. Unchecked: 127 entries.
;                 Checked: 112 entries (S down to 8020h); the 32 bytes below
;                 are a guard band for what a handler and an interrupt push
;                 on top of a full stack before the check runs.
;    8100h-81FFh  data stack (U). Unchecked: 127 cells, empty = 8200h.
;                 Checked: 126 cells (U from 81FCh, empty, down to 8100h):
;                 the 4 bytes above are a guard band, so a handler that runs
;                 on an empty stack writes there and not on the letter
;                 cells. A push past the last cell lands on the return
;                 stack's bottom entry (80FEh), and the program stops with S
;                 before anything reads it.
;    8200h-82FFh  letter page (LET): A..Z at +00h..+33h, a..z at +40h..+73h
;                 (a word cell is always 64 bytes below its variable), the
;                 heap pointer at +7Ch (= z10+), interpreter variables in the
;                 gaps, and the -n? line buffer at +80h..+FFh. The break-off
;                 cell is at +7Bh (827Bh); +7Ah is free.
;    8300h-       PROG, the program text, NUL-terminated; the heap starts
;                 after the NUL and grows to HEAPLIM*256 (F000h)
;    F000h-       this image (ROM). The reset vector (FFFEh) must point to
;                 `start` (see the listing); the image does not contain it.
;    FF03h-FF17h  the console routines (CONOUT, KEY, and with ANSI = 0
;                 CONCLS, CONEOL, CONCUR, CONAT) and EXIT are supplied by
;                 the system and need no space here.
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
        IF      1-ANSI
; With ANSI = 0 the console escapes of '$' call these, with JSR. All four
; may change A, B, X and CC, and must keep Y, U and DP.
CONCLS  EQU     0FF0Ch          ; /{  clear the screen, the cursor to the top left
CONEOL  EQU     0FF0Fh          ; /}  clear from the cursor to the end of the line
CONCUR  EQU     0FF12h          ; /| and /`  show the cursor if A is not 0, hide
                                ;     it if A = 0
CONAT   EQU     0FF15h          ; /~  the cursor to row X, column D, both counted
                                ;     from 0
        ENDIF
RSPAGE  EQU     80h
DSPAGE  EQU     81h
LETPAGE EQU     82h
PROG    EQU     8300h           ; where the loader puts the program text
                                ; (the checked startup counts on it being
                                ; the page after LETPAGE)
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)

MSLOOP  EQU     20              ; n? inner loop count for about 1 ms; tune it
                                ; for your clock and your KEY routine

; letter-page layout (direct-page offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     7Ch             ; z10+, the heap pointer (little-endian)
KEYBUF  EQU     34h             ; gap after Z: a key held back by the break check
COUNT   EQU     35h             ; the break check's countdown (1 look in 256)
AT      EQU     36h             ; checked: the address of the character being
                                ;   run (big-endian), the place an error reports
PEND    EQU     38h             ; checked: the program's end, the first byte
                                ;   after its NUL (big-endian): the heap's floor
SSAV    EQU     3Ah             ; checked: S as each character starts (big-
                                ;   endian): the return stack an error reports
PSAV    EQU     3Ch             ; checked: the address '$' prints from (big-
                                ;   endian), put back on the stack for a Q
BRKOFF  EQU     7Bh             ; the break-off cell (827Bh, z9+): 0 = the
                                ;   break key is on
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSTOP   EQU     RSPAGE*256+100h ; empty return stack
RSLIM   EQU     RSPAGE*256+20h  ; checked: S may go no lower between characters
RSREP   EQU     RSTOP-16        ; checked: S while the error report runs
DSTOP   EQU     DSPAGE*256+100h-4*CHECKED ; empty data stack (a guard if checked)
DSLIM   EQU     DSPAGE*256      ; checked: U may go no lower between characters

        ORG     0F000h


; =============================================================================
;  Startup
; =============================================================================
start:  LDS     #RSTOP
        LDU     #DSTOP
        LDA     #LETPAGE
        TFR     A,DP
        IF      CHECKED
        ; Zero the whole letter page: every variable starts at 0, every word
        ; cell at 0 (undefined: a call stops with U), and so do the
        ; interpreter's own cells in the gaps (KEYBUF and the rest). A is
        ; still LETPAGE; 256 rounds leave X at the next page, PROG.
        CLRB
        TFR     D,X
sz:     CLR     ,X+
        DECB
        BNE     sz
        ENDIF
        LDY     #PROG           ; the reading position
        IF      1-CHECKED
        CLR     <KEYBUF         ; no key held
        CLR     <BRKOFF         ; the break key is on
        TFR     Y,X             ; the heap starts after the program's NUL
        ENDIF
sc:     LDA     ,X+
        BNE     sc
        TFR     X,D
        STB     <HEAP           ; (little-endian)
        STA     <HEAP+1
        IF      CHECKED
        STX     <PEND           ; the heap may never go below this
        ENDIF

; =============================================================================
;  The inner loop: read one character and sort it by range.
;
;    00h          end of program
;    01h-20h, 7Fh       ignored (control, space, DEL)
;    80h-FFh      reserved: ignored, or X in the checked build
;    30h-39h      digit: read a whole number
;    41h-5Ah      A-Z: call the word in that letter's cell
;    61h-7Ah      a-z: push the address of that letter's cell
;    the rest     punctuation: JSR through PTAB, 32 entries, in code order
; =============================================================================
next:
        IF      CHECKED
        ; Both stacks are checked once per character, not in every handler:
        ; the pointer minus its limit, taken as unsigned, must be no more
        ; than the stack's size. Below the limit (an overflow) it wraps to
        ; FFxxh, and the compare leaves N set; above the empty point (an
        ; underflow) it is just over the size, and N is clear.
        LEAX    (0-DSLIM)&0FFFFh,U
        CMPX    #DSTOP-DSLIM
        BHI     e_ds
        LEAX    (0-RSLIM)&0FFFFh,S
        CMPX    #RSTOP-RSLIM
        BHI     e_rs
        STY     <AT             ; the place, should this character fail
        STS     <SSAV           ; and the return stack, as it is now
        ENDIF
        LDA     ,Y+
        BEQ     fin             ; NUL ends the program
        SUBA    #21h            ; A = c - 21h
        BLO     next            ; 01h-20h ignored
        CMPA    #0Fh
        BLO     punct           ; 21h-2Fh: PTAB index 0-14
        CMPA    #19h
        BLO     digit           ; 30h-39h
        CMPA    #20h
        BLO     p3a             ; 3Ah-40h: A = 19h-1Fh
        SUBA    #20h            ; A = c - 41h
        CMPA    #1Ah
        BLO     upper           ; 41h-5Ah: A = letter index 0-25
        CMPA    #20h
        BLO     p5b             ; 5Bh-60h
        CMPA    #3Ah
        BLO     lower           ; 61h-7Ah: A = 20h-39h (cell +64 bytes)
        CMPA    #3Eh
        IF      1-CHECKED
        BHS     next            ; 7Fh-FFh: ignored
        ENDIF
        IF      CHECKED
        BEQ     next            ; 7Fh (DEL): ignored
        BHI     e_resv          ; 80h-FFh: reserved
        ENDIF
        SUBA    #1Ah            ; 7Bh-7Eh: -1Eh in all, index 28-31
p5b:    ADDA    #6              ; 5Bh-60h: -4 in all, index 22-27
p3a:    SUBA    #0Ah            ; 3Ah-40h: index 15-21
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
; Checked: a cell still 0 (high byte 0) was never defined, since every
; address in the program's space is 8200h or more. The call has not been
; made yet, so the report shows the stacks as they were.
upper:  BSR     cellx
        LDB     ,X
        LDA     1,X
        IF      CHECKED
        BEQ     e_undef
        ENDIF
        PSHS    Y
        TFR     D,Y
        BSR     pollk           ; the break check, at every word call
        BRA     next

; =============================================================================
;  Checked build: the error entries.
;
;  Each entry loads its letter and then hides the next entry inside a 3-byte
;  CMPX # (the 8Ch), so that a run of them falls through to one place. The
;  place an error reports is the address in AT, which the inner loop sets to
;  each character before it runs it; the one error that reports another
;  place (W, at the character after the [) changes AT before it comes.
;
;  The report counts the return stack from SSAV, which the inner loop sets
;  to S before each character, so an error may come from any depth of
;  calls: a handler, chkst under one, or ctlc under '?' or the break check.
;  (An r sets SSAV to the empty stack.) The inner loop's own entries are
;  here, where its short branches reach them; those reached from a handler
;  are after h_cstore, just ahead of the report.
; =============================================================================
        IF      CHECKED
; ---- reached from the inner loop -------------------------------------------
; The stack checks branch here with N set for an overflow (the pointer is
; below its limit) and clear for an underflow. After an underflow that stack
; counts as empty.
e_ds:   BMI     e_S
        LDU     #DSTOP          ; s
        LDA     #'s'
        BRA     eall
e_rs:   BMI     e_R
        LDX     #RSTOP          ; r
        STX     <SSAV
        LDA     #'r'
        FCB     8Ch
e_S:    LDA     #'S'
        FCB     8Ch
e_R:    LDA     #'R'
        FCB     8Ch
e_resv: LDA     #'X'            ; a reserved byte (80h-FFh) outside a string
        FCB     8Ch
e_break:LDA     #'B'            ; Ctrl-C (from ctlc, at any depth)
        FCB     8Ch
e_undef:LDA     #'U'            ; a word never defined (its cell is still 0)
eall:   JMP     error
        ENDIF

fin:    JMP     EXIT            ; the program has ended

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
;  Console layer: the break key. A running program reads the keyboard only
;  through pollk and getk, which between them give the break key its rules:
;    - Ctrl-C (03h) stops the program;
;    - any other key that the break check reads is held in KEYBUF for the
;      next '?', and a newer one takes its place;
;    - '?' (getk) takes the held key first;
;    - a program that has stored a non-zero byte at BRKOFF gets Ctrl-C as a
;      key like any other, but two of them within about 250 ms still stop it.
;  On a break the unchecked build ends without a word (EXIT); the checked
;  one reports B. All three keep B, X, Y and U.
; =============================================================================
; pollk: the break check, at every word call and every true ')' loop-back.
; It looks at the keyboard only once in 256 calls.
pollk:  DEC     <COUNT
        BNE     cc9
        JSR     KEY
        BEQ     cc9             ; no key
        STA     <KEYBUF         ; held for the next '?'
        BRA     ctlc

; getk: a key for '?', or A = 0 with the zero flag set if there is none.
getk:   LDA     <KEYBUF         ; a held key goes first, and is taken out of
        CLR     <KEYBUF         ;   the buffer (it has been through ctlc)
        TSTA
        BNE     cc9
        JSR     KEY
        BEQ     cc9
; ctlc: a key has been read. If it is Ctrl-C and the break key is on, that
; is the end. If the program has turned it off, wait about 250 ms for one
; more key: a second Ctrl-C is the end too; any other key is held (the
; newest wins), and the Ctrl-C goes on: A = 3, zero flag clear.
ctlc:   CMPA    #3
        BNE     cc9
        TST     <BRKOFF
        BEQ     brk
        PSHS    X
        LDX     #250*MSLOOP
cc1:    JSR     KEY
        BNE     cc2
        LEAX    -1,X
        BNE     cc1
        BRA     cc3
cc2:    CMPA    #3
        BEQ     brk
        STA     <KEYBUF
cc3:    LDA     #3
        PULS    X
cc9:    RTS
        IF      1-CHECKED
brk     EQU     fin             ; the unchecked build stops without a word;
        ENDIF
        IF      CHECKED
brk     EQU     e_break         ;   the checked build reports B (the report
        ENDIF                   ;   takes S from SSAV, so the depth of the
                                ;   calls here doesn't matter)



; hexc: if the character at IP is a hex digit (0-9, A-F, a-f), step over it
; and return its value in A with the carry set; otherwise leave the IP and
; return with the carry clear.
; (In the unchecked build it is here, ahead of the table, to leave room in
; the two ranges after it; the checked build has it next to the grave.)
        IF      1-CHECKED
hexc:   BSR     isdig
        BLO     hv1             ; C = 1
        ANDA    #0DFh
        SUBA    #11h
        CMPA    #6
        BHS     hv9             ; C = 0
        SUBA    #0F6h           ; + 10, and sets the carry
hv1:    LEAY    1,Y             ; (LEAY leaves the carry alone)
hv9:    RTS
        ENDIF

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

; '}' ( -- n ) R: ( n -- )    The dispatcher's return address comes off
; into D and the entry under it into X; D is then jumped to.
h_fromr:PULS    D,X
        PSHU    X
        TFR     D,PC

; '_' ( n -- addr ): the heap pointer moves by n (signed: a 16-bit add);
; TOS is the old pointer.
; Checked: the new top must be at least the program's end (PEND) and below
; the limit page. That also catches an add that wraps: the top is always
; 8301h-EFFFh and n is -32768..32767, so a sum that carries past FFFFh
; lands below 7000h, and one that borrows can't happen.
h_alloc:LDB     <HEAP
        LDA     <HEAP+1
        TFR     D,X             ; the old pointer
        ADDD    ,U
        IF      CHECKED
        CMPD    <PEND
        BLO     ah9             ; below the program's end
        CMPA    #HEAPLIM
        BLO     ah1             ; the new top must stay below the limit page
ah9:    LDA     #'H'
        BRA     ejmp            ; (with [ below)
ah1:
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
; Neither the loader's stores nor the code are checked, in either build.
h_grave:BSR     hexc            ; the digit after the grave, if any
        BCC     exec
        LDX     ,U
hx1:    LDB     #16
        MUL                     ; B = the digit, moved up to the high half
        STB     ,X              ; (an odd digit is overwritten by the RTS)
        BSR     hexc
        BCC     hx2             ; odd digit: already consumed, dropped
        ORA     ,X
        STA     ,X+
        BSR     hexc
        BCS     hx1
hx2:    LDA     #39h            ; RTS
        STA     ,X
        STX     ,U
        RTS
exec:   PULU    PC              ; jump to it: the code's RTS returns to the
                                ;   dispatcher

        IF      CHECKED
hexc:   JSR     isdig
        BLO     hv1             ; C = 1
        ANDA    #0DFh
        SUBA    #11h
        CMPA    #6
        BHS     hv9             ; C = 0
        SUBA    #0F6h           ; + 10, and sets the carry
hv1:    LEAY    1,Y             ; (LEAY leaves the carry alone)
hv9:    RTS
        ENDIF

; ---- where the two ranges meet ---------------------------------------------
; The first range ends somewhere among the next five handlers, ] \ [ @ ?
; (they are in falling code order for this): NPG1 follows. Every handler
; below them must start in the second range, and every one above in the
; first.

; ']' returns: pop an address and jump to it. (PULS X,Y: the dispatcher's
; return address into X, then the saved IP into Y.)
h_ret:  PULS    X,Y
        JMP     ,X

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
h_break:LDD     ,U++
        BEQ     sk9             ; false: nothing to do
        BSR     skip
        TSTA                    ; skip returns 0 for ')'
        IF      CHECKED
        LBMI    fin             ; (and FFh for the NUL: the program ends)
        ENDIF
        BNE     h_ret
rdrop:  PULS    D,X             ; the return address and the block start
        TFR     D,PC            ; back to the dispatcher

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything that is not a letter as the space; the
; checked build stops on it.)
        IF      CHECKED
def1:   CMPA    #' '-'A'+256
        BEQ     def2
        LEAY    -1,Y            ; anything but a letter or a space: W. The
        STY     <AT             ;   place is that character, just read
        LDA     #'W'
ejmp:   JMP     error           ; (H and N come here too)
        ENDIF
h_def:  LDA     ,Y+
        SUBA    #'A'            ; a letter gives 0-25 or 32-57: lowercase
        TFR     A,B             ;   lands 64 bytes up
        ANDB    #0DFh           ; fold case
        CMPB    #26
        IF      1-CHECKED
        BHS     def2            ; not a letter
        ENDIF
        IF      CHECKED
        BHS     def1
        ENDIF
        JSR     cellx
        TFR     Y,D
        STB     ,X              ; little-endian
        STA     1,X
        FCB     8Ch             ; (CMPX #: steps over the PSHU)
def2:   PSHU    Y               ; an anonymous block: push its address
        IF      1-CHECKED
        ; fall into skip
        ENDIF
        IF      CHECKED
        ; Checked: the skip must end at a ']' (A = 2), or for a false '(',
        ; which comes to opf, at a ')' (A = 0). Anything else stops with N.
        BSR     skip
        SUBA    #2
        FCB     8Ch             ; (CMPX #: steps over the BSR)
opf:    BSR     skip
        TSTA
        BEQ     sk9             ; (an RTS)
        LDA     #'N'
        BRA     ejmp
        ENDIF

; skip: read past text to the closer at this level, and return A = 0 if it
; was ')' and 2 if it was ']'. Brackets of both kinds count together;
; strings are stepped over whole. B counts the open levels.
; Unchecked: a NUL first ends the program (for '\' with no closer; anything
; else that runs into the NUL had unbalanced brackets anyway).
; Checked: a NUL, or a string that runs into it, returns A = FFh, and the
; caller decides: '\' ends the program, '(' and '[' stop with N, as they do
; for a closer of the other kind. The place is the opener, still in AT.
skip:   CLRB
sk1:    LDA     ,Y+
        IF      1-CHECKED
        LBEQ    fin
        ENDIF
        IF      CHECKED
        BEQ     ssn             ; A = FFh
        ENDIF
        CMPA    #22h
        BNE     sk2
        BSR     skipstr         ; leaves A = 22h, which matches nothing below
        IF      CHECKED
        BCS     sk9             ; (or FFh, with the carry set: unclosed)
        ENDIF
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

; 22h, checked build (the unchecked one is with the handlers below).
; Checked: a NUL ends the string too, even right after a '/'; skipstr then
; returns A = FFh with the carry set (the carry is clear at the quote), and
; '"' stops with Q, the string's address already pushed. (skip comes here
; for its own NUL as well.)
        IF      CHECKED
h_str:  PSHU    Y
        BSR     skipstr
        LBCS    e_quote
        RTS
ss0:    LDA     ,Y+             ; the character after the '/'
        BEQ     ssn
skipstr:LDA     ,Y+
        BEQ     ssn
        CMPA    #'/'
        BEQ     ss0
        CMPA    #22h
        BNE     skipstr
        RTS                     ; the quote: C = 0
ssn:    SUBA    #1              ; the NUL: A = FFh, C = 1
        RTS
        ENDIF

h_fetch:LDX     ,U              ; '@' (the cell in memory is little-endian)
        LDA     1,X
        BRA     cf1

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. The buffer
;          holds 127 characters and the CR: a bigger count is taken as 127.
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
line:   CMPX    #-127           ; (X = TOS, minus the count)
        BHS     ln1
        LDA     #-127           ; more than 127 is taken as 127
        STA     1,U
ln1:    NEG     1,U
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
        IF      1-CHECKED
        BEQ     skip            ; tail call: skip ends in RTS
        ENDIF
        IF      CHECKED
        LBEQ    opf             ; checked: skip, and check the closer
        ENDIF
        PULS    X
        PSHS    Y
        JMP     ,X

; 22h pushes the address of the text after it and skips the string.
; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it. Leaves A = 22h. (The checked
; build's is after skip.)
        IF      1-CHECKED
h_str:  PSHU    Y
        FCB     8Ch             ; (CMPX #: steps over the LEAY)
ss0:    LEAY    1,Y
skipstr:LDA     ,Y+
        CMPA    #'/'
        BEQ     ss0
        CMPA    #22h
        BNE     skipstr
        RTS
        ENDIF

h_cfetch:LDX    ,U              ; ','
        CLRA
cf1:    LDB     ,X
        STD     ,U
        RTS

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on.
h_close:LDD     ,U++
        LBEQ    rdrop
        LDY     2,S             ; the block start, under the return address
        JMP     pollk           ; the break check, at every loop-back

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

; ---- stack, and printing ----------------------------------------------------

h_swap: PULU    D,X             ; '%'
        PSHU    D
        PSHU    X
        RTS

h_dup:  LDD     ,U              ; ':'
        PSHU    D
        RTS

h_emit: LDA     1,U             ; "'"
        IF      1-CHECKED
        BSR     putc
        ENDIF
        IF      CHECKED
        JSR     CONOUT          ; (the checked build's report is in the way)
        ENDIF
h_drop: LEAU    2,U             ; ';'
        RTS

; '!' ( n addr -- ) is '.' with the high byte stored first. The cell in
; memory is little-endian.
; Checked: both bytes must be in the program's space, and they are tested
; before either is stored (chkst stops with O, the stack untouched).
h_store:LDX     ,U
        IF      1-CHECKED
        LDA     2,U
        STA     1,X
        ENDIF
        IF      CHECKED
        BSR     chkst
        LEAX    1,X
        BSR     chkst
        LDA     2,U
        STA     ,X
        ; and fall into '.', which loads X again (and checks it again)
        ENDIF
        IF      1-CHECKED
        FCB     8Ch             ; (CMPX #: steps over the LDX)
        ENDIF
h_cstore:LDX    ,U              ; '.' ( c addr -- )
        IF      CHECKED
        BSR     chkst
        ENDIF
        LEAU    2,U
        PULU    D
        STB     ,X
        RTS

        IF      CHECKED
; ---- reached from a handler ------------------------------------------------
; chkst: stop with O unless X is in the program's own space: from the letter
; page up to HEAPLIM, so the interpreter's stacks and whatever lies above the
; limit are safe. Memory above the heap top but below the limit is the
; program's own: Tiny BASIC keeps its lines there. Keeps every register.
chkst:  CMPX    #LET
        BLO     cs9
        CMPX    #HEAPLIM*256
        BHS     cs9
        RTS                     ; in range
cs9:    LDA     #'O'
        FCB     8Ch
e_zero: LDA     #'Z'            ; / by zero
        FCB     8Ch
e_quote:LDA     #'Q'            ; " or $ ran into the NUL
        ; and fall into error. (H, W and N have their own entries, near
        ; their handlers, at ejmp.)

; =============================================================================
;  Checked build: the error report. A = the letter, AT = the place; U is
;  as the program left it, and SSAV holds S as the failing character began
;  (see "the error entries" after `upper`).
;  It sits here, ahead of h_num, pdec and putc, so that it reaches them with
;  short calls. Prints
;
;     CR LF
;     Err X @ line,col CR LF
;     <up to 16 raw characters from the place, ending early at CR, LF, NUL>
;     CR LF
;     Stk n:[ ...][ v]*  CR LF     (the top 8 cells, bottom to top, signed)
;     Rtn n CR LF
;
;  and goes to EXIT. Line and column count from 1: the line is one more
;  than the LFs between PROG and the place, the column the distance from the
;  last LF (or from PROG-1). A place below PROG is in the -n? line buffer:
;  line 0, column = its offset there + 1. Numbers other than the cells are
;  printed unsigned (pdec), the cells signed (h_num).
;
;  The data stack may be one cell past its limit (S, U = 80FEh): the
;  report's own cells then reach 8 bytes further down, to 80F6h, into the
;  return stack page, so the report runs on a fresh return stack at RSREP
;  (80F0h), below those bytes.
; =============================================================================
error:  LDS     #RSREP
        TFR     A,B             ; the letter (pmsg and CONOUT keep B)
        BSR     pmsg
        FCB     13,10,"Err",' '+80h
        TFR     B,A
        JSR     CONOUT
        BSR     pmsg
        FCB     " @",' '+80h
        ; the place: Y counts the lines, X walks, the cell at ,U holds the
        ; address of the last LF (PROG-1 to begin with)
        LDY     #0
        LDX     #LINEBUF-1
        PSHU    X
        LDX     #PROG-1
        CMPX    <AT
        BHS     lc3             ; the place is below PROG: line 0
        STX     ,U
lc1:    LEAY    1,Y             ; a line
lc2:    LEAX    1,X
        CMPX    <AT
        BHS     lc3
        LDA     ,X
        CMPA    #10
        BNE     lc2
        STX     ,U
        BRA     lc1

; pmsg: print the text after the call, up to and including the character
; that has bit 7 set (it is printed without it), then return after it.
; (It sits here, in the middle of the report, where all its calls reach.)
pmsg:   PULS    X
pm1:    LDA     ,X
        ANDA    #7Fh
        JSR     putc
        TST     ,X+
        BPL     pm1
        JMP     ,X

lc3:    LDD     <AT
        SUBD    ,U
        STD     ,U              ; the column
        PSHU    Y
        JSR     pdec            ; the line
        BSR     pmsg
        FCB     ','+80h
        BSR     pdec            ; the column
        BSR     pmsg
        FCB     13,10+80h
        ; the text at the place
        LDX     <AT
        LDB     #16
tx1:    LDA     ,X+
        BEQ     tx9
        CMPA    #10
        BEQ     tx9
        CMPA    #13
        BEQ     tx9
        BSR     putc
        DECB
        BNE     tx1
tx9:    BSR     pmsg
        FCB     13,10,"Stk",' '+80h
        ; the data stack: its depth, then its top 8 cells, from Y down to
        ; the program's top cell, at ,U.
        PSHS    U               ; where the walk ends
        LDD     #DSTOP
        SUBD    ,S
        BSR     pdh             ; the depth (pdec leaves U as it was)
        BSR     pmsg
        FCB     ':'+80h
        LEAY    16,U            ; past the 8th cell from the top ...
        CMPY    #DSTOP
        BHS     sl1
        BSR     pmsg            ; (there are more than 8)
        FCB     " ..",'.'+80h
        BRA     sl2
sl1:    LDY     #DSTOP          ; ... or the whole stack, if no more than 8
sl2:    CMPY    ,S
        BLS     sl9
        LDD     ,--Y
        PSHU    D
        BSR     pmsg
        FCB     ' '+80h
        BSR     h_num
        BRA     sl2
sl9:    BSR     pmsg
        FCB     13,10,"Rtn",' '+80h
        LDD     #RSTOP          ; the return stack's depth, (RSTOP - S) / 2,
        SUBD    <SSAV           ;   S as it was when this character began
        BSR     pdh
        JSR     pmsg
        FCB     13,10+80h
        JMP     EXIT

; pdh: print D/2 (a depth: D is twice it), unsigned.
pdh:    LSRA
        RORB
        PSHU    D
        BRA     pdec
        ENDIF

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
        BSR     pdec            ; (it drops the quotient)
        FCB     8Ch             ; (CMPX #: steps over the LEAU)
pd1:    LEAU    2,U             ; drop the zero quotient
        PULS    A
        ADDA    #'0'            ; and fall into putc

putc:   JMP     CONOUT

; ---- more arithmetic ---------------------------------------------------------

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

; '$' prints the string at TOS, decoding escapes: '/' plus a character from
; 60h to 7Eh is one of the escapes at pesc; '/' plus any other character
; clears that character's bit 6 (/M is CR, /? is DEL's '?'; '/' and '"' have
; no bit 6, so // and /" give themselves). The address comes off the stack
; first, and Y walks the string (the IP waits on S), so that /~ finds its
; row and column on top, and an escape may use A, B, X and the routines.
; Checked: a NUL (not one escaped by '/') stops with Q, the string's
; address put back on the stack (from PSAV) over what any /~ left.
; (The loop is with the tail, past the second range.)
h_print:PSHS    Y
        PULU    Y
        IF      CHECKED
        STY     <PSAV
        ENDIF
        BRA     pr0

; ---- the tail ---------------------------------------------------------------
; '/' is the last handler, so what follows its first byte may lie past the
; second range: the divide itself and the routines after it.

; '/' ( a b -- q r ): the remainder is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Unchecked, dividing by zero returns two cells of no meaning; checked,
; it stops with Z, both operands still on the stack.
h_div:
        IF      CHECKED
        LDD     ,U
        LBEQ    e_zero
        ENDIF
        LDA     2,U
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
; Dividing by 2 is one shift (the spec wants that fast).
udiv:   LDD     ,U
        SUBD    #2
        BNE     ud0
        LSR     2,U
        ROR     3,U             ; the quotient
        ROLB                    ; the remainder: the bit that fell out (D was 0)
        BRA     ud3
ud0:    LDX     #16
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
ud3:    STD     ,U
        RTS

; The loop of '$' (see h_print).
pr0:    LDA     ,Y+
        IF      CHECKED
        BEQ     prq
        ENDIF
        CMPA    #22h
        BEQ     pr9
        CMPA    #'/'
        BNE     pr1
        LDA     ,Y+
        SUBA    #60h            ; ` 0, a-z 1-26, { 27, | 28, } 29, ~ 30
        CMPA    #1Fh
        BHS     pr2
        BSR     pesc
        BRA     pr0
pr2:    ADDA    #60h            ; any other: bit 6 goes
        ANDA    #0BFh
pr1:    JSR     CONOUT
        BRA     pr0
pr9:    PULS    Y,PC
        IF      CHECKED
prq:    LDX     <PSAV
        PSHU    X
        JMP     e_quote
        ENDIF

; pesc: the escapes of '$'. A = the character after the '/', minus 60h
; (0 to 30); Y points past it. Each returns to the loop with an RTS, its
; own or that of the routine it ends by jumping to. A, B and X are free.
;    /a-/z   print the variable, as '#' does
;    /{      clear the screen, the cursor to the top left
;    /}      clear from the cursor to the end of the line
;    /|  /`  show the cursor, hide it
;    /~      ( row col -- ) the cursor to that row and column, from 0
pesc:   CMPA    #27
        BHS     pcon
        ASLA                    ; (` leaves A = 0: hide)
        BEQ     phide
        LDX     #LET+40h-2      ; the variable's cell (little-endian)
        LDD     A,X
        EXG     A,B
        PSHU    D
        JMP     h_num
        IF      1-ANSI
pcon:   LBEQ    CONCLS          ; /{
        CMPA    #29
        LBEQ    CONEOL          ; /}
        BHI     pat
phide:  JMP     CONCUR          ; /|  (A = 28: show), /`  (A = 0: hide)
        ENDIF
pat:
        IF      CHECKED
        ; /~ checks first that there are a row and a column (with less it
        ; is s, and the stack counts as empty): U is never let past the
        ; top of the stack, however many /~ there are.
        CMPU    #DSTOP-4
        LBHI    e_ds            ; (N is clear: an underflow)
        ENDIF
        IF      1-ANSI
        PULU    D,X             ; /~  D = the column, X = the row
        JMP     CONAT
        ENDIF
        IF      ANSI
; /~  ESC [ row+1 ; col+1 H (ANSI counts from 1)
        PULU    D,X             ; D = the column, X = the row
        ADDD    #1
        LEAX    1,X
        PSHU    D
        PSHU    X
        BSR     csi
        JSR     pdec
        BSR     pm
        FCB     ';'+80h
        JSR     pdec
        BSR     pm
        FCB     'H'+80h
        RTS
pcon:   BEQ     pcls            ; /{
        CMPA    #29
        BEQ     peol            ; /}
        BHI     pat
        BSR     pcsi            ; /|  ESC [ ? 2 5 h
        FCB     "?25",'h'+80h
        RTS
phide:  BSR     pcsi            ; /`  ESC [ ? 2 5 l
        FCB     "?25",'l'+80h
        RTS
pcls:   BSR     pcsi            ; /{  ESC [ H ESC [ J
        FCB     'H'+80h
        BSR     pcsi
        FCB     'J'+80h
        RTS
peol:   BSR     pcsi            ; /}  ESC [ K
        FCB     'K'+80h
        RTS
; pcsi: ESC [ and then the text after the call, as pmsg. csi: ESC [.
csi:    BSR     pm
        FCB     27,'['+80h
        RTS
pcsi:   BSR     csi
        ENDIF
        IF      ANSI*(1-CHECKED)
; pmsg: print the text after the call, up to and including the character
; that has bit 7 set (it is printed without it), then return after it.
; (The checked build has its own, with the report: pm leads to it.)
pm:
pmsg:   PULS    X
pm1:    LDA     ,X
        ANDA    #7Fh
        JSR     CONOUT
        TST     ,X+
        BPL     pm1
        JMP     ,X
        ENDIF
        IF      ANSI*CHECKED
pm:     JMP     pmsg
        ENDIF

imgend:
