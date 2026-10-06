/* Reference for benchmarks/loops_tail: the same 10M-iteration counter as
   a plain C loop. */
#include <stdio.h>

int main(void) {
    long acc = 0;
    for (long i = 0; i < 10000000; i++) acc += 1;
    printf("%ld\n", acc);
    return 0;
}
