; -----------------------------------------------------------------------------
; ClearScreen
;   Wipes the screen buffer by filling it with zeroes while preserving registers.
;   Inputs:
;     None (constants below define buffer location and size)
;   Clobbers:
;     None (uses stack to save AF, BC, DE, HL)
; -----------------------------------------------------------------------------

SCREEN_START EQU 0x4000        ; adjust to your screen base address
SCREEN_SIZE  EQU 6912          ; example: 6912 bytes for ZX Spectrum-like layout

ClearScreen:
    push af
    push bc
    push de
    push hl

    ld   hl,SCREEN_START       ; HL → start of screen memory
    ld   de,SCREEN_START+1     ; DE → next byte after HL
    ld   bc,SCREEN_SIZE-1      ; BC counts remaining bytes
    xor  a                     ; create zero in A
    ld   (hl),a                ; clear first byte explicitly

    ldir                       ; copy zero from HL to DE, auto-increment, repeat BC+1 times

    pop  hl
    pop  de
    pop  bc
    pop  af
    ret
