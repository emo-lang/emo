// The C library's conformance probe (EmoOS plan B, T2.4): the calls
// the milestone carries, printed as deterministic lines the host's C
// library and the metal's EmoOS library can be compared on byte for
// byte. The float formats stay out: T2.2's quad helpers are stubs.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int one(int v) {
  return v ? 1 : 0;
}

static int sign(int v) {
  return v < 0 ? -1 : v > 0 ? 1 : 0;
}

int main(void) {
  puts("conformance start");

  printf("printf d %d\n", -42);
  printf("printf u %u\n", 42u);
  printf("printf x %x\n", 0x2a);
  printf("printf o %o\n", 052);
  printf("printf c %c\n", 'Z');
  printf("printf s %s\n", "hello");
  printf("printf width [%5d][%-5d][%05d][%+d][% d]\n", 42, 42, 42, 42, 42);
  printf("printf prec [%.3s][%5.2s][%#x][%#o]\n", "abcdef", "abcdef", 42, 052);
  printf("printf long %ld %lu %lld\n", -42L, 42UL, -42LL);
  printf("printf percent %%\n");
  printf("puts ");
  puts("line");
  fputs("fputs line\n", stdout);
  fwrite("fwrite line\n", 1, 12, stdout);
  fflush(stdout);

  printf("string len %d\n", (int)strlen("conformance"));
  printf("string cmp %d %d %d\n", sign(strcmp("a", "b")),
         sign(strcmp("a", "a")), sign(strcmp("b", "a")));
  printf("string ncmp %d %d\n", one(strncmp("abcX", "abcY", 3) == 0),
         one(strncmp("abcX", "abdY", 3) < 0));
  char s[32];
  strcpy(s, "one");
  strcat(s, "-two");
  printf("string cat %s\n", s);
  printf("string chr %d %d\n", one(strchr(s, '-') != 0),
         one(strrchr(s, 'o') != 0));
  printf("string str %d\n", one(strstr("one-two-three", "two") != 0));
  printf("string span %d %d\n", (int)strspn("abc123", "abc"),
         (int)strcspn("abc123", "123"));

  char m[8];
  memset(m, 'x', 5);
  m[5] = 0;
  printf("string memset %s\n", m);
  char src[8] = "abcdefg";
  char dst[8];
  memcpy(dst, src, 8);
  printf("string memcpy %d\n", one(memcmp(dst, src, 8) == 0));
  memmove(dst + 1, dst, 4);
  dst[5] = 0;
  printf("string memmove %s\n", dst);

  void *p = malloc(64);
  printf("malloc alloc %d\n", one(p != 0));
  printf("malloc align %d\n", one(((uintptr_t)p & 15) == 0));
  if (p != 0) {
    memset(p, 'a', 64);
  }
  void *q = realloc(p, 128);
  printf("malloc realloc %d\n",
         one(q != 0 && ((char *)q)[0] == 'a' && ((char *)q)[63] == 'a'));
  free(q);
  void *z = malloc(0);
  printf("malloc zero %d\n", one(z != 0));
  free(z);
  printf("malloc free %d\n", 1);

  unsetenv("EMO_CONF_PROBE");
  printf("getenv missing %d\n", one(getenv("EMO_CONF_PROBE") == 0));
  printf("getenv set %d\n",
         one(setenv("EMO_CONF_PROBE", "yes", 1) == 0));
  const char *e = getenv("EMO_CONF_PROBE");
  printf("getenv value %s\n", e != 0 ? e : "(none)");
  printf("getenv overwrite %d\n",
         one(setenv("EMO_CONF_PROBE", "no", 1) == 0 &&
             getenv("EMO_CONF_PROBE") != 0 &&
             strcmp(getenv("EMO_CONF_PROBE"), "no") == 0));
  printf("getenv unset %d\n",
         one(unsetenv("EMO_CONF_PROBE") == 0 &&
             getenv("EMO_CONF_PROBE") == 0));

  errno = 0;
  int r = setenv("", "x", 1);
  printf("errno setenv %d %d\n", one(r != 0), errno);

  puts("conformance end");
  return 0;
}
