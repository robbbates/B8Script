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

PRINT_ASCII_CHAR:
	LD DE,(STACK_POP)	; Get a value off the stack
    LD (PLUGIN_CALL_ADDR),DE
    CALL PLUGIN_CALL
	LD E,L				; Put the lower byte into E for the BDOS call
	LD C,2 ; Set function
	CALL $0005       ; Call BDOS
    RET

PLUGIN_END: