/* The Emo C runtime — hosted profile: libc plus these sources. The
   compiler emits one main.c per program, compiles it next to
   emo_c_runtime.c, and links a standalone binary with the system cc
   (plan/step-24-c-target.md). This skeleton covers hosted startup and
   println; the allocator, dynamic values, and scheduler land with
   their tasks (T24.2–T24.9). */

#ifndef EMO_C_RUNTIME_H
#define EMO_C_RUNTIME_H

#include <stdint.h>
#include <stdio.h>

/* Hosted startup: every generated main calls this first. The
   scheduler's initialization hooks in here (T24.9). */
void emo_startup(void);

/* println over stdio, one line per value. The string form takes
   NUL-terminated UTF-8 — string literals cross from Emo source
   directly; runtime-built strings get a length-prefixed
   representation in T24.3. */
void emo_println_str(const char *s);

#endif /* EMO_C_RUNTIME_H */
