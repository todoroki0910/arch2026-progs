#include "gcd.h"

/* Dummy: returns 0 for every input. Replace with the binary GCD. */
uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    if (a == 0) {
        return b;
    } else if (b == 0) {
        return a;
    }

    uint32_t shift = 0;  // gcd(2a,2b)=2* gcd(a,b)
    while (((a | b) & 1) == 0) {
        a = a >> 1;
        b = b >> 1;
        shift++;
    }

    while ((a & 1) == 0) {
        a = a >> 1;
    }

    do {
        while ((b & 1) == 0) {
            b >>= 1;
        }
        if (a > b) {
            uint32_t tem = a;
            a = b;
            b = tem;
        }
        b = b - a;

    } while (b != 0);

    return a << shift;
}
