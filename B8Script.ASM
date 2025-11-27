;=====================================================================
;	B8Script 1.0beta
;	Size: <=2048 bytes | CP/M .COM | Z80
;	by Robb Bates (c) 2025
;
;	If Forth and VTL had a love child!
;
;
;	There once was a game small and sweet
;	That Mr. Bates crammed in a tweet
;	With all the fluff stripped
;	It ran on B8Script
;	A CP/M programming feat!
;
;=====================================================================

.cpu z80
.pragma com
.engine cpm

;=====================================================================
; Register usage
;=====================================================================
;	A	General usage
;		BDOS return value
;	B	Counters
;		BDOS return value
;	C	BDOS command to be called
;	DE	Second off stack for command handlers
;		BDOS second value
;	HL	First off stack for command handlers
;		BDOS return value
;	IX	Address of data stack pointer
;	IY	Address of control stack pointer
;	SP	Address of standard CPU stack pointer
;	F	CPU flags

;=====================================================================
; Constants
;=====================================================================
	BDOS_CON_OUT		EQU	2		; BDOS print single character
	BDOS_CON_DIR_IO		EQU	6		; BDOS direct console access
	BDOS_PRINT_STR		EQU	9		; BDOS print string
	BDOS_CON_BUF		EQU	10		; BDOS get console buffer
	BDOS_FILE_OPEN		EQU	15		; BDOS open file
	BDOS_FILE_CLOSE		EQU	16		; BDOS close file
	BDOS_FILE_DELETE	EQU	19		; BDOS delete file
	BDOS_FILE_READ		EQU	20		; BDOS sequential 128 byte read
	BDOS_FILE_WRITE		EQU	21		; BDOS sequential 128 byte write
	BDOS_FILE_MAKE		EQU	22		; BDOS create file
	BDOS_DMA_ADDR		EQU	26		; BDOS set DMA address
	STACK_SIZE			EQU	32		; Data stack size of 2 byte values
	STACK_CTRL_SIZE		EQU	32		; Control stack size of 2 byte addresses
	STACK_CPU_SIZE		EQU	32		; CPU stack size of 2 byte addresses

;=====================================================================
; Memory layout
;=====================================================================
	BDOS_CALL		EQU	$0005								; BDOS calling address
	OS_START		EQU BDOS_CALL + 1						; BDOS_CALL is a JR to the first byte of the OS. TPA is just below that.
	RAM_START		EQU	B8SCRIPT_END						; Begins at the end of the code
	
ORG	RAM_START												; Sets start of RAM which is at the end of the code
	FILE_FCB		EQU	RAM_START							; File Control Buffer used in file Operations.  
	FILE_DMA		EQU	FILE_FCB + 36						; DMA buffer for file I/O (128 bytes)
	PLUGIN_FIRST	EQU FILE_DMA + 128						; Pointer to first plugin header
	LOAD_SIZE		EQU	PLUGIN_FIRST + 2					; Size of plugin to be loaded
	IN_BUF			EQU	LOAD_SIZE + 2						; Buffer for string input
	LINE_START		EQU IN_BUF + 128						; Address of the start of the line we found
	LINE_NEXT		EQU LINE_START + 2						; Address of the end of the line we found
	LINE_FOUND		EQU LINE_NEXT + 2						; Line actually found, for use with repeat edit/insert
	EDIT_MODE		EQU	LINE_FOUND + 2						; Insert (0) or Edit (1) Mode
	TABLE_PROC		EQU	EDIT_MODE + 1						; Procedure (A-Z) jump table
	TABLE_VAR		EQU	TABLE_PROC + 52						; Variable (a-z) storage table
	STACK_CPU_BOT	EQU	TABLE_VAR + 52						; Bottom of CPU stack
	STACK_CPU_TOP	EQU	STACK_CPU_BOT + STACK_SIZE * 2		; Top of CPU stack.  Stack starts here and works down
	STACK_BOT		EQU	STACK_CPU_TOP						; Bottom of data stack
	STACK_TOP		EQU	STACK_BOT + STACK_SIZE * 2			; Top of data stack.  Stack starts here and works down
	STACK_CTRL_BOT	EQU	STACK_TOP							; Bottom of control stack
	STACK_CTRL_TOP	EQU	STACK_CTRL_BOT + STACK_CTRL_SIZE * 2; Top of control stack.  Stack start here and works down
	HEAP_PTR		EQU STACK_CTRL_TOP						; Points to the top of the heap, which starts right after the end of the script
	SCRIPT_END		EQU	HEAP_PTR + 2						; Pointer to the end of script buffer. For calculating script size
	SCRIPT_START	EQU	SCRIPT_END + 2						; Beginning of the script buffer

ORG $0100		; CP/M calls program here
B8SCRIPT_START:		; Start of code
;=====================================================================
; Start of code
;=====================================================================
	JP INIT		; Go initialize the program

;------------------------------
; PLUGIN_CALL: Self modifying helper code for CALL or JP from within the relocatable plugin code
; Inputs: None
; Outputs: None
; Modifies: None
;------------------------------
PLUGIN_CALL:
      JP  $0000 ; Jump to the address stored

;=====================================================================
; Plugin access Pointers and variables.  These must stay in this location for backwards compatibility with plugin access
;=====================================================================
PLUGIN_JUMP_TABLE:			; Indirect jump addresses to plugin accessible functions
	DW PROCESS_SCRIPT_CHAR	; Put command character in A and call this function
PLUGIN_BASE:				; Points to the first address of loaded plugin
	DW 0
SCRIPT_PC:					; Points to the next character being processed by the program (after plugin filename when plugin is called)
	DW 0
	DW SCRIPT_START			; Defaults to start of script
	DW STACK_PUSH			; Address of STACK_PUSH function
	DW STACK_POP			; Address of STACK_POP function

;=====================================================================
; Code above this must not change to ensure backward compatibility across versions
;=====================================================================

 
;=====================================================================
; Command indirect jump table. Entries are in ASCII order
;=====================================================================
CMD_JUMP_TABLE:
    DW CMD_POKE         ; ! (33)  (value addr -- )
    DW CMD_STR          ; " (34)  ( -- addr )
    DW CMD_HEAP   ; # (35)  ( size -- addr )
    DW CMD_HEX          ; $ (36)  ( -- value )
    DW CMD_INLINE_CODE  ; % (37)  ( addr -- )
    DW CMD_AND          ; & (38)  ( a b -- a&b )
    DW CMD_POKE_BYTE    ; ' (39)  ( value addr -- )
    DW CMD_IF           ; ( (40)  ( flag -- )
    DW CMD_ENDIF        ; ) (41)  ( -- )
    DW CMD_MUL          ; * (42)  ( a b -- a*b )
    DW CMD_ADD          ; + (43)  ( a b -- a+b )
    DW CMD_PRINT_STR    ; , (44)  ( addr -- )
    DW CMD_SUB          ; - (45)  ( a b -- a-b )
    DW CMD_PRINT_DEC    ; . (46)  ( value -- )
    DW CMD_DIV_MOD      ; / (47)  ( a b -- a/b a%b )
    ; (48–57) = digits 0–9 - handled by CMD_DECIMAL
    DW CMD_DUP 		    ; : (58)  ( a -- a a )
    DW STACK_POP 	    ; ; (59)  ( a -- ) ; DROP Command handler removed and command redirected to just pop the stack
    DW CMD_LT           ; < (60)  ( a b -- flag )
    DW CMD_EQ           ; = (61)  ( a b -- flag )
    DW CMD_GT           ; > (62)  ( a b -- flag )
    DW CMD_INPUT        ; ? (63)  ( -- value 0 | addr 1 )
    DW CMD_PEEK         ; @ (64)  ( addr -- value )
    ; (65–90) = procedures A–Z - handled by CMD_PROC
    DW CMD_PROC_DEF     ; [ (91)  ( -- )
    DW CMD_ELSE         ; \ (92)  ( -- )
    DW CMD_PROC_END     ; ] (93)  ( -- ) CTRL( ADDR -- )
    DW CMD_XOR          ; ^ (94)  ( a b -- a^b )
    DW CMD_BREAK        ; _ (95)  ( flag -- ) CTRL( -- addr 1 )
    DW CMD_PLUGIN       ; ` (96)  ( -- addr )
    ; (97–122) = variables a–z - handled by CMD_VAR
    DW CMD_DO           ; { (123) ( -- ) CTRL( -- addr )
    DW CMD_OR           ; | (124) ( a b -- a|b )
    DW CMD_WHILE        ; } (125) ( flag -- )
    DW CMD_STR_CMP      ; ~ (126) ( addr addr -- flag )

;=====================================================================
; Main command loop
;=====================================================================

;------------------------------
; MAIN_RUN_LOOP: Main execution loop for script
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL
;------------------------------
MAIN_RUN_LOOP:	; Gets next script command character and dispatches it based on ASCII value range
	LD DE,(SCRIPT_PC)	; Get the value of the script program counter
	LD A,(DE)			; Get next script character at the address in the program counter
	INC DE				; Increment it to the next character, which many handlers will start parsing at or point to for flow control
	LD (SCRIPT_PC),DE	; Save it back so we don't lose the pointer if DE gets corrupted.  Handler will modify it if needed
	OR A				; Set flags
	JP Z,EDIT_MAIN		; If we get a zero, we're at the end of the script, so back jump to the editor
	CALL PROCESS_SCRIPT_CHAR; Call to process the current script character
    JR MAIN_RUN_LOOP    ; Jump back and process the next script character

;=====================================================================
; Script character processor.  Can be called by either the main loop or a plugin
;=====================================================================

;------------------------------
; PROCESS_SCRIPT_CHAR: Processes a single script character
; Inputs: A - script character to process
; Outputs: None
; Modifies: A, BC, HL
;------------------------------
PROCESS_SCRIPT_CHAR:	; Processes a script character
	PUSH AF				; Preserve the script character we're looking at
	CALL CHECK_CTRL_C	; Checks for CTRL-C
	POP AF				; And restore it
CHECK_WHITE_SPACE:
	CP 33				; Is it white space?
	RET C				; If so, return
CHECK_RANGE1:
	CP 48				; Is it normal command (ASCII 33-47)?
	JR NC,CHECK_DIGIT	; If not, skip to check for digit
	SUB 33				; If so, set offset for first group.  (ASCII 33 to 47) - 33 = (0 to 14)
	JR CALC_JUMP		; And go calculate the jump
CHECK_DIGIT:
	CP 58				; Is it a digit (ASCII 48-57)?
	JP C,CMD_DECIMAL	; If so, go process a decimal number
CHECK_RANGE2:
	CP 65				; Is it a normal command (ASCII 58-64)?
	JR NC,CHECK_PROC	; If not, skip to check for procedure
	SUB 43				; If so, set offset for second group.  (ASCII 58 to 64) - 43 = (15 to 21)
	JR CALC_JUMP		; And go calculate the jump
CHECK_PROC:
	CP 91				; Is it a capital letter (ASCII 65-90)?
	JP C,CMD_PROC		; If so, go call a procedure
CHECK_RANGE3:
	CP 97				; Is it a normal command (ASCII 91-96)?
	JR NC,CHECK_VAR	; If not, skip to check for variable
	SUB 69				; If so, set offset for third group.  (ASCII 91 to 96) - 69 = (22 to 27)
	JR CALC_JUMP		; And go calculate the jump
CHECK_VAR:
	CP 123				; Is it a variable (ASCII 97-122)?
	JP C,CMD_VAR		; If so, go process a variable
CHECK_RANGE4:
	CP 127				; Is it a normal command (ASCII 123-126)?
	RET NC				; If not, return
	SUB 95				; If so, set offset for fourth group.  (ASCII 123 to 126) - 95 = (28 to 31)
CALC_JUMP:
	ADD A,A				; Double the offset because each is 2 bytes
	LD C,A				; Set up BC ...
	LD B,0				; ... and ...
	LD HL,CMD_JUMP_TABLE	; HL to ...
	ADD HL,BC			; add the offset to the jump table address
	LD A,(HL)   ; Load low byte of handler address
	INC HL      ; Point to high byte
	LD H,(HL)   ; Load high byte of handler address (overwrites H)
	LD L,A      ; Put low byte back into L (now HL = full handler address)
	JP (HL)     ; Jump to the loaded handler address

;=====================================================================
; Script command handlers, arranged to take advantage of JR to STACK_PUSH_STUB and ERROR_HANDLER
;=====================================================================

;------------------------------
; CMD_DROP: ; DATA( a -- )
; Inputs: None
; Outputs: None
; Modifies: None
;------------------------------
;CMD_DROP:
;	JP STACK_POP    ; Pop and discard
;
; The jump table entry was re-directed to STACK_POP since that's all this command does

;------------------------------
; CMD_PLUGIN: ` Loads plugin, DATA( -- addr )
; Inputs: DE - 
; Outputs: None
; Modifies: A, DE, HL, SCRIPT_PC
;------------------------------
CMD_PLUGIN:
    CALL PARSE_FILENAME ; Get the filename and set up FCB
    LD (SCRIPT_PC),DE   ; Set program counter to the character after the filename just parsed. If a plugin is called from another plugin, SCRIPT_PC must be preserved
NO_UPDATE:
    LD (HL),'X'         ; Tweak ext to B8X.  HL was left on that character after we parsed it
    LD HL,PLUGIN_FIRST  ; Get pointer to the first plugin (it's zero if there are none)
FIND_LOOP:
    LD A,(HL)			; Get the low byte of the next plugin pointer
	LD E,(HL)			; Also store the low byte in E
    INC HL				; Go to the high byte
	LD D,(HL)			; Store it in D, so now DE is the pointer to the next plugin
    OR (HL)				; OR the low byte with the high byte. If both are zero, then the link is zero which means we're are the end and the plugin is not found at all
    JR Z,LOAD_PLUGIN	; If so, we need to go set up a new header and load the plugin
	PUSH DE				; It it's not zero, then stash the pointer to the next plugin in case we need to check the next plugin
	INC HL				; Bump HL to point at the plugin header filename
    LD DE,FILE_FCB+1	; Set up to compare the filenames.  Point to filename in FCB
    LD B,8              ; Loads counter for 8 bytes to compare
COMPARE_LOOP:
    LD A,(DE)          	; Get character of the filename we're looking for
    CP (HL)             ; Compare it to the character in the plugin header filename
    JR NZ,PLUGIN_NOT_FOUND  ; If they are different, go look for the next link
    INC DE              ; Increment to next character of filename we're looking for
    INC HL              ; Increment to next character of filename in the plugin header we're comparing it with. If all 8 bytes match, we end up at first byte of plugin code
    DJNZ COMPARE_LOOP   ; Loop back for 8 characters
	POP DE				; If we have a match, we need to drop the next plugin pointer we stashed ealier since we don't need it sitting on the stack
    JP (HL)				; Then go execute the plugin.  It will return back to either the main run loop or the plugin that called it
PLUGIN_NOT_FOUND:
	POP HL				; Retrieve pointer to next plugin we stashed earlier
    JR FIND_LOOP		; and go check the next one
LOAD_PLUGIN:
	LD DE,(HEAP_PTR)	; Set destination for copying the plugin header pointer and filename at the first available byte in the heap
	LD (HL),D			; Update high byte of previous pointer (sitting there from zero check above) with high byte of heap top
	DEC HL				; Back up to the low byte
	LD (HL),E			; Update low byte of previous pointer with low byte of heap top
	XOR A				; Set A to zero
	LD (DE),A			; Set link to next plugin as zero,
	INC DE				; which means
	LD (DE),A			; no more plugins after this
	INC DE				; and bump to the next byte which is where plugin name will be stored
	LD HL,FILE_FCB+1	; Set source of filename to copy
	LD BC,8				; Set byte count to copy
	LDIR				; Copy filename, leaving DE at next byte
	LD (HEAP_PTR),DE	; Set the heap top temporarily to that address where plugin code will be loaded, since it will get clobbered during loading
	PUSH DE				; And also stash it as pointer when we the execute code later
	CALL FILE_OPEN		; Open the file so we can grab the plugin size from the first two bytes
	CALL LOAD_SECTOR	; Get the first sector
	LD DE,(FILE_DMA)	; Point to the FILE_DMA where the first sector was loaded
	LD (LOAD_SIZE),DE	; Get the plugin size from the first two bytes of the plugin file
	LD DE,FILE_DMA + 2	; Bump the source to the start of the code
	LD BC,2				; Set the total byte counter to two since we already got the plugin size bytes and we don't want to copy those
	LD HL,(HEAP_PTR)	; Set destination to byte after the zeroed next pointer link that was temporarily stored in HEAD_PTR above
    CALL FL_COPY		; Jumps to the middle of the loader since we already got the sector and first two bytes
    LD (HEAP_PTR),HL    ; Update heap top, HL was left right after the last loaded byte from FILE_LOAD
    CALL FILE_CLOSE		; Close the file
	POP HL				; Retreive the pointer to the start of code that we stashed earlier
    JP (HL)				; And go execute it.  It will return back to the main run loop

;------------------------------
; CMD_POKE_BYTE: ' DATA( value addr -- )
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL
;------------------------------
CMD_POKE_BYTE:
	CALL STACK_POP_TWO	; Pop two values off stack, Address in DE, Value in HL
	LD A,L				; Load value low byte into A (because there"s not a LD (DE),L)
	LD (DE),A			; Store value low byte at address
CMD_ENDIF:				; Label for ENDIF inserted here to save space
	RET                 ; Return to caller

;------------------------------
; CMD_ENDIF: ) No-op for endif
; Inputs: None
; Outputs: None
; Modifies: None
;------------------------------
; Re-used RET above to save space

;------------------------------
; CMD_PRINT_DEC: . DATA( value -- )
; Inputs: None
; Outputs: None
; Modifies: A, HL
;------------------------------
CMD_PRINT_DEC:
	CALL STACK_POP      ; Pop value
	JP PRINT_DEC        ; Jump to print decimal routine

;------------------------------
; CMD_PROC_END: ] Ends procedure definition CTRL( addr -- )
; Inputs: None
; Outputs: None
; Modifies: HL, SCRIPT_PC
;------------------------------
CMD_PROC_END:
	CALL STACK_CTRL_POP	; Get the return address off the control stack into HL
	LD (SCRIPT_PC),HL	; Set the script program counter to that address to return from the procedure
	RET                 ; Return to caller

;------------------------------
; CMD_POKE: ! DATA( value addr -- )
; Inputs: None
; Outputs: None
; Modifies: DE, HL
;------------------------------
CMD_POKE:
	CALL STACK_POP_TWO	; Pop two values off stack, Address in DE, Value in HL
	EX DE,HL			; Now Address in HL, Value in DE (because there"s not a LD (DE),L/H)
	LD (HL),E			; Store value low byte at low byte address
	INC HL				; Increment the address
	LD (HL),D			; Store value high byte at high byte address
	RET					; Return to caller

;------------------------------
; CMD_PRINT_STR: , DATA( addr -- )
; Inputs: None
; Outputs: None
; Modifies: A, HL
;------------------------------
CMD_PRINT_STR:
	CALL STACK_POP		; Get address of string from the stack into HL
PRINT_STR_LOOP:
	LD A,(HL)			; Load current character
	INC HL				; Advance pointer
	OR A				; Test for null (end of script)
	RET Z				; Done if zero.  Could be input buffer.  Could be EOF
	CP 34				; Check for closing quote
	RET Z				; If found, done
	CP "~"				; Check for escape character
	JR NZ,NOT_ESC		; If yes, handle escape
	LD A,(HL)			; Load escaped character
	INC HL				; Advance pointer
	OR A				; Test for null
	JP Z,ERROR_HANDLER	; Error if escape at end
	CP "~"				; Is letter after escape character the escape character itself?
	JR Z,NOT_ESC		; If so, go print it
	CP 34 ;quote		; Is letter after escape character a quote?
	JR Z,NOT_ESC		; If so, go print it
	CP "|"				; Is letter after escape character a pipe?
	JR NZ,CHECK_DOT	; If not, go check for a dot
	CALL PRINT_CR_LF	; Is it is, print a CR+LF
	JR PRINT_STR_LOOP	; And go to get the next character
CHECK_DOT:
	CP "."				; Is letter after escape character a period?
	JR NZ,CHECK_VAR_ESC	; If not, go check for the apostrophe
	PUSH HL
	CALL STACK_POP		; Get a value off the stack
	CALL PRINT_DEC		; Print it
	JR POP_AND_NEXT		; And go to get the next character
CHECK_VAR_ESC:
	CP "z" + 1			; Check if letter after escape is
	JR NC,NOT_VAR		; between "z"
	CP "a"				; and "a"
	JR C,NOT_VAR		; If not, it's not a variable
	PUSH HL
	CALL CMD_VAR
	CALL CMD_PEEK
	CALL CMD_PRINT_DEC
POP_AND_NEXT:
	POP HL
	JR PRINT_STR_LOOP   ; continue with next character
NOT_VAR:
	SUB 64				; Subtract 64 for control char
NOT_ESC:
	LD E,A				; Prepare to print normal char
	CALL PRINT_CHAR		; Print it
	JR PRINT_STR_LOOP	; Continue

;------------------------------
; CMD_INLINE_CODE: % DATA( addr -- )
; Inputs: None
; Outputs: None
; Modifies: A, B, DE, HL, SCRIPT_PC
;------------------------------
CMD_INLINE_CODE:
    CALL STACK_POP      ; HL = start address
	PUSH HL             ; Push start address
INLINE_LOOP:
    CALL PARSE_HEX_NIBBLE ; Parse high nibble, DE is initially loaded with SCRIPT_PC
    JR C,INLINE_DONE    ; No (more) hex: done
    RLCA                ; High nibble <<= 4
    RLCA                ; Shift left
    RLCA                ; Shift left
    RLCA                ; Shift left
    LD B,A              ; B = high << 4
    INC DE              ; To next char
    CALL PARSE_HEX_NIBBLE ; Parse low nibble
    JR C,ERROR_HANDLER  ; Missing low nibble
    OR B                ; A = byte value
    LD (HL),A           ; Store at addr
    INC DE              ; Next addr
    JR INLINE_LOOP      ; Continue loop
INLINE_DONE:
	LD (SCRIPT_PC),DE	; Where to resume script after call or not
	POP HL				; Get original popped address
	LD A,(DE)
	CP "`"              ; Check if char is "`"
	RET NZ				; If not a call to the popped address, then return to main run loop
	INC DE				; Otherwise, bump to script character after the "`"
	LD (SCRIPT_PC),DE	; And stash that location in the script program counter
	JP (HL)				; Then jump to popped address and executed code should return

;------------------------------
; CMD_HEAP: # DATA( size -- addr )
; Inputs: None
; Outputs: None
; Modifies: BC, DE, HL, HEAP_PTR
;------------------------------
CMD_HEAP:
    CALL STACK_POP		; HL = size (0 is allowed)
    BIT 7,H			; Negative?
    JR NZ,HEAP_NEG
HEAP_POS:
    EX DE,HL			; DE = size
    LD HL,(HEAP_PTR)	; HL = current top
    CALL STACK_PUSH		; push it: ( -- addr )
    ADD HL,DE			; HL = new top = old_top + size
    JR C,ERROR_HANDLER	; new top overflows top of memory - error
    LD (HEAP_PTR),HL	; update heap pointer
HEAP_NEG:
    CALL NEG_HL			; |size|
    EX DE,HL			; DE = |size|
    LD HL,(HEAP_PTR)
    CALL STACK_PUSH		; Push new top
    ;OR A ; Carry already clear from stack bounrary check
    SBC HL,DE			; New top = old - |size|
    JR C,ERROR_HANDLER	; Underflow (borrow)
HEAP_UPDATE:
    LD (HEAP_PTR),HL
TPA_OVERFLOW:
    LD DE,(OS_START)	; BDOS entry, i.e. start of BDOS
    OR A				; Clear carry.  It might be set over in FILE_LOAD
    SBC HL,DE			; Compare
    JR NC,ERROR_HANDLER	; new top >= BDOS - error
	ADD HL,DE
	RET

;------------------------------
; CMD_DECIMAL: 0-9 Parses decimal number DATA( -- value )
; Inputs: None
; Outputs: None
; Modifies: DE, HL, SCRIPT_PC
;------------------------------
CMD_DECIMAL:
	DEC DE				; Back up one since DE was incremented by main run loop
	CALL PARSE_DEC		; Go parse the number with DE now loaded with SCRIPT_PC
	JR HEX_DONE 		; Reusing the code below

;------------------------------
; ERROR_HANDLER: Handles errors
; Inputs: E - error code char
; Outputs: None
; Modifies: DE
;------------------------------
ERROR_HANDLER:		; Prints error notification with error type (context or line number?)
	LD DE,MSG_ERROR     ; Error message
	CALL PRINT_STR      ; Print it
	JP EDIT_MAIN        ; To editor

MSG_ERROR:
	DB $0D,$0A,"Err$" ; Error message string

;------------------------------
; CMD_HEX: $ DATA( -- value )
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL, SCRIPT_PC
;------------------------------
CMD_HEX:
    LD HL,0             ; Accumulator = 0
HEX_LOOP:
    CALL PARSE_HEX_NIBBLE ; Parse hex nibble, DE is initially loaded with SCRIPT_PC after the "$"
    JR C,HEX_DONE       ; Invalid: done
    ADD HL,HL           ; HL <<= 4
    ADD HL,HL           ; Shift left again
    ADD HL,HL           ; Shift left again
    ADD HL,HL           ; Shift left again
    OR L                ; Add to low nibble (low bits 0)
    LD L,A              ; Store in L
	INC DE				; Get next hex character
    JR HEX_LOOP         ; Loop for next
HEX_DONE:
    LD (SCRIPT_PC),DE   ; Update script program counter with DE which is on the first non-hex character
    JR STACK_PUSH_STUB       ; Push the value

;------------------------------
; CMD_DIV_MOD: / DATA( a b -- a/b a%b )
; Inputs: None
; Outputs: None
; Modifies: A, BC, DE, HL
;------------------------------
CMD_DIV_MOD:
	CALL STACK_POP_TWO	; HL = a (bottom/dividend), DE = b (top/divisor)
    ; OR A            ; Clear the carry flag initially ; Carry already cleared from POP function
    CALL ABS_CTOG_HL  ; Negate HL if needed and toggle the carry flag
    EX DE,HL        ; Swap DE and HL so we can do the same to DE
    CALL ABS_CTOG_HL  ; Negate what was DE if needed and toggle the carry flag
    PUSH AF         ; Stash the carry flag for later
    EX DE,HL        ; Swap them back and continue on with the division
	LD A,D			; Check for divisor == 0
	OR E            ; OR with low byte
	JR Z,ERROR_HANDLER	; Error if divide by zero
	LD BC,0			; BC = quotient
DIV_LOOP:
	; OR A			; Clear carry. Carry is always clear from OR E above and loop results
	SBC HL,DE		; HL -= DE
	JR C,DIV_END		; Done if borrow
	INC BC			; Quotient++
	JR DIV_LOOP         ; Continue loop
DIV_END:
	ADD HL,DE		; Restore remainder
    POP AF          ; Get our carry flag back
	PUSH HL			; Save remainder
	LD H,B			; Move quotient to HL
	LD L,C          ; Copy low byte
    JR NC,DIV_POS   ; If carry is not set, HL is positive
    CALL NEG_HL  ; Otherwise, we negate HL first
DIV_POS:
	CALL STACK_PUSH		; Push quotient
	POP HL			; Restore remainder
	JR STACK_PUSH_STUB       ; Push remainder

;------------------------------
; CMD_MUL: * DATA( a b -- a*b )
; Inputs: None
; Outputs: None
; Modifies: A, B, C, DE, HL
;------------------------------
CMD_MUL:
	CALL STACK_POP_TWO	; HL = a (bottom/multiplicand), DE = b (top/multiplier)
	LD B,H			; Move multiplicand to BC
	LD C,L          ; Copy low byte
	LD HL,0			; HL = partial product (accumulator)
	LD A,16			; A = bit counter
MUL_LOOP:
	ADD HL,HL		; Shift partial left
	RL E			; Shift multiplier left (low byte)
	RL D			; Shift multiplier left (high byte)
	JR NC,MUL_NO_ADD	; Skip add if no carry (bit was 0)
	ADD HL,BC		; Add multiplicand to partial
MUL_NO_ADD:
	DEC A			; Decrement counter
	JR NZ,MUL_LOOP		; Repeat if bits remain
	JR STACK_PUSH_STUB       ; Push result

;------------------------------
; CMD_STR: " DATA( -- addr )
; Inputs: None
; Outputs: None
; Modifies: DE, HL, SCRIPT_PC
;------------------------------
CMD_STR:
	LD H,D				; DE = scan pointer, which is character after initial quote
	LD L,E
	CALL QUOTE_SCAN		; Scan the string
	JR NZ,ERROR_HANDLER	; Error if no closing "
	LD (SCRIPT_PC),DE	; Set program counter to character after closing "
	JR STACK_PUSH_STUB       ; Push the address to the stack

;------------------------------
; CMD_EQ: = DATA( a b -- flag )
; Inputs: None
; Outputs: None
; Modifies: DE, HL
;------------------------------
CMD_EQ:
	CALL STACK_POP_TWO	; Pop two values off stack
	;OR A			; Clear carry flag. Carry is clear from STACK boundary check
	SBC HL,DE		; Subtracts the two to compare
	LD HL,0		; Assume HL = DE is false
	JR NZ,EQ_PUSH		; If it is false, go push to stack
	INC HL			; otherwise, bump HL to true
EQ_PUSH:
	JR STACK_PUSH_STUB       ; Push flag

;------------------------------
; CMD_XOR: ^ DATA( a b -- a^b )
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL
;------------------------------
CMD_XOR:
	CALL STACK_POP_TWO	; Pop two values off stack
	LD A,H			; Get high byte (can"t just XOR HL,DE)
	XOR D			; XOR high byte
	LD H,A			; Store back
	LD A,L			; Get low byte
	XOR E			; XOR low byte
	LD L,A			; Store back
	;JR STACK_PUSH_STUB   ; Push result ; fall through

STACK_PUSH_STUB:		; Placed in the middle of several functions that JP STACK_PUSH to allow for JR to save bytes
	JP STACK_PUSH

;------------------------------
; CMD_PEEK: @ DATA( addr -- value )
; Inputs: None
; Outputs: None
; Modifies: DE, HL
;------------------------------
CMD_PEEK:
	CALL STACK_POP	; Pop address off stack
	LD E,(HL)		; Get the low byte at address low byte
	INC HL			; Increment the address
	LD D,(HL)		; Get the high byte at address high byte
	EX DE,HL		; Swap them so value is in HL for STACK_PUSH
	JR STACK_PUSH_STUB   ; Push value

;------------------------------
; CMD_ADD: + DATA( a b -- a+b )
; Inputs: None
; Outputs: None
; Modifies: DE, HL
;------------------------------
CMD_ADD:
	CALL STACK_POP_TWO	; Pop two values off stack
	ADD HL,DE		; Add them
	JR STACK_PUSH_STUB   ; Push result

;------------------------------
; CMD_DUP: : DATA( a -- a a )
; Inputs: None
; Outputs: None
; Modifies: HL
;------------------------------
CMD_DUP:
	LD L,(IX+0)		; Load low byte from top
	LD H,(IX+1)		; Load high byte from top
	JR STACK_PUSH_STUB   ; Push duplicate

;------------------------------
; CMD_SUB: - DATA( a b -- a-b )
; Inputs: None
; Outputs: None
; Modifies: DE, HL
;------------------------------
CMD_SUB:
    LD A,(DE)           ; First, let's see if this is a minus sign and not subtract by looking at next char. DE is already pointing there
    SUB "0"             ; Turn it into a value
    JR C,SUB_CMD        ; If it's less than zero then we have a subtract command
    CP 10               ; See if it's above 9
    JP C,CMD_DECIMAL    ; If it's less than 10, it's a digit, so we turn this over to CMD_DECIMAL
SUB_CMD:
	CALL STACK_POP_TWO	; Pop two values off stack
	; OR A			; Clear the carry flag, C is clear already from STACK_POP boundary check
	SBC HL,DE		; Subtract them
    JR STACK_PUSH_STUB   ; Push result

;------------------------------
; CMD_VAR: a-z Handles variable access DATA( -- addr )
; Inputs: A - variable letter
; Outputs: None
; Modifies: A, DE, HL
;------------------------------
CMD_VAR:
	SUB "a"			; Subtract so we get offset of 0 for variable a
	ADD A, A		; Double the offset because each is 2 bytes
	LD E, A			; Set up DE ...
	LD D, 0			; .... and ...
	LD HL, TABLE_VAR	; HL to ...
	ADD HL, DE		; add the offset to the variable table address
	JR STACK_PUSH_STUB       ; Push the address

;------------------------------
; CMD_OR: | DATA( a b -- a|b )
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL
;------------------------------
CMD_OR:
	CALL STACK_POP_TWO	; Pop two values off stack
	LD A,H			; Get high byte (can"t just OR HL,DE)
	OR D			; OR high byte
	LD H,A			; Store back
	LD A,L			; Get low byte
	OR E			; OR low byte
	LD L,A			; Store back
	JR STACK_PUSH_STUB   ; Push result

;------------------------------
; CMD_AND: & DATA( a b -- a&b )
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL
;------------------------------
CMD_AND:
	CALL STACK_POP_TWO	; Pop two values off stack
	LD A,H			; Get high byte (can"t just AND HL,DE)
	AND D			; AND high byte
	LD H,A			; Store back in H
	LD A,L			; Get low byte
	AND E			; AND low byte
	LD L,A			; Store back in L
	JR STACK_PUSH_STUB   ; Push result

;------------------------------
; CMD_GT: > DATA( a b -- flag )
; Inputs: None
; Outputs: None
; Modifies: DE, HL
;------------------------------
CMD_GT:
	CALL STACK_POP_TWO	; Pop two values off stack
	EX DE,HL
	JR COMPARE

;------------------------------
; CMD_LT: < DATA( a b -- flag )
; Inputs: None
; Outputs: None
; Modifies: DE, HL
;------------------------------
CMD_LT:
	CALL STACK_POP_TWO	; Pop two values off stack
COMPARE:
    LD A,H
    XOR D
    JP P,SIGNS_SAME
    LD A,H
    ADD A,A          ; Shift sign bit into carry
    LD HL,0
    RL L             ; L = 1 if carry (negative), else 0
    JR STACK_PUSH_STUB
SIGNS_SAME:
	;OR A			; Clear carry flag. Carry is clear from STACK boundary check
	SBC HL,DE		; Subtracts the two to compare
	LD HL,0		; Assume false
	RL L            ; L = 1 if borrow (less), else 0
	JR STACK_PUSH_STUB       ; Push flag

;------------------------------
; CMD_PROC: A-Z Calls procedure CTRL( -- addr )
; Inputs: A - procedure letter
; Outputs: None
; Modifies: A, DE, HL, SCRIPT_PC
;------------------------------
CMD_PROC:
	SUB 'A'                   ; Convert it to a value
	ADD A,A                   ; Double for 2-byte entries
	LD L,A                    ; L = offset, H=0
	LD H,0                    ; H = 0
	LD DE,TABLE_PROC          ; Base of procedure table
	ADD HL,DE                 ; HL = entry address
	LD E,(HL)                 ; Load low byte of proc address
	INC HL                    ; Increment HL
	LD D,(HL)                 ; Load high byte -> DE = proc start
	LD HL,(SCRIPT_PC)         ; HL = address of the procedure letter
	CALL STACK_CTRL_PUSH      ; Push return address of letter to control stack
    LD (SCRIPT_PC),DE         ; Update script program counter
	RET

;------------------------------
; CMD_IF: ( DATA( flag -- )
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL, SCRIPT_PC
;------------------------------
CMD_IF:
	CALL STACK_POP		; Pop flag from data stack into HL
	LD A,L				; Test if flag is non-zero
	OR H                ; OR with high byte
	RET NZ				; If non-zero (true), continue execution
	LD H,92		    	; Otherwise, set expected closer "\", DE set to after the "("
	LD L,")"			; If a "\" doesn't exist, search for ")"
	CALL MATCH_LOOP		; Scan for matching "\" first or if there isn't one, then ")"
	JR SET_PC_RET1      ; Set script program counter and return

;------------------------------
; CMD_ELSE: \ Skips to end of else branch
; Inputs: None
; Outputs: None
; Modifies: DE, SCRIPT_PC
;------------------------------
CMD_ELSE:
	LD H,")"			; Expected closer.  DE set to after the "\"
	CALL MATCH_ONE		; Scan for matching ")"
	JR SET_PC_RET1      ; Set script program counter and return

;------------------------------
; CMD_PROC_DEF: [ Defines a procedure
; Inputs: None
; Outputs: None
; Modifies: A, BC, DE, HL, SCRIPT_PC
;------------------------------
CMD_PROC_DEF:
	LD A,(DE)			; Get procedure letter. DE is pointing to that already
	INC DE
	SUB "A"				; 'A'->0 ... 'Z'->25
	JP C,ERROR_HANDLER	; If < 'A', error
	CP 26				; Check if > 'Z'
	JP NC,ERROR_HANDLER	; If >=26, error
	ADD A,A				; Offset * 2
	LD L,A              ; L = offset
	LD H,0              ; H = 0
	LD BC,TABLE_PROC    ; Base of table
	ADD HL,BC			; HL = slot in procedure table
	LD (HL),E			; Store low byte (letter addr)
	INC HL              ; Increment HL
	LD (HL),D			; Store high byte
	LD H,"]"			; H = closer, L=0 (no second closer)
	CALL MATCH_ONE		; Scan for matching ']', returns DE at character after the "]"
SET_PC_RET1:
	LD (SCRIPT_PC),DE	; Set script program counter to after the closer
	RET                 ; Return to caller

;------------------------------
; CMD_STR_CMP: ~ DATA( addr addr -- flag )
; Inputs: None
; Outputs: None
; Modifies: A, B, DE, HL
;------------------------------
CMD_STR_CMP:
	CALL STACK_POP_TWO	; HL=addr1 (bottom), DE=addr2 (top)
STR_CMP_LOOP:
	LD A,(HL)			; Load char from addr1
	OR A				; Null terminator?
	JR Z, CHECK_END2	; Yes: check if addr2 also ends
	CP 34				; " terminator? (ASCII 34)
	JR Z, CHECK_END2	; Yes: check if addr2 also ends
	LD B,A				; Save char1 for comparison
	LD A,(DE)			; Load char from addr2
	OR A				; Null on addr2?
	JR Z, NOT_EQUAL		; Yes, but addr1 not ended: unequal
	CP 34				; " on addr2?
	JR Z, NOT_EQUAL		; Yes, but addr1 not ended: unequal
	CP B				; Compare chars
	JR NZ, NOT_EQUAL	; Mismatch: unequal
	INC HL				; Advance both pointers
	INC DE              ; Advance DE
	JR STR_CMP_LOOP		; Continue
CHECK_END2:
	LD A,(DE)			; Now check addr2's current char
	OR A				; Null?
	JR Z, EQUAL			; Yes: both ended
	CP 34				; "?
	JR NZ, NOT_EQUAL			; Yes: both ended
EQUAL:
	LD HL,1				; Flag = true
	JR PUSH_FLAG        ; Jump to push
NOT_EQUAL:
	LD HL,0				; Flag = false
PUSH_FLAG:
	JR STACK_PUSH       ; Push flag

;------------------------------
; CMD_BREAK: _ DATA( flag -- ) CTRL( -- addr 1 )
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL, SCRIPT_PC
;------------------------------
CMD_BREAK:
	CALL STACK_POP		; Get flag from data stack into HL
	LD A,H				; Check if flag is non-zero
	OR L                ; OR with low byte
	RET Z				; If zero (false), return - do nothing
	LD H,"}"			; First closer
	LD L,"]"			; Second closer
	CALL MATCH_LOOP		; Scan for matching "}" or "]"
	LD (SCRIPT_PC),DE	; DE = char after found match
	CP "}"				; Check for loop closer, already stored in A from MATCH_LOOP
	JR NZ,CHECK_PROC_CLOSE	; If not a "}", it's a "]"
	JR STACK_CTRL_POP	; If it is, drop loop back address and return from there
CHECK_PROC_CLOSE:
	DEC DE				; Back up to "]" so main run loop can process it normally
	JR SET_PC_RET1      ; Set script program counter and return

;------------------------------
; CMD_INPUT: ? DATA( -- value 0 | addr 1 | value 2)
; Inputs: Pops stack for mode
; Outputs: None
; Modifies: A, DE, HL
;------------------------------
CMD_INPUT:
	CALL STACK_POP      ; Get value from top of stack. 0 = Get number, 1 = Get string, 2 = Get key
	LD A,L				; Check L for mode number, Only checks lower byte to save bytes
	OR A                ; Set flags
	JR Z,IN_NUM			; If zero, that's mode 0.  Go get number
	DEC A				; Decrement to check next mode
	JR Z,IN_STR			; If it was initially one, now zero, go get string
	DEC A				; Decrement to check next mode
	RET NZ				; If it was initially two, now zero, get key press, otherwise return
IN_KEY:
	LD C,BDOS_CON_DIR_IO	; Sets BDOS direct console I/O
	LD E,$FD	; Sets BDOS call to wait for a keypresses
	CALL BDOS	; Calls BDOS function. Returns with keypress in A
	LD L,A
	LD H,0
	JR STACK_PUSH
IN_NUM:
	CALL INPUT_LINE
	LD DE,IN_BUF+2		; DE = start of input text
	CALL PARSE_DEC		; Parse decimal (HL = value, advances DE to non-digit)
	JR STACK_PUSH		; Push value
IN_STR:
	CALL INPUT_LINE     ; Get input line
	LD HL,IN_BUF+2		; HL = address of input start
	JR STACK_PUSH       ; Push address

;------------------------------
; CMD_DO: { CTRL( -- addr )
; Inputs: None
; Outputs: None
; Modifies: HL
;------------------------------
CMD_DO:
	EX DE,HL		; Get the script program counter. DE points to character after the "{"
	JR STACK_CTRL_PUSH	; Push that address to the control stack 

;------------------------------
; CMD_WHILE: } DATA( flag -- )
; Inputs: Flag or variable
; Outputs: None
; Modifies: A, DE,HL, SCRIPT_PC, variable
;------------------------------
CMD_WHILE:
	CALL STACK_POP			; Get a flag from the stack
	LD A, H					; Put it in A
	OR L					; and OR it with H
CHECK_FLAG:
	JR Z, WHILE_FALSE		; Is it false (i.e. zero)?
WHILE_TRUE:
	CALL STACK_CTRL_POP		; If not, get the address off the control stack into HL
	LD (SCRIPT_PC),HL		; Set the script program counter to the start of the loop
	JR STACK_CTRL_PUSH		; And push it back to the stack
WHILE_FALSE:
;	JR STACK_CTRL_POP		; If the flag was false, dump the top of the control stack ; fall through


;=====================================================================
; Stack manipulation. Calls error handler if over or underflow
;=====================================================================

;------------------------------
; STACK_CTRL_POP: Pops from control stack CTRL( HL -- )
; Outputs: HL - popped value
; Modifies: BC, HL, IY
;------------------------------
STACK_CTRL_POP:
	LD L,(IY+0)				; Load low byte from control stack
	LD H,(IY+1)				; Load high byte from control stack
	INC IY					; Increment control stack pointer twice
	INC IY                  ; Second increment
	PUSH HL                 ; Push HL to CPU stack
	PUSH IY					; Save control stack pointer
	LD HL,STACK_CTRL_TOP+2	; Load control stack top + 2
	JR STACK_BOUND_CHECK	; Jump to shared boundary check
	
;------------------------------
; STACK_CTRL_PUSH: Pushes to control stack CTRL( -- HL )
; Inputs: HL - value to push
; Outputs: None
; Modifies: BC, HL, IY
;------------------------------
STACK_CTRL_PUSH:
	DEC IY					; Decrements control stack pointer twice
	DEC IY                  ; Second decrement
	LD (IY+0),L				; Pushes low byte to control stack
	LD (IY+1),H				; Pushes high byte to control stack
	PUSH HL                 ; Push HL to CPU stack
	PUSH IY					; Save control stack pointer
	LD HL,STACK_CTRL_BOT-2	; Load control stack bottom (adjusted)
	JR STACK_BOUND_CHECK	; Jump to shared boundary check

;------------------------------
; STACK_PUSH: Pushes to data stack DATA( HL -- )
; Inputs: HL - value to push
; Outputs: None
; Modifies: BC, HL, IX
;------------------------------
STACK_PUSH:
	DEC IX					; Decrements stack pointer twice
	DEC IX                  ; Second decrement
	LD (IX+0),L				; Pushes low byte to stack
	LD (IX+1),H				; Pushes high byte to stack
	PUSH HL                 ; Push HL to CPU stack
	PUSH IX					; Save stack pointer on CPU stack
	LD HL,STACK_BOT-2		; Load bottom limit (adjusted)
	JR STACK_BOUND_CHECK	; Jump to shared boundary check

;------------------------------
; STACK_POP_TWO: Pops two values DATA( -- HL DE )
; Outputs: HL - first pop, DE - second pop
; Modifies: DE, HL
;------------------------------
STACK_POP_TWO:
	CALL STACK_POP			; Pops first value off stack
	EX DE,HL				; Moves HL to DE
	CALL STACK_POP			; Pops second value off stack
	RET						; Return with top of stack in DE and second in HL

;------------------------------
; STACK_POP: Pops from data stack DATA( -- HL )
; Outputs: HL - popped value
; Modifies: BC, HL, IX
;------------------------------
STACK_POP:
	LD L,(IX+0)				; Load low byte from stack
	LD H,(IX+1)				; Load high byte from stack
	INC IX					; Increment stack pointer twice
	INC IX                  ; Second increment
	PUSH HL                 ; Push HL to CPU stack
	PUSH IX					; Save stack pointer on CPU stack
	LD HL,STACK_TOP+2		; Load top limit + 2 (post-increment). Fall through

;------------------------------
; STACK_BOUND_CHECK: Checks stack bounds
; Inputs: HL - limit, BC - SP
; Outputs: None
; Modifies: HL
;------------------------------
STACK_BOUND_CHECK:
	POP BC					; Retrieve saved stack pointer (IX or IY) into BC
	OR A					; Clear carry
	SBC HL,BC				; HL = limit - SP
	JP Z, ERROR_HANDLER		; If equal, boundary violation
	POP HL                  ; Pop HL back
	RET						; If not equal, no error

;=====================================================================
; Various common or support routines.
;=====================================================================

;------------------------------
; ABS_CTOG_HL: Perfoms a two's complement on HL and toggle a flag
; Inputs: HL - value to be negated, A - Flag to indicate negative number
; Outputs: HL - value returned either as is or negated if negative, A - flag toggled indicating negatin occured
; Modifies: HL, A
;------------------------------
ABS_CTOG_HL:
    BIT 7,H     ;
    RET Z       ;
NEG_HL:
    LD A,L      ;
    CPL         ;
    LD L,A      ;
    LD A,H      ;
    CPL         ;
    LD H,A      ;
    INC HL      ;
    CCF         ;
    RET         ;

;------------------------------
; PARSE_HEX_NIBBLE: Parses hex nibble
; Inputs: DE - pointer
; Outputs: A - nibble, C set if invalid
; Modifies: A
;------------------------------
PARSE_HEX_NIBBLE:
    LD A,(DE)           ; Load char
    SUB '0'         ; Convert to value
    CP 10               ; Check if 0-9
    JR C,PHN_VALID  ; 0-9
    CP 17               ; Gap
    JR C,PHN_INVALID; Gap invalid
    SUB 7           ; Adjust for A-F
    CP 16               ; Check if <16
    JR C,PHN_VALID ; >F invalid
    CP 42               ; Gap
    JR C,PHN_INVALID; Gap invalid
    SUB 32           ; Adjust for a-f
    CP 16               ; Check if <16
    JR NC,PHN_INVALID ; >F invalid
PHN_VALID:
    AND A           ; Clear carry (AND sets C=0)
    RET                 ; Return valid
PHN_INVALID:
    SCF             ; Set carry
    RET                 ; Return invalid

;------------------------------
; PARSE_DEC: Parses decimal number
; Inputs: DE - string pointer
; Outputs: HL - value, DE - after digits
; Modifies: A, B, C, DE, HL
;------------------------------
GET_LINE_NUMBER:	; Early jump point to set DE with input buffer location for editor
	LD DE,IN_BUF+3	; Point to digits
PARSE_DEC:
	LD HL,0		; Sets starting value to 0
    LD A,(DE)   ; Check if we have a minus sign
    CP "-"      ; Compare to set flags
    PUSH AF     ; Stash it for later negation if needed
    JR NZ,PARSE_DEC_LOOP ; Don't skip to next char if no minus sign
    INC DE      ; If thee's a minus sing, skip to next char
PARSE_DEC_LOOP:
	LD A,(DE)	; Get character from string pointer
	SUB "0"		; Turn char into value
	CP 10		; Check if it"s a digit
	JR NC,PD_DONE		; If not, go negate if needed
	LD B,H		; Copies HL to BC
	LD C,L		; Copy low
	ADD HL,HL	; Then multiplies by 10. HL=(HL*2*2+1)*2
	ADD HL,HL	; Shift
	ADD HL,BC	; Add original
	ADD HL,HL	; Shift
	ADD A,L		; A = A + L
	LD L,A		; L = A + L (because there"s not a ADD L,A)
	ADC A,H		; A = A + L + H + carry (which seems weird to add H to it, but...)
	SUB L		; remove L so we get A = H + carry
	LD H,A		; H = H + carry so in the end HL = HL + A
	INC DE		; Increment pointer to next char
	JR PARSE_DEC_LOOP ; Continue
PD_DONE:        ; Return with value in HL and DE pointing to first non-decimal character
    POP AF      ; Get the flags initially testing if we have a minus sign
    RET NZ      ; If not, we're done
    JR NEG_HL   ; If so, we negate HL and return from there

;------------------------------
; PRINT_DEC: Prints HL as decimal with leading zeros suppressed
; Inputs: HL - value
; Outputs: None
; Modifies: A, B, HL
;------------------------------
PRINT_DEC:
    BIT 7,H     ; Test if HL is negative
    JR Z,PD_POS ; If not, go print without minus sign
    LD E,"-"    ; Set E with minus sign for BDOS call
    CALL PRINT_CHAR
    CALL ABS_CTOG_HL
PD_POS:
	LD A,H		; Load high byte of HL into A to check if HL is zero
	OR L		; Combine with low byte to see if HL is zero
	JR NZ,PD_START	; If HL is not zero, jump to PD_START
	LD E,'0'	; Load '0' character into A for printing
	JR PRINT_CHAR	; Go print '0' and exit the routine from there
PD_START:		; Start processing digits when HL is not zero
	XOR A		; A=0 for sentinel
	PUSH AF		; Push sentinel
PD_LOOP:		; Loop to extract each decimal digit
	XOR A		; Clear A to start digit calculation
	LD B,16		; Set B to 16 for inner loop (16 bits)
PD_DLOOP:		; Inner loop to divide HL by 10
	ADD HL,HL	; Shift HL left (multiply by 2)
	RLA		; Shift A left, including carry from HL
	CP 10		; Check if A is 10 or more
	JR C,PD_NO	; If A < 10, skip subtraction
	SUB 10		; Subtract 10 from A if needed
	INC L		; Add 1 to L for division adjustment
PD_NO:			; Continue after checking subtraction
	DJNZ PD_DLOOP	; Repeat inner loop 16 times
	ADD A,'0'	; Convert digit in A to ASCII ('0' to '9')
	PUSH AF		; Save digit character on the stack
	LD A,H		; Check if HL is zero
	OR L		; Combine with L to test
	JR NZ,PD_LOOP	; If HL not zero, get next digit
PD_PRINT:		; Loop to print digits
	POP AF		; Get next digit from stack
	OR A		; Test for sentinel (0)
	RET Z		; Done if sentinel
	LD E,A          ; Load to E
	CALL PRINT_CHAR	; Print the digit
	JR PD_PRINT	; Continue

;------------------------------
; PRINT_CHAR: Prints char in E
; Inputs: E - char
; Outputs: None
; Modifies: None
;------------------------------
PRINT_CHAR:
	PUSH HL         ; Preserve HL
	PUSH BC         ; Preserve BC
	LD C,BDOS_CON_OUT ; Set function
	CALL BDOS       ; Call BDOS
	POP BC          ; Restore BC
	POP HL          ; Restore HL
	RET             ; Return

;------------------------------
; PRINT_CR_LF: Prints CR LF
; Inputs: None
; Outputs: None
; Modifies: None
;------------------------------
PRINT_CR_LF:
	PUSH DE         ; Preserve DE
	LD E,$0D        ; CR
	CALL PRINT_CHAR ; Print CR
	LD E,$0A        ; LF
	CALL PRINT_CHAR ; Print LF
	POP DE          ; Restore DE
	RET             ; Return

;------------------------------
; MATCH_ONE: Matches one closer
; Inputs: H - closer, DE - start
; Outputs: DE - at closer, Z set
; Modifies: A, BC, DE, HL, SP
;------------------------------
MATCH_ONE:
	LD L,0                    ; Second closer = none
MATCH_LOOP:
	LD A,(DE)                 ; Load char
	INC DE                    ; Advance
	OR A                      ; EOF?
	JR Z,ERROR_STUB           ; Error
	CP H                      ; Primary closer?
	JR Z,MATCH_FOUND          ; Yes
	CP L                      ; Secondary?
	JR NZ,MATCH_STRAY         ; No: check special
MATCH_FOUND:
	RET                       ; Return with DE pointing to character after the closer, Caller sets script program counter if needed
MATCH_STRAY:
	CP "]"                    ; Stray proc closer?
	JR Z,ERROR_STUB           ; Error
	CP "}"                    ; Stray loop closer?
	JR Z,ERROR_STUB           ; Error
	CP ")"                    ; Stray ifelse closer?
	JR Z,ERROR_STUB           ; Error
	CP "("                    ; Open if?
	JR Z,MATCH_DO_IF   		  ; Yes <<< UPDATED: now full skip
	CP "["                    ; Open proc?
	JR Z,MATCH_DO_PROC        ; Yes
	CP "{"                    ; Open loop?
	JR Z,MATCH_DO_LOOP        ; Yes
	CP 92                     ; Open \ (else)?
	JR Z,MATCH_DO_ELSE        ; Yes
	CP 34                     ; quote ?
	JR NZ,MATCH_LOOP          ; No: loop
MATCH_DO_QUOTE:
	CALL QUOTE_SCAN           ; Skip quote
	JR Z,MATCH_LOOP           ; OK
	JR ERROR_STUB             ; Error
MATCH_DO_IF:                  ; ( – skip full if-else
	LD A,92                   ; First: skip to \ (end of true branch)
	CALL MATCH_NEST           ; (advances DE to after \ )
	LD A,")"                  ; Then: skip to ) (end of false branch)
	CALL MATCH_NEST           ; (advances DE to after ) )
	JR MATCH_LOOP             ; Continue
MATCH_DO_PROC:
	LD A,"]"                  ; Closer proc
	JR MATCH_NEST             ; Nest
MATCH_DO_LOOP:
	LD A,"}"                  ; Closer loop
	JR MATCH_NEST             ; Nest
MATCH_DO_ELSE:
	LD A,")"                  ; Closer else
	JR MATCH_NEST             ; Nest
MATCH_NEST:
	PUSH HL                   ; Save closers
	LD HL,0                   ; HL=0
	ADD HL,SP                 ; SP check
	LD BC,STACK_CPU_BOT       ; Bottom
	OR A                      ; Clear carry
	SBC HL,BC                 ; Overflow?
	JR C,ERROR_STUB           ; Error
	LD H,A                    ; New closer
	LD L,0                    ; Single
	CALL MATCH_LOOP           ; Recurse
	POP HL                    ; Restore
	JR NZ,ERROR_STUB          ; Failed: error
	INC DE                    ; Past closer
	JR MATCH_LOOP             ; Continue
ERROR_STUB:
	JP ERROR_HANDLER          ; Error

;------------------------------
; QUOTE_SCAN: Scans quoted string
; Inputs: DE - after "
; Outputs: DE - after closing ", Z set if found
; Modifies: A, DE
;------------------------------
QS_SKIP:
	INC DE				; Skip the escaped character
QUOTE_SCAN:
	LD A,(DE)			; Load current char in quoted string
	INC DE				; Advance pointer
	OR A				; End of data?
	RET Z				; Yes: unclosed quote
	CP "~"				; Is this the escape character?
	JR Z,QS_SKIP		; Yes: skip next character
	CP 34				; Is this the closing quote? (ASCII 34)
	JR NZ,QUOTE_SCAN	; No: continue scanning
	XOR A				; Set z flag for success
	RET					; Return with z set

;------------------------------
; PRINT_STR: Prints $ terminated string in DE
; Inputs: DE - string ptr
; Outputs: None
; Modifies: C
;------------------------------
PRINT_STR:
	LD C,BDOS_PRINT_STR ; Set function
;	JR BDOS         ; Call BDOS   ; fall through

;------------------------------
; BDOS: Calls BDOS function
; Inputs: C - function, DE - param
; Outputs: A - result
; Modifies: IX, IY
;------------------------------
BDOS:
	PUSH IX                 ; Preserve IX
	PUSH IY                 ; Preserve IY
	CALL BDOS_CALL          ; Call BDOS
	POP IY                  ; Restore IY
	POP IX                  ; Restore IX
	RET                     ; Return

;------------------------------
; CHECK_CTRL_C: Checks for CTRL-C
; Inputs: None
; Outputs: None
; Modifies: A, BC, DE
;------------------------------
CHECK_CTRL_C:
	PUSH BC             ; Preserve BC
	PUSH DE             ; Preserve DE
	LD C,BDOS_CON_DIR_IO	; Sets BDOS direct console I/O
	LD E,$FF	; Sets BDOS call to check for any keypresses, non-blocking
	CALL BDOS	; Calls BDOS function. Returns with keypress in A or 0 in A if no keypress
	CP $03		; If CTRL-C was pressed
	JR Z,EDIT_MAIN	; then jump to the editor
	OR A		; Set flags for other characters
	POP DE      ; Restore DE
	POP BC      ; Restore BC
	RET         ; Return

B8SCRIPT_EDITOR_START:
;=====================================================================
; Script Editor
;=====================================================================

;------------------------------
; INIT: Initializes the system
; Inputs: None
; Outputs: None
; Modifies:
;------------------------------
INIT:						; Initializes editor using the Clear function

;------------------------------
; EDIT_CLEAR: Clears script
; Inputs: None
; Outputs: None
; Modifies: HL
;------------------------------
EDIT_CLEAR:
	LD HL,SCRIPT_START		; Gets the address of the start of the script buffer
	LD (HL),0				; Set the end of file byte as the first character in the script buffer
	INC HL                  ; Increment HL
	LD (SCRIPT_END),HL		; And sets the end of script address char after the last
	XOR A					; Set A to 0
	LD (PLUGIN_FIRST),A		; Set the first plugin link pointer
	LD (PLUGIN_FIRST + 1),A ; to zero
	
;------------------------------
; EDIT_MAIN: Editor main loop
; Inputs: None
; Outputs: None
; Modifies: A
;------------------------------
EDIT_MAIN:
	LD SP,STACK_CPU_TOP		; Set top of CPU stack. CP/M default stack is too small
	CALL PRINT_CR_LF		; Give us a little space
	LD E,"]"				; Prints editor prompt
	CALL PRINT_CHAR         ; Print prompt
	CALL INPUT_LINE			; Get a editor command from the user
	LD A,(IN_BUF+2)			; Or get the first letter in the input buffer
	AND $5F					; Set command letter to uppercase
	CP "L"                  ; List. Compares it to the letter for each menu item
	JP Z,EDIT_LIST          ; Jump to list
	CP "D"                  ; Delete
	JR Z,EDIT_DELETE        ; Jump to delete
	CP "C"                  ; Clear
	JR Z,EDIT_CLEAR         ; Clear
	CP "R"                  ; Run
	JR Z,EDIT_RUN           ; Jump to run
	CP "O"                  ; Open
	JR Z,EDIT_OPEN          ; Jump to open
	CP "S"                  ; Save
	JP Z,EDIT_SAVE         ; Jump to save
	CP "I"					; Insert
	JR Z,EDIT_INSERT        ; Jump to insert
	CP "Q"                  ; Quit
	JR NZ,EDIT_MAIN	; If none of the menu letters were entered, start over
	JP $0000		; But if "Q" then jump to CP/M

;------------------------------
; EDIT_OPEN: O Opens file
; Inputs: None
; Outputs: None
; Modifies: DE, HL
;------------------------------
EDIT_OPEN:          	; Ofilename
    CALL GET_FILENAME   ; Gets filename starting after the O command
    CALL FILE_OPEN      ; Open
    LD HL,SCRIPT_START  ; Dest
    CALL FILE_LOAD      ; Load
    LD (HL),0           ; Add EOF null
    INC HL              ; Next
    LD (SCRIPT_END),HL  ; Update end
    CALL FILE_CLOSE     ; Close
    JR EDIT_MAIN        ; Back

;------------------------------
; EDIT_DELETE: Dn Deletes line
; Inputs: None
; Outputs: None
; Modifies: A, BC, DE, HL
;------------------------------
EDIT_DELETE:
	CALL GET_LINE_NUMBER	; Parse to HL
	CALL GET_LINE 			; We have the line number we're looking for in HL. Returned are the insertion point in LINE_START and the new line number in BC
	JR NC,EDIT_MAIN			; Error back if line not found
	LD HL,(SCRIPT_END)		; Get the address of the end
	LD DE,(LINE_NEXT)       ; End of line
	OR A					; Clear carry
	SBC HL,DE				; Get tail size
	LD B,H					; Move it to BC for byte count
	LD C,L                  ; Low byte
	LD HL,(LINE_NEXT)       ; Source
	LD DE,(LINE_START)		; Put LINE_START into DE as destination
	LDIR					; Slide the tail down
	LD (SCRIPT_END),DE		; Final destination address is where EOF goes. Update end of script pointer
	JR EDIT_MAIN			; Back to editor

;------------------------------
; EDIT_RUN: R Runs the script
; Inputs: None
; Outputs: None
; Modifies: BC, DE, HL, IX, IY, SCRIPT_PC, HEAP_PTR
;------------------------------
EDIT_RUN:
	LD DE,TEMP_FILENAME
	CALL PARSE_FILENAME
	CALL SAVE_FILE
	CALL PRINT_CR_LF        ; New line
	LD IX,STACK_TOP			; Set data stack pointer
	LD IY,STACK_CTRL_TOP	; Set control stack pointer
	LD HL,SCRIPT_START		; Get start of script buffer
	LD (SCRIPT_PC),HL		; and assign in starting program counter address
    LD HL,(SCRIPT_END)      ; HL = address after NUL ($00)
    LD (HEAP_PTR),HL        ; Heap starts here
CLEAR_PROC_TABLE:
	LD HL,TABLE_PROC		; Get address of procedure table
	LD DE,ERROR_HANDLER		; Get address of error handler
	LD B,26				; Set counter for 26 entries
CLEAR_PROC_LOOP:			; Set each procedure A-Z slot to default error handler to protect from uninitialize use
	LD (HL),E				; Put low byte of error handler address into low byte of procedure address
	INC HL					; Set up for high byte
	LD (HL),D				; Put high byte of error handler address into high byte of procedure address
	INC HL					; Set up for next slot
	DJNZ CLEAR_PROC_LOOP	; DEC B and see if we"re done
	LD B,52					; Set counter for 26 x 2 byte entries
CLEAR_VAR_LOOP:				; Clear each variable a-z slot
	LD (HL),0				; Clear all variable slots
	INC HL					; Set up for next slot
	DJNZ CLEAR_VAR_LOOP		; DEC B and see if we"re done
	JP MAIN_RUN_LOOP		; Jump to main loop to begin executing the script

TEMP_FILENAME:
	DB "TEMP "
;------------------------------
; EDIT_INSERT: I[n] Inserts line
; Inputs: None
; Outputs: None
; Modifies: A, BC, DE, HL, LINE_FOUND, SCRIPT_END, line buffer
;------------------------------
EDIT_INSERT:
	CALL GET_LINE_NUMBER	; Parse to HL
GOT_LINE:
	CALL GET_LINE 			; We have the line number we're looking for in HL. Returned are the insertion point in LINE_START and the new line number in BC
	JR C,INSERT_FOUND       ; Found
INSERT_END:
	INC BC                  ; If we didn't find the line, increment line to the new line number at the end
INSERT_FOUND:
	LD (LINE_FOUND),BC      ; Store found
	PUSH BC					; Push actual line number
	CALL PRINT_CR_LF		; Go down one line
	POP HL					; And pop it out as HL for PRINT_DEC, conveniently avoiding getting clobbered by BDOS
	CALL PRINT_DEC			; Print the line number
	LD E,'>'				; and the prompt
	CALL PRINT_CHAR         ; Print prompt
	CALL INPUT_LINE			; Get the line from the user
	LD A,(IN_BUF+1)         ; Get length
	OR A                    ; Zero?
	JP Z,EDIT_MAIN          ; Yes, back to main
	LD HL,(SCRIPT_END)		; Get the script end pointer (at the EOF null)
	LD DE,(LINE_START)		; Get pointer to insertion point
	SBC HL,DE				; Subtract line start from new end to find byte count
	PUSH HL					; Stash it as byte count for LDDR later
	ADD HL,DE				; Add it back to get script end again
	PUSH HL					; Stash script end as source for LDDR later
	LD E,A					; Copy total to DE
	LD D,0                  ; High zero
	INC DE					; Add 2 to account for CR+LF which will be added later
	INC DE                  ; Second inc
	ADD HL,DE				; Add it to script end to get new end
	LD (SCRIPT_END),HL		; Store new script end
	EX DE,HL				; Move new end in HL to DE as destination for LDDR
	POP HL					; Pop end script as source
	POP BC					; Pop byte count
	DEC DE                  ; Adjust DE
	DEC HL                  ; Adjust HL
	LDDR					; And move it
	LD HL,IN_BUF+2			; Set the source. i.e. first char of line buffer
	LD DE,(LINE_START)		; Start of line is destination
	LD C,A					; Load chars to copy in C
	LD B,0					; BC is now byte count
	LDIR					; Copy text
	LD A,$0D				; Set carriage return
	LD (DE),A				; Add it. DE was left at next char
	INC DE                  ; Increment DE
	LD A,$0A				; And line feed
	LD (DE),A				; Add it too
	LD HL,(LINE_FOUND)      ; Load found line
	INC HL                  ; Increment to next
	JR GOT_LINE             ; Continue insert

;------------------------------
; EDIT_LIST: L[n] Lists script
; Inputs: None
; Outputs: None
; Modifies: A, DE, HL
;------------------------------
EDIT_LIST:
	CALL GET_LINE_NUMBER	; Parse to HL
	CALL GET_LINE 			; We have the line number we're looking for in HL. Returned are the insertion point in LINE_START and the new line number in BC
	LD DE,(LINE_START)      ; Start
	LD H,B                  ; H = B
	LD L,C                  ; L = C
    JR C,EL_LOOP			; Num present: use it
    LD HL,1					; Default: 1
	LD DE,SCRIPT_START      ; Start
EL_LOOP:
	LD A,(DE)				; Get char
	OR A					; EOF?
	JP Z,EDIT_MAIN			; Yes (though shouldn't hit here)
	PUSH HL                 ; Save line num
	PUSH DE                 ; Save ptr
	CALL PRINT_CR_LF		; New line
	CALL PRINT_DEC			; Print line number
	LD E,':'				; Print colon
	CALL PRINT_CHAR         ; Print
	POP DE                  ; Restore ptr
EL_LINE_LOOP:
	LD A,(DE)				; Get char
	INC DE                  ; Advance
	OR A					; EOF?
	JP Z,EDIT_MAIN			; Yes (though shouldn't hit here)
	CP $0A					; LF?
	JR Z,EL_LINE_END		; Yes
	PUSH DE					; Save pointer
	LD E,A					; Char to E
	CALL PRINT_CHAR			; Print it
	CALL CHECK_CTRL_C       ; Check key
	JR NZ,PAUSE_WAIT        ; Key pressed
	POP DE					; Restore
	JR EL_LINE_LOOP			; Continue
EL_LINE_END:
	POP HL                  ; Restore line num
	INC HL                  ; Next line
	JR Z,EL_LOOP			; No key, continue to next line
PAUSE_WAIT:
	CALL CHECK_CTRL_C       ; Check
	JR Z,PAUSE_WAIT			; Wait for key
	JR EL_LOOP				; Resume

;------------------------------
; EDIT_SAVE: Sf Saves script
; Inputs: None
; Outputs: None
; Modifies: A, B, C, DE, HL, IX
;------------------------------
EDIT_SAVE:
    CALL GET_FILENAME 	; Parses the filename after the S
    JP EDIT_MAIN        ; Back

SAVE_FILE:
    LD DE,FILE_FCB      ; FCB
    LD C,BDOS_FILE_DELETE ; Delete
    CALL BDOS           ; Ignore return
    LD DE,FILE_FCB      ; FCB
    LD C,BDOS_FILE_MAKE ; Make
    CALL BDOS_ERR_CHK   ; Call
    LD HL,SCRIPT_START  ; Source
FS_NEXT_LOOP:
    LD B,128              ; Bytes in current buffer
    LD DE,FILE_DMA      ; Buffer pointer
FS_LOOP:
	LD A,(HL)            ; Load next character from script buffer (source HL)
	OR A                 ; Set flags to check for EOF null ($00)
	JR Z,FS_DONE         ; If zero, jump to done (close file)
	INC HL               ; Increment source pointer early (to next char for next iteration)
	LD (DE),A            ; Store the loaded char into current DMA buffer slot (IX)
	INC DE               ; Increment buffer pointer to next slot
	DJNZ FS_LOOP         ; No, loop back for next char
	CALL FS_WRITE_BUF    ; Yes, write the full sector to file
	JR FS_NEXT_LOOP      ; Loop back for next char
FS_DONE:
	LD A,B               ; Load final buffer count into A
	CP 128               ; Set flags to check if zero (no data left)
	JR Z,FS_CLOSE        ; If zero, skip write/pad and just close file
	LD A,26              ; Load ^Z ($1A) for EOF padding
FS_PAD:
	LD (DE),A            ; Store ^Z in current buffer slot (IX points after last data)
	INC DE               ; Increment to next slot
	DJNZ FS_PAD          ; Decrement B and loop if pads remain
	CALL FS_WRITE_BUF    ; Write the final buffer (full or partial+padded); no extra sector
FS_CLOSE:
    JP FILE_CLOSE  		 ; Close (always)

FS_WRITE_BUF:
	PUSH HL
	PUSH DE
    LD DE,FILE_DMA      ; DMA
    LD C,BDOS_DMA_ADDR  ; Function
    CALL BDOS           ; Set
    LD DE,FILE_FCB      ; FCB
    LD C,BDOS_FILE_WRITE ; Write
    CALL BDOS           ; Call
    OR A                ; Error? 
    JP NZ,ERROR_HANDLER ; Yes
	POP DE
	POP HL
	RET

;=====================================================================
; Support routines
;=====================================================================

;------------------------------
; FILE_OPEN: Opens file
; Inputs: None
; Outputs: A=0 success
; Modifies: C, DE
;------------------------------
FILE_OPEN:
    LD DE,FILE_FCB      ; FCB
    LD C,BDOS_FILE_OPEN ; Function
    JR BDOS_ERR_CHK           ; Call

;------------------------------
; FILE_CLOSE: Closes file
; Inputs: None
; Outputs: A=0 success
; Modifies: A, C, DE
;------------------------------
FILE_CLOSE:
    LD DE,FILE_FCB      ; FCB
    LD C,BDOS_FILE_CLOSE ; Function
    JR BDOS_ERR_CHK           ; Call

;------------------------------
; BDOS_ERR_CHK: Common function
; Inputs: None
; Outputs: None
; Modifies: None
;------------------------------
BDOS_ERR_CHK:
    CALL BDOS           ; Call
    CP $FF                ; Check
    JP Z,ERROR_HANDLER    ; Error
	RET

;------------------------------
; GET_LINE: Locates line by number
; Inputs: HL - line number
; Outputs: BC - found line, DE - end, C set if found
; Modifies: A, BC, DE, HL, LINE_START, LINE_NEXT, LINE_FOUND
;------------------------------
GET_LINE:					; Called with the line number we're looking for in HL.
	LD BC,0					; Line counter
	LD DE,SCRIPT_START		; Starting looking at the beginning of the script
    LD (LINE_START),DE		; remember start of line 1
	LD (LINE_NEXT),DE		; and set it as start of next line
LOCATE_LOOP:
	LD A,(DE)				; Check the character where we're at now
	INC DE					; Increment the pointer to the next character
	OR A					; Set flags to test A
	JR Z,LOCATE_DONE        ; Done if zero
	CP $0A					; Is it a line feed? (ASCII $0A)
	JR NZ,LOCATE_LOOP		; If not, go to the next character
FOUND_LINE_END:
	INC BC					; Then we increment our line counter
	LD (LINE_NEXT),DE		; and set end of line to current position
	;OR A					; Clear carry flag so we can
	SBC HL,BC				; SBC to compare the line we're looking for, HL, with the lines we've counted so far
	JR Z,FOUND_LINE			; If they match return with the new line number in BC and the insertion point in DE
	ADD HL,BC				; If they don't match, restore HL to what it was before
	LD IX,(LINE_NEXT)		; Otherwise, get previous line end
    LD (LINE_START),IX		; and set it as line start
	JR LOCATE_LOOP			; And check again
FOUND_LINE:
	SCF						; Carry flag indicates success
LOCATE_DONE:
	LD (LINE_FOUND),BC      ; Store found line
	RET                     ; Return

;------------------------------
; INPUT_LINE: Gets input line
; Inputs: None
; Outputs: None
; Modifies: A, BC, DE, HL, input buffer
;------------------------------
INPUT_LINE:
	LD B,127			; Load BC with 125, the number of bytes to clear after the first one
	LD HL,IN_BUF + 127	; Load HL with the address of the first byte to clear (IN_BUF+2)
IL_CLEAR:
	LD (HL),0			; Set the first byte at HL to 0
	DEC HL
	DJNZ IL_CLEAR		; Copy 0 from HL to DE for BC bytes, effectively zeroing the buffer
	LD (HL),126			; Store max length in first byte of input buffer (BDOS requirement)
	LD C,BDOS_CON_BUF	; Load C with BDOS function 10 (buffered console input)
	LD DE,IN_BUF		; Load DE with address of input buffer
	JP BDOS				; Call BDOS - returns with actual count in IN_BUF+1, data in IN_BUF+2...

;------------------------------
; PARSE_FILENAME: Parses filename to FCB
; Inputs: DE - start
; Outputs: DE - after
; Modifies: B, DE, HL
;------------------------------
GET_FILENAME:				; Early jump point to set DE with input buffer location
    LD DE,IN_BUF + 3	    ; Start at at first char of filename
PARSE_FILENAME:				; DE = start of filename string, sets FCB, advances DE to after last char
	LD HL,FILE_FCB + 36 	; Point to one space past the end of the FCB
	LD B,36					; Counter for control fields (FCB+12 to +35)
ZERO_LOOP:
	DEC HL					; Start at the end of the FCB and move down, ending on FCB drive letter
	LD (HL),0				; Fill with whole FCB with zeros
	DJNZ ZERO_LOOP			; Loop
	LD B,8					; Max characters to copy is 8
PF_LOOP:
    LD A,(DE)				; Get a character
    CP "z" + 1         		; Is it above "z"?
    JR NC,PF_PAD			; If so, then it's the first invalid character and we're done parsing, go pad with spaces
    CP "a"					; Is it below "a"?
	JR C,NOT_LC				; If so, then we're not a lowercase character
	AND $5F					; If not, then we are and we tweak it into an uppercase letter
NOT_LC:
	CP "Z" + 1				; Is it above "Z"?
    JR NC,PF_PAD		    ; If so, tt's the first invalid character and we're done parsing, go add the extension
	CP "A"					; Is it above or on "A"?
    JR NC,NEXT_PF     		; If so, then we're a captial letter and we go copy it and get the next
	CP "9" + 1				; Is it above "9"?
	JR NC,PF_PAD			; If so, then it's the first invalid character and we're done parsing, go add the extension
	CP "0"					; Is it below "0"
	JR C,PF_PAD				; If so, then it's the first invalid character and we're done parsing, go add the extension
NEXT_PF:
	INC HL					; Bump up to first char of filename and move up
	LD (HL),A				; Copy the character to the FCB
    INC DE              	; Move to the next byte in the filename we're checking
    DJNZ PF_LOOP        	; Get another character until we have done all 8
	JR PF_SET_EXT			; If we get here, no padding needed, go set the extension
PF_PAD:
	LD A,B
	CP 8
	JP Z,ERROR_HANDLER
	INC HL					; Bump up, ending on first character of extension
	LD (HL)," "				; Pad remainder with spaces
	DJNZ PF_PAD				; Keep going until all eight filename characters have been filled
PF_SET_EXT:
	INC HL					; Bump to start of extension
    LD (HL),'B'         	; Copy "B"
    INC HL              	; Next
    LD (HL),'8'         	; Copy "8"
    INC HL              	; Next
    LD (HL),'S'         	; Copy "S"
    RET                 	; And we're done, leaving DE on the character after the filename we just parsed

;------------------------------
; FILE_LOAD: Loads file to HL
; Inputs: HL - dest
; Outputs: HL - after loaded
; Modifies: A, B, C, DE, HL
;------------------------------
FILE_LOAD:                   ; Entry only for scripts (extension 'S', LOAD_SIZE=FFFF)
    LD BC,$FFFF              ; Set imaginary max size for scripts (^Z or EOF stops)
    LD (LOAD_SIZE),BC      	 ; Store to check var (won't trigger for scripts)
    INC BC                   ; Reset BC to 0 as total copied counter
FL_LOOP:                     ; Sector loop
    CALL LOAD_SECTOR         ; Read next sector (A=BDOS result: 0=OK, !=0=EOF)
    OR A                     ; Test BDOS return for EOF
    JR Z,FL_COPY             ; If not zero, go copy the sector to memory
    LD (HL),0                ; Otherwise add NULL terminator at current dest (after last good data), only could get here when loading a script
    RET                      ; Done loading. Return
FL_COPY:                     ; Byte copy loop (shared entry for plugins)
    LD A,(FILE_FCB+11)       ; Load extension third char ('S' script/'X' plugin)
    CP "X"                   ; Check if plugin
    LD A,(DE)                ; Load next source byte from DMA
    JR Z,FL_PLUGIN           ; If plugin, skip ^Z check and always store
    CP $1A                   ; For script: Check for ^Z EOF marker
    RET Z                    ; If ^Z, terminate without storing it (caller adds NULL)
FL_PLUGIN:                   ; Store path for both
    LD (HL),A                ; Store byte to destination
    INC HL                   ; Advance dest pointer
    INC DE                   ; Advance source pointer
    INC BC                   ; Increment copied count
    PUSH HL                  ; Preserve dest for check
    LD HL,(LOAD_SIZE)        ; Load target size
    OR A                     ; Clear carry for subtract
    SBC HL,BC                ; Compare copied to size
    POP HL                   ; Restore dest
    RET Z                    ; If equal, terminate. This would happend if we have loaded all the bytes in a plugin, but not for scripts, since we're checking for ^Z in that case
    PUSH DE                  ; Preserve source pointer
    CALL TPA_OVERFLOW        ; Check if next HL would overflow TPA
    POP DE                   ; Restore source pointer
    LD A,$7F                 ; Mask for mod 128 check (sector boundary)
    AND C                    ; C & 127 (low bits of count)
    JR NZ,FL_COPY            ; If it didn't roll over to zero continue byte copy in sector
    JR FL_LOOP               ; If it did, we're at the end of the sector, so loop for next

;------------------------------
; LOAD_SECTOR: Loads a sector from disk to DMA buffer
; Inputs: FCB configured
; Outputs: DMA filled with sector data
; Modifies: DE
;------------------------------
LOAD_SECTOR:
	PUSH HL					; Preserve destination
	PUSH BC					; Preserve total byte counter
    LD DE,FILE_DMA			; Get the DMA address
    LD C,BDOS_DMA_ADDR		; Configure BDOS to set current DMA address
    CALL BDOS				; Set it
    LD DE,FILE_FCB			; Get the FCB pointer
    LD C,BDOS_FILE_READ		; Configure BDOS to read a sector
    CALL BDOS_ERR_CHK		; Read it
    LD DE,FILE_DMA			; Point back to the start of the Source again
	POP BC					; Restore total byte counter
	POP HL					; Restore destination
    RET

B8SCRIPT_END:	; End of source code