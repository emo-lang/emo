/* The Emo C runtime — hosted profile: libc plus these sources. The
   compiler emits one main.c per program, compiles it next to
   emo_c_runtime.c, and links a standalone binary with the system cc
   (plan/step-24-c-target.md). This file carries hosted startup,
   println, the integer core's wrap-around helpers (T24.2), the scalar
   runtime (T24.3), and the dynamic value model (T24.4): one tagged
   word per value, 8-byte-aligned heap cells, boxed Int64/Float64
   two-word cells, Bool/Char immediates, and the bump allocator (the
   provisional reclamation profile — CHECK.md; nothing is ever
   freed). Classes, enums, interfaces, and closures extend the cell
   kind set in T24.5. */

#ifndef EMO_C_RUNTIME_H
#define EMO_C_RUNTIME_H

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

/* A String in native (typed) positions: length-prefixed bytes, no
   NUL terminator — one is added only when a string crosses the FFI
   boundary (T24.8). Passed by value; literals are (emo_str){len,
   "..."} compound literals. */
typedef struct {
  int64_t len;
  const char *bytes;
} emo_str;

/* ---- The dynamic value model (T24.4) ----

   One machine word. Low three bits:
     000  a pointer to an 8-byte-aligned cell (kind in the header)
     001  a Bool immediate (false = 0b0001, true = 0b1001)
     011  a Char immediate (codepoint in bits 3 and up)

   A cell is [header][payload...]: the header word holds the kind.
   Int64 and Float64 are boxed two-word cells — header plus payload —
   because the full 2⁶⁴ bit patterns must be representable, so
   neither is an immediate (and there is no NaN-boxing). An immediate
   is never a valid pointer, so a future precise collector can walk
   the heap without layout churn. */
typedef uintptr_t emo_value;

enum emo_kind {
  EMO_INT64 = 1,
  EMO_FLOAT64,
  EMO_STRING,
  EMO_TUPLE,
  EMO_ARRAY,
  EMO_BOX
};

/* ---- Hosted startup and println ---- */

/* Every generated main calls this first. The scheduler's
   initialization hooks in here (T24.9). */
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

/* ---- The dynamic world (T24.4) ---- */

/* Boxing: a native scalar into the dynamic world. String copies its
   bytes into a cell; Bool and Char are immediates. */
emo_value emo_box_i64(int64_t v);
emo_value emo_box_f64(double v);
emo_value emo_box_str(emo_str s);
emo_value emo_vbool(bool v);
emo_value emo_vchar(int32_t v);

/* Unboxing: the dynamic world into a native scalar. A wrong-kind
   word is a runtime type error: printed like the interpreter's and
   the process exits 70. */
int64_t emo_unbox_i64(emo_value v);
double emo_unbox_f64(emo_value v);
emo_str emo_str_of(emo_value v); /* borrows the cell's bytes */
bool emo_bool_of(emo_value v);
int32_t emo_char_of(emo_value v);

/* Tuples, arrays, and Box. Tuples and arrays are value-semantic:
   the constructors copy the element words and equality is
   structural. A Box is the one identity: replace writes through it. */
emo_value emo_tuple_new(int64_t arity, emo_value *elems);
emo_value emo_array_new(int64_t len, emo_value *elems);
emo_value emo_box_new(emo_value v);
emo_value emo_box_read(emo_value box);
emo_value emo_box_replace(emo_value box, emo_value v);

/* Shared accessors: a tuple and an array index and measure alike. */
emo_value emo_index(emo_value v, int64_t i); /* bounds-checked */
int64_t emo_length(emo_value v);

/* Dynamic operations — the runtime dispatches the interpreter's
   semantics when the static type is Unknown. Arithmetic and
   comparisons require the same kind on both sides, `+` on two
   strings concatenates, and equality is structural. */
emo_value emo_add_dyn(emo_value a, emo_value b);
emo_value emo_sub_dyn(emo_value a, emo_value b);
emo_value emo_mul_dyn(emo_value a, emo_value b);
emo_value emo_div_dyn(emo_value a, emo_value b);
emo_value emo_mod_dyn(emo_value a, emo_value b);
emo_value emo_neg_dyn(emo_value v);
bool emo_eq_dyn(emo_value a, emo_value b);
bool emo_lt_dyn(emo_value a, emo_value b);
bool emo_le_dyn(emo_value a, emo_value b);

/* The one stringification rule over dynamic values: the scalar
   renderings, plus tuples "(a, b)", arrays "[a, b]", and Box as
   "<box>" — matching the interpreter's emo_to_string. */
emo_str emo_to_string_dyn(emo_value v);
void emo_println_dyn(emo_value v);

/* ---- The integer core (T24.2) ---- */

/* Wrap-around Int64 division and remainder: INT64_MIN / -1 wraps to
   INT64_MIN with remainder 0 — signed division there is undefined in
   C, so the runtime guards it. Every other case matches C's signed
   semantics, which equal Emo's. */
int64_t emo_div_i64(int64_t a, int64_t b);
int64_t emo_mod_i64(int64_t a, int64_t b);

#endif /* EMO_C_RUNTIME_H */
