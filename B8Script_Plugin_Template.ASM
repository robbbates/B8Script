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
STACK_PUSH          EQU $0106   ; Pushes HL to top of stack
STACK_POP           EQU $0108   ; Pops HL from top of stack
PROCESS_SCRIPT_CHAR	EQU $010A   ; Load A with script command to process
SCRIPT_PC           EQU $010C   ; Points to current location of the script program counter which is at the last character of the plugin filename when plugin is executed
PLUGIN_FIRST        EQU $010E   ; First plugin link.  Can be used by plugins to call other plugins
PLUGIN_ADDR         EQU $0110   ; Points to the first address of loaded plugin
PLUGIN_DATA         EQU $0112   ; Points to an address that can be used to store the start of a block of heap

ORG $0000                       ; This allows all labels to be used as offsets from the start of the plugin to calculate the absolute address of those labels
PLUGIN_START:
;   LD (PLUGIN_ADDR),HL         ; Do this first to capture HL which contains the address of the plugin when called which can be used as an offset for CALLS and JPs within the plugin
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