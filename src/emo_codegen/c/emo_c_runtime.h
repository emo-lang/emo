/* The Emo C runtime — hosted profile: libc plus these sources. The
   compiler emits one main.c per program, compiles it next to
   emo_c_runtime.c, and links a standalone binary with the system cc
   (plan/step-24-c-target.md). This file carries hosted startup and
   println plus the integer core's wrap-around helpers (T24.2); the
   allocator, dynamic values, and scheduler land with their tasks
   (T24.4–T24.9). */

#ifndef EMO_C_RUNTIME_H
#define EMO_C_RUNTIME_H

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

/* Hosted startup: every generated main calls this first. The
   scheduler's initialization hooks in here (T24.9). */
void emo_startup(void);

/* println over stdio, one line per value. The string form takes
   NUL-terminated UTF-8 — string literals cross from Emo source
   directly; runtime-built strings get a length-prefixed
   representation in T24.3. The integer form is exact over the full
   Int64 range, INT64_MIN included. */
void emo_println_str(const char *s);
void emo_println_i64(int64_t v);

/* Wrap-around Int64 division and remainder: INT64_MIN / -1 wraps to
   INT64_MIN with remainder 0 — signed division there is undefined in
   C, so the runtime guards it. Every other case matches C's signed
   semantics, which equal Emo's. */
int64_t emo_div_i64(int64_t a, int64_t b);
int64_t emo_mod_i64(int64_t a, int64_t b);

#endif /* EMO_C_RUNTIME_H */
