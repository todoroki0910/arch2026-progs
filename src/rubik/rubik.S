# rubik_solve_asm: optimal 2x2x2 cube solver, hand-written RV32I.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#                                   a0 = state, a1 = out, a2 = cap; result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions, no heap, no recursion. Tests: tests/trubik.c.
#
# The plain IDA* of rubik.c retires up to 18.7 million instructions here for
# the hardest states at distance 11. This one ends the search in a table of
# the 12,224 states within 5 moves (rubik_near, tables.S): a state found there
# is the root, or a node at rem = bound - g = 5, and its distance completes
# the solution. The bound starts at 6 and grows by one; the iteration of bound
# b sees every solution of length b, through its prefix of length b - 5, and
# every shorter one was found by an earlier iteration, so the first solution
# is a shortest one. Above rem = 5 a node is cut when perm_dist or ori_dist
# exceeds rem.
#
# A coordinate is kept as its byte offset in its table (rank * 12), and the
# entry of a face holds both the offset of the next state and that state's
# distance, so a child costs two loads per coordinate.
#
# Frame g (16 bytes, s0 points at the current one) holds the state reached at
# depth g, the face (times 4) of the child being tried and its quarter turns:
#   0 x (perm offset)   4 y (ori offset)   8 face * 4   12 turns, 1..3
# The face that reached frame g is the word at 8 of frame g - 1; the frame
# below the root holds 12, which no face equals. Once a solution is found,
# the frames from the node onwards receive the rest of the moves.
#
# Registers through the search:
#   s0 frame   s1 rem   s2 perm table   s3 ori table   s4 the constant 6
#   s5 frame of the root   s6 rubik_near   t0 face * 4   t1 turns
#   a3, a4 x, y of a child   a5, a6 its distances   t5 the constant 3
#   t6 the constant 12
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

    # Frames: ra and s0..s6 at 0, the frame below the root at 32, the
    # twelve frames of depth 0..11 at 48.
    addi    sp, sp, -240
    sw      ra, 0(sp)
    sw      s0, 4(sp)
    sw      s1, 8(sp)
    sw      s2, 12(sp)
    sw      s3, 16(sp)
    sw      s4, 20(sp)
    sw      s5, 24(sp)
    sw      s6, 28(sp)
    la      s2, rubik_perm_tab
    la      s3, rubik_ori_tab
    la      s6, rubik_near
    addi    s5, sp, 48
    li      s4, 6
    li      t5, 3
    li      t6, 12
    sw      t6, -8(s5)              # the root has no previous face
    sw      a3, 0(s5)
    sw      a4, 4(s5)
    mv      s0, s5
    jal     .Lnear                  # a root within 5 moves is solved at once
    bne     a7, t6, .Lfound         # 12 is no distance (see .Lnear)
    li      s1, 6                   # bound of the first iteration
.Literation:
    mv      s0, s5
    j       .Lexpand                # the root has rem >= 6 and is not cut

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
    bltu    s1, a5, .Lback          # cut: h > rem
    bltu    s1, a6, .Lback
    bltu    s1, s4, .Lprobe         # rem = 5: look the state up
.Lexpand:
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

.Lprobe:
    jal     .Lnear
    bgeu    s1, a7, .Lfound         # within rem moves
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
    addi    s1, s1, 1               # nothing within the bound: raise it
    j       .Literation

    # .Lnear: a7 = distance of the state (a3, a4) if it is within 5 moves,
    # else 12. Leaves t0, t1, t5, t6 and the s registers alone; uses t2, t3,
    # t4 and a0.
    #
    # Binary search of the 12,224 sorted words of rubik_near for the key
    # (p * 3) << 15 | (o * 3) << 3, with p * 3 = x / 4 and o * 3 = y / 4.
    # With the low bits set, word <= a0 holds exactly when the key of the
    # word is at most the key searched for. t4 ends at the last word whose
    # key is at most it: one probe at 12,224 - 8,192 = 4,032 words, then
    # steps of 4,096 down to 1 words (bytes below). The last word reachable
    # is 4,032 + 8,191 = 12,223, the end of the table.
.Lnear:
    srli    t2, a3, 2
    slli    t2, t2, 15
    srli    a0, a4, 2
    slli    a0, a0, 3
    or      a0, a0, t2
    ori     a0, a0, 7
    mv      t4, s6
    .irp    step, 16128, 16384, 8192, 4096, 2048
    li      t3, \step
    add     t3, t4, t3
    lw      t2, 0(t3)
    bltu    a0, t2, 1f
    mv      t4, t3
1:
    .endr
    .irp    step, 1024, 512, 256, 128, 64, 32, 16, 8, 4
    lw      t2, \step(t4)
    bltu    a0, t2, 1f
    addi    t4, t4, \step
1:
    .endr
    lw      t2, 0(t4)
    ori     a7, t2, 7
    bne     a7, a0, .Lnear_miss
    andi    a7, t2, 7
    ret
.Lnear_miss:
    li      a7, 12
    ret

.Lfound:
    # Frame s0 holds a state at distance a7. Walk down: of the nine moves,
    # take one that reaches distance a7 - 1, until the cube is solved.
    mv      s1, a7
.Ldescend:
    beqz    s1, .Lsolved
    addi    s4, s1, -1              # the distance to reach
    li      t0, 0
.Ldescend_face:
    lw      a3, 0(s0)
    lw      a4, 4(s0)
    li      t1, 1
.Ldescend_turn:
    add     t2, s2, a3
    add     t2, t2, t0
    lhu     a3, 0(t2)
    add     t3, s3, a4
    add     t3, t3, t0
    lhu     a4, 0(t3)
    jal     .Lnear
    beq     a7, s4, .Ldescend_move
    addi    t1, t1, 1
    bgeu    t5, t1, .Ldescend_turn
    addi    t0, t0, 4
    j       .Ldescend_face
.Ldescend_move:
    sw      t0, 8(s0)
    sw      t1, 12(s0)
    addi    s0, s0, 16
    sw      a3, 0(s0)
    sw      a4, 4(s0)
    mv      s1, s4
    j       .Ldescend

.Lsolved:
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
    lw      ra, 0(sp)
    lw      s0, 4(sp)
    lw      s1, 8(sp)
    lw      s2, 12(sp)
    lw      s3, 16(sp)
    lw      s4, 20(sp)
    lw      s5, 24(sp)
    lw      s6, 28(sp)
    addi    sp, sp, 240
    ret
.Lbad:
    li      a0, -1
    ret
    .size   rubik_solve_asm, .-rubik_solve_asm
