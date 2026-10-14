// Native ARM64 bridge for a GOAL function that owns its own stack.
// Arguments: x0 GOAL stack top, x3 function, x4 symbol-table GOAL offset,
// x5 writable GOAL base (x22), x6 signed-code base (x27).

.section __TEXT,__text,regular,pure_instructions
.p2align 4
.globl _og_jak1_call_goal_on_stack_arm64
_og_jak1_call_goal_on_stack_arm64:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x20, x21, [sp, #-16]!
    stp x22, x27, [sp, #-16]!
    sub sp, sp, #128
    stp q8, q9, [sp]
    stp q10, q11, [sp, #32]
    stp q12, q13, [sp, #64]
    stp q14, q15, [sp, #96]

    mov x9, sp
    mov sp, x0
    str x9, [sp, #-16]!
    mov x20, x4
    mov x21, x4
    mov x22, x5
    mov x27, x6
    blr x3

    ldr x9, [sp], #16
    mov sp, x9
    ldp q8, q9, [sp]
    ldp q10, q11, [sp, #32]
    ldp q12, q13, [sp, #64]
    ldp q14, q15, [sp, #96]
    add sp, sp, #128
    ldp x22, x27, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// Same bridge, but passes x1 to the GOAL function as its first argument (x0), for methods that
// allocate on the stack (e.g. `new 'stack 'file-stream`) and so must run on the GOAL stack.
.p2align 4
.globl _og_jak1_call_goal_on_stack_with_arg_arm64
_og_jak1_call_goal_on_stack_with_arg_arm64:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x20, x21, [sp, #-16]!
    stp x22, x27, [sp, #-16]!
    sub sp, sp, #128
    stp q8, q9, [sp]
    stp q10, q11, [sp, #32]
    stp q12, q13, [sp, #64]
    stp q14, q15, [sp, #96]

    mov x9, sp
    mov sp, x0
    str x9, [sp, #-16]!
    mov x20, x4
    mov x21, x4
    mov x22, x5
    mov x27, x6
    mov x0, x1
    blr x3

    ldr x9, [sp], #16
    mov sp, x9
    ldp q8, q9, [sp]
    ldp q10, q11, [sp, #32]
    ldp q12, q13, [sp, #64]
    ldp q14, q15, [sp, #96]
    add sp, sp, #128
    ldp x22, x27, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// Same bridge with three GOAL arguments: x1, x2 and x7 become x0, x1 and x2 (art-group relocate
// and level-code top-levels run between GOAL frames, see LoadExpandedFlut).
.p2align 4
.globl _og_jak1_call_goal_on_stack_with_args_arm64
_og_jak1_call_goal_on_stack_with_args_arm64:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x20, x21, [sp, #-16]!
    stp x22, x27, [sp, #-16]!
    sub sp, sp, #128
    stp q8, q9, [sp]
    stp q10, q11, [sp, #32]
    stp q12, q13, [sp, #64]
    stp q14, q15, [sp, #96]

    mov x9, sp
    mov sp, x0
    str x9, [sp, #-16]!
    mov x20, x4
    mov x21, x4
    mov x22, x5
    mov x27, x6
    mov x0, x1
    mov x1, x2
    mov x2, x7
    blr x3

    ldr x9, [sp], #16
    mov sp, x9
    ldp q8, q9, [sp]
    ldp q10, q11, [sp, #32]
    ldp q12, q13, [sp, #64]
    ldp q14, q15, [sp, #96]
    add sp, sp, #128
    ldp x22, x27, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x29, x30, [sp], #16
    ret
