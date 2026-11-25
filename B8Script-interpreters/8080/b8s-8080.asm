; =============================================================================
;  B8Script interpreter for the Intel 8080
;  Spec: docs/b8script.md (2026-11-24).
;  Design follows the Z80 interpreter (z80/b8s-z80.asm), with 8080 opcodes
;  only.
;
;  The switches, set in the EQU lines below:
;    CPM      0 = generic ROM build (KEY/CONOUT at fixed addresses)
;             1 = CP/M 2.2 .COM file: loads the file named on the command line
;    CHECKED  0 = no checks (spec: the programmer is responsible)
;             1 = starts with every variable at 0 and every word undefined,
;                 and stops on every error in the spec's table (and Ctrl-C)
;                 with a three-line report: the letter and the place as line
;                 and column, and both stacks. See `error`.
;    ANSI     what the console escapes of '$' (/{ /} /| /` /~) do:
;             1 = send ANSI (VT100) sequences through CONOUT
;             0 = call the machine's own routines CONCLS, CONEOL, CONCUR and
;                 CONAT (see the equates). The CP/M builds always send ANSI.
;    SPEED    0 = small: the smallest build
;             1 = base, the default: the speed-ups that cost bytes: a skip
;                 cache, a faster skip, '*' and '/' quicker for small and
;                 power-of-two operands, and more (see "Speed-ups")
;             2 = fast: base and a dispatch table besides, with no size
;                 limit (see "The fast build").
;
;  In every build Ctrl-C stops a running program (an unchecked build stops
;  without a word): see the console layer for the rules, the held key and
;  the break-off cell.
;
;  Assembler: asm80 (https://maly.github.io/asm80-node/), I8080 mode.
; =============================================================================

CPM     EQU     0               ; 1 = CP/M .COM build
CHECKED EQU     0               ; 1 = checked build
ANSI    EQU     0               ; 1 = the console escapes send ANSI sequences
SPEED   EQU     1               ; 0 = small, 1 = base, 2 = fast (see "Speed-ups")
FAST    EQU     SPEED/2         ; (1: the fast build)
SBASE   EQU     SPEED-FAST*2    ; (1: the base build)
ANS     EQU     ANSI+CPM-ANSI*CPM ; (CP/M: always ANSI)
QK      EQU     SBASE+FAST-SBASE*FAST ; (the speed-ups: base, or the fast build)
SBASEU  EQU     QK*(1-CHECKED)*(1-FAST) ; (and those that only the unchecked
                                ;  builds take; the fast build has its own)
PTLATE  EQU     SBASEU*(1-CPM)  ; (1: the table goes after psgn and pdec, not
                                ;   before the routines: wherever it doesn't
                                ;   cross a page. chktab.py says if it does)

; -----------------------------------------------------------------------------
;  Register use, everywhere in the interpreter
;
;    BC   IP: the address of the next program character to read
;    HL   TOS: the top data-stack cell is kept here, not in memory
;    SP   the data stack: (SP) is NOS, the cell under TOS. The data stack is
;         the 8080's own stack, which is what the spec's machine-code contract
;         needs ("the data cells above the return address").
;    A DE scratch. Every handler is entered with HL = TOS and may use A, DE.
;
;  The return stack pointer has no register (the 8080 has no spare pair): it
;  is the RAM word RSP. Only rpop, rpushd and ')' (and the checks) touch it.
;
;  One-byte calls. In a generic build the routines used most are reached
;  with RST, one byte instead of three. The source writes them as macros:
;
;    POPR   RST 1  08h  rpop    pop the return stack into HL
;    DROP   RST 3  18h  drp     drop TOS, then next character  (ends a handler)
;    NEGH   RST 4  20h  neg16   HL = -HL
;    PUTA   RST 5  28h  putc    print A
;    NEXT   RST 6  30h  next0   next character                 (ends a handler)
;
;  RST 3 and RST 6 never return: an RST is a CALL, so the first thing each
;  of them does is POP D to throw the return address away.
;
;  A CP/M build leaves page zero alone (CP/M keeps it for interrupts, and
;  RomWBW's BIOS calls itself through RST 1): there the macros are CALLs, and
;  DROP and NEXT are JMPs.
;
;  Dispatch. PTAB holds one byte per punctuation character: the low byte of
;  its handler's address. The high byte is worked out from the character:
;  the handlers of the first NPG1 characters (in code order) start in the
;  image's second page, the rest in its first. The layout below keeps to
;  that, and testing/chktab.py checks it in every build.
;
;  The fast build (FAST) dispatches through a full table instead, and there
;  NEXT and DROP are jumps outside page zero: see "The fast build".
;
;  What the 8080 lacks, and what replaces it: no JR (JMP/Jcc), no DJNZ, no
;  SBC HL (byte-wise SUB/SBB, or negate and DAD), no shifts on register pairs
;  (DAD H doubles; RAL/RAR through A), no LDIR/CPIR (small loops).
; -----------------------------------------------------------------------------

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
;  The base and fast builds have a fifth, CPAGE, for the skip cache: the
;  page at the heap limit (F000h) in a generic build, and under CP/M the
;  first page after the image, before the return stack, so that the letter
;  page is still the one just below the program text.
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
EXIT    EQU     0000h           ; warm boot
BASE    EQU     0100h           ; where the image starts
        ENDIF
        IFN     CPM
; ---- generic machine: edit these to suit -----------------------------------
KEY     EQU     0FF06h          ; a waiting key in A, or A = 0 if none is
                                ;   waiting. The zero flag must match A
                                ;   (end the routine with ORA A / RET).
CONOUT  EQU     0FF03h          ; print the character in A
EXIT    EQU     0FF09h          ; where to go when the program ends
;   KEY and CONOUT must preserve BC, DE and HL.
        ENDIF
        IF      1-ANS
; With ANSI = 0 the console escapes call these. All four must keep BC, and
; all but CONAT also HL. They may change A, DE and the flags.
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

MSLOOP  EQU     40-36*CPM       ; n? inner loop count for about 1 ms (1-255;
                                ; the wait for a second Ctrl-C uses it too):
                                ; each pass calls getk once, so tune it for
                                ; your clock and your KEY routine. CP/M: 4,
                                ; for a BDOS 6 call of about 280 us (an RC2014
                                ; with RomWBW and ZPM3). A .COM can be
                                ; patched: see TIMING.B8S.

; letter-page layout (offsets inside LETPAGE)
LET     EQU     LETPAGE*256
HEAP    EQU     LET+7Ch         ; the heap pointer
RSP     EQU     LET+34h         ; gap after Z: the return stack pointer;
BRKCNT  EQU     LET+36h         ;   the break check's countdown;
NPEND   EQU     LET+38h         ;   minus the address of the program's end
                                ;   (the heap's first byte), for the checked '_';
PSAVE   EQU     LET+3Ah         ;   the checked build: the address '$' prints
                                ;   from, for a report
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

; The five one-byte calls (see the header). asm80 can't nest IF, so these
; are written with DS: a count of 0 writes nothing. DS can't take a label
; that comes later, but EQU can, and DS can take that.
AROP    EQU     rpop
ADRP    EQU     drp
ANEG    EQU     neg16
APUT    EQU     putc
ANXT    EQU     next0
        IF      CHECKED
ACHK    EQU     chkstk          ; (for the fast build's dispatcher)
        ENDIF
        IF      1-CHECKED
ACHK    EQU     0
        ENDIF
        IF      FAST
DTPG    EQU     DTAB/256        ; (the fast build's table's first page)
        ENDIF
        IF      1-FAST
DTPG    EQU     0
        ENDIF
        .macro  POPR            ; pop the return stack into HL
        DS      1-CPM,0CFh      ;   RST 1
        DS      CPM,0CDh        ;   CALL rpop
        DS      CPM,AROP&0FFh
        DS      CPM,AROP/256
        .endm
        .macro  DROP            ; drop TOS, then next character
        DS      (1-CPM)*(1-FAST),0DFh ; RST 3
        DS      CPM*(1-FAST),0C3h ;   JMP drp
        DS      CPM*(1-FAST),ADRP&0FFh
        DS      CPM*(1-FAST),ADRP/256
        DS      FAST,0E1h       ;   (fast build: POP H / JMP next0)
        DS      FAST,0C3h
        DS      FAST,ANXT&0FFh
        DS      FAST,ANXT/256
        .endm
        .macro  DROPZ           ; the same, in the generic page zero: one byte
        DS      1-CPM,0DFh      ;   there in every build (RST 3)
        DS      CPM,0C3h        ;   JMP drp
        DS      CPM,ADRP&0FFh
        DS      CPM,ADRP/256
        .endm
        .macro  NEGH            ; HL = -HL
        DS      1-CPM,0E7h      ;   RST 4
        DS      CPM,0CDh        ;   CALL neg16
        DS      CPM,ANEG&0FFh
        DS      CPM,ANEG/256
        .endm
        .macro  PUTA            ; print A
        DS      1-CPM,0EFh      ;   RST 5
        DS      CPM,0CDh        ;   CALL putc
        DS      CPM,APUT&0FFh
        DS      CPM,APUT/256
        .endm
        .macro  NEXT            ; next character
        DS      (1-CPM)*(1-FAST),0F7h ; RST 6
        DS      CPM+FAST-CPM*FAST,0C3h ; JMP next0 (CP/M, and the fast build)
        DS      CPM+FAST-CPM*FAST,ANXT&0FFh
        DS      CPM+FAST-CPM*FAST,ANXT/256
        .endm
        .macro  NEXTZ           ; next character, in the generic page zero: one
        DS      1-CPM,0F7h      ;   byte there in every build (RST 6)
        DS      CPM,0C3h        ;   JMP next0
        DS      CPM,ANXT&0FFh
        DS      CPM,ANXT/256
        .endm
        .macro  NEXTF           ; (fast build only: the dispatcher itself, inline)
        DS      FAST*CHECKED,0CDh ; (checked: CALL chkstk)
        DS      FAST*CHECKED,ACHK&0FFh
        DS      FAST*CHECKED,ACHK/256
        DS      FAST,0Ah        ;   LDAX B
        DS      FAST,03h        ;   INX B
        DS      FAST,0EBh       ;   XCHG        (TOS to DE)
        DS      FAST,6Fh        ;   MOV L,A
        DS      FAST,26h        ;   MVI H,DTAB/256
        DS      FAST,DTPG
        DS      FAST,7Eh        ;   MOV A,M     (the low byte)
        DS      FAST,24h        ;   INR H
        DS      FAST,66h        ;   MOV H,M     (the high byte)
        DS      FAST,6Fh        ;   MOV L,A
        DS      FAST,0E9h       ;   PCHL
        .endm
        .macro  NEXTD           ; (fast build only: the dispatcher, with TOS in DE.
        DS      FAST*CHECKED,0EBh ; A checked build's chkstk wants it in HL)
        DS      FAST*CHECKED,0CDh
        DS      FAST*CHECKED,ACHK&0FFh
        DS      FAST*CHECKED,ACHK/256
        DS      FAST,0Ah
        DS      FAST,03h
        DS      FAST*CHECKED,0EBh
        DS      FAST,6Fh
        DS      FAST,26h
        DS      FAST,DTPG
        DS      FAST,7Eh
        DS      FAST,24h
        DS      FAST,66h
        DS      FAST,6Fh
        DS      FAST,0E9h
        .endm
        .macro  NEXTX           ; (fast build only: the dispatcher, with TOS in HL
        DS      FAST*CHECKED,0CDh ; in a checked build and in DE unchecked)
        DS      FAST*CHECKED,ACHK&0FFh
        DS      FAST*CHECKED,ACHK/256
        DS      FAST,0Ah
        DS      FAST,03h
        DS      FAST*CHECKED,0EBh
        DS      FAST,6Fh
        DS      FAST,26h
        DS      FAST,DTPG
        DS      FAST,7Eh
        DS      FAST,24h
        DS      FAST,66h
        DS      FAST,6Fh
        DS      FAST,0E9h
        .endm
        .macro  XCHGC           ; (XCHG in a checked build)
        DS      CHECKED,0EBh
        .endm
        .macro  NEXTQ           ; (the speed-ups' tails: NEXT, or in the fast
        DS      (1-CPM)*(1-FAST),0F7h ; build the dispatcher inline)
        DS      CPM*(1-FAST),0C3h
        DS      CPM*(1-FAST),ANXT&0FFh
        DS      CPM*(1-FAST),ANXT/256
        DS      FAST*CHECKED,0CDh
        DS      FAST*CHECKED,ACHK&0FFh
        DS      FAST*CHECKED,ACHK/256
        DS      FAST,0Ah
        DS      FAST,03h
        DS      FAST,0EBh
        DS      FAST,6Fh
        DS      FAST,26h
        DS      FAST,DTPG
        DS      FAST,7Eh
        DS      FAST,24h
        DS      FAST,66h
        DS      FAST,6Fh
        DS      FAST,0E9h
        .endm

; =============================================================================
;  The first 49 bytes: the entry, then the RST routines, with small handlers
;  and routines filling the gaps between them. Generic: this IS page zero.
;  CP/M: it is just the start of the .COM file.
; =============================================================================
        ORG     BASE
        IF      1-(1-CPM)*CHECKED
        LXI     SP,DSTOP        ; 00  reset, or the start of the .COM file
        ENDIF
        JMP     start           ; In the checked generic build this is at 0000h
                                ;   (and `start` sets SP): its first byte, C3h,
                                ;   is what an undefined word runs into, as
                                ;   CP/M's own JMP at 0000h is in a .COM: e_hi.
        IF      (1-CPM)*CHECKED
        DB      0,0,0           ; 03  spare
        ENDIF
rdrop:  POPR                    ; 06  drop the top of the return stack, then
        DROPZ                   ;     drop TOS (a spent flag) and go on
; ---- RST 1: rpop: pop the return stack into HL (DE is lost) -----------------
rpop:   LHLD    RSP             ; 08
        MOV     E,M
        INX     H
        MOV     D,M
        INX     H
        SHLD    RSP
        XCHG
        RET                     ; 13  (so RST 2 is not used)
h_tor:  XCHG                    ; 14  '{' TOS to the return stack; rpushd
        JMP     rpushd          ;     brings up the new TOS
; ---- RST 3: drop TOS, then next ---------------------------------------------
        IF      1-CPM
rst18:  POP     D               ; 18  discard the RST's return address
        ENDIF
drp:    POP     H               ;     new TOS = NOS
        JMP     next0
h_fromr:PUSH    H               ; 1D  '}' return stack to TOS
        POPR     
        NEXTZ    
; ---- RST 4: neg16: HL = -HL (keeps BC, DE) ----------------------------------
neg16:  XRA     A               ; 20
        SUB     L
        MOV     L,A
        SBB     A
        SUB     H
        MOV     H,A
        RET
jphl:   PCHL                    ; 27  (for the machine-code call)
; ---- RST 5: putc: print A (keeps BC, DE, HL) --------------------------------
        IFN     CPM
rst28:
putc:   JMP     CONOUT          ; 28
        ENDIF
; exec: '`' with no hex digit after it: call the machine code at TOS. It
; returns here, with its top cell on the stack: that becomes the new TOS.
exec:   CALL    jphl            ; 2B
        POP     H
        NEXTZ    
; ---- RST 6: next character --------------------------------------------------
        IF      1-CPM
rst30:  POP     D               ; 30  discard the RST's return address
        ENDIF

; The dispatch table (see PTAB, where it is placed)
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
next0:  NEXTF                   ; (the fast build: the table dispatcher)
        IF      CHECKED*(1-FAST)
        CALL    chkstk          ; both stacks are checked once per character
        ENDIF
        IF      1-FAST
        LDAX    B
        INX     B
        SUI     21h             ; A = c - 21h
        JC      ctl             ; c < 21h: NUL ends, the rest are ignored
        CPI     0Fh
        JC      punct           ; 21h-2Fh: PTAB index 0-14
        SUI     0Fh             ; A = c - 30h
        CPI     0Ah
        JC      digit           ; 30h-39h
        CPI     11h
        JC      p3a             ; 3Ah-40h
        SUI     11h             ; A = c - 41h
        CPI     1Ah
        JC      upper           ; 41h-5Ah: A = letter index 0-25
        CPI     20h
        JC      p5b             ; 5Bh-60h
        CPI     3Ah
        JC      lower           ; 61h-7Ah: A = 20h-39h (cell +64 bytes)
        CPI     3Eh
        ENDIF
        IF      CHECKED*(1-FAST)
        JZ      next0           ; 7Fh, DEL: ignored
        JNC     e_hi            ; 80h-FFh: reserved
        ENDIF
        IF      (1-CHECKED)*(1-FAST)
        JNC     next0           ; 7Fh-FFh: ignored
        ENDIF
        IF      1-FAST
        SUI     1Ah             ; 7Bh-7Eh: -1Eh in all, index 28-31
p5b:    SUI     9               ; 5Bh-60h: -4 in all, index 22-27
p3a:    ADI     5               ; 3Ah-40h: index 15-21

; Punctuation: A = the PTAB index. The handler starts with HL = TOS,
; untouched, and A, DE free.
punct:  ADI     PTAB & 0FFh     ; PTAB never crosses a page
        MOV     E,A
        MVI     D,PTAB / 256
        CPI     (PTAB & 0FFh) + NPG1 ; carry: one of the first NPG1
        LDAX    D
        MOV     E,A             ; the handler's low byte
        ENDIF
        IF      (1-CPM)*(1-FAST)
        MVI     A,0
        RAL                     ; its page: 0 + carry
        ENDIF
        IF      CPM*(1-FAST)
        MVI     A,1
        ACI     0               ; its page: 1 + carry
        ENDIF
        IF      1-FAST
        MOV     D,A
        PUSH    D               ; jump to it; the stack is balanced again
        RET                     ;   when the handler starts

; ctl: characters below 21h. A = c - 21h.
ctl:    ADI     21h             ; back to c; zero only for NUL
        JNZ     next0           ; the rest are ignored
        ENDIF
endprog:JMP     EXIT            ; the program has ended

; =============================================================================
;  Handlers that must start in the image's first page: ^ _ ` | ~
;  ({ and } are up among the RST routines.)
; =============================================================================
h_xor:  POP     D
        MOV     A,H
        XRA     D
        MOV     H,A
        MOV     A,L
        XRA     E
        MOV     L,A
        NEXT     

h_or:   POP     D
        MOV     A,H
        ORA     D
        MOV     H,A
        MOV     A,L
        ORA     E
        MOV     L,A
        NEXT     

h_not:  NEGH                    ; ~x = -x - 1
        DCX     H
        NEXT     

; '_' ( n -- addr ): the heap pointer moves by n, a signed count (the add is
; the same either way); TOS is the old pointer.
h_alloc:XCHG
        LHLD    HEAP
        PUSH    H
        DAD     D               ; the new top
        IF      CHECKED
        CALL    chkhp
        ENDIF
        SHLD    HEAP
        POP     H
        NEXT     

        IF      1-CPM
; ---- the letters and digits --------------------------------------------------

; a-z: push the cell's address (the cell is the variable)
;  (the unchecked base build does x@ and x! in one step: lowq)
        ENDIF
        IF      (1-CPM)*(1-SBASEU)
lower:  PUSH    H
        ADD     A
        MOV     L,A
        MVI     H,LETPAGE
        NEXT     
        ENDIF
        IF      1-CPM

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  PUSH    H               ; keep TOS: rpushd pops it back
        ADD     A
        MOV     L,A
        MVI     H,LETPAGE       ; HL -> cell
        MOV     D,B
        MOV     E,C             ; DE = the return address
        MOV     C,M
        INX     H
        MOV     B,M             ; IP = the word's body, and fall into rpushd

; rpushd: push DE on the return stack, then pop TOS off the data stack and
; go on. Every push of the return stack ends here: for a word call the cell
; popped is the TOS that upper parked; for '(' and '{' it is the cell under
; the one that was used up.
;
; The break key is looked at here, so at every word call and loop-back (and
; block entry and '{'), but only one time in 256: BRKCNT counts them. Reading
; the keyboard can be slow (it is a BDOS call under CP/M).
rpushd: LHLD    RSP
        DCX     H
        MOV     M,D
        DCX     H
        MOV     M,E
        SHLD    RSP
        LXI     H,BRKCNT
        DCR     M
        POP     H               ; (keeps the flags)
        CZ      pollk
        NEXT     

        ENDIF

; ---- machine code: the grave -----------------------------------------------
; '`' plus a hex digit loads bytes: ( addr -- addr' ). Pairs of hex digits
; are stored from addr until a non-hex character; then a RET (C9h) is
; written and its address is left. An odd last digit is consumed and dropped.
; '`' plus anything else calls the machine code at TOS: ( addr -- ). The
; code is entered by CALL with the data stack above the return address; it
; must keep BC, and on return the top cell becomes the new TOS.
h_grave:CALL    hexc
        JNC     exec
hx1:    ADD     A
        ADD     A
        ADD     A
        ADD     A
        MOV     D,A             ; the high digit
        CALL    hexc
        JNC     hx2             ; odd digit: consumed and dropped
        ORA     D
        MOV     M,A
        INX     H
        CALL    hexc
        JC      hx1
hx2:    MVI     M,0C9h          ; (never range-checked: the spec says so)
        NEXT     

; ---- where the two pages meet ----------------------------------------------
; The first page ends somewhere among the next four handlers, ] \ [ @ (they
; are in falling code order for this), and where exactly differs between the
; builds: NPG1 follows. Every handler below these four must start in the
; second page, and every one above in the first; chktab.py checks both.

; ']' returns: pop an address and jump to it. TOS is parked on the stack
; while rpop uses HL, and the drop at the end brings it back.
h_ret:  PUSH    H
ret2:   POPR     
        MOV     B,H
        MOV     C,L
        DROP     

; '\' ( flag -- ): true skips to the next ')' or ']' at this level; ')'
; drops the block start, ']' returns. No closer at all ends the program.
; The flag stays in HL as the spent cell that rdrop and ret2 drop.
h_break:MOV     A,H
        ORA     L
        JZ      h_drop          ; false: just drop the flag
        CALL    skip
        ORA     A               ; skip returns 0 for ')'
        JNZ     ret2
        JMP     rdrop

; '[' followed by a letter stores the body's address in that letter's cell:
; uppercase is a word, lowercase a variable. Followed by a space it pushes
; the body's address instead. Either way it then skips to the matching ']'.
; (The unchecked build takes anything that is not a letter as the space; the
; checked build stops on it.)
h_def:  LDAX    B
        INX     B
        SUI     'A'             ; a letter gives 0-25 or 32-57: lowercase
        MOV     E,A             ;   lands 64 bytes up
        ANI     0DFh            ; fold case
        CPI     26
        JNC     def2            ; not a letter
        MOV     A,E
        ADD     A
        MOV     E,A
        MVI     D,LETPAGE       ; DE -> cell
        MOV     A,C
        STAX    D
        INR     E
        MOV     A,B
        STAX    D
        JMP     skipnx
def2:
        IF      CHECKED
        MOV     A,E
        CPI     ' '-'A'+256
        JNZ     e_brack         ; anything but a letter or a space
        ENDIF
        PUSH    H               ; an anonymous block: push its address
        MOV     H,B
        MOV     L,C
skipnx:
        IF      CHECKED
        DCX     B               ; back onto the letter, so that skip finds its
        ENDIF                   ;   opener, the '[', just before where it starts
skipo:  CALL    skip
        NEXT     

h_fetch:MOV     E,M             ; '@'
        INX     H
        MOV     D,M
        XCHG
        NEXT     

; =============================================================================
;  Handlers that must start in the image's second page.
;  '?' is the last (with ',' inside it in the unchecked build), so its long
;  tail may run past that page.
; =============================================================================

; ---- flow control ----------------------------------------------------------

; '(' ( flag -- ): true pushes the block start and enters; false skips to
; the matching ')'.
h_open: MOV     A,H
        ORA     L
        POP     H
        JZ      skipo
        PUSH    H               ; (rpushd pops it again)
        MOV     D,B
        MOV     E,C             ; the block starts at the IP
        JMP     rpushd

; ')' ( flag -- ): true jumps back to the block start (and keeps it); false
; drops it and carries on.
h_close:MOV     A,H
        ORA     L
        JZ      rdrop
        IF      QK
        JMP     closeq          ; (out of the handlers' pages: see Speed-ups)
        ENDIF
        IF      1-QK
        POPR                    ; pop the block start ...
        MOV     B,H
        MOV     C,L             ; ... jump to it ...
        XCHG
        JMP     rpushd          ; ... and push it back (which drops the flag)
        ENDIF

; ---- arithmetic and logic: ( NOS TOS -- result ) ---------------------------

; '-' has two jobs: directly before a digit it starts a negative number.
h_sub:  LDAX    B
        SUI     '0'
        CPI     10
        JC      negnum
        NEGH                    ; a - b = a + (-b): fall into '+'
h_add:  POP     D
        DAD     D
        NEXT     

h_and:  POP     D
        MOV     A,H
        ANA     D
        MOV     H,A
        MOV     A,L
        ANA     E
        MOV     L,A
        NEXT     

; Signed compares. Both are "DE < HL" for the right pair: > swaps the two
; cells first (XTHL), < doesn't. There is no overflow flag, so the signed
; answer is the unsigned borrow of DE - HL, flipped when the signs differ.
; SBB A turns a carry into -1 or 0 with no branch.
h_gt:   XTHL                    ; a > b  is  b < a
h_lt:   POP     D               ; a < b: DE = a, HL = b
        MOV     A,E
        SUB     L
        MOV     A,D
        SBB     H
        SBB     A               ; A = -1 if DE < HL unsigned
        MOV     L,A
        MOV     A,H
        XRA     D
        RAL                     ; carry = the signs differ
        SBB     A
        XRA     L               ; flip when they do
        MOV     H,A
        MOV     L,A
        NEXT     

h_eq:   POP     D
        MOV     A,L
        XRA     E
        MOV     L,A
        MOV     A,H
        XRA     D
        ORA     L               ; zero if equal
        SUI     1               ; carry only for zero
        SBB     A
        MOV     H,A
        MOV     L,A
        NEXT     

; '*': shift-and-add on the multiplier's low bit, so it stops as soon as the
; multiplier is used up; only the low 16 bits are kept.
        IF      QK
h_mul:  POP     D               ; DE = multiplicand
        JMP     mulq            ; (out of the handlers' pages: see Speed-ups)
        ENDIF
        IF      1-QK
h_mul:  POP     D               ; DE = multiplicand
        PUSH    B
        MOV     B,H
        MOV     C,L             ; BC = multiplier
        LXI     H,0
mul1:   MOV     A,B
        ORA     A               ; clear carry
        RAR
        MOV     B,A
        MOV     A,C
        RAR
        MOV     C,A             ; BC >> 1, carry = the bit shifted out
        JNC     mul2
        DAD     D
mul2:   XCHG
        DAD     H               ; multiplicand << 1
        XCHG
        MOV     A,B
        ORA     C
        JNZ     mul1
        POP     B
        NEXT     
        ENDIF

; '/' ( a b -- q r ): the remainder is on top. Truncates toward zero; r takes
; a's sign. Divide |a| by |b|, then q gets the sign of a XOR b and r the sign
; of a. Dividing by zero returns two cells of no meaning; the checked build
; stops on it.
h_div:
        IF      CHECKED
        MOV     A,H
        ORA     L
        JZ      e_zero
        ENDIF
        POP     D               ; DE = a, HL = b
        PUSH    B
        MOV     A,D
        ORA     A
        PUSH    PSW             ; S flag = sign of a (for r)
        XRA     H
        PUSH    PSW             ; S flag = sign of q
        MOV     A,H
        ORA     A
        CM      neg16           ; HL = |b|
        XCHG
        MOV     A,H
        ORA     A
        CM      neg16           ; HL = |a|, DE = |b|
        CALL    udiv            ; HL = q, BC = r
        POP     PSW
        CM      neg16           ; q's sign
        XCHG                    ; DE = q
        MOV     H,B
        MOV     L,C             ; HL = r
        POP     PSW
        CM      neg16           ; r's sign
        POP     B
        PUSH    D               ; q under r
        NEXT     

; ---- stack and storage -----------------------------------------------------

h_dup:  PUSH    H               ; ':'
        NEXT     

h_swap: XTHL                    ; '%'
        NEXT     

; (The checked build tests the address before it takes the value off the
; stack, so that an error report shows both.)
h_store:                        ; '!' ( n addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        POP     D
        MOV     M,E
        INX     H
        MOV     M,D
        DROP     

h_cstore:                       ; '.' ( c addr -- )
        IF      CHECKED
        CALL    chkst
        ENDIF
        POP     D
        MOV     M,E
        DROP     

; ---- console ---------------------------------------------------------------

; 22h pushes the address of the text after it and skips the string.
h_str:  PUSH    H
        MOV     H,B
        MOV     L,C
        CALL    skipstr
        IF      CHECKED
        ORA     A               ; 0: the text ran out before the closing quote
        JZ      e_quote
        ENDIF
        NEXT     

; '$' prints the string at TOS, decoding escapes: '/' plus a character from
; 60h to 7Eh is one of the escapes at pesc; '/' plus any other character
; clears that character's bit 6 (/M is CR, and / then DEL gives '?'; '/',
; '"' and '?' have no bit 6, so //, /" and /? give themselves).
        IF      1-CHECKED
h_print:JMP     prlp            ; (the loop is with the escapes, out of the
PRLOOP  EQU     prlp            ;   way of the handlers, which must fit in
PRAGAIN EQU     prlp            ;   the image's first two pages)
        ENDIF
        IF      CHECKED
; (The checked build has the loop as a routine, prstr, which the error
; report uses too. The address is kept meanwhile, for a report: it shows
; the stack as it was before the '$'. /~ comes back to hp1.)
h_print:SHLD    PSAVE
hp1:    CALL    prstr
        DROP     
        ENDIF

h_emit: MOV     A,L             ; "'"
        PUTA     
h_drop: DROP                    ; ';' is this one byte

; '#' prints TOS as a signed decimal number, with no space after it.
h_num:  PUSH    B
        CALL    psgn
        POP     B
        DROP     

        IF      CHECKED         ; (the checked build has no room to start ','
h_cfetch:MOV    L,M             ;   as late as the unchecked one does: see
        MVI     H,0             ;   the end of '?')
        NEXT     
        ENDIF

; '?' ( n -- c ) or ( -n -- addr )
;   n > 0: wait about n ms for a key; 0 if none came
;   n = 0: wait for a key
;   n < 0: read a line of at most -n characters, with echo. The buffer
;          holds 127 characters and the CR: a bigger count is taken as 127.
h_key:  MOV     A,H
        ORA     A
        JM      line
kt1:    MVI     E,MSLOOP        ; one millisecond, roughly
kt2:    CALL    getk
        JNZ     kt3
        DCR     E
        JNZ     kt2
        MOV     A,H             ; 0? never counts down: it waits
        ORA     L
        JZ      kt1
        DCX     H
        MOV     A,H
        ORA     L
        JNZ     kt1             ; A = 0 if the time ran out
        IF      1-CHECKED
        DB      0FEh            ; (CPI: steps over the one byte of ',')
h_cfetch:MOV    A,M             ; ',' shares '?'s ending: A becomes TOS
        ENDIF
kt3:    MOV     L,A
        MVI     H,0
        NEXT     

        ; Backspace takes the last character back (and is echoed as
        ; it is), CR ends (stored, not echoed), every other key is stored and
        ; echoed until the line is full. The line buffer starts at offset 80h
        ; of its page, so L alone is the place in the line: D holds the L of
        ; a full line.
line:   LXI     D,127           ; TOS is minus the count: adding 127 carries
        DAD     D               ;   only for 1 to 127, and leaves 127 - count
        SBB     A
        ANA     L               ; (0 for a count that is too big)
        CMA
        MOV     D,A             ; D = the L of a full line: 80h + count, FFh
                                ;   at most
        LXI     H,LINEBUF
ln2:    CALL    getk
        JZ      ln2
        CPI     13
        JZ      ln5
        CPI     8
        JZ      ln4
        MOV     E,A
        MOV     A,L
        CMP     D
        JZ      ln2             ; full
        MOV     M,E
        INR     L
        MOV     A,E
ln3:    PUTA     
        JMP     ln2
ln4:    DCR     L               ; Backspace: one back, and echo it,
        JM      ln3             ;   unless the line was empty (L left the
        INR     L               ;   upper half of the page)
        JMP     ln2
ln5:    MOV     M,A             ; the CR
        MVI     L,LINEBUF & 0FFh
        NEXT     

; =============================================================================
;  Dispatch table: the low byte of each handler's address, in code order.
;  It must not cross a page (the dispatcher only adds to its low byte).
; =============================================================================
; The handlers of the first NPG1 characters start in the image's second page.
; ] \ [ @ sit where the two pages meet, and which side each lands on
; differs between the builds, so the count is worked out here.
; (One division to a line: asm80 only rounds down when it stores a value.)
        IF      1-FAST
PGRET   EQU     (h_ret-BASE)/256        ; 0 = first page, 1 = second
PGBRK   EQU     (h_break-BASE)/256
PGDEF   EQU     (h_def-BASE)/256
PGFET   EQU     (h_fetch-BASE)/256
NPG1    EQU     21 + PGFET + PGDEF + PGBRK + PGRET
        ENDIF
        IF      (1-FAST)*(1-PTLATE)
PTAB:
        PTABLE
PTABEND:
        ENDIF

; =============================================================================
;  Routines (no handler starts past this point)
; =============================================================================

; Digits: step back onto the first digit and read the whole number.
digit:  PUSH    H
        DCX     B
        CALL    rdnum
        NEXT     

; negnum: '-' directly before a digit: read the number, negate it.
negnum: PUSH    H
        CALL    rdnum
        NEGH     
        NEXT     

; rdnum: read decimal digits at IP into HL; IP is left on the first
; non-digit. Values wrap at 16 bits, as the spec says.
rdnum:  LXI     H,0
rdn1:   LDAX    B
        SUI     '0'
        CPI     10
        RNC
        INX     B
        MOV     D,H
        MOV     E,L
        DAD     H
        DAD     H
        DAD     D
        DAD     H               ; HL * 10
        MOV     E,A
        MVI     D,0
        DAD     D
        JMP     rdn1

; udiv: unsigned HL / DE (DE <= 8000h). Returns HL = quotient, BC = remainder.
; Uses A, BC; the caller saves the IP. HL holds the dividend and, as its bits
; leave at the top, the quotient bits arrive at the bottom. The loop counter
; lives on the stack, since A is busy with the shifts.
; Dividing by 2 is one shift (the spec wants that fast).
udiv:   LXI     B,0
        IF      1-QK
        MOV     A,E
        XRI     2
        ORA     D
        JNZ     udv0
        ORA     H               ; A was 0, and the carry is clear
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A             ; the quotient
        MOV     A,B
        RAL
        MOV     C,A             ; the remainder: the bit that fell out
        RET
        ENDIF
        IF      QK
; (The builds with room divide by any power of two with shifts: 2, and 32,
; 64, 256 and the like, which fixed point and byte work use all the time.)
        MOV     A,D
        ORA     A
        JNZ     uq1             ; 256 and up
        ORA     E
        JZ      udv0            ; by 0: the long way (it means nothing anyway)
        DCR     A
        ANA     E
        JNZ     udv0            ; not a power of two
        MOV     A,E             ; by 2^k below 256: q = HL >> k, and
        DCR     A               ;   r = L & (2^k - 1)
        ANA     L
        MOV     C,A
        ENDIF
        IF      QK*(1-FAST)
uq2:    MOV     A,E             ; one shift for each halving of E down to 1
        ORA     A
        RAR
        RC
        MOV     E,A
        MOV     A,H             ; (the carry is clear: E's bit 0 was 0)
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A
        JMP     uq2
        ENDIF
        IF      FAST
; (the fast build: the shifts unrolled. By 16 to 128 it is fewer shifts to
; go the other way: A:HL up by 8 - k, and A:H is the quotient)
uq2:    MOV     A,E
        CPI     16
        JNC     uqh
        CPI     2
        RC                      ; by 1
        JZ      ur1
        CPI     4
        JZ      ur2
ur3:
        MOV     A,H
        ORA     A
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A
ur2:
        MOV     A,H
        ORA     A
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A
ur1:
        MOV     A,H
        ORA     A
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A
        RET
uqh:    CPI     64
        MVI     A,0
        JZ      ul2
        JNC     ul1
        MOV     A,E
        CPI     32
        MVI     A,0
        JZ      ul3
        DAD     H               ; by 16
        ADC     A
ul3:    DAD     H
        ADC     A
ul2:    DAD     H
        ADC     A
ul1:    DAD     H
        ADC     A
        MOV     L,H
        MOV     H,A
        RET
        ENDIF
        IF      QK
uq1:    MOV     A,E
        ORA     A
        JNZ     udv0
        MOV     A,D
        DCR     A
        ANA     D
        JNZ     udv0            ; not a power of two
        MOV     A,D             ; by 2^k, 256 and up: r = HL & (2^k - 1), and
        DCR     A               ;   q = H >> (k - 8)
        ANA     H
        MOV     B,A
        MOV     C,L
        MOV     L,H
        MVI     H,0
        MOV     E,D
        JMP     uq2
        ENDIF
        IF      1-FAST
udv0:   MVI     A,16
        PUSH    PSW
udv1:   DAD     H               ; next dividend bit into the carry
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      udv2
        MOV     B,A             ; BC - DE (high byte; A holds it)
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
udv2:   POP     PSW
        DCR     A
        PUSH    PSW
        JNZ     udv1
        POP     PSW
        RET
        ENDIF
        IF      FAST
; (the fast build: the same 16 rounds, unrolled; and a dividend below 256
; starts 8 bits up and takes only the last 8, since its first 8 would only
; shift zeros)
udv0:   MOV     A,H
        ORA     A
        JZ      uvs
uv0:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw0
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw0:
uv1:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw1
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw1:
uv2:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw2
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw2:
uv3:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw3
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw3:
uv4:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw4
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw4:
uv5:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw5
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw5:
uv6:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw6
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw6:
uv7:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw7
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw7:
uv8:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw8
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw8:
uv9:    DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw9
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw9:
uv10:   DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw10
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw10:
uv11:   DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw11
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw11:
uv12:   DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw12
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw12:
uv13:   DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw13
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw13:
uv14:   DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw14
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw14:
uv15:   DAD     H
        MOV     A,C
        RAL
        MOV     C,A
        MOV     A,B
        RAL
        MOV     B,A             ; BC = BC*2 + bit
        MOV     A,C
        SUB     E
        MOV     A,B
        SBB     D               ; carry if BC < DE
        JC      uw15
        MOV     B,A
        MOV     A,C
        SUB     E
        MOV     C,A
        INR     L               ; quotient bit
uw15:
        RET
uvs:    MOV     H,L
        MVI     L,0
        JMP     uv8
        ENDIF

; psgn: print HL as a signed number. Uses BC.
psgn:   MOV     A,H
        ORA     A
        JP      pdec
        MVI     A,'-'
        PUTA     
        NEGH     
; pdec: print HL unsigned, by recursion on HL / 10 (the stack holds digits).
; Uses BC.
pdec:   LXI     D,10
        CALL    udiv            ; HL = HL / 10, C = the last digit
        MOV     A,C
        PUSH    PSW
        MOV     A,H
        ORA     L
        CNZ     pdec
        POP     PSW
        ADI     '0'
        PUTA     
        RET

; (The table goes here instead in the builds where, before the routines, it
; would cross a page: PTLATE. If it would cross one here too, it starts on
; the next page: PTPAD is 0 unless it must.)
        IF      (1-FAST)*PTLATE
PTPH    EQU     $ & 0FFh
PTPX    EQU     (PTPH + 31) / 256
PTPAD   EQU     PTPX * (256 - PTPH)
        DS      PTPAD
PTAB:
        PTABLE
PTABEND:
        ENDIF

        IF      1-CHECKED
; '$' prints the string at TOS (see h_print).
prlp:   MOV     A,M
        INX     H
        CPI     22h
        JZ      h_drop
        CPI     '/'
        JNZ     pr1
        MOV     A,M
        INX     H
        CPI     60h
        JC      pr0
        CPI     7Fh
        JC      pesc
pr0:    ANI     0BFh
pr1:    PUTA     
        JMP     prlp
        ENDIF

;-----------------------------------------------------------------------------
; pesc: the escapes of '$'. A = the character after the '/', 60h to 7Eh, and
; HL points past it. Each goes back into the loop that prints the string
; (PRLOOP), but /~ has the stack to see to, and goes back by PRAGAIN.
;    /a-/z   print the variable, as '#' does
;    /{      clear the screen, the cursor to the top left
;    /}      clear from the cursor to the end of the line
;    /|  /`  show the cursor, hide it
;    /~      ( row col -- ) the cursor to that row and column, from 0
pesc:   CPI     7Eh
        JZ      pat
        LXI     D,PRLOOP        ; the others return into the loop
        PUSH    D
        SUI     7Bh             ; { 0, | 1, } 2, and no borrow
        JNC     pcon
        ADI     1Ah             ; a-z: 0-25, and a carry; `: FFh, and none
        JNC     phide
        ADD     A               ; the variable's cell
        ADI     40h
        PUSH    H
        PUSH    B
        MOV     L,A
        MVI     H,LETPAGE
        MOV     A,M
        INR     L
        MOV     H,M
        MOV     L,A
        CALL    psgn
        POP     B
        POP     H
        RET

; /~ ( row col addr -- ): the two cells under the string's address go. In
; the checked build '$' is the routine prstr: its own return address goes
; first, and hp1 calls it again afterwards. There each /~ first looks that
; its two cells are there, and is s if not, before it prints anything.
pat:
        IF      CHECKED
        XTHL                    ; the text pointer over prstr's return address
        LXI     H,(6-DSTOP)&0FFFFh ; a carry: the two cells aren't there
        DAD     SP
        JC      e_under
        POP     H
        ENDIF
        POP     D               ; DE = the column
        XTHL                    ; HL = the row; the text pointer is kept
        IF      1-ANS
        CALL    CONAT
        POP     H
        JMP     PRAGAIN

; With ANSI = 0 the machine's routines do the rest.
pcon:   JZ      CONCLS          ; /{
        CPI     2
        JZ      CONEOL          ; /}
        DB      0FEh            ; /|  (CPI steps over the XRA: A = 1, show)
phide:  XRA     A               ; /`  (A = 0: hide)
        JMP     CONCUR
        ENDIF
        IF      ANS
        PUSH    B               ; (pdec uses BC)
        PUSH    D
        CALL    csi             ; ESC [ row+1 ; col+1 H (ANSI counts from 1)
        INX     H
        CALL    pdec
        MVI     A,';'
        PUTA     
        POP     H
        INX     H
        CALL    pdec
        MVI     A,'H'
        PUTA     
        POP     B
        POP     H
        JMP     PRAGAIN

; With ANSI = 1 they are sequences. The carry is clear on the way in.
pshow:  MVI     E,'h'           ; /|  ESC [ ? 2 5 h
        DB      0DAh            ; (JC nn: with no carry it steps over two bytes)
phide:  MVI     E,'l'           ; /`  ESC [ ? 2 5 l
        MVI     A,'?'
        CALL    csia
        MVI     A,'2'
        PUTA     
        MVI     A,'5'
        PUTA     
        MOV     A,E
        PUTA     
        RET

; pcon: /{ /| /}, with A = 0, 1, 2. /{ runs on into csia.
pcon:   DCR     A
        JZ      pshow           ; /|
        MVI     A,'K'
        JP      csia            ; /}  ESC [ K
        MVI     A,'H'           ; /{  ESC [ H ESC [ J
        CALL    csia
        MVI     A,'J'           ; (on into csia)
; csia: ESC [ and then A. csi: ESC [. Both keep all but A.
csia:   PUSH    PSW
        CALL    csi
        POP     PSW
        PUTA     
        RET
csi:    MVI     A,27
        PUTA     
        MVI     A,'['
        PUTA     
        RET
        ENDIF

; skip: read past text to the closer at this level, and return A = 0 if it
; was ')' and 2 if it was ']'. Brackets of both kinds count together;
; strings are stepped over whole. A NUL first ends the program (for '\' with
; no closer; anything else that runs into the NUL had unbalanced brackets
; anyway). D counts the open levels, starting at 1 for the one we are in:
; skip sets it to 0 and falls through the INR that an opener comes back to.
;
; The checked build also looks at the character the skip was started by,
; which is always the one just before where it starts: '(' must end at ')',
; '[' at ']', and neither may run into the NUL (N); a string with no closing
; quote counts as running into it. '\' takes either closer. The place where
; the skip started is kept on the stack, for the report.
        IF      1-QK
; (Without base: no skip cache.)
skip:
        ENDIF
        IF      CHECKED*(1-QK)
        PUSH    B
        DCX     B
        LDAX    B
        INX     B
        MOV     E,A             ; E = the opener: ( [ or \
        ENDIF
        IF      1-QK
        MVI     D,0
sk3:    INR     D               ; an opener: one deeper
sk1:    LDAX    B
        ENDIF
        IF      (1-CHECKED)*(1-QK)
        INX     B
        ORA     A
        JZ      endprog
        ENDIF
        IF      CHECKED*(1-QK)
        ORA     A
        JZ      sk6             ; (the IP stays on the NUL)
        INX     B
        ENDIF
        IF      1-QK
        CPI     22h
        CZ      skipstr         ; leaves A = 22h, which matches nothing below
        SUI     '('             ;   (or 0, and then the NUL is read next)
        JZ      sk3
        DCR     A               ; ')'
        JZ      sk4
        SUI     '['-')'
        JZ      sk3
        CPI     ']'-'['
        JNZ     sk1
sk4:    DCR     D
        ENDIF
        IF      (1-CHECKED)*(1-QK)
        RZ                      ; the closer at this level
        JMP     sk1
        ENDIF
        IF      CHECKED*(1-QK)
        JNZ     sk1
        MOV     D,A             ; the closer at this level: 0 or 2. Bit 1 of the
        XRA     E               ;   opener is 0 for '(' and 1 for '[', and only
        ANI     6               ;   '\' has bit 2: so this is 2 for the wrong
        CPI     2               ;   closer, and only then
        MOV     A,D
        POP     D               ; (where the skip started)
        RNZ
        MOV     B,D             ; N. The place is the opener
        MOV     C,E
        JMP     sk7
sk6:    MOV     A,E             ; the text ran out:
        ANI     4
        JNZ     endprog         ;   '\' with no closer ends the program
        POP     B
sk7:    MVI     A,'N'
        JMP     errp            ; (errp drops skip's return address)
        ENDIF
        IF      QK
; The skip cache. Nearly every skip is one that has happened before (a loop
; skips the same false block on every pass), so the first scan from each
; place is remembered: 64 entries of {start, end}, in the page CPAGE, found
; by the start's low byte (times 4). Only skips that start in the program
; text are kept (the line buffer changes); the cache is emptied whenever a
; run starts (see start). A program that changes its own text while it
; runs is not looked after.
skip:   MOV     A,B
        CPI     PROG/256
        JC      sks             ; below the program text: no cache
        MOV     A,C
        ADD     A
        ADD     A
        MOV     E,A
        MVI     D,CPAGE         ; DE -> the entry
        LDAX    D
        CMP     C
        JNZ     sks
        INR     E
        LDAX    D
        CMP     B
        JNZ     sks
        INR     E
        LDAX    D
        MOV     C,A
        INR     E
        LDAX    D
        MOV     B,A             ; a hit: the IP is past the closer
        DCX     B
        LDAX    B
        INX     B
        SUI     ')'             ; 0 for ')', not 0 for ']'
        RET
sks:    PUSH    B               ; where it starts: the cache's key (and the
        ENDIF                   ;   checked report's place)
        IF      QK*CHECKED
        DCX     B
        LDAX    B
        INX     B
        MOV     E,A             ; E = the opener: ( [ or \
        ENDIF
        IF      QK
; The scan. Most characters are nothing to it, and two range tests rule
; them out: * to Z, and ^ and up. Only NUL " ( ) [ ] count.
        MVI     D,0
sq3:    INR     D               ; an opener: one deeper
sq1:    LDAX    B
        INX     B
        CPI     5Eh
        JNC     sq1             ; ^ _ ` a-z { | } ~ and up: nothing
        CPI     5Bh
        JNC     sqb             ; [ \ ]
        CPI     2Ah
        JNC     sq1             ; * to Z: nothing
        CPI     28h
        JZ      sq3             ; (
        JNC     sqc             ; )
        CPI     22h
        JZ      sqq             ; a string
        ORA     A
        JNZ     sq1             ; the rest below '(': nothing
        ENDIF
        IF      QK*(1-CHECKED)
        JMP     endprog         ; NUL: the end of the program
        ENDIF
        IF      QK*CHECKED
        DCX     B               ; NUL: the IP stays on it
        MOV     A,E             ; the text ran out:
        ANI     4
        JNZ     endprog         ;   '\' with no closer ends the program
        POP     B
sq7:    MVI     A,'N'           ; N. The place is the opener
        JMP     errp            ; (errp drops skip's return address)
        ENDIF
        IF      QK
sqq:    CALL    skipstr         ; step over the string
        JMP     sq1
sqb:    SUI     5Ch             ; [ -1, \ 0, ] 1
        JZ      sq1             ; '\' is nothing here
        JC      sq3             ; [
        MVI     A,2             ; ]
        DB      0FEh            ; (CPI: steps over the XRA)
sqc:    XRA     A               ; )
sq4:    DCR     D
        JNZ     sq1
        ENDIF
        IF      QK*CHECKED
        MOV     D,A             ; the closer at this level (as above): 2 here
        XRA     E               ;   means the wrong closer
        ANI     6
        CPI     2
        MOV     A,D
        POP     D               ; (where the skip started)
        JNZ     sq8
        MOV     B,D
        MOV     C,E
        JMP     sq7
sq8:
        ENDIF
        IF      QK*(1-CHECKED)
        POP     D               ; where the skip started
        ENDIF
        IF      QK
; The closer at this level: remember the skip (if it started in the program
; text), and return A = 0 for ')' or 2 for ']'. DE = the start, BC = the end.
        PUSH    H
        MOV     H,A
        MOV     A,D
        CPI     PROG/256
        JC      sq9
        MOV     A,E
        ADD     A
        ADD     A
        MOV     L,A
        MOV     A,H
        MVI     H,CPAGE
        MOV     M,E
        INR     L
        MOV     M,D
        INR     L
        MOV     M,C
        INR     L
        MOV     M,B
        POP     H
        RET
sq9:    MOV     A,H
        POP     H
        RET
        ENDIF

; skipstr: IP is inside a string; step past its closing quote. '/' escapes
; the next character, so '/"' does not end it. Leaves A = 22h.
        IF      1-CHECKED
ss0:    INX     B
skipstr:LDAX    B
        INX     B
        CPI     '/'
        JZ      ss0
        CPI     22h
        JNZ     skipstr
        RET
        ENDIF
        IF      CHECKED
; The checked build never steps over a NUL: if the text runs out first it
; returns A = 0 with the IP on the NUL.
skipstr:LDAX    B
        ORA     A
        RZ
        INX     B
        CPI     22h
        RZ
        CPI     '/'
        JNZ     skipstr
        LDAX    B               ; the escaped character
        ORA     A
        RZ
        INX     B
        JMP     skipstr
        ENDIF

; hexc: if the character at IP is a hex digit (0-9, A-F, a-f), step over it
; and return its value in A with the carry set; otherwise leave the IP and
; return with the carry clear.
hexc:   LDAX    B
        SUI     '0'
        CPI     10
        JC      hc1
        ANI     0DFh
        SUI     11h
        CPI     6
        RNC
        SUI     0F6h            ; + 10, and sets the carry
hc1:    INX     B
        RET

;  ---- Speed-ups (base builds) -------------------------------------------
;  The skip cache and '/' by a power of two are above. These are the
;  handlers' tails that the builds with room take, kept here, out of the
;  handlers' first two pages.
        IF      QK
; '*' with an operand below 256: that one becomes the multiplier, a byte in
; A, and the loop stops as soon as its bits are used up (most
; multiplications have one, a count or a small constant). With both at 256
; and up, the multiplier's low byte takes exactly 8 rounds (a marker bit
; shifted in above it says when), and its high byte goes on as a small one.
; DE = NOS, HL = TOS.
mulq:   MOV     A,H
        ORA     A
        JZ      mq8             ; the multiplier is below 256
        MOV     A,D
        ORA     A
        JNZ     mq16
        XCHG                    ; the multiplicand is: it becomes the multiplier
mq8:    MOV     A,L
        LXI     H,0
        ORA     A               ; (clears the carry)
        JZ      mq9
mq1:    RAR                     ; the next bit
        JNC     mq2
        DAD     D
mq2:    XCHG
        DAD     H               ; multiplicand << 1
        XCHG
        ORA     A               ; bits left? (and clears the carry)
        JNZ     mq1
mq9:    NEXTQ    
mq16:   PUSH    B
        MOV     B,H             ; the high byte, for later
        MOV     A,L
        LXI     H,0
        STC                     ; the marker
        RAR
mq3:    JNC     mq4
        DAD     D
mq4:    XCHG
        DAD     H
        XCHG
        CPI     1               ; only the marker left: 8 rounds done (and
        RAR                     ;   the carry was clear for the shift)
        JNZ     mq3
        MOV     A,B
        POP     B
        ORA     A
        JMP     mq1             ; the high byte, as a small multiplier
; A true ')' reads the block start where it is, on top of the return stack,
; instead of popping it and pushing it back; the break key is looked at as
; rpushd would.
closeq: LHLD    RSP
        MOV     C,M
        INX     H
        MOV     B,M
        LXI     H,BRKCNT
        DCR     M
        POP     H               ; (keeps the flags)
        CZ      pollk
        NEXTQ    
        ENDIF
        IF      SBASEU
; a-z, in the unchecked builds: a variable followed by '@' or '!' is fetched
; or stored in the same step (x@ is the commonest pair in most programs).
; (A checked build checks the stacks between the two, so it keeps them apart.)
lower   EQU     lowq
lowq:   ADD     A
        MOV     E,A
        MVI     D,LETPAGE       ; DE -> the cell
        LDAX    B
        CPI     '@'
        JZ      lwf
        CPI     '!'
        JZ      lws
        PUSH    H
        XCHG                    ; TOS = the cell's address
        NEXT     
lwf:    INX     B               ; x@: TOS = the cell's value
        PUSH    H
        XCHG
        MOV     E,M
        INX     H
        MOV     D,M
        XCHG
        NEXT     
lws:    INX     B               ; x!: the cell = TOS, and NOS comes up
        XCHG
        MOV     M,E
        INX     H
        MOV     M,D
        POP     H
        NEXT     
        ENDIF

; =============================================================================
;  Console layer. rawk is the host's key routine: a waiting key in A (zero
;  flag clear), or A = 0 with the zero flag set when none is waiting. putc
;  (RST 5) prints A. Both keep BC, DE and HL. In the generic build they are
;  the host's KEY and CONOUT routines themselves.
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
;  data stack, and TOS in HL.
; =============================================================================
        IFN     CPM
rawk    EQU     KEY
        ENDIF
; pollk: the break check (see rpushd).
pollk:  CALL    rawk
        RZ                      ; no key
        STA     KEYBUF          ; held for the next '?'
pk1:    CPI     3               ; (getk joins here)
        RNZ
; ctlc: Ctrl-C has been read. If the break key is on, that is the end. If
; the program has turned it off, wait about 250 ms for one more key: a
; second Ctrl-C is the end too; any other key is held (the newest wins),
; and the Ctrl-C goes to the program: returns A = 3, zero flag clear.
ctlc:   LDA     BRKOFF
        ORA     A
        JZ      brk
        PUSH    D
        LXI     D,250*MSLOOP
ct1:    CALL    rawk
        JNZ     ct2
        DCX     D
        MOV     A,D
        ORA     E
        JNZ     ct1
ct2:    POP     D               ; A = the second key, or 0 if none came
        CPI     3
        JZ      brk
        ORA     A
        JZ      ct3
        STA     KEYBUF
ct3:    MVI     A,3
        ORA     A
        RET
; getk: a key for '?', or A = 0 and the zero flag if there is none.
getk:   PUSH    H               ; a held key goes first, and is taken out of
        LXI     H,KEYBUF        ;   the buffer
        MOV     A,M
        MVI     M,0
        POP     H
        ORA     A
        RNZ
        CALL    rawk
        RZ
        JMP     pk1             ; Ctrl-C? If not, that is the key
        IF      1-CHECKED
brk     EQU     endprog         ; the unchecked build stops without a word;
        ENDIF
        IF      CHECKED
brk     EQU     e_break         ;   the checked build reports B
        ENDIF
        IF      CPM
; (In a CP/M build the letters and digits are here, out of the way of the
; handlers, which must fit in the image's first two pages. The same code as
; in the generic build.)
; ---- the letters and digits --------------------------------------------------

; a-z: push the cell's address (the cell is the variable)
        ENDIF
        IF      CPM*(1-SBASEU)
lower:  PUSH    H
        ADD     A
        MOV     L,A
        MVI     H,LETPAGE
        NEXT     
        ENDIF
        IF      CPM

; A-Z: call the word. The return address (the IP after the letter) goes on
; the return stack, and the IP becomes the address in the letter's cell.
upper:  PUSH    H               ; keep TOS: rpushd pops it back
        ADD     A
        MOV     L,A
        MVI     H,LETPAGE       ; HL -> cell
        MOV     D,B
        MOV     E,C             ; DE = the return address
        MOV     C,M
        INX     H
        MOV     B,M             ; IP = the word's body, and fall into rpushd

; rpushd: push DE on the return stack, then pop TOS off the data stack and
; go on. Every push of the return stack ends here: for a word call the cell
; popped is the TOS that upper parked; for '(' and '{' it is the cell under
; the one that was used up.
;
; The break key is looked at here, so at every word call and loop-back (and
; block entry and '{'), but only one time in 256: BRKCNT counts them. Reading
; the keyboard can be slow (it is a BDOS call under CP/M).
rpushd: LHLD    RSP
        DCX     H
        MOV     M,D
        DCX     H
        MOV     M,E
        SHLD    RSP
        LXI     H,BRKCNT
        DCR     M
        POP     H               ; (keeps the flags)
        CZ      pollk
        NEXT     

rawk:   MVI     A,0FFh          ; BDOS 6 with E = FFh: a key, or 0
; putc: BDOS 6 for every character. BDOS 2 would check for ^S while
; printing and could swallow a key that BDOS 6 then never sees.
putc:   PUSH    B
        PUSH    D
        PUSH    H
        MOV     E,A
        MVI     C,6
        CALL    BDOS
        POP     H
        POP     D
        POP     B
        ORA     A               ; (for getk)
        RET
        ENDIF

; =============================================================================
;  Checked build: the checks and the error report
; =============================================================================
        IF      CHECKED
; chkhp: HL = the new heap top, DE = the count, the carry is from adding
; it, and the old top is on the stack under the return address. Stop if the
; new top is not below the limit page, or is below the program's end.
chkhp:
        ENDIF
        IF      CHECKED*CPM
        ; With this much room a top that wrapped round can land back in
        ; range, so the add is tested too: growing must not carry, and
        ; releasing must.
        MOV     A,D
        RAR                     ; the carry comes in above the count's sign:
        ADI     40h             ;   bit 7 = carry XOR sign
        ADD     A
        JC      e_heap
        LDA     0007h
        DCR     A
        CMP     H
        JC      e_heap
        ENDIF
        IF      CHECKED*(1-CPM)
        ; (Here the program's space is under 32K, so a top that wrapped
        ; round always falls outside it.)
        MOV     A,H
        CPI     HEAPLIM
        JNC     e_heap
        ENDIF
        IF      CHECKED
        XCHG
        PUSH    H               ; the count
        LHLD    NPEND
        DAD     D               ; carry: at or above the program's end
        POP     H
        XCHG
        RC
e_heap: XCHG                    ; put the count back in TOS for the report,
        POP     D               ;   and drop the return address (errp drops
        MVI     A,'H'           ;   the old top)
        JMP     errp

; chkst: stop unless HL is in the program's own space: from the letter page
; up to the heap limit (the OS, or HEAPLIM), so the interpreter's stacks and
; whatever lies above the limit are safe. Memory above the heap top but
; below the limit is the program's own: Tiny BASIC keeps its lines there.
; It is the page of HL + 1 that is tested, so that one test serves both
; bytes of a cell: the last byte below the limit can't be stored to with '.'.
; Keeps HL and BC. It runs on into its own error entry.
chkst:  INX     H
        MOV     A,H
        DCX     H
        CPI     LETPAGE
        JC      e_store
        ENDIF
        IF      CHECKED*(1-CPM)
        CPI     HEAPLIM
        RC
        ENDIF
        IF      CHECKED*CPM
        MOV     E,A
        LDA     0007h           ; the BDOS page is the heap limit
        DCR     A
        CMP     E
        RNC
        ENDIF
        IF      CHECKED
; Two error entries for errors found inside a routine: the first hides the
; second inside a 3-byte LXI D (the 11h); errp then drops the routine's
; return address.
e_store:MVI     A,'O'           ; a store outside the program's space
        DB      11h
e_break:MVI     A,'B'           ; Ctrl-C (found inside pollk or getk)
        JMP     errp

; prstr: print the string at HL, to its closing quote, decoding '/' (this is
; '$', and the error report's texts). A NUL first is an error: Q.
prstr:  MOV     A,M
        INX     H
        CPI     22h
        RZ
        ORA     A
        JZ      e_dollar
        CPI     '/'
        JNZ     prs1
        MOV     A,M
        INX     H
        CPI     60h
        JC      prs0
        CPI     7Fh
        JC      pesc
prs0:   ANI     0BFh
prs1:   PUTA     
        JMP     prstr
PRLOOP  EQU     prstr           ; (where the escapes go back to)
PRAGAIN EQU     hp1             ; (and where /~ goes back to)

; pmsg: print the text that follows the CALL, to its closing quote. Keeps HL.
; pnl: the same, on a new line.
pnl:    MVI     A,13
        PUTA     
        MVI     A,10
        PUTA     
pmsg:   XTHL
        CALL    prstr
        XTHL
        RET

; chkstk: both stacks are checked once per character, not in every handler.
; The data stack is right when SP lies in the 256 bytes below DSTOP: adding
; the constant carries if it is above (cells were popped that were never
; pushed), and leaves a high byte of FFh if it is in range. Errors are found
; a character late at most: the bytes above DSTOP and the guard band below
; the page take what happens meanwhile.
chkstk: XCHG                    ; DE = TOS (HL is needed for the pointers)
        LXI     H,(1-DSTOP)&0FFFFh ; (SP is 2 lower here: the call)
        DAD     SP
        JC      e_under
        INR     H
        JNZ     e_over
        LHLD    RSP             ; the return stack: in its page (or it has
        MOV     A,H             ;   overflowed), and not above its empty
        CPI     RSPAGE          ;   position (an underflow stays inside the
        JNZ     e_rover         ;   page, in the guard band)
        MOV     A,L
        CPI     RSTOP&0FFh+1
        JNC     e_runder
        XCHG                    ; TOS back
        RET
e_runder:LXI    H,RSTOP         ; return stack underflow: it counts as empty
        SHLD    RSP
        MVI     A,'r'
        DB      21h             ; (LXI H hides the next entry; HL is free)
e_rover:MVI     A,'R'           ; return stack overflow
        DB      21h
e_over: MVI     A,'S'           ; data stack overflow
        XCHG                    ; TOS back
        JMP     errp
e_under:LXI     SP,DSTOP        ; data stack underflow: it counts as empty
        MVI     A,'s'
        JMP     error

; e_hi: the inner loop read a reserved byte, 80h-FFh: X. But a word cell that
; was never defined still holds 0000h, and the byte there is a JMP, C3h, in
; every build: if the IP is in page zero, this was a call of an undefined
; word. The call is undone, so the place is the call itself.
e_hi:   INR     B
        DCR     B
        JNZ     e_resv
        PUSH    H
        POPR     
        MOV     B,H
        MOV     C,L
        POP     H
        MVI     A,'U'
        JMP     error
; e_dollar: '$' ran into a NUL (in prstr): Q, with the string's address
; back in TOS. prstr's return address goes first. But if '$' had no
; address at all (the stack was empty), it is s, found now: chkstk, called
; one cell up, sees the stack past its empty place then.
e_dollar:POP    D
        POP     H
        CALL    chkstk
        PUSH    H
        LHLD    PSAVE
        DB      11h             ; (LXI D hides e_quote's first two bytes)
; Error entries. Each loads its letter and then hides the next entry inside
; a 3-byte LXI D (the 11h), so they all fall through to `error`.
e_quote:MOV     B,H             ; an unclosed string: HL is its address, one
        MOV     C,L             ;   past the opening quote, which is the place
        MVI     A,'Q'
        DB      11h
e_resv: MVI     A,'X'           ; a reserved byte outside a string
        DB      11h
e_zero: MVI     A,'Z'           ; dividing by zero
        DB      11h
e_brack:MVI     A,'W'           ; bad character after [
        DB      0FEh            ; (CPI hides the one byte of errp)
; errp: an error found inside a routine: drop its return address first.
errp:   POP     D

; error: the report, then the end. A = the letter, BC = one past the place,
; HL = TOS, and both stacks as the report is to show them:
;
;   Err X @ line,col
;   D:n: the top 8 cells at most, bottom to top
;   R:n
error:  PUSH    H               ; now the whole data stack is in memory
        MOV     E,A
        CALL    pnl
        DB      "Err ",22h
        MOV     A,E
        PUTA     
        CALL    pmsg
        DB      " @ ",22h
        DCX     B               ; BC = the place
        ; The line and column. A place below the program is in the line
        ; buffer: line 0. Otherwise count the LFs from the program's start;
        ; DE = the line's number, HL = where it starts.
        LXI     H,LINEBUF
        LXI     D,0
        MOV     A,B
        CPI     PROG/256
        JC      er3
        INR     H
        MOV     L,E             ; HL = PROG
er1:    INX     D               ; a new line starts at HL
        PUSH    H
er2:    MOV     A,L
        SUB     C
        MOV     A,H
        SBB     B
        JNC     er2x            ; reached the place
        MOV     A,M
        INX     H
        CPI     10
        JNZ     er2
        POP     PSW
        JMP     er1
er2x:   POP     H
er3:    PUSH    B
        PUSH    H
        XCHG
        CALL    pdec            ; the line
        MVI     A,','
        PUTA     
        POP     D
        POP     H
        CALL    sub16
        INX     H
        CALL    pdec            ; the column
        CALL    pnl
        DB      "D:",22h
        LXI     H,(2-DSTOP)&0FFFFh ; SP - (DSTOP-2) is minus twice the depth
        DAD     SP              ;   (the cell at DSTOP-2 was pushed with the
        NEGH                    ;   first value and holds nothing)
        MOV     A,H
        CALL    phal2           ; the depth
        MVI     A,':'
        PUTA     
        MOV     A,C
        CPI     9
        JC      er6
        CALL    pmsg
        DB      " ...",22h
        MVI     C,8
er6:    MVI     H,0             ; C = the number of cells to show
        MOV     L,C
        DAD     H
        DAD     SP              ; HL -> just above the deepest of them
        INR     C
er7:    DCR     C
        JZ      er8
        DCX     H
        MOV     D,M
        DCX     H
        MOV     E,M
        PUSH    H
        PUSH    B
        MVI     A,' '
        PUTA     
        XCHG
        CALL    psgn
        POP     B
        POP     H
        JMP     er7
er8:    CALL    pnl
        DB      "R:",22h
        LHLD    RSP
        XCHG
        LXI     H,RSTOP
        CALL    phalf
        CALL    pnl
        DB      22h
        JMP     endprog
; phalf: print half of HL - DE, and leave it in BC
phalf:  CALL    sub16
phal2:  ORA     A               ; (A = H; this clears the carry)
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A
        PUSH    H
        CALL    pdec
        POP     B
        RET
; sub16: HL = HL - DE. Leaves A = H.
sub16:  MOV     A,L
        SUB     E
        MOV     L,A
        MOV     A,H
        SBB     D
        MOV     H,A
        RET
        ENDIF

; =============================================================================
;  Startup
; =============================================================================
start:
        IF      (1-CPM)*CHECKED
        LXI     SP,DSTOP
        ENDIF
        IF      QK
        LXI     H,CPAGE*256     ; every run starts with an empty skip cache (a
        XRA     A               ;   start of 0000h matches no skip)
skc1:   MOV     M,A
        INR     L
        JNZ     skc1
        ENDIF
        IF      CHECKED
        ; Clear the lower half of the letter page: every variable starts at
        ; 0, every word cell holds 0000h, the address an undefined word is
        ; caught at (see e_hi), and no key is held back.
        LXI     H,LET
        XRA     A
ini1:   MOV     M,A
        INR     L
        JP      ini1            ; +00h to +7Fh
        ENDIF
        IF      CPM
        ; CP/M: the RAM pages follow the image; the heap may grow to the BDOS
        LXI     D,005Ch         ; open the file named on the command line
        MVI     C,15            ; (no such file: the first read fails too,
        CALL    BDOS            ;   and the program is empty)
        LXI     D,PROG
ld1:    PUSH    D
        MVI     C,26            ; set the DMA address
        CALL    BDOS
        LXI     D,005Ch
        MVI     C,20            ; read the next 128 bytes
        CALL    BDOS
        POP     H               ; HL = the address this record went to
        ORA     A
        JNZ     ld2
        LXI     D,128
        DAD     D
        XCHG
        JMP     ld1
ld2:    MVI     M,0             ; the end of the file counts as NUL
        INX     H               ; the heap starts after it
        ENDIF
        IFN     CPM
        LXI     H,PROG          ; the heap starts after the program's NUL
fnul:   MOV     A,M
        INX     H
        ORA     A
        JNZ     fnul
        ENDIF
        SHLD    HEAP
        IF      CHECKED
        NEGH                    ; minus the heap's first address: '_' may not
        SHLD    NPEND           ;   release below it
        ENDIF
        LXI     H,RSTOP         ; the return stack is empty
        SHLD    RSP
        IF      (1-CHECKED)*(1-CPM)
        MOV     H,A             ; (A = 0, from the search for the NUL) no key
        MOV     L,A             ;   is held, and the break key is on (the
        ENDIF                   ;   checked build has cleared these)
        IF      (1-CHECKED)*CPM
        LXI     H,0
        ENDIF
        IF      1-CHECKED
        SHLD    KEYBUF
        ENDIF
        LXI     B,PROG          ; the IP
        NEXT                    ; (its return address is thrown away)

        IF      FAST
; =============================================================================
;  The fast build (SPEED = 2)
;
;  The inner loop is a table: 256 entries, the low bytes of the handlers'
;  addresses in one page and the high bytes in the next. The dispatcher (at
;  next0, and inline, as NEXTF, at the end of the fast build's own entries,
;  so there is no jump back to it; the ordinary handlers end in JMP next0):
;
;      LDAX B / INX B / XCHG / MOV L,A / MVI H,DTAB/256 /
;      MOV A,M / INR H / MOV H,M / MOV L,A / PCHL
;
;  So every entry starts with TOS in DE, not HL. The rest of the punctuation
;  is reached through thunks into the ordinary handlers (XCHG / JMP handler);
;  the letters and digits have one entry each, which knows its cell or its
;  value already.
; =============================================================================
ftstore:XCHG                    ; !
        JMP     h_store
ftstr:  XCHG                    ; "
        JMP     h_str
ftnum:  XCHG                    ; #
        JMP     h_num
ftprint:XCHG                    ; $
        JMP     h_print
ftemit: XCHG                    ; '
        JMP     h_emit
ftcstore:XCHG                   ; .
        JMP     h_cstore
ftdiv:  XCHG                    ; /
        JMP     h_div
ftkey:  XCHG                    ; ?
        JMP     h_key
ftdef:  XCHG                    ; [
        JMP     h_def
ftbreak:XCHG                    ; \
        JMP     h_break
ftalloc:XCHG                    ; _
        JMP     h_alloc
ftgrave:XCHG                    ; `
        JMP     h_grave
; The commonest punctuation, written for the fast build: TOS in DE on the
; way in, and the dispatcher inline on the way out.
fs_add: POP     H               ; +
        DAD     D
        NEXTF
fs_sub: LDAX    B               ; -
        SUI     '0'
        CPI     10
        JC      fs_neg
        POP     H
        MOV     A,L
        SUB     E
        MOV     E,A
        MOV     A,H
        SBB     D
        MOV     D,A
        NEXTD
fs_neg: XCHG                    ; a digit next: a negative number
        JMP     negnum
fs_dup: PUSH    D               ; :
        NEXTD
fs_drop:POP     H               ; ;
        NEXTF
fs_swap:POP     H               ; %
        PUSH    D
        NEXTF
fs_fet: XCHG                    ; @
        MOV     E,M
        INX     H
        MOV     D,M
        NEXTD
fs_cfet:LDAX    D               ; ,
        MOV     E,A
        MVI     D,0
        NEXTD
fs_lt:  POP     H               ; < (HL = a, DE = b: the borrow of a - b, flipped if the signs differ)
        MOV     A,L
        SUB     E
        MOV     A,H
        SBB     D
        SBB     A
        MOV     L,A
        MOV     A,H
        XRA     D
        RAL
        SBB     A
        XRA     L
        MOV     D,A
        MOV     E,A
        NEXTD
fs_gt:  POP     H               ; > (b < a: the borrow of b - a)
        MOV     A,E
        SUB     L
        MOV     A,D
        SBB     H
        SBB     A
        MOV     L,A
        MOV     A,H
        XRA     D
        RAL
        SBB     A
        XRA     L
        MOV     D,A
        MOV     E,A
        NEXTD
fs_eq:  POP     H               ; =
        MOV     A,L
        XRA     E
        MOV     L,A
        MOV     A,H
        XRA     D
        ORA     L
        SUI     1
        SBB     A
        MOV     D,A
        MOV     E,A
        NEXTD
fs_and: POP     H               ; &
        MOV     A,H
        ANA     D
        MOV     D,A
        MOV     A,L
        ANA     E
        MOV     E,A
        NEXTD
fs_or:  POP     H               ; |
        MOV     A,H
        ORA     D
        MOV     D,A
        MOV     A,L
        ORA     E
        MOV     E,A
        NEXTD
fs_xor: POP     H               ; ^
        MOV     A,H
        XRA     D
        MOV     D,A
        MOV     A,L
        XRA     E
        MOV     E,A
        NEXTD
fs_not: MOV     A,E             ; ~
        CMA
        MOV     E,A
        MOV     A,D
        CMA
        MOV     D,A
        NEXTD
fs_mul: POP     H               ; * (the two the other way round: the same)
        JMP     mulq
fs_open:MOV     A,D             ; (
        ORA     E
        JZ      fs_op0
        LHLD    RSP
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LXI     H,BRKCNT
        DCR     M
        POP     H
        CZ      pollk
        NEXTF
fs_op0: POP     H
        CALL    skip
        NEXTF
fs_close:MOV     A,D            ; )
        ORA     E
        JZ      fs_cl0
        LHLD    RSP
        MOV     C,M
        INX     H
        MOV     B,M
        LXI     H,BRKCNT
        DCR     M
        POP     H
        CZ      pollk
        NEXTF
fs_cl0: LHLD    RSP
        INX     H
        INX     H
        SHLD    RSP
        POP     H
        NEXTF
fs_ret: LHLD    RSP             ; ]
        MOV     C,M
        INX     H
        MOV     B,M
        INX     H
        SHLD    RSP
        NEXTD
fs_fromr:PUSH    D              ; }
        LHLD    RSP
        MOV     E,M
        INX     H
        MOV     D,M
        INX     H
        SHLD    RSP
        NEXTD
fd0:    PUSH    D               ; 0
        LXI     D,0
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd1:    PUSH    D               ; 1
        LXI     D,1
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd2:    PUSH    D               ; 2
        LXI     D,2
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd3:    PUSH    D               ; 3
        LXI     D,3
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd4:    PUSH    D               ; 4
        LXI     D,4
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd5:    PUSH    D               ; 5
        LXI     D,5
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd6:    PUSH    D               ; 6
        LXI     D,6
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd7:    PUSH    D               ; 7
        LXI     D,7
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd8:    PUSH    D               ; 8
        LXI     D,8
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fd9:    PUSH    D               ; 9
        LXI     D,9
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm
        NEXTD
fdm:    XCHG                    ; more digits: HL = HL * 10 + the digit
fdm1:   INX     B
        MOV     D,H
        MOV     E,L
        DAD     H
        DAD     H
        DAD     D
        DAD     H
        MOV     E,A
        MVI     D,0
        DAD     D
        LDAX    B
        SUI     '0'
        CPI     10
        JC      fdm1
        NEXTF
; A-Z: call the word. The return address goes on the return stack, the IP
; becomes the word's body, and the break key is looked at as rpushd would.
fuA:    LHLD    RSP             ; A
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+0
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuB:    LHLD    RSP             ; B
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+2
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuC:    LHLD    RSP             ; C
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+4
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuD:    LHLD    RSP             ; D
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+6
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuE:    LHLD    RSP             ; E
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+8
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuF:    LHLD    RSP             ; F
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+10
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuG:    LHLD    RSP             ; G
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+12
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuH:    LHLD    RSP             ; H
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+14
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuI:    LHLD    RSP             ; I
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+16
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuJ:    LHLD    RSP             ; J
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+18
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuK:    LHLD    RSP             ; K
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+20
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuL:    LHLD    RSP             ; L
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+22
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuM:    LHLD    RSP             ; M
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+24
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuN:    LHLD    RSP             ; N
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+26
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuO:    LHLD    RSP             ; O
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+28
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuP:    LHLD    RSP             ; P
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+30
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuQ:    LHLD    RSP             ; Q
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+32
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuR:    LHLD    RSP             ; R
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+34
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuS:    LHLD    RSP             ; S
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+36
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuT:    LHLD    RSP             ; T
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+38
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuU:    LHLD    RSP             ; U
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+40
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuV:    LHLD    RSP             ; V
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+42
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuW:    LHLD    RSP             ; W
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+44
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuX:    LHLD    RSP             ; X
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+46
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuY:    LHLD    RSP             ; Y
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+48
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
fuZ:    LHLD    RSP             ; Z
        DCX     H
        MOV     M,B
        DCX     H
        MOV     M,C
        SHLD    RSP
        LHLD    LET+50
        MOV     B,H
        MOV     C,L
        LXI     H,BRKCNT
        DCR     M
        XCHGC
        CZ      pollk
        NEXTX
        ENDIF
        IF      FAST*(1-CHECKED)
; a-z, unchecked: a variable followed by '@' or '!' is fetched or stored in
; the same step.
fva:    LXI     H,LET+40h+0     ; a
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvb:    LXI     H,LET+40h+2     ; b
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvc:    LXI     H,LET+40h+4     ; c
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvd:    LXI     H,LET+40h+6     ; d
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fve:    LXI     H,LET+40h+8     ; e
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvf:    LXI     H,LET+40h+10    ; f
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvg:    LXI     H,LET+40h+12    ; g
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvh:    LXI     H,LET+40h+14    ; h
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvi:    LXI     H,LET+40h+16    ; i
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvj:    LXI     H,LET+40h+18    ; j
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvk:    LXI     H,LET+40h+20    ; k
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvl:    LXI     H,LET+40h+22    ; l
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvm:    LXI     H,LET+40h+24    ; m
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvn:    LXI     H,LET+40h+26    ; n
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvo:    LXI     H,LET+40h+28    ; o
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvp:    LXI     H,LET+40h+30    ; p
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvq:    LXI     H,LET+40h+32    ; q
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvr:    LXI     H,LET+40h+34    ; r
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvs:    LXI     H,LET+40h+36    ; s
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvt:    LXI     H,LET+40h+38    ; t
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvu:    LXI     H,LET+40h+40    ; u
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvv:    LXI     H,LET+40h+42    ; v
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvw:    LXI     H,LET+40h+44    ; w
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvx:    LXI     H,LET+40h+46    ; x
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvy:    LXI     H,LET+40h+48    ; y
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvz:    LXI     H,LET+40h+50    ; z
        LDAX    B
        CPI     '@'
        JZ      fvat
        CPI     '!'
        JZ      fvst
        PUSH    D
        NEXTF
fvat:   INX     B               ; x@: TOS = the cell's value
        PUSH    D
        MOV     E,M
        INX     H
        MOV     D,M
        NEXTD
fvst:   INX     B               ; x!: the cell = TOS, and NOS comes up
        MOV     M,E
        INX     H
        MOV     M,D
        POP     H
        NEXTF
FHIGH   EQU     fign            ; (80h-FFh are ignored)
fs_store:POP     H              ; !
        XCHG
        MOV     M,E
        INX     H
        MOV     M,D
        POP     H
        NEXTF
fs_cstore:POP     H             ; .
        XCHG
        MOV     M,E
        POP     H
        NEXTF
FSTORE  EQU     fs_store
FCSTORE EQU     fs_cstore
        ENDIF
        IF      FAST*CHECKED
; a-z, checked: push the cell's address (a checked build checks the stacks
; between the variable and what follows it, so it keeps them apart)
fva:    LXI     H,LET+40h+0     ; a
        PUSH    D
        NEXTF
fvb:    LXI     H,LET+40h+2     ; b
        PUSH    D
        NEXTF
fvc:    LXI     H,LET+40h+4     ; c
        PUSH    D
        NEXTF
fvd:    LXI     H,LET+40h+6     ; d
        PUSH    D
        NEXTF
fve:    LXI     H,LET+40h+8     ; e
        PUSH    D
        NEXTF
fvf:    LXI     H,LET+40h+10    ; f
        PUSH    D
        NEXTF
fvg:    LXI     H,LET+40h+12    ; g
        PUSH    D
        NEXTF
fvh:    LXI     H,LET+40h+14    ; h
        PUSH    D
        NEXTF
fvi:    LXI     H,LET+40h+16    ; i
        PUSH    D
        NEXTF
fvj:    LXI     H,LET+40h+18    ; j
        PUSH    D
        NEXTF
fvk:    LXI     H,LET+40h+20    ; k
        PUSH    D
        NEXTF
fvl:    LXI     H,LET+40h+22    ; l
        PUSH    D
        NEXTF
fvm:    LXI     H,LET+40h+24    ; m
        PUSH    D
        NEXTF
fvn:    LXI     H,LET+40h+26    ; n
        PUSH    D
        NEXTF
fvo:    LXI     H,LET+40h+28    ; o
        PUSH    D
        NEXTF
fvp:    LXI     H,LET+40h+30    ; p
        PUSH    D
        NEXTF
fvq:    LXI     H,LET+40h+32    ; q
        PUSH    D
        NEXTF
fvr:    LXI     H,LET+40h+34    ; r
        PUSH    D
        NEXTF
fvs:    LXI     H,LET+40h+36    ; s
        PUSH    D
        NEXTF
fvt:    LXI     H,LET+40h+38    ; t
        PUSH    D
        NEXTF
fvu:    LXI     H,LET+40h+40    ; u
        PUSH    D
        NEXTF
fvv:    LXI     H,LET+40h+42    ; v
        PUSH    D
        NEXTF
fvw:    LXI     H,LET+40h+44    ; w
        PUSH    D
        NEXTF
fvx:    LXI     H,LET+40h+46    ; x
        PUSH    D
        NEXTF
fvy:    LXI     H,LET+40h+48    ; y
        PUSH    D
        NEXTF
fvz:    LXI     H,LET+40h+50    ; z
        PUSH    D
        NEXTF
fhi:    XCHG                    ; 80h-FFh: reserved (X), or an undefined word (U)
        JMP     e_hi
FHIGH   EQU     fhi
FSTORE  EQU     ftstore
FCSTORE EQU     ftcstore
        ENDIF
        IF      FAST
fs_nul: JMP     endprog         ; NUL: the end of the program
fign:   NEXTD                   ; 01h-20h and DEL (and 80h-FFh unchecked): nothing
; the table: low bytes, then high bytes, each a page
        DS      (256 - ($ & 0FFh)) & 0FFh
DTAB:
        DB      fs_nul&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh,fign&0FFh   ; 00h
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
        DB      fvx&0FFh,fvy&0FFh,fvz&0FFh,rpushd&0FFh,fs_or&0FFh,fs_fromr&0FFh,fs_not&0FFh,fign&0FFh   ; 78h
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
        DB      fs_nul/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256,fign/256   ; 00h
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
        DB      fvx/256,fvy/256,fvz/256,rpushd/256,fs_or/256,fs_fromr/256,fs_not/256,fign/256   ; 78h
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
RSPAGE  EQU     CPAGE + QK      ;   that the letter page is still the one
DSPAGE  EQU     RSPAGE + 1      ;   just below the program text
LETPAGE EQU     RSPAGE + 2
PROG    EQU     LETPAGE*256 + 256
        ENDIF
imgend:
