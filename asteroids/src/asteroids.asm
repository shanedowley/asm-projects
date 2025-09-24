; ----------------------------------------------------------------------------
; ZX Spectrum Asteroids Clone
; Entry point, initialization, and main loop orchestration.
; Target: 48K Spectrum, assembled with pasmo.
; ----------------------------------------------------------------------------

        ORG     0x8000                 ; Load address for the assembled program
        INCLUDE "constants.inc"

; ----------------------------------------------------------------------------
; External module imports (order: code first, data appended later)
; ----------------------------------------------------------------------------
        INCLUDE "vectors.asm"
        INCLUDE "physics.asm"
        INCLUDE "input.asm"
        INCLUDE "sound.asm"
        INCLUDE "hud.asm"


; ----------------------------------------------------------------------------
; ROM routine references (addresses from 48K ROM)
; ----------------------------------------------------------------------------
CLS_ROM        EQU 0x0DAF              ; ROM: Clear screen and attributes

; ----------------------------------------------------------------------------
; Program entry point
; ----------------------------------------------------------------------------
START:
        DI                              ; Block interrupts while configuring
        LD      SP, STACK_TOP           ; Relocate stack to safe high memory

        CALL    InitSystem              ; Configure interrupts, clear screen, etc.

MainLoop:
        LD      A, 0x01                 ; blue border so we know we reached MainLoop
        OUT     (0xFE), A

        CALL    WaitFrame               ; Synchronize to 50 Hz interrupt
        CALL    ReadControls            ; Poll keyboard into g_controlState
        CALL    UpdateGame              ; Physics, spawning, collision, scoring
        CALL    RenderFrame             ; Draw the complete scene
        CALL    UpdateAudio             ; Trigger queued beeper effects
        JR      MainLoop                ; Loop forever (until reset)

; ----------------------------------------------------------------------------
; System initialization
; ----------------------------------------------------------------------------
InitSystem:
        LD      A, 0x07                 ; white border
        OUT     (0xFE), A
        CALL    CLS_ROM                 ; Clear the whole display

        XOR     A
        LD      (g_frameLatch), A       ; Reset frame timing helper
        LD      (g_soundQueue), A       ; Clear pending sound flag

        CALL    InitVectors             ; Prepare vector renderer tables
        CALL    ClearAttributes         ; Reset attribute table to white
        CALL    ColorizeHUD             ; Apply HUD colour bands
        CALL    InitGameState           ; Seed randomizer, create first wave
        CALL    InitHUD                 ; Reset score/lives display
        CALL    InitAudio               ; Reset audio engine state

        IM      1                       ; Use IM1 for VBL interrupts
        EI                              ; Allow interrupts for HALT sync
        RET

; ----------------------------------------------------------------------------
; Frame synchronization
; ----------------------------------------------------------------------------
WaitFrame:
        RET

; ----------------------------------------------------------------------------
; Append global data definitions near end of binary
; ----------------------------------------------------------------------------
        INCLUDE "data.asm"

; ----------------------------------------------------------------------------
; Export entry symbol for the assembler/linker
; ----------------------------------------------------------------------------
        END START
