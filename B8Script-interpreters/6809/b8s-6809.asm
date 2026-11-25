; =============================================================================
;  B8Script interpreter for the Motorola 6809
;  Required Notice: Copyright 2026 Robb Bates (https://github.com/robbbates)
;  Licence: PolyForm Noncommercial License 1.0.0 (LICENSE.md at the top of
;  the repository, or https://polyformproject.org/licenses/noncommercial/1.0.0)
;  Spec: docs/b8script.md (2026-11-24).
;  Follows the design of the Z80 interpreter (z80/b8s-z80.asm).
;
;  The switches, in the EQU lines below (CPM is always 0: the 6809 has no
;  CP/M; the line is kept only so that build.sh works):
;    CHECKED  0 = no checks (spec: an unchecked build checks nothing)
;             1 = a checked build: variables start at 0, words start
;                 undefined, and every error in the spec's table stops the
;                 program with the three-line report, then goes to EXIT:
;                   Err X @ line,col
;                   D:n: ... v v v      (n = depth, then the top 8 values)
;                   R:n
;                 S/s data stack over/underflow, R/r return stack over/
;                 underflow, H heap, O store outside the program's space,
;                 W bad character after [, U undefined word, Q no closing
;                 quote, X reserved byte, Z divide by zero, N unbalanced or
;                 mismatched brackets, B Ctrl-C.
;    ANSI     what the console escapes of '$' (/{ /} /| /` /~) do:
;             1 = send ANSI (VT100) sequences through CONOUT
;             0 = call the machine's own routines CONCLS, CONEOL, CONCUR and
;                 CONAT (see the equates)
;    SPEED    0 = small: the smallest build
;             1 = base, the default: the speed-ups that cost few bytes: a
;                 skip cache, a faster skip, '*' quicker when a high byte is
;                 0, '/' by any power of two as a shift, and (unchecked) a
;                 variable and its '@' or '!' in one step. See "Speed-ups".
;                 The heap limit is a page lower (EF00h): the skip cache has
;                 the page above it.
;             2 = fast: base, and a dispatch table besides, with
;                 no size limit. See "The fast build". The image starts at
;                 E000h, the heap limit is DF00h and the skip cache is at
;                 DF00h-DFFFh.
;
;  In every build Ctrl-C stops a running program (the unchecked build goes
;  to EXIT without a word): see the console layer below for the rules, the
;  held key and the break-off cell at 827Bh.
;
;  Assembler: asm80, M6809 mode.
; =============================================================================

CPM     EQU     0               ; always 0 (no CP/M on the 6809)
CHECKED EQU     0               ; 1 = checked build
ANSI    EQU     0               ; 1 = the console escapes send ANSI sequences
SPEED   EQU     1               ; 0 = small, 1 = base, 2 = fast (see "Speed-ups")
FAST    EQU     SPEED/2         ; (1: the fast build)
SBASE   EQU     SPEED-FAST*2    ; (1: the base build)
QK      EQU     SBASE+FAST-SBASE*FAST ; (the speed-ups: base, or the fast build)
SBASEU  EQU     QK*(1-CHECKED)*(1-FAST) ; (and those that only the unchecked
                                ;  base build takes; the fast build has its own)
                                ; (asm80 can't nest IF, and IF takes any value
                                ;  but 0 as true, so IF CHECKED+QK means "either")

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
;  table holds whole addresses instead. (The fast build has neither: its
;  table, FTAB, has an address for every byte. See "The fast build".)
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
;  Memory map. Everything the interpreter writes is in four RAM areas:
;
;    8000h-80FFh  return stack (S); empty = 8100h. Unchecked: 127 entries.
;                 Checked: 96 entries (S down to 8040h); the 64 bytes below
;                 are a guard band for what a handler, the console routines
;                 and interrupts push on top of a full stack before the check
;                 runs (the escapes of '$' take up to 22 of them, so 42 are
;                 left for CONOUT and interrupts).
;    8100h-81FFh  data stack (U). Unchecked: 127 cells, empty = 8200h.
;                 Checked: 125 cells (U from 81FCh, empty, down to 8102h):
;                 the 4 bytes above are a guard band, so a handler that runs
;                 on an empty stack writes there and not on the letter
;                 cells. A push past the last cell lands on 8100h, still in
;                 this page, and the program stops with S. (It must not
;                 reach 80FEh: with the return stack empty, the handler's
;                 own return address is there. pdec's cell for its divisor,
;                 under '#' or a /a in '$' on a full stack, lands on 8100h
;                 too.)
;    8200h-82FFh  letter page (LET): A..Z at +00h..+33h, a..z at +40h..+73h
;                 (a word cell is always 64 bytes below its variable), the
;                 heap pointer at +7Ch (= z10+), interpreter variables in the
;                 gaps, and the -n? line buffer at +80h..+FFh. The break-off
;                 cell is at +7Bh (827Bh); +7Ah is free.
;    8300h-       PROG, the program text, NUL-terminated; the heap starts
;                 after the NUL and grows to HEAPLIM*256 (F000h; EF00h
;                 with base, DF00h in the fast build)
;    EF00h-EFFFh  base: the skip cache (CPAGE), the page at the heap limit,
;                 which the heap never reaches. (Fast build: DF00h-DFFFh.)
;    F000h-       this image (ROM). The reset vector (FFFEh) must point to
;                 `start` (see the listing); the image does not contain it.
;                 (The fast build's image starts at E000h.)
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
; With ANSI = 0 the console escapes of '$' call these as subroutines (each
; ends with RTS). All four may change A, B, X and CC, and must keep Y, U
; and DP.
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
ROM     EQU     0F000h-FAST*1000h ; where the image starts (the fast build: E000h)
HEAPLIM EQU     ROM/256-QK      ; the heap must stay below F000h (a page);
                                ;   with base EF00h, the fast build DF00h
CPAGE   EQU     HEAPLIM         ; the skip cache's page (base and the fast
                                ;   build): the page at the heap limit

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
RSLIM   EQU     RSPAGE*256+40h  ; checked: S may go no lower between characters
RSREP   EQU     RSTOP-16        ; checked: S while the error report runs
DSTOP   EQU     DSPAGE*256+100h-4*CHECKED ; empty data stack (a guard if checked)
DSLIM   EQU     DSPAGE*256+2    ; checked: U may go no lower between characters

; The fast build's dispatcher, inline at the end of each of its own entries
; (see "The fast build", at the end). The checked one calls fchk first.
; (A count of 0 makes DS write nothing; DS needs fchk's address before the
; first use, so fchk comes first in that part.)
        IF      FAST*CHECKED
ACHK    EQU     fchk
        ENDIF
        IF      1-FAST*CHECKED
ACHK    EQU     0
        ENDIF
        .macro  NEXTF
        DS      CHECKED,0BDh    ; (checked: JSR fchk)
        DS      CHECKED,ACHK/256
        DS      CHECKED,ACHK&0FFh
        LDB     ,Y+             ; the character,
        LDX     #FTAB
        ABX
        ABX                     ;   its entry in the table,
        JMP     [,X]            ;   and its handler
        .endm

        ORG     ROM


; =============================================================================
;  Startup
; =============================================================================
start:  LDS     #RSTOP
        LDU     #DSTOP
        IF      QK
        ; Empty the skip cache: a start of 0000h matches no skip.
        LDX     #CPAGE*256
        CLRB
skz:    CLR     ,X+
        DECB
        BNE     skz
        ENDIF
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
        IF      1-CHECKED
        CLR     <KEYBUF         ; no key held
        CLR     <BRKOFF         ; the break key is on
        LDX     #PROG
        ENDIF
        TFR     X,Y             ; the reading position; the heap starts
sc:     LDA     ,X+             ;   after the program's NUL
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
        IF      FAST
        JMP     fnext           ; (the fast build has its own: see the end)
        ENDIF
        IF      1-FAST
next:
        ENDIF
        IF      CHECKED*(1-FAST)
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
        IF      1-FAST
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
        ENDIF
        IF      (1-CHECKED)*(1-FAST)
        BHS     next            ; 7Fh-FFh: ignored
        ENDIF
        IF      CHECKED*(1-FAST)
        BEQ     next            ; 7Fh (DEL): ignored
        BHI     e_resv          ; 80h-FFh: reserved
        ENDIF
        IF      1-FAST
        SUBA    #1Ah            ; 7Bh-7Eh: -1Eh in all, index 28-31
p5b:    ADDA    #6              ; 5Bh-60h: -4 in all, index 22-27
p3a:    SUBA    #0Ah            ; 3Ah-40h: index 15-21
; Punctuation: A = the PTAB index.
punct:  LDX     #PTAB
        ENDIF
        IF      (1-CHECKED)*(1-FAST)
        ; The handler is at PTAB + D, where B is the table byte and A is 1
        ; for the first NPG1 characters, 0 for the rest.
        LDB     A,X
        CMPA    #NPG1           ; carry: one of the first NPG1
        LDA     #0              ; (leaves the carry alone)
        ROLA
        JSR     D,X             ; the handler ends in RTS
        ENDIF
        IF      CHECKED*(1-FAST)
        ASLA                    ; the table holds whole addresses
        JSR     [A,X]
        ENDIF
        IF      1-FAST
        BRA     next

; Digits: step back onto the first digit and read the whole number.
digit:  LEAY    -1,Y
        BSR     rdnum
        BRA     next
        ENDIF

; a-z: push the cell's address (the cell is the variable)
;  (the unchecked base build does x@ and x! in one step)
        IF      (1-SBASEU)*(1-FAST)
lower:  BSR     cellx
        PSHU    X
        BRA     next
        ENDIF
        IF      SBASEU
; a-z, unchecked base: a variable followed by '@' or '!' is fetched or
; stored in the same step (x@ is the commonest pair in most programs). A
; checked build checks the stacks between the two, so it keeps them apart.
lower:  ASLA                    ; (cellx, inline)
        LDX     #LET
        LEAX    A,X
        LDB     ,Y
        CMPB    #'@'
        BEQ     lwf
        CMPB    #'!'
        BEQ     lws
        PSHU    X
        BRA     next
lwf:    LEAY    1,Y             ; x@: the cell's value (little-endian)
        LDB     ,X
        LDA     1,X
        PSHU    D
        BRA     next
lws:    LEAY    1,Y             ; x!: the cell = TOS
        PULU    D
        STB     ,X
        STA     1,X
        BRA     next
        ENDIF

; A-Z: call the word. The IP (the address after the letter) goes on the
; return stack, and the IP becomes the address in the letter's cell.
; Checked: a cell still 0 (high byte 0) was never defined, since every
; address in the program's space is 8200h or more. The call has not been
; made yet, so the report shows the stacks as they were.
        IF      1-FAST
upper:  BSR     cellx
        LDB     ,X
        LDA     1,X
        ENDIF
        IF      CHECKED*(1-FAST)
        BEQ     e_undef
        ENDIF
        IF      1-FAST
        PSHS    Y
        TFR     D,Y
        BSR     pollk           ; the break check, at every word call
        BRA     next
        ENDIF

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
        LDD     ,U
        ASLB
        ROLA
        ASLB
        ROLA
        ADDD    ,U              ; 5V
        ASLB
        ROLA                    ; 10V
        ADDB    ,Y+             ; and the digit, read again
        ADCA    #0
        SUBD    #30h            ; minus '0' (asm80 would put a quoted '0'
                                ;   in the high byte of a 16-bit operand)
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
pk1:    JSR     KEY             ; (the fast build counts down itself)
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
; the two ranges after it; the checked build has it next to the grave, and
; so does the unchecked base build, which needs its bytes there instead.)
        IF      (1-CHECKED)*(1-QK)
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
;
;  The unchecked base build keeps to the same rules: its skip and udiv are
;  out in the tail, and hexc comes into the first range, where the checked
;  build has it. The fast build has no PTAB (see "The fast build").
; =============================================================================
        IF      (1-CHECKED)*(1-FAST)
PGRET   EQU     (h_ret-PTAB)/256        ; 0 = first range, 1 = second
PGBRK   EQU     (h_break-PTAB)/256
PGDEF   EQU     (h_def-PTAB)/256
PGFET   EQU     (h_fetch-PTAB)/256
PGKEY   EQU     (h_key-PTAB)/256
NPG1    EQU     20 + PGKEY + PGFET + PGDEF + PGBRK + PGRET
        ENDIF
PTAB:
        IF      (1-CHECKED)*(1-FAST)
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
        IF      CHECKED*(1-FAST)
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

        IF      CHECKED+QK
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
        IF      1-QK
        BEQ     sk9             ; false: nothing to do
        BSR     skip
        ENDIF
        IF      QK
        BEQ     hv9             ; false: nothing to do (hexc's RTS)
        JSR     skip            ; (base: in the tail, with its cache)
        ENDIF
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
        IF      (1-CHECKED)*(1-QK)
        ; fall into skip
        ENDIF
        IF      QK*(1-CHECKED)
        JMP     skip            ; (base: in the tail, with its cache)
        ENDIF
        IF      CHECKED
        ; Checked: the skip must end at a ']' (A = 2), or for a false '(',
        ; which comes to opf, at a ')' (A = 0). Anything else stops with N.
        ENDIF
        IF      CHECKED*(1-QK)
        BSR     skip
        SUBA    #2
        FCB     8Ch             ; (CMPX #: steps over the BSR)
opf:    BSR     skip
        TSTA
        BEQ     sk9             ; (an RTS)
        LDA     #'N'
        BRA     ejmp
        ENDIF
        IF      CHECKED*QK
        JSR     skip            ; (base: in the tail, with its cache)
        SUBA    #2
        BRA     of1
opf:    JSR     skip
of1:    TSTA
        BEQ     hv9             ; (an RTS: hexc's)
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
; (base has its own, with the skip cache, in the tail: see "Speed-ups".)
        IF      1-QK
skip:   CLRB
sk1:    LDA     ,Y+
        ENDIF
        IF      (1-CHECKED)*(1-QK)
        LBEQ    fin
        ENDIF
        IF      CHECKED*(1-QK)
        BEQ     ssn             ; A = FFh
        ENDIF
        IF      1-QK
        CMPA    #22h
        BNE     sk2
        BSR     skipstr         ; leaves A = 22h, which matches nothing below
        ENDIF
        IF      CHECKED*(1-QK)
        BCS     sk9             ; (or FFh, with the carry set: unclosed)
        ENDIF
        IF      1-QK
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
        ENDIF

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
        IF      (1-CHECKED)*(1-QK)
        BEQ     skip            ; tail call: skip ends in RTS
        ENDIF
        IF      QK*(1-CHECKED)
        LBEQ    skip            ; (base: in the tail)
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
; (base leaves out a cross term whose high byte is 0, which most
; multiplications have: a count or a small constant.)
        IF      1-QK
h_mul:  LDA     3,U
        LDB     ,U
        MUL                     ; al*bh
        STB     ,U              ; (bh is no longer needed)
        LDA     2,U
        LDB     1,U
        MUL                     ; ah*bl
        ADDB    ,U
        STB     ,U              ; the cross terms, low byte
        ENDIF
        IF      QK
h_mul:  LDA     3,U
        LDB     ,U
        BEQ     mu1             ; bh = 0: no al*bh (and ,U is 0 already)
        MUL                     ; al*bh
        STB     ,U              ; (bh is no longer needed)
mu1:    LDA     2,U
        BEQ     mu2             ; ah = 0: no ah*bl
        LDB     1,U
        MUL                     ; ah*bl
        ADDB    ,U
        STB     ,U              ; the cross terms, low byte
mu2:
        ENDIF
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
; (The checked build has it in the tail, near negnum: its report would be
; in the way here.)
        IF      1-CHECKED
h_sub:  JSR     isdig
        BLO     negnum
        LDD     2,U
        SUBD    ,U++
        BRA     st
        ENDIF

; '!' ( n addr -- ) is '.' with the high byte stored first. The cell in
; memory is little-endian.
; Checked: both bytes must be in the program's space, and they are tested
; before either is stored (chkst stops with O, the stack untouched).
        IF      1-CHECKED
h_store:PULU    X
        LDA     ,U
        STA     1,X
        ENDIF
        IF      CHECKED
h_store:LDX     ,U
        BSR     chkst
        LEAX    1,X
        BSR     chkst
        LDA     2,U
        STA     ,X
        ; and fall into '.', which loads X again (and checks it again)
        ENDIF
        IF      1-CHECKED
        FCB     8Ch             ; (CMPX #: steps over the PULU)
h_cstore:PULU   X               ; '.' ( c addr -- )
        ENDIF
        IF      CHECKED
h_cstore:LDX    ,U              ; '.' ( c addr -- )
        BSR     chkst
        LEAU    2,U
        ENDIF
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
;     D:n:[ ...][ v]*  CR LF     (the top 8 cells, bottom to top, signed)
;     R:n CR LF
;
;  and goes to EXIT. Line and column count from 1: the line is one more
;  than the LFs between PROG and the place, the column the distance from the
;  last LF (or from PROG-1). A place below PROG is in the -n? line buffer:
;  line 0, column = its offset there + 1. Numbers other than the cells are
;  printed unsigned (pdec), the cells signed (h_num).
;
;  The data stack may be one cell past its limit (S, U = 8100h): the
;  report's own cells then reach 6 bytes further down, to 80FAh, into the
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
        BSR     pdec            ; the line
        BSR     pmsg
        FCB     ','+80h
        BSR     pdec            ; the column
        BSR     pmsg
        FCB     13,10,"D",':'+80h
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
        FCB     13,10,"R",':'+80h
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
        IF      CHECKED
        LBSR    negt            ; (long: the checked h_print is in between)
        ENDIF
        IF      1-CHECKED
        BSR     negt
        ENDIF
; pdec: print the top cell as unsigned and drop it, by recursion on /10
pdec:   LDD     #10
        PSHU    D
        IF      (1-CHECKED)*(1-QK)
        BSR     udiv            ; NOS = quotient, TOS = digit
        ENDIF
        IF      CHECKED*(1-QK)
        LBSR    udiv            ; (out of a BSR's reach here)
        ENDIF
        IF      SBASEU
        BSR     ud0             ; (base: past the power-of-two test)
        ENDIF
        IF      QK-SBASEU
        LBSR    ud0
        ENDIF
        PULU    D               ; the digit
        PSHS    B
        LDD     ,U++            ; the quotient: if it is not 0, it goes
        BEQ     pd1             ;   back for the rest of the digits
        PSHU    D
        BSR     pdec
pd1:    PULS    A
        ADDA    #'0'            ; and fall into putc

putc:   JMP     CONOUT

; ---- the tail ---------------------------------------------------------------
; '$' is the last handler, so what follows its first byte may lie past the
; second range: its loop, the escapes, and the routines of '/'.

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
        IF      1-QK
        BSR     udiv            ; NOS = q, TOS = r
        ENDIF
        IF      QK
        JSR     udiv            ; (base: with the speed-ups)
        ENDIF
        LEAX    2,U
        TST     ,S+
        BPL     dv1
        BSR     negx            ; q's sign
dv1:    TST     ,S+
        BPL     ng9
        BRA     negt            ; r's sign

; '$' prints the string at TOS, decoding escapes: '/' plus a character from
; 60h to 7Eh is one of the escapes at pesc; '/' plus any other character
; clears that character's bit 6 (/M is CR, '/' and DEL is '?'; '/', '"'
; and '?' have no bit 6, so //, /" and /? give themselves). The address
; comes off the stack first, and Y walks the string (the IP waits on S), so
; that /~ finds its row and column on top, and an escape may use A, B, X
; and the routines.
; Checked: a NUL (not one escaped by '/') stops with Q, the string's
; address put back on the stack (from PSAV) over what any /~ left.
h_print:PSHS    Y
        PULU    Y
        IF      CHECKED
        CMPU    #DSTOP          ; '$' with nothing on the stack: s, before it
        LBHI    e_ds            ;   prints from an address of no meaning (N
        STY     <PSAV           ;   is clear: an underflow)
        ENDIF
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
pr1:    BSR     putc
        BRA     pr0
pr9:    PULS    Y,PC
        IF      CHECKED
prq:    LDX     <PSAV
        PSHU    X
        JMP     e_quote
        ENDIF

; '-', checked build (see the unchecked one, before '!').
        IF      CHECKED
h_sub:  JSR     isdig
        BLO     negnum
        LDD     2,U
        SUBD    ,U++
        BRA     ud3             ; (STD ,U / RTS)
        ENDIF

negnum: JSR     rdnum           ; a negative literal: read it, then negate
negt:   TFR     U,X
negx:   CLRA                    ; negx: negate the cell at X
        CLRB
        SUBD    ,X
        STD     ,X
ng9:    RTS
absx:   TST     ,X              ; absx: negate the cell at X if negative
        BPL     ng9
        BRA     negx

; udiv: unsigned divide, in place. The dividend is the NOS cell and the
; divisor the TOS cell, both <= 8000h; the NOS cell becomes the quotient and
; the TOS cell the remainder. The remainder is built in D (always < the
; divisor, so 2R+1 fits in 16 bits).
; Dividing by 2 is one shift (the spec wants that fast). (base divides
; by any power of two with shifts: its udiv is with the speed-ups, and
; comes to ud0 for the rest; pdec, whose divisor is 10, goes straight there.)
        IF      1-QK
udiv:   LDD     ,U
        SUBD    #2
        BNE     ud0
        LSR     2,U
        ROR     3,U             ; the quotient
        ROLB                    ; the remainder: the bit that fell out (D was 0)
        BRA     ud3
        ENDIF
        IF      1-FAST
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
        ENDIF                   ; (the fast build's is unrolled: see the end)
ud3:    STD     ,U
        RTS

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

        IF      QK
; =============================================================================
;  Speed-ups (base, and the fast build)
;
;  The rest of them are with their handlers: '*' (h_mul), the unchecked
;  a-z (lower), pdec (straight to the long divide) and the startup, which
;  empties the skip cache. (A true ')' already reads the block start where
;  it is, in every build, so there is nothing to gain there.)
; =============================================================================
; skip, with the skip cache. Nearly every skip is one that has happened
; before (a loop skips the same false block on every pass), so the end of
; each scan is remembered: 64 entries of {start, end} (big-endian), in the
; page CPAGE, found by the start's low byte times 4. Only skips that start
; in the program text hit (the line buffer changes); the cache is emptied
; whenever a run starts. A program that changes its own text while it runs
; is not looked after. A hit returns as the scan would: Y past the closer,
; and A = 0 for ')' or 2 for ']'.
skip:   TFR     Y,D             ; the start: the cache's key
        ASLB
        ASLB
        LDX     #CPAGE*256
        ABX                     ; X -> the entry
        CMPY    ,X
        BNE     sks
        CMPY    #PROG
        BLO     sks             ; below the program text: never a hit
        LDY     2,X             ; a hit: the IP is past the closer,
        LDA     -1,Y            ;   ')' (29h) or ']' (5Dh): 0 or 2
        LSRA
        ANDA    #2
        RTS
; The scan, which fills the entry (X is kept throughout). A scan that fails
; ends the program, so an entry is never left half written for a later run
; to find. Two range tests rule most characters out: ^ and up, and * to Z.
; Only NUL " ( ) [ ] count. B counts the open levels.
sks:    STY     ,X              ; the key
        LDB     #0FFh
sq3:    INCB                    ; an opener: one deeper
sq1:    LDA     ,Y+
        CMPA    #5Eh
        BHS     sq1             ; ^ _ ` a-z { | } ~ and up: nothing
        CMPA    #5Bh
        BHS     sqb             ; [ \ ]
        CMPA    #2Ah
        BHS     sq1             ; * to Z: nothing
        CMPA    #28h
        BEQ     sq3             ; (
        BHI     sqc             ; )
        CMPA    #22h
        BEQ     sqq             ; a string
        TSTA
        BNE     sq1             ; the rest below '(': nothing
        ENDIF
        IF      QK*(1-CHECKED)
        JMP     fin             ; NUL: the end of the program
sqq:    JSR     skipstr         ; step over the string
        BRA     sq1
        ENDIF
        IF      QK*CHECKED
        DECA                    ; NUL: A = FFh, and the caller decides
        RTS
sqq:    JSR     skipstr         ; step over the string; A = FFh with the
        BCC     sq1             ;   carry set if it ran into the NUL
        RTS
        ENDIF
        IF      QK
sqb:    SUBA    #5Ch            ; [ -1, \ 0, ] 1
        BEQ     sq1             ; '\' is nothing here
        BLO     sq3             ; [
        LDA     #2              ; ]
        FCB     21h             ; (BRN: steps over the CLRA)
sqc:    CLRA                    ; )
        DECB
        BPL     sq1
        STY     2,X             ; the closer at this level: the entry's end
        RTS

; base: a power of two, 2^k, is a shift: q = a >> k and r = a AND (2^k - 1).
; That is 2, and 256 for a high byte, and the 32 or 64 of fixed point.
udiv:   LDD     ,U
        LBEQ    ud0             ; by 0: the long way (it means nothing anyway)
        SUBD    #1
        TFR     D,X             ; X = d - 1
        ANDA    ,U
        LBNE    ud0
        ANDB    1,U
        LBNE    ud0             ; not a power of two
        TFR     X,D
        ANDA    2,U
        ANDB    3,U
        PSHS    D               ; r
        TST     1,U
        BNE     uq0             ; d < 256
        LDA     ,U              ; 256 and up: d and a move a byte down
        STA     1,U             ;   (the low byte of d is all the loop
        LDB     2,U             ;   looks at)
        CLRA
        BRA     uq1
uq0:    LDD     2,U
uq1:    LSR     1,U             ; a moves down until d's one bit falls out
        BCS     uq2
        LSRA
        RORB
        BRA     uq1
uq2:    STD     2,U             ; q
        PULS    D
        STD     ,U
        RTS
        ENDIF

        IF      FAST
; =============================================================================
;  The fast build (SPEED = 2)
;
;  The inner loop is a table of 256 handler addresses, FTAB, one for every
;  byte, and the dispatcher (NEXTF, at the top) is inline at the end of each
;  of the fast build's own entries, so there is no return to a loop:
;
;      LDB ,Y+ / LDX #FTAB / ABX / ABX / JMP [,X]
;
;  (21 cycles; the checked build calls fchk first, which checks the stacks
;  and keeps the place, as the ordinary inner loop does.) The entries are
;  jumped to, not called, so nothing of the dispatcher's is on the return
;  stack while they run. The letters and digits have one entry each, which
;  knows its cell or its value already; the commonest punctuation has its
;  own; the rest are thunks, JSR to the ordinary handler, which returns
;  with its RTS as it would to the ordinary dispatcher.
; =============================================================================
        ENDIF
        IF      FAST*CHECKED
; fchk: the checks of the inner loop, for the checked fast build (S is 2
; lower in here than when the character starts).
fchk:   LEAX    (0-DSLIM)&0FFFFh,U
        CMPX    #DSTOP-DSLIM
        LBHI    e_ds
        LEAX    (2-RSLIM)&0FFFFh,S
        CMPX    #RSTOP-RSLIM
        LBHI    e_rs
        STY     <AT             ; the place, should this character fail
        LEAX    2,S
        STX     <SSAV           ; and the return stack, as it is then
        RTS
FOPF    EQU     opf             ; (a false '(': the checked skip)
FSTORE  EQU     ft_store        ; ('!' and '.' are checked: the thunks)
FCSTORE EQU     ft_cstore
FHIGH   EQU     fhi             ; (80h-FFh: X)
fhi:    JMP     e_resv          ; 80h-FFh: reserved
        ENDIF
        IF      FAST*(1-CHECKED)
FOPF    EQU     skip
FSTORE  EQU     fs_store
FCSTORE EQU     fs_cstore
FHIGH   EQU     fign            ; (80h-FFh are ignored)
        ENDIF
        IF      FAST
fnext:  NEXTF                   ; the startup comes here
fnul:   JMP     EXIT            ; NUL: the end of the program
fign:   NEXTF                   ; 01h-20h and DEL (and 80h-FFh unchecked): nothing
; The thunks: the ordinary handler, then the dispatcher.
ft_store:JSR    h_store         ; !
        NEXTF
ft_str: JSR     h_str           ; "
        NEXTF
ft_num: JSR     h_num           ; #
        NEXTF
ft_print:JSR    h_print         ; $
        NEXTF
ft_emit:JSR     h_emit          ; '
        NEXTF
ft_cstore:JSR   h_cstore        ; .
        NEXTF
ft_div: JSR     h_div           ; /
        NEXTF
ft_key: JSR     h_key           ; ?
        NEXTF
ft_def: JSR     h_def           ; [
        NEXTF
ft_break:JSR    h_break         ; \
        NEXTF
ft_alloc:JSR    h_alloc         ; _
        NEXTF
ft_grave:JSR    h_grave         ; `
        NEXTF
ft_tor: JSR     h_tor           ; {
        NEXTF
ft_fromr:JSR    h_fromr         ; }
        NEXTF
; The commonest punctuation, written for the fast build.
fs_add: PULU    D               ; +
        ADDD    ,U
        STD     ,U
        NEXTF
fs_sub: LDA     ,Y              ; -  (a digit next: a negative number)
        SUBA    #'0'
        CMPA    #10
        BLO     fsb1
        LDD     2,U
        SUBD    ,U++
        STD     ,U
        NEXTF
fsb1:   JSR     negnum
        NEXTF
fs_dup: LDD     ,U              ; :
        PSHU    D
        NEXTF
fs_drop:LEAU    2,U             ; ;
        NEXTF
fs_swap:LDD     ,U              ; %
        LDX     2,U
        STD     2,U
        STX     ,U
        NEXTF
fs_fet: LDX     ,U              ; @  (the cell in memory is little-endian)
        LDB     ,X
        LDA     1,X
        STD     ,U
        NEXTF
fs_cfet:LDX     ,U              ; ,
        LDB     ,X
        CLRA
        STD     ,U
        NEXTF
fs_lt:  PULU    X               ; <  (X = b: b - a)
        CMPX    ,U
        BGT     flt1
        LDD     #0
        STD     ,U
        NEXTF
flt1:   LDD     #0FFFFh
        STD     ,U
        NEXTF
fs_eq:  PULU    X               ; =  (X = b: b - a)
        CMPX    ,U
        BEQ     feq1
        LDD     #0
        STD     ,U
        NEXTF
feq1:   LDD     #0FFFFh
        STD     ,U
        NEXTF
fs_gt:  PULU    X               ; >  (X = b: b - a)
        CMPX    ,U
        BLT     fgt1
        LDD     #0
        STD     ,U
        NEXTF
fgt1:   LDD     #0FFFFh
        STD     ,U
        NEXTF
fs_and: PULU    D               ; &
        ANDA    ,U
        ANDB    1,U
        STD     ,U
        NEXTF
fs_or:  PULU    D               ; |
        ORA     ,U
        ORB     1,U
        STD     ,U
        NEXTF
fs_xor: PULU    D               ; ^
        EORA    ,U
        EORB    1,U
        STD     ,U
        NEXTF
fs_not: COM     ,U              ; ~
        COM     1,U
        NEXTF
fs_mul: LDA     3,U             ; *  (as base's h_mul)
        LDB     ,U
        BEQ     fmu1
        MUL                     ; al*bh
        STB     ,U
fmu1:   LDA     2,U
        BEQ     fmu2
        LDB     1,U
        MUL                     ; ah*bl
        ADDB    ,U
        STB     ,U
fmu2:   LDA     3,U
        LDB     1,U
        MUL                     ; al*bl
        ADDA    ,U
        LEAU    2,U
        STD     ,U
        NEXTF
fs_open:LDD     ,U++            ; (
        BEQ     fop0
        PSHS    Y               ; true: the block starts at the IP
        NEXTF
fop0:   JSR     FOPF            ; false: skip to the ')'
        NEXTF
fs_close:LDD    ,U++            ; )
        BEQ     fcl0
        LDY     ,S              ; true: back to the block start, read where
        DEC     <COUNT          ;   it is; and the break check, 1 look in 256
        BNE     fcl1
        JSR     pk1
fcl1:   NEXTF
fcl0:   LEAS    2,S             ; false: drop the block start
        NEXTF
fs_ret: PULS    Y               ; ]
        NEXTF
        ENDIF
        IF      FAST*(1-CHECKED)
fs_store:PULU   X               ; !  ( n addr -- ), little-endian
        PULU    D
        STB     ,X
        STA     1,X
        NEXTF
fs_cstore:PULU  X               ; .
        PULU    D
        STB     ,X
        NEXTF
        ENDIF
        IF      FAST
; The digits: each pushes its value, and goes on to fdm for more digits.
fd0:    LDD     #0
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd0n
        JMP     fdm             ; another digit
fd0n:   NEXTF
fd1:    LDD     #1
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd1n
        JMP     fdm             ; another digit
fd1n:   NEXTF
fd2:    LDD     #2
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd2n
        JMP     fdm             ; another digit
fd2n:   NEXTF
fd3:    LDD     #3
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd3n
        JMP     fdm             ; another digit
fd3n:   NEXTF
fd4:    LDD     #4
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd4n
        JMP     fdm             ; another digit
fd4n:   NEXTF
fd5:    LDD     #5
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd5n
        JMP     fdm             ; another digit
fd5n:   NEXTF
fd6:    LDD     #6
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd6n
        JMP     fdm             ; another digit
fd6n:   NEXTF
fd7:    LDD     #7
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd7n
        JMP     fdm             ; another digit
fd7n:   NEXTF
fd8:    LDD     #8
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd8n
        JMP     fdm             ; another digit
fd8n:   NEXTF
fd9:    LDD     #9
        PSHU    D
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BHS     fd9n
        JMP     fdm             ; another digit
fd9n:   NEXTF
; fdm: another digit, at the IP: the value on top becomes value * 10 + digit
fdm:    LDD     ,U
        ASLB
        ROLA
        ASLB
        ROLA
        ADDD    ,U              ; 5V
        ASLB
        ROLA                    ; 10V
        ADDB    ,Y+             ; and the digit
        ADCA    #0
        SUBD    #30h            ; minus '0'
        STD     ,U
        LDA     ,Y
        SUBA    #'0'
        CMPA    #10
        BLO     fdm
        NEXTF
        ENDIF
        IF      FAST*(1-CHECKED)
; A-Z: call the word: the IP goes on the return stack, the IP becomes
; the word's body (the cell is little-endian), and the break key is
; looked at, one time in 256.
fuA:    PSHS    Y               ; A
        LDB     <00h
        LDA     <01h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuA1
        JSR     pk1
fuA1:   NEXTF
fuB:    PSHS    Y               ; B
        LDB     <02h
        LDA     <03h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuB1
        JSR     pk1
fuB1:   NEXTF
fuC:    PSHS    Y               ; C
        LDB     <04h
        LDA     <05h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuC1
        JSR     pk1
fuC1:   NEXTF
fuD:    PSHS    Y               ; D
        LDB     <06h
        LDA     <07h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuD1
        JSR     pk1
fuD1:   NEXTF
fuE:    PSHS    Y               ; E
        LDB     <08h
        LDA     <09h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuE1
        JSR     pk1
fuE1:   NEXTF
fuF:    PSHS    Y               ; F
        LDB     <0Ah
        LDA     <0Bh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuF1
        JSR     pk1
fuF1:   NEXTF
fuG:    PSHS    Y               ; G
        LDB     <0Ch
        LDA     <0Dh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuG1
        JSR     pk1
fuG1:   NEXTF
fuH:    PSHS    Y               ; H
        LDB     <0Eh
        LDA     <0Fh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuH1
        JSR     pk1
fuH1:   NEXTF
fuI:    PSHS    Y               ; I
        LDB     <10h
        LDA     <11h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuI1
        JSR     pk1
fuI1:   NEXTF
fuJ:    PSHS    Y               ; J
        LDB     <12h
        LDA     <13h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuJ1
        JSR     pk1
fuJ1:   NEXTF
fuK:    PSHS    Y               ; K
        LDB     <14h
        LDA     <15h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuK1
        JSR     pk1
fuK1:   NEXTF
fuL:    PSHS    Y               ; L
        LDB     <16h
        LDA     <17h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuL1
        JSR     pk1
fuL1:   NEXTF
fuM:    PSHS    Y               ; M
        LDB     <18h
        LDA     <19h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuM1
        JSR     pk1
fuM1:   NEXTF
fuN:    PSHS    Y               ; N
        LDB     <1Ah
        LDA     <1Bh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuN1
        JSR     pk1
fuN1:   NEXTF
fuO:    PSHS    Y               ; O
        LDB     <1Ch
        LDA     <1Dh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuO1
        JSR     pk1
fuO1:   NEXTF
fuP:    PSHS    Y               ; P
        LDB     <1Eh
        LDA     <1Fh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuP1
        JSR     pk1
fuP1:   NEXTF
fuQ:    PSHS    Y               ; Q
        LDB     <20h
        LDA     <21h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuQ1
        JSR     pk1
fuQ1:   NEXTF
fuR:    PSHS    Y               ; R
        LDB     <22h
        LDA     <23h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuR1
        JSR     pk1
fuR1:   NEXTF
fuS:    PSHS    Y               ; S
        LDB     <24h
        LDA     <25h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuS1
        JSR     pk1
fuS1:   NEXTF
fuT:    PSHS    Y               ; T
        LDB     <26h
        LDA     <27h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuT1
        JSR     pk1
fuT1:   NEXTF
fuU:    PSHS    Y               ; U
        LDB     <28h
        LDA     <29h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuU1
        JSR     pk1
fuU1:   NEXTF
fuV:    PSHS    Y               ; V
        LDB     <2Ah
        LDA     <2Bh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuV1
        JSR     pk1
fuV1:   NEXTF
fuW:    PSHS    Y               ; W
        LDB     <2Ch
        LDA     <2Dh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuW1
        JSR     pk1
fuW1:   NEXTF
fuX:    PSHS    Y               ; X
        LDB     <2Eh
        LDA     <2Fh
        TFR     D,Y
        DEC     <COUNT
        BNE     fuX1
        JSR     pk1
fuX1:   NEXTF
fuY:    PSHS    Y               ; Y
        LDB     <30h
        LDA     <31h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuY1
        JSR     pk1
fuY1:   NEXTF
fuZ:    PSHS    Y               ; Z
        LDB     <32h
        LDA     <33h
        TFR     D,Y
        DEC     <COUNT
        BNE     fuZ1
        JSR     pk1
fuZ1:   NEXTF
; a-z: push the cell's address; or with '@' or '!' next, fetch or
; store in the same step.
fva:    LDA     ,Y              ; a
        CMPA    #'@'
        BEQ     fva1
        CMPA    #'!'
        BEQ     fva2
        LDD     #LET+40h
        PSHU    D
        NEXTF
fva1:   LEAY    1,Y             ; a@
        LDB     <40h
        LDA     <41h
        PSHU    D
        NEXTF
fva2:   LEAY    1,Y             ; a!
        PULU    D
        STB     <40h
        STA     <41h
        NEXTF
fvb:    LDA     ,Y              ; b
        CMPA    #'@'
        BEQ     fvb1
        CMPA    #'!'
        BEQ     fvb2
        LDD     #LET+42h
        PSHU    D
        NEXTF
fvb1:   LEAY    1,Y             ; b@
        LDB     <42h
        LDA     <43h
        PSHU    D
        NEXTF
fvb2:   LEAY    1,Y             ; b!
        PULU    D
        STB     <42h
        STA     <43h
        NEXTF
fvc:    LDA     ,Y              ; c
        CMPA    #'@'
        BEQ     fvc1
        CMPA    #'!'
        BEQ     fvc2
        LDD     #LET+44h
        PSHU    D
        NEXTF
fvc1:   LEAY    1,Y             ; c@
        LDB     <44h
        LDA     <45h
        PSHU    D
        NEXTF
fvc2:   LEAY    1,Y             ; c!
        PULU    D
        STB     <44h
        STA     <45h
        NEXTF
fvd:    LDA     ,Y              ; d
        CMPA    #'@'
        BEQ     fvd1
        CMPA    #'!'
        BEQ     fvd2
        LDD     #LET+46h
        PSHU    D
        NEXTF
fvd1:   LEAY    1,Y             ; d@
        LDB     <46h
        LDA     <47h
        PSHU    D
        NEXTF
fvd2:   LEAY    1,Y             ; d!
        PULU    D
        STB     <46h
        STA     <47h
        NEXTF
fve:    LDA     ,Y              ; e
        CMPA    #'@'
        BEQ     fve1
        CMPA    #'!'
        BEQ     fve2
        LDD     #LET+48h
        PSHU    D
        NEXTF
fve1:   LEAY    1,Y             ; e@
        LDB     <48h
        LDA     <49h
        PSHU    D
        NEXTF
fve2:   LEAY    1,Y             ; e!
        PULU    D
        STB     <48h
        STA     <49h
        NEXTF
fvf:    LDA     ,Y              ; f
        CMPA    #'@'
        BEQ     fvf1
        CMPA    #'!'
        BEQ     fvf2
        LDD     #LET+4Ah
        PSHU    D
        NEXTF
fvf1:   LEAY    1,Y             ; f@
        LDB     <4Ah
        LDA     <4Bh
        PSHU    D
        NEXTF
fvf2:   LEAY    1,Y             ; f!
        PULU    D
        STB     <4Ah
        STA     <4Bh
        NEXTF
fvg:    LDA     ,Y              ; g
        CMPA    #'@'
        BEQ     fvg1
        CMPA    #'!'
        BEQ     fvg2
        LDD     #LET+4Ch
        PSHU    D
        NEXTF
fvg1:   LEAY    1,Y             ; g@
        LDB     <4Ch
        LDA     <4Dh
        PSHU    D
        NEXTF
fvg2:   LEAY    1,Y             ; g!
        PULU    D
        STB     <4Ch
        STA     <4Dh
        NEXTF
fvh:    LDA     ,Y              ; h
        CMPA    #'@'
        BEQ     fvh1
        CMPA    #'!'
        BEQ     fvh2
        LDD     #LET+4Eh
        PSHU    D
        NEXTF
fvh1:   LEAY    1,Y             ; h@
        LDB     <4Eh
        LDA     <4Fh
        PSHU    D
        NEXTF
fvh2:   LEAY    1,Y             ; h!
        PULU    D
        STB     <4Eh
        STA     <4Fh
        NEXTF
fvi:    LDA     ,Y              ; i
        CMPA    #'@'
        BEQ     fvi1
        CMPA    #'!'
        BEQ     fvi2
        LDD     #LET+50h
        PSHU    D
        NEXTF
fvi1:   LEAY    1,Y             ; i@
        LDB     <50h
        LDA     <51h
        PSHU    D
        NEXTF
fvi2:   LEAY    1,Y             ; i!
        PULU    D
        STB     <50h
        STA     <51h
        NEXTF
fvj:    LDA     ,Y              ; j
        CMPA    #'@'
        BEQ     fvj1
        CMPA    #'!'
        BEQ     fvj2
        LDD     #LET+52h
        PSHU    D
        NEXTF
fvj1:   LEAY    1,Y             ; j@
        LDB     <52h
        LDA     <53h
        PSHU    D
        NEXTF
fvj2:   LEAY    1,Y             ; j!
        PULU    D
        STB     <52h
        STA     <53h
        NEXTF
fvk:    LDA     ,Y              ; k
        CMPA    #'@'
        BEQ     fvk1
        CMPA    #'!'
        BEQ     fvk2
        LDD     #LET+54h
        PSHU    D
        NEXTF
fvk1:   LEAY    1,Y             ; k@
        LDB     <54h
        LDA     <55h
        PSHU    D
        NEXTF
fvk2:   LEAY    1,Y             ; k!
        PULU    D
        STB     <54h
        STA     <55h
        NEXTF
fvl:    LDA     ,Y              ; l
        CMPA    #'@'
        BEQ     fvl1
        CMPA    #'!'
        BEQ     fvl2
        LDD     #LET+56h
        PSHU    D
        NEXTF
fvl1:   LEAY    1,Y             ; l@
        LDB     <56h
        LDA     <57h
        PSHU    D
        NEXTF
fvl2:   LEAY    1,Y             ; l!
        PULU    D
        STB     <56h
        STA     <57h
        NEXTF
fvm:    LDA     ,Y              ; m
        CMPA    #'@'
        BEQ     fvm1
        CMPA    #'!'
        BEQ     fvm2
        LDD     #LET+58h
        PSHU    D
        NEXTF
fvm1:   LEAY    1,Y             ; m@
        LDB     <58h
        LDA     <59h
        PSHU    D
        NEXTF
fvm2:   LEAY    1,Y             ; m!
        PULU    D
        STB     <58h
        STA     <59h
        NEXTF
fvn:    LDA     ,Y              ; n
        CMPA    #'@'
        BEQ     fvn1
        CMPA    #'!'
        BEQ     fvn2
        LDD     #LET+5Ah
        PSHU    D
        NEXTF
fvn1:   LEAY    1,Y             ; n@
        LDB     <5Ah
        LDA     <5Bh
        PSHU    D
        NEXTF
fvn2:   LEAY    1,Y             ; n!
        PULU    D
        STB     <5Ah
        STA     <5Bh
        NEXTF
fvo:    LDA     ,Y              ; o
        CMPA    #'@'
        BEQ     fvo1
        CMPA    #'!'
        BEQ     fvo2
        LDD     #LET+5Ch
        PSHU    D
        NEXTF
fvo1:   LEAY    1,Y             ; o@
        LDB     <5Ch
        LDA     <5Dh
        PSHU    D
        NEXTF
fvo2:   LEAY    1,Y             ; o!
        PULU    D
        STB     <5Ch
        STA     <5Dh
        NEXTF
fvp:    LDA     ,Y              ; p
        CMPA    #'@'
        BEQ     fvp1
        CMPA    #'!'
        BEQ     fvp2
        LDD     #LET+5Eh
        PSHU    D
        NEXTF
fvp1:   LEAY    1,Y             ; p@
        LDB     <5Eh
        LDA     <5Fh
        PSHU    D
        NEXTF
fvp2:   LEAY    1,Y             ; p!
        PULU    D
        STB     <5Eh
        STA     <5Fh
        NEXTF
fvq:    LDA     ,Y              ; q
        CMPA    #'@'
        BEQ     fvq1
        CMPA    #'!'
        BEQ     fvq2
        LDD     #LET+60h
        PSHU    D
        NEXTF
fvq1:   LEAY    1,Y             ; q@
        LDB     <60h
        LDA     <61h
        PSHU    D
        NEXTF
fvq2:   LEAY    1,Y             ; q!
        PULU    D
        STB     <60h
        STA     <61h
        NEXTF
fvr:    LDA     ,Y              ; r
        CMPA    #'@'
        BEQ     fvr1
        CMPA    #'!'
        BEQ     fvr2
        LDD     #LET+62h
        PSHU    D
        NEXTF
fvr1:   LEAY    1,Y             ; r@
        LDB     <62h
        LDA     <63h
        PSHU    D
        NEXTF
fvr2:   LEAY    1,Y             ; r!
        PULU    D
        STB     <62h
        STA     <63h
        NEXTF
fvs:    LDA     ,Y              ; s
        CMPA    #'@'
        BEQ     fvs1
        CMPA    #'!'
        BEQ     fvs2
        LDD     #LET+64h
        PSHU    D
        NEXTF
fvs1:   LEAY    1,Y             ; s@
        LDB     <64h
        LDA     <65h
        PSHU    D
        NEXTF
fvs2:   LEAY    1,Y             ; s!
        PULU    D
        STB     <64h
        STA     <65h
        NEXTF
fvt:    LDA     ,Y              ; t
        CMPA    #'@'
        BEQ     fvt1
        CMPA    #'!'
        BEQ     fvt2
        LDD     #LET+66h
        PSHU    D
        NEXTF
fvt1:   LEAY    1,Y             ; t@
        LDB     <66h
        LDA     <67h
        PSHU    D
        NEXTF
fvt2:   LEAY    1,Y             ; t!
        PULU    D
        STB     <66h
        STA     <67h
        NEXTF
fvu:    LDA     ,Y              ; u
        CMPA    #'@'
        BEQ     fvu1
        CMPA    #'!'
        BEQ     fvu2
        LDD     #LET+68h
        PSHU    D
        NEXTF
fvu1:   LEAY    1,Y             ; u@
        LDB     <68h
        LDA     <69h
        PSHU    D
        NEXTF
fvu2:   LEAY    1,Y             ; u!
        PULU    D
        STB     <68h
        STA     <69h
        NEXTF
fvv:    LDA     ,Y              ; v
        CMPA    #'@'
        BEQ     fvv1
        CMPA    #'!'
        BEQ     fvv2
        LDD     #LET+6Ah
        PSHU    D
        NEXTF
fvv1:   LEAY    1,Y             ; v@
        LDB     <6Ah
        LDA     <6Bh
        PSHU    D
        NEXTF
fvv2:   LEAY    1,Y             ; v!
        PULU    D
        STB     <6Ah
        STA     <6Bh
        NEXTF
fvw:    LDA     ,Y              ; w
        CMPA    #'@'
        BEQ     fvw1
        CMPA    #'!'
        BEQ     fvw2
        LDD     #LET+6Ch
        PSHU    D
        NEXTF
fvw1:   LEAY    1,Y             ; w@
        LDB     <6Ch
        LDA     <6Dh
        PSHU    D
        NEXTF
fvw2:   LEAY    1,Y             ; w!
        PULU    D
        STB     <6Ch
        STA     <6Dh
        NEXTF
fvx:    LDA     ,Y              ; x
        CMPA    #'@'
        BEQ     fvx1
        CMPA    #'!'
        BEQ     fvx2
        LDD     #LET+6Eh
        PSHU    D
        NEXTF
fvx1:   LEAY    1,Y             ; x@
        LDB     <6Eh
        LDA     <6Fh
        PSHU    D
        NEXTF
fvx2:   LEAY    1,Y             ; x!
        PULU    D
        STB     <6Eh
        STA     <6Fh
        NEXTF
fvy:    LDA     ,Y              ; y
        CMPA    #'@'
        BEQ     fvy1
        CMPA    #'!'
        BEQ     fvy2
        LDD     #LET+70h
        PSHU    D
        NEXTF
fvy1:   LEAY    1,Y             ; y@
        LDB     <70h
        LDA     <71h
        PSHU    D
        NEXTF
fvy2:   LEAY    1,Y             ; y!
        PULU    D
        STB     <70h
        STA     <71h
        NEXTF
fvz:    LDA     ,Y              ; z
        CMPA    #'@'
        BEQ     fvz1
        CMPA    #'!'
        BEQ     fvz2
        LDD     #LET+72h
        PSHU    D
        NEXTF
fvz1:   LEAY    1,Y             ; z@
        LDB     <72h
        LDA     <73h
        PSHU    D
        NEXTF
fvz2:   LEAY    1,Y             ; z!
        PULU    D
        STB     <72h
        STA     <73h
        NEXTF
        ENDIF
        IF      FAST*CHECKED
; A-Z, checked: call the word, unless its cell is still 0 (U); the
; IP goes on the return stack, and the break key is looked at.
fuA:    LDB     <00h            ; A
        LDA     <01h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuA1
        JSR     pk1
fuA1:   NEXTF
fuB:    LDB     <02h            ; B
        LDA     <03h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuB1
        JSR     pk1
fuB1:   NEXTF
fuC:    LDB     <04h            ; C
        LDA     <05h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuC1
        JSR     pk1
fuC1:   NEXTF
fuD:    LDB     <06h            ; D
        LDA     <07h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuD1
        JSR     pk1
fuD1:   NEXTF
fuE:    LDB     <08h            ; E
        LDA     <09h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuE1
        JSR     pk1
fuE1:   NEXTF
fuF:    LDB     <0Ah            ; F
        LDA     <0Bh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuF1
        JSR     pk1
fuF1:   NEXTF
fuG:    LDB     <0Ch            ; G
        LDA     <0Dh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuG1
        JSR     pk1
fuG1:   NEXTF
fuH:    LDB     <0Eh            ; H
        LDA     <0Fh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuH1
        JSR     pk1
fuH1:   NEXTF
fuI:    LDB     <10h            ; I
        LDA     <11h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuI1
        JSR     pk1
fuI1:   NEXTF
fuJ:    LDB     <12h            ; J
        LDA     <13h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuJ1
        JSR     pk1
fuJ1:   NEXTF
fuK:    LDB     <14h            ; K
        LDA     <15h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuK1
        JSR     pk1
fuK1:   NEXTF
fuL:    LDB     <16h            ; L
        LDA     <17h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuL1
        JSR     pk1
fuL1:   NEXTF
fuM:    LDB     <18h            ; M
        LDA     <19h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuM1
        JSR     pk1
fuM1:   NEXTF
fuN:    LDB     <1Ah            ; N
        LDA     <1Bh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuN1
        JSR     pk1
fuN1:   NEXTF
fuO:    LDB     <1Ch            ; O
        LDA     <1Dh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuO1
        JSR     pk1
fuO1:   NEXTF
fuP:    LDB     <1Eh            ; P
        LDA     <1Fh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuP1
        JSR     pk1
fuP1:   NEXTF
fuQ:    LDB     <20h            ; Q
        LDA     <21h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuQ1
        JSR     pk1
fuQ1:   NEXTF
fuR:    LDB     <22h            ; R
        LDA     <23h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuR1
        JSR     pk1
fuR1:   NEXTF
fuS:    LDB     <24h            ; S
        LDA     <25h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuS1
        JSR     pk1
fuS1:   NEXTF
fuT:    LDB     <26h            ; T
        LDA     <27h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuT1
        JSR     pk1
fuT1:   NEXTF
fuU:    LDB     <28h            ; U
        LDA     <29h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuU1
        JSR     pk1
fuU1:   NEXTF
fuV:    LDB     <2Ah            ; V
        LDA     <2Bh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuV1
        JSR     pk1
fuV1:   NEXTF
fuW:    LDB     <2Ch            ; W
        LDA     <2Dh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuW1
        JSR     pk1
fuW1:   NEXTF
fuX:    LDB     <2Eh            ; X
        LDA     <2Fh
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuX1
        JSR     pk1
fuX1:   NEXTF
fuY:    LDB     <30h            ; Y
        LDA     <31h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuY1
        JSR     pk1
fuY1:   NEXTF
fuZ:    LDB     <32h            ; Z
        LDA     <33h
        LBEQ    e_undef
        PSHS    Y
        TFR     D,Y
        DEC     <COUNT
        BNE     fuZ1
        JSR     pk1
fuZ1:   NEXTF
; a-z, checked: push the cell's address (a checked build checks the
; stacks between a variable and what follows it, so it keeps them apart)
fva:    LDD     #LET+40h        ; a
        PSHU    D
        NEXTF
fvb:    LDD     #LET+42h        ; b
        PSHU    D
        NEXTF
fvc:    LDD     #LET+44h        ; c
        PSHU    D
        NEXTF
fvd:    LDD     #LET+46h        ; d
        PSHU    D
        NEXTF
fve:    LDD     #LET+48h        ; e
        PSHU    D
        NEXTF
fvf:    LDD     #LET+4Ah        ; f
        PSHU    D
        NEXTF
fvg:    LDD     #LET+4Ch        ; g
        PSHU    D
        NEXTF
fvh:    LDD     #LET+4Eh        ; h
        PSHU    D
        NEXTF
fvi:    LDD     #LET+50h        ; i
        PSHU    D
        NEXTF
fvj:    LDD     #LET+52h        ; j
        PSHU    D
        NEXTF
fvk:    LDD     #LET+54h        ; k
        PSHU    D
        NEXTF
fvl:    LDD     #LET+56h        ; l
        PSHU    D
        NEXTF
fvm:    LDD     #LET+58h        ; m
        PSHU    D
        NEXTF
fvn:    LDD     #LET+5Ah        ; n
        PSHU    D
        NEXTF
fvo:    LDD     #LET+5Ch        ; o
        PSHU    D
        NEXTF
fvp:    LDD     #LET+5Eh        ; p
        PSHU    D
        NEXTF
fvq:    LDD     #LET+60h        ; q
        PSHU    D
        NEXTF
fvr:    LDD     #LET+62h        ; r
        PSHU    D
        NEXTF
fvs:    LDD     #LET+64h        ; s
        PSHU    D
        NEXTF
fvt:    LDD     #LET+66h        ; t
        PSHU    D
        NEXTF
fvu:    LDD     #LET+68h        ; u
        PSHU    D
        NEXTF
fvv:    LDD     #LET+6Ah        ; v
        PSHU    D
        NEXTF
fvw:    LDD     #LET+6Ch        ; w
        PSHU    D
        NEXTF
fvx:    LDD     #LET+6Eh        ; x
        PSHU    D
        NEXTF
fvy:    LDD     #LET+70h        ; y
        PSHU    D
        NEXTF
fvz:    LDD     #LET+72h        ; z
        PSHU    D
        NEXTF
        ENDIF
        IF      FAST
; (the fast build: the same 16 rounds, unrolled)
ud0:    CLRA
        CLRB
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur0
        SUBD    ,U
        INC     3,U
ur0:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur1
        SUBD    ,U
        INC     3,U
ur1:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur2
        SUBD    ,U
        INC     3,U
ur2:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur3
        SUBD    ,U
        INC     3,U
ur3:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur4
        SUBD    ,U
        INC     3,U
ur4:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur5
        SUBD    ,U
        INC     3,U
ur5:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur6
        SUBD    ,U
        INC     3,U
ur6:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur7
        SUBD    ,U
        INC     3,U
ur7:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur8
        SUBD    ,U
        INC     3,U
ur8:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur9
        SUBD    ,U
        INC     3,U
ur9:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur10
        SUBD    ,U
        INC     3,U
ur10:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur11
        SUBD    ,U
        INC     3,U
ur11:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur12
        SUBD    ,U
        INC     3,U
ur12:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur13
        SUBD    ,U
        INC     3,U
ur13:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur14
        SUBD    ,U
        INC     3,U
ur14:
        ASL     3,U
        ROL     2,U
        ROLB
        ROLA
        CMPD    ,U
        BLO     ur15
        SUBD    ,U
        INC     3,U
ur15:
        STD     ,U
        RTS
; The table: one handler address for every byte.
FTAB:
        FDB     fnul,fign,fign,fign,fign,fign,fign,fign ; 00h
        FDB     fign,fign,fign,fign,fign,fign,fign,fign ; 08h
        FDB     fign,fign,fign,fign,fign,fign,fign,fign ; 10h
        FDB     fign,fign,fign,fign,fign,fign,fign,fign ; 18h
        FDB     fign,FSTORE,ft_str,ft_num,ft_print,fs_swap,fs_and,ft_emit ; 20h
        FDB     fs_open,fs_close,fs_mul,fs_add,fs_cfet,fs_sub,FCSTORE,ft_div ; 28h
        FDB     fd0,fd1,fd2,fd3,fd4,fd5,fd6,fd7 ; 30h
        FDB     fd8,fd9,fs_dup,fs_drop,fs_lt,fs_eq,fs_gt,ft_key ; 38h
        FDB     fs_fet,fuA,fuB,fuC,fuD,fuE,fuF,fuG ; 40h
        FDB     fuH,fuI,fuJ,fuK,fuL,fuM,fuN,fuO ; 48h
        FDB     fuP,fuQ,fuR,fuS,fuT,fuU,fuV,fuW ; 50h
        FDB     fuX,fuY,fuZ,ft_def,ft_break,fs_ret,fs_xor,ft_alloc ; 58h
        FDB     ft_grave,fva,fvb,fvc,fvd,fve,fvf,fvg ; 60h
        FDB     fvh,fvi,fvj,fvk,fvl,fvm,fvn,fvo ; 68h
        FDB     fvp,fvq,fvr,fvs,fvt,fvu,fvv,fvw ; 70h
        FDB     fvx,fvy,fvz,ft_tor,fs_or,ft_fromr,fs_not,fign ; 78h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; 80h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; 88h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; 90h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; 98h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; A0h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; A8h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; B0h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; B8h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; C0h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; C8h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; D0h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; D8h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; E0h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; E8h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; F0h
        FDB     FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH,FHIGH ; F8h
        ENDIF

imgend:
