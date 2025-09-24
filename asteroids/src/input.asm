; ----------------------------------------------------------------------------
; input.asm - Keyboard scanning and control state update
; ----------------------------------------------------------------------------

        INCLUDE "constants.inc"


; ----------------------------------------------------------------------------
; ReadControls
; Polls the ZX Spectrum keyboard matrix and sets control bits accordingly.
; ----------------------------------------------------------------------------
ReadControls:
        LD      HL, g_controlState
        LD      A, 0

        ; Row: P O I U Y  (address mask 0xDFFE)
        LD      BC, 0xDFFE
        IN      D, (C)
        BIT     1, D                     ; O key → rotate left
        JR      NZ, .noLeft
        SET     CTRL_LEFT, A
.noLeft:
        BIT     0, D                     ; P key → rotate right
        JR      NZ, .noRight
        SET     CTRL_RIGHT, A
.noRight:

        ; Row: Q W E R T (mask 0xFBFE)
        LD      BC, 0xFBFE
        IN      D, (C)
        BIT     0, D                     ; Q key → thrust
        JR      NZ, .noThrust
        SET     CTRL_THRUST, A
.noThrust:

        ; Row: Space, Sym, M, N, B (mask 0x7FFE)
        LD      BC, 0x7FFE
        IN      D, (C)
        BIT     2, D                     ; M key → fire
        JR      NZ, .noFire
        SET     CTRL_FIRE, A
.noFire:
        BIT     0, D                     ; Space key → hyperspace
        JR      NZ, .noHyper
        SET     CTRL_HYPERSPACE, A
.noHyper:

        ; Row: 1 2 3 4 5 (mask 0xF7FE)
        LD      BC, 0xF7FE
        IN      D, (C)
        BIT     0, D                     ; 1 key → start/reset
        JR      NZ, .noStart
        SET     CTRL_START, A
.noStart:

        LD      (HL), A                  ; Persist control state bits
        RET
