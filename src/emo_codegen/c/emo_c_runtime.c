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
  default:
    fputs("<value>", out);
    return;
  }
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

/* ---- The integer core ---- */

int64_t emo_div_i64(int64_t a, int64_t b) {
  if (a == INT64_MIN && b == -1) return INT64_MIN;
  return a / b;
}

int64_t emo_mod_i64(int64_t a, int64_t b) {
  if (a == INT64_MIN && b == -1) return 0;
  return a % b;
}
