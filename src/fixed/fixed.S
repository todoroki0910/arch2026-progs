# op1, op2, op3 and q_mul: hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)   a0, a1, a2 -> a0
# uint32_t op2_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# uint32_t op3_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# int32_t  q_mul_asm(int32_t a, int32_t b)           a0, a1 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. q_mul forms a 64-bit product in a register pair. Tests:
# tests/tfixed.c.

    .text

# ---------------------------------------------------------------------------
# op1_asm：只用位元運算做加法 a + b (mod 2^32)，並回傳迴圈跑了幾輪。
#
#   a ^ b       = 不考慮進位的和
#   (a & b) << 1 = 每一位產生的進位，往左移一位加到下一位
#   重複「和 = a ^ b、進位 = (a & b) << 1」直到進位變成 0。
#
# 暫存器：
#   a0 = a（目前的部分和，最後就是答案）
#   a1 = b（目前的進位，變 0 時結束）
#   a2 = n 的位址（把輪數寫回去）
#   t0 = 輪數 passes
#   t1 = 暫存 a & b
# ---------------------------------------------------------------------------
    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:

    li t0,0                 # passes = 0
    beqz a1,.Lop1_done      # b 一開始就是 0：不用進迴圈，答案就是 a，輪數 0
.L_add:
    and t1,a0,a1            # t1 = a & b      （哪些位會產生進位）
    xor a0,a0,a1            # a  = a ^ b      （不含進位的和）
    slli a1,t1,1            # b  = (a & b) << 1（進位移到下一位）
    addi t0,t0,1            # passes++
    bnez a1, .L_add         # 還有進位就繼續（迴圈條件放尾端，每輪只要一個分支）
.Lop1_done:
    sw t0,0(a2)             # *n = passes
    ret                     # a0 = 和
    .size   op1_asm, .-op1_asm

# ---------------------------------------------------------------------------
# op2_asm：a - b (mod 2^32)。
# 規格允許直接用減法（指令上限 40），一條 sub 就搞定，
# 效果等同於 op1(a, op1(~b, 1))，也就是 a + (-b)。
# ---------------------------------------------------------------------------
    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub a0,a0,a1            # a0 = a - b
    ret
    .size   op2_asm, .-op2_asm

# ---------------------------------------------------------------------------
# op3_asm：floor((a + b) / 2)，中間不能溢位。
#
#   a + b = (a ^ b) + 2 * (a & b)
#   所以 (a + b) / 2 = ((a ^ b) >> 1) + (a & b)
# 這樣就不用先算 a + b（那個可能超過 32 位元）。
# ---------------------------------------------------------------------------
    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    and t0,a0,a1            # t0 = a & b      （兩個數都有的位，平均後保留）
    xor a0,a0,a1            # a0 = a ^ b      （只有一邊有的位）
    srli a0,a0,1            # a0 = (a ^ b) >> 1（這部分除以 2，邏輯右移）
    add a0,a0,t0            # a0 = ((a ^ b) >> 1) + (a & b)
    ret
    .size   op3_asm, .-op3_asm

# ---------------------------------------------------------------------------
# q_mul_asm：Q11.20 定點數乘法。
#   數值 A 代表 A / 2^20，所以 (A * B) 要再右移 20 位。
#   步驟：
#     1. 取出結果的正負號，把 a、b 轉成絕對值（無號數）
#     2. 用 shift-and-add 算出 64 位元的無號乘積 |a| * |b|，存在 t6:t5
#     3. 若結果為負，對 64 位元乘積取 2 補數
#     4. 加上 2^19（0.5 個最小單位）做四捨五入（同值時往 +∞）
#     5. 64 位元算術右移 20 位，取低 32 位當答案（溢位就 wrap，不飽和）
#
# 暫存器：
#   a0 = 被乘數（絕對值較大的那個）
#   a1 = 乘數（絕對值較小的那個，逐位元檢查，越小迴圈越早結束）
#   t1 = 正負號遮罩：0 表示結果為正，-1（全 1）表示結果為負
#   t6:t5 = 64 位元乘積（t6 = 高 32 位，t5 = 低 32 位）
#   a2 = 目前處理的位元編號 i（被乘數左移 i 位）
#   a3 = 32 - i（用來算出左移時溢出到高 32 位的部分）
#   t0 = 進位 / 暫存
#   t2 = 暫存
# ---------------------------------------------------------------------------
    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
# --- 1. 正負號與絕對值 ---
    xor t1,a0,a1            # 符號位不同 -> 結果為負
    srai t1,t1,31           # t1 = 0（正）或 -1（負）

    # 無分支取絕對值：m = x >> 31（0 或 -1），|x| = (x ^ m) - m
    # x 為負時：(x ^ -1) - (-1) = ~x + 1 = -x
    srai t2,a0,31
    xor a0,a0,t2
    sub a0,a0,t2            # a0 = |a|（當成無號數，INT_MIN 會變 0x80000000，仍正確）
    srai t2,a1,31
    xor a1,a1,t2
    sub a1,a1,t2            # a1 = |b|

    # 讓 a1 放比較小的數：迴圈次數取決於 a1 的最高位元，越小越快結束
    bgeu a0,a1, .L_prepare  # 已經是 a0 >= a1 就不用交換
    mv t2,a1                # 交換 a0、a1
    mv a1,a0
    mv a0,t2

# --- 2. shift-and-add 乘法 ---
# 乘積 = Σ (a1 的第 i 位) * (a0 << i)，i = 0..31
# a0 << i 是 64 位元的值：低 32 位 = a0 << i，高 32 位 = a0 >> (32 - i)
.L_prepare:
    # 先單獨處理第 0 位（i = 0）：
    # a0 << 0 = a0，沒有東西溢出到高位，
    # 而且 a0 >> 32 在 RV32 上 shift 量只取低 5 位會變成 a0 >> 0，不能放進迴圈裡算
    li t6,0                 # high = 0
    andi t2,a1,1            # t2 = a1 的第 0 位
    neg t2,t2               # 0 -> 0，1 -> 0xFFFFFFFF（根據最後一個 bit 擴充成遮罩）
    and t5,a0,t2            # low = 第 0 位是 1 ? a0 : 0（不用分支）
    srli a1,a1,1            # 處理完第 0 位，乘數右移
    beqz a1,.L_sign         # 乘數已經沒有 1 了，乘法結束

    li a2,0                 # i（進迴圈後馬上 +1，所以第一輪 i = 1）
    li a3,32                # 32 - i（第一輪 = 31）
.Lmul_loop:
    addi a2,a2,1            # i++
    addi a3,a3,-1           # (32 - i)--
    andi t2,a1,1            # 取乘數目前最低位（= 原本的第 i 位）
    srli a1,a1,1            # 乘數右移，下一輪看下一位
    beqz t2,.L_next         # 這一位是 0：不用加
    # 這一位是 1：把 64 位元的 (a0 << i) 加到 t6:t5
    sll t2,a0,a2            # 低 32 位部分 = a0 << i
    add t5,t5,t2            # low += a0 << i
    sltu t0,t5,t2           # 相加後變小 -> 有進位，t0 = carry
    srl t2,a0,a3            # 高 32 位部分 = a0 >> (32 - i)
    add t6,t6,t2            # high += a0 >> (32 - i)
    add t6,t6,t0            # high += carry
.L_next:
    bnez a1, .Lmul_loop     # 乘數還有 1 就繼續；i 最大到 31，a3 最小到 1，不會出現 shift 32

# --- 3. 套上正負號 ---
# 64 位元取 2 補數：-(high:low) = (~high:~low) + 1
#   low  = -low（等於 ~low + 1）
#   若 ~low + 1 有進位（只會發生在 low 變回 0 時），high 也要 +1
.L_sign:
    beqz t1,.L_round        # 結果為正：不用處理
    neg t5,t5               # low = -low
    seqz t0,t5              # t0 = (low == 0) ? 1 : 0，也就是低位的進位
    not t6,t6               # high = ~high
    add t6,t6,t0            # high += carry

# --- 4. 四捨五入：加上 2^19 ---
.L_round:
    lui t0,0x80             # t0 = 0x80 << 12 = 0x80000 = 2^19（lui 填高 20 位，低 12 位為 0）
    add t5,t5,t0            # low += 2^19
    sltu t0,t5,t0           # 檢查有沒有進位
    add t6,t6,t0            # high += carry

# --- 5. 64 位元右移 20 位，取低 32 位 ---
# 結果 = (high:low) >> 20 的低 32 位 = (low >> 20) | (high << 12)
# 只取低 32 位，所以算術右移或邏輯右移都一樣，高位溢出的部分直接丟掉（wrap）
    srli t5,t5,20           # low 的高 12 位移到結果的低 12 位
    slli t6,t6,12           # high 的低 20 位移到結果的高 20 位
    or a0,t5,t6             # 合併成 32 位元答案
    ret
    .size   q_mul_asm, .-q_mul_asm
