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
