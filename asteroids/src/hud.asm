; ----------------------------------------------------------------------------
; hud.asm - Heads-up display for ZX Spectrum Asteroids clone
; ----------------------------------------------------------------------------
; Renders textual information (score, lives, wave) using an 8x8 bitmap font.
; The HUD occupies the top character row; the rest of the screen is reserved
; for gameplay. Values are converted to decimal and blitted as glyphs each
; frame after the bitmap has been cleared.
; ----------------------------------------------------------------------------

        INCLUDE "constants.inc"


; ----------------------------------------------------------------------------
; Module-scoped storage
; ----------------------------------------------------------------------------
hudCharX:       DEFB    0
hudPixelY:      DEFB    0
rowIndex:       DEFB    0
glyphPointer:   DEFW    0
glyphIdTemp:    DEFB    0
glyphRowByte:   DEFB    0

scoreTemp:      DEFB    0, 0, 0
scoreDigits:    DEFB    0, 0, 0, 0, 0, 0

scratch0:       DEFB    0
scratch1:       DEFB    0

numberDigits:   DEFB    0, 0             ; Generic two-digit buffer (tens, ones)

scorePlaceTable:
        DEFB    0xA0, 0x86, 0x01         ; 100000
        DEFB    0x10, 0x27, 0x00         ; 10000
        DEFB    0xE8, 0x03, 0x00         ; 1000
        DEFB    0x64, 0x00, 0x00         ; 100
        DEFB    0x0A, 0x00, 0x00         ; 10
        DEFB    0x01, 0x00, 0x00         ; 1

; Label strings (glyph IDs terminated with 0xFF)
hudLabelScore:
        DEFB    HUD_CHAR_S, HUD_CHAR_C, HUD_CHAR_O, HUD_CHAR_R, HUD_CHAR_E, 0xFF
hudLabelLives:
        DEFB    HUD_CHAR_L, HUD_CHAR_I, HUD_CHAR_V, HUD_CHAR_E, HUD_CHAR_S, 0xFF
hudLabelWave:
        DEFB    HUD_CHAR_W, HUD_CHAR_A, HUD_CHAR_V, HUD_CHAR_E, 0xFF

hudHelpControls1:
        DEFB    HUD_CHAR_O, HUD_CHAR_EQUALS, HUD_CHAR_L, HUD_CHAR_E, HUD_CHAR_F, HUD_CHAR_T, HUD_CHAR_BLANK, HUD_CHAR_BLANK, HUD_CHAR_P, HUD_CHAR_EQUALS, HUD_CHAR_R, HUD_CHAR_I, HUD_CHAR_G, HUD_CHAR_H, HUD_CHAR_T, 0xFF
hudHelpControls2:
        DEFB    HUD_CHAR_Q, HUD_CHAR_EQUALS, HUD_CHAR_T, HUD_CHAR_H, HUD_CHAR_R, HUD_CHAR_U, HUD_CHAR_S, HUD_CHAR_T, HUD_CHAR_BLANK, HUD_CHAR_M, HUD_CHAR_EQUALS, HUD_CHAR_F, HUD_CHAR_I, HUD_CHAR_R, HUD_CHAR_E, 0xFF
hudHelpControls3:
        DEFB    HUD_CHAR_S, HUD_CHAR_P, HUD_CHAR_A, HUD_CHAR_C, HUD_CHAR_E, HUD_CHAR_EQUALS, HUD_CHAR_W, HUD_CHAR_A, HUD_CHAR_R, HUD_CHAR_P, 0xFF

; ----------------------------------------------------------------------------
InitHUD:
        RET

RenderHUD:
        CALL    ConvertScoreToDigits
        CALL    DrawScoreSection
        CALL    DrawLivesSection
        CALL    DrawWaveSection
        CALL    DrawHelpOverlay
        RET

; ----------------------------------------------------------------------------
; Rendering helpers
; ----------------------------------------------------------------------------
DrawScoreSection:
        LD      HL, hudLabelScore
        LD      B, 0                       ; Char column
        LD      C, 0
        CALL    DrawString

        LD      B, 6
        LD      C, 0
        LD      HL, scoreDigits
        LD      D, 6
.drawLoop:
        LD      A, (HL)
        CALL    DrawGlyph
        INC     HL
        INC     B
        DEC     D
        JR      NZ, .drawLoop
        RET

DrawLivesSection:
        LD      HL, hudLabelLives
        LD      B, 14
        LD      C, 0
        CALL    DrawString

        LD      IX, g_shipState
        LD      A, (IX + SHIP_LIVES)
        CALL    ConvertByteToTwoDigits

        LD      B, 20
        LD      C, 0
        LD      HL, numberDigits
        LD      D, 2
.livesLoop:
        LD      A, (HL)
        CALL    DrawGlyph
        INC     HL
        INC     B
        DEC     D
        JR      NZ, .livesLoop
        RET

DrawWaveSection:
        LD      HL, hudLabelWave
        LD      B, 24
        LD      C, 0
        CALL    DrawString

        LD      A, (g_waveNumber)
        CALL    ConvertByteToTwoDigits

        LD      B, 29
        LD      C, 0
        LD      HL, numberDigits
        LD      D, 2
.waveLoop:
        LD      A, (HL)
        CALL    DrawGlyph
        INC     HL
        INC     B
        DEC     D
        JR      NZ, .waveLoop
        RET

DrawHelpOverlay:
        LD      HL, hudHelpControls1
        LD      B, 0
        LD      C, 1
        CALL    DrawString

        LD      HL, hudHelpControls2
        LD      B, 0
        LD      C, 2
        CALL    DrawString

        LD      HL, hudHelpControls3
        LD      B, 0
        LD      C, 3
        CALL    DrawString
        RET

; ----------------------------------------------------------------------------
; Text drawing routines
; ----------------------------------------------------------------------------
DrawString:
        ; HL -> glyph ID sequence (terminated by 0xFF)
        ; B = starting character column, C = character row
.nextChar:
        LD      A, (HL)
        CP      0xFF
        RET     Z
        PUSH    HL
        PUSH    BC
        CALL    DrawGlyph
        POP     BC
        POP     HL
        INC     HL
        INC     B
        JR      .nextChar

DrawGlyph:
        ; Inputs: A=glyph ID, B=character column, C=character row
        PUSH    AF
        PUSH    BC
        LD      (glyphIdTemp), A
        LD      A, B
        LD      (hudCharX), A
        LD      A, C
        SLA     A
        SLA     A
        SLA     A
        LD      (hudPixelY), A
        XOR     A
        LD      (rowIndex), A

        LD      A, (glyphIdTemp)
        LD      L, A
        LD      H, 0
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        LD      DE, hudFont
        ADD     HL, DE
        LD      (glyphPointer), HL

        LD      B, 8
.glyphRowLoop:
        LD      HL, (glyphPointer)
        LD      A, (HL)
        INC     HL
        LD      (glyphPointer), HL
        LD      (glyphRowByte), A

        LD      A, (rowIndex)
        LD      E, A
        LD      A, (hudPixelY)
        ADD     A, E
        LD      C, A

        LD      L, C
        LD      H, 0
        LD      DE, yAddrTableLo
        ADD     HL, DE
        LD      A, (HL)
        LD      E, A
        LD      L, C
        LD      H, 0
        LD      DE, yAddrTableHi
        ADD     HL, DE
        LD      A, (HL)
        LD      D, A
        LD      H, D
        LD      L, E

        LD      A, (hudCharX)
        LD      E, A
        LD      D, 0
        ADD     HL, DE
        LD      A, (glyphRowByte)
        LD      (HL), A

        LD      A, (rowIndex)
        INC     A
        LD      (rowIndex), A
        DJNZ    .glyphRowLoop

        POP     BC
        POP     AF
        RET

; ----------------------------------------------------------------------------
; Numeric conversion helpers
; ----------------------------------------------------------------------------
ConvertScoreToDigits:
        LD      IX, g_shipState
        LD      A, (IX + SHIP_SCORE_L)
        LD      (scoreTemp), A
        LD      A, (IX + SHIP_SCORE_M)
        LD      (scoreTemp + 1), A
        LD      A, (IX + SHIP_SCORE_H)
        LD      (scoreTemp + 2), A

        LD      IX, scorePlaceTable
        LD      B, 6                       ; digits
        LD      C, 0                       ; index
.digitLoop:
        LD      D, 0                       ; digit accumulator
.subLoop:
        LD      A, (scoreTemp)
        LD      L, (IX + 0)
        SUB     L
        LD      (scratch0), A
        LD      A, (scoreTemp + 1)
        LD      L, (IX + 1)
        SBC     A, L
        LD      (scratch1), A
        LD      A, (scoreTemp + 2)
        LD      L, (IX + 2)
        SBC     A, L
        JR      C, .storeDigit
        LD      (scoreTemp + 2), A
        LD      A, (scratch0)
        LD      (scoreTemp), A
        LD      A, (scratch1)
        LD      (scoreTemp + 1), A
        INC     D
        JR      .subLoop

.storeDigit:
        LD      A, D
        ADD     A, HUD_DIGIT_0
        LD      HL, scoreDigits
        LD      E, C
        LD      D, 0
        ADD     HL, DE
        LD      (HL), A
        INC     IX
        INC     IX
        INC     IX
        INC     C
        DJNZ    .digitLoop
        RET

ConvertByteToTwoDigits:
        ; Input A=0..255, output glyph IDs in numberDigits[0..1]
        LD      B, 0
.tenLoop:
        CP      10
        JR      C, .ones
        SUB     10
        INC     B
        JR      .tenLoop
.ones:
        ADD     A, HUD_DIGIT_0
        LD      (numberDigits + 1), A
        LD      A, B
        ADD     A, HUD_DIGIT_0
        LD      (numberDigits), A
        RET

