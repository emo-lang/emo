#include "emo_c_runtime.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Fatal runtime errors ----
   The interpreter surfaces these as E30xx diagnostics and `emo run`
   exits 70; the standalone binary prints the same shape to stderr
   and exits 70. */

#if defined(__GNUC__)
#define EMO_NORETURN __attribute__((noreturn))
#else
#define EMO_NORETURN
#endif

static EMO_NORETURN void emo_fatal(const char *message) {
  fprintf(stderr, "runtime error: %s\n", message);
  exit(70);
}

/* ---- The bump allocator (CHECK.md's provisional profile) ----
   Chunks from malloc; the bump pointer never retreats and nothing is
   ever freed — the documented leakage until the reclamation decision
   settles. Large requests get a chunk of their own. */

typedef struct emo_chunk {
  struct emo_chunk *next;
  size_t used;
  size_t cap;
  /* payload follows, 8-byte aligned */
} emo_chunk;

static emo_chunk *emo_heap = NULL;

static void *emo_alloc(size_t n) {
  n = (n + 7) & ~(size_t)7;
  if (emo_heap == NULL || emo_heap->cap - emo_heap->used < n) {
    size_t cap = n > 65536 ? n : 65536;
    emo_chunk *c = malloc(sizeof(emo_chunk) + cap);
    if (c == NULL) {
      fputs("emo: out of memory\n", stderr);
      abort();
    }
    c->next = emo_heap;
    c->used = 0;
    c->cap = cap;
    emo_heap = c;
  }
  void *p = (char *)(emo_heap + 1) + emo_heap->used;
  emo_heap->used += n;
  return p;
}

/* A cell: the header word holds the kind; the payload follows. */
typedef struct {
  uintptr_t header;
} emo_cell;

static emo_value emo_cell_new(uintptr_t kind, int64_t words) {
  emo_cell *c =
      emo_alloc(sizeof(emo_cell) + (size_t)words * sizeof(emo_value));
  c->header = kind;
  return (uintptr_t)c; /* 8-byte aligned: low bits 000 */
}

static uintptr_t *emo_payload(emo_value v) {
  return (uintptr_t *)(((emo_cell *)v) + 1);
}

/* ---- Hosted startup and println ---- */

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

/* The Float64 rendering rule shared by println and the string
   builders (the header comment spells it out); println appends the
   newline to the format instead of a second call. */
static const char *emo_f64_format(double v, bool newline) {
  if (floor(v) == v && fabs(v) < 1e16)
    return newline ? "%.1f\n" : "%.1f";
  return newline ? "%g\n" : "%g";
}

void emo_println_f64(double v) {
  printf(emo_f64_format(v, true), v);
}

void emo_println_bool(bool v) {
  fputs(v ? "true" : "false", stdout);
  fputc('\n', stdout);
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

void emo_println_char(int32_t v) {
  char buf[4];
  int32_t n = emo_utf8_put(buf, v);
  fwrite(buf, 1, (size_t)n, stdout);
  fputc('\n', stdout);
}

void emo_println_byte(uint8_t v) {
  printf("%u\n", (unsigned)v);
}

/* ---- The scalar renderings ---- */

emo_str emo_str_from_i64(int64_t v) {
  char buf[24];
  int n = snprintf(buf, sizeof buf, "%" PRId64, v);
  emo_str s = {n, emo_alloc((size_t)n)};
  memcpy((char *)s.bytes, buf, (size_t)n);
  return s;
}

emo_str emo_str_from_f64(double v) {
  char buf[48];
  int n = snprintf(buf, sizeof buf, emo_f64_format(v, false), v);
  emo_str s = {n, emo_alloc((size_t)n)};
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
  emo_str s = {n, emo_alloc((size_t)n)};
  memcpy((char *)s.bytes, buf, (size_t)n);
  return s;
}

emo_str emo_str_concat(emo_str a, emo_str b) {
  if (a.len > INT64_MAX - b.len) abort(); /* length overflow */
  emo_str s = {a.len + b.len, emo_alloc((size_t)(a.len + b.len))};
  memcpy((char *)s.bytes, a.bytes, (size_t)a.len);
  memcpy((char *)s.bytes + a.len, b.bytes, (size_t)b.len);
  return s;
}

bool emo_str_eq(emo_str a, emo_str b) {
  return a.len == b.len && memcmp(a.bytes, b.bytes, (size_t)a.len) == 0;
}

const char *emo_str_cstr(emo_str s) {
  char *p = emo_alloc(s.len + 1);
  memcpy(p, s.bytes, (size_t)s.len);
  p[s.len] = '\0';
  return p;
}

emo_str emo_str_from_cstr(const char *cs) {
  size_t n = strlen(cs);
  char *p = emo_alloc((int64_t)n);
  memcpy(p, cs, n);
  emo_str s = {(int64_t)n, p};
  return s;
}

/* ---- The dynamic world ---- */

static const char *emo_wrong_type =
    "a value of the wrong type was used where a type was expected";

static emo_value emo_box_kind(uintptr_t kind, int64_t payload) {
  emo_value v = emo_cell_new(kind, 1);
  *emo_payload(v) = (uintptr_t)payload;
  return v;
}

emo_value emo_box_i64(int64_t v) { return emo_box_kind(EMO_INT64, v); }

emo_value emo_box_f64(double v) {
  int64_t bits;
  memcpy(&bits, &v, sizeof bits);
  return emo_box_kind(EMO_FLOAT64, bits);
}

emo_value emo_vbool(bool v) { return (uintptr_t)(v ? 0b1001 : 0b0001); }

emo_value emo_vchar(int32_t v) {
  return ((uintptr_t)(uint32_t)v << 3) | 0b011;
}

emo_value emo_box_str(emo_str s) {
  /* The cell: [header][len][bytes...] — the bytes share the cell, so
     the borrowed emo_str below stays valid for the program's life. */
  emo_value v = emo_cell_new(EMO_STRING, 1 + (s.len + 7) / 8);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)s.len;
  memcpy(p + 1, s.bytes, (size_t)s.len);
  return v;
}

static uintptr_t emo_cell_kind(emo_value v) {
  if ((v & 7) != 0) return 0;
  return ((emo_cell *)v)->header;
}

static emo_value emo_expect_kind(emo_value v, uintptr_t kind) {
  if (emo_cell_kind(v) != kind) emo_fatal(emo_wrong_type);
  return v;
}

int64_t emo_unbox_i64(emo_value v) {
  return (int64_t)*emo_payload(emo_expect_kind(v, EMO_INT64));
}

double emo_unbox_f64(emo_value v) {
  int64_t bits = (int64_t)*emo_payload(emo_expect_kind(v, EMO_FLOAT64));
  double d;
  memcpy(&d, &bits, sizeof d);
  return d;
}

emo_str emo_str_of(emo_value v) {
  v = emo_expect_kind(v, EMO_STRING);
  uintptr_t *p = emo_payload(v);
  emo_str s = {(int64_t)p[0], (const char *)(p + 1)};
  return s;
}

bool emo_bool_of(emo_value v) {
  if ((v & 7) != 0b001) emo_fatal(emo_wrong_type);
  return (v >> 3) != 0;
}

int32_t emo_char_of(emo_value v) {
  if ((v & 7) != 0b011) emo_fatal(emo_wrong_type);
  return (int32_t)(uint32_t)(v >> 3);
}

emo_value emo_tuple_new(int64_t arity, emo_value *elems) {
  /* [header][arity][elements...] */
  emo_value v = emo_cell_new(EMO_TUPLE, arity + 1);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)arity;
  for (int64_t i = 0; i < arity; i++) p[i + 1] = (uintptr_t)elems[i];
  return v;
}

emo_value emo_array_new(int64_t len, emo_value *elems) {
  /* [header][len][elements...] */
  emo_value v = emo_cell_new(EMO_ARRAY, len + 1);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)len;
  for (int64_t i = 0; i < len; i++) p[i + 1] = (uintptr_t)elems[i];
  return v;
}

emo_value emo_array_append(emo_value arr, emo_value v) {
  int64_t n = emo_length(arr);
  emo_value out = emo_cell_new(EMO_ARRAY, n + 2);
  uintptr_t *p = emo_payload(out);
  p[0] = (uintptr_t)(n + 1);
  for (int64_t i = 0; i < n; i++) p[i + 1] = emo_payload(arr)[i + 1];
  p[n + 1] = (uintptr_t)v;
  return out;
}

emo_value emo_box_new(emo_value v) {
  return emo_box_kind(EMO_BOX, (int64_t)v);
}

emo_value emo_box_read(emo_value box) {
  box = emo_expect_kind(box, EMO_BOX);
  return (emo_value)*emo_payload(box);
}

emo_value emo_box_replace(emo_value box, emo_value v) {
  box = emo_expect_kind(box, EMO_BOX);
  uintptr_t *p = emo_payload(box);
  emo_value old = (emo_value)*p;
  *p = (uintptr_t)v;
  return old;
}

/* ---- Instances (T24.5) ---- */

emo_value emo_instance_new(const emo_vtable *vt, int64_t nfields) {
  /* [header][vtable][fields...] */
  emo_value v = emo_cell_new(EMO_INSTANCE, nfields + 1);
  *emo_payload(v) = (uintptr_t)vt;
  return v;
}

const emo_vtable *emo_vtable_of(emo_value instance) {
  instance = emo_expect_kind(instance, EMO_INSTANCE);
  return (const emo_vtable *)*emo_payload(instance);
}

emo_value emo_instance_field(emo_value instance, int64_t i) {
  instance = emo_expect_kind(instance, EMO_INSTANCE);
  if (i < 0 || i >= (int64_t)((const emo_vtable *)*emo_payload(instance))->field_count)
    emo_fatal("a field index is out of range for its class");
  return (emo_value)emo_payload(instance)[i + 1];
}

void emo_set_field(emo_value instance, int64_t i, emo_value v) {
  instance = emo_expect_kind(instance, EMO_INSTANCE);
  if (i < 0 || i >= (int64_t)((const emo_vtable *)*emo_payload(instance))->field_count)
    emo_fatal("a field index is out of range for its class");
  emo_payload(instance)[i + 1] = (uintptr_t)v;
}

bool emo_is_class(emo_value instance, const emo_vtable *vt) {
  if (emo_cell_kind(instance) != EMO_INSTANCE) return false;
  return (const emo_vtable *)*emo_payload(instance) == vt;
}

bool emo_is_iface(emo_value instance, const emo_iface *ifc) {
  if (emo_cell_kind(instance) != EMO_INSTANCE) return false;
  const emo_vtable *vt = (const emo_vtable *)*emo_payload(instance);
  for (int64_t i = 0; i < ifc->method_count; i++) {
    bool found = false;
    for (int64_t j = 0; j < vt->method_count; j++) {
      if (strcmp(vt->methods[j].method_name, ifc->methods[i].method_name) == 0 &&
          vt->methods[j].method_arity == ifc->methods[i].method_arity) {
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return true;
}

/* ---- Enums (T24.5) ---- */

emo_value emo_enum_new(const char *enum_name, const char *member) {
  size_t elen = strlen(enum_name), mlen = strlen(member);
  /* [header][elen][ebytes...][mlen][mbytes...] — one byte per char in
     words, len words each */
  emo_value v = emo_cell_new(EMO_ENUM, 2 + (int64_t)((elen + 7) / 8) +
                                       1 + (int64_t)((mlen + 7) / 8));
  uintptr_t *p = emo_payload(v);
  *p++ = elen;
  memcpy(p, enum_name, elen);
  p += (elen + 7) / 8;
  *p++ = mlen;
  memcpy(p, member, mlen);
  return v;
}

static bool emo_enum_words_equal(uintptr_t *p, const char *s) {
  uintptr_t len = *p;
  if (len != strlen(s)) return false;
  return memcmp(p + 1, s, len) == 0;
}

bool emo_enum_is(emo_value v, const char *enum_name, const char *member) {
  if (emo_cell_kind(v) != EMO_ENUM) return false;
  uintptr_t *p = emo_payload(v);
  if (!emo_enum_words_equal(p, enum_name)) return false;
  p += 1 + (*p + 7) / 8;
  return emo_enum_words_equal(p, member);
}

/* ---- Closures (T24.5) ---- */

emo_value emo_closure_new(emo_closure_fn fn, int64_t ncaps,
                          const emo_value *caps) {
  /* [header][fn][captured...] */
  emo_value v = emo_cell_new(EMO_CLOSURE, ncaps + 1);
  uintptr_t *p = emo_payload(v);
  *p++ = (uintptr_t)fn;
  for (int64_t i = 0; i < ncaps; i++) *p++ = (uintptr_t)caps[i];
  return v;
}

emo_closure_fn emo_closure_fn_of(emo_value closure) {
  closure = emo_expect_kind(closure, EMO_CLOSURE);
  return (emo_closure_fn)*emo_payload(closure);
}

emo_value emo_closure_get(emo_value closure, int64_t i) {
  closure = emo_expect_kind(closure, EMO_CLOSURE);
  return (emo_value)emo_payload(closure)[i + 1];
}

emo_value emo_closure_call0(emo_value f) {
  emo_closure_fn fn = emo_closure_fn_of(f);
  return fn(f, NULL);
}

emo_value emo_closure_call1(emo_value f, emo_value a) {
  emo_closure_fn fn = emo_closure_fn_of(f);
  emo_value args[1] = {(uintptr_t)a};
  return fn(f, args);
}

emo_value emo_closure_call2(emo_value f, emo_value a, emo_value b) {
  emo_closure_fn fn = emo_closure_fn_of(f);
  emo_value args[2] = {(uintptr_t)a, (uintptr_t)b};
  return fn(f, args);
}

emo_value emo_closure_call3(emo_value f, emo_value a, emo_value b, emo_value c) {
  emo_closure_fn fn = emo_closure_fn_of(f);
  emo_value args[3] = {(uintptr_t)a, (uintptr_t)b, (uintptr_t)c};
  return fn(f, args);
}

emo_value emo_closure_call4(emo_value f, emo_value a, emo_value b, emo_value c,
                            emo_value d) {
  emo_closure_fn fn = emo_closure_fn_of(f);
  emo_value args[4] = {(uintptr_t)a, (uintptr_t)b, (uintptr_t)c, (uintptr_t)d};
  return fn(f, args);
}

/* A tuple and an array index and measure alike: both keep their
   length in the first payload word. */

static bool emo_is_sequence(emo_value v) {
  uintptr_t k = emo_cell_kind(v);
  return k == EMO_TUPLE || k == EMO_ARRAY;
}

emo_value emo_index(emo_value v, int64_t i) {
  if (!emo_is_sequence(v)) emo_fatal("only tuples and arrays are indexable");
  int64_t n = emo_length(v);
  if (i < 0 || i >= n) {
    fprintf(stderr,
            "runtime error: index %lld is out of bounds for a length-%lld "
            "%s\n",
            (long long)i, (long long)n,
            emo_cell_kind(v) == EMO_TUPLE ? "tuple" : "array");
    exit(70);
  }
  return (emo_value)emo_payload(v)[i + 1];
}

int64_t emo_length(emo_value v) {
  if (!emo_is_sequence(v)) emo_fatal("only tuples and arrays have a length");
  return (int64_t)*emo_payload(v);
}

bool emo_is_tuple(emo_value v) { return emo_cell_kind(v) == EMO_TUPLE; }

static int64_t emo_length_bytes(emo_value v) {
  return (int64_t)*emo_payload(v);
}

void emo_raise(emo_value v) {
  emo_str s = emo_to_string_dyn(v);
  fprintf(stderr, "uncaught exception: %.*s\n", (int)s.len, s.bytes);
  exit(1);
}

void emo_no_match(void) {
  emo_fatal("no pattern matched the case scrutinee");
}

emo_value emo_send(emo_value recv, const char *name, int64_t arity,
                   const emo_value *args) {
  const emo_vtable *vt = emo_vtable_of(recv);
  for (int64_t i = 0; i < vt->method_count; i++) {
    if (strcmp(vt->methods[i].method_name, name) == 0 &&
        vt->methods[i].method_arity == arity) {
      if (vt->methods[i].thunk == NULL)
        emo_fatal("message not understood");
      return vt->methods[i].thunk(recv, args);
    }
  }
  fprintf(stderr, "runtime error: message not understood: %s/%lld\n", name,
          (long long)arity);
  exit(70);
}

/* ---- Dynamic operations ----
   The interpreter's runtime rules: arithmetic and comparisons need
   the same kind on both sides (int64 with int64, float64 with
   float64, string with string for `+`), equality is structural. */

emo_value emo_add_dyn(emo_value a, emo_value b) {
  uintptr_t ka = emo_cell_kind(a), kb = emo_cell_kind(b);
  if (ka == EMO_STRING && kb == EMO_STRING)
    return emo_box_str(emo_str_concat(emo_str_of(a), emo_str_of(b)));
  if (ka == EMO_INT64 && kb == EMO_INT64) {
    int64_t r = (int64_t)((uint64_t)emo_unbox_i64(a) +
                          (uint64_t)emo_unbox_i64(b));
    return emo_box_i64(r);
  }
  if (ka == EMO_FLOAT64 && kb == EMO_FLOAT64)
    return emo_box_f64(emo_unbox_f64(a) + emo_unbox_f64(b));
  emo_fatal("`+` needs two numbers or two strings");
}

static emo_value emo_arith_dyn(emo_value a, emo_value b, char op) {
  uintptr_t ka = emo_cell_kind(a), kb = emo_cell_kind(b);
  if (ka == EMO_INT64 && kb == EMO_INT64) {
    int64_t x = emo_unbox_i64(a), y = emo_unbox_i64(b), r;
    switch (op) {
    case '-': r = (int64_t)((uint64_t)x - (uint64_t)y); break;
    case '*': r = (int64_t)((uint64_t)x * (uint64_t)y); break;
    case '/': r = emo_div_i64(x, y); break;
    default: r = emo_mod_i64(x, y); break;
    }
    return emo_box_i64(r);
  }
  if (ka == EMO_FLOAT64 && kb == EMO_FLOAT64) {
    double x = emo_unbox_f64(a), y = emo_unbox_f64(b);
    switch (op) {
    case '-': return emo_box_f64(x - y);
    case '*': return emo_box_f64(x * y);
    case '/': return emo_box_f64(x / y);
    default: return emo_box_f64(0.0 / 0.0); /* `%` on floats is refused */
    }
  }
  emo_fatal("arithmetic needs two values of the same numeric type");
}

emo_value emo_sub_dyn(emo_value a, emo_value b) {
  return emo_arith_dyn(a, b, '-');
}

emo_value emo_mul_dyn(emo_value a, emo_value b) {
  return emo_arith_dyn(a, b, '*');
}

emo_value emo_div_dyn(emo_value a, emo_value b) {
  return emo_arith_dyn(a, b, '/');
}

emo_value emo_mod_dyn(emo_value a, emo_value b) {
  return emo_arith_dyn(a, b, '%');
}

emo_value emo_neg_dyn(emo_value v) {
  if (emo_cell_kind(v) == EMO_INT64)
    return emo_box_i64((int64_t)(0ULL - (uint64_t)emo_unbox_i64(v)));
  if (emo_cell_kind(v) == EMO_FLOAT64) return emo_box_f64(-emo_unbox_f64(v));
  emo_fatal("unary minus needs a number");
}

bool emo_eq_dyn(emo_value a, emo_value b) {
  if (a == b) return true;
  bool ap = (a & 7) == 0, bp = (b & 7) == 0;
  if (ap != bp) return false;
  if (!ap) return false; /* distinct immediates differ */
  emo_cell *ca = (emo_cell *)a, *cb = (emo_cell *)b;
  if (ca->header != cb->header) return false;
  switch (ca->header) {
  case EMO_INT64: return emo_unbox_i64(a) == emo_unbox_i64(b);
  case EMO_FLOAT64: return emo_unbox_f64(a) == emo_unbox_f64(b);
  case EMO_STRING: return emo_str_eq(emo_str_of(a), emo_str_of(b));
  case EMO_TUPLE:
  case EMO_ARRAY: {
    int64_t na = emo_length(a), nb = emo_length(b);
    if (na != nb) return false;
    for (int64_t i = 0; i < na; i++)
      if (!emo_eq_dyn((emo_value)emo_payload(a)[i + 1],
                      (emo_value)emo_payload(b)[i + 1]))
        return false;
    return true;
  }
  case EMO_BOX: return emo_eq_dyn(emo_box_read(a), emo_box_read(b));
  case EMO_INSTANCE: {
    /* Same class (vtable identity) and equal fields. */
    if (*emo_payload(a) != *emo_payload(b)) return false;
    int64_t n = ((const emo_vtable *)*emo_payload(a))->field_count;
    for (int64_t i = 0; i < n; i++)
      if (!emo_eq_dyn((emo_value)emo_payload(a)[i + 1],
                      (emo_value)emo_payload(b)[i + 1]))
        return false;
    return true;
  }
  case EMO_ENUM: {
    /* [elen][ebytes...][mlen][mbytes...] compared by name */
    uintptr_t *pa = emo_payload(a), *pb = emo_payload(b);
    uintptr_t elen = *pa, elen_b = *pb;
    if (elen != elen_b) return false;
    uintptr_t skip = 1 + (elen + 7) / 8;
    uintptr_t mlen = pa[skip], mlen_b = pb[skip];
    if (mlen != mlen_b) return false;
    if (memcmp(pa + 1, pb + 1, elen) != 0) return false;
    if (memcmp(pa + skip + 1, pb + skip + 1, mlen) != 0) return false;
    return true;
  }
  case EMO_BYTES: {
    emo_str sa = emo_str_of_bytes(a), sb = emo_str_of_bytes(b);
    return sa.len == sb.len && memcmp(sa.bytes, sb.bytes, (size_t)sa.len) == 0;
  }
  case EMO_CLOSURE: return false; /* identity: distinct creations differ */
  default: return false;
  }
}

static int emo_cmp_dyn(emo_value a, emo_value b) {
  uintptr_t ka = emo_cell_kind(a), kb = emo_cell_kind(b);
  if (ka == EMO_STRING && kb == EMO_STRING) {
    emo_str sa = emo_str_of(a), sb = emo_str_of(b);
    int64_t n = sa.len < sb.len ? sa.len : sb.len;
    int r = memcmp(sa.bytes, sb.bytes, (size_t)n);
    if (r != 0) return r < 0 ? -1 : 1;
    return sa.len < sb.len ? -1 : (sa.len > sb.len ? 1 : 0);
  }
  if (ka == EMO_INT64 && kb == EMO_INT64) {
    int64_t x = emo_unbox_i64(a), y = emo_unbox_i64(b);
    return x < y ? -1 : (x > y ? 1 : 0);
  }
  if (ka == EMO_FLOAT64 && kb == EMO_FLOAT64) {
    double x = emo_unbox_f64(a), y = emo_unbox_f64(b);
    return x < y ? -1 : (x > y ? 1 : 0);
  }
  emo_fatal("comparisons need two values of the same type");
}

bool emo_lt_dyn(emo_value a, emo_value b) { return emo_cmp_dyn(a, b) < 0; }

bool emo_le_dyn(emo_value a, emo_value b) { return emo_cmp_dyn(a, b) <= 0; }

/* ---- The one stringification rule over dynamic values ---- */

/* Inside an instance's default rendering, strings show quoted and
   tuples/arrays recurse in debug form — the interpreter's
   debug_value. */
static void emo_debug_dyn(emo_value v, FILE *out);

static void emo_render_dyn(emo_value v, FILE *out) {
  if ((v & 7) == 0b001) {
    fputs((v >> 3) ? "true" : "false", out);
    return;
  }
  if ((v & 7) == 0b011) {
    char buf[4];
    int32_t n = emo_utf8_put(buf, emo_char_of(v));
    fwrite(buf, 1, (size_t)n, out);
    return;
  }
  switch (emo_cell_kind(v)) {
  case EMO_INT64:
    fprintf(out, "%" PRId64, emo_unbox_i64(v));
    return;
  case EMO_FLOAT64: {
    double d = emo_unbox_f64(v);
    fprintf(out, emo_f64_format(d, false), d);
    return;
  }
  case EMO_STRING: {
    emo_str s = emo_str_of(v);
    fwrite(s.bytes, 1, (size_t)s.len, out);
    return;
  }
  case EMO_TUPLE:
  case EMO_ARRAY: {
    bool tuple = emo_cell_kind(v) == EMO_TUPLE;
    fputc(tuple ? '(' : '[', out);
    int64_t n = emo_length(v);
    for (int64_t i = 0; i < n; i++) {
      if (i > 0) fputs(", ", out);
      emo_render_dyn((emo_value)emo_payload(v)[i + 1], out);
    }
    fputc(tuple ? ')' : ']', out);
    return;
  }
  case EMO_BOX:
    fputs("<box>", out);
    return;
  case EMO_ENUM: {
    /* the member name only — the interpreter's EnumMember rendering */
    uintptr_t *p = emo_payload(v);
    uintptr_t skip = 1 + (*p + 7) / 8;
    fwrite(p + skip + 1, 1, p[skip], out);
    return;
  }
  case EMO_INSTANCE: {
    const emo_vtable *vt = (const emo_vtable *)*emo_payload(v);
    fprintf(out, "#%s(", vt->class_name);
    for (int64_t i = 0; i < vt->field_count; i++) {
      if (i > 0) fputs(", ", out);
      fprintf(out, "%s: ", vt->field_names[i]);
      emo_debug_dyn((emo_value)emo_payload(v)[i + 1], out);
    }
    fputc(')', out);
    return;
  }
  case EMO_CLOSURE:
    fputs("<block>", out);
    return;
  case EMO_BYTES:
    fprintf(out, "Bytes[%lld]", (long long)emo_length_bytes(v));
    return;
  default:
    fputs("<value>", out);
    return;
  }
}

static void emo_debug_dyn(emo_value v, FILE *out) {
  if ((v & 7) == 0 && emo_cell_kind(v) == EMO_STRING) {
    /* quoted, control characters escaped; UTF-8 bytes stay raw */
    emo_str s = emo_str_of(v);
    fputc('"', out);
    for (int64_t i = 0; i < s.len; i++) {
      unsigned char c = (unsigned char)s.bytes[i];
      if (c == '"' || c == '\\') fprintf(out, "\\%c", c);
      else if (c < 0x20) fprintf(out, "\\%03o", c);
      else fputc((char)c, out);
    }
    fputc('"', out);
    return;
  }
  if ((v & 7) == 0 && emo_cell_kind(v) == EMO_TUPLE) {
    fputc('(', out);
    int64_t n = emo_length(v);
    for (int64_t i = 0; i < n; i++) {
      if (i > 0) fputs(", ", out);
      emo_debug_dyn((emo_value)emo_payload(v)[i + 1], out);
    }
    fputc(')', out);
    return;
  }
  if ((v & 7) == 0 && emo_cell_kind(v) == EMO_ARRAY) {
    fputc('[', out);
    int64_t n = emo_length(v);
    for (int64_t i = 0; i < n; i++) {
      if (i > 0) fputs(", ", out);
      emo_debug_dyn((emo_value)emo_payload(v)[i + 1], out);
    }
    fputc(']', out);
    return;
  }
  emo_render_dyn(v, out);
}

emo_str emo_to_string_dyn(emo_value v) {
  char *buf = NULL;
  size_t len = 0;
  FILE *f = open_memstream(&buf, &len);
  if (f == NULL) abort();
  emo_render_dyn(v, f);
  fclose(f);
  emo_str s = {(int64_t)len, buf};
  return s;
}

void emo_println_dyn(emo_value v) {
  emo_render_dyn(v, stdout);
  fputc('\n', stdout);
}

emo_str emo_to_string_method(emo_value v) {
  if (emo_cell_kind(v) == EMO_BYTES) return emo_str_of_bytes(v);
  return emo_to_string_dyn(v);
}

/* ---- The integer core ---- */

int64_t emo_div_i64(int64_t a, int64_t b) {
  if (b == 0) emo_fatal("division by zero");
  if (a == INT64_MIN && b == -1) return INT64_MIN;
  return a / b;
}

int64_t emo_mod_i64(int64_t a, int64_t b) {
  if (b == 0) emo_fatal("division by zero");
  if (a == INT64_MIN && b == -1) return 0;
  return a % b;
}

/* ---- The systems layer ---- */

emo_value emo_bytes_new(int64_t len) {
  /* [header][len][bytes...] — zero-filled by the bump allocator's
     fresh malloc? malloc does not zero: clear explicitly. */
  emo_value v = emo_cell_new(EMO_BYTES, 1 + (len + 7) / 8);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)len;
  memset(p + 1, 0, (size_t)len);
  return v;
}

int64_t emo_bytes_length(emo_value b) {
  b = emo_expect_kind(b, EMO_BYTES);
  return (int64_t)*emo_payload(b);
}

static unsigned char *emo_bytes_ptr(emo_value b, int64_t i, int64_t width,
                                    const char *op) {
  b = emo_expect_kind(b, EMO_BYTES);
  int64_t n = (int64_t)*emo_payload(b);
  if (i < 0 || i + width > n) {
    fprintf(stderr,
            "runtime error: index %lld is out of bounds for a %s on a "
            "length-%lld Bytes\n",
            (long long)i, op, (long long)n);
    exit(70);
  }
  return (unsigned char *)(emo_payload(b) + 1) + i;
}

int64_t emo_bytes_get(emo_value b, int64_t i) {
  return (int64_t)*emo_bytes_ptr(b, i, 1, "get");
}

int64_t emo_bytes_set(emo_value b, int64_t i, int64_t v) {
  if (v < 0 || v > 255) {
    fprintf(stderr,
            "runtime error: byte value %lld is out of range for a byte "
            "(0-255)\n",
            (long long)v);
    exit(70);
  }
  *emo_bytes_ptr(b, i, 1, "set") = (unsigned char)v;
  return v;
}

emo_value emo_bytes_of_str(emo_str s) {
  emo_value v = emo_cell_new(EMO_BYTES, 1 + (s.len + 7) / 8);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)s.len;
  memcpy(p + 1, s.bytes, (size_t)s.len);
  return v;
}

emo_str emo_str_of_bytes(emo_value b) {
  b = emo_expect_kind(b, EMO_BYTES);
  uintptr_t *p = emo_payload(b);
  emo_str s = {(int64_t)p[0], (const char *)(p + 1)};
  return s;
}

int64_t emo_bytes_get_u16_le(emo_value b, int64_t i) {
  unsigned char *p = emo_bytes_ptr(b, i, 2, "get_u16_le");
  return (int64_t)(p[0] | (p[1] << 8));
}

int64_t emo_bytes_get_u32_le(emo_value b, int64_t i) {
  unsigned char *p = emo_bytes_ptr(b, i, 4, "get_u32_le");
  uint32_t u = 0;
  for (int k = 3; k >= 0; k--) u = (u << 8) | p[k];
  return (int64_t)u;
}

int64_t emo_bytes_get_u64_le(emo_value b, int64_t i) {
  unsigned char *p = emo_bytes_ptr(b, i, 8, "get_u64_le");
  uint64_t u = 0;
  for (int k = 7; k >= 0; k--) u = (u << 8) | p[k];
  return (int64_t)u;
}

int64_t emo_bytes_set_u16_le(emo_value b, int64_t i, int64_t v) {
  unsigned char *p = emo_bytes_ptr(b, i, 2, "set_u16_le");
  uint16_t u = (uint16_t)v;
  for (int k = 0; k < 2; k++) p[k] = (unsigned char)((u >> (8 * k)) & 0xFF);
  return (int64_t)u;
}

int64_t emo_bytes_set_u32_le(emo_value b, int64_t i, int64_t v) {
  unsigned char *p = emo_bytes_ptr(b, i, 4, "set_u32_le");
  uint32_t u = (uint32_t)v;
  for (int k = 0; k < 4; k++) p[k] = (unsigned char)((u >> (8 * k)) & 0xFF);
  return (int64_t)u;
}

int64_t emo_bytes_set_u64_le(emo_value b, int64_t i, int64_t v) {
  unsigned char *p = emo_bytes_ptr(b, i, 8, "set_u64_le");
  uint64_t u = (uint64_t)v;
  for (int k = 0; k < 8; k++) p[k] = (unsigned char)((u >> (8 * k)) & 0xFF);
  return v;
}

int64_t emo_shl_i64(int64_t a, int64_t c) {
  if (c < 0) emo_fatal("shift count must be non-negative");
  if (c >= 64) return 0;
  return (int64_t)((uint64_t)a << c);
}

int64_t emo_shr_i64(int64_t a, int64_t c) {
  if (c < 0) emo_fatal("shift count must be non-negative");
  if (c >= 64) return a < 0 ? -1 : 0;
  return a >> c; /* arithmetic on gcc/clang */
}

int64_t emo_f64_bits(double d) {
  int64_t bits;
  memcpy(&bits, &d, sizeof bits);
  return bits;
}

double emo_f64_from_bits(int64_t bits) {
  double d;
  memcpy(&d, &bits, sizeof d);
  return d;
}
