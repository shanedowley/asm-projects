
; ----------------------------------------------------------------------------
; physics.asm - Core game state, physics, and collision management
; ----------------------------------------------------------------------------
;
; This module owns the mutable game state for the Asteroids clone.  It keeps
; track of the player ship, asteroids, and bullets; advances their motion each
; frame; resolves collisions; and updates the scoring / wave progression.  The
; logic is written with readability in mind and each routine documents the
; calling convention it expects so that future maintenance is straightforward.
; ----------------------------------------------------------------------------

        INCLUDE "constants.inc"


FRAME_COUNTER       EQU 0x5C78                ; ROM frame counter used for RNG seed

; -----------------------------------------------------------------------------
; Tunable gameplay constants (fixed point values expressed in 8.8 format)
; -----------------------------------------------------------------------------
SHIP_INIT_X         EQU 128                   ; Ship starts in center of 256x192
SHIP_INIT_Y         EQU 96
SHIP_INIT_X_FP      EQU SHIP_INIT_X * 256
SHIP_INIT_Y_FP      EQU SHIP_INIT_Y * 256
SHIP_INIT_INVULN    EQU 120                   ; Frames of safety after spawn
SHIP_RESPAWN_TIME   EQU 120
SHIP_ROT_RATE       EQU 4                     ; Angle step per frame (≈5.6°)
SHIP_FRICTION_SHIFT EQU 5                     ; Velocity dampening divisor (1/32)
SHIP_THRUST_DELAY   EQU 2                     ; Frames of thrust sound decay
SHIP_FIRE_DELAY     EQU 6                     ; Minimum frames between bullets
SHIP_RADIUS         EQU 10                    ; Used for ship hit radius

BULLET_SPEED_SHIFT  EQU 3                     ; Direction vector << 3 for speed
BULLET_LIFETIME     EQU 32                    ; Frames before bullet despawns

ASTEROID_LARGE      EQU 0
ASTEROID_MEDIUM     EQU 1
ASTEROID_SMALL      EQU 2

SCORE_LARGE         EQU 20
SCORE_MEDIUM        EQU 50
SCORE_SMALL         EQU 100

; -----------------------------------------------------------------------------
; Module-scoped workspace
; -----------------------------------------------------------------------------
currentControls:
        DEFB    0                               ; Latched control bits for frame
thrustDecay:
        DEFB    0                               ; Tail-off frames for thrust SFX

; Scratch bytes used during collision tests
scratchX:
        DEFB    0
scratchY1:
        DEFB    0
scratchY2:
        DEFB    0

; Temporary storage for bullet position during asteroid sweep
bulletPosX:
        DEFB    0
bulletPosY:
        DEFB    0

; Pre-computed asteroid radii and scores (indexed by size enum)
asteroidRadius:
        DEFB    18, 12, 7
asteroidScore:
        DEFW    SCORE_LARGE, SCORE_MEDIUM, SCORE_SMALL
asteroidRadiusSq:
        DEFW    324, 144, 49
asteroidShipRadiusSq:
        DEFW    784, 484, 289

; -----------------------------------------------------------------------------
; ============================================================================
; Memory utilities and random helpers
; ============================================================================
ZeroBlock:
        ; Fill BC bytes starting at HL with zeroes
        XOR     A
.zeroLoop:
        LD      (HL), A
        INC     HL
        DEC     BC
        LD      A, B
        OR      C
        JR      NZ, .zeroLoop
        RET

SeedRandomFromFrame:
        ; Use the ROM frame counter to introduce variability between runs
        LD      HL, (FRAME_COUNTER)
        LD      (g_randSeed), HL
        RET

NextRandom:
        ; 16-bit linear congruential generator (x = 129*x + 1)
        LD      HL, (g_randSeed)
        LD      D, H
        LD      E, L
        ADD     HL, HL                ; x*2
        ADD     HL, HL                ; x*4
        ADD     HL, HL                ; x*8
        ADD     HL, HL                ; x*16
        ADD     HL, HL                ; x*32
        ADD     HL, HL                ; x*64
        ADD     HL, HL                ; x*128
        ADD     HL, DE                ; x*129
        INC     HL                    ; +1
        LD      (g_randSeed), HL
        LD      A, H                  ; High byte offers decent entropy
        RET

RandomAngle:
        CALL    NextRandom
        RET

RandomSmall:
        ; Produce a small signed nibble (-4..+3) for rotation variance
        CALL    NextRandom
        AND     0x07
        SUB     4
        RET

RandomVelocity:
        ; Provide a modest random velocity vector in 8.8 fixed-point format.
        ; Each component is built from a signed range (-16..+15) scaled so that
        ; the ship can comfortably outrun spawned asteroids.
        CALL    NextRandom
        AND     0x1F
        SUB     16
        LD      L, A
        LD      H, 0
        BIT     7, A
        JR      Z, .xShift
        LD      H, 0xFF
.xShift:
        ADD     HL, HL                ; <<1
        ADD     HL, HL                ; <<2
        ADD     HL, HL                ; <<3
        ADD     HL, HL                ; <<4 (convert to 8.8 scale)
        PUSH    HL

        CALL    NextRandom
        AND     0x1F
        SUB     16
        LD      L, A
        LD      H, 0
        BIT     7, A
        JR      Z, .yShift
        LD      H, 0xFF
.yShift:
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        EX      DE, HL                ; DE = velY
        POP     HL                    ; HL = velX
        RET

RandomScreenEdge:
        ; Return a spawn position anchored on a random screen edge.
        ; HL = X (8.8), DE = Y (8.8)
        CALL    NextRandom
        AND     0x03
        LD      B, A                  ; 0:left 1:right 2:top 3:bottom

        CALL    NextRandom
        LD      H, A
        LD      L, 0                  ; Random X pixel (0..255)

        CALL    NextRandom
        LD      D, A
        LD      E, 0                  ; Random Y pixel (0..191)

        LD      A, B
        OR      A
        JR      Z, .edgeLeft
        CP      1
        JR      Z, .edgeRight
        CP      2
        JR      Z, .edgeTop

        ; Bottom edge -> reuse random X, clamp Y to bottom row
        LD      D, SCREEN_HEIGHT - 1
        RET

.edgeLeft:
        LD      HL, 0
        RET

.edgeRight:
        LD      H, SCREEN_WIDTH - 1
        LD      L, 0
        RET

.edgeTop:
        LD      D, 0
        RET

FetchTrig:
        ; Look up cosine and sine for the supplied angle in C
        LD      B, 0
        LD      HL, cosTable
        ADD     HL, BC
        LD      A, (HL)
        LD      D, A
        LD      HL, sinTable
        ADD     HL, BC
        LD      A, (HL)
        LD      E, A
        RET

SignedQuarter:
        ; Convert signed byte in A into a small 8.8 increment (A / 4)
        LD      E, A
        LD      D, 0
        BIT     7, A
        JR      Z, .sqShift
        LD      D, 0xFF
.sqShift:
        SRA     D
        RR      E
        SRA     D
        RR      E
        RET

SignedShiftLeft3:
        ; Convert signed byte in A into an 8.8 value scaled by 8
        LD      L, A
        LD      H, 0
        BIT     7, A
        JR      Z, .sslShift
        LD      H, 0xFF
.sslShift:
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        RET

ShiftRightFriction:
        ; Divide HL by 2^SHIP_FRICTION_SHIFT with sign extension
        LD      B, SHIP_FRICTION_SHIFT
.srfLoop:
        SRA     H
        RR      L
        DJNZ    .srfLoop
        RET

WrapYCoordinate:
        ; Keep an 8.8 Y coordinate within 0..SCREEN_HEIGHT-1 toroidally
        LD      A, H
        BIT     7, A
        JR      Z, .checkUpper
.wrapAdd:
        LD      DE, SCREEN_HEIGHT * 256
        ADD     HL, DE
        LD      A, H
        BIT     7, A
        JR      NZ, .wrapAdd
        JR      .wrapDone
.checkUpper:
        CP      SCREEN_HEIGHT
        JR      C, .wrapDone
.wrapSub:
        LD      DE, SCREEN_HEIGHT * 256
        XOR     A
        SBC     HL, DE
        LD      A, H
        CP      SCREEN_HEIGHT
        JR      NC, .wrapSub
.wrapDone:
        RET

ComputeDistanceSq:
        ; Given integer pixel coordinates:
        ;   B = y1, C = x1, D = x2, E = y2
        ; return HL = squared distance accounting for toroidal wrapping.
        LD      A, B
        LD      (scratchY1), A
        LD      A, E
        LD      (scratchY2), A

        ; --- X delta (wrap around 0..255) ---
        LD      A, C
        SUB     D
        LD      B, A
        BIT     7, B
        JR      Z, .dxAbs
        LD      A, B
        NEG
        LD      B, A
.dxAbs:
        LD      A, B
        CP      128
        JR      C, .dxNoWrap
        CPL
        INC     A
        LD      B, A
.dxNoWrap:
        LD      L, B
        LD      H, 0
        ADD     HL, HL
        LD      DE, squareTable
        ADD     HL, DE
        LD      A, (HL)
        LD      E, A
        INC     HL
        LD      A, (HL)
        LD      D, A
        PUSH    DE                     ; Preserve dx^2 on stack

        ; --- Y delta (wrap around 0..191) ---
        LD      A, (scratchY1)
        LD      C, A
        LD      A, (scratchY2)
        LD      D, A
        LD      A, C
        SUB     D
        LD      B, A
        BIT     7, B
        JR      Z, .dyAbs
        LD      A, B
        NEG
        LD      B, A
.dyAbs:
        LD      A, B
        CP      SCREEN_HEIGHT / 2
        JR      C, .dyNoWrap
        LD      A, SCREEN_HEIGHT
        SUB     B
        LD      B, A
.dyNoWrap:
        LD      L, B
        LD      H, 0
        ADD     HL, HL
        LD      DE, squareTable
        ADD     HL, DE
        LD      A, (HL)
        LD      E, A
        INC     HL
        LD      A, (HL)
        LD      D, A

        POP     HL                     ; HL = dx^2
        ADD     HL, DE                 ; + dy^2
        RET

; ============================================================================
; Game initialisation and per-frame driver
; ============================================================================
InitGameState:
        CALL    SeedRandomFromFrame

        LD      HL, g_shipState
        LD      BC, SHIP_STATE_SIZE
        CALL    ZeroBlock

        LD      HL, g_asteroids
        LD      BC, AST_STRUCT_SIZE * MAX_ASTEROIDS
        CALL    ZeroBlock

        LD      HL, g_bullets
        LD      BC, BUL_STRUCT_SIZE * MAX_BULLETS
        CALL    ZeroBlock

        XOR     A
        LD      (currentControls), A
        LD      (thrustDecay), A

        LD      A, 1
        LD      (g_waveNumber), A

        CALL    ResetShipState
        CALL    SpawnWave
        RET

UpdateGame:
        LD      A, (g_controlState)
        LD      (currentControls), A

        BIT     CTRL_START, A
        JR      Z, .skipReset
        LD      IX, g_shipState
        LD      B, (IX + SHIP_LIVES)
        OR      B
        JR      NZ, .skipReset
        CALL    InitGameState
        RET

.skipReset:
        CALL    UpdateShip
        CALL    UpdateBullets
        CALL    UpdateAsteroids
        CALL    HandleCollisions
        CALL    CheckWaveClear
        RET

; ============================================================================
; Player ship control and physics
; ============================================================================
ResetShipState:
        ; Place ship at centre and clear motion flags
        LD      IX, g_shipState
        LD      HL, SHIP_INIT_X_FP
        LD      (IX + SHIP_POS_X), L
        LD      (IX + SHIP_POS_X + 1), H
        LD      HL, SHIP_INIT_Y_FP
        LD      (IX + SHIP_POS_Y), L
        LD      (IX + SHIP_POS_Y + 1), H

        XOR     A
        LD      (IX + SHIP_VEL_X), A
        LD      (IX + SHIP_VEL_X + 1), A
        LD      (IX + SHIP_VEL_Y), A
        LD      (IX + SHIP_VEL_Y + 1), A
        LD      (IX + SHIP_ANGLE), A
        LD      (IX + SHIP_THRUST), A
        LD      (IX + SHIP_FIRE_TIMER), A
        LD      (IX + SHIP_FLAGS), A

        LD      A, SHIP_INIT_INVULN
        LD      (IX + SHIP_INVULN), A

        LD      A, (IX + SHIP_LIVES)
        OR      A
        JR      NZ, .haveLives
        LD      A, 3
        LD      (IX + SHIP_LIVES), A
.haveLives:
        RET

UpdateShip:
        LD      IX, g_shipState
        LD      A, (IX + SHIP_RESPAWN)
        OR      A
        JR      Z, .active
        DEC     (IX + SHIP_RESPAWN)
        JR      Z, ResetShipState
        JR      .timers

.active:
        CALL    HandleShipRotation
        CALL    HandleShipThrust
        CALL    HandleShipFire
        CALL    HandleShipHyperspace
        CALL    IntegrateShip

.timers:
        CALL    UpdateShipTimers
        RET

HandleShipRotation:
        LD      A, (currentControls)
        BIT     CTRL_LEFT, A
        JR      Z, .checkRight
        LD      A, (IX + SHIP_ANGLE)
        SUB     SHIP_ROT_RATE
        LD      (IX + SHIP_ANGLE), A
        RET

.checkRight:
        BIT     CTRL_RIGHT, A
        JR      Z, .rotDone
        LD      A, (IX + SHIP_ANGLE)
        ADD     A, SHIP_ROT_RATE
        LD      (IX + SHIP_ANGLE), A
.rotDone:
        RET

HandleShipThrust:
        LD      A, (currentControls)
        BIT     CTRL_THRUST, A
        JR      Z, .stopThrust

        LD      (IX + SHIP_THRUST), 1
        LD      C, (IX + SHIP_ANGLE)
        CALL    ApplyThrustVector

        LD      A, (g_soundQueue)
        OR      SOUND_THRUST_MASK
        LD      (g_soundQueue), A

        LD      A, SHIP_THRUST_DELAY
        LD      (thrustDecay), A
        RET

.stopThrust:
        LD      (IX + SHIP_THRUST), 0
        LD      A, (thrustDecay)
        OR      A
        RET     Z
        DEC     A
        LD      (thrustDecay), A
        RET

HandleShipFire:
        LD      A, (IX + SHIP_FIRE_TIMER)
        OR      A
        JR      Z, .ready
        DEC     (IX + SHIP_FIRE_TIMER)
        RET

.ready:
        LD      A, (currentControls)
        BIT     CTRL_FIRE, A
        RET     Z
        CALL    SpawnBullet
        LD      (IX + SHIP_FIRE_TIMER), SHIP_FIRE_DELAY
        RET

HandleShipHyperspace:
        LD      A, (currentControls)
        BIT     CTRL_HYPERSPACE, A
        JR      Z, .release

        LD      A, (IX + SHIP_FLAGS)
        BIT     0, A
        RET     NZ

        CALL    RandomScreenEdge
        LD      (IX + SHIP_POS_X), L
        LD      (IX + SHIP_POS_X + 1), H
        LD      (IX + SHIP_POS_Y), E
        LD      (IX + SHIP_POS_Y + 1), D

        LD      (IX + SHIP_VEL_X), 0
        LD      (IX + SHIP_VEL_X + 1), 0
        LD      (IX + SHIP_VEL_Y), 0
        LD      (IX + SHIP_VEL_Y + 1), 0

        LD      A, (IX + SHIP_FLAGS)
        OR      1
        LD      (IX + SHIP_FLAGS), A

        LD      A, SHIP_INIT_INVULN / 2
        LD      (IX + SHIP_INVULN), A
        RET

.release:
        LD      A, (IX + SHIP_FLAGS)
        AND     0xFE
        LD      (IX + SHIP_FLAGS), A
        RET

IntegrateShip:
        CALL    ApplyShipFriction

        LD      L, (IX + SHIP_POS_X)
        LD      H, (IX + SHIP_POS_X + 1)
        LD      E, (IX + SHIP_VEL_X)
        LD      D, (IX + SHIP_VEL_X + 1)
        ADD     HL, DE
        LD      (IX + SHIP_POS_X), L
        LD      (IX + SHIP_POS_X + 1), H

        LD      L, (IX + SHIP_POS_Y)
        LD      H, (IX + SHIP_POS_Y + 1)
        LD      E, (IX + SHIP_VEL_Y)
        LD      D, (IX + SHIP_VEL_Y + 1)
        ADD     HL, DE
        CALL    WrapYCoordinate
        LD      (IX + SHIP_POS_Y), L
        LD      (IX + SHIP_POS_Y + 1), H
        RET

ApplyShipFriction:
        LD      L, (IX + SHIP_VEL_X)
        LD      H, (IX + SHIP_VEL_X + 1)
        PUSH    HL
        CALL    ShiftRightFriction
        LD      B, H
        LD      C, L
        POP     HL
        XOR     A
        SBC     HL, BC
        LD      (IX + SHIP_VEL_X), L
        LD      (IX + SHIP_VEL_X + 1), H

        LD      L, (IX + SHIP_VEL_Y)
        LD      H, (IX + SHIP_VEL_Y + 1)
        PUSH    HL
        CALL    ShiftRightFriction
        LD      B, H
        LD      C, L
        POP     HL
        XOR     A
        SBC     HL, BC
        LD      (IX + SHIP_VEL_Y), L
        LD      (IX + SHIP_VEL_Y + 1), H
        RET

UpdateShipTimers:
        LD      A, (IX + SHIP_INVULN)
        OR      A
        JR      Z, .noInv
        DEC     (IX + SHIP_INVULN)
.noInv:
        RET

ApplyThrustVector:
        LD      C, (IX + SHIP_ANGLE)
        CALL    FetchTrig               ; D = cos, E = sin

        LD      L, (IX + SHIP_VEL_X)
        LD      H, (IX + SHIP_VEL_X + 1)
        LD      A, D
        CALL    SignedQuarter
        ADD     HL, DE
        LD      (IX + SHIP_VEL_X), L
        LD      (IX + SHIP_VEL_X + 1), H

        LD      L, (IX + SHIP_VEL_Y)
        LD      H, (IX + SHIP_VEL_Y + 1)
        LD      A, E
        CALL    SignedQuarter
        ADD     HL, DE
        LD      (IX + SHIP_VEL_Y), L
        LD      (IX + SHIP_VEL_Y + 1), H
        RET

; ============================================================================
; Bullet management
; ============================================================================
SpawnBullet:
        LD      IY, g_bullets
        LD      B, MAX_BULLETS
.findSlot:
        LD      A, (IY + BUL_ACTIVE)
        OR      A
        JR      Z, .useSlot
        LD      DE, BUL_STRUCT_SIZE
        ADD     IY, DE
        DJNZ    .findSlot
        RET                             ; All slots busy

.useSlot:
        LD      (IY + BUL_ACTIVE), 1
        LD      (IY + BUL_TTL), BULLET_LIFETIME

        LD      A, (IX + SHIP_POS_X)
        LD      (IY + BUL_POS_X), A
        LD      A, (IX + SHIP_POS_X + 1)
        LD      (IY + BUL_POS_X + 1), A
        LD      A, (IX + SHIP_POS_Y)
        LD      (IY + BUL_POS_Y), A
        LD      A, (IX + SHIP_POS_Y + 1)
        LD      (IY + BUL_POS_Y + 1), A

        LD      C, (IX + SHIP_ANGLE)
        CALL    FetchTrig

        LD      A, D
        CALL    SignedShiftLeft3
        LD      B, H
        LD      C, L
        LD      L, (IX + SHIP_VEL_X)
        LD      H, (IX + SHIP_VEL_X + 1)
        ADD     HL, BC
        LD      (IY + BUL_VEL_X), L
        LD      (IY + BUL_VEL_X + 1), H

        LD      A, E
        CALL    SignedShiftLeft3
        LD      B, H
        LD      C, L
        LD      L, (IX + SHIP_VEL_Y)
        LD      H, (IX + SHIP_VEL_Y + 1)
        ADD     HL, BC
        LD      (IY + BUL_VEL_Y), L
        LD      (IY + BUL_VEL_Y + 1), H

        LD      A, (g_soundQueue)
        OR      SOUND_FIRE_MASK
        LD      (g_soundQueue), A
        RET

UpdateBullets:
        LD      IY, g_bullets
        LD      B, MAX_BULLETS
.bLoop:
        LD      A, (IY + BUL_ACTIVE)
        OR      A
        JR      Z, .nextBulletUpdate

        LD      A, (IY + BUL_TTL)
        DEC     A
        LD      (IY + BUL_TTL), A
        JP      Z, .deactivate

        LD      L, (IY + BUL_POS_X)
        LD      H, (IY + BUL_POS_X + 1)
        LD      E, (IY + BUL_VEL_X)
        LD      D, (IY + BUL_VEL_X + 1)
        ADD     HL, DE
        LD      (IY + BUL_POS_X), L
        LD      (IY + BUL_POS_X + 1), H

        LD      L, (IY + BUL_POS_Y)
        LD      H, (IY + BUL_POS_Y + 1)
        LD      E, (IY + BUL_VEL_Y)
        LD      D, (IY + BUL_VEL_Y + 1)
        ADD     HL, DE
        CALL    WrapYCoordinate
        LD      (IY + BUL_POS_Y), L
        LD      (IY + BUL_POS_Y + 1), H
        JR      .nextBulletUpdate

.deactivate:
        LD      (IY + BUL_ACTIVE), 0

.nextBulletUpdate:
        LD      DE, BUL_STRUCT_SIZE
        ADD     IY, DE
        DJNZ    .bLoop
        RET

; ============================================================================
; Asteroid management
; ============================================================================
UpdateAsteroids:
        LD      IY, g_asteroids
        LD      B, MAX_ASTEROIDS
.astLoop:
        LD      A, (IY + AST_ACTIVE)
        OR      A
        JR      Z, .nextAst

        LD      A, (IY + AST_ANGLE)
        LD      C, (IY + AST_ROT)
        ADD     A, C
        LD      (IY + AST_ANGLE), A

        LD      L, (IY + AST_POS_X)
        LD      H, (IY + AST_POS_X + 1)
        LD      E, (IY + AST_VEL_X)
        LD      D, (IY + AST_VEL_X + 1)
        ADD     HL, DE
        LD      (IY + AST_POS_X), L
        LD      (IY + AST_POS_X + 1), H

        LD      L, (IY + AST_POS_Y)
        LD      H, (IY + AST_POS_Y + 1)
        LD      E, (IY + AST_VEL_Y)
        LD      D, (IY + AST_VEL_Y + 1)
        ADD     HL, DE
        CALL    WrapYCoordinate
        LD      (IY + AST_POS_Y), L
        LD      (IY + AST_POS_Y + 1), H

.nextAst:
        LD      DE, AST_STRUCT_SIZE
        ADD     IY, DE
        DJNZ    .astLoop
        RET

SpawnWave:
        ; Clear asteroid pool then spawn a new batch of large rocks
        LD      HL, g_asteroids
        LD      BC, AST_STRUCT_SIZE * MAX_ASTEROIDS
        CALL    ZeroBlock

        LD      A, (g_waveNumber)
        ADD     A, 3
        LD      B, A
        CP      MAX_ASTEROIDS
        JR      C, .countOk
        LD      B, MAX_ASTEROIDS
.countOk:
        LD      C, B

.spawnLoop:
        CALL    CreateAsteroid
        DEC     C
        JR      NZ, .spawnLoop
        RET

CreateAsteroid:
        CALL    FindFreeAsteroidSlot
        RET     C

        LD      (IY + AST_ACTIVE), 1
        LD      (IY + AST_SIZE), ASTEROID_LARGE

        CALL    RandomAngle
        LD      (IY + AST_ANGLE), A

        CALL    RandomSmall
        LD      (IY + AST_ROT), A

        CALL    RandomScreenEdge
        LD      (IY + AST_POS_X), L
        LD      (IY + AST_POS_X + 1), H
        LD      (IY + AST_POS_Y), E
        LD      (IY + AST_POS_Y + 1), D

        CALL    RandomVelocity
        LD      (IY + AST_VEL_X), L
        LD      (IY + AST_VEL_X + 1), H
        LD      (IY + AST_VEL_Y), E
        LD      (IY + AST_VEL_Y + 1), D
        RET

FindFreeAsteroidSlot:
        LD      IY, g_asteroids
        LD      B, MAX_ASTEROIDS
.findLoop:
        LD      A, (IY + AST_ACTIVE)
        OR      A
        RET     Z
        LD      DE, AST_STRUCT_SIZE
        ADD     IY, DE
        DJNZ    .findLoop
        SCF
        RET

; ============================================================================
; Collision detection and resolution
; ============================================================================
HandleCollisions:
        CALL    BulletAsteroidCollisions
        CALL    ShipAsteroidCollisions
        RET

BulletAsteroidCollisions:
        LD      IX, g_bullets
        LD      B, MAX_BULLETS
.bulletSweep:
        LD      A, (IX + BUL_ACTIVE)
        OR      A
        JR      Z, .collisionNextBullet

        LD      A, (IX + BUL_POS_X + 1)
        LD      (bulletPosX), A
        LD      A, (IX + BUL_POS_Y + 1)
        LD      (bulletPosY), A

        LD      IY, g_asteroids
        LD      C, MAX_ASTEROIDS
.astCheck:
        PUSH    BC
        LD      A, (IY + AST_ACTIVE)
        OR      A
        JR      Z, .skipAstPop

        LD      A, (bulletPosX)
        LD      C, A
        LD      A, (bulletPosY)
        LD      B, A
        LD      D, (IY + AST_POS_X + 1)
        LD      E, (IY + AST_POS_Y + 1)
        CALL    ComputeDistanceSq
        PUSH    HL                     ; dist^2

        LD      A, (IY + AST_SIZE)
        LD      L, A
        LD      H, 0
        ADD     HL, HL
        LD      DE, asteroidRadiusSq
        ADD     HL, DE
        LD      A, (HL)
        LD      C, A
        INC     HL
        LD      A, (HL)
        LD      B, A
        LD      L, C
        LD      H, B                   ; HL = radius^2

        POP     DE                     ; dist^2
        XOR     A
        SBC     HL, DE                 ; radius^2 - dist^2
        JR      C, .skipAstPop

        ; --- Collision detected ---
        LD      (IX + BUL_ACTIVE), 0
        LD      A, (g_soundQueue)
        OR      SOUND_EXPLODE_MASK
        LD      (g_soundQueue), A
        CALL    AddScoreForSize
        CALL    SplitAsteroid
        POP     BC                    ; Restore loop counter
        RET

.skipAstPop:
        POP     BC
.skipAst:
        LD      DE, AST_STRUCT_SIZE
        ADD     IY, DE
        DEC     C
        JR      NZ, .astCheck

.collisionNextBullet:
        LD      DE, BUL_STRUCT_SIZE
        ADD     IX, DE
        DJNZ    .bulletSweep
        RET

ShipAsteroidCollisions:
        LD      IX, g_shipState
        LD      A, (IX + SHIP_RESPAWN)
        OR      A
        RET     NZ
        LD      A, (IX + SHIP_INVULN)
        OR      A
        RET     NZ

        LD      IY, g_asteroids
        LD      B, MAX_ASTEROIDS
.shipLoop:
        LD      A, (IY + AST_ACTIVE)
        OR      A
        JR      Z, .nextShip
        PUSH    BC
        CALL    TestShipVsAsteroid
        POP     BC
        JR      C, .nextShip
        CALL    KillPlayerShip
        RET

.nextShip:
        LD      DE, AST_STRUCT_SIZE
        ADD     IY, DE
        DJNZ    .shipLoop
        RET

TestShipVsAsteroid:
        LD      C, (IX + SHIP_POS_X + 1)
        LD      B, (IX + SHIP_POS_Y + 1)
        LD      D, (IY + AST_POS_X + 1)
        LD      E, (IY + AST_POS_Y + 1)
        CALL    ComputeDistanceSq
        PUSH    HL

        LD      A, (IY + AST_SIZE)
        LD      L, A
        LD      H, 0
        ADD     HL, HL
        LD      DE, asteroidShipRadiusSq
        ADD     HL, DE
        LD      A, (HL)
        LD      C, A
        INC     HL
        LD      A, (HL)
        LD      B, A
        LD      L, C
        LD      H, B

        POP     DE
        XOR     A
        SBC     HL, DE                 ; radius^2 - dist^2
        RET                             ; Carry=1 → no collision, Carry=0 → hit

KillPlayerShip:
        LD      A, (IX + SHIP_LIVES)
        OR      A
        JR      Z, .outOfLives
        DEC     A
        LD      (IX + SHIP_LIVES), A
.outOfLives:
        LD      (IX + SHIP_RESPAWN), SHIP_RESPAWN_TIME
        LD      (IX + SHIP_INVULN), SHIP_INIT_INVULN
        LD      (IX + SHIP_VEL_X), 0
        LD      (IX + SHIP_VEL_X + 1), 0
        LD      (IX + SHIP_VEL_Y), 0
        LD      (IX + SHIP_VEL_Y + 1), 0
        LD      A, (g_soundQueue)
        OR      SOUND_EXPLODE_MASK
        LD      (g_soundQueue), A
        RET

AddScoreForSize:
        LD      IX, g_shipState
        LD      A, (IY + AST_SIZE)
        LD      L, A
        LD      H, 0
        ADD     HL, HL
        LD      DE, asteroidScore
        ADD     HL, DE
        LD      A, (HL)
        LD      C, A
        INC     HL
        LD      A, (HL)
        LD      B, A
        CALL    IncrementScore24       ; Adds BC to 24-bit score in ship state
        RET

IncrementScore24:
        LD      A, (IX + SHIP_SCORE_L)
        ADD     A, C
        LD      (IX + SHIP_SCORE_L), A
        LD      A, (IX + SHIP_SCORE_M)
        ADC     A, B
        LD      (IX + SHIP_SCORE_M), A
        LD      A, (IX + SHIP_SCORE_H)
        ADC     A, 0
        LD      (IX + SHIP_SCORE_H), A
        RET

SplitAsteroid:
        LD      A, (IY + AST_SIZE)
        LD      (IY + AST_ACTIVE), 0
        CP      ASTEROID_SMALL
        RET     Z

        INC     A                           ; Child size (medium or small)
        LD      C, A

        LD      L, (IY + AST_POS_X)
        LD      H, (IY + AST_POS_X + 1)
        LD      E, (IY + AST_POS_Y)
        LD      D, (IY + AST_POS_Y + 1)

        PUSH    HL
        PUSH    DE
        CALL    CreateChildAsteroid
        POP     DE
        POP     HL
        CALL    CreateChildAsteroid
        RET

CreateChildAsteroid:
        PUSH    BC
        PUSH    HL
        PUSH    DE
        CALL    FindFreeAsteroidSlot
        JR      C, .noSlot
        POP     DE
        POP     HL
        POP     BC
        LD      (IY + AST_ACTIVE), 1
        LD      (IY + AST_SIZE), C
        LD      (IY + AST_POS_X), L
        LD      (IY + AST_POS_X + 1), H
        LD      (IY + AST_POS_Y), E
        LD      (IY + AST_POS_Y + 1), D
        CALL    RandomAngle
        LD      (IY + AST_ANGLE), A
        CALL    RandomSmall
        LD      (IY + AST_ROT), A
        CALL    RandomVelocity
        LD      (IY + AST_VEL_X), L
        LD      (IY + AST_VEL_X + 1), H
        LD      (IY + AST_VEL_Y), E
        LD      (IY + AST_VEL_Y + 1), D
        RET

.noSlot:
        POP     DE
        POP     HL
        POP     BC
        RET

; ============================================================================
; Wave progression
; ============================================================================
CheckWaveClear:
        LD      IY, g_asteroids
        LD      B, MAX_ASTEROIDS
.checkLoop:
        LD      A, (IY + AST_ACTIVE)
        OR      A
        JR      NZ, .stillActive
        LD      DE, AST_STRUCT_SIZE
        ADD     IY, DE
        DJNZ    .checkLoop

        LD      A, (g_waveNumber)
        INC     A
        LD      (g_waveNumber), A
        CALL    SpawnWave
.stillActive:
        RET
