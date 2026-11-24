// The musl body's first static program (EmoOS plan B, T2.2): malloc,
// printf and getenv over the gate. The output is the T2.2 metal proof;
// the C door's own `hello.c` stays the T1 test.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
  char *p = malloc(64);
  if (p == 0) {
    printf("malloc failed\n");
    return 1;
  }
  strcpy(p, "musl body");
  printf("hello from musl: %s %d\n", p, 42);
  if (setenv("EMO_HOME", "yes", 1) != 0) {
    printf("setenv failed\n");
    free(p);
    return 2;
  }
  const char *e = getenv("EMO_HOME");
  printf("getenv %s\n", e == 0 ? "(none)" : e);
  free(p);
  return 0;
}
