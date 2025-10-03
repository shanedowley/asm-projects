; ----------------------------------------------------------------------------
; vectors.asm - Rendering routines for ZX Spectrum Asteroids clone
; ----------------------------------------------------------------------------
; Handles screen clearing, vector drawing, and per-frame rendering of the
; player ship, asteroids, bullets, and HUD overlay. Rendering is deliberately
; simple for the initial sprint: we clear the bitmap each frame, redraw all
; elements as wireframes, and rely on the attribute table being pre-filled to a
; bright white foreground. Future sprints can optimise by retaining dirty
; regions or introducing double buffering.
; ----------------------------------------------------------------------------

        INCLUDE "constants.inc"


HUD_ATTR_SCORE    EQU 0x47
HUD_ATTR_HELP1    EQU 0x45
HUD_ATTR_HELP2    EQU 0x46
HUD_ATTR_HELP3    EQU 0x43

; ----------------------------------------------------------------------------
; Local constants used for ship shape and asteroid geometry
; ----------------------------------------------------------------------------
SHIP_NOSE_LEN       EQU 18
SHIP_WING_LEN       EQU 12
SHIP_TAIL_LEN       EQU 8
SHIP_WING_OFFSET    EQU 85                 ; ≈120° in 0-255 angular space

AST_LARGE_PTR       EQU 0
AST_MEDIUM_PTR      EQU 1
AST_SMALL_PTR       EQU 2

; ----------------------------------------------------------------------------
; Module-scoped workspace
; ----------------------------------------------------------------------------
bitMaskTable:
        DEFB    0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01

shipVertexX:
        DEFB    0, 0, 0, 0               ; nose, left, right, tail
shipVertexY:
        DEFB    0, 0, 0, 0
shipEdgeTable:
        DEFB    0, 1
        DEFB    0, 2
        DEFB    1, 2
        DEFB    1, 3
        DEFB    2, 3
shipEdgeCount      EQU $ - shipEdgeTable

currentCos:
        DEFB    0
currentSin:
        DEFB    0
centerXLow:
        DEFB    0
centerXHigh:
        DEFB    0
centerYLow:
        DEFB    0
centerYHigh:
        DEFB    0
deltaXTemp:
        DEFB    0
deltaYTemp:
        DEFB    0

polyVertexCount:
        DEFB    0
polyVertexX:
        DEFB    0,0,0,0,0,0,0,0,0,0,0,0
polyVertexY:
        DEFB    0,0,0,0,0,0,0,0,0,0,0,0

prevX:
        DEFB    0
prevY:
        DEFB    0
firstX:
        DEFB    0
firstY:
        DEFB    0
segmentCounter:
        DEFB    0

line_dx:
        DEFW    0
line_dy:
        DEFW    0
line_err:
        DEFW    0
line_temp:
        DEFW    0
line_x0:
        DEFB    0
line_y0:
        DEFB    0
line_x1:
        DEFB    0
line_y1:
        DEFB    0
line_sx:
        DEFB    0
line_sy:
        DEFB    0

mulSign:
        DEFB    0
mulTemp:
        DEFB    0

; Temporary storage for rotated coordinates
term1_lo:
        DEFB    0
term1_hi:
        DEFB    0
term2_lo:
        DEFB    0
term2_hi:
        DEFB    0
coordX_temp:
        DEFB    0
coordY_temp:
        DEFB    0

; ----------------------------------------------------------------------------
; Asteroid outline definitions (signed 8-bit vertex coordinates around origin)
; ----------------------------------------------------------------------------
asteroidLargeShape:
        DEFB    12
        DEFB    20, 0,   14, 8,    8, 18,    0, 20
        DEFB   -8, 16,  -14, 10,  -20, 0,  -16, -10
        DEFB   -8, -18,   0, -20,  10, -16,  18, -8

asteroidMediumShape:
        DEFB    10
        DEFB    12, 0,    8, 5,     4, 11,    0, 12
        DEFB   -6, 10,  -10, 6,   -12, 0,   -10, -7
        DEFB   -4, -11,   6, -10,  10, -4

asteroidSmallShape:
        DEFB    8
        DEFB    6, 0,     4, 3,     2, 6,     0, 7
        DEFB   -3, 6,    -5, 3,    -6, 0,    -3, -5

asteroidShapeTable:
        DEFW    asteroidLargeShape
        DEFW    asteroidMediumShape
        DEFW    asteroidSmallShape

; ----------------------------------------------------------------------------
; API entry points
; ----------------------------------------------------------------------------
InitVectors:
        CALL    ClearBitmap

        LD      HL, SCREEN_ATTR
        LD      DE, SCREEN_ATTR + 1
        LD      BC, ATTR_BYTES - 1
        LD      A, 0x07                    ; White ink on black paper
        LD      (HL), A
        LDIR
        CALL    ColorizeHUD
        RET

RenderFrame:
        CALL    ClearBitmap
        CALL    DrawShip
        CALL    DrawAsteroids
        CALL    DrawBullets
        CALL    RenderHUD
        RET

ClearAttributes:
        LD      HL, SCREEN_ATTR
        LD      DE, SCREEN_ATTR + 1
        LD      BC, ATTR_BYTES - 1
        LD      A, 0x07
        LD      (HL), A
        LDIR
        RET

; ----------------------------------------------------------------------------
; Screen utilities
; ----------------------------------------------------------------------------
ClearBitmap:
        LD      HL, SCREEN_BITMAP
        LD      DE, SCREEN_BITMAP + 1
        LD      BC, SCREEN_BYTES - 1
        XOR     A
        LD      (HL), A
        LDIR
        RET

ColorizeHUD:
        LD      HL, SCREEN_ATTR
        LD      B, 32
        LD      A, HUD_ATTR_SCORE
.chRow0:
        LD      (HL), A
        INC     HL
        DJNZ    .chRow0

        LD      B, 32
        LD      A, HUD_ATTR_HELP1
.chRow1:
        LD      (HL), A
        INC     HL
        DJNZ    .chRow1

        LD      B, 32
        LD      A, HUD_ATTR_HELP2
.chRow2:
        LD      (HL), A
        INC     HL
        DJNZ    .chRow2

        LD      B, 32
        LD      A, HUD_ATTR_HELP3
.chRow3:
        LD      (HL), A
        INC     HL
        DJNZ    .chRow3
        RET

PlotPixel:
        ; Input: B = x (0-255), C = y (0-191)
        PUSH    BC
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
        POP     BC

        LD      A, B
        AND     0x07
        LD      E, A
        LD      D, 0
        PUSH    HL
        LD      HL, bitMaskTable
        ADD     HL, DE
        LD      A, (HL)                  ; Bit mask for this pixel
        POP     HL

        LD      E, B
        SRL     E
        SRL     E
        SRL     E
        LD      D, 0
        ADD     HL, DE

        LD      B, A                     ; Preserve mask
        LD      A, (HL)
        OR      B
        LD      (HL), A
        RET

; ----------------------------------------------------------------------------
; Ship rendering
; ----------------------------------------------------------------------------
DrawShip:
        LD      IX, g_shipState
        LD      A, (IX + SHIP_RESPAWN)
        OR      A
        RET     NZ                        ; Hide while respawning

        LD      A, (IX + SHIP_POS_X)
        LD      (centerXLow), A
        LD      A, (IX + SHIP_POS_X + 1)
        LD      (centerXHigh), A
        LD      A, (IX + SHIP_POS_Y)
        LD      (centerYLow), A
        LD      A, (IX + SHIP_POS_Y + 1)
        LD      (centerYHigh), A

        ; Precompute cosine/sine for the ship heading
        LD      C, (IX + SHIP_ANGLE)
        CALL    FetchTrigLocal
        LD      (currentCos), A          ; FetchTrigLocal returns cos in A
        LD      A, L
        LD      (currentSin), A          ; and sin in L

        CALL    ComputeShipVertices
        CALL    StrokeShipEdges
        RET

ComputeShipVertices:
        ; Nose vertex
        LD      A, (currentCos)
        LD      B, A
        LD      A, SHIP_NOSE_LEN
        CALL    MulTrigMagnitude         ; HL = cos * len * 2
        LD      A, (centerXLow)
        LD      E, A
        LD      A, (centerXHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (shipVertexX), A

        LD      A, (currentSin)
        LD      B, A
        LD      A, SHIP_NOSE_LEN
        CALL    MulTrigMagnitude
        LD      A, (centerYLow)
        LD      E, A
        LD      A, (centerYHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (shipVertexY), A

        ; Left wing vertex (angle + offset)
        LD      A, (IX + SHIP_ANGLE)
        ADD     A, SHIP_WING_OFFSET
        LD      C, A
        CALL    FetchTrigLocal
        LD      (currentCos), A
        LD      A, L
        LD      (currentSin), A

        LD      A, (currentCos)
        LD      B, A
        LD      A, SHIP_WING_LEN
        CALL    MulTrigMagnitude
        LD      A, (centerXLow)
        LD      E, A
        LD      A, (centerXHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (shipVertexX + 1), A

        LD      A, (currentSin)
        LD      B, A
        LD      A, SHIP_WING_LEN
        CALL    MulTrigMagnitude
        LD      A, (centerYLow)
        LD      E, A
        LD      A, (centerYHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (shipVertexY + 1), A

        ; Right wing vertex (angle - offset)
        LD      A, (IX + SHIP_ANGLE)
        SUB     SHIP_WING_OFFSET
        LD      C, A
        CALL    FetchTrigLocal
        LD      (currentCos), A
        LD      A, L
        LD      (currentSin), A

        LD      A, (currentCos)
        LD      B, A
        LD      A, SHIP_WING_LEN
        CALL    MulTrigMagnitude
        LD      A, (centerXLow)
        LD      E, A
        LD      A, (centerXHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (shipVertexX + 2), A

        LD      A, (currentSin)
        LD      B, A
        LD      A, SHIP_WING_LEN
        CALL    MulTrigMagnitude
        LD      A, (centerYLow)
        LD      E, A
        LD      A, (centerYHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (shipVertexY + 2), A

        ; Tail vertex (angle + 180°)
        LD      A, (IX + SHIP_ANGLE)
        ADD     A, 128
        LD      C, A
        CALL    FetchTrigLocal
        LD      (currentCos), A
        LD      A, L
        LD      (currentSin), A

        LD      A, (currentCos)
        LD      B, A
        LD      A, SHIP_TAIL_LEN
        CALL    MulTrigMagnitude
        LD      A, (centerXLow)
        LD      E, A
        LD      A, (centerXHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (shipVertexX + 3), A

        LD      A, (currentSin)
        LD      B, A
        LD      A, SHIP_TAIL_LEN
        CALL    MulTrigMagnitude
        LD      A, (centerYLow)
        LD      E, A
        LD      A, (centerYHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (shipVertexY + 3), A
        RET

StrokeShipEdges:
        LD      HL, shipEdgeTable
        LD      B, shipEdgeCount / 2
.edgeLoop:
        PUSH    BC
        LD      A, (HL)
        CALL    LoadShipVertex          ; returns B=x, C=y
        INC     HL
        LD      A, (HL)
        CALL    LoadShipVertexNext      ; returns D=x, E=y
        INC     HL
        CALL    DrawLine
        POP     BC
        DJNZ    .edgeLoop
        RET

LoadShipVertex:
        LD      E, A
        LD      D, 0
        LD      HL, shipVertexX
        ADD     HL, DE
        LD      A, (HL)
        LD      B, A
        LD      HL, shipVertexY
        ADD     HL, DE
        LD      A, (HL)
        LD      C, A
        RET

LoadShipVertexNext:
        LD      E, A
        LD      D, 0
        LD      HL, shipVertexX
        ADD     HL, DE
        LD      A, (HL)
        LD      D, A
        LD      HL, shipVertexY
        ADD     HL, DE
        LD      A, (HL)
        LD      E, A
        RET

; ----------------------------------------------------------------------------
; Asteroid rendering
; ----------------------------------------------------------------------------
DrawAsteroids:
        LD      IY, g_asteroids
        LD      B, MAX_ASTEROIDS
.nextAsteroid:
        LD      A, (IY + AST_ACTIVE)
        OR      A
        JR      Z, .skip
        PUSH    BC
        PUSH    IY
        CALL    DrawSingleAsteroid
        POP     IY
        POP     BC
.skip:
        LD      DE, AST_STRUCT_SIZE
        ADD     IY, DE
        DJNZ    .nextAsteroid
        RET

DrawSingleAsteroid:
        LD      A, (IY + AST_SIZE)
        LD      E, A
        LD      D, 0
        LD      HL, asteroidShapeTable
        ADD     HL, DE
        ADD     HL, DE
        LD      A, (HL)
        LD      E, A
        INC     HL
        LD      A, (HL)
        LD      D, A
        EX      DE, HL                    ; HL = shape pointer

        LD      A, (HL)
        LD      (polyVertexCount), A
        INC     HL

        LD      A, (IY + AST_POS_X)
        LD      (centerXLow), A
        LD      A, (IY + AST_POS_X + 1)
        LD      (centerXHigh), A
        LD      A, (IY + AST_POS_Y)
        LD      (centerYLow), A
        LD      A, (IY + AST_POS_Y + 1)
        LD      (centerYHigh), A

        PUSH    HL                       ; Preserve shape pointer for trig lookup
        LD      C, (IY + AST_ANGLE)
        CALL    FetchTrigLocal
        LD      (currentCos), A
        LD      A, L
        LD      (currentSin), A
        POP     HL                       ; Restore shape pointer
        PUSH    HL                       ; Preserve shape pointer on stack
        CALL    TransformPolygonVertices
        POP     HL
        CALL    StrokePolygon
        RET

TransformPolygonVertices:
        LD      C, 0                      ; vertex index
        LD      A, (polyVertexCount)
        OR      A
        RET     Z
        LD      B, A
.vertexLoop:
        PUSH    BC

        LD      A, (HL)
        LD      (coordX_temp), A
        INC     HL
        LD      A, (HL)
        LD      (coordY_temp), A
        INC     HL

        CALL    ComputeRotatedVertex
        LD      D, B                    ; x result
        LD      E, C                    ; y result

        POP     BC

        LD      A, C
        LD      L, A
        LD      H, 0
        LD      DE, polyVertexX
        ADD     HL, DE
        LD      (HL), D

        LD      A, C
        LD      L, A
        LD      H, 0
        LD      DE, polyVertexY
        ADD     HL, DE
        LD      (HL), E

        INC     C
        DJNZ    .vertexLoop
        RET

ComputeRotatedVertex:
        ; Uses coordX_temp/coordY_temp, currentCos/currentSin, centers.
        ; Returns B=x (pixel), C=y (pixel)

        ; term1 = x * cos
        LD      HL, coordX_temp
        LD      A, (HL)
        LD      HL, currentCos
        LD      B, (HL)
        CALL    MulSigned8
        ADD     HL, HL
        LD      A, L
        LD      (term1_lo), A
        LD      A, H
        LD      (term1_hi), A

        ; term2 = y * sin
        LD      HL, coordY_temp
        LD      A, (HL)
        LD      HL, currentSin
        LD      B, (HL)
        CALL    MulSigned8
        ADD     HL, HL
        LD      A, L
        LD      (term2_lo), A
        LD      A, H
        LD      (term2_hi), A

        ; deltaX = term1 - term2 + centerX
        LD      A, (term1_lo)
        LD      L, A
        LD      A, (term1_hi)
        LD      H, A
        LD      A, (term2_lo)
        LD      E, A
        LD      A, (term2_hi)
        LD      D, A
        XOR     A
        SBC     HL, DE
        LD      A, (centerXLow)
        LD      E, A
        LD      A, (centerXHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (deltaXTemp), A

        ; term1 = x * sin
        LD      HL, coordX_temp
        LD      A, (HL)
        LD      HL, currentSin
        LD      B, (HL)
        CALL    MulSigned8
        ADD     HL, HL
        LD      A, L
        LD      (term1_lo), A
        LD      A, H
        LD      (term1_hi), A

        ; term2 = y * cos
        LD      HL, coordY_temp
        LD      A, (HL)
        LD      HL, currentCos
        LD      B, (HL)
        CALL    MulSigned8
        ADD     HL, HL
        LD      A, L
        LD      (term2_lo), A
        LD      A, H
        LD      (term2_hi), A

        ; deltaY = term1 + term2 + centerY
        LD      A, (term1_lo)
        LD      L, A
        LD      A, (term1_hi)
        LD      H, A
        LD      A, (term2_lo)
        LD      E, A
        LD      A, (term2_hi)
        LD      D, A
        ADD     HL, DE
        LD      A, (centerYLow)
        LD      E, A
        LD      A, (centerYHigh)
        LD      D, A
        ADD     HL, DE
        LD      A, H
        LD      (deltaYTemp), A

        LD      A, (deltaXTemp)
        LD      B, A
        LD      A, (deltaYTemp)
        LD      C, A
        RET

StrokePolygon:
        LD      A, (polyVertexCount)
        OR      A
        RET     Z
        CP      1
        RET     Z

        LD      HL, polyVertexX
        LD      DE, polyVertexY
        LD      A, (polyVertexCount)
        LD      (segmentCounter), A

        LD      A, (HL)
        LD      (firstX), A
        LD      (prevX), A
        LD      A, (DE)
        LD      (firstY), A
        LD      (prevY), A

        INC     HL
        INC     DE
        LD      A, (segmentCounter)
        DEC     A
        LD      (segmentCounter), A

.polyLoop:
        LD      A, (segmentCounter)
        OR      A
        JR      Z, .close

        LD      A, (HL)
        LD      D, A
        LD      A, (DE)
        LD      E, A

        LD      A, (prevX)
        LD      B, A
        LD      A, (prevY)
        LD      C, A
        CALL    DrawLine

        LD      A, D
        LD      (prevX), A
        LD      A, E
        LD      (prevY), A

        INC     HL
        INC     DE
        LD      A, (segmentCounter)
        DEC     A
        LD      (segmentCounter), A
        JR      .polyLoop

.close:
        LD      A, (prevX)
        LD      B, A
        LD      A, (prevY)
        LD      C, A
        LD      A, (firstX)
        LD      D, A
        LD      A, (firstY)
        LD      E, A
        CALL    DrawLine
        RET

; ----------------------------------------------------------------------------
; Bullet rendering
; ----------------------------------------------------------------------------
DrawBullets:
        LD      IY, g_bullets
        LD      B, MAX_BULLETS
.bulletLoop:
        LD      A, (IY + BUL_ACTIVE)
        OR      A
        JR      Z, .next
        PUSH    BC
        LD      B, (IY + BUL_POS_X + 1)
        LD      C, (IY + BUL_POS_Y + 1)
        CALL    PlotPixel
        POP     BC
.next:
        LD      DE, BUL_STRUCT_SIZE
        ADD     IY, DE
        DJNZ    .bulletLoop
        RET

; ----------------------------------------------------------------------------
; Bresenham line drawing
; ----------------------------------------------------------------------------
DrawLine:
        ; Inputs: B=x0, C=y0, D=x1, E=y1
        LD      A, B
        LD      (line_x0), A
        LD      A, C
        LD      (line_y0), A
        LD      A, D
        LD      (line_x1), A
        LD      A, E
        LD      (line_y1), A

        ; Compute dx and step direction for x
        LD      A, D
        SUB     B
        JR      NC, .dxPositive
        NEG
        LD      A, 0xFF
        LD      (line_sx), A
        JR      .dxStore
.dxPositive:
        LD      A, 1
        LD      (line_sx), A
.dxStore:
        LD      L, A
        LD      H, 0
        LD      (line_dx), HL

        ; Compute dy (store as negative) and step for y
        LD      A, E
        SUB     C
        JR      NC, .dyPositive
        NEG
        LD      A, 0xFF
        LD      (line_sy), A
        JR      .dyStore
.dyPositive:
        LD      A, 1
        LD      (line_sy), A
.dyStore:
        LD      L, A
        LD      H, 0
        LD      (line_temp), HL        ; store |dy|
        LD      D, H
        LD      E, L
        LD      HL, 0
        XOR     A                      ; clear carry
        SBC     HL, DE                 ; HL = -|dy|
        LD      (line_dy), HL

        ; err = dx + dy
        LD      HL, (line_dx)
        LD      DE, (line_dy)
        ADD     HL, DE
        LD      (line_err), HL

drawLine_loop:
        LD      A, (line_x0)
        LD      B, A
        LD      A, (line_y0)
        LD      C, A
        CALL    PlotPixel

        LD      A, (line_x1)
        CP      B
        JR      NZ, drawLine_continue
        LD      A, (line_y1)
        CP      C
        RET     Z
drawLine_continue:
        LD      HL, (line_err)
        ADD     HL, HL
        LD      (line_temp), HL

        ; if (e2 >= line_dy)
        LD      HL, (line_temp)
        LD      DE, (line_dy)
        XOR     A
        SBC     HL, DE
        JR      C, drawLine_skipX
        LD      HL, (line_err)
        LD      DE, (line_dy)
        ADD     HL, DE
        LD      (line_err), HL
        LD      A, (line_sx)
        LD      E, A
        LD      A, (line_x0)
        ADD     A, E
        LD      (line_x0), A
drawLine_skipX:
        ; if (e2 <= line_dx)
        LD      HL, (line_temp)
        LD      DE, (line_dx)
        XOR     A
        SBC     HL, DE
        JR      NC, drawLine_skipY
        LD      HL, (line_err)
        LD      DE, (line_dx)
        ADD     HL, DE
        LD      (line_err), HL
        LD      A, (line_sy)
        LD      E, A
        LD      A, (line_y0)
        ADD     A, E
        LD      (line_y0), A
drawLine_skipY:
        JR      drawLine_loop
FetchTrigLocal:
        ; Input: C = angle
        LD      B, 0
        LD      HL, cosTable
        ADD     HL, BC
        LD      A, (HL)                  ; Cosine result
        LD      D, A                     ; Preserve cosine
        LD      HL, sinTable
        ADD     HL, BC
        LD      A, (HL)
        LD      L, A                  ; Sine result returned in L
        LD      A, D                     ; Restore cosine into A
        RET

MulTrigMagnitude:
        ; Multiply signed trig value in B by unsigned magnitude in A.
        ; Returns HL = (trig * magnitude * 2) in 8.8 format.
        PUSH    AF
        PUSH    BC
        LD      C, A
        LD      A, B
        LD      B, C
        CALL    MulSigned8
        ADD     HL, HL
        POP     BC
        POP     AF
        RET

MulSigned8:
        ; Multiply two signed 8-bit numbers.
        ; Inputs: A = multiplicand, B = multiplier.
        ; Output: HL = signed 16-bit product.
        LD      C, 0                      ; Sign flag
        LD      D, A
        BIT     7, D
        JR      Z, .checkMultiplier
        CPL
        INC     A
        LD      D, A
        LD      C, 1

.checkMultiplier:
        LD      E, B
        BIT     7, E
        JR      Z, .doMultiply
        LD      A, E
        CPL
        INC     A
        LD      E, A
        LD      A, C
        XOR     1
        LD      C, A

.doMultiply:
        LD      A, E
        LD      B, A
        LD      E, D
        LD      D, 0
        LD      HL, 0
        LD      A, B
        OR      A
        JR      Z, .applySign

.mulLoop:
        ADD     HL, DE
        DEC     B
        JR      NZ, .mulLoop

.applySign:
        LD      A, C
        OR      A
        RET     Z
        LD      A, L
        CPL
        LD      L, A
        LD      A, H
        CPL
        LD      H, A
        INC     HL
        RET

; ----------------------------------------------------------------------------
