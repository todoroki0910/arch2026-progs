# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.
#
# Version 2: all three are leaf functions. The multiply forms the 8-bit by
# 8-bit significand product inline, and the square root uses a digit-by-digit
# integer square root, so neither calls __mulsi3 or needs a stack frame.

    .equ    BF16_INF, 0x7F80
    .equ    BF16_NAN, 0x7FC0

    .text

# ---------------------------------------------------------------------------
# bf16_from_f32_asm: round a binary32 pattern to bf16, ties to even.
# ---------------------------------------------------------------------------
    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    lui     t0, 0x7F800             # exponent mask, in place
    and     t1, a0, t0
    beq     t1, t0, .Lf32_keep      # Inf or NaN: no rounding
    srli    t1, a0, 16
    andi    t1, t1, 1               # bit 16, the last kept bit
    lui     t2, 0x8
    addi    t2, t2, -1              # 0x7FFF
    add     a0, a0, t2
    add     a0, a0, t1              # + 0x7FFF + bit 16
.Lf32_keep:
    srli    a0, a0, 16
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

# ---------------------------------------------------------------------------
# bf16_mul_asm: product of two bf16 values, fraction truncated.
#
# t0 = sign, t1 = exponent, t2 = exp_b, t3 = multiplicand x (mant_a),
# t4 = multiplier y (mant_b), t5 = 0xFF, a2 = product, a3 = scratch
# ---------------------------------------------------------------------------
    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    xor     t0, a0, a1
    lui     t1, 0x8
    and     t0, t0, t1              # sign of the product
    srli    t1, a0, 7
    andi    t1, t1, 0xFF            # exp_a
    srli    t2, a1, 7
    andi    t2, t2, 0xFF            # exp_b
    li      t5, 0xFF
    beq     t1, t5, .Lmul_a_special
    beq     t2, t5, .Lmul_b_special
    slli    a3, a0, 17              # drops the sign: zero iff a is +0 or -0
    beqz    a3, .Lmul_zero
    slli    a3, a1, 17
    beqz    a3, .Lmul_zero

    andi    t3, a0, 0x7F
    andi    t4, a1, 0x7F
    beqz    t1, .Lmul_a_denormal
    ori     t3, t3, 0x80            # hidden one
.Lmul_a_ready:
    beqz    t2, .Lmul_b_denormal
    ori     t4, t4, 0x80
.Lmul_b_ready:
    add     t1, t1, t2
    addi    t1, t1, -127            # exponent of the product

    # x * y with y = 1yyyyyyy: bit 7 is always set, so start from x << 7
    # and add x << i for each set bit i below it. A fraction of 0 exits at
    # once; otherwise each bit costs 2 instructions, or 4 when it is set.
    slli    a2, t3, 7
    andi    a3, t4, 0x7F
    beqz    a3, .Lmul_product
    andi    a3, t4, 0x40
    beqz    a3, 1f
    slli    a3, t3, 6
    add     a2, a2, a3
1:  andi    a3, t4, 0x20
    beqz    a3, 1f
    slli    a3, t3, 5
    add     a2, a2, a3
1:  andi    a3, t4, 0x10
    beqz    a3, 1f
    slli    a3, t3, 4
    add     a2, a2, a3
1:  andi    a3, t4, 0x08
    beqz    a3, 1f
    slli    a3, t3, 3
    add     a2, a2, a3
1:  andi    a3, t4, 0x04
    beqz    a3, 1f
    slli    a3, t3, 2
    add     a2, a2, a3
1:  andi    a3, t4, 0x02
    beqz    a3, 1f
    slli    a3, t3, 1
    add     a2, a2, a3
1:  andi    a3, t4, 0x01
    beqz    a3, .Lmul_product
    add     a2, a2, t3

    # Renormalize: bit 15 of the product moves to the sign bit, so one
    # bgez tests it without loading 0x8000.
.Lmul_product:
    slli    a3, a2, 16
    bgez    a3, .Lmul_below_two
    srli    a2, a2, 1               # product >= 2.0: shift one more
    addi    t1, t1, 1
.Lmul_below_two:
    srli    a2, a2, 7
    andi    a2, a2, 0x7F            # truncated fraction

    bge     t1, t5, .Lmul_inf       # exponent >= 0xFF
    blez    t1, .Lmul_underflow
    slli    t1, t1, 7
    or      a0, a2, t1
    or      a0, a0, t0
    ret

.Lmul_underflow:
    li      a3, -6
    blt     t1, a3, .Lmul_zero      # exponent < -6: zero
    li      a3, 1
    sub     a3, a3, t1
    srl     a2, a2, a3              # denormal fraction
    or      a0, a2, t0
    ret

    # A denormal has at most seven fraction bits, so it needs at least one
    # shift: the loops test at the bottom and lower the exponent directly.
.Lmul_a_denormal:
    li      t1, 1
1:  slli    t3, t3, 1
    addi    t1, t1, -1
    andi    a3, t3, 0x80
    beqz    a3, 1b
    j       .Lmul_a_ready
.Lmul_b_denormal:
    li      t2, 1
1:  slli    t4, t4, 1
    addi    t2, t2, -1
    andi    a3, t4, 0x80
    beqz    a3, 1b
    j       .Lmul_b_ready

    # Special values, a first: a NaN a, then Inf x 0, then Inf.
.Lmul_a_special:
    andi    a3, a0, 0x7F
    bnez    a3, .Lmul_ret               # a is NaN: return it unchanged
    slli    a3, a1, 17
    beqz    a3, .Lmul_nan               # Inf x 0
    j       .Lmul_inf
.Lmul_b_special:
    andi    a3, a1, 0x7F
    bnez    a3, .Lmul_ret_b             # b is NaN
    slli    a3, a0, 17
    beqz    a3, .Lmul_nan               # 0 x Inf
.Lmul_inf:
    li      a0, BF16_INF
    or      a0, a0, t0
.Lmul_ret:
    ret
.Lmul_ret_b:
    mv      a0, a1
    ret
.Lmul_nan:
    li      a0, BF16_NAN
    ret
.Lmul_zero:
    mv      a0, t0                      # zero with the product sign
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

# ---------------------------------------------------------------------------
# bf16_sqrt_asm: square root without a multiply.
#
# The contract's search returns the largest mid with mid * mid / 128 <= m
# (truncating), that is, mid * mid <= 128 * m + 127. That is the integer
# square root of T = 128 * m + 127, found here digit by digit. For a positive
# normal it is always in [128, 255], so no renormalization or range check is
# needed, and the exponent (E + 127) / 2 is always in [64, 190].
#
# t1 = E, t2 = m, then T, a1 = bit, a2 = result, a3 = scratch
# ---------------------------------------------------------------------------
    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    srli    t1, a0, 7
    andi    t1, t1, 0xFF            # E
    andi    t2, a0, 0x7F            # fraction
    li      a3, 0xFF
    beq     t1, a3, .Lsq_inf_nan
    slli    a3, a0, 17
    beqz    a3, .Lsq_zero           # +0 and -0 give +0
    srli    a3, a0, 15
    bnez    a3, .Lsq_nan            # any other negative
    beqz    t1, .Lsq_zero           # positive denormal

    ori     t2, t2, 0x80            # m = 1.fraction * 128
    andi    a3, t1, 1
    slli    t2, t2, 7
    bnez    a3, 1f                  # E odd: the exponent E - 127 is even
    slli    t2, t2, 1               # E even: m * 2 for an odd exponent
1:  ori     t2, t2, 127             # T = 128 * m + 127

    # Integer square root of T < 2^16. The first digit is always 1
    # (T >= 2^14), so start after it with result = bit = 2^14.
    lui     a1, 0x4                 # 2^14
    sub     t2, t2, a1
    mv      a2, a1
    srli    a1, a1, 2
.Lsq_loop:
    add     a3, a2, a1              # result + bit
    srli    a2, a2, 1
    bltu    t2, a3, .Lsq_next
    sub     t2, t2, a3
    add     a2, a2, a1
.Lsq_next:
    srli    a1, a1, 2
    bnez    a1, .Lsq_loop

    addi    t1, t1, 127
    srli    t1, t1, 1               # (E + 127) / 2 = (E - 127) / 2 + 127
    slli    t1, t1, 7
    andi    a2, a2, 0x7F            # drop the hidden one
    or      a0, t1, a2
    ret

.Lsq_inf_nan:
    bnez    t2, .Lsq_ret            # NaN: return it unchanged
    srli    a3, a0, 15
    bnez    a3, .Lsq_nan            # -Inf
.Lsq_ret:
    ret                             # +Inf
.Lsq_nan:
    li      a0, BF16_NAN
    ret
.Lsq_zero:
    li      a0, 0
    ret
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm