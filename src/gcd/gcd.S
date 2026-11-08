# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2

gcd_u32_asm:
    beqz a0,.Lb_Ret
    beqz a1,.Ldone
    li t0,0 # shift=0

.Lboth_even:
    or t1,a0,a1
    andi t1,t1,1
    bnez t1, .La_odd
    srli a0,a0,1
    srli a1,a1,1
    addi t0,t0,1
    j .Lboth_even


.La_odd:
    andi t1,a0,1
    bnez t1, .Lb_odd
    srli a0,a0,1
    j .La_odd
.Lb_odd:
    andi t1,a1,1
    bnez t1, .L_compare
    srli a1,a1,1
    j .Lb_odd
.L_compare:
    bgeu a1,a0, .L_step
    mv t1,a0
    mv a0,a1
    mv a1,t1

.L_step:
    sub a1,a1,a0
    bnez a1, .Lb_odd

    sll a0,a0,t0

.Ldone:
    ret
.Lb_Ret:
    mv a0,a1
    ret
    .size   gcd_u32_asm, .-gcd_u32_asm
