/* The build-system probe (T4.3): a program the three front ends build
 * through the sysroot; its bytes are the same whichever built it. */
#include <unistd.h>

int main(void) {
  write(1, "build probe ok\n", 15);
  return 0;
}
