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
CALL_PLUG           EQU $0103   ; Load CALL_PLUG_ADDR with address to be called
CALL_PLUG_ADDR      EQU $0104   ; and CALL CALL_PLUG

; STACK_JUMP_TABLE              ; Pointers to stack and process functions
PROCESS_SCRIPT_CHAR	EQU $0106   ; Load A with script command to process
PLUGIN_BASE         EQU $0108   ; Points to the first address of loaded plugin
SCRIPT_PC           EQU $010A   ; Points to current location of the script program counter which is at the last character of the plugin filename when plugin is executed
SCRIPT_START        EQU $010C   ; Points to the start of the script
STACK_PUSH          EQU $010E   ; Pushes HL to top of stack
STACK_POP           EQU $0110   ; Pops HL from top of stack

ORG $0000                       ; This allows all labels to be used as offsets from the start of the plugin to calculate the absolute address of those labels
PLUGIN_START:
    DW PLUGIN_END       ; Calculates the plugin size for loading. Loader grabs this word to know how much to load. Plugins are called to address right after this.  Don't delete this or plugin won't work.


	LD DE,(STACK_POP)	; Get a value off the stack
    LD (CALL_PLUG_ADDR),DE
    CALL CALL_PLUG
	LD B,4				; Set for four nibbles
HEXLOOP:
	LD A,H				; Push H into A
	OR A            	; Reset carry flag
	RRCA				; Shift A four bits
	RRCA				; to the right to get the nibble we want
	RRCA				; in the right hand nibble
	RRCA             	; A now holds the current high nibble
	AND $0F				; Isolate low nibble
	CP $0A				; Compare to 10 (for hex A-F adjustment threshold)
	SBC A,$69			; Subtract 69h with carry (effective branchless adjustment)
	DAA					; Decimal adjust to finalize ASCII hex char
	LD E,A				; Put A in E for BDOS call
    PUSH HL
    PUSH BC
	LD C,2 ; Set function
	CALL $0005       ; Call BDOS
    POP BC
    POP HL
	ADD HL, HL			; Now shift
	ADD HL, HL			; HL
	ADD HL, HL			; To the left for next nibble
	ADD HL, HL      	; Shift HL left by 4 bits
	DJNZ HEXLOOP

    RET
PLUGIN_END: