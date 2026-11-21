; B8Script Plugin Template 1.0
; Plugins must be entirely relocatable
; No Absolute addresses must be used within the plugin
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

;   DEC HL
;   DEC HL
;   LD (PLUGIN_BASE),HL         ; Do this first to capture HL which contains the address of the plugin when called which can be used as an offset for CALLS and JPs within the plugin
;
; To CALL internal subroutine
;   PUSH HL                     ; Preserve HL if needed
;   PUSH DE                     ; Preserve DE if needed
;   LD HL,(PLUGIN_ADDR)         ; Get base
;   LD DE,SUBROUTINE            ; Add the offset
;   ADD HL,DE                   ; HL = absolute addr of SUBROUTINE
;   LD BC,HL                    ; BC = target
;   POP DE                      ; Restore DE if needed
;   POP HL                      ; Restore DE if needed
;   CALL CALL_BC                ; Use fixed CALL_BC helper
; Return from subroutine continues execution here
;
;SUBROUTINE:
;   ;some code
;   RET


; Insert your Plugin code here.

    RET
PLUGIN_END: