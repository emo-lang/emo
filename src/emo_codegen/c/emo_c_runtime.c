#include "emo_c_runtime.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* All string builders allocate with malloc and never free: the
   bump/arena decision (CHECK.md) is the reclamation profile this
   provisional stage documents. */
static char *emo_alloc(int64_t n) {
  char *p = malloc(n > 0 ? (size_t)n : 1);
  if (p == NULL) {
    fputs("emo: out of memory\n", stderr);
    abort();
  }
  return p;
}

/* The Float64 rendering rule shared by println and the string
   builders (the header comment spells it out); println appends the
   newline to the format instead of a second call. */
static const char *emo_f64_format(double v, bool newline) {
  if (floor(v) == v && fabs(v) < 1e16)
    return newline ? "%.1f\n" : "%.1f";
  return newline ? "%g\n" : "%g";
}

/* UTF-8 for one codepoint; Emo chars are valid by lexing. */
static int32_t emo_utf8_put(char *p, int32_t cp) {
  if (cp < 0x80) {
    p[0] = (char)cp;
    return 1;
  }
  if (cp < 0x800) {
    p[0] = (char)(0xC0 | (cp >> 6));
    p[1] = (char)(0x80 | (cp & 0x3F));
    return 2;
  }
  if (cp < 0x10000) {
    p[0] = (char)(0xE0 | (cp >> 12));
    p[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    p[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
  }
  p[0] = (char)(0xF0 | (cp >> 18));
  p[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
  p[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
  p[3] = (char)(0x80 | (cp & 0x3F));
  return 4;
}

void emo_startup(void) {
  /* Line-buffered stdout keeps program output interleaved with
     runtime diagnostics when a terminal is attached; elsewhere the
     platform default applies. */
  setvbuf(stdout, NULL, _IOLBF, 0);
}

void emo_println_str(emo_str s) {
  fwrite(s.bytes, 1, (size_t)s.len, stdout);
  fputc('\n', stdout);
}

void emo_println_i64(int64_t v) {
  printf("%" PRId64 "\n", v);
}

void emo_println_f64(double v) {
  printf(emo_f64_format(v, true), v);
}

void emo_println_bool(bool v) {
  fputs(v ? "true" : "false", stdout);
  fputc('\n', stdout);
}

void emo_println_char(int32_t v) {
  char buf[4];
  int32_t n = emo_utf8_put(buf, v);
  fwrite(buf, 1, (size_t)n, stdout);
  fputc('\n', stdout);
}

emo_str emo_str_from_i64(int64_t v) {
  char buf[24];
  int n = snprintf(buf, sizeof buf, "%" PRId64, v);
  emo_str s = {n, emo_alloc(n)};
  memcpy((char *)s.bytes, buf, (size_t)n);
  return s;
}

emo_str emo_str_from_f64(double v) {
  char buf[48];
  int n = snprintf(buf, sizeof buf, emo_f64_format(v, false), v);
  emo_str s = {n, emo_alloc(n)};
  memcpy((char *)s.bytes, buf, (size_t)n);
  return s;
}

emo_str emo_str_from_bool(bool v) {
  if (v) return (emo_str){4, "true"};
  return (emo_str){5, "false"};
}

emo_str emo_str_from_char(int32_t v) {
  char buf[4];
  int32_t n = emo_utf8_put(buf, v);
  emo_str s = {n, emo_alloc(n)};
  memcpy((char *)s.bytes, buf, (size_t)n);
  return s;
}

emo_str emo_str_concat(emo_str a, emo_str b) {
  if (a.len > INT64_MAX - b.len) abort(); /* length overflow */
  emo_str s = {a.len + b.len, emo_alloc(a.len + b.len)};
  memcpy((char *)s.bytes, a.bytes, (size_t)a.len);
  memcpy((char *)s.bytes + a.len, b.bytes, (size_t)b.len);
  return s;
}

bool emo_str_eq(emo_str a, emo_str b) {
  return a.len == b.len && memcmp(a.bytes, b.bytes, (size_t)a.len) == 0;
}

int64_t emo_div_i64(int64_t a, int64_t b) {
  if (a == INT64_MIN && b == -1) return INT64_MIN;
  return a / b;
}

int64_t emo_mod_i64(int64_t a, int64_t b) {
  if (a == INT64_MIN && b == -1) return 0;
  return a % b;
}
