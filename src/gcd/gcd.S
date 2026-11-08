# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# Registers: a0 = a, a1 = b, t0 = shared power of two (shift count),
#            t1 = parity scratch, t2 = difference in the swap path.
#            Leaf function: no stack, no callee-saved registers touched.
#
# Every loop is rotated so the test sits at the bottom (loop inversion):
# each iteration ends in one conditional branch instead of a branch plus j.
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2

gcd_u32_asm:
    beqz    a0, .Lb_Ret         # gcd(0, b) = b
    beqz    a1, .Ldone          # gcd(a, 0) = a, already in a0
    li      t0, 0               # shift = 0

    # Strip the factors of two that a and b share; count them in t0.
    or      t1, a0, a1
    andi    t1, t1, 1           # t1 = 1 if a or b is odd
    bnez    t1, .La_odd
.Lboth_even:
    srli    a0, a0, 1
    srli    a1, a1, 1
    addi    t0, t0, 1
    or      t1, a0, a1
    andi    t1, t1, 1
    beqz    t1, .Lboth_even     # both still even: keep halving

    # Make a odd; the remaining factors of two of a are not shared.
.La_odd:
    andi    t1, a0, 1           # t1 = 1 if a is odd
    bnez    t1, .Lb_odd
.La_shift:
    srli    a0, a0, 1
    andi    t1, a0, 1
    beqz    t1, .La_shift

    # Main loop. Invariant: a is odd. Make b odd, then subtract.
.Lb_odd:
    andi    t1, a1, 1           # t1 = 1 if b is odd
    bnez    t1, .L_compare
.Lb_shift:
    srli    a1, a1, 1
    andi    t1, a1, 1
    beqz    t1, .Lb_shift

.L_compare:
    bltu    a1, a0, .L_swap     # b < a: swap so the larger is in a1
    sub     a1, a1, a0          # b - a of two odd numbers is even
    bnez    a1, .Lb_shift       # nonzero and even: shift at least once

    sll     a0, a0, t0          # restore the shared factors of two
.Ldone:
    ret

    # b < a: new a = b, new b = a - b. The difference of two odd numbers
    # with a > b is even and nonzero, so skip the parity test of b.
.L_swap:
    sub     t2, a0, a1
    mv      a0, a1
    mv      a1, t2
    j       .Lb_shift

.Lb_Ret:
    mv      a0, a1
    ret
    .size   gcd_u32_asm, .-gcd_u32_asm
