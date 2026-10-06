/* The Emo C runtime — hosted profile: libc plus these sources. The
   compiler emits one main.c per program, compiles it next to
   emo_c_runtime.c, and links a standalone binary with the system cc
   (plan/step-24-c-target.md). This file carries hosted startup,
   println, the integer core's wrap-around helpers (T24.2), and the
   scalar runtime — length-prefixed strings, Float64 rendering, Bool
   and Char (T24.3). The dynamic value model and its allocator arrive
   with T24.4; until then the string builders below allocate with
   malloc and the results leak by design (CHECK.md: bump/arena is the
   provisional reclamation profile). */

#ifndef EMO_C_RUNTIME_H
#define EMO_C_RUNTIME_H

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

/* A String value: length-prefixed bytes, no NUL terminator — NUL is
   added only when a string crosses the FFI boundary (T24.8). Passed
   by value; literals are (emo_str){len, "..."} compound literals. */
typedef struct {
  int64_t len;
  const char *bytes;
} emo_str;

/* Hosted startup: every generated main calls this first. The
   scheduler's initialization hooks in here (T24.9). */
void emo_startup(void);

/* println over stdio, one line per value. The integer form is exact
   over the full Int64 range, INT64_MIN included. */
void emo_println_str(emo_str s);
void emo_println_i64(int64_t v);
void emo_println_f64(double v);
void emo_println_bool(bool v);
void emo_println_char(int32_t v);

/* The scalar renderings a string interpolation and to_string() lower
   to. The Float64 rule matches the interpreter's emo_to_string:
   integral magnitudes below 1e16 keep one decimal ("2.0"); anything
   else goes through %g (six significant digits, exponent form below
   1e-4 and at 1e6 and above, two-digit signed exponent). */
emo_str emo_str_from_i64(int64_t v);
emo_str emo_str_from_f64(double v);
emo_str emo_str_from_bool(bool v);
emo_str emo_str_from_char(int32_t v);

/* Concatenation and content equality. */
emo_str emo_str_concat(emo_str a, emo_str b);
bool emo_str_eq(emo_str a, emo_str b);

/* Wrap-around Int64 division and remainder: INT64_MIN / -1 wraps to
   INT64_MIN with remainder 0 — signed division there is undefined in
   C, so the runtime guards it. Every other case matches C's signed
   semantics, which equal Emo's. */
int64_t emo_div_i64(int64_t a, int64_t b);
int64_t emo_mod_i64(int64_t a, int64_t b);

#endif /* EMO_C_RUNTIME_H */
