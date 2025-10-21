// hello.s — macOS ARM64 "Hello, World!" via main()

        .global _main        // Export the entry point symbol
        .extern _puts        // Import puts() from libSystem

        .text
_main:
        // Prepare argument: pointer to "Hello, ARM64 World!"
        adrp    x0, msg@PAGE       // Load page address of msg
        add     x0, x0, msg@PAGEOFF // Add offset within page
        bl      _puts              // Call puts(msg)

        // Return 0 (exit code)
        mov     x0, #0
        ret

        .data
msg:
        .asciz  "Hello, ARM64 World!"
