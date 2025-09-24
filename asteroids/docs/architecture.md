# ZX Spectrum Asteroids Clone Architecture

## Target Platform
- ZX Spectrum 48K running at 3.5 MHz
- Display: 256×192 pixels, attribute-based colour at 8×8 character cells
- Audio: 1-bit beeper
- Input: Keyboard (classic Asteroids controls: rotate left/right, thrust, fire, hyperspace)

## Toolchain and Build
- Assembler: `pasmo`
- Binary layout: assembled to 48K TAP image with program start at 0x8000
- Build process: single pass assembly combining code modules into `asteroids.tap`

## Memory Layout (48K)
```
0x8000-0x87FF  Game core code (initialization, main loop)
0x8800-0x8FFF  Rendering routines and sprite tables
0x9000-0x97FF  Physics & game object manager
0x9800-0x9FFF  Input & audio routines
0xA000-0xA7FF  Game state tables (ship, asteroids, bullets, HUD)
0xA800-0xB7FF  Back buffer workspace (vector plot buffer, attribute staging)
0xB800-0xBFFF  Sound effect waveforms / envelopes
0xC000-0xDFFF  Scratch RAM (stack, temporary buffers)
0xE000-0xFFFF  Reserved for ROM calls / system use (not touched)
```
(Exact section addresses will be fine-tuned as code stabilizes.)

## Game Loop Overview
1. **Initialization**: Clear display, seed randomizer, create initial asteroid field, reset player ship.
2. **Main Loop** (60 FPS target):
   - Poll keyboard and update control flags
   - Update physics for ship, asteroids, bullets, UFO (future enhancement)
   - Handle collisions (bullet↔asteroid, ship↔asteroid)
   - Update score, lives, level progression
   - Render frame:
     - Clear staging buffer
     - Draw vectors for ship, asteroids, bullets, HUD text
     - Convert vector buffer to pixel/attribute data, copy to screen
   - Generate queued sound effects (fire, thrust, explosion)
   - Wait for next frame (synchronize with 50Hz vertical blank)

## Rendering Strategy
- Represent game objects as vector outlines stored as vertex lists.
- Plot into an off-screen line buffer (to avoid flicker) using Bresenham line routine.
- After drawing all vectors, blit buffer into Spectrum bitmap memory (`0x4000-0x57FF`) and set attributes (`0x5800-0x5AFF`).
- HUD uses precomputed font glyphs drawn directly into the attribute layer for readability.

## Game Objects
- **Player Ship**: Position (x,y), velocity, rotation (0..255 for full circle), thrust flag, hyperspace cooldown, lives.
- **Asteroids**: Array of structs containing position, velocity, rotation speed, size (large/medium/small), shape pointer, active flag.
- **Bullets**: Fixed ring buffer (max 4 active). Each entry: position, velocity, lifespan counter.
- **Fragments**: Optional debris for explosion effect (limited lifetime vector sprites).

## Physics Model
- Use fixed-point 8.8 format for positions/velocities to balance precision & speed.
- Wrap positions at screen edges (toroidal space).
- Ship thrust adds acceleration along heading; rotation adjusts heading by ±4 degrees per frame.
- Asteroid split rules: large → 2 medium, medium → 2 small, small → destroyed.

## Collision Detection
- Bounding circle checks using squared distance to avoid `sqrt`.
- Bullet vs asteroid and ship vs asteroid handled each frame.

## Input Mapping
- `O`: Rotate left
- `P`: Rotate right
- `Q`: Thrust
- `M`: Fire
- `SPACE`: Hyperspace (random reposition)
- `1`: Start game / reset

## Audio Design
- Use 1-bit beeper routines timed via CPU loops.
- Sound effects encoded as envelopes:
  - Thrust: continuous buzzing while key held
  - Fire: short pulse with decay
  - Explosion: noise via rapid toggling with varying periods

## File Structure
```
src/
  asteroids.asm        ; main entry, system setup, game loop
  vectors.asm          ; vector shape definitions and drawing routines
  physics.asm          ; movement, collision, spawning logic
  input.asm            ; keyboard scanning and control state
  sound.asm            ; beeper effects manager
  hud.asm              ; scoring, lives, UI text rendering
  data.asm             ; persistent tables, random seeds, fonts
assets/
  font.bin             ; optional custom font data (generated)
docs/
  architecture.md
```

## Testing & Debug Strategy
- Manual playtesting in Fuse or Speccy emulators.
- Instrumented `DEBUG` flag to display diagnostic HUD data (FPS, object counts).
- Keep routines modular for ease of single-step debugging in emulator.
