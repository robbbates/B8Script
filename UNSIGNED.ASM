; B8Script Plugin Template 1.0
; Plugins must be entirely relocatable
; No Absolute addresses must be used within the plugin without helper routines
; Absolute addresses in the B8SCRIPT.COM code may be used,
; but different versions may vary
; Only locations listed below should not change,
; and are meant to be compatible across versions
; All regsiters except IX and IY are available for use.  IX and IY may be used if preserved and restored
; IX points to top of data stack.  IY points to top of control stack

; CALL self modifying code for CALLing functions listed below from within the plugin
PLUGIN_CALL         EQU $0103   ; Load CALL_PLUG_ADDR with address to be called
PLUGIN_CALL_ADDR    EQU $0104   ; and CALL PLUGIN_CALL

; STACK_JUMP_TABLE              ; Pointers to stack and process functions
PROCESS_SCRIPT_CHAR	EQU $0106   ; Load A with script command and call this to process a command. Be aware some commands modify the script program counter
PLUGIN_BASE         EQU $0108   ; Points to the first address of loaded plugin
SCRIPT_PC           EQU $010A   ; Points to the next character being processed by the program (after plugin filename when plugin is called)
STACK_PUSH          EQU $010C   ; Pushes HL to top of stack
STACK_POP           EQU $010E   ; Pops HL from top of stack

ORG $0000                       ; This allows all labels to be used as offsets from the start of the plugin to calculate the absolute address of those labels
PLUGIN_START:
    DW PLUGIN_END       ; Calculates the plugin size for loading. Loader grabs this word to know how much to load. Plugins are called to address right after this.  Don't delete this or plugin won't work.


PRINT_UNSIGNED:
	LD DE,(STACK_POP)	; Get a value off the stack
    LD (PLUGIN_CALL_ADDR),DE
    CALL PLUGIN_CALL
	LD A,H		; Load high byte of HL into A to check if HL is zero
	OR L		; Combine with low byte to see if HL is zero
	JR NZ,PD_START	; If HL is not zero, jump to PD_START
	LD E,'0'	; Load '0' character into A for printing
	LD C,2 ; Set function
	JP $0005    ; Jump to BDOS and return from there
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
	LD C,2 ; Set function
	CALL $0005       ; Call BDOS
	JR PD_PRINT	; Continue

    RET
PLUGIN_END: