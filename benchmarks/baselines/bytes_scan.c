/* Reference for benchmarks/bytes_scan: 20M reads from a 256-byte buffer. */
#include <stdio.h>

int main(void) {
    unsigned char buf[256];
    for (int i = 0; i < 256; i++) buf[i] = (unsigned char)(i * 7);
    long acc = 0;
    for (long i = 0; i < 20000000; i++) acc += buf[i & 255];
    printf("%ld\n", acc);
    return 0;
}
