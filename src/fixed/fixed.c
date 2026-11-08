#include "fixed.h"

/* Bitwise addition, subtraction and averaging, and Q11.20 multiplication
 * built from four 16 x 16 partial products. See fixed.h for the contracts.
 */
uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    int passes = 0;
    while (b != 0) {
        uint32_t c = (a & b) << 1;
        a = a ^ b;
        b = c;
        passes++;
    }
    *n = passes;
    return a;
}

uint32_t op2(uint32_t a, uint32_t b)
{
    return a - b;
}

uint32_t op3(uint32_t a, uint32_t b)
{
    return ((a ^ b) >> 1) + (a & b);
}

int32_t q_mul(int32_t a, int32_t b)
{
    int sign = (uint32_t) (a ^ b) >> 31;
    uint32_t a_size = a;
    if (a < 0) {
        a_size = -a_size;
    }
    uint32_t b_size = b;
    if (b < 0) {
        b_size = -b_size;
    }

    // size*size 拆成 lo high
    uint32_t a_lo = a_size & 0xFFFF;
    uint32_t a_high = a_size >> 16;
    uint32_t b_lo = b_size & 0xFFFF;
    uint32_t b_high = b_size >> 16;

    // 每個 16x16 乘積都裝得進 32 位元，組合時才轉成 64 位元
    uint32_t low = a_lo * b_lo;
    uint32_t middle1 = a_high * b_lo;
    uint32_t middle2 = b_high * a_lo;
    uint32_t high = a_high * b_high;

    uint64_t product = (uint64_t) low + ((uint64_t) middle1 << 16) +
                       ((uint64_t) middle2 << 16) + ((uint64_t) high << 32);

    if (sign) {
        product = -product;
    }

    // rounded +最小位數的一半 在捨去
    uint64_t rounded = product + (1U << 19);

    return (int32_t) (uint32_t) (rounded >> 20);
}
