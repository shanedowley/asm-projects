; ----------------------------------------------------------------------------
; sound.asm - 1-bit beeper effects for ZX Spectrum Asteroids clone
; ----------------------------------------------------------------------------
; The audio engine consumes the per-frame sound queue (set by physics.asm)
; and translates each bit into a short 1-bit waveform on the 48K beeper.
; Each effect runs for a small number of frames to avoid stalling the game
; loop while still providing audible feedback.
; ----------------------------------------------------------------------------

        INCLUDE "constants.inc"

BEEPER_PORT        EQU 0xFE
FIRE_FRAMES        EQU 6
THRUST_FRAMES      EQU 3
EXPLOSION_FRAMES   EQU 20
NOISE_LFSR_TAP     EQU 0x1D

; ----------------------------------------------------------------------------
fireLoopTable:      DEFB    6, 10, 14, 18, 24, 30
thrustLoopTable:   DEFB    60, 52, 56, 48
explosionLoopTable: DEFB   10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 44, 48, 52, 56

; Module-scoped state
; ----------------------------------------------------------------------------
fireTimer:        DEFB    0
thrustTimer:      DEFB    0
explosionTimer:   DEFB    0
thrustPhase:      DEFB    0
noiseSeed:        DEFB    0x5A

InitAudio:
        XOR     A
        LD      (g_soundQueue), A
        LD      (fireTimer), A
        LD      (thrustTimer), A
        LD      (explosionTimer), A
        LD      A, 0x5A
        LD      (noiseSeed), A
        RET

UpdateAudio:
        LD      A, (g_soundQueue)
        LD      B, A
        XOR     A
        LD      (g_soundQueue), A

        LD      A, B
        BIT     0, A
        JR      Z, .noFireLoad
        LD      A, FIRE_FRAMES
        LD      (fireTimer), A
.noFireLoad:
        LD      A, B
        BIT     1, A
        JR      Z, .noThrustLoad
        LD      A, THRUST_FRAMES
        LD      (thrustTimer), A
.noThrustLoad:
        LD      A, B
        BIT     2, A
        JR      Z, .noExplosionLoad
        LD      A, EXPLOSION_FRAMES
        LD      (explosionTimer), A
.noExplosionLoad:

        CALL    ServiceThrust
        CALL    ServiceFire
        CALL    ServiceExplosion
        RET

; ----------------------------------------------------------------------------
; Individual effect handlers
; ----------------------------------------------------------------------------
ServiceThrust:
        LD      A, (thrustTimer)
        OR      A
        RET     Z
        DEC     A
        LD      (thrustTimer), A

        LD      C, BEEPER_PORT
        LD      A, (thrustPhase)
        INC     A
        LD      (thrustPhase), A
        AND     0x03
        LD      E, A
        LD      D, 0
        LD      HL, thrustLoopTable
        ADD     HL, DE
        LD      B, (HL)
.thrustLoop:
        LD      A, 0x10
        OUT     (C), A
        LD      A, 0x00
        OUT     (C), A
        DJNZ    .thrustLoop
        XOR     A
        OUT     (C), A
        RET

ServiceFire:
        LD      A, (fireTimer)
        OR      A
        RET     Z
        DEC     A
        LD      (fireTimer), A

        LD      C, BEEPER_PORT
        LD      A, (fireTimer)
        LD      E, A
        LD      D, 0
        LD      HL, fireLoopTable
        ADD     HL, DE
        LD      B, (HL)
.fireLoop:
        LD      A, 0x10
        OUT     (C), A
        LD      A, 0x00
        OUT     (C), A
        DJNZ    .fireLoop
        XOR     A
        OUT     (C), A
        RET

ServiceExplosion:
        LD      A, (explosionTimer)
        OR      A
        RET     Z
        DEC     A
        LD      (explosionTimer), A

        LD      C, BEEPER_PORT
        LD      A, (explosionTimer)
        LD      E, A
        LD      D, 0
        LD      HL, explosionLoopTable
        ADD     HL, DE
        LD      B, (HL)
.exLoop:
        LD      A, (noiseSeed)
        RLCA
        XOR     NOISE_LFSR_TAP
        LD      (noiseSeed), A
        AND     0x10
        OUT     (C), A
        XOR     0x10
        OUT     (C), A
        DJNZ    .exLoop
        XOR     A
        OUT     (C), A
        RET

