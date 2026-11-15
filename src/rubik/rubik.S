# rubik_solve_asm: optimal 2x2x2 cube solver, hand-written RV32I.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#                                   a0 = state, a1 = out, a2 = cap; result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions, no heap, no recursion. Tests: tests/trubik.c.
#
# The search is the IDA* of rubik.c, h = max(perm_dist, ori_dist), over the
# tables in tables.S. A coordinate is kept as its byte offset in its table
# (rank * 12), and the entry of a face holds both the offset of the next state
# and that state's distance, so a child costs two loads per coordinate and no
# separate distance lookup.
#
# A node at depth g is cut when h > rem = bound - g. A node that is not cut at
# rem = 0 has h = 0, so it is the solved cube; one at rem > 0 is never solved,
# since the bound grows only to the smallest f that was cut.
#
# Frame g (16 bytes, s0 points at the current one) holds the state reached at
# depth g, the face (times 4) of the child being tried and its quarter turns:
#   0 x (perm offset)   4 y (ori offset)   8 face * 4   12 turns, 1..3
# The face that reached frame g is the word at 8 of frame g - 1; the frame
# below the root holds 12, which no face equals.
#
# Registers through the search:
#   s0 frame   s1 rem   s2 perm table   s3 ori table   s4 smallest excess
#   s5 frame of the root   t0 face * 4   t1 turns   a3, a4 x, y of a child
#   a5, a6 its distances   t5 the constant 3   t6 the constant 12
# a1 and a2 (out and cap) are kept for the output.

    .section .rodata
move_letter:                        # indexed by face * 4
    .ascii  "R\0\0\0B\0\0\0D"
move_suffix:                        # indexed by quarter turns
    .byte   0, 0, '2', 39

    .text
    .globl  rubik_solve_asm
    .type   rubik_solve_asm, @function
    .align  2
rubik_solve_asm:
    # Validate: seven distinct cubies '1'..'7', seven twists '1'..'3', the
    # NUL, and twists that sum to a multiple of 3. Nothing past the first
    # out-of-range character is read.
    li      t6, 0                   # cubies seen, one bit each
    li      t0, 0
    li      t3, 7
    li      t4, 1
.Lperm:
    add     t1, a0, t0
    lbu     t2, 0(t1)
    addi    t2, t2, -49             # '1' -> 0; below '1' wraps above 6
    bgeu    t2, t3, .Lbad
    sll     t5, t4, t2
    and     t1, t6, t5
    bnez    t1, .Lbad               # repeated cubie
    or      t6, t6, t5
    addi    t0, t0, 1
    blt     t0, t3, .Lperm
    li      a3, 0                   # twist sum
    li      t3, 3
    li      t4, 14
.Ltwist:
    add     t1, a0, t0
    lbu     t2, 0(t1)
    addi    t2, t2, -49
    bgeu    t2, t3, .Lbad
    add     a3, a3, t2
    addi    t0, t0, 1
    blt     t0, t4, .Ltwist
    lbu     t2, 14(a0)
    bnez    t2, .Lbad               # exactly 14 characters
.Lmod3:                             # the sum is at most 14
    blt     a3, t3, .Lmod3_done
    addi    a3, a3, -3
    j       .Lmod3
.Lmod3_done:
    bnez    a3, .Lbad

    # Rank: the permutation by its Lehmer code, p = p * (7 - i) + smaller,
    # then the first six twists in base 3; keep both as offsets, rank * 12.
    li      a3, 0                   # p
    li      t0, 0                   # i
    li      t4, 7
.Lrank_i:
    add     t1, a0, t0
    lbu     t2, 0(t1)
    li      t5, 0                   # later digits smaller than digit i
    addi    t3, t0, 1
.Lrank_j:
    bge     t3, t4, .Lrank_mul
    add     t1, a0, t3
    lbu     t1, 0(t1)
    sltu    t1, t1, t2
    add     t5, t5, t1
    addi    t3, t3, 1
    j       .Lrank_j
.Lrank_mul:                         # p * (7 - i) by repeated addition
    sub     t3, t4, t0
    li      t1, 0
.Lrank_add:
    add     t1, t1, a3
    addi    t3, t3, -1
    bnez    t3, .Lrank_add
    add     a3, t1, t5
    addi    t0, t0, 1
    blt     t0, t4, .Lrank_i
    li      a4, 0                   # o
    li      t4, 13
.Lori:
    add     t1, a0, t0
    lbu     t2, 0(t1)
    addi    t2, t2, -49
    slli    t3, a4, 1
    add     a4, a4, t3
    add     a4, a4, t2
    addi    t0, t0, 1
    blt     t0, t4, .Lori
    slli    a3, a3, 2               # x = p * 12
    slli    t1, a3, 1
    add     a3, a3, t1
    slli    a4, a4, 2               # y = o * 12
    slli    t1, a4, 1
    add     a4, a4, t1

    # Frames: saved registers at 0, the frame below the root at 32, the
    # twelve frames of depth 0..11 at 48.
    addi    sp, sp, -240
    sw      s0, 0(sp)
    sw      s1, 4(sp)
    sw      s2, 8(sp)
    sw      s3, 12(sp)
    sw      s4, 16(sp)
    sw      s5, 20(sp)
    la      s2, rubik_perm_tab
    la      s3, rubik_ori_tab
    addi    s5, sp, 48
    li      t5, 3
    li      t6, 12
    sw      t6, -8(s5)              # the root has no previous face
    sw      a3, 0(s5)
    sw      a4, 4(s5)
    add     t2, s2, a3              # first bound: h of the root
    lbu     s1, 3(t2)
    add     t3, s3, a4
    lbu     a6, 3(t3)
    bgeu    s1, a6, .Literation
    mv      s1, a6
.Literation:
    li      s4, 255
    mv      s0, s5
    j       .Lexpand                # the root is within its own bound

.Lchild:                            # turn (a3, a4) by face t0 into frame s0+16
    add     t2, s2, a3
    add     t2, t2, t0
    add     t3, s3, a4
    add     t3, t3, t0
    lhu     a3, 0(t2)
    lbu     a5, 2(t2)
    lhu     a4, 0(t3)
    lbu     a6, 2(t3)
    addi    s0, s0, 16
    addi    s1, s1, -1
    sw      a3, 0(s0)
    sw      a4, 4(s0)
.Lenter:
    bltu    s1, a5, .Lcut
    bltu    s1, a6, .Lcut
.Lexpand:
    beqz    s1, .Lfound
    li      t0, 0
.Lfirst_turn:                       # start face t0, skipping the last face
    lw      t2, -8(s0)
    bne     t0, t2, 1f
    addi    t0, t0, 4
1:
    bgeu    t0, t6, .Lleave
    li      t1, 1
    sw      t0, 8(s0)
    sw      t1, 12(s0)
    lw      a3, 0(s0)
    lw      a4, 4(s0)
    j       .Lchild

.Lcut:                              # keep the smallest excess max(h) - rem
    bgeu    a5, a6, 1f
    mv      a5, a6
1:
    sub     a5, a5, s1
    bgeu    a5, s4, .Lback
    mv      s4, a5
.Lback:                             # back in the parent of frame s0
    addi    s0, s0, -16
    addi    s1, s1, 1
    lw      t1, 12(s0)
    lw      t0, 8(s0)
    beq     t1, t5, .Lnext_face
    addi    t1, t1, 1               # one more quarter turn on the sibling,
    sw      t1, 12(s0)              # which is still in the child frame
    lw      a3, 16(s0)
    lw      a4, 20(s0)
    j       .Lchild
.Lnext_face:
    addi    t0, t0, 4
    j       .Lfirst_turn
.Lleave:                            # frame s0 done
    bne     s0, s5, .Lback
    add     s1, s1, s4              # nothing within the bound: raise it
    j       .Literation

.Lfound:
    # The moves are in frames 0 .. g-1. The text needs a letter, a suffix
    # unless the turn is a quarter turn, and a space or the NUL after each
    # move; the empty solution needs the NUL alone.
    sub     a0, s0, s5
    srli    a0, a0, 4               # g, the length
    mv      t2, s5
    li      a7, 0
    li      t4, 1
.Lneed:
    beq     t2, s0, .Lneed_done
    lw      t1, 12(t2)
    addi    a7, a7, 2
    beq     t1, t4, 1f
    addi    a7, a7, 1
1:
    addi    t2, t2, 16
    j       .Lneed
.Lneed_done:
    bnez    a7, 1f
    li      a7, 1
1:
    bgeu    a2, a7, .Lwrite
    li      a0, -2
    beqz    a2, .Lreturn
    sb      zero, 0(a1)
    j       .Lreturn
.Lwrite:
    la      t3, move_letter
    la      t4, move_suffix
    mv      t2, s5
    j       .Lwrite_move
.Lwrite_space:
    li      t1, 32
    sb      t1, 0(a1)
    addi    a1, a1, 1
.Lwrite_move:
    beq     t2, s0, .Lwrite_done
    lw      t0, 8(t2)
    lw      t1, 12(t2)
    add     t0, t0, t3
    lbu     t0, 0(t0)
    sb      t0, 0(a1)
    addi    a1, a1, 1
    add     t1, t1, t4
    lbu     t1, 0(t1)
    addi    t2, t2, 16
    beqz    t1, 1f
    sb      t1, 0(a1)
    addi    a1, a1, 1
1:
    bne     t2, s0, .Lwrite_space
.Lwrite_done:
    sb      zero, 0(a1)
.Lreturn:
    lw      s0, 0(sp)
    lw      s1, 4(sp)
    lw      s2, 8(sp)
    lw      s3, 12(sp)
    lw      s4, 16(sp)
    lw      s5, 20(sp)
    addi    sp, sp, 240
    ret
.Lbad:
    li      a0, -1
    ret
    .size   rubik_solve_asm, .-rubik_solve_asm
