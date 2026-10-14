// Native ARM64 bridge from the Apple ABI into a prelinked GOAL function.
// Arguments: x0-x2 GOAL arguments, x3 function, x4 symbol-table GOAL offset,
// x5 writable GOAL base (x22), x6 signed-code base (x27).

.section __TEXT,__text,regular,pure_instructions
.p2align 4
.globl _og_jak1_call_goal_arm64
_og_jak1_call_goal_arm64:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x20, x21, [sp, #-16]!
    stp x22, x27, [sp, #-16]!
    sub sp, sp, #128
    stp q8, q9, [sp]
    stp q10, q11, [sp, #32]
    stp q12, q13, [sp, #64]
    stp q14, q15, [sp, #96]

    mov x20, x4
    mov x21, x4
    mov x22, x5
    mov x27, x6
    blr x3

    ldp q8, q9, [sp]
    ldp q10, q11, [sp, #32]
    ldp q12, q13, [sp, #64]
    ldp q14, q15, [sp, #96]
    add sp, sp, #128
    ldp x22, x27, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// Call a GOAL function with all eight argument registers from Mips2C.
.globl _call_goal8_asm_arm64
_call_goal8_asm_arm64:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x20, x21, [sp, #-16]!
    stp x22, x27, [sp, #-16]!
    sub sp, sp, #128
    stp q8, q9, [sp]
    stp q10, q11, [sp, #32]
    stp q12, q13, [sp, #64]
    stp q14, q15, [sp, #96]
    mov x20, x3
    mov x21, x4
    mov x22, x5
    mov x27, x6
    mov x8, x0
    ldr x0, [x1]
    ldr x2, [x1, #16]
    ldr x3, [x1, #24]
    ldr x4, [x1, #32]
    ldr x5, [x1, #40]
    ldr x6, [x1, #48]
    ldr x7, [x1, #56]
    ldr x1, [x1, #8]
    blr x8
    ldp q8, q9, [sp]
    ldp q10, q11, [sp, #32]
    ldp q12, q13, [sp, #64]
    ldp q14, q15, [sp, #96]
    add sp, sp, #128
    ldp x22, x27, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x29, x30, [sp], #16
    ret
