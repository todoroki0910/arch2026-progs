# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.
#
# Version 1: a line-by-line translation of the C version. The multiplies
# call __mulsi3, so bf16_mul_asm and bf16_sqrt_asm need a stack frame.

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
    srli    t0, a0, 23
    andi    t0, t0, 0xFF            # t0 = exponent
    li      t1, 0xFF
    beq     t0, t1, .Lf32_keep      # Inf or NaN: no rounding

    srli    t0, a0, 16
    andi    t0, t0, 1               # t0 = bit 16, the last kept bit
    li      t1, 0x7FFF
    add     t0, t0, t1              # 0x7FFF + bit 16
    add     a0, a0, t0
.Lf32_keep:
    srli    a0, a0, 16              # keep the top 16 bits
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

# ---------------------------------------------------------------------------
# bf16_mul_asm: product of two bf16 values, fraction truncated.
#
# t0 = sign, t1 = exp_a, t2 = exp_b, t3 = mant_a, t4 = mant_b,
# a2 = exp_adjust
# ---------------------------------------------------------------------------
    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    # Step 1: split the fields.
    xor     t0, a0, a1
    lui     t1, 0x8                 # t1 = 0x8000
    and     t0, t0, t1              # t0 = sign of the product
    srli    t1, a0, 7
    andi    t1, t1, 0xFF            # t1 = exp_a
    srli    t2, a1, 7
    andi    t2, t2, 0xFF            # t2 = exp_b
    andi    t3, a0, 0x7F            # t3 = mant_a
    andi    t4, a1, 0x7F            # t4 = mant_b
    li      t6, 0x7FFF              # mask that drops the sign

    # Step 2: special values, a first.
    li      t5, 0xFF
    bne     t1, t5, .Lmul_check_b
    bnez    t3, .Lmul_ret_a         # a is NaN
    and     t5, a1, t6
    beqz    t5, .Lmul_ret_nan       # Inf x 0
    j       .Lmul_ret_inf           # Inf x anything else

.Lmul_check_b:
    bne     t2, t5, .Lmul_check_zero
    bnez    t4, .Lmul_ret_b         # b is NaN
    and     t5, a0, t6
    beqz    t5, .Lmul_ret_nan       # 0 x Inf
    j       .Lmul_ret_inf

    # Step 3: zero times a finite value.
.Lmul_check_zero:
    and     t5, a0, t6
    beqz    t5, .Lmul_ret_sign
    and     t5, a1, t6
    beqz    t5, .Lmul_ret_sign

    # Step 4: make both significands 1xxxxxxx.
    li      a2, 0                   # a2 = exp_adjust
    bnez    t1, .Lmul_a_normal
.Lmul_a_shift:                      # a is denormal
    andi    t5, t3, 0x80
    bnez    t5, .Lmul_a_done
    slli    t3, t3, 1
    addi    a2, a2, -1
    j       .Lmul_a_shift
.Lmul_a_done:
    li      t1, 1
    j       .Lmul_b_start
.Lmul_a_normal:
    ori     t3, t3, 0x80            # hidden one

.Lmul_b_start:
    bnez    t2, .Lmul_b_normal
.Lmul_b_shift:                      # b is denormal
    andi    t5, t4, 0x80
    bnez    t5, .Lmul_b_done
    slli    t4, t4, 1
    addi    a2, a2, -1
    j       .Lmul_b_shift
.Lmul_b_done:
    li      t2, 1
    j       .Lmul_multiply
.Lmul_b_normal:
    ori     t4, t4, 0x80

    # Step 5: multiply. exp = exp_a + exp_b - 127 + exp_adjust.
.Lmul_multiply:
    add     t1, t1, t2
    addi    t1, t1, -127
    add     t1, t1, a2              # t1 = exp

    addi    sp, sp, -16             # __mulsi3 may change t0 and t1
    sw      ra, 12(sp)
    sw      t0, 8(sp)
    sw      t1, 4(sp)
    mv      a0, t3
    mv      a1, t4
    call    __mulsi3                # a0 = product, in [2^14, 2^16)
    lw      ra, 12(sp)
    lw      t0, 8(sp)
    lw      t1, 4(sp)
    addi    sp, sp, 16

    # Step 6: renormalize and truncate the fraction.
    lui     t2, 0x8                 # t2 = 0x8000
    and     t2, a0, t2
    beqz    t2, .Lmul_below_two
    srli    a0, a0, 8               # product >= 2.0: shift one more
    andi    a0, a0, 0x7F
    addi    t1, t1, 1
    j       .Lmul_range
.Lmul_below_two:
    srli    a0, a0, 7
    andi    a0, a0, 0x7F            # a0 = frac

    # Step 7: overflow and underflow.
.Lmul_range:
    li      t2, 0xFF
    bge     t1, t2, .Lmul_ret_inf   # exp >= 0xFF: Inf
    bgtz    t1, .Lmul_pack          # exp > 0: normal
    li      t2, -6
    blt     t1, t2, .Lmul_ret_sign  # exp < -6: zero
    li      t2, 1
    sub     t2, t2, t1              # 1 - exp
    srl     a0, a0, t2              # denormal fraction
    li      t1, 0

    # Step 8: put sign, exponent and fraction together.
.Lmul_pack:
    slli    t1, t1, 7
    or      a0, a0, t1
    or      a0, a0, t0
    ret

.Lmul_ret_a:
    ret                             # a0 is still a
.Lmul_ret_b:
    mv      a0, a1
    ret
.Lmul_ret_nan:
    li      a0, BF16_NAN
    ret
.Lmul_ret_inf:
    li      a0, BF16_INF
    or      a0, a0, t0
    ret
.Lmul_ret_sign:
    mv      a0, t0                  # zero with the product sign
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

# ---------------------------------------------------------------------------
# bf16_sqrt_asm: square root by a binary search over the significand.
#
# t0 = sign, t1 = exp, then new_exp, t2 = mant, then m
# In the search: s0 = low, s1 = high, s2 = result, s3 = m, s4 = new_exp,
# s5 = mid
# ---------------------------------------------------------------------------
    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    # Step 1: split the fields.
    srli    t0, a0, 15              # t0 = sign
    srli    t1, a0, 7
    andi    t1, t1, 0xFF            # t1 = exp
    andi    t2, a0, 0x7F            # t2 = mant

    # Step 2: special values.
    li      t3, 0xFF
    bne     t1, t3, .Lsq_not_inf_nan
    bnez    t2, .Lsq_ret_a          # NaN
    bnez    t0, .Lsq_ret_nan        # -Inf
    ret                             # +Inf

.Lsq_not_inf_nan:
    bnez    t1, .Lsq_not_zero
    beqz    t2, .Lsq_ret_zero       # +0 and -0 give +0
.Lsq_not_zero:
    bnez    t0, .Lsq_ret_nan        # negative
    beqz    t1, .Lsq_ret_zero       # denormal

    # Step 3: make the exponent even.
    addi    t1, t1, -127            # t1 = e
    ori     t2, t2, 0x80            # t2 = m, in [128, 256)
    andi    t3, t1, 1
    beqz    t3, .Lsq_even
    slli    t2, t2, 1               # e odd: m * 2
    addi    t1, t1, -1              #        e - 1
.Lsq_even:
    srai    t1, t1, 1
    addi    t1, t1, 127             # t1 = new_exp

    # Step 4: largest mid in [90, 256] with mid * mid / 128 <= m.
    addi    sp, sp, -32             # the loop calls __mulsi3
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    sw      s3, 12(sp)
    sw      s4, 8(sp)
    sw      s5, 4(sp)

    li      s0, 90                  # low
    li      s1, 256                 # high
    li      s2, 128                 # result
    mv      s3, t2                  # m
    mv      s4, t1                  # new_exp

.Lsq_loop:
    bgtu    s0, s1, .Lsq_done       # while (low <= high)
    add     s5, s0, s1
    srli    s5, s5, 1               # mid = (low + high) / 2
    mv      a0, s5
    mv      a1, s5
    call    __mulsi3                # a0 = mid * mid
    srli    a0, a0, 7               # / 128
    bgtu    a0, s3, .Lsq_too_big
    mv      s2, s5                  # fits: result = mid
    addi    s0, s5, 1               #       low = mid + 1
    j       .Lsq_loop
.Lsq_too_big:
    addi    s1, s5, -1              # high = mid - 1
    j       .Lsq_loop

.Lsq_done:
    mv      t0, s2                  # t0 = result
    mv      t1, s4                  # t1 = new_exp
    lw      ra, 28(sp)
    lw      s0, 24(sp)
    lw      s1, 20(sp)
    lw      s2, 16(sp)
    lw      s3, 12(sp)
    lw      s4, 8(sp)
    lw      s5, 4(sp)
    addi    sp, sp, 32

    # Step 5: renormalize into [128, 256) and pack.
    li      t2, 256
    bltu    t0, t2, .Lsq_up
    srli    t0, t0, 1               # result >= 256
    addi    t1, t1, 1
    j       .Lsq_range
.Lsq_up:
    li      t2, 128
    bgeu    t0, t2, .Lsq_range      # while (result < 128
    li      t3, 1
    ble     t1, t3, .Lsq_range      #        && new_exp > 1)
    slli    t0, t0, 1
    addi    t1, t1, -1
    j       .Lsq_up

.Lsq_range:
    li      t2, 0xFF
    bge     t1, t2, .Lsq_ret_inf
    blez    t1, .Lsq_ret_zero
    slli    t1, t1, 7
    andi    t0, t0, 0x7F            # drop the hidden one
    or      a0, t1, t0
    ret

.Lsq_ret_a:
    ret
.Lsq_ret_nan:
    li      a0, BF16_NAN
    ret
.Lsq_ret_inf:
    li      a0, BF16_INF
    ret
.Lsq_ret_zero:
    li      a0, 0
    ret
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm