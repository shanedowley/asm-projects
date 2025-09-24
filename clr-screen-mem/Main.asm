ENTRY_POINT     EQU 0x8000      ; adjust to actual load/entry address

                org ENTRY_POINT

Start:          call ClearScreen
                jr Start

                include "ClearScreen.asm"
