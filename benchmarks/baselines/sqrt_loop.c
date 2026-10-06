/* Reference for benchmarks/ffi_call: 10M sqrt calls in C. */
#include <math.h>
#include <stdio.h>

int main(void) {
    double acc = 4.0;
    for (long i = 0; i < 10000000; i++) acc = sqrt(acc);
    printf("%g\n", acc);
    return 0;
}
