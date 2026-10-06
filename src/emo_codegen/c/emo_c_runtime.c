#include "emo_c_runtime.h"

void emo_startup(void) {
  /* Line-buffered stdout keeps program output interleaved with
     runtime diagnostics when a terminal is attached; elsewhere the
     platform default applies. */
  setvbuf(stdout, NULL, _IOLBF, 0);
}

void emo_println_str(const char *s) {
  fputs(s, stdout);
  fputc('\n', stdout);
}

void emo_println_i64(int64_t v) {
  printf("%" PRId64 "\n", v);
}

int64_t emo_div_i64(int64_t a, int64_t b) {
  if (a == INT64_MIN && b == -1) return INT64_MIN;
  return a / b;
}

int64_t emo_mod_i64(int64_t a, int64_t b) {
  if (a == INT64_MIN && b == -1) return 0;
  return a % b;
}
