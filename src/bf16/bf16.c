#include "bf16.h"

#define BF16_NAN 0x7FC0u
#define BF16_INF 0x7F80u
/* Dummies: every function returns 0. Replace with the real routines. */
uint16_t bf16_from_f32(uint32_t f32bits)
{
    if (((f32bits >> 23) & 0XFF) == 0xFF) {  // deal with INF NAN
        return (uint16_t) (f32bits >> 16);
    }
    f32bits += 0x7FFF + ((f32bits >> 16) & 1);

    return (uint16_t) (f32bits >> 16);
}

uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    // 要先把sign exp mag 撥出來
    // 處理 inf nan 0
    // 相乘 normalize overflow underflow
    uint16_t sign = (a ^ b) & 0x8000;
    int16_t a_exp = (a >> 7) & 0xFF;
    int16_t b_exp = (b >> 7) & 0xFF;
    uint16_t a_mant = a & 0x7F;
    uint16_t b_mant = b & 0x7F;

    if (a_exp == 0xFF) {
        if (a_mant) {
            return a;
        }
        if ((b & 0x7FFF) == 0) {
            return BF16_NAN;
        }
        return sign | BF16_INF;
    }
    if (b_exp == 0xFF) {
        if (b_mant) {
            return b;
        }
        if ((a & 0x7FFF) == 0) {
            return BF16_NAN;
        }
        return sign | BF16_INF;
    }
    if (((a & 0x7FFF) == 0) || ((b & 0x7FFF) == 0)) {
        return sign;
    }

    int32_t exp_adjust = 0;
    // deal with hidden leading one,denormalize
    if (a_exp == 0) {
        while (!(a_mant & 0x80)) {
            a_mant <<= 1;
            exp_adjust--;
        }
        a_exp = 1;

    } else {
        a_mant = a_mant | 0x80;
    }
    if (b_exp == 0) {
        while (!(b_mant & 0x80)) {
            b_mant <<= 1;
            exp_adjust--;
        }
        b_exp = 1;

    } else {
        b_mant = b_mant | 0x80;
    }
    uint32_t product = a_mant * b_mant;  //[2^14,2^16)
    int32_t exp = a_exp + b_exp - 127 + exp_adjust;

    // normalized 存最高位1 後面七個bit 當mant
    if (product & 0x8000) {
        exp++;
        product = product >> 1;
    }
    product = (product >> 7) & 0x7F;

    if (exp >= 0xFF) {
        return sign | BF16_INF;
    } else if (exp <= 0) {
        if (exp <= -6) {
            return sign;
        }
        product >>= (1 - exp);
        exp = 0;
    }
    return sign | (exp << 7) | product;
}

uint16_t bf16_sqrt(uint16_t a)
{
    uint32_t sign = (a & 0x8000);
    int32_t exp = (a >> 7) & 0xFF;
    uint32_t mant = a & 0x7F;
    // 特殊值
    if (exp == 0xFF) {
        if (mant) {
            return a;
        }
        if (sign) {
            return BF16_NAN;
        }
        return BF16_INF;
    }
    if (exp == 0) {
        if (mant == 0) {
            return 0;
        }
        if (sign) {
            return BF16_NAN;
        }
        return 0;
    }
    if (sign) {
        return BF16_NAN;
    }
    // exp 變成偶數
    uint32_t m = mant | 0x80;
    int32_t e = exp - 127;
    if (e & 1) {
        m <<= 1;
        e = ((e - 1) >> 1) + 127;
    } else {
        e = (e >> 1) + 127;
    }

    // binary search
    // m 介於[128,510]
    // 找最大的mid 使mid*mid/128<=m
    uint32_t low = 90, high = 256, result = 128;
    while (low <= high) {
        uint32_t mid = (low + high) >> 1;
        uint32_t sq = (mid * mid) >> 7;
        if (sq <= m) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    // normalize overflow underflow check [128,255]
    if (result >= 256) {
        result >>= 1;
        e++;

    } else {
        while ((result < 128) & (e > 1)) {
            result <<= 1;
            e--;
        }
    }
    if (e >= 0xFF) {
        return BF16_INF;
    }
    if (e < 0) {
        return 0;
    }
    return ((uint16_t) (e << 7) | (result & 0x7F));
}
