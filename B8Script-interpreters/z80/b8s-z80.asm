; =============================================================================
;  B8Script interpreter for the Z80
;  Spec: docs/b8script.md (2026-11-24).
;
;  The switches, set in the EQU lines below:
;    CPM      0 = generic ROM build (KEY/CONOUT at fixed addresses)
;             1 = CP/M 2.2 .COM file: loads the file named on the command line
;    EDITOR   1 = with the line editor built in (see the end of this file):
;                 the spec's suggested standard. It goes with either setting
;                 of the other two.
;    CHECKED  0 = no checks (spec: the programmer is responsible)
;             1 = starts with every variable at 0 and every word undefined,
;                 and stops on every error in the spec's table (and Ctrl-C)
;                 with a four-line report: the letter and the place as line
;                 and column, the text there, and both stacks. See `error`.
;    QUICK    1 = the speed-ups that cost bytes: a skip cache, a faster skip,
;                 '*' and '/' quicker for small and power-of-two operands, and
;                 more (see "Speed-ups"). 0, the default, is the smallest build.
;    FAST     1 = the speed build: QUICK and a dispatch table besides, with
;                 no size limit (see "The speed build"). Not with EDITOR.
;    ANSI     what the console escapes of '$' (/{ /} /| /` /~) do:
;             1 = send ANSI (VT100) sequences through CONOUT
;             0 = call the machine's own routines CONCLS, CONEOL, CONCUR and
;                 CONAT (see the equates). The CP/M builds always send ANSI.
;
;  In every build Ctrl-C stops a running program (an unchecked build stops
;  without a word): see the console layer for the rules, the held key and
;  the break-off cell.
;
;  Assembler: asm80 (https://maly.github.io/asm80-node/), Z80 mode.
; =============================================================================

CPM     EQU     0               ; 1 = CP/M .COM build
CHECKED EQU     0               ; 1 = checked build
EDITOR  EQU     0               ; 1 = with the line editor
ANSI    EQU     0               ; 1 = the console escapes send ANSI sequences
QUICK   EQU     0               ; 1 = the speed-ups that cost bytes (see "Speed-ups")
FAST    EQU     0               ; 1 = the speed build (not with EDITOR): see "The speed build"
ANS     EQU     ANSI+CPM-ANSI*CPM ; (CP/M: always ANSI)
EDGEN   EQU     EDITOR*(1-CPM)  ; (the generic build with the editor)
                                ; (IF takes any value but 0 as true, so
                                ;  IF CHECKED+EDITOR means "either")
TABP0   EQU     EDGEN*(1-CHECKED) ; (the build with its table in page zero)
PTLATE  EQU     1-(1-CPM)*(1-EDITOR)*(1-CHECKED)*(1-ANS) ; (1: the table goes after psgn and pdec,
                                ;   not before them: wherever it doesn't cross a
                                ;   page. chktab.py says if it does)
QK      EQU     QUICK+FAST-QUICK*FAST ; (the speed-ups: QUICK, or the speed build)
QUICKU  EQU     QK*(1-CHECKED)*(1-FAST) ; (and those that only the unchecked
                                ;  builds take; the speed build has its own)

; -----------------------------------------------------------------------------
;  Register use, everywhere in the interpreter
;
;    BC   IP: the address of the next program character to read
;    HL   TOS: the top data-stack cell is kept here, not in memory
;    SP   the data stack: (SP) is NOS, the cell under TOS. The data stack is
;         the Z80's own stack, which is what the spec's machine-code contract
;         needs ("the data cells above the return address").
;    IY   return-stack pointer. Entries are 2 bytes; the stack grows down.
;         Only rpop and rpushn (and the checks) touch it. The alternate
;         registers are not used at all: an interrupt routine may use them.
;    A DE scratch. Every handler is entered with HL = TOS and may use A, DE.
;
;  One-byte calls. In a generic build the routines used most are reached
;  with RST, one byte instead of three. The source writes them as macros:
;
;    POPR   RST 08h  rpop    pop the return stack into DE
;    DROP   RST 18h  drp     drop TOS, then next character  (ends a handler)
;    NEGH   RST 20h  neg16   HL = -HL
;    PUTA   RST 28h  putc    print A
;    NEXT   RST 30h  next0   next character                 (ends a handler)
;
;  RST 18h and RST 30h never return: an RST is a CALL, so the first thing
;  each of them does is POP DE to throw the return address away.
;
;  A CP/M build leaves page zero alone: there the macros are CALLs, and
;  DROP and NEXT are jumps (DROPR and NEXTR: JR, where it reaches).
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
;   KEY and CONOUT must preserve BC, DE, HL and IY.
        ENDIF
        IF      1-ANS
; With ANSI = 0 the console escapes call these. All four must keep BC and
; IY, and all but CONAT also HL. They may change A, DE and the flags.
CONCLS  EQU     0FF0Ch          ; /{  clear the screen, the cursor to the top left
CONEOL  EQU     0FF0Fh          ; /}  clear from the cursor to the end of the line
CONCUR  EQU     0FF12h          ; /| and /`  show the cursor if A is not 0, hide
                                ;     it if A = 0
CONAT   EQU     0FF15h          ; /~  the cursor to row HL, column DE, both
                                ;     counted from 0. May change A, DE and HL
        ENDIF
        IFN     CPM
RSPAGE  EQU     80h             ; 8000h return stack
DSPAGE  EQU     81h             ; 8100h data stack
LETPAGE EQU     82h             ; 8200h letter cells and line buffer
PROG    EQU     8300h           ; where the loader puts the program text
HEAPLIM EQU     0F0h            ; the heap must stay below F000h (a page)
CPAGE   EQU     HEAPLIM         ; the skip cache's page (QK builds): the page
                                ;   at the heap limit, which the heap never reaches
BASE    EQU     0000h           ; where the image starts
        ENDIF
        IF      (1-CPM)*(1-EDITOR)
EXIT    EQU     0FF09h          ; where to go when the program ends
        ENDIF
        IF      EDGEN
LEAVE   EQU     0FF09h          ; where the editor's ^X goes
        ENDIF
        IF      EDITOR*CPM
LEAVE   EQU     0000h           ; the editor's ^X: warm boot
        ENDIF
        IF      EDITOR
EXIT    EQU     edend           ; a program that ends goes back to the editor,
SKEND   EQU     skend           ;   also when it ends inside skip
        ENDIF
        IF      1-EDITOR
SKEND   EQU     EXIT
        ENDIF

MSLOOP  EQU     40-36*CPM       ; n? inner loop count for about 1 ms (1-255):
                                ; each pass calls getk once, so tune it for
                                ; your clock and your KEY routine. (The wait
                                ; for a second Ctrl-C uses it too: 250 ms.)
                                ; CP/M: 4, for a BDOS 6 call of about 280 us
                                ; (an RC2014 with RomWBW and ZPM3). A .COM can
                                ; be patched: see TIMING.B8S.

; letter-page layout (offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     LET+7Ch         ; the heap pointer
RSAVE   EQU     LET+34h         ; gap after Z: return stack pointer, saved
                                ;   around machine code (and in the checked
                                ;   build the address '$' prints from);
PCNT    EQU     LET+36h         ;   the break-key poll count (see rpushn);
SKPL    EQU     LET+3Ch         ;   the checked skip's starting place;
NPEND   EQU     LET+38h         ;   minus the address of the program's end
                                ;   (the heap's first byte), for the checked '_';
EDLN    EQU     LET+3Ah         ;   the editor: the number of the line that ^E
                                ;   put in the input line (0: none)
KEYBUF  EQU     LET+7Ah         ; gap after z: a key read by the break check and
                                ;   held for the next '?' (0: none);
BRKOFF  EQU     LET+7Bh         ;   the break-off cell: a program that stores a
                                ;   non-zero byte here gets Ctrl-C as a key
LINEBUF EQU     LET+80h         ; -n? text, ending in CR
RSTOP   EQU     RSPAGE*256+0E0h ; empty return stack: the 32 bytes above it
                                ; take calls made while the data stack is full
DSTOP   EQU     DSPAGE*256+0FCh ; empty data stack. The four bytes above it
                                ; are spare: a character can pop two cells
                                ; too many before the checked build sees it,
                                ; and the next call must not land on the
                                ; letter cells.

; The five one-byte calls. A generic build owns page zero and reaches them
; with RST. A CP/M build must leave page zero alone (CP/M keeps it for
; interrupts, and RomWBW's BIOS calls itself through RST 08h), so there each
; is a CALL, or a jump for the two that never return: DROP is a JP, and
; NEXT is JP (IX), two bytes, with IX holding next0's address throughout.
; (asm80 can't nest IF, so these are written with DS: a count of 0 writes
; nothing. DS can't take a label that comes later, but EQU can, and DS can
; take that.)
AROP    EQU     rpop
ANEG    EQU     neg16
APUT    EQU     putc
APTK    EQU     putk
        IF      1-CPM
putk:   EQU     putc            ; (CP/M only: here it is never used)
        ENDIF
ANXT    EQU     next0
        IF      CHECKED
ACHK    EQU     chkstk          ; (for the speed build's dispatcher)
        ENDIF
        IF      1-CHECKED
ACHK    EQU     0
        ENDIF
        IF      FAST
DTPG    EQU     DTAB/256        ; (the speed build's table's first page)
        ENDIF
        IF      1-FAST
DTPG    EQU     0
        ENDIF
        .macro  POPR            ; pop the return stack into DE
        DS      1-CPM,0CFh      ;   RST 08h
        DS      CPM,0CDh        ;   CALL rpop
        DS      CPM,AROP&0FFh
        DS      CPM,AROP/256
        .endm
        .macro  DROP            ; drop TOS, then next character
        DS      (1-CPM)*(1-FAST),0DFh ; RST 18h
        DS      CPM+FAST-CPM*FAST,0E1h ; POP HL
        DS      CPM+FAST-CPM*FAST,0DDh ; JP (IX)
        DS      CPM+FAST-CPM*FAST,0E9h
        .endm
        .macro  NEGH            ; HL = -HL
        DS      1-CPM,0E7h      ;   RST 20h
        DS      CPM,0CDh        ;   CALL neg16
        DS      CPM,ANEG&0FFh
        DS      CPM,ANEG/256
        .endm
        .macro  PUTA            ; print A
        DS      1-CPM,0EFh      ;   RST 28h
        DS      CPM,0CDh        ;   CALL putc
        DS      CPM,APUT&0FFh
        DS      CPM,APUT/256
        .endm
        .macro  PUTK            ; print the character %%1 (a number)
        DS      1-CPM,3Eh       ;   LD A,%%1 / RST 28h
        DS      1-CPM,%%1
        DS      1-CPM,0EFh
        DS      CPM,0CDh        ;   CALL putk / DB %%1
        DS      CPM,APTK&0FFh
        DS      CPM,APTK/256
        DS      CPM,%%1
        .endm
        .macro  PUTAR           ; print A, and return
        DS      1-CPM,0EFh      ;   RST 28h
        DS      1-CPM,0C9h      ;   RET
        DS      CPM,0C3h        ;   JP putc
        DS      CPM,APUT&0FFh
        DS      CPM,APUT/256
        .endm
        .macro  NEXT            ; next character
        DS      (1-CPM)*(1-FAST),0F7h ; RST 30h
        DS      CPM+FAST-CPM*FAST,0DDh ; JP (IX): IX holds next0
        DS      CPM+FAST-CPM*FAST,0E9h
        .endm
        .macro  NEXTF           ; (speed build only: the dispatcher itself, inline)
        DS      FAST*CHECKED,0CDh ;   (speed build: CALL chkstk, checked)
        DS      FAST*CHECKED,ACHK&0FFh
        DS      FAST*CHECKED,ACHK/256
        DS      FAST,0Ah        ;   (speed build: the dispatcher: LD A,(BC)
        DS      FAST,03h        ;   INC BC
        DS      FAST,0EBh       ;   EX DE,HL
        DS      FAST,6Fh        ;   LD L,A
        DS      FAST,26h        ;   LD H,DTAB/256
        DS      FAST,DTPG
        DS      FAST,7Eh        ;   LD A,(HL)
        DS      FAST,24h        ;   INC H
        DS      FAST,66h        ;   LD H,(HL)
        DS      FAST,6Fh        ;   LD L,A
        DS      FAST,0E9h       ;   JP (HL))
        .endm
        .macro  NEXTZ           ; next character, in the generic page zero: one
        DS      1-CPM,0F7h      ;   byte there in every build (RST 30h)
        DS      CPM,0DDh        ; JP (IX)
        DS      CPM,0E9h
        .endm
        .macro  SETIX           ; CP/M and the speed build: IX = next0 (nothing in
        DS      CPM+FAST-CPM*FAST,0DDh ; a generic build): LD IX,next0
        DS      CPM+FAST-CPM*FAST,21h
        DS      CPM+FAST-CPM*FAST,ANXT&0FFh
        DS      CPM+FAST-CPM*FAST,ANXT/256
        .endm

; =============================================================================
;  The first 49 bytes: the entry, then the RST routines, with small handlers
;  and routines filling the gaps between them. Generic: this IS page zero.
;  CP/M: it is just the start of the .COM file.
; =============================================================================
        ORG     BASE
        IF      (1-CPM)*(1-EDITOR)*CHECKED
        XOR     A               ; 00  reset. (This byte, AFh, is also what an
        ENDIF                   ;     undefined word runs into: see e_hi.)
        IF      1-EDGEN
        LD      SP,DSTOP        ; 00  reset, or the start of the .COM file
        ENDIF
        IF      (1-CPM)*(1-EDITOR)*(1-CHECKED)*(1-QK)
        LD      BC,PROG         ; 03  the IP
        JR      st0             ; 06  (the rest of the startup is close by)
        ENDIF
        IF      (1-CPM)*(1-EDITOR)*(1-CHECKED)*QK
        JP      qstart          ; 03  (the skip cache is emptied first)
        DW      0               ; 06  spare
        ENDIF
        IF      (1-CPM)*(1-EDITOR)*CHECKED*(1-QK)
        JR      init            ; 04  (the rest of the startup is close by)
        DW      0               ; 06  spare
        ENDIF
        IF      (1-CPM)*(1-EDITOR)*CHECKED*QK
        JP      qinit           ; 04  (the skip cache is emptied first)
        DB      0               ; 07  spare
        ENDIF
        IF      EDGEN
        XOR     A               ; 00  reset: no program yet. (This byte, AFh,
        LD      (PROG),A        ;     is also what an undefined word runs
        JP      init            ; 04  into in the checked build: see e_hi.)
        NOP                     ; 07  spare
        ENDIF
        IF      CPM*(1-EDITOR)
        JP      start           ; 03
        ENDIF
        IF      CPM*EDITOR*CHECKED
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
        IF      CPM*EDITOR
        CALL    load            ; the file named on the command line
        JP      edit0
        ENDIF
        IF      1-CPM
; ---- RST 08h: rpop: pop the return stack into DE ---------------------------
rpop:   LD      E,(IY+0)        ; 08
        LD      D,(IY+1)
        JR      rp2             ; (the rest is at 2Bh)
; ctl: the inner loop comes here for characters below 21h. A = c - 21h.
ctl:    ADD     A,21h           ; 10  back to c; zero only for NUL
        JR      NZ,next0        ;     the rest are ignored
endprog:JP      EXIT            ;     the program has ended
        NOP                     ; 17  spare
; ---- RST 18h: drop TOS, then next ------------------------------------------
rst18:  POP     DE              ; 18  discard the RST's return address
drp:    POP     HL              ;     new TOS = NOS
        JR      next0
        ENDIF
h_fromr:PUSH    HL              ; 1C  '}' return stack to TOS
        POPR       
        EX      DE,HL
        NEXTZ      
        IF      1-CPM
; ---- RST 20h: neg16: HL = -HL (keeps BC, DE) -------------------------------
neg16:  XOR     A               ; 20
        SUB     L
        LD      L,A
        SBC     A,A
        SUB     H
        LD      H,A
        RET
        NOP                     ; 27  spare
; ---- RST 28h: putc: print A (keeps BC, DE, HL, IY) -------------------------
rst28:
putc:   JP      CONOUT          ; 28
rp2:    INC     IY              ; 2B  the rest of rpop
        INC     IY
        RET
; ---- RST 30h: next character -----------------------------------------------
rst30:  POP     DE              ; 30  discard the RST's return address
        ENDIF
        IF      CPM
; ctl: the inner loop comes here for characters below 21h. A = c - 21h.
ctl:    ADD     A,21h           ; back to c; zero only for NUL
        JR      NZ,next0        ; the rest are ignored
endprog:JP      EXIT            ; the program has ended
        ENDIF

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
        IF      FAST
next0:  NEXTF                   ; (the speed build: the table dispatcher)
        ENDIF
        IF      1-FAST
next0:
        ENDIF
        IF      CHECKED*(1-FAST)
        CALL    chkstk          ; both stacks are checked once per character
        ENDIF
        IF      1-FAST
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
        ENDIF
        IF      (1-CHECKED)*(1-FAST)
        JR      NC,next0        ; 7Fh-FFh: ignored
        ENDIF
        IF      CHECKED*(1-FAST)
        JR      Z,next0         ; 7Fh, DEL: ignored
        JP      NC,e_hi         ; 80h-FFh: reserved
        ENDIF
        IF      1-FAST
        SUB     1Ah             ; 7Bh-7Eh: -1Eh in all, index 28-31
p5b:    SUB     9               ; 5Bh-60h: -4 in all, index 22-27
p3a:    ADD     A,5             ; 3Ah-40h: index 15-21
        ENDIF

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
        IF      1-FAST
punct:  ADD     A,PTAB & 0FFh   ; PTAB never crosses a page
        LD      E,A
        LD      D,PTAB / 256    ; (0 if the table is in page zero)
        CP      (PTAB & 0FFh) + NPG1 ; carry: one of the first NPG1
        LD      A,(DE)
        LD      E,A             ; the handler's low byte
        ENDIF
        IF      (1-CPM)*(1-TABP0)*(1-FAST)
        LD      D,0
        ENDIF
        IF      (1-CPM)*(1-FAST)
        RL      D               ; its page: 0 + carry
        ENDIF
        IF      CPM*(1-FAST)
        LD      D,1
        JR      NC,pu1
        INC     D               ; its page: 1 + carry
pu1:
        ENDIF
        IF      1-FAST
        PUSH    DE              ; jump to it; the stack is balanced again
        RET                     ;   when the handler starts
        ENDIF

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
        NEGH                    ; minus the heap's first address: '_' may not
        LD      (NPEND),HL      ;   release below it
        ENDIF
        IF      (1-CHECKED)*(1-EDITOR)*(1-CPM)
        LD      H,A             ; (A = 0) no key is held, and the break key
        LD      L,A             ;   is on (the checked build has cleared
        ENDIF                   ;   these)
        IF      (1-CHECKED)*(1-EDITOR)*CPM
        LD      HL,0
        ENDIF
        IF      (1-CHECKED)*(1-EDITOR)
        LD      (KEYBUF),HL
        ENDIF
        IF      1-EDITOR
        SETIX
        LD      IY,RSTOP        ; the return stack is empty
        NEXT                    ; (its return address is thrown away)
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
        NEXT       

h_or:   POP     DE
        LD      A,H
        OR      D
        LD      H,A
        LD      A,L
        OR      E
        LD      L,A
        NEXT       

h_not:  NEGH                    ; ~x = -x - 1
        DEC     HL
        NEXT       

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
        NEXT       

        IF      1-CPM*CHECKED
exec:   LD      (RSAVE),IY      ; machine code may change IX and IY
        CALL    jphl
        LD      IY,(RSAVE)
        SETIX
        POP     HL
        NEXT       
        ENDIF

; ---- the letters and digits (here, in the middle, so that the inner loop's
; ---- short jumps reach them, and the handlers after them reach rpushn) ------

; Digits: step back onto the first digit and read the whole number.
digit:  PUSH    HL
        DEC     BC
        CALL    rdnum
        NEXT       

; a-z: push the cell's address (the cell is the variable)
;  (the unchecked builds with room do x@ and x! in one step: lowq)
        IF      1-QUICKU
lower:  PUSH    HL
        ADD     A,A
        LD      L,A
        LD      H,LETPAGE
        NEXT       
        ENDIF
        IF      QUICKU
lower:  JP      lowq
        ENDIF

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
;
; The break key is looked at here, so at every word call and loop-back (and
; block entry and '{'), but only one time in 256: PCNT counts them.
; Reading the keyboard can be slow (it is a BDOS call under CP/M).
rpushn: POP     DE
        LD      (IY-1),D
        LD      (IY-2),E
        DEC     IY
        DEC     IY
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL              ; (the zero flag lasts)
        CALL    Z,pollk
        NEXT       
; '{' TOS to the return stack: the new TOS comes up, the old one goes across.
h_tor:  EX      (SP),HL
        JR      rpushn
jphl:   JP      (HL)            ; (for the machine-code call)

; ---- machine code: the grave -----------------------------------------------
; '`' plus a hex digit loads bytes: ( addr -- addr' ). Pairs of hex digits
; are stored from addr until a non-hex character; then a RET (C9h) is
; written and its address is left. An odd last digit is consumed and dropped.
; '`' plus anything else calls the machine code at TOS: ( addr -- ). The
; code is entered by CALL with the data stack above the return address; it
; must keep BC, and on return the top cell becomes the new TOS.
h_grave:CALL    hexc
        IF      1-CPM*CHECKED
        JR      NC,exec
        ENDIF
        IF      CPM*CHECKED
        JP      NC,exec         ; (out of the way: see rpop)
        ENDIF
hx1:    LD      (HL),A          ; the high digit goes in first ...
        CALL    hexc
        JR      NC,hx2          ; odd digit: consumed, and the RET below
        RLD                     ;   overwrites it
        INC     HL              ; ... and RLD shifts it up under the low one
        CALL    hexc
        JR      C,hx1
hx2:    LD      (HL),0C9h       ; (never range-checked: the spec says so)
        NEXT       

; ---- where the two pages meet ----------------------------------------------
; The first page ends somewhere among the next four handlers, ] \ [ @ (they
; are in falling code order for this), and where exactly differs between the
; builds: NPG1 follows. Every handler below these four must start in the
; second page, and every one above in the first; chktab.py checks both.

; ']' returns: pop an address and jump to it.
h_ret:  POPR       
        LD      B,D
        LD      C,E
brk1:   NEXT       

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
h_break:LD      A,H
        OR      L
        POP     HL
        JR      Z,brk1
        CALL    skip
        OR      A               ; skip returns 0 for ')'
        JR      NZ,h_ret
rdrop:  POPR       
        NEXT       

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
        NEXT       

h_fetch:LD      E,(HL)          ; '@'
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        NEXT       


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
        IF      QK
        JP      closeq          ; (out of the handlers' pages: see Speed-ups)
        ENDIF
        IF      1-QK
        POPR                    ; pop the block start ...
        LD      B,D
        LD      C,E
        PUSH    BC
        ENDIF
        IF      (1-QK)*(1-CPM)
        JR      rpushn          ; ... and push it back
        ENDIF
        IF      (1-QK)*CPM
        JP      rpushn
        ENDIF

; ---- arithmetic and logic: ( NOS TOS -- result ) ---------------------------

; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  LD      A,(BC)
        SUB     '0'
        CP      10
        JR      C,negnum
        NEGH                    ; a - b = a + (-b): fall into '+'
h_add:  POP     DE
        ADD     HL,DE
        NEXT       
negnum: PUSH    HL              ; a negative number: read it, negate it
        CALL    rdnum
        NEGH       
        NEXT       

h_and:  POP     DE
        LD      A,H
        AND     D
        LD      H,A
        LD      A,L
        AND     E
        LD      L,A
        NEXT       


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
        NEXT       

h_eq:   POP     DE
        OR      A
        SBC     HL,DE
        LD      A,H
        OR      L
        CP      1               ; carry only if a - b = 0
        JR      tf

; '*': shift-and-add, 16 rounds; only the low 16 bits are kept. The
; multiplier shifts up through A:C.
        IF      1-QK
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
        NEXT       
        ENDIF
        IF      QK
h_mul:  POP     DE              ; DE = multiplicand
        JP      mulq            ; (out of the handlers' pages: see Speed-ups)
        ENDIF

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
        PUSH    DE              ; q under r
        NEXT       

; ---- stack and storage -----------------------------------------------------

h_dup:  PUSH    HL              ; ':'
        NEXT       

h_swap: EX      (SP),HL         ; '%'
        NEXT       

; (The checked build tests the address before it takes the value off the
; stack, so that an error report shows both.)
h_cstore:                       ; '.' ( c addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        POP     DE
        LD      (HL),E
h_drop: DROP                    ; ';' is this one byte

h_store:                        ; '!' ( n addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        POP     DE
        LD      (HL),E
        INC     HL
        LD      (HL),D
        DROP       


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
        NEXT       

; '$' prints the string at TOS, decoding escapes: '/' plus a character from
; 60h to 7Eh is one of the escapes at pesc; '/' plus any other character
; clears that character's bit 6 (/M is CR, and / then DEL gives '?'; '/',
; '"' and '?' have no bit 6, so //, /" and /? give themselves).
        IF      1-CHECKED
h_print:LD      A,(HL)
        INC     HL
        CP      22h
        JR      Z,pr9
        CP      '/'
        JR      NZ,pr1
        LD      A,(HL)
        INC     HL
        CP      60h
        JR      C,pr0
        CP      7Fh
        JR      C,pesc
pr0:    AND     0BFh
pr1:    PUTA       
        JR      h_print
PRLOOP  EQU     h_print         ; (where the escapes go back to)
PRAGAIN EQU     h_print         ; (and where /~ goes back to)
        ENDIF
        IF      CHECKED
; (The checked build has the loop as a routine, prstr, which the error
; report uses too. The address is kept meanwhile, for a report: it shows
; the stack as it was before the '$'. /~ comes back to hp1.)
h_print:LD      (RSAVE),HL
hp1:    CALL    prstr
        DROP       
        ENDIF

h_emit: LD      A,L             ; "'"
        PUTA       
pr9:    DROP       

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  CALL    psgn
        DROP       

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
        NEXT       

        ; Backspace takes the last character back (and is echoed as it
        ; is), CR ends (stored, not echoed), every other key is stored and
        ; echoed until the line is full. (CP/M too: getk reads through BDOS
        ; 6.) The line buffer starts at offset 80h of its page, so L alone
        ; is the place in the line: D holds the L of a full line.
line:   LD      DE,127          ; TOS is minus the count: adding 127 carries
        ADD     HL,DE           ;   only for 1 to 127, and leaves 127 - count
        SBC     A,A
        AND     L               ; (0 for a count that is too big)
        CPL
        LD      D,A             ; D = the L of a full line: 80h + count, FFh
                                ;   at most
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
ln3:    PUTA       
        JR      ln2
ln4:    DEC     L               ; Backspace: one back, and echo it,
        JP      M,ln3           ;   unless the line was empty (L left the
        INC     L               ;   upper half of the page)
        JR      ln2
ln5:    LD      (HL),A          ; the CR
        LD      L,LINEBUF & 0FFh
        NEXT       

; =============================================================================
;  More routines (no handler starts past this point)
; =============================================================================

        IF      CHECKED
; prstr: print the string at HL, to its closing quote, decoding '/' (this is
; '$', and the texts of the report). A NUL first is an error: Q.
prstr:  LD      A,(HL)
        INC     HL
        CP      22h
        RET     Z
        OR      A
        JP      Z,e_dollar
        CP      '/'
        JR      NZ,prs1
        LD      A,(HL)
        INC     HL
        CP      60h
        JR      C,prs0
        CP      7Fh
        JR      C,pesc
prs0:   AND     0BFh
prs1:   PUTA       
        JR      prstr
PRLOOP  EQU     prstr           ; (where the escapes go back to)
PRAGAIN EQU     hp1             ; (and where /~ goes back to)

; pmsg: print the text that follows the CALL, to its closing quote. Keeps HL.
; pnl: the same, on a new line.
pnl:    CALL    pmsg            ; (pmsg's own CR LF, then on into pmsg for
        DB      13,10,22h       ;   the caller's text)
pmsg:   EX      (SP),HL
        CALL    prstr
        EX      (SP),HL
        RET
        ENDIF

; pesc: the escapes of '$'. A = the character after the '/', 60h to 7Eh, and
; HL points past it. Each goes back into the loop that prints the string
; (PRLOOP), but /~ has the stack to see to, and goes back by PRAGAIN.
;    /a-/z   print the variable, as '#' does
;    /{      clear the screen, the cursor to the top left
;    /}      clear from the cursor to the end of the line
;    /|  /`  show the cursor, hide it
;    /~      ( row col -- ) the cursor to that row and column, from 0
pesc:   CP      7Eh
        JR      Z,pat
        LD      DE,PRLOOP       ; the others return into the loop
        PUSH    DE
        SUB     7Bh             ; { 0, | 1, } 2, and no borrow
        JR      NC,pcon
        ADD     A,1Ah           ; a-z: 0-25, and a carry; `: FFh, and none
        JR      NC,phide
        ADD     A,A             ; the variable's cell
        ADD     A,40h
        PUSH    HL
        LD      L,A
        LD      H,LETPAGE
        LD      A,(HL)
        INC     L
        LD      H,(HL)
        LD      L,A
        CALL    psgn
        POP     HL
        RET

; /~ ( row col addr -- ): the two cells under the string's address go. In
; the checked build '$' is the routine prstr: its own return address goes
; first, and hp1 calls it again afterwards. There each /~ first looks that
; its two cells are there, and is s if not, before it prints anything.
pat:
        IF      CHECKED
        EX      (SP),HL         ; the text pointer over prstr's return address
        LD      HL,(6-DSTOP)&0FFFFh ; a carry: the two cells aren't there
        ADD     HL,SP
        JP      C,e_under
        POP     HL
        ENDIF
        POP     DE              ; DE = the column
        EX      (SP),HL         ; HL = the row; the text pointer is kept
        IF      1-ANS
        CALL    CONAT
        POP     HL
        JP      PRAGAIN

; With ANSI = 0 the machine's routines do the rest.
pcon:   JP      Z,CONCLS        ; /{
        CP      2
        JP      Z,CONEOL        ; /}
        DB      0FEh            ; /|  (CP n steps over the XOR: A = 1, show)
phide:  XOR     A               ; /`  (A = 0: hide)
        JP      CONCUR
        ENDIF
        IF      ANS
        PUSH    DE
        CALL    csi             ; ESC [ row+1 ; col+1 H (ANSI counts from 1)
        INC     HL
        CALL    pdec
        PUTK    3Bh             ; ';'
        POP     HL
        INC     HL
        CALL    pdec
        PUTK    48h             ; 'H'
        POP     HL
        JP      PRAGAIN

; With ANSI = 1 they are sequences. The carry is clear on the way in.
pshow:  LD      E,'h'           ; /|  ESC [ ? 2 5 h
        DB      0DAh            ; (JP C,nn: with no carry it steps over two bytes)
phide:  LD      E,'l'           ; /`  ESC [ ? 2 5 l
        ENDIF
        IF      ANS*CHECKED
; (The checked build prints the fixed parts with pmsg, which it has for the
; report: shorter than a character at a time.)
        CALL    pmsg
        DB      27,'[?25',22h
pse:    LD      A,E             ; then E
        PUTAR

; pcon: /{ /| /}, with A = 0, 1, 2. /{ runs on into cse.
pcon:   DEC     A
        JR      Z,pshow         ; /|
        LD      E,'K'
        JP      P,cse           ; /}  ESC [ K
        LD      E,'H'           ; /{  ESC [ H ESC [ J
        CALL    cse
        LD      E,'J'           ; (on into cse)
; cse: ESC [ and then E. csi: ESC [. Both keep HL.
cse:    CALL    csi
        JR      pse
csi:    CALL    pmsg
        DB      27,'[',22h
        RET
        ENDIF
        IF      ANS*(1-CHECKED)
        LD      A,'?'
        CALL    csia
        PUTK    32h             ; '2'
        PUTK    35h             ; '5'
        LD      A,E
        PUTAR

; pcon: /{ /| /}, with A = 0, 1, 2. /{ runs on into csia.
pcon:   DEC     A
        JR      Z,pshow         ; /|
        LD      A,'K'
        JP      P,csia          ; /}  ESC [ K
        LD      A,'H'           ; /{  ESC [ H ESC [ J
        CALL    csia
        LD      A,'J'           ; (on into csia)
; csia: ESC [ and then A. csi: ESC [, keeping A.
csia:   CALL    csi
        PUTAR
csi:    PUSH    AF
        PUTK    1Bh             ; ESC
        PUTK    5Bh             ; '['
        POP     AF
        RET
        ENDIF

; udiv: unsigned HL / DE (DE <= 8000h). Returns HL = quotient, DE = remainder.
; Uses A; keeps BC (the IP) itself. The dividend shifts up through A:C while
; the quotient bits arrive at the bottom of C.
; Dividing by 2 is one shift (the spec wants that fast).
        IF      1-QK
udiv:   LD      A,E
        XOR     2
        OR      D
        JR      NZ,udv0
        SRL     H
        RR      L               ; the quotient
        ADC     A,A
        LD      E,A             ; the remainder: the bit that fell out (D is 0)
        RET
        ENDIF
        IF      QK
; (The builds with room divide by any power of two with shifts: 2, and 32,
; 64, 256 and the like, which fixed point and byte work use all the time.)
udiv:   LD      A,D
        OR      A
        JR      NZ,uq1          ; 256 and up
        OR      E
        JR      Z,udv0          ; by 0: the long way (it means nothing anyway)
        DEC     A
        AND     E
        JR      NZ,udv0         ; not a power of two
        LD      A,E             ; by 2^k below 256: q = HL >> k, and
        DEC     A               ;   r = L & (2^k - 1)
        AND     L
        PUSH    AF
uq2:    SRL     E
        JR      C,uq3
        SRL     H
        RR      L
        JR      uq2
uq3:    POP     AF
        LD      E,A
        LD      D,0
        RET
uq1:    LD      A,E
        OR      A
        JR      NZ,udv0
        LD      A,D
        DEC     A
        AND     D
        JR      NZ,udv0         ; not a power of two
        LD      A,D             ; by 2^k, 256 and up: q = H >> (k - 8), and
        DEC     A               ;   r = HL & (2^k - 1)
        AND     H
        LD      E,A             ; (the remainder's high byte,
        LD      A,L             ;   and its low byte)
        LD      L,H
        LD      H,0
uq4:    SRL     D
        JR      C,uq5
        SRL     L
        JR      uq4
uq5:    LD      D,E
        LD      E,A
        RET
        ENDIF
        IF      1-FAST
udv0:   PUSH    BC
        LD      A,H
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
        POP     BC
        RET
        ENDIF
        IF      FAST
; (the speed build: the same 16 rounds, unrolled)
udv0:   PUSH    BC
        LD      A,H
        LD      C,L
        LD      HL,0
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr0
        ADD     HL,DE
        DEC     C
uvr0:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr1
        ADD     HL,DE
        DEC     C
uvr1:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr2
        ADD     HL,DE
        DEC     C
uvr2:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr3
        ADD     HL,DE
        DEC     C
uvr3:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr4
        ADD     HL,DE
        DEC     C
uvr4:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr5
        ADD     HL,DE
        DEC     C
uvr5:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr6
        ADD     HL,DE
        DEC     C
uvr6:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr7
        ADD     HL,DE
        DEC     C
uvr7:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr8
        ADD     HL,DE
        DEC     C
uvr8:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr9
        ADD     HL,DE
        DEC     C
uvr9:   INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr10
        ADD     HL,DE
        DEC     C
uvr10:  INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr11
        ADD     HL,DE
        DEC     C
uvr11:  INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr12
        ADD     HL,DE
        DEC     C
uvr12:  INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr13
        ADD     HL,DE
        DEC     C
uvr13:  INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr14
        ADD     HL,DE
        DEC     C
uvr14:  INC     C
        SLA     C
        RLA
        ADC     HL,HL
        SBC     HL,DE
        JR      NC,uvr15
        ADD     HL,DE
        DEC     C
uvr15:  INC     C
        EX      DE,HL           ; DE = remainder
        LD      H,A
        LD      L,C             ; HL = quotient
        POP     BC
        RET
        ENDIF

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
; quote counts as running into it. '\' takes either closer. SKPL keeps the
; place where the skip started, for the report.
        IF      1-QK
; (Without QUICK: no skip cache.)
skip:
        ENDIF
        IF      CHECKED*(1-QK)
        LD      (SKPL),BC
        DEC     BC
        LD      A,(BC)
        INC     BC
        LD      E,A             ; E = the opener: ( [ or \
        ENDIF
        IF      1-QK
        LD      D,0
sk3:    INC     D               ; an opener: one deeper
sk1:    LD      A,(BC)
        ENDIF
        IF      (1-CHECKED)*(1-QK)
        INC     BC
        OR      A
        JP      Z,SKEND         ; (the end of the program)
        ENDIF
        IF      CHECKED*(1-QK)
        OR      A
        JR      Z,sk6           ; (the IP stays on the NUL)
        INC     BC
        ENDIF
        IF      1-QK
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
        ENDIF
        IF      (1-CHECKED)*(1-QK)
        RET     Z               ; the closer at this level
        JR      sk1
        ENDIF
        IF      CHECKED*(1-QK)
        JR      NZ,sk1
        LD      D,A             ; the closer at this level: 0 or 2. Bit 1 of the
        XOR     E               ;   opener is 0 for '(' and 1 for '[', and only
        AND     6               ;   '\' has bit 2: so this is 2 for the wrong
        CP      2               ;   closer, and only then
        LD      A,D
        RET     NZ
        JR      sk7
sk6:    BIT     2,E             ; the text ran out:
        JP      NZ,SKEND        ;   '\' with no closer ends the program
sk7:    LD      BC,(SKPL)       ; N. The place is the opener
        LD      A,'N'
        JP      errp            ; (errp drops skip's return address)
        ENDIF
        IF      QK
; The skip cache. Nearly every skip is one that has happened before (a loop
; skips the same false block on every pass), so the first scan from each
; place is remembered: 64 entries of {start, end}, at CPAGE, found by the
; start's low byte. Only skips that start in the program text are kept (the
; line buffer changes); the cache is emptied whenever a run starts (skclr).
; A program that changes its own text while it runs is not looked after.
skip:   LD      (SKPL),BC       ; where it starts: the cache's key (and the
        LD      A,B             ;   checked report's place)
        CP      PROG/256
        JR      C,sks           ; below the program text: no cache
        LD      A,C
        ADD     A,A
        ADD     A,A
        LD      E,A
        LD      D,CPAGE         ; DE -> the entry
        LD      A,(DE)
        CP      C
        JR      NZ,sks
        INC     E
        LD      A,(DE)
        CP      B
        JR      NZ,sks
        INC     E
        LD      A,(DE)
        LD      C,A
        INC     E
        LD      A,(DE)
        LD      B,A             ; a hit: the IP is past the closer
        DEC     BC
        LD      A,(BC)
        INC     BC
        SUB     ')'             ; 0 for ')', not 0 for ']'
        RET
sks:
        ENDIF
        IF      QK*CHECKED
        DEC     BC
        LD      A,(BC)
        INC     BC
        LD      E,A             ; E = the opener: ( [ or \
        ENDIF
        IF      QK
; The scan. Most characters are nothing to it, and two range tests rule
; them out: * to Z, and ^ and up. Only NUL " ( ) [ ] count.
        LD      D,0
sq3:    INC     D               ; an opener: one deeper
sq1:    LD      A,(BC)
        INC     BC
        CP      5Eh
        JR      NC,sq1          ; ^ _ ` a-z { | } ~ and up: nothing
        CP      5Bh
        JR      NC,sqb          ; [ \ ]
        CP      2Ah
        JR      NC,sq1          ; * to Z: nothing
        CP      28h
        JR      Z,sq3           ; (
        JR      NC,sqc          ; )
        CP      22h
        JR      Z,sqq           ; a string
        OR      A
        JR      NZ,sq1          ; the rest below '(': nothing
        ENDIF
        IF      QK*(1-CHECKED)
        JP      SKEND           ; NUL: the end of the program
        ENDIF
        IF      QK*CHECKED
        DEC     BC              ; NUL: the IP stays on it
        BIT     2,E             ; the text ran out:
        JP      NZ,SKEND        ;   '\' with no closer ends the program
sq7:    LD      BC,(SKPL)       ; N. The place is the opener
        LD      A,'N'
        JP      errp            ; (errp drops skip's return address)
        ENDIF
        IF      QK
sqq:    CALL    skipstr         ; step over the string
        JR      sq1
sqb:    SUB     5Ch             ; [ -1, \ 0, ] 1
        JR      Z,sq1           ; '\' is nothing here
        JR      C,sq3           ; [
        LD      A,2             ; ]
        JR      sq4
sqc:    XOR     A               ; )
sq4:    DEC     D
        JR      NZ,sq1
        ENDIF
        IF      QK*CHECKED
        LD      D,A             ; the closer at this level (as above): 2 here
        XOR     E               ;   means the wrong closer
        AND     6
        CP      2
        LD      A,D
        JR      Z,sq7
        ENDIF
        IF      QK
; The closer at this level: remember the skip (if it started in the program
; text), and return A = 0 for ')' or 2 for ']'.
        PUSH    AF
        PUSH    HL
        LD      HL,(SKPL)
        LD      A,H
        CP      PROG/256
        JR      C,sq9
        LD      A,L
        ADD     A,A
        ADD     A,A
        LD      E,A
        LD      D,CPAGE
        LD      A,L
        LD      (DE),A
        INC     E
        LD      A,H
        LD      (DE),A
        INC     E
        LD      A,C
        LD      (DE),A
        INC     E
        LD      A,B
        LD      (DE),A
sq9:    POP     HL
        POP     AF
        RET
; skclr: empty the skip cache (a start of 0000h matches no skip). Keeps HL.
skclr:  PUSH    HL
        LD      HL,CPAGE*256
skc1:   LD      (HL),0
        INC     L
        JR      NZ,skc1
        POP     HL
        RET
        ENDIF
;  ---- Speed-ups (QUICK builds) -------------------------------------------
;  The skip cache is above. These are the handlers' tails that the builds with
;  room take, kept here, out of the handlers' first two pages.
        IF      QK
; '*' with an operand below 256 takes 8 rounds, not 16: that one becomes the
; multiplier (most multiplications have one, a count or a small constant).
mulq:   LD      A,H
        OR      A
        JR      Z,mq8           ; the multiplier is below 256
        LD      A,D
        OR      A
        JR      NZ,mq16
        EX      DE,HL           ; the multiplicand is: it becomes the multiplier
        ENDIF
        IF      QK*(1-FAST)
mq8:    LD      A,L
        LD      HL,0
        PUSH    BC
        LD      B,8
mq1:    ADD     HL,HL
        RLA
        JR      NC,mq2
        ADD     HL,DE
mq2:    DJNZ    mq1
        POP     BC
        NEXT       
mq16:   PUSH    BC              ; 16 rounds; the multiplier shifts up through A:C
        LD      A,H
        LD      C,L
        LD      HL,0
        LD      B,16
mq3:    ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mq4
        ADD     HL,DE
mq4:    DJNZ    mq3
        POP     BC
        NEXT       
        ENDIF
        IF      FAST
; (the speed build: the same rounds, unrolled)
mq8:    LD      A,L
        LD      HL,0
        ADD     HL,HL
        RLA
        JR      NC,mur0
        ADD     HL,DE
mur0:
        ADD     HL,HL
        RLA
        JR      NC,mur1
        ADD     HL,DE
mur1:
        ADD     HL,HL
        RLA
        JR      NC,mur2
        ADD     HL,DE
mur2:
        ADD     HL,HL
        RLA
        JR      NC,mur3
        ADD     HL,DE
mur3:
        ADD     HL,HL
        RLA
        JR      NC,mur4
        ADD     HL,DE
mur4:
        ADD     HL,HL
        RLA
        JR      NC,mur5
        ADD     HL,DE
mur5:
        ADD     HL,HL
        RLA
        JR      NC,mur6
        ADD     HL,DE
mur6:
        ADD     HL,HL
        RLA
        JR      NC,mur7
        ADD     HL,DE
mur7:
        NEXT       
mq16:   PUSH    BC
        LD      A,H
        LD      C,L
        LD      HL,0
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus0
        ADD     HL,DE
mus0:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus1
        ADD     HL,DE
mus1:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus2
        ADD     HL,DE
mus2:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus3
        ADD     HL,DE
mus3:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus4
        ADD     HL,DE
mus4:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus5
        ADD     HL,DE
mus5:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus6
        ADD     HL,DE
mus6:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus7
        ADD     HL,DE
mus7:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus8
        ADD     HL,DE
mus8:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus9
        ADD     HL,DE
mus9:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus10
        ADD     HL,DE
mus10:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus11
        ADD     HL,DE
mus11:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus12
        ADD     HL,DE
mus12:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus13
        ADD     HL,DE
mus13:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus14
        ADD     HL,DE
mus14:
        ADD     HL,HL
        SLA     C
        RLA
        JR      NC,mus15
        ADD     HL,DE
mus15:
        POP     BC
        NEXT       
        ENDIF
        IF      QK
; A true ')' reads the block start where it is, on top of the return stack,
; instead of popping it and pushing it back; the break key is looked at as
; rpushn would.
closeq: LD      C,(IY+0)
        LD      B,(IY+1)
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXT       
        ENDIF
        IF      QUICKU
; a-z, in the unchecked builds: a variable followed by '@' or '!' is fetched
; or stored in the same step (x@ is the commonest pair in most programs).
; (A checked build checks the stacks between the two, so it keeps them apart.)
lowq:   ADD     A,A
        LD      E,A
        LD      D,LETPAGE       ; DE -> the cell
        LD      A,(BC)
        CP      '@'
        JR      Z,lwf
        CP      '!'
        JR      Z,lws
        PUSH    HL
        EX      DE,HL           ; TOS = the cell's address
        NEXT       
lwf:    INC     BC              ; x@: TOS = the cell's value
        PUSH    HL
        EX      DE,HL
        LD      E,(HL)
        INC     L
        LD      D,(HL)
        EX      DE,HL
        NEXT       
lws:    INC     BC              ; x!: the cell = TOS, and NOS comes up
        EX      DE,HL
        LD      (HL),E
        INC     L
        LD      (HL),D
        POP     HL
        NEXT       
        ENDIF
        IF      (1-CPM)*(1-EDITOR)*(1-CHECKED)*QK
qstart: LD      BC,PROG         ; the generic reset goes on here: the IP,
        CALL    skclr           ;   an empty skip cache, and the rest of the
        JP      st0             ;   startup
        ENDIF
        IF      (1-CPM)*(1-EDITOR)*CHECKED*QK
qinit:  CALL    skclr           ; (keeps A, which init wants 0)
        JP      init
        ENDIF

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
        IF      (1-TABP0)*(1-PTLATE)
PTAB:
        PTABLE
PTABEND:
        ENDIF

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

; psgn: print HL as a signed number. Keeps BC.
psgn:   BIT     7,H
        JR      Z,pdec
        PUTK    2Dh             ; '-'
        NEGH       
; pdec: print HL unsigned, by recursion on HL / 10 (the stack holds digits).
; Keeps BC.
pdec:   LD      DE,10
        CALL    udiv            ; HL = HL / 10, E = the last digit
        LD      A,E
        PUSH    AF
        LD      A,H
        OR      L
        CALL    NZ,pdec
        POP     AF
        ADD     A,'0'
        PUTAR

; (The table goes here instead in the builds where, before psgn, it would
; cross a page: PTLATE. If it would cross one here too, it starts on the next
; page: PTPAD is 0 unless it must.)
        IF      (1-TABP0)*PTLATE
PTPH    EQU     $ & 0FFh
PTPX    EQU     (PTPH + 31) / 256
PTPAD   EQU     PTPX * (256 - PTPH)
        DS      PTPAD
PTAB:
        PTABLE
PTABEND:
        ENDIF

; =============================================================================
;  Console layer. rawk is the host's key routine: a waiting key in A (zero
;  flag clear), or A = 0 with the zero flag set when none is waiting. putc
;  (RST 28h) prints A. Both keep BC, DE, HL and IY. In the generic build
;  they are the host's KEY and CONOUT routines themselves.
;
;  A running program reads the keyboard only through getk and pollk, which
;  between them give the break key its rules:
;    - Ctrl-C stops the program;
;    - any other key that the break check reads is held in KEYBUF for the
;      next '?', and a newer one takes its place;
;    - '?' (getk) takes the held key first;
;    - a program that has stored a non-zero byte at BRKOFF gets Ctrl-C as a
;      key like any other, but two of them within about 250 ms still stop it.
;  Both are called straight from a handler, never from a routine under one:
;  the checked build's report counts on finding one return address above the
;  data stack.
; =============================================================================
        IFN     CPM
rawk    EQU     KEY
        ENDIF
; pollk: the break check (see rpushn).
pollk:  CALL    rawk
        RET     Z               ; no key
        LD      (KEYBUF),A      ; held for the next '?'
pk1:    CP      3               ; (getk joins here)
        RET     NZ
; ctlc: Ctrl-C has been read. If the break key is on, that is the end. If
; the program has turned it off, wait about 250 ms for one more key: a
; second Ctrl-C is the end too; any other key is held (the newest wins),
; and the Ctrl-C goes to the program: returns A = 3, zero flag clear.
ctlc:   LD      A,(BRKOFF)
        OR      A
ct0:    JP      Z,brk
        PUSH    DE
        LD      DE,250*MSLOOP
ct1:    CALL    rawk
        JR      NZ,ct2
        DEC     DE
        LD      A,D
        OR      E
        JR      NZ,ct1
ct2:    POP     DE              ; A = the second key, or 0 if none came
        CP      3
        JR      Z,ct0           ; (the zero flag takes the JP there)
        OR      A
        JR      Z,ct3
        LD      (KEYBUF),A
ct3:    LD      A,3
        OR      A
        RET
; getk: a key for '?', or A = 0 and the zero flag if there is none.
getk:   PUSH    HL              ; a held key goes first, and is taken out of
        LD      HL,KEYBUF       ;   the buffer
        LD      A,(HL)
        LD      (HL),0
        POP     HL
        OR      A
        RET     NZ
        CALL    rawk
        RET     Z
        JR      pk1             ; Ctrl-C? If not, that is the key
        IF      (1-CHECKED)*(1-EDITOR)
brk     EQU     endprog         ; the unchecked build stops without a word
        ENDIF                   ;   (with the editor, both stacks are cleared);
        IF      (1-CHECKED)*EDITOR
brk     EQU     edit0
        ENDIF
        IF      CHECKED
brk     EQU     e_break         ;   the checked build reports B
        ENDIF
        IF      CPM
; The routines a generic build keeps in page zero (see there). Here they are
; out of the way of the handlers, which must fit in the image's first two
; pages.
rpop:   LD      E,(IY+0)        ; pop the return stack into DE
        LD      D,(IY+1)
        INC     IY
        INC     IY
        RET
neg16:  XOR     A               ; HL = -HL (keeps BC, DE)
        SUB     L
        LD      L,A
        SBC     A,A
        SUB     H
        LD      H,A
        RET
        ENDIF
        IF      CPM*CHECKED     ; (the checked builds need the room)
exec:   LD      (RSAVE),IY      ; machine code may change IX and IY
        CALL    jphl
        LD      IY,(RSAVE)
        SETIX
        POP     HL
        NEXT       
        ENDIF
        IF      CPM
rawk:   LD      A,0FFh          ; BDOS 6 with E = FFh: a key, or 0
        JR      putc
putk:   EX      (SP),HL         ; print the byte after the CALL
        LD      A,(HL)
        INC     HL
        EX      (SP),HL
; putc: BDOS 6 for every character. BDOS 2 would check for ^S while
; printing and could swallow a key that BDOS 6 then never sees.
; It keeps every register but A and the flags: BDOS may change any of them
; (IX and IY too, in a Z80 BDOS or BIOS).
putc:   PUSH    BC
        PUSH    DE
        PUSH    HL
        PUSH    IX
        PUSH    IY
        LD      E,A
        LD      C,6
        CALL    BDOS
        POP     IY
        POP     IX
        POP     HL
        POP     DE
        POP     BC
        OR      A               ; (for getk)
        RET
        ENDIF

; =============================================================================
;  Checked build: the checks and the error report
; =============================================================================
        IF      CHECKED
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
        PUSH    IY              ; the return stack: in its page (or it has
        POP     DE              ;   overflowed), and not above its empty
        LD      A,D             ;   position (an underflow stays inside the
        CP      RSPAGE          ;   page, in the guard band)
        LD      A,E
        JR      NZ,e_rover
        CP      RSTOP&0FFh+1
        RET     C
        LD      IY,RSTOP        ; return stack underflow: it counts as empty
        LD      A,'r'
        JR      errp
e_rover:LD      A,'R'           ; return stack overflow
        DB      11h             ; (LD DE,nn hides the next entry)
e_over: LD      A,'S'           ; data stack overflow
        JR      errp
e_under:LD      SP,DSTOP        ; data stack underflow: it counts as empty
        LD      A,'s'
        JR      error

; e_hi: the inner loop read a reserved byte, 80h-FFh: X. But a word cell that
; was never defined still holds 0000h, and the byte there is a reserved one
; in every build (AFh or C3h): if the IP is in page zero, this was a call of
; an undefined word. The call is undone, so the place is the call itself.
e_hi:   INC     B
        DJNZ    e_resv          ; (B is as it was, and is not 0)
        POPR       
        LD      B,D
        LD      C,E
        LD      A,'U'
        JR      error

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
        LD      A,'H'
        JR      errp

; chkst: stop unless HL is in the program's own space: from the letter page
; up to the heap limit (the OS, or HEAPLIM), so the interpreter's stacks and
; whatever lies above the limit are safe. Memory above the heap top but
; below the limit is the program's own: Tiny BASIC keeps its lines there.
; It is the page of HL + 1 that is tested, so that one test serves both
; bytes of a cell: the last byte below the limit can't be stored to with '.'.
; Keeps HL and BC. It runs on into its own error entry.
chkst:  INC     HL
        LD      A,H
        DEC     HL
        CP      LETPAGE
        JR      C,e_store
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
; Error entries. Each loads its letter and then hides the next entry inside
; a 3-byte LD DE,nn (the 11h), so they all fall through to `error`.
e_store:LD      A,'O'           ; a store outside the program's space
        DB      11h
e_break:LD      A,'B'           ; Ctrl-C (found inside pollk or getk)
; errp: an error found inside a routine: drop its return address first.
errp:   POP     DE
        JR      error
; e_dollar: '$' ran into a NUL (in prstr): Q, with the string's address
; back in TOS. prstr's return address goes first. But if '$' had no
; address at all (the stack was empty), it is s, found now: chkstk, called
; one cell up, sees the stack past its empty place then.
e_dollar:POP    DE
        POP     HL
        CALL    chkstk
        PUSH    HL
        LD      HL,(RSAVE)
        DB      11h             ; (LD DE,nn hides e_quote's first two bytes)
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
;   D:n: the top 8 cells at most, bottom to top
;   R:n
error:  PUSH    HL              ; now the whole data stack is in memory
        LD      E,A
        CALL    pnl
        DB      "Err ",22h
        LD      A,E
        PUTA       
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
        PUTK    2Ch             ; ','
        POP     DE
        POP     HL
        OR      A
        SBC     HL,DE
        INC     HL
        CALL    pdec            ; the column


; The two stack lines:  D:n: the top 8 cells at most, bottom to top
;                       R:n
; TOS is in memory with the rest (pushed) by now.
        CALL    pnl
        DB      "D:",22h
        LD      HL,DSTOP-2      ; (DSTOP-2) - SP is twice the depth (the cell
        SBC     HL,SP           ;   at DSTOP-2 was pushed with the first value
                                ;   and holds nothing; pnl left the carry clear)
        CALL    phalf           ; the depth
        PUTK    3Ah             ; ':'
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
        PUTK    20h             ; ' '
        EX      DE,HL
        CALL    psgn
        POP     HL
        JR      er7
er8:    CALL    pnl
        DB      "R:",22h
        PUSH    IY              ; RSTOP - IY is under 256 (the pointer is
        POP     HL              ;   at most one entry below its page), so
        LD      A,RSTOP&0FFh    ;   the low bytes are enough
        SUB     L
        LD      L,A
        LD      H,0
        CALL    phalf
        CALL    pnl
        DB      22h
        ENDIF
        IF      CHECKED*(1-EDITOR)
        JP      endprog
        ENDIF
        IF      CHECKED*EDITOR
        JR      edit0           ; back to the editor, with both stacks cleared
        ENDIF
        IF      CHECKED
; phalf: print half of HL, and leave it in C.
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
;  The interpreter starts here, and a program that ends comes back here.
;  There is no prompt. It follows the spec's suggested standard for a line
;  editor (docs/b8script.md, Environments). Type a line and press Return:
;
;    n text    put the text in as line n; the lines from n on move down. A
;              number past the end (or 0) adds the line at the end.
;    n         take line n out
;    anything else is run at once, as B8Script. (Start such a line with a
;    space if it would begin with a digit.)
;
;  A command key ends the line too, and takes what was typed as its argument:
;
;    ^G        run the program
;    n ^L      list from line n (no number: all of it). Any key holds the
;              list until another key is pressed; Ctrl-C ends it.
;    n ^E      put line n in the input line; Return puts it back, changed
;    name ^R   read. CP/M: the file of that name (no name: the same file as
;              last time). Generic: what is typed, or pasted, from now until
;              ^Z replaces the program; it is not echoed.
;    name ^W   write. CP/M: to that file (no name: the same file as last
;              time). Generic: the text is printed, as it is.
;    ^N        new: no program
;    ^X        leave (to LEAVE)
;
;  In the line: the left and right arrow keys move the cursor;
;  a character goes in at the cursor; Backspace and DEL take out the one
;  before it; Esc drops the line. Only CR, LF, BS and printing characters are
;  sent to the terminal, so any terminal will do.
;
;  Lines are counted, not numbered: the text holds no line numbers, and the
;  list shows each line's place. There can be 65535 lines. A typed line holds
;  125 characters; the one character after a line number separates it from
;  the text and is not stored. The text is kept as it is typed, each line
;  ending in CR LF, at PROG.
;
;  What lasts from one line to the next: the program, the words, the
;  variables and the data stack. An error or a break clears both stacks. The
;  return stack starts empty for every line.
;
;  Things to know:
;    - Reset empties the program (generic builds).
;    - A word's address points into the program, so run the program again
;      after editing it.
;    - Nothing is printed between a program's output and what is typed next.
;    - A line run at once sits in the line buffer, which -n? also reads into:
;      a line that calls -n? and carries on afterwards runs what was typed.
;      (The stored program never comes back to the line, so it may.)
;    - The editor's own keys are not the program's: -n? is the plain line
;      read of the other builds.
;
;  The data stack is the CPU's stack, so the editor works on top of whatever
;  the last line left there, with TOS pushed like the rest.
; =============================================================================
        IF      EDGEN
init:                           ; reset (A = 0)
        ENDIF
        IF      EDGEN*CHECKED
; Clear the lower half of the letter page: every variable starts at 0, and
; every word cell holds 0000h, the address an undefined word is caught at
; (see e_hi).
        LD      HL,LET
ini1:   LD      (HL),A
        INC     L
        JP      P,ini1          ; +00h to +7Fh
        ENDIF
        IF      EDGEN
        JR      edit0
        ENDIF
        IF      EDITOR
; Right arrow: one to the right, by printing the character there
right:  LD      A,L
        CP      E
        JR      Z,ed1           ; at the end
        LD      A,(HL)
        INC     L
        JR      lf1

; Esc: alone it drops the line. An arrow key sends Esc [ and a letter, so
; wait about 5 ms for a second key: after a '[' read on to the letter that
; ends the sequence, and act on C (right) and D (left).
esc:    LD      BC,5*MSLOOP
es1:    CALL    rawk
        JR      NZ,es2
        DEC     BC
        LD      A,B
        OR      C
        JR      NZ,es1
        CALL    fin             ; no second key: the line is dropped
        JR      edit
es2:    CP      '['
        JR      NZ,ed1          ; not a sequence known here
es3:    CALL    ekey
        CP      40h
        JR      C,es3           ; (its parameters)
        SUB     'C'
        JR      Z,right
        DEC     A               ; 'D'?
        JR      NZ,ed1          ; no: on into left
; Left arrow: the cursor goes one to the left
left:   LD      A,L
        ADD     A,A
        JR      Z,ed1           ; (L = 80h: at the start)
        DEC     L
        LD      A,8
lf1:    PUTA       
        JR      ed1

; edit0: reset, an error or a break: both stacks are cleared, and the cursor
;   is shown, in case the program had hidden it and could not show it again.
; skend: a program that ended inside skip: its return address goes.
; edend: a program that ended: TOS joins the rest of the data stack.
edit0:  LD      SP,DSTOP-2      ; empty (the cell that stands for TOS is pushed)
        ENDIF
        IF      EDITOR*ANS
        XOR     A               ; (pshow wants the carry clear)
        CALL    pshow           ; ESC [ ? 2 5 h
        ENDIF
        IF      EDITOR*(1-ANS)
        LD      A,1
        CALL    CONCUR          ; show the cursor
        ENDIF
        IF      EDITOR
        DB      21h             ; (LD HL,nn: steps over the next two bytes)
skend:  POP     DE
edend:  PUSH    HL
; edit: start a new input line.
edit:   LD      IY,RSTOP        ; the return stack is empty
        SETIX                   ; (a file read or written may have changed IX)
        LD      HL,0
        LD      (KEYBUF),HL     ; no key is held, and the break key is on
        LD      (EDLN),HL       ; no line is being edited
        LD      HL,LINEBUF      ; HL = the cursor,
        LD      E,L             ;   E = the end of the line (its low byte)
ed1:    CALL    ekey
        CP      7Fh
        JR      Z,bsp           ; DEL
        CP      ' '
        JR      NC,insc
        CP      9
        JR      Z,insc          ; Tab is text
        CP      8
        JR      Z,bsp
        CP      1Bh
        JR      Z,esc
        PUSH    HL              ; a command key? Look it up
        LD      HL,cmds
        LD      B,NCMD
ed2:    CP      (HL)
        INC     HL
        JR      Z,ed3
        INC     HL
        INC     HL
        DJNZ    ed2
        POP     HL
        JR      ed1             ; no: the key is ignored
ed3:    LD      A,(HL)
        INC     HL
        LD      H,(HL)
        LD      L,A
        EX      (SP),HL         ; the command's address: fin returns to it
; fin: end the input line: CR LF and a NUL after it, and a new line on the
; terminal. Leaves BC -> the line and HL -> the NUL.
fin:    LD      H,LETPAGE
        LD      L,E
        LD      (HL),13
        INC     L
        LD      (HL),10
        DEC     L
        CALL    prl             ; (prints the CR LF)
        LD      (HL),0
        LD      BC,LINEBUF
        RET

; Backspace, DEL: the character before the cursor goes. The cursor moves
; left, the rest of the line moves down over it, and the last place (now a
; space) is printed over along with the rest.
bsp:    LD      A,L
        ADD     A,A
        JR      Z,ed1           ; at the start
        DEC     L
        PUTK    08h             ; backspace
        PUSH    HL
bs1:    INC     L
        LD      A,(HL)
        DEC     L
        LD      (HL),A
        INC     L
        LD      A,L
        CP      E
        JR      NZ,bs1
        DEC     L
        LD      (HL),' '
        POP     HL
        LD      D,E
        DEC     E
        JR      ic2
; A character goes in at the cursor: it ripples up through the rest of the
; line, the cursor moves on, and the rest is printed again.
insc:   LD      B,A
        LD      A,E
        CP      0FDh
        JR      Z,ed1           ; the line is full: 125 characters
        LD      A,B
        PUTA       
        PUSH    HL
ic1:    LD      A,(HL)
        LD      (HL),B
        LD      B,A
        LD      A,L
        INC     L
        CP      E
        JR      NZ,ic1
        POP     HL
        INC     L
        INC     E
        LD      D,E
ic2:    CALL    tail
        JR      ed1
; tail: print the line from the cursor to D (a low byte), and bring the
; cursor back with backspaces. Nothing at all if the cursor is at D.
tail:   LD      C,L
ta1:    LD      A,L
        CP      D
        JR      Z,ta2
        LD      A,(HL)
        PUTA       
        INC     L
        JR      ta1
ta2:    LD      A,L
        CP      C
        RET     Z
        PUTK    08h             ; backspace
        DEC     L
        JR      ta2

; ekey: wait for a key
ekey:   CALL    rawk
        JR      Z,ekey
        RET

; The command keys, and where each goes (after fin).
cmds:   DB      13
        DW      cret
        DB      7               ; ^G
        DW      crun
        DB      12              ; ^L
        DW      clist
        DB      5               ; ^E
        DW      cedln
        DB      18              ; ^R
        DW      cread
        DB      23              ; ^W
        DW      cwrite
        DB      14              ; ^N
        DW      cnew
        DB      24              ; ^X
        DW      LEAVE
NCMD    EQU     8

; ^N: no program
cnew:   XOR     A
        LD      (PROG),A
ged0:   JR      gedit

; ^E: line n goes into the input line, to be changed. EDLN remembers which
; line it was: Return puts the text back in its place.
cedln:  CALL    rdnum
        PUSH    HL
        CALL    find            ; HL -> the line, or the NUL if there is none
        POP     DE
        LD      A,(HL)
        OR      A
        JR      Z,ged0
        LD      (EDLN),DE
        LD      DE,LINEBUF
ce1:    LD      A,(HL)          ; copy it, and show it, up to its CR (or LF)
        CP      13
        JR      Z,ce2
        CP      10
        JR      Z,ce2
        LD      (DE),A
        PUTA       
        INC     HL
        INC     E
        LD      A,E
        CP      0FDh            ; (a longer line is cut at 125 characters)
        JR      NZ,ce1
ce2:    EX      DE,HL           ; the cursor is at the line's end
        LD      E,L
        JP      ed1

; Return. If ^E put a line here, the text goes back in its place. If not:
; a number and text is a line to put in, a number alone a line to take out,
; and anything else is run where it is.
cret:   PUSH    HL              ; the end of what was typed
        LD      HL,(EDLN)
        LD      A,H
        OR      L
        JR      Z,cr1
        PUSH    HL
        CALL    delln
        POP     HL
        JR      ins
cr1:    CALL    rdnum           ; HL = the number it starts with, BC -> after
        LD      A,C             ; C is still 80h if there was no number:
        ADD     A,A             ;   only then is twice it 0
        JR      Z,st0p          ; no number: run the line
        LD      A,(BC)
        CP      13
        JR      NZ,cr2
        POP     DE              ; the number alone: take that line out
        CALL    delln
        JR      gedit
cr2:    INC     BC              ; step over the one character after the number

; Put the text at BC in as line n (in HL): open a gap of its length there,
; CR and LF included, and copy it in.
ins:    CALL    find            ; HL -> where it goes
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
gedit:  JP      edit

; ^G: run the program. st0p: run the typed line (BC -> it).
crun:   LD      BC,PROG
        DB      3Eh             ; (LD A,n: steps over the POP)
st0p:   POP     HL              ; (the end of what was typed)
; st0: start running at BC. The heap starts after the stored program's NUL.
st0:    LD      HL,PROG
        XOR     A
st1:    CP      (HL)
        INC     HL
        JR      NZ,st1
        LD      (HEAP),HL
        ENDIF
        IF      EDITOR*QK
        CALL    skclr           ; every run starts with an empty skip cache
        ENDIF
        IF      EDITOR*CHECKED
        NEGH                    ; minus the heap's first address: '_' may not
        LD      (NPEND),HL      ;   release below it
        ENDIF
        IF      EDITOR
        POP     HL              ; TOS: the data stack is as the last line left it
        NEXT                    ; (its return address is thrown away)

; ^L: list from line n. DE = the number of the line at HL.
clist:  CALL    rdnum           ; HL = n, or 0 if there was none:
        LD      A,H
        OR      L
        JR      NZ,li0
        INC     L               ;   then from line 1
li0:    PUSH    HL
        CALL    find
        POP     DE
li1:    LD      A,(HL)
        OR      A
        JR      Z,gedit         ; the end of the text
        CALL    rawk
        JR      Z,li3           ; no key: carry on
        CP      3
        CALL    NZ,ekey         ; any key but Ctrl-C: wait for one more
        CP      3
        JR      Z,gedit         ; Ctrl-C, first or second, ends the list
li3:    PUSH    HL
        PUSH    DE
        EX      DE,HL
        CALL    pdec            ; the line's number,
        LD      A,' '
        PUTA                    ;   a space,
        POP     DE
        POP     HL
        INC     DE
        CALL    prl             ;   and the line
        JR      li1

; delln: take line n (in HL) out: copy everything after it down over it.
delln:  CALL    find
        LD      D,H
        LD      E,L
        CALL    nxl             ; HL -> the next line
de1:    LD      A,(HL)
        LD      (DE),A
        INC     HL
        INC     DE
        OR      A
        JR      NZ,de1
        RET

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
        PUTA       
        LD      A,(HL)
        INC     HL
        CP      10
        JR      NZ,prl
        RET
        ENDIF

        IF      EDGEN
ged1:   JP      edit

; ^R, generic: what comes in from now until ^Z is the program. A CR is
; stored as CR LF; a LF right after a line end is dropped (it is the CR's
; own, or an empty line's), and a LF anywhere else ends a line too. A last
; line with no end is given one. Nothing is echoed, and there is no check
; for running out of memory.
cread:  LD      HL,PROG-1
        LD      (HL),10         ; (as if a line had just ended: the byte is
        INC     HL              ;   the line buffer's last, and spare)
rd1:    CALL    ekey
        LD      C,A
        CP      1Ah
        JR      NZ,rd2
        LD      A,10            ; ^Z ends the last line, as a LF would
rd2:    CP      10
        JR      NZ,rd3
        DEC     HL
        CP      (HL)
        INC     HL
        JR      Z,rd4           ; straight after a line end: dropped
        LD      A,13            ; anywhere else it ends the line
rd3:    LD      (HL),A
        INC     HL
        CP      13
        JR      NZ,rd4
        LD      (HL),10         ; after a CR goes a LF
        INC     HL
rd4:    LD      A,C
        CP      1Ah
        JR      NZ,rd1
        LD      (HL),0
        JR      ged1

; ^W, generic: the text is printed as it is, for the terminal to capture.
cwrite: LD      HL,PROG
cw1:    LD      A,(HL)
        OR      A
        JR      Z,ged1
        PUTA       
        INC     HL
        JR      cw1
        ENDIF

        IF      EDITOR*CPM
CFCB     EQU     005Ch           ; the file's name is kept here, where the CCP
                                ;   put the one from the command line
; ^W, CP/M: write the file: delete the old one, make it anew, write the
; text in records of 128 bytes, and close it. The text's NUL and the 127
; bytes after it are set to ^Z meanwhile, which pads the last record. (A
; full disk or directory is not noticed: the calls fail and that is all.)
cwrite: CALL    setname
        LD      C,19            ; delete
        CALL    fbdos
        LD      C,22            ; make
        CALL    fbdos
        LD      HL,PROG
        XOR     A
cw1:    CP      (HL)
        INC     HL
        JR      NZ,cw1
        DEC     HL              ; HL -> the NUL
        PUSH    HL
        LD      B,128
cw2:    LD      (HL),1Ah
        INC     HL
        DJNZ    cw2
        POP     HL
        LD      DE,PROG
cw3:    LD      A,E             ; a record that starts before the end is written
        SUB     L
        LD      A,D
        SBC     A,H
        JR      NC,cw4
        PUSH    HL
        LD      C,21            ; write, from where the record lies
        CALL    frec
        POP     HL
        JR      cw3
cw4:    LD      (HL),0          ; the NUL again
        LD      C,16            ; close
        CALL    fbdos
        JP      edit

; frec: BDOS function C (read or write a record) with the 128 bytes at DE.
; Returns A = the BDOS's answer, HL = DE and DE = DE + 128.
frec:   PUSH    DE
        PUSH    BC
        LD      C,26            ; set the DMA address
        CALL    BDOS
        POP     BC
        CALL    fbdos
        POP     DE
        LD      HL,128
        ADD     HL,DE
        EX      DE,HL
        RET

; setname: if a name was typed (the line does not start with its CR), put it
; in the FCB: up to 8 characters, a dot, up to 3 more, in capitals. The drive
; is the current one. Then, name or no name, clear the FCB after the name,
; as it must be before a file is opened or made.
setname:LD      DE,LINEBUF
        LD      A,(DE)
        CP      13
        JR      Z,fcbclr
        LD      HL,CFCB
        LD      (HL),0          ; the current drive
        LD      B,11
sn1:    INC     L
        LD      (HL),' '
        DJNZ    sn1
        LD      L,CFCB+1
sn2:    LD      A,(DE)
        INC     DE
        CP      13
        JR      Z,fcbclr
        CP      '.'
        JR      NZ,sn3
        LD      L,CFCB+9        ; the type
        JR      sn2
sn3:    CP      'a'
        JR      C,sn4
        AND     5Fh             ; a capital
sn4:    LD      (HL),A
        INC     L
        JR      sn2
fcbclr: LD      HL,CFCB+12
        LD      B,24
fc1:    LD      (HL),0
        INC     HL
        DJNZ    fc1
        RET

; fbdos: BDOS function C on the file
fbdos:  LD      DE,CFCB
        JP      BDOS

; ^R, CP/M: read the file. A name typed before the key is the file's name
; from now on. (On into load, which returns to edit.)
cread:  CALL    setname
        LD      HL,edit
        PUSH    HL

; load: read the file into PROG. No such file: no program. The text ends at
; the file's first ^Z (1Ah), which pads a text file's last record; one more
; goes after the last record, so the search always stops. And every line
; must end in LF: a last line without one is given a CR LF. (The FCB is
; clear after its name: the CCP left it so, or setname did.)
load:   LD      C,15            ; open (no such file: the first read fails
        CALL    fbdos           ;   too)
        LD      DE,PROG
ld1:    LD      C,20            ; read the next 128 bytes
        CALL    frec
        OR      A
        JR      Z,ld1
        LD      (HL),1Ah        ; (HL = where the record that failed would be)
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
        RET
        ENDIF

; =============================================================================
        IF      CPM
        ; The RAM pages follow the image; the heap may grow to the BDOS.
start:
        ENDIF
        IF      CPM*CHECKED*(1-EDITOR)
        ; Clear the lower half of the letter page (as the editor build does
        ; at its start).
        LD      HL,LET
        XOR     A
ini1:   LD      (HL),A
        INC     L
        JP      P,ini1          ; +00h to +7Fh
        ENDIF
        IF      CPM*(1-EDITOR)
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
ld2:    LD      (HL),0          ; the end of the file counts as NUL
        INC     HL              ; the heap starts after it
        LD      BC,PROG         ; the IP
        ENDIF
        IF      CPM*(1-EDITOR)*QK
        CALL    skclr           ; an empty skip cache
        ENDIF
        IF      CPM*(1-EDITOR)
        JP      st2
        ENDIF

        IF      FAST
; =============================================================================
;  The speed build (FAST = 1)
;
;  The inner loop is a table: 256 entries, the low bytes of the handlers'
;  addresses in one page and the high bytes in the next. The dispatcher (at
;  next0, and inline, as NEXTF, at the end of the speed build's own entries,
;  so there is no jump back to it; the ordinary handlers end in JP (IX), with
;  IX = next0, as in the CP/M builds):
;
;      LD A,(BC) / INC BC / EX DE,HL / LD L,A / LD H,DTAB/256 /
;      LD A,(HL) / INC H / LD H,(HL) / LD L,A / JP (HL)
;
;  So every entry starts with TOS in DE, not HL. The punctuation entries are
;  thunks into the ordinary handlers (EX DE,HL / JP handler); the letters and
;  digits have one entry each, which knows its cell or its value already.
; =============================================================================
ftstore:EX      DE,HL           ; !
        JP      h_store
ftstr:  EX      DE,HL           ; "
        JP      h_str
ftnum:  EX      DE,HL           ; #
        JP      h_num
ftprint:EX      DE,HL           ; $
        JP      h_print
ftswap: EX      DE,HL           ; %
        JP      h_swap
ftand:  EX      DE,HL           ; &
        JP      h_and
ftemit: EX      DE,HL           ; '
        JP      h_emit
ftopen: EX      DE,HL           ; (
        JP      h_open
ftclose:EX      DE,HL           ; )
        JP      h_close
ftmul:  EX      DE,HL           ; *
        JP      h_mul
ftadd:  EX      DE,HL           ; +
        JP      h_add
ftcfetch:EX      DE,HL           ; ,
        JP      h_cfetch
ftsub:  EX      DE,HL           ; -
        JP      h_sub
ftcstore:EX      DE,HL           ; .
        JP      h_cstore
ftdiv:  EX      DE,HL           ; /
        JP      h_div
ftdup:  EX      DE,HL           ; :
        JP      h_dup
ftdrop: EX      DE,HL           ; ;
        JP      h_drop
ftlt:   EX      DE,HL           ; <
        JP      h_lt
fteq:   EX      DE,HL           ; =
        JP      h_eq
ftgt:   EX      DE,HL           ; >
        JP      h_gt
ftkey:  EX      DE,HL           ; ?
        JP      h_key
ftfetch:EX      DE,HL           ; @
        JP      h_fetch
ftdef:  EX      DE,HL           ; [
        JP      h_def
ftbreak:EX      DE,HL           ; \
        JP      h_break
ftret:  EX      DE,HL           ; ]
        JP      h_ret
ftxor:  EX      DE,HL           ; ^
        JP      h_xor
ftalloc:EX      DE,HL           ; _
        JP      h_alloc
ftgrave:EX      DE,HL           ; `
        JP      h_grave
fttor:  EX      DE,HL           ; {
        JP      h_tor
ftor:   EX      DE,HL           ; |
        JP      h_or
ftfromr:EX      DE,HL           ; }
        JP      h_fromr
ftnot:  EX      DE,HL           ; ~
        JP      h_not
; The commonest punctuation, written for the speed build: TOS in DE on the
; way in, and the dispatcher inline on the way out.
fs_add: ; +
        POP     HL
        ADD     HL,DE
        NEXTF      
fs_sub: ; -
        LD      A,(BC)          ; a digit next: a negative number
        SUB     '0'
        CP      10
        JR      C,fs_neg
        POP     HL
        OR      A
        SBC     HL,DE
        NEXTF      
fs_neg: EX      DE,HL
        JP      h_sub
fs_dup: ; :
        PUSH    DE
        EX      DE,HL
        NEXTF      
fs_drop: ; ;
        POP     HL
        NEXTF      
fs_swap: ; %
        POP     HL
        PUSH    DE
        NEXTF      
fs_fet: ; @
        EX      DE,HL
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        NEXTF      
fs_cfet: ; ,
        LD      A,(DE)
        LD      L,A
        LD      H,0
        NEXTF      
fs_lt:  ; <
        POP     HL              ; a < b: HL = a, DE = b
fs_lt1: LD      A,H
        XOR     80h
        LD      H,A
        LD      A,D
        XOR     80h
        LD      D,A
        SBC     HL,DE           ; carry if HL < DE
        SBC     HL,HL
        NEXTF      
fs_gt:  ; >
        POP     HL              ; a > b  is  b < a
        EX      DE,HL
        JP      fs_lt1
fs_eq:  ; =
        POP     HL
        OR      A
        SBC     HL,DE
        LD      A,H
        OR      L
        CP      1               ; carry only if a - b = 0
        SBC     HL,HL
        NEXTF      
fs_and: ; &
        POP     HL
        LD      A,H
        AND     D
        LD      H,A
        LD      A,L
        AND     E
        LD      L,A
        NEXTF      
fs_or:  ; |
        POP     HL
        LD      A,H
        OR      D
        LD      H,A
        LD      A,L
        OR      E
        LD      L,A
        NEXTF      
fs_xor: ; ^
        POP     HL
        LD      A,H
        XOR     D
        LD      H,A
        LD      A,L
        XOR     E
        LD      L,A
        NEXTF      
fs_not: ; ~
        LD      A,E
        CPL
        LD      L,A
        LD      A,D
        CPL
        LD      H,A
        NEXTF      
fs_mul: ; *
        POP     HL              ; (the two the other way round: the same)
        JP      mulq
fs_open: ; (
        LD      A,D
        OR      E
        POP     HL
        JR      Z,fs_op0
        PUSH    BC              ; the block start
        JP      rpushn
fs_op0: CALL    skip
        NEXTF      
fs_close: ; )
        LD      A,D
        OR      E
        POP     HL
        JR      Z,fs_cl0
        LD      C,(IY+0)        ; the block start, read where it is
        LD      B,(IY+1)
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fs_cl0: POPR       
        NEXTF      
fs_ret: EX      DE,HL           ; ]
        LD      C,(IY+0)
        LD      B,(IY+1)
        INC     IY
        INC     IY
        NEXTF      
fd0:    EX      DE,HL           ; 0
        PUSH    HL
        LD      HL,0
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd1:    EX      DE,HL           ; 1
        PUSH    HL
        LD      HL,1
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd2:    EX      DE,HL           ; 2
        PUSH    HL
        LD      HL,2
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd3:    EX      DE,HL           ; 3
        PUSH    HL
        LD      HL,3
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd4:    EX      DE,HL           ; 4
        PUSH    HL
        LD      HL,4
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd5:    EX      DE,HL           ; 5
        PUSH    HL
        LD      HL,5
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd6:    EX      DE,HL           ; 6
        PUSH    HL
        LD      HL,6
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd7:    EX      DE,HL           ; 7
        PUSH    HL
        LD      HL,7
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd8:    EX      DE,HL           ; 8
        PUSH    HL
        LD      HL,8
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fd9:    EX      DE,HL           ; 9
        PUSH    HL
        LD      HL,9
        LD      A,(BC)
        SUB     '0'
        CP      10
        JP      C,fdm
        NEXTF      
fdm:    INC     BC              ; more digits: HL = HL * 10 + the digit
        LD      D,H
        LD      E,L
        ADD     HL,HL
        ADD     HL,HL
        ADD     HL,DE
        ADD     HL,HL
        LD      E,A
        LD      D,0
        ADD     HL,DE
        LD      A,(BC)
        SUB     '0'
        CP      10
        JR      C,fdm
        NEXTF      
fuA:    LD      (IY-1),B        ; A: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+0)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuB:    LD      (IY-1),B        ; B: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+2)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuC:    LD      (IY-1),B        ; C: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+4)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuD:    LD      (IY-1),B        ; D: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+6)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuE:    LD      (IY-1),B        ; E: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+8)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuF:    LD      (IY-1),B        ; F: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+10)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuG:    LD      (IY-1),B        ; G: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+12)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuH:    LD      (IY-1),B        ; H: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+14)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuI:    LD      (IY-1),B        ; I: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+16)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuJ:    LD      (IY-1),B        ; J: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+18)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuK:    LD      (IY-1),B        ; K: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+20)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuL:    LD      (IY-1),B        ; L: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+22)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuM:    LD      (IY-1),B        ; M: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+24)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuN:    LD      (IY-1),B        ; N: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+26)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuO:    LD      (IY-1),B        ; O: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+28)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuP:    LD      (IY-1),B        ; P: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+30)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuQ:    LD      (IY-1),B        ; Q: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+32)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuR:    LD      (IY-1),B        ; R: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+34)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuS:    LD      (IY-1),B        ; S: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+36)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuT:    LD      (IY-1),B        ; T: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+38)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuU:    LD      (IY-1),B        ; U: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+40)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuV:    LD      (IY-1),B        ; V: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+42)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuW:    LD      (IY-1),B        ; W: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+44)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuX:    LD      (IY-1),B        ; X: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+46)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuY:    LD      (IY-1),B        ; Y: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+48)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
fuZ:    LD      (IY-1),B        ; Z: call the word. The return address goes
        LD      (IY-2),C        ;   on the return stack,
        DEC     IY
        DEC     IY
        LD      BC,(LET+50)  ;   the IP becomes the word's body, and the break
        EX      DE,HL           ;   key is looked at as rpushn would
        PUSH    HL
        LD      HL,PCNT
        DEC     (HL)
        POP     HL
        CALL    Z,pollk
        NEXTF      
        ENDIF
        IF      FAST*(1-CHECKED)
; a-z, unchecked: a variable followed by '@' or '!' is fetched or stored in
; the same step.
fva:    LD      HL,LET+40h+0 ; a
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvb:    LD      HL,LET+40h+2 ; b
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvc:    LD      HL,LET+40h+4 ; c
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvd:    LD      HL,LET+40h+6 ; d
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fve:    LD      HL,LET+40h+8 ; e
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvf:    LD      HL,LET+40h+10 ; f
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvg:    LD      HL,LET+40h+12 ; g
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvh:    LD      HL,LET+40h+14 ; h
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvi:    LD      HL,LET+40h+16 ; i
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvj:    LD      HL,LET+40h+18 ; j
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvk:    LD      HL,LET+40h+20 ; k
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvl:    LD      HL,LET+40h+22 ; l
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvm:    LD      HL,LET+40h+24 ; m
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvn:    LD      HL,LET+40h+26 ; n
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvo:    LD      HL,LET+40h+28 ; o
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvp:    LD      HL,LET+40h+30 ; p
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvq:    LD      HL,LET+40h+32 ; q
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvr:    LD      HL,LET+40h+34 ; r
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvs:    LD      HL,LET+40h+36 ; s
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvt:    LD      HL,LET+40h+38 ; t
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvu:    LD      HL,LET+40h+40 ; u
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvv:    LD      HL,LET+40h+42 ; v
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvw:    LD      HL,LET+40h+44 ; w
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvx:    LD      HL,LET+40h+46 ; x
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvy:    LD      HL,LET+40h+48 ; y
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvz:    LD      HL,LET+40h+50 ; z
        LD      A,(BC)
        CP      '@'
        JP      Z,fvat
        CP      '!'
        JP      Z,fvst
        PUSH    DE
        NEXTF      
fvat:   INC     BC              ; x@: TOS = the cell's value
        PUSH    DE
        LD      A,(HL)
        INC     L
        LD      H,(HL)
        LD      L,A
        NEXTF      
fvst:   INC     BC              ; x!: the cell = TOS, and NOS comes up
        LD      (HL),E
        INC     L
        LD      (HL),D
        POP     HL
        NEXTF      
FHIGH   EQU     fign            ; (80h-FFh are ignored)
fs_store: ; !
        POP     HL
        EX      DE,HL
        LD      (HL),E
        INC     HL
        LD      (HL),D
        POP     HL
        NEXTF      
fs_cstore: ; .
        POP     HL
        EX      DE,HL
        LD      (HL),E
        POP     HL
        NEXTF      
FSTORE  EQU     fs_store
FCSTORE EQU     fs_cstore
        ENDIF
        IF      FAST*CHECKED
; a-z, checked: push the cell's address (a checked build checks the stacks
; between the variable and what follows it, so it keeps them apart)
fva:    LD      HL,LET+40h+0 ; a
        PUSH    DE
        NEXTF      
fvb:    LD      HL,LET+40h+2 ; b
        PUSH    DE
        NEXTF      
fvc:    LD      HL,LET+40h+4 ; c
        PUSH    DE
        NEXTF      
fvd:    LD      HL,LET+40h+6 ; d
        PUSH    DE
        NEXTF      
fve:    LD      HL,LET+40h+8 ; e
        PUSH    DE
        NEXTF      
fvf:    LD      HL,LET+40h+10 ; f
        PUSH    DE
        NEXTF      
fvg:    LD      HL,LET+40h+12 ; g
        PUSH    DE
        NEXTF      
fvh:    LD      HL,LET+40h+14 ; h
        PUSH    DE
        NEXTF      
fvi:    LD      HL,LET+40h+16 ; i
        PUSH    DE
        NEXTF      
fvj:    LD      HL,LET+40h+18 ; j
        PUSH    DE
        NEXTF      
fvk:    LD      HL,LET+40h+20 ; k
        PUSH    DE
        NEXTF      
fvl:    LD      HL,LET+40h+22 ; l
        PUSH    DE
        NEXTF      
fvm:    LD      HL,LET+40h+24 ; m
        PUSH    DE
        NEXTF      
fvn:    LD      HL,LET+40h+26 ; n
        PUSH    DE
        NEXTF      
fvo:    LD      HL,LET+40h+28 ; o
        PUSH    DE
        NEXTF      
fvp:    LD      HL,LET+40h+30 ; p
        PUSH    DE
        NEXTF      
fvq:    LD      HL,LET+40h+32 ; q
        PUSH    DE
        NEXTF      
fvr:    LD      HL,LET+40h+34 ; r
        PUSH    DE
        NEXTF      
fvs:    LD      HL,LET+40h+36 ; s
        PUSH    DE
        NEXTF      
fvt:    LD      HL,LET+40h+38 ; t
        PUSH    DE
        NEXTF      
fvu:    LD      HL,LET+40h+40 ; u
        PUSH    DE
        NEXTF      
fvv:    LD      HL,LET+40h+42 ; v
        PUSH    DE
        NEXTF      
fvw:    LD      HL,LET+40h+44 ; w
        PUSH    DE
        NEXTF      
fvx:    LD      HL,LET+40h+46 ; x
        PUSH    DE
        NEXTF      
fvy:    LD      HL,LET+40h+48 ; y
        PUSH    DE
        NEXTF      
fvz:    LD      HL,LET+40h+50 ; z
        PUSH    DE
        NEXTF      
fhi:    EX      DE,HL           ; 80h-FFh: reserved (X), or an undefined word (U)
        JP      e_hi
FHIGH   EQU     fhi
FSTORE  EQU     ftstore
FCSTORE EQU     ftcstore
        ENDIF
        IF      FAST
fnul:   EX      DE,HL           ; NUL: the end of the program
        JP      EXIT
fign:   EX      DE,HL           ; 01h-20h and DEL (and 80h-FFh unchecked): nothing
        NEXTF      
; the table: low bytes, then high bytes, each a page
        DS      (256 - ($ & 0FFh)) & 0FFh
DTAB:
        DB      fnul&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh   ; 00h
        DB      fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh   ; 08h
        DB      fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh   ; 10h
        DB      fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh   ; 18h
        DB      fign&0FFh,FSTORE&0FFh,ftstr&0FFh,ftnum&0FFh,ftprint&0FFh,fs_swap&0FFh,fs_and&0FFh,ftemit&0FFh   ; 20h
        DB      fs_open&0FFh,fs_close&0FFh,fs_mul&0FFh,fs_add&0FFh,fs_cfet&0FFh,fs_sub&0FFh,FCSTORE&0FFh,ftdiv&0FFh   ; 28h
        DB      fd0&0FFh,fd1&0FFh,fd2&0FFh,fd3&0FFh,fd4&0FFh,fd5&0FFh,fd6&0FFh,fd7&0FFh   ; 30h
        DB      fd8&0FFh,fd9&0FFh,fs_dup&0FFh,fs_drop&0FFh,fs_lt&0FFh,fs_eq&0FFh,fs_gt&0FFh,ftkey&0FFh   ; 38h
        DB      fs_fet&0FFh,fuA&0FFh,fuB&0FFh,fuC&0FFh,fuD&0FFh,fuE&0FFh,fuF&0FFh,fuG&0FFh   ; 40h
        DB      fuH&0FFh,fuI&0FFh,fuJ&0FFh,fuK&0FFh,fuL&0FFh,fuM&0FFh,fuN&0FFh,fuO&0FFh   ; 48h
        DB      fuP&0FFh,fuQ&0FFh,fuR&0FFh,fuS&0FFh,fuT&0FFh,fuU&0FFh,fuV&0FFh,fuW&0FFh   ; 50h
        DB      fuX&0FFh,fuY&0FFh,fuZ&0FFh,ftdef&0FFh,ftbreak&0FFh,fs_ret&0FFh,fs_xor&0FFh,ftalloc&0FFh   ; 58h
        DB      ftgrave&0FFh,fva&0FFh,fvb&0FFh,fvc&0FFh,fvd&0FFh,fve&0FFh,fvf&0FFh,fvg&0FFh   ; 60h
        DB      fvh&0FFh,fvi&0FFh,fvj&0FFh,fvk&0FFh,fvl&0FFh,fvm&0FFh,fvn&0FFh,fvo&0FFh   ; 68h
        DB      fvp&0FFh,fvq&0FFh,fvr&0FFh,fvs&0FFh,fvt&0FFh,fvu&0FFh,fvv&0FFh,fvw&0FFh   ; 70h
        DB      fvx&0FFh,fvy&0FFh,fvz&0FFh,fttor&0FFh,fs_or&0FFh,ftfromr&0FFh,fs_not&0FFh,fign&0FFh   ; 78h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; 80h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; 88h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; 90h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; 98h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; A0h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; A8h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; B0h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; B8h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; C0h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; C8h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; D0h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; D8h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; E0h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; E8h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; F0h
        DB      FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh,FHIGH&0FFh   ; F8h
        DB      fnul/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256   ; 00h
        DB      fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256   ; 08h
        DB      fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256   ; 10h
        DB      fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256   ; 18h
        DB      fign/256,FSTORE/256,ftstr/256,ftnum/256,ftprint/256,fs_swap/256,fs_and/256,ftemit/256   ; 20h
        DB      fs_open/256,fs_close/256,fs_mul/256,fs_add/256,fs_cfet/256,fs_sub/256,FCSTORE/256,ftdiv/256   ; 28h
        DB      fd0/256,fd1/256,fd2/256,fd3/256,fd4/256,fd5/256,fd6/256,fd7/256   ; 30h
        DB      fd8/256,fd9/256,fs_dup/256,fs_drop/256,fs_lt/256,fs_eq/256,fs_gt/256,ftkey/256   ; 38h
        DB      fs_fet/256,fuA/256,fuB/256,fuC/256,fuD/256,fuE/256,fuF/256,fuG/256   ; 40h
        DB      fuH/256,fuI/256,fuJ/256,fuK/256,fuL/256,fuM/256,fuN/256,fuO/256   ; 48h
        DB      fuP/256,fuQ/256,fuR/256,fuS/256,fuT/256,fuU/256,fuV/256,fuW/256   ; 50h
        DB      fuX/256,fuY/256,fuZ/256,ftdef/256,ftbreak/256,fs_ret/256,fs_xor/256,ftalloc/256   ; 58h
        DB      ftgrave/256,fva/256,fvb/256,fvc/256,fvd/256,fve/256,fvf/256,fvg/256   ; 60h
        DB      fvh/256,fvi/256,fvj/256,fvk/256,fvl/256,fvm/256,fvn/256,fvo/256   ; 68h
        DB      fvp/256,fvq/256,fvr/256,fvs/256,fvt/256,fvu/256,fvv/256,fvw/256   ; 70h
        DB      fvx/256,fvy/256,fvz/256,fttor/256,fs_or/256,ftfromr/256,fs_not/256,fign/256   ; 78h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; 80h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; 88h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; 90h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; 98h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; A0h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; A8h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; B0h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; B8h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; C0h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; C8h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; D0h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; D8h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; E0h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; E8h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; F0h
        DB      FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256,FHIGH/256   ; F8h
        ENDIF

        IF      CPM
; RAM pages, after the image
CPAGE   EQU     (imgend + 255) / 256 ; the skip cache (QK builds), first, so
RSPAGE  EQU     CPAGE + QK   ;   that the letter page is still the one
DSPAGE  EQU     RSPAGE + 1      ;   just below the program text
LETPAGE EQU     RSPAGE + 2
PROG    EQU     LETPAGE*256 + 256
        ENDIF
imgend:
