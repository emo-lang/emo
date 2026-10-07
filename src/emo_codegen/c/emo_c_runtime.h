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

/* Generated metadata tables an unused interface leaves unreferenced. */
#if defined(__GNUC__)
#define EMO_META_UNUSED __attribute__((unused))
#else
#define EMO_META_UNUSED
#endif

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
  EMO_BOX,
  EMO_INSTANCE,
  EMO_ENUM,
  EMO_CLOSURE,
  EMO_BYTES
};

/* A class's compile-time vtable: every generated program defines one
   static vtable per class (T24.5), stored in the instance cell.
   Identity is vtable-pointer equality; `is(Interface)` matches
   structurally against the method name/arity list. */
typedef struct {
  const char *method_name;
  int32_t method_arity; /* parameters, self excluded */
  /* The dynamic-convention thunk for runtime dispatch (interface and
     Unknown receivers): NULL on interface contract entries. */
  emo_value (*thunk)(emo_value self, const emo_value *args);
} emo_method_sig;

typedef struct {
  const char *class_name; /* the source-level display name */
  int64_t method_count;
  const emo_method_sig *methods;
  int64_t field_count;
  const char *const *field_names; /* init-assignment order */
} emo_vtable;

/* An interface's compile-time contract: the shape `is(Interface)`
   matches against. */
typedef struct {
  const char *interface_name;
  int64_t method_count;
  const emo_method_sig *methods;
} emo_iface;

/* A closure's code: the canonical dynamic calling convention — the
   closure word itself plus the arguments as dynamic words. The
   emo_closure_callN helpers pack the arguments. */
typedef emo_value (*emo_closure_fn)(emo_value closure, const emo_value *args);

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
void emo_println_byte(uint8_t v);

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

/* The FFI boundary (T24.8): a String crossing OUT gets a
   NUL-terminated copy (the length prefix does not survive the C
   ABI); a char * coming IN is copied into a cell. */
const char *emo_str_cstr(emo_str s);
emo_str emo_str_from_cstr(const char *cs);

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
emo_value emo_array_append(emo_value arr, emo_value v); /* value semantics: a new array */
emo_value emo_box_new(emo_value v);
emo_value emo_box_read(emo_value box);
emo_value emo_box_replace(emo_value box, emo_value v);

/* Instances (T24.5): the vtable rides in the cell; fields are
   dynamic words addressed by the compile-time field index. */
emo_value emo_instance_new(const emo_vtable *vt, int64_t nfields);
const emo_vtable *emo_vtable_of(emo_value instance);
emo_value emo_instance_field(emo_value instance, int64_t i);
void emo_set_field(emo_value instance, int64_t i, emo_value v);
bool emo_is_class(emo_value instance, const emo_vtable *vt);
bool emo_is_iface(emo_value instance, const emo_iface *ifc);

/* Dynamic method dispatch: look the (name, arity) up in the
   receiver's vtable and call its thunk. A missing method is a
   runtime "message not understood" error. */
emo_value emo_send(emo_value recv, const char *name, int64_t arity,
                   const emo_value *args);

/* Sequence kind tests for pattern matching (the accessors themselves
   are fatal on the wrong kind; the tests short-circuit first). */
bool emo_is_tuple(emo_value v);

/* A case expression with no matching branch. */
void emo_no_match(void);

/* An uncaught raise (T24.6): render the value like the interpreter's
   E3010 and exit 1. `begin`/`catch`/`ensure` is unscheduled — until
   then every raise terminates the process, so no unwinder exists. */
void emo_raise(emo_value v);

/* Enums (T24.5): a member is (enum name, member name), compared and
   rendered by name — no data on members (a carrying tag rides in a
   tuple). */
emo_value emo_enum_new(const char *enum_name, const char *member);
bool emo_enum_is(emo_value v, const char *enum_name, const char *member);

/* Closures (T24.5): [header][fn][captured...]. Creation and the
   call sites agree on the arity syntactically. */
emo_value emo_closure_new(emo_closure_fn fn, int64_t ncaps, const emo_value *caps);
emo_closure_fn emo_closure_fn_of(emo_value closure);
emo_value emo_closure_get(emo_value closure, int64_t i);
emo_value emo_closure_call0(emo_value f);
emo_value emo_closure_call1(emo_value f, emo_value a);
emo_value emo_closure_call2(emo_value f, emo_value a, emo_value b);
emo_value emo_closure_call3(emo_value f, emo_value a, emo_value b, emo_value c);
emo_value emo_closure_call4(emo_value f, emo_value a, emo_value b, emo_value c,
                            emo_value d);

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
   renderings, plus tuples "(a, b)", arrays "[a, b]", Box as "<box>",
   enums by member name, instances as "#Name(field: value, ...)", and
   closures as "<block>" — matching the interpreter's emo_to_string. */
emo_str emo_to_string_dyn(emo_value v);
void emo_println_dyn(emo_value v);

/* The to_string METHOD over a dynamic receiver: a Bytes cell yields
   its content, every other kind renders (the interpreter dispatches
   the same way at runtime). */
emo_str emo_to_string_method(emo_value v);

/* ---- The systems layer (T24.7) ---- */

/* Bytes: a fixed-length mutable byte buffer — [header][len][bytes...].
   All indices and values are Int64 at the surface; get zero-extends,
   set rejects values outside 0-255, the little-endian accessors bound
   the whole field, and the u16/u32 setters mask the value like the
   interpreter. */
emo_value emo_bytes_new(int64_t len);
int64_t emo_bytes_length(emo_value b);
int64_t emo_bytes_get(emo_value b, int64_t i);
int64_t emo_bytes_set(emo_value b, int64_t i, int64_t v); /* returns v */
emo_value emo_bytes_of_str(emo_str s); /* copies into a cell */
emo_str emo_str_of_bytes(emo_value b); /* borrows the cell's bytes */

int64_t emo_bytes_get_u16_le(emo_value b, int64_t i);
int64_t emo_bytes_get_u32_le(emo_value b, int64_t i);
int64_t emo_bytes_get_u64_le(emo_value b, int64_t i);
int64_t emo_bytes_set_u16_le(emo_value b, int64_t i, int64_t v);
int64_t emo_bytes_set_u32_le(emo_value b, int64_t i, int64_t v);
int64_t emo_bytes_set_u64_le(emo_value b, int64_t i, int64_t v);

/* Shifts with the interpreter's rules: a negative count is a runtime
   error, a count at or past the width gives 0 (arithmetic `>>` gives
   the sign fill). */
int64_t emo_shl_i64(int64_t a, int64_t c);
int64_t emo_shr_i64(int64_t a, int64_t c);

/* Bit-casts. */
int64_t emo_f64_bits(double d);
double emo_f64_from_bits(int64_t bits);

/* ---- The integer core (T24.2) ---- */

/* Wrap-around Int64 division and remainder: INT64_MIN / -1 wraps to
   INT64_MIN with remainder 0 — signed division there is undefined in
   C, so the runtime guards it. Every other case matches C's signed
   semantics, which equal Emo's. */
int64_t emo_div_i64(int64_t a, int64_t b);
int64_t emo_mod_i64(int64_t a, int64_t b);

#endif /* EMO_C_RUNTIME_H */
