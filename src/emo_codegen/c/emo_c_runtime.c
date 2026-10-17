/* Feature macros must stand before every include: strict -std=c11
   defines __STRICT_ANSI__, and glibc then hides the POSIX surface
   (open_memstream, struct timeval, suseconds_t) unless one of these
   is set. macOS gates the same surface — and the ucontext fibers —
   behind _XOPEN_SOURCE; 700 is the level that declares
   open_memstream. */
#if defined(__APPLE__)
#define _XOPEN_SOURCE 700
#else
#define _POSIX_C_SOURCE 200809L
#endif

#include "emo_c_runtime.h"

#include <ucontext.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <dirent.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <stdarg.h>
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

/* ---- The bump allocator ----
   Chunks from malloc; the bump pointer never retreats. Since step 49
   every dynamic cell is malloc'd individually with a refcount, so the
   arena serves only native transient buffers — string bytes on their
   way into a cell, the printf buffer, cstr copies. Large requests get
   a chunk of their own. */

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

static uintptr_t *emo_payload(emo_value v) {
  return (uintptr_t *)(((emo_cell *)v) + 1);
}

/* ---- Reclamation (CHECK.md, the T23.5 gate; step 49) ----

   Reference counting over every dynamic cell. T23.5 counted the
   identity-bearing kinds — instances, closures, Box — and left the
   value families (strings, tuples, arrays, maps, lists, bytes, enums,
   boxed scalars) bump-arena resident; step 49 extends the same
   discipline to them, because a long-running program (the UI render
   loop) rebuilds exactly those kinds per frame. Every cell is now
   malloc'd individually with a refcount ahead of the header, so a
   value cell reaches zero and frees, and an aggregate's release frees
   what it holds — tuple and array elements, list nodes, map entries
   and buckets, builder item buffers. The aggregate constructors retain
   the words they store; the emitter pools expression births at
   statement boundaries and retains at every longer-lived slot. Cycles
   leak, documented (the Swift model): the immutable families are
   structurally acyclic — an element word is evaluated before its
   container exists — and the mutable identities (Box, List, Map,
   ArrayBuilder, instances, closures) can cycle only the way instances
   already could. */

typedef struct {
  int64_t rc;
  /* the emo_cell header follows */
} emo_idhead;

static int64_t emo_identity_live = 0;

/* Memory a cell owns besides its own payload — a list's struct and
   nodes, a map's entry and bucket arrays, a builder's item buffer —
   allocated here and freed by the owning cell's release. */
static void *emo_owned_alloc(size_t n) {
  void *p = malloc(n);
  if (p == NULL) {
    fputs("emo: out of memory\n", stderr);
    abort();
  }
  return p;
}

static emo_value emo_cell_new(uintptr_t kind, int64_t words) {
  /* zeroed: the field write barrier releases the previous word, so a
     fresh cell's fields must read as 0, not as malloc garbage */
  emo_idhead *h = calloc(1, sizeof(emo_idhead) + sizeof(emo_cell) +
                               (size_t)words * sizeof(emo_value));
  if (h == NULL) {
    fputs("emo: out of memory\n", stderr);
    abort();
  }
  h->rc = 1;
  emo_identity_live++;
  emo_cell *c = (emo_cell *)(h + 1);
  c->header = kind;
  return (uintptr_t)c; /* malloc alignment: low bits 000 */
}

static int64_t *emo_rc_of(emo_value v) {
  return &((emo_idhead *)((emo_cell *)v - 1))->rc;
}

static uintptr_t emo_cell_kind(emo_value v); /* defined with the accessors */

emo_value emo_retain(emo_value v) {
  if (v == 0 || (v & 7) != 0) return v; /* immediates carry no count */
  (*emo_rc_of(v))++;
  return v;
}

/* The release half is defined after the aggregate layouts it walks
   (the list, map, and builder sections): every cell frees its holdings
   at zero. The header's declaration covers the callers above. */

/* ---- Hosted startup and println ---- */

/* A measurement probe (the T49.4 gate; the spike's fuller set lives in
   spike/arena-scope/runtime/): the arena's live byte count. Since step
   49 the arena serves only native transients, so a render-shaped loop
   holds this flat — the property the gate pins. Read-only on purpose:
   the spike's arena_mark/arena_reset stayed out of the shipped runtime
   when the region was rejected. */
int64_t emo_arena_bytes(void) {
  int64_t total = 0;
  for (emo_chunk *c = emo_heap; c != NULL; c = c->next)
    total += (int64_t)c->used;
  return total;
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

/* A malloc'd copy of n bytes as a native string — the shape every
   dynamic→native crossing hands out, so the view owns its bytes. */
static emo_str emo_str_from_parts(const char *p, int64_t n);

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
  /* The cell: [header][len][bytes...] — the bytes share the cell,
     which owns them from here on; an emo_str borrowed back out
     (emo_str_of) is valid as long as the cell lives. */
  emo_value v = emo_cell_new(EMO_STRING, 1 + (s.len + 7) / 8);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)s.len;
  memcpy(p + 1, s.bytes, (size_t)s.len);
  return v;
}

/* ---- Cell-native strings (step 49) ----

   Every string the generated code builds is a cell: the builders
   allocate the result cell directly and copy the bytes in, so no
   bump-arena intermediate ever exists. The [emo_str] views here read
   the operands' own bytes and die with the expression. */

/* The raw concat behind `+` on two strings: a plain birth — the
   dyn-arithmetic caller pools it. */
emo_value emo_cell_concat_raw(emo_value a, emo_value b) {
  emo_str sa = emo_str_of(a), sb = emo_str_of(b);
  if (sa.len > INT64_MAX - sb.len) abort(); /* length overflow */
  emo_value v = emo_cell_new(EMO_STRING, 1 + (sa.len + sb.len + 7) / 8);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)(sa.len + sb.len);
  memcpy(p + 1, sa.bytes, (size_t)sa.len);
  memcpy((char *)(p + 1) + sa.len, sb.bytes, (size_t)sb.len);
  return v;
}

/* The leaf builders answer pooled births: they open no pool frame of
   their own, so the claim lands in the calling statement's frame and
   dies at its boundary; a result that crosses a frame re-claims
   through the return's __ret. */
emo_value emo_cell_concat(emo_value a, emo_value b) {
  return emo_autorelease(emo_cell_concat_raw(a, b));
}

emo_value emo_cell_from_i64(int64_t v) {
  char buf[24];
  int n = snprintf(buf, sizeof buf, "%" PRId64, v);
  return emo_autorelease(emo_box_str((emo_str){n, buf}));
}

emo_value emo_cell_from_f64(double v) {
  char buf[48];
  int n = snprintf(buf, sizeof buf, emo_f64_format(v, false), v);
  return emo_autorelease(emo_box_str((emo_str){n, buf}));
}

emo_value emo_cell_from_char(int32_t v) {
  char buf[4];
  int32_t n = emo_utf8_put(buf, v);
  return emo_autorelease(emo_box_str((emo_str){n, buf}));
}

emo_value emo_cell_from_cstr(const char *cs) {
  /* a plain birth — like emo_box_str, this wraps a general
     constructor, so the caller pools the claim where it fits */
  return emo_box_str((emo_str){(int64_t)strlen(cs), cs});
}

emo_value emo_cell_substring(emo_value s, int64_t start, int64_t len) {
  emo_str src = emo_str_of(s);
  if (start < 0 || len < 0 || start + len > src.len)
    emo_fatal("substring is out of bounds for the string");
  return emo_autorelease(emo_box_str((emo_str){len, src.bytes + start}));
}

emo_value emo_cell_lower(emo_value s) {
  emo_str src = emo_str_of(s);
  emo_value v = emo_cell_new(EMO_STRING, 1 + (src.len + 7) / 8);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)src.len;
  for (int64_t i = 0; i < src.len; i++) {
    char c = src.bytes[i];
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    ((char *)(p + 1))[i] = c;
  }
  return emo_autorelease(v);
}

emo_value emo_cell_trim(emo_value s) {
  emo_str src = emo_str_of(s);
  int64_t lo = 0, hi = src.len;
  while (lo < hi && (unsigned char)src.bytes[lo] <= ' ') lo++;
  while (hi > lo && (unsigned char)src.bytes[hi - 1] <= ' ') hi--;
  return emo_autorelease(emo_box_str((emo_str){hi - lo, src.bytes + lo}));
}

emo_value emo_cell_split(emo_value s, emo_value sep) {
  emo_str str = emo_str_of(s);
  emo_str mark = emo_str_of(sep);
  if (mark.len == 0) emo_fatal("the separator must not be empty");
  int64_t parts = 1;
  for (int64_t i = 0; i + mark.len <= str.len;)
    if (memcmp(str.bytes + i, mark.bytes, (size_t)mark.len) == 0) {
      parts++;
      i += mark.len;
    } else
      i++;
  /* the element array is a transient: malloc'd, copied out by
     emo_array_new, freed here */
  emo_value *elems = malloc((size_t)parts * sizeof(emo_value));
  if (elems == NULL) abort();
  int64_t count = 0, start = 0;
  for (int64_t i = 0; i + mark.len <= str.len;) {
    if (memcmp(str.bytes + i, mark.bytes, (size_t)mark.len) == 0) {
      elems[count++] = emo_box_str((emo_str){i - start, str.bytes + start});
      i += mark.len;
      start = i;
    } else
      i++;
  }
  elems[count++] =
      emo_box_str((emo_str){str.len - start, str.bytes + start});
  emo_value out = emo_array_new(count, elems);
  free(elems);
  return emo_autorelease(out);
}

/* The to_string surface over a dynamic value: the rendered bytes copy
   into a cell, and the memstream transient dies here. */
emo_value emo_to_string_cell(emo_value v) {
  if (emo_cell_kind(v) == EMO_BYTES) {
    /* the content, not the Bytes[n] rendering — the interpreter's
       to_string over Bytes yields the raw bytes */
    emo_str s = emo_str_of_bytes(v);
    return emo_box_str(s);
  }
  emo_str s = emo_to_string_dyn(v);
  emo_value cell = emo_box_str(s);
  free((void *)s.bytes);
  return cell;
}

/* A malloc'd C copy of a borrowed string — free() it after the POSIX
   call; the underlying cell's claim may not outlive the statement. */
static char *emo_cstr_owned(emo_str s) {
  char *p = malloc((size_t)s.len + 1);
  if (p == NULL) abort();
  memcpy(p, s.bytes, (size_t)s.len);
  p[s.len] = '\0';
  return p;
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
  for (int64_t i = 0; i < arity; i++) {
    p[i + 1] = (uintptr_t)elems[i];
    emo_retain(elems[i]); /* the arena cell holds its identities */
  }
  return v;
}

emo_value emo_array_new(int64_t len, emo_value *elems) {
  /* [header][len][elements...] */
  emo_value v = emo_cell_new(EMO_ARRAY, len + 1);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)len;
  for (int64_t i = 0; i < len; i++) {
    p[i + 1] = (uintptr_t)elems[i];
    emo_retain(elems[i]);
  }
  return v;
}

emo_value emo_array_append(emo_value arr, emo_value v) {
  int64_t n = emo_length(arr);
  emo_value out = emo_cell_new(EMO_ARRAY, n + 2);
  uintptr_t *p = emo_payload(out);
  p[0] = (uintptr_t)(n + 1);
  for (int64_t i = 0; i < n; i++) {
    p[i + 1] = emo_payload(arr)[i + 1];
    emo_retain((emo_value)p[i + 1]);
  }
  p[n + 1] = (uintptr_t)v;
  emo_retain(v);
  return out;
}

emo_value emo_box_new(emo_value v) {
  emo_value box = emo_cell_new(EMO_BOX, 1);
  *emo_payload(box) = (uintptr_t)v;
  emo_retain(v); /* the box owns its contents */
  return box;
}

emo_value emo_box_read(emo_value box) {
  box = emo_expect_kind(box, EMO_BOX);
  emo_value v = (emo_value)*emo_payload(box);
  return emo_retain(v); /* the read hands the caller its own claim */
}

emo_value emo_box_replace(emo_value box, emo_value v) {
  box = emo_expect_kind(box, EMO_BOX);
  uintptr_t *p = emo_payload(box);
  /* the write barrier: the box owns the new value and drops the old */
  emo_retain(v);
  emo_value old = (emo_value)*p;
  *p = (uintptr_t)v;
  emo_release(old);
  return emo_retain(v); /* replace answers the new value, like every target */
}

/* ---- The List deque ----

   A List is an identity, like a Box: [header][emo_list *], the struct
   owning a doubly-linked node chain — O(1) push and pop at both ends.
   The struct and the nodes are the list cell's own memory: release
   frees the chain element by element and the struct with it. */

typedef struct emo_list_node {
  emo_value v;
  struct emo_list_node *prev;
  struct emo_list_node *next;
} emo_list_node;

typedef struct {
  emo_list_node *head;
  emo_list_node *tail;
  int64_t size;
} emo_list;

static emo_list *emo_list_of(emo_value l) {
  return (emo_list *)*emo_payload(emo_expect_kind(l, EMO_LIST));
}

emo_value emo_list_new(emo_value arr) {
  if (emo_cell_kind(arr) != EMO_ARRAY)
    emo_fatal("`List.new` expects an Array");
  emo_list *l = emo_owned_alloc(sizeof(emo_list));
  l->head = NULL;
  l->tail = NULL;
  l->size = 0;
  int64_t n = (int64_t)emo_payload(arr)[0];
  for (int64_t i = 0; i < n; i++) {
    emo_list_node *node = emo_owned_alloc(sizeof(emo_list_node));
    node->v = (emo_value)emo_payload(arr)[i + 1];
    emo_retain(node->v); /* the list holds its elements */
    node->prev = l->tail;
    node->next = NULL;
    if (l->tail != NULL)
      l->tail->next = node;
    else
      l->head = node;
    l->tail = node;
    l->size++;
  }
  return emo_box_kind(EMO_LIST, (int64_t)(uintptr_t)l);
}

emo_value emo_list_push_front(emo_value l, emo_value v) {
  emo_list *list = emo_list_of(l);
  emo_list_node *node = emo_owned_alloc(sizeof(emo_list_node));
  node->v = v;
  emo_retain(v);
  node->prev = NULL;
  node->next = list->head;
  if (list->head != NULL)
    list->head->prev = node;
  else
    list->tail = node;
  list->head = node;
  list->size++;
  return emo_retain(l); /* the chained call hands the caller its own claim */
}

emo_value emo_list_push_back(emo_value l, emo_value v) {
  emo_list *list = emo_list_of(l);
  emo_list_node *node = emo_owned_alloc(sizeof(emo_list_node));
  node->v = v;
  emo_retain(v);
  node->prev = list->tail;
  node->next = NULL;
  if (list->tail != NULL)
    list->tail->next = node;
  else
    list->head = node;
  list->tail = node;
  list->size++;
  return emo_retain(l);
}

emo_value emo_list_pop_front(emo_value l) {
  emo_list *list = emo_list_of(l);
  if (list->size == 0) emo_fatal("`pop_front` on an empty List");
  emo_list_node *node = list->head;
  list->head = node->next;
  if (list->head != NULL)
    list->head->prev = NULL;
  else
    list->tail = NULL;
  list->size--;
  return node->v; /* the element's claim transfers */
}

emo_value emo_list_pop_back(emo_value l) {
  emo_list *list = emo_list_of(l);
  if (list->size == 0) emo_fatal("`pop_back` on an empty List");
  emo_list_node *node = list->tail;
  list->tail = node->prev;
  if (list->tail != NULL)
    list->tail->next = NULL;
  else
    list->head = NULL;
  list->size--;
  return node->v;
}

int64_t emo_list_length(emo_value l) { return emo_list_of(l)->size; }

/* ---- The ArrayBuilder ----

   A growable array under construction. The cell payload is
   [size][cap][items]: a push past the capacity allocates a doubled
   items buffer, copies, and repoints — the same amortized doubling the
   Map below uses, and for the same reason (a k-element build must not
   be quadratic). The builder is an identity, like a List, and the
   items buffer is the builder cell's own memory: growth frees the
   superseded buffer, and release frees the last one with its
   elements. */

static uintptr_t *emo_builder_words(emo_value b) {
  return emo_payload(emo_expect_kind(b, EMO_BUILDER));
}

emo_value emo_builder_new(void) {
  emo_value v = emo_cell_new(EMO_BUILDER, 3);
  uintptr_t *p = emo_payload(v);
  p[0] = 0;               /* size */
  p[1] = 0;               /* cap */
  p[2] = (uintptr_t)NULL; /* items */
  return v;
}

/* The store behind `push`, shared with the deep copy: the element's
   claim transfers (no retain), growth reuses the doubled buffer, and
   nothing is handed out. */
static void emo_builder_store(emo_value b, emo_value v) {
  uintptr_t *p = emo_builder_words(b);
  int64_t size = (int64_t)p[0];
  int64_t cap = (int64_t)p[1];
  if (size == cap) {
    int64_t ncap = cap < 8 ? 8 : cap * 2;
    emo_value *items =
        realloc((void *)p[2], (size_t)ncap * sizeof(emo_value));
    if (items == NULL) abort();
    p[1] = (uintptr_t)ncap;
    p[2] = (uintptr_t)items;
  }
  ((emo_value *)p[2])[size] = v;
  p[0] = (uintptr_t)(size + 1);
}

emo_value emo_builder_push(emo_value b, emo_value v) {
  emo_builder_store(b, v);
  emo_retain(v); /* the builder holds its elements */
  return emo_retain(b); /* the chained call hands the caller its own claim */
}

int64_t emo_builder_length(emo_value b) {
  return (int64_t)emo_builder_words(b)[0];
}

emo_value emo_builder_get(emo_value b, int64_t i) {
  uintptr_t *p = emo_builder_words(b);
  int64_t size = (int64_t)p[0];
  if (i < 0 || i >= size) {
    fprintf(stderr,
            "runtime error: index %lld is out of bounds for a length-%lld "
            "ArrayBuilder\n",
            (long long)i, (long long)size);
    exit(70);
  }
  /* the read hands the caller its own claim, like get on a Map */
  return emo_retain(((emo_value *)p[2])[i]);
}

emo_value emo_builder_to_array(emo_value b) {
  /* A fresh Array of exactly the builder's contents — a copy, so the
     builder stays free to grow without touching what it handed out. */
  uintptr_t *p = emo_builder_words(b);
  return emo_array_new((int64_t)p[0], (emo_value *)p[2]);
}

/* ---- The Map ----

   A mutable, insertion-ordered hash table. The cell payload:
   [count][cap][entries][bucket_mask][buckets]. Entries live in an
   append-only array (indices never move, so array order is insertion
   order; a removed entry's key becomes 0), chained through `next`
   into an open bucket array rehashed at a 0.5 load factor. Keys are
   the primitive kinds only — the same rule the checker enforces when
   it can prove one — validated at every insertion. The entry and
   bucket arrays are the map cell's own memory: growth frees the
   superseded array, and release frees both with the entries' keys and
   values. */

typedef struct {
  emo_value key; /* 0 marks a removed entry */
  emo_value value;
  int64_t next; /* the chain's next entry index, -1 ends */
} emo_map_entry;

static void emo_debug_dyn(emo_value v, FILE *out);

static const char *emo_map_key_rule =
    "a map key must be a String, Int64, Byte, Bool, Char, or Float64";

static bool emo_map_key_ok(emo_value k) {
  if ((k & 7) == 0b001 || (k & 7) == 0b011) return true; /* Bool, Char */
  switch (emo_cell_kind(k)) {
  case EMO_INT64:
  case EMO_FLOAT64:
  case EMO_STRING: return true;
  default: return false;
  }
}

static uint64_t emo_hash_mix(uint64_t x) {
  x += 0x9E3779B97F4A7C15ULL;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
  return x ^ (x >> 31);
}

static uint64_t emo_hash_key(emo_value k) {
  if ((k & 7) == 0b001) return emo_hash_mix(0x1000ULL + (k >> 3));
  if ((k & 7) == 0b011)
    return emo_hash_mix(0x2000ULL + (uint64_t)(uint32_t)(k >> 3));
  switch (emo_cell_kind(k)) {
  case EMO_INT64:
    return emo_hash_mix((uint64_t)emo_unbox_i64(k) ^ 0x3000ULL);
  case EMO_FLOAT64: {
    double d = emo_unbox_f64(k);
    uint64_t bits;
    memcpy(&bits, &d, sizeof bits);
    return emo_hash_mix(bits ^ 0x4000ULL);
  }
  case EMO_STRING: {
    emo_str s = emo_str_of(k);
    uint64_t h = 0xCBF29CE484222325ULL;
    for (int64_t i = 0; i < s.len; i++) {
      h ^= (uint64_t)(uint8_t)s.bytes[i];
      h *= 0x100000001B3ULL;
    }
    return h;
  }
  default:
    emo_fatal(emo_map_key_rule);
  }
}

/* The entry index for the key, or -1. */
static int64_t emo_map_find(emo_value m, emo_value key) {
  uintptr_t *p = emo_payload(m);
  if (p[4] == (uintptr_t)NULL) return -1;
  emo_map_entry *entries = (emo_map_entry *)p[2];
  int64_t *buckets = (int64_t *)p[4];
  uintptr_t mask = p[3];
  for (int64_t i = buckets[emo_hash_key(key) & mask]; i >= 0;
       i = entries[i].next)
    if (entries[i].key != 0 && emo_eq_dyn(entries[i].key, key)) return i;
  return -1;
}

/* Rehashes every live entry into a bucket array sized for the load. */
static void emo_map_rehash(emo_value m);

emo_value emo_map_set(emo_value m, emo_value key, emo_value value);

/* The fresh-insert behind `Map.new` (defined with set): the map takes
   its own claims, nothing is handed out. */
static void emo_map_insert(emo_value m, emo_value key, emo_value value);

emo_value emo_map_new(int64_t npairs, emo_value *pairs) {
  emo_value m = emo_cell_new(EMO_MAP, 5);
  uintptr_t *p = emo_payload(m);
  p[0] = 0;
  p[1] = 0;
  p[2] = (uintptr_t)NULL;
  p[3] = 0;
  p[4] = (uintptr_t)NULL;
  for (int64_t i = 0; i < npairs; i++) {
    emo_value pair = pairs[i];
    if (emo_cell_kind(pair) != EMO_TUPLE || emo_length(pair) != 2)
      emo_fatal("`Map.new` takes (key, value) pairs of two elements");
    emo_map_insert(m, (emo_value)emo_payload(pair)[1],
                   (emo_value)emo_payload(pair)[2]);
  }
  return m;
}

emo_value emo_map_get(emo_value m, emo_value key) {
  emo_expect_kind(m, EMO_MAP);
  if (!emo_map_key_ok(key)) emo_fatal(emo_map_key_rule);
  int64_t i = emo_map_find(m, key);
  if (i < 0) {
    char *buf = NULL;
    size_t len = 0;
    FILE *f = open_memstream(&buf, &len);
    if (f == NULL) abort();
    emo_debug_dyn(key, f);
    fclose(f);
    fprintf(stderr, "runtime error: no key %.*s in this Map\n", (int)len, buf);
    exit(70);
  }
  return emo_retain(((emo_map_entry *)emo_payload(m)[2])[i].value);
}

/* The store behind `set` and the deep copy: a fresh insert takes the
   map's own claims on the key and the value; a replacement keeps the
   old entries alive until the new ones are in when [replace_barrier]
   is set (self-assignment survives). Nothing is handed out. */
static void emo_map_store(emo_value m, emo_value key, emo_value value,
                          bool replace_barrier) {
  emo_expect_kind(m, EMO_MAP);
  int64_t i = emo_map_find(m, key);
  uintptr_t *p = emo_payload(m);
  if (i >= 0) {
    /* the write barrier: the map owns its entries */
    emo_map_entry *slot = (emo_map_entry *)p[2];
    if (replace_barrier) {
      emo_retain(key);
      emo_retain(value);
    }
    emo_release(slot[i].key);
    emo_release(slot[i].value);
    slot[i].key = key;
    slot[i].value = value;
    return;
  }
  int64_t cap = (int64_t)p[1];
  int64_t count = (int64_t)p[0];
  if (cap == count) {
    int64_t ncap = cap < 8 ? 8 : cap * 2;
    emo_map_entry *entries =
        realloc((void *)p[2], (size_t)ncap * sizeof(emo_map_entry));
    if (entries == NULL) abort();
    memset(entries + cap, 0, (size_t)(ncap - cap) * sizeof(emo_map_entry));
    p[1] = (uintptr_t)ncap;
    p[2] = (uintptr_t)entries;
  }
  emo_map_entry *entries = (emo_map_entry *)p[2];
  entries[count].key = key;
  entries[count].value = value;
  emo_retain(key); /* the map owns its entries */
  emo_retain(value);
  entries[count].next = -1;
  p[0] = (uintptr_t)(count + 1);
  uintptr_t mask = p[3];
  if (p[4] == (uintptr_t)NULL ||
      (uint64_t)(count + 1) * 2 > (uint64_t)(mask + 1))
    emo_map_rehash(m);
  else {
    int64_t *buckets = (int64_t *)p[4];
    uint64_t h = emo_hash_key(key);
    entries[count].next = buckets[h & mask];
    buckets[h & mask] = count;
  }
}

/* The insert `Map.new` and the deep copy use: fresh inserts only, so
   the map takes its own claims, and no result is handed out. */
static void emo_map_insert(emo_value m, emo_value key, emo_value value) {
  emo_map_store(m, key, value, false);
}

emo_value emo_map_set(emo_value m, emo_value key, emo_value value) {
  emo_expect_kind(m, EMO_MAP);
  if (!emo_map_key_ok(key)) emo_fatal(emo_map_key_rule);
  emo_map_store(m, key, value, true);
  return emo_retain(m); /* the chained call hands the caller its own claim */
}

/* Rehashes every live entry into a bucket array sized for the load. */
static void emo_map_rehash(emo_value m) {
  uintptr_t *p = emo_payload(m);
  int64_t cap = (int64_t)p[1];
  int64_t nbuckets = 8;
  while ((uint64_t)cap * 2 > (uint64_t)nbuckets) nbuckets <<= 1;
  int64_t *buckets = emo_owned_alloc((size_t)nbuckets * sizeof(int64_t));
  for (int64_t i = 0; i < nbuckets; i++) buckets[i] = -1;
  emo_map_entry *entries = (emo_map_entry *)p[2];
  uintptr_t mask = (uintptr_t)(nbuckets - 1);
  for (int64_t i = 0; i < cap; i++) {
    if (entries[i].key == 0) continue;
    uint64_t h = emo_hash_key(entries[i].key);
    entries[i].next = buckets[h & mask];
    buckets[h & mask] = i;
  }
  free((void *)p[4]); /* the superseded bucket array */
  p[3] = mask;
  p[4] = (uintptr_t)buckets;
}

bool emo_map_has(emo_value m, emo_value key) {
  emo_expect_kind(m, EMO_MAP);
  if (!emo_map_key_ok(key)) return false; /* never storable, so never present */
  return emo_map_find(m, key) >= 0;
}

emo_value emo_map_remove(emo_value m, emo_value key) {
  emo_expect_kind(m, EMO_MAP);
  if (!emo_map_key_ok(key)) return emo_retain(m);
  uintptr_t *p = emo_payload(m);
  if (p[4] == (uintptr_t)NULL) return emo_retain(m);
  emo_map_entry *entries = (emo_map_entry *)p[2];
  int64_t *buckets = (int64_t *)p[4];
  uintptr_t mask = p[3];
  int64_t *link = &buckets[emo_hash_key(key) & mask];
  while (*link >= 0) {
    emo_map_entry *e = &entries[*link];
    if (e->key != 0 && emo_eq_dyn(e->key, key)) {
      emo_release(e->key); /* the map drops the removed entry */
      emo_release(e->value);
      e->key = 0;
      *link = e->next;
      p[0] = (uintptr_t)((int64_t)p[0] - 1);
      return emo_retain(m);
    }
    link = &e->next;
  }
  return emo_retain(m);
}

int64_t emo_map_length(emo_value m) {
  emo_expect_kind(m, EMO_MAP);
  return (int64_t)emo_payload(m)[0];
}

/* The keys or values as an Array, in insertion order. */
static emo_value emo_map_collect(emo_value m, bool values) {
  uintptr_t *p = emo_payload(m);
  int64_t count = (int64_t)p[0];
  int64_t cap = (int64_t)p[1];
  emo_map_entry *entries = (emo_map_entry *)p[2];
  emo_value *out = emo_alloc((size_t)(count > 0 ? count : 1) * sizeof(emo_value));
  int64_t n = 0;
  for (int64_t i = 0; i < cap; i++) {
    if (entries[i].key == 0) continue;
    out[n++] = values ? entries[i].value : entries[i].key;
  }
  return emo_array_new(n, out);
}

emo_value emo_map_keys(emo_value m) {
  emo_expect_kind(m, EMO_MAP);
  return emo_map_collect(m, false);
}

emo_value emo_map_values(emo_value m) {
  emo_expect_kind(m, EMO_MAP);
  return emo_map_collect(m, true);
}

/* ---- Reclamation, the release half (step 49) ----

   Every cell frees its holdings at zero: a tuple or array its
   elements, a List its struct and nodes, a Map its entries and
   buckets, an ArrayBuilder its items and buffer, an instance its
   fields, a closure its captures, a Box its contents. The remaining
   kinds — String, Bytes, Enum, Int64, Float64, Pid — hold no cell
   words, so their release is the free alone. */

void emo_release(emo_value v) {
  if (v == 0 || (v & 7) != 0) return;
  if (--*emo_rc_of(v) > 0) return;
  emo_identity_live--;
  uintptr_t *p = emo_payload(v);
  switch (emo_cell_kind(v)) {
  case EMO_TUPLE:
  case EMO_ARRAY: {
    /* [header][len][elements...] */
    int64_t n = (int64_t)p[0];
    for (int64_t i = 0; i < n; i++) emo_release((emo_value)p[i + 1]);
    break;
  }
  case EMO_INSTANCE: {
    /* [header][vtable][fields...] */
    const emo_vtable *vt = (const emo_vtable *)p[0];
    for (int64_t i = 0; i < vt->field_count; i++)
      emo_release((emo_value)p[i + 1]);
    break;
  }
  case EMO_CLOSURE: {
    /* [header][fn][ncaps][captured...] */
    int64_t ncaps = (int64_t)p[1];
    for (int64_t i = 0; i < ncaps; i++) emo_release((emo_value)p[i + 2]);
    break;
  }
  case EMO_LIST: {
    /* [header][emo_list *] — the struct and every node */
    emo_list *l = (emo_list *)*p;
    for (emo_list_node *n = l->head; n != NULL;) {
      emo_list_node *next = n->next;
      emo_release(n->v);
      free(n);
      n = next;
    }
    free(l);
    break;
  }
  case EMO_MAP: {
    /* [header][count][cap][entries][bucket_mask][buckets] */
    emo_map_entry *entries = (emo_map_entry *)p[2];
    int64_t cap = (int64_t)p[1];
    for (int64_t i = 0; i < cap; i++)
      if (entries[i].key != 0) {
        emo_release(entries[i].key);
        emo_release(entries[i].value);
      }
    free(entries);
    free((void *)p[4]);
    break;
  }
  case EMO_BUILDER: {
    /* [header][size][cap][items] */
    int64_t size = (int64_t)p[0];
    for (int64_t i = 0; i < size; i++) emo_release(((emo_value *)p[2])[i]);
    free((void *)p[2]);
    break;
  }
  case EMO_BOX:
    /* [header][payload] */
    emo_release((emo_value)p[0]);
    break;
  default:
    break; /* String, Bytes, Enum, Int64, Float64, Pid */
  }
  free((emo_idhead *)((emo_cell *)v - 1));
}

/* ---- Instances (T23.5) ---- */

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

/* The dynamic send's fork: an instance answers through its vtable, a
   non-instance takes the builtin helper that owns the method name. */
int emo_is_instance(emo_value v) { return emo_cell_kind(v) == EMO_INSTANCE; }

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
  /* the write barrier (CHECK.md): the instance owns its field, so the
     store retains the new value and releases the overwritten one */
  emo_retain(v);
  uintptr_t old = emo_payload(instance)[i + 1];
  emo_payload(instance)[i + 1] = (uintptr_t)v;
  emo_release((emo_value)old);
}

bool emo_is_class(emo_value instance, const emo_vtable *vt) {
  if (emo_cell_kind(instance) != EMO_INSTANCE) return false;
  return (const emo_vtable *)*emo_payload(instance) == vt;
}

emo_value emo_field_by_name(emo_value instance, const char *name) {
  const emo_vtable *vt = emo_vtable_of(instance);
  for (int64_t i = 0; i < vt->field_count; i++)
    if (strcmp(vt->field_names[i], name) == 0)
      return (emo_value)emo_payload(instance)[i + 1];
  fprintf(stderr, "runtime error: no field `%s` on #%s\n", name,
          vt->class_name);
  exit(70);
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

/* ---- Enums (T23.5) ---- */

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

/* ---- Closures (T23.5) ---- */

emo_value emo_closure_new(emo_closure_fn fn, int64_t ncaps,
                          const emo_value *caps) {
  /* [header][fn][ncaps][captured...] — the capture count rides in the
     cell so release can free the captures */
  emo_value v = emo_cell_new(EMO_CLOSURE, ncaps + 2);
  uintptr_t *p = emo_payload(v);
  *p++ = (uintptr_t)fn;
  *p++ = (uintptr_t)ncaps;
  for (int64_t i = 0; i < ncaps; i++) {
    *p++ = (uintptr_t)caps[i];
    emo_retain(caps[i]);
  }
  return v;
}

emo_closure_fn emo_closure_fn_of(emo_value closure) {
  closure = emo_expect_kind(closure, EMO_CLOSURE);
  return (emo_closure_fn)*emo_payload(closure);
}

emo_value emo_closure_get(emo_value closure, int64_t i) {
  closure = emo_expect_kind(closure, EMO_CLOSURE);
  return (emo_value)emo_payload(closure)[i + 2];
}

emo_value emo_closure_call0(emo_value f) {
  emo_closure_fn fn = emo_closure_fn_of(f);
  return fn(f, NULL); /* the body's __ret claim */
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
  uintptr_t k = emo_cell_kind(v);
  if (k == EMO_LIST) return emo_list_length(v);
  if (k == EMO_BUILDER) return emo_builder_length(v);
  if (k != EMO_TUPLE && k != EMO_ARRAY && k != EMO_BYTES && k != EMO_STRING)
    emo_fatal(
        "only strings, Bytes, tuples, arrays, Lists, and ArrayBuilders have a "
        "length");
  return (int64_t)*emo_payload(v);
}

bool emo_is_tuple(emo_value v) { return emo_cell_kind(v) == EMO_TUPLE; }

/* ---- printf ----

   The C target anchors on libc: every numeric conversion builds its C
   format string and goes through snprintf, so flags, width, precision,
   and rounding are the platform printf's own — which is the contract.
   `%s` and `%c` render by hand (Emo strings are (len, bytes) and may
   hold NULs), with byte-measured width and precision; the `0` flag is
   ignored there, space padding applies. Argument mismatches are the
   interpreter's E3001 as a fatal runtime error. */

typedef struct {
  char *bytes;
  size_t len;
  size_t cap;
} emo_printf_buf;

static void emo_printf_reserve(emo_printf_buf *b, size_t extra) {
  if (b->len + extra <= b->cap) return;
  size_t cap = b->cap ? b->cap : 128;
  while (cap < b->len + extra) cap *= 2;
  char *nb = realloc(b->bytes, cap);
  if (nb == NULL) abort();
  b->bytes = nb;
  b->cap = cap;
}

static void emo_printf_addn(emo_printf_buf *b, const char *bytes, size_t n) {
  emo_printf_reserve(b, n);
  memcpy(b->bytes + b->len, bytes, n);
  b->len += n;
}

static void emo_printf_addc(emo_printf_buf *b, char c) {
  emo_printf_reserve(b, 1);
  b->bytes[b->len++] = c;
}

static void emo_printf_addspaces(emo_printf_buf *b, int64_t n) {
  while (n-- > 0) emo_printf_addc(b, ' ');
}

/* One snprintf conversion into the buffer, growing as snprintf
   reports the needed size. */
static void emo_printf_addf(emo_printf_buf *b, const char *spec, ...) {
  va_list ap, ap2;
  va_start(ap, spec);
  va_copy(ap2, ap);
  int n = vsnprintf(NULL, 0, spec, ap);
  va_end(ap);
  if (n >= 0) {
    emo_printf_reserve(b, (size_t)n + 1);
    vsnprintf(b->bytes + b->len, (size_t)n + 1, spec, ap2);
    b->len += (size_t)n;
  }
  va_end(ap2);
}

/* C's %F is %f with INF and NAN spelled uppercase. */
static void emo_printf_addf_upper(emo_printf_buf *b, const char *spec,
                                  double v) {
  size_t start = b->len;
  emo_printf_addf(b, spec, v);
  size_t i = start;
  while (i + 3 <= b->len) {
    if ((b->bytes[i] == 'i' && b->bytes[i + 1] == 'n' &&
         b->bytes[i + 2] == 'f') ||
        (b->bytes[i] == 'n' && b->bytes[i + 1] == 'a' &&
         b->bytes[i + 2] == 'n')) {
      b->bytes[i] = (char)(b->bytes[i] - 'a' + 'A');
      b->bytes[i + 1] = (char)(b->bytes[i + 1] - 'a' + 'A');
      b->bytes[i + 2] = (char)(b->bytes[i + 2] - 'a' + 'A');
      i += 3;
    } else {
      i++;
    }
  }
}

/* Assemble "%" flags width ".prec" conv into out. */
static void emo_printf_spec(char *out, const char *flags, const char *width,
                            const char *prec, const char *conv) {
  size_t n = 0;
  out[n++] = '%';
  for (const char *p = flags; *p != 0;) out[n++] = *p++;
  for (const char *p = width; *p != 0;) out[n++] = *p++;
  for (const char *p = prec; *p != 0;) out[n++] = *p++;
  for (const char *p = conv; *p != 0;) out[n++] = *p++;
  out[n] = 0;
}

static const char *emo_printf_kind_name(emo_value v) {
  if ((v & 7) == 0b001) return "Bool";
  if ((v & 7) == 0b011) return "Char";
  switch (emo_cell_kind(v)) {
    case EMO_INT64: return "Int64";
    case EMO_FLOAT64: return "Float64";
    case EMO_STRING: return "String";
    case EMO_TUPLE: return "Tuple";
    case EMO_ARRAY: return "Array";
    case EMO_BOX: return "Box";
    case EMO_BYTES: return "Bytes";
    case EMO_LIST: return "List";
    case EMO_PID: return "Pid";
    case EMO_MAP: return "Map";
    case EMO_BUILDER: return "ArrayBuilder";
    default: return "value";
  }
}

static const char *emo_printf_slot_expects(char conv) {
  switch (conv) {
    case 'c': return "a Char, Byte, or Int64";
    case 's': return "a String";
    case 'f':
    case 'F':
    case 'e':
    case 'E':
    case 'g':
    case 'G': return "a Float64";
    default: return "an Int64";
  }
}

static void emo_printf_wrong(char conv, emo_value v) {
  char message[128];
  snprintf(message, sizeof message, "printf: `%%%c` expects %s, got %s", conv,
           emo_printf_slot_expects(conv), emo_printf_kind_name(v));
  emo_fatal(message);
}

static emo_value emo_printf_next(emo_value args, int64_t *next, int64_t nargs) {
  if (*next >= nargs)
    emo_fatal("printf: the format consumes more arguments than the array "
              "has elements");
  return emo_index(args, (*next)++);
}

static int64_t emo_printf_pull_i64(emo_value args, int64_t *next,
                                   int64_t nargs, char conv) {
  emo_value v = emo_printf_next(args, next, nargs);
  if (emo_cell_kind(v) != EMO_INT64) emo_printf_wrong(conv, v);
  return emo_unbox_i64(v);
}

void emo_printf(emo_str fmt, emo_value args) {
  if (emo_cell_kind(args) != EMO_ARRAY)
    emo_fatal("printf: data must be an Array");
  int64_t nargs = emo_length(args);
  /* Count the consumed slots before rendering anything: the
     interpreter fails upfront, so a mismatched format never emits a
     partial line there — match that here. */
  int64_t slots = 0;
  for (size_t k = 0; k < (size_t)fmt.len; k++) {
    if (fmt.bytes[k] != '%') continue;
    k++;
    if (k >= (size_t)fmt.len) break;
    if (fmt.bytes[k] == '%') continue;
    while (k < (size_t)fmt.len && (fmt.bytes[k] == '-' || fmt.bytes[k] == '+' ||
                                   fmt.bytes[k] == ' ' || fmt.bytes[k] == '#' ||
                                   fmt.bytes[k] == '0'))
      k++;
    if (k < (size_t)fmt.len && fmt.bytes[k] == '*') {
      slots++;
      k++;
    } else {
      while (k < (size_t)fmt.len && fmt.bytes[k] >= '0' && fmt.bytes[k] <= '9')
        k++;
    }
    if (k < (size_t)fmt.len && fmt.bytes[k] == '.') {
      k++;
      if (k < (size_t)fmt.len && fmt.bytes[k] == '*') {
        slots++;
        k++;
      } else {
        while (k < (size_t)fmt.len && fmt.bytes[k] >= '0' &&
               fmt.bytes[k] <= '9')
          k++;
      }
    }
    if (k >= (size_t)fmt.len) break;
    if (fmt.bytes[k] != '%') slots++;
  }
  if (slots != nargs) {
    char message[128];
    snprintf(message, sizeof message,
             "printf: the format consumes %lld argument(s), the array has %lld "
             "element(s)",
             (long long)slots, (long long)nargs);
    emo_fatal(message);
  }
  int64_t next = 0;
  emo_printf_buf b = {NULL, 0, 0};
  char flags[8], wbuf[24], pbuf[24], spec[72], message[128];
  size_t i = 0;
  const size_t len = (size_t)fmt.len;
  while (i < len) {
    char c = fmt.bytes[i];
    if (c != '%') {
      emo_printf_addc(&b, c);
      i++;
      continue;
    }
    i++;
    if (i >= len) emo_fatal("printf: the format ends with a lone `%`");
    if (fmt.bytes[i] == '%') {
      emo_printf_addc(&b, '%');
      i++;
      continue;
    }
    int minus = 0, plus = 0, space = 0, hash = 0, zero = 0;
    for (;;) {
      if (i >= len) break;
      char f = fmt.bytes[i];
      if (f == '-') {
        minus = 1;
        i++;
      } else if (f == '+') {
        plus = 1;
        i++;
      } else if (f == ' ') {
        space = 1;
        i++;
      } else if (f == '#') {
        hash = 1;
        i++;
      } else if (f == '0') {
        zero = 1;
        i++;
      } else {
        break;
      }
    }
    int has_width = 0;
    int64_t width = 0;
    if (i < len && fmt.bytes[i] == '*') {
      has_width = 1;
      i++;
      width = emo_printf_pull_i64(args, &next, nargs, '*');
      if (width < 0) {
        minus = 1;
        width = -width;
      }
    } else if (i < len && fmt.bytes[i] >= '0' && fmt.bytes[i] <= '9') {
      has_width = 1;
      while (i < len && fmt.bytes[i] >= '0' && fmt.bytes[i] <= '9') {
        width = width * 10 + (fmt.bytes[i] - '0');
        if (width > 999999999) width = 999999999;
        i++;
      }
    }
    int has_prec = 0;
    int64_t prec = 0;
    if (i < len && fmt.bytes[i] == '.') {
      i++;
      has_prec = 1;
      if (i < len && fmt.bytes[i] == '*') {
        i++;
        prec = emo_printf_pull_i64(args, &next, nargs, '*');
        if (prec < 0) has_prec = 0; /* C17: negative precision is omitted */
      } else {
        while (i < len && fmt.bytes[i] >= '0' && fmt.bytes[i] <= '9') {
          prec = prec * 10 + (fmt.bytes[i] - '0');
          if (prec > 999999999) prec = 999999999;
          i++;
        }
      }
    }
    if (i < len && (fmt.bytes[i] == 'h' || fmt.bytes[i] == 'l' ||
                    fmt.bytes[i] == 'L' || fmt.bytes[i] == 'z' ||
                    fmt.bytes[i] == 'j' || fmt.bytes[i] == 't'))
      emo_fatal("printf: length modifiers (`h`, `l`, `ll`, `z`, ...) have no "
                "meaning in Emo");
    if (i >= len) emo_fatal("printf: the format ends with a bare `%`");
    char conv = fmt.bytes[i++];
    int nflags = 0;
    if (minus) flags[nflags++] = '-';
    if (plus) flags[nflags++] = '+';
    if (space) flags[nflags++] = ' ';
    if (hash) flags[nflags++] = '#';
    if (zero && !minus) flags[nflags++] = '0';
    flags[nflags] = 0;
    wbuf[0] = 0;
    if (has_width) snprintf(wbuf, sizeof wbuf, "%lld", (long long)width);
    pbuf[0] = 0;
    if (has_prec) snprintf(pbuf, sizeof pbuf, ".%lld", (long long)prec);
    switch (conv) {
      case 'd':
      case 'i':
      case 'u':
      case 'o':
      case 'x':
      case 'X': {
        emo_value v = emo_printf_next(args, &next, nargs);
        if (emo_cell_kind(v) != EMO_INT64) emo_printf_wrong(conv, v);
        int64_t n = emo_unbox_i64(v);
        char convstr[4] = {'l', 'l',
                           (char)((conv == 'd' || conv == 'i') ? 'd' : conv), 0};
        emo_printf_spec(spec, flags, wbuf, pbuf, convstr);
        emo_printf_addf(&b, spec, n);
        break;
      }
      case 'c': {
        emo_value v = emo_printf_next(args, &next, nargs);
        unsigned char byte;
        if ((v & 7) == 0b011) {
          byte = (unsigned char)(emo_char_of(v) & 0xFF);
        } else if (emo_cell_kind(v) == EMO_INT64) {
          byte = (unsigned char)(emo_unbox_i64(v) & 0xFF);
        } else {
          emo_printf_wrong(conv, v);
          byte = 0;
        }
        if (width > 1 && !minus) emo_printf_addspaces(&b, width - 1);
        emo_printf_addc(&b, (char)byte);
        if (width > 1 && minus) emo_printf_addspaces(&b, width - 1);
        break;
      }
      case 's': {
        emo_value v = emo_printf_next(args, &next, nargs);
        if (emo_cell_kind(v) != EMO_STRING) emo_printf_wrong(conv, v);
        emo_str s = emo_str_of(v);
        int64_t n = s.len;
        if (has_prec && prec < n) n = prec;
        int64_t missing = width - n;
        if (missing > 0 && !minus) emo_printf_addspaces(&b, missing);
        emo_printf_addn(&b, s.bytes, (size_t)n);
        if (missing > 0 && minus) emo_printf_addspaces(&b, missing);
        break;
      }
      case 'f':
      case 'F':
      case 'e':
      case 'E':
      case 'g':
      case 'G': {
        emo_value v = emo_printf_next(args, &next, nargs);
        if (emo_cell_kind(v) != EMO_FLOAT64) emo_printf_wrong(conv, v);
        double d = emo_unbox_f64(v);
        char convstr[2] = {(char)(conv == 'F' ? 'f' : conv), 0};
        emo_printf_spec(spec, flags, wbuf, pbuf, convstr);
        if (conv == 'F') emo_printf_addf_upper(&b, spec, d);
        else emo_printf_addf(&b, spec, d);
        break;
      }
      case 'a':
      case 'A':
        snprintf(message, sizeof message,
                 "printf: hex-float conversion `%%%c` is not supported", conv);
        emo_fatal(message);
      case 'n':
        emo_fatal("printf: `%n` is not supported (it writes through pointers)");
      case 'p':
        emo_fatal("printf: `%p` is not supported (Emo has no pointers)");
      default:
        snprintf(message, sizeof message, "printf: unknown conversion `%%%c`",
                 conv);
        emo_fatal(message);
    }
  }
  if (next != nargs) {
    snprintf(message, sizeof message,
             "printf: the format consumes %lld argument(s), the array has %lld "
             "element(s)",
             (long long)next, (long long)nargs);
    emo_fatal(message);
  }
  fwrite(b.bytes, 1, b.len, stdout);
  free(b.bytes); /* the render buffer dies with the call */
}

static int64_t emo_length_bytes(emo_value v) {
  return (int64_t)*emo_payload(v);
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
      return vt->methods[i].thunk(recv, args); /* the body's __ret claim */
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
    return emo_cell_concat_raw(a, b);
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
  case EMO_BOX: {
    /* the contents borrow their owners' claims; no handout here */
    return emo_eq_dyn((emo_value)*emo_payload(a), (emo_value)*emo_payload(b));
  }
  case EMO_LIST: {
    /* element-wise, front to back — the Box rule generalized */
    emo_list *la = (emo_list *)*emo_payload(a);
    emo_list *lb = (emo_list *)*emo_payload(b);
    if (la->size != lb->size) return false;
    emo_list_node *na = la->head, *nb = lb->head;
    while (na != NULL && nb != NULL) {
      if (!emo_eq_dyn(na->v, nb->v)) return false;
      na = na->next;
      nb = nb->next;
    }
    return true;
  }
  case EMO_BUILDER: {
    /* element-wise in push order — the List rule over a flat buffer */
    uintptr_t *pa = emo_payload(a), *pb = emo_payload(b);
    if (pa[0] != pb[0]) return false;
    for (int64_t i = 0; i < (int64_t)pa[0]; i++)
      if (!emo_eq_dyn(((emo_value *)pa[2])[i], ((emo_value *)pb[2])[i]))
        return false;
    return true;
  }
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
  case EMO_PID: return emo_unbox_pid(a) == emo_unbox_pid(b);
  case EMO_MAP: {
    /* Same live keys with equal values — order is presentation. */
    if (emo_payload(a)[0] != emo_payload(b)[0]) return false;
    emo_map_entry *ea = (emo_map_entry *)emo_payload(a)[2];
    int64_t cap = (int64_t)emo_payload(a)[1];
    for (int64_t i = 0; i < cap; i++) {
      if (ea[i].key == 0) continue;
      int64_t j = emo_map_find(b, ea[i].key);
      if (j < 0) return false;
      if (!emo_eq_dyn(ea[i].value,
                      ((emo_map_entry *)emo_payload(b)[2])[j].value))
        return false;
    }
    return true;
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
  case EMO_LIST: {
    emo_list *list = (emo_list *)*emo_payload(v);
    fputs("List[", out);
    bool first = true;
    for (emo_list_node *n = list->head; n != NULL; n = n->next) {
      if (!first) fputs(", ", out);
      first = false;
      emo_render_dyn(n->v, out);
    }
    fputc(']', out);
    return;
  }
  case EMO_BUILDER: {
    uintptr_t *p = emo_payload(v);
    fputs("ArrayBuilder[", out);
    for (int64_t i = 0; i < (int64_t)p[0]; i++) {
      if (i > 0) fputs(", ", out);
      emo_render_dyn(((emo_value *)p[2])[i], out);
    }
    fputc(']', out);
    return;
  }
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
  case EMO_MAP: {
    /* The literal's shape, keys and values in debug form — the
       interpreter's to_string for a Map. */
    fputc('{', out);
    uintptr_t *p = emo_payload(v);
    emo_map_entry *entries = (emo_map_entry *)p[2];
    int64_t cap = (int64_t)p[1];
    bool first = true;
    for (int64_t i = 0; i < cap; i++) {
      if (entries[i].key == 0) continue;
      if (!first) fputs(", ", out);
      first = false;
      emo_debug_dyn(entries[i].key, out);
      fputs(": ", out);
      emo_debug_dyn(entries[i].value, out);
    }
    fputc('}', out);
    return;
  }
  case EMO_PID:
    fprintf(out, "<pid %lld>", (long long)emo_unbox_pid(v));
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
  if ((v & 7) == 0 && emo_cell_kind(v) == EMO_LIST) {
    emo_list *list = (emo_list *)*emo_payload(v);
    fputs("List[", out);
    bool first = true;
    for (emo_list_node *n = list->head; n != NULL; n = n->next) {
      if (!first) fputs(", ", out);
      first = false;
      emo_debug_dyn(n->v, out);
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

/* ---- Processes and the cooperative scheduler ---- */

typedef struct emo_msg {
  struct emo_msg *next;
  emo_value v;
} emo_msg;

/* The autorelease pool: dynamic words handed out inside one statement
   wait here and release together at the statement boundary (the
   generated `emo_drain`). The ObjC shape — it lets every call site
   pass borrowed words without ownership analysis. */
typedef struct emo_pool {
  emo_value *items;
  int64_t count;
  int64_t cap;
} emo_pool;

static void emo_pool_push(emo_pool *p, emo_value v) {
  if (p->count == p->cap) {
    int64_t ncap = p->cap < 16 ? 16 : p->cap * 2;
    emo_value *items = realloc(p->items, (size_t)ncap * sizeof(emo_value));
    if (items == NULL) abort();
    p->items = items;
    p->cap = ncap;
  }
  p->items[p->count++] = v;
}



typedef struct emo_process {
  int64_t pid;
  ucontext_t ctx;
  struct emo_process *next_run;   /* the run queue's linkage */
  struct emo_process *next_table; /* the live-process table's linkage */
  emo_msg *inbox_head, *inbox_tail;
  int blocked;     /* parked on receive or io */
  int finished;    /* body returned or halted */
  int64_t wait_fd; /* -1: parked on a mailbox; >= 0: parked on io */
  int wait_write;  /* 0: wait for readability; 1: writability (the TLS
                      handshake's WANT_WRITE park) */
  emo_value *spawn_args;
  int64_t spawn_nargs;
  void *top_frame; /* the fiber's autorelease-pool frame stack (emo_frame) */
  void (*entry)(void);
  void *stack; /* the fiber's malloc'd stack — ctx.uc_stack is clobbered
                  by swapcontext on save */
} emo_process;

static emo_process *emo_runq_head = NULL, *emo_runq_tail = NULL;
static emo_process *emo_process_table = NULL;
static emo_process **emo_process_table_tail = &emo_process_table;
static emo_process *emo_current = NULL;

/* The autorelease pool is FRAME-scoped (the ObjC @autoreleasepool
   shape): a generated function enters a pool at its first line and
   exits it at every return, so the words it pools release together —
   and never the caller's. A statement boundary drains the current
   frame's pool, which is exactly the borrow window of the expressions
   in it. The frame stack rides the fiber (the process holds its top),
   so fibers never see each other's pools. */

typedef struct emo_frame {
  emo_pool pool;
  struct emo_frame *parent;
} emo_frame;

static emo_frame *emo_frame_free = NULL;

static emo_frame *emo_frame_alloc(void) {
  emo_frame *f = emo_frame_free;
  if (f != NULL)
    emo_frame_free = f->parent;
  else {
    f = malloc(sizeof(emo_frame));
    if (f == NULL) abort();
  }
  f->pool.items = NULL;
  f->pool.count = 0;
  f->pool.cap = 0;
  return f;
}

static emo_frame *emo_cur_frame(void) {
  if (emo_current == NULL) return NULL; /* nothing runs outside a fiber */
  return emo_current->top_frame;
}

void emo_pool_enter(void) {
  if (emo_current == NULL) return;
  emo_frame *f = emo_frame_alloc();
  f->parent = emo_current->top_frame;
  emo_current->top_frame = f;
}

void emo_pool_exit(void) {
  if (emo_current == NULL) return;
  emo_frame *f = emo_current->top_frame;
  if (f == NULL) return;
  for (int64_t i = 0; i < f->pool.count; i++) emo_release(f->pool.items[i]);
  free(f->pool.items);
  emo_current->top_frame = f->parent;
  f->parent = emo_frame_free;
  emo_frame_free = f;
}

static emo_pool *emo_pool_of(void) {
  emo_frame *f = emo_cur_frame();
  return &f->pool;
}

emo_value emo_autorelease(emo_value v) {
  if (v == 0 || (v & 7) != 0) return v;
  emo_pool_push(emo_pool_of(), v);
  return v;
}

void emo_drain(void) {
  emo_frame *f = emo_cur_frame();
  if (f == NULL) return;
  for (int64_t i = 0; i < f->pool.count; i++) emo_release(f->pool.items[i]);
  f->pool.count = 0;
}

/* Releases every frame of the running fiber's chain. A statement
   boundary drains one frame; a fiber that ends mid-stack — a raise, a
   halt — never reaches its own `emo_pool_exit`, and the frames it
   abandons are the last holders of its pooled identities. The chain is
   walked instead of unwinding the C stack, which nothing does: the
   frames are heap-resident and the fiber is simply discarded. */
static void emo_fiber_release_frames(void) {
  if (emo_current == NULL) return;
  emo_frame *f = emo_current->top_frame;
  while (f != NULL) {
    emo_frame *parent = f->parent;
    for (int64_t i = 0; i < f->pool.count; i++) emo_release(f->pool.items[i]);
    free(f->pool.items);
    f->parent = emo_frame_free;
    emo_frame_free = f;
    f = parent;
  }
  emo_current->top_frame = NULL;
}

int64_t emo_identity_live_count(void) { return emo_identity_live; }

static int64_t emo_next_pid = 1;
static int64_t emo_root_pid = -1; /* the entry process: its finish ends
                                     the program */
static ucontext_t emo_sched_ctx;

static void *emo_proc_stack_alloc(size_t n) {
  void *p = malloc(n);
  if (p == NULL) {
    fputs("emo: out of memory for a process stack\n", stderr);
    abort();
  }
  return p;
}

static void emo_runq_push(emo_process *p) {
  p->next_run = NULL;
  if (emo_runq_tail == NULL) {
    emo_runq_head = emo_runq_tail = p;
  } else {
    emo_runq_tail->next_run = p;
    emo_runq_tail = p;
  }
}

static emo_process *emo_runq_pop(void) {
  emo_process *p = emo_runq_head;
  if (p == NULL) return NULL;
  emo_runq_head = p->next_run;
  if (emo_runq_head == NULL) emo_runq_tail = NULL;
  p->next_run = NULL;
  return p;
}

/* Every fiber enters here: the site wrapper, then the finish
   transition. (Table registration happens at spawn time — a message
   may arrive before the fiber's first dispatch.) */
static void emo_process_trampoline(void) {
  emo_process *self = emo_current;
  self->entry();
  /* the body's frames closed themselves; the spawn-time references
     drop here */
  self->top_frame = NULL;
  for (int64_t i = 0; i < self->spawn_nargs; i++)
    emo_release(self->spawn_args[i]); /* drop the spawn-time references */
  free(self->spawn_args);
  self->spawn_args = NULL;
  if (getenv("EMO_TRACE"))
    fprintf(stderr, "[trace] exit %lld\n", (long long)self->pid);
  self->finished = 1;
  swapcontext(&self->ctx, &emo_sched_ctx);
  abort(); /* unreachable */
}

int64_t emo_spawn_process(void (*entry)(void), int64_t nargs,
                          const emo_value *args) {
  emo_process *p = calloc(1, sizeof(emo_process));
  if (p == NULL) abort();
  p->pid = emo_next_pid++;
  p->wait_fd = -1;
  p->wait_write = 0;
  p->entry = entry;
  if (nargs > 0) {
    p->spawn_args = malloc((size_t)nargs * sizeof(emo_value));
    if (p->spawn_args == NULL) abort();
    memcpy(p->spawn_args, args, (size_t)nargs * sizeof(emo_value));
    for (int64_t i = 0; i < nargs; i++)
      emo_retain(p->spawn_args[i]); /* the child owns its arguments */
    p->spawn_nargs = nargs;
  }
  /* Every process, the root one included, runs on one of these, so the size
     is what bounds recursion. Match the OS default for a main thread: a
     smaller stack overflows into the neighbouring heap silently instead of
     faulting, which corrupts live cells rather than reporting anything. */
  const size_t stack_size = 8 * 1024 * 1024;
  p->stack = emo_proc_stack_alloc(stack_size);
  getcontext(&p->ctx);
  p->ctx.uc_stack.ss_sp = p->stack;
  p->ctx.uc_stack.ss_size = stack_size;
  p->ctx.uc_link = &emo_sched_ctx;
  makecontext(&p->ctx, emo_process_trampoline, 0);
  if (emo_current == NULL && emo_root_pid == -1) emo_root_pid = p->pid;
  *emo_process_table_tail = p;
  emo_process_table_tail = &p->next_table;
  emo_runq_push(p);
  if (getenv("EMO_TRACE"))
    fprintf(stderr, "[trace] spawn %lld (from %lld)\n", (long long)p->pid,
            (long long)(emo_current ? emo_current->pid : 0));
  return p->pid;
}

emo_value *emo_process_spawn_args(void) { return emo_current->spawn_args; }

int64_t emo_process_self_pid(void) { return emo_current->pid; }

/* The current fiber leaves the CPU for the scheduler. */
static void emo_yield_to_sched(void) {
  emo_process *self = emo_current;
  swapcontext(&self->ctx, &emo_sched_ctx);
}

void emo_process_halt_current(void) {
  emo_fiber_release_frames();
  emo_current->finished = 1;
  swapcontext(&emo_current->ctx, &emo_sched_ctx);
  abort(); /* unreachable */
}

/* An uncaught raise. The root's is the program's outcome (T23.6): render
   the interpreter's E3010 message and exit 1. A spawned process's ends
   only that process, the interpreter's `Exit_raised` — the scheduler
   reaps the fiber and the program runs on, so a bad event cannot kill a
   whole UI. Nothing unwinds the C stack either way, which is why the
   `setjmp`/`longjmp` the error-handling decision priced in is not
   needed: a dead fiber's pooled identities are released from its frame
   chain (emo_fiber_release_frames), and its stack is discarded whole. */
void emo_raise(emo_value v) {
  if (emo_current == NULL || emo_current->pid == emo_root_pid) {
    emo_str s = emo_to_string_dyn(v);
    fprintf(stderr, "uncaught exception: %.*s\n", (int)s.len, s.bytes);
    exit(1);
  }
  emo_process_halt_current();
}

/* ---- The send snapshot (T12.4) ----

   A message crosses a process boundary by copy, never by reference: the
   receiver must not observe a write the sender makes after the send.
   The rule is the interpreter's `snapshot` (emo_eval.ml), over the kinds
   this runtime has — immutable data and identity-bearing values pass
   through, everything mutable is rebuilt. An aggregate's constructor
   retains what it stores, so a copy releases its own claim on a child
   once the child is stored; a cell built here directly needs no such
   step, the child's claim simply becomes the cell's. */

static emo_value emo_deep_copy(emo_value v) {
  if (v == 0) return v; /* the absent word, which every helper lets by */
  switch (emo_cell_kind(v)) {
  case EMO_BOX: {
    emo_value inner = emo_deep_copy((emo_value)*emo_payload(v));
    emo_value copy = emo_box_new(inner);
    emo_release(inner);
    return copy;
  }
  case EMO_BYTES: {
    /* [header][len][bytes...] */
    int64_t len = (int64_t)emo_payload(v)[0];
    emo_value copy = emo_bytes_new(len);
    memcpy(emo_payload(copy) + 1, emo_payload(v) + 1, (size_t)len);
    return copy;
  }
  case EMO_TUPLE: {
    /* [header][arity][elements...] */
    uintptr_t *p = emo_payload(v);
    int64_t arity = (int64_t)p[0];
    emo_value copy = emo_cell_new(EMO_TUPLE, arity + 1);
    uintptr_t *q = emo_payload(copy);
    q[0] = (uintptr_t)arity;
    for (int64_t i = 0; i < arity; i++)
      q[i + 1] = emo_deep_copy((emo_value)p[i + 1]);
    return copy;
  }
  case EMO_ARRAY: {
    /* [header][len][elements...] */
    uintptr_t *p = emo_payload(v);
    int64_t len = (int64_t)p[0];
    emo_value copy = emo_cell_new(EMO_ARRAY, len + 1);
    uintptr_t *q = emo_payload(copy);
    q[0] = (uintptr_t)len;
    for (int64_t i = 0; i < len; i++)
      q[i + 1] = emo_deep_copy((emo_value)p[i + 1]);
    return copy;
  }
  case EMO_LIST: {
    emo_list *src = emo_list_of(v);
    emo_list *l = emo_owned_alloc(sizeof(emo_list));
    l->head = NULL;
    l->tail = NULL;
    l->size = 0;
    for (emo_list_node *n = src->head; n != NULL; n = n->next) {
      emo_list_node *node = emo_owned_alloc(sizeof(emo_list_node));
      node->v = emo_deep_copy(n->v); /* the node holds the copy's claim */
      node->prev = l->tail;
      node->next = NULL;
      if (l->tail != NULL)
        l->tail->next = node;
      else
        l->head = node;
      l->tail = node;
      l->size++;
    }
    return emo_box_kind(EMO_LIST, (int64_t)(uintptr_t)l);
  }
  case EMO_BUILDER: {
    emo_value copy = emo_builder_new();
    uintptr_t *p = emo_builder_words(v);
    for (int64_t i = 0; i < (int64_t)p[0]; i++) {
      /* the store takes the copy's own claim */
      emo_builder_store(copy, emo_deep_copy(((emo_value *)p[2])[i]));
    }
    return copy;
  }
  case EMO_MAP: {
    /* Entries never move in the append-only entry array, so index order
       is insertion order — copying in that order preserves it. */
    emo_value copy = emo_map_new(0, NULL);
    uintptr_t *p = emo_payload(v);
    emo_map_entry *entries = (emo_map_entry *)p[2];
    for (int64_t i = 0; i < (int64_t)p[1]; i++) {
      if (entries[i].key == 0) continue; /* a removed entry */
      emo_value value = emo_deep_copy(entries[i].value);
      emo_map_insert(copy, entries[i].key, value);
      emo_release(value);
    }
    return copy;
  }
  case EMO_INSTANCE: {
    /* the class stays, the fields are copied (the interpreter's rule) */
    const emo_vtable *vt = (const emo_vtable *)*emo_payload(v);
    emo_value copy = emo_instance_new(vt, vt->field_count);
    for (int64_t i = 0; i < vt->field_count; i++)
      /* a fresh instance cell is zeroed, so its fields read as 0 and the
         store takes the child's own claim without a barrier */
      emo_payload(copy)[i + 1] = emo_deep_copy((emo_value)emo_payload(v)[i + 1]);
    return copy;
  }
  default:
    /* Int64, Float64, String, Enum, Closure, Pid: immutable data, or an
       identity the boundary deliberately shares (the interpreter's
       `| v -> v`). Since the value families refcount, sharing takes a
       claim — the copy's parent owns this word's shared reference and
       releases it when the copy dies; a bare pass-through would leave
       the mailbox holding the sender's claim, freed when the send
       statement drains. */
    return emo_retain(v);
  }
}

void emo_process_send(int64_t pid, emo_value message) {
  emo_process *target = NULL;
  for (emo_process *p = emo_process_table; p; p = p->next_table) {
    if (p->pid == pid) {
      target = p;
      break;
    }
  }
  if (target == NULL || target->finished) {
    fprintf(stderr,
            "runtime error: <- to a pid that has exited (%lld, from %lld)\n",
            (long long)pid, (long long)emo_current->pid);
    exit(70);
  }
  emo_msg *m = malloc(sizeof(emo_msg));
  if (m == NULL) abort();
  m->next = NULL;
  m->v = emo_deep_copy(message); /* the mailbox owns the snapshot (T12.4) */
  if (target->inbox_tail == NULL) target->inbox_head = m;
  else target->inbox_tail->next = m;
  target->inbox_tail = m;
  if (getenv("EMO_TRACE"))
    fprintf(stderr, "[trace] send %lld -> %lld\n",
            (long long)emo_current->pid, (long long)pid);
  if (target->blocked) {
    target->blocked = 0;
    emo_runq_push(target);
  }
  /* Sending yields the sender's slice: the sender re-joins the run
     queue at the tail (emo_sched_det's Continue policy), so a
     process firing a million sends never starves its peers. */
  emo_runq_push(emo_current);
  emo_yield_to_sched();
}

void emo_process_park_current(void) {
  if (getenv("EMO_TRACE"))
    fprintf(stderr, "[trace] park %lld\n", (long long)emo_current->pid);
  emo_current->wait_fd = -1;
  emo_current->blocked = 1;
  swapcontext(&emo_current->ctx, &emo_sched_ctx);
}

bool emo_mailbox_empty(void) { return emo_current->inbox_head == NULL; }

void *emo_mailbox_first(void) { return emo_current->inbox_head; }

void *emo_mailbox_next(void *m) { return ((emo_msg *)m)->next; }

emo_value emo_msg_value(void *m) { return ((emo_msg *)m)->v; }

void emo_mailbox_take_current(void *m) {
  emo_msg *dead = (emo_msg *)m;
  emo_msg **p = &emo_current->inbox_head;
  while (*p != NULL && *p != dead) p = &(*p)->next;
  if (*p == NULL) return;
  *p = dead->next;
  if (emo_current->inbox_tail == dead) {
    emo_msg *n = emo_current->inbox_head;
    if (n == NULL) emo_current->inbox_tail = NULL;
    else {
      while (n->next != NULL) n = n->next;
      emo_current->inbox_tail = n;
    }
  }
  emo_release(dead->v); /* the mailbox drops its claim on the snapshot */
  free(dead);
}

void emo_scheduler_run(void) {
  for (;;) {
    emo_process *p = emo_runq_pop();
    if (p == NULL) {
      /* No runnable work: poll the io-waiters; mailbox-parked fibers
         can only be woken by a send, so with no io-waiter ready and
         nothing runnable, any remainder is deadlocked. */
      struct pollfd fds[64];
      emo_process *waiters[64];
      int n = 0;
      for (emo_process *q = emo_process_table; q && n < 64; q = q->next_table)
        if (!q->finished && q->blocked && q->wait_fd >= 0) {
          fds[n].fd = (int)q->wait_fd;
          fds[n].events = q->wait_write ? POLLOUT : POLLIN;
          fds[n].revents = 0;
          waiters[n] = q;
          n++;
        }
      if (n > 0) {
        poll(fds, (nfds_t)n, 100);
        int woke = 0;
        for (int i = 0; i < n; i++) {
          int want = waiters[i]->wait_write
                         ? (POLLOUT | POLLERR | POLLHUP)
                         : (POLLIN | POLLERR | POLLHUP);
          if (fds[i].revents & want) {
            waiters[i]->blocked = 0;
            waiters[i]->wait_fd = -1;
            emo_runq_push(waiters[i]);
            woke = 1;
          }
        }
        if (woke) continue;
        /* io-waiters exist: keep polling (their readiness can still
           arrive from outside the process) */
        continue;
      }
      int deadlocked = 0;
      for (emo_process *q = emo_process_table; q; q = q->next_table)
        if (!q->finished) deadlocked++;
      if (deadlocked > 0) {
        fprintf(stderr, "runtime error: deadlock: %d process(es) waiting\n",
                deadlocked);
        exit(70);
      }
      return;
    }
    emo_current = p;
    if (getenv("EMO_TRACE"))
      fprintf(stderr, "[trace] dispatch %lld\n", (long long)p->pid);
    swapcontext(&emo_sched_ctx, &p->ctx);
    emo_current = NULL;
    if (p->finished && p->pid == emo_root_pid) {
      /* the entry process ended: the program is over (a long-running
         server spawned from it does not keep it alive) */
      return;
    }
    if (p->finished && p->stack != NULL) {
      if (getenv("EMO_TRACE"))
        fprintf(stderr, "[trace] reap %lld\n", (long long)p->pid);
      free(p->stack);
      p->stack = NULL;
    }
  }
}

/* Pids in the dynamic world. */
emo_value emo_box_pid(int64_t pid) {
  emo_value v = emo_cell_new(EMO_PID, 1);
  *emo_payload(v) = (uintptr_t)pid;
  return v;
}

int64_t emo_unbox_pid(emo_value v) {
  v = emo_expect_kind(v, EMO_PID);
  return (int64_t)*emo_payload(v);
}

/* ---- Hosted IO ---- */

static emo_str emo_str_from_parts(const char *p, int64_t n) {
  char *buf = emo_alloc(n);
  memcpy(buf, p, (size_t)n);
  emo_str s = {n, buf};
  return s;
}

/* The data-driven os failures are values: the call answers
   (R.ok, value) or (R.error, reason) — the reason the same text the
   raise carried. */
static emo_value emo_os_pair(const char *member, emo_value v) {
  emo_value elems[2];
  elems[0] = emo_enum_new("R", member);
  elems[1] = v;
  return emo_tuple_new(2, elems);
}

static emo_value emo_os_ok(emo_value v) { return emo_os_pair("ok", v); }

static emo_value emo_os_fail(const char *what, const char *arg) {
  char buf[512];
  if (arg[0] == 0)
    snprintf(buf, sizeof buf, "os: %s: %s", what, strerror(errno));
  else
    snprintf(buf, sizeof buf, "os: %s %s: %s", what, arg, strerror(errno));
  return emo_os_pair("error", emo_box_str(emo_str_from_cstr(buf)));
}

emo_value emo_file_read(emo_str path) {
  char *clean = emo_cstr_owned(path);
  FILE *f = fopen(clean, "rb");
  if (f == NULL) {
    char why[512];
    snprintf(why, sizeof why, "file: cannot read %s: %s", clean,
             strerror(errno));
    free(clean);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(why)));
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc(n > 0 ? (size_t)n : 1);
  if (buf == NULL) abort();
  size_t got = fread(buf, 1, (size_t)n, f);
  fclose(f);
  free(clean);
  if ((long)got != n) {
    free(buf);
    return emo_os_pair(
        "error",
        emo_box_str(emo_str_concat(
            emo_str_from_cstr("file: cannot read "),
            emo_str_concat(path, emo_str_from_cstr(": short read")))));
  }
  emo_value out = emo_box_str((emo_str){(int64_t)n, buf});
  free(buf);
  return emo_os_pair("ok", out);
}

emo_value emo_file_write(emo_str path, emo_str contents) {
  char *clean = emo_cstr_owned(path);
  FILE *f = fopen(clean, "wb");
  if (f == NULL) {
    char why[512];
    snprintf(why, sizeof why, "file: cannot write %s: %s", clean,
             strerror(errno));
    free(clean);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(why)));
  }
  size_t put = fwrite(contents.bytes, 1, (size_t)contents.len, f);
  fclose(f);
  free(clean);
  if ((int64_t)put != contents.len)
    return emo_os_pair(
        "error",
        emo_box_str(emo_str_concat(
            emo_str_from_cstr("file: cannot write "),
            emo_str_concat(path, emo_str_from_cstr(": short write")))));
  return emo_os_pair("ok", emo_box_i64((int64_t)contents.len));
}

/* ---- TCP ---- */

static void emo_net_fatal(const char *what, const char *detail) {
  fprintf(stderr, "uncaught exception: %s (%s)\n", what, detail);
  exit(70);
}

/* The cooperative scheduler needs EAGAIN on would-block reads, so
   every socket is non-blocking; fibers park on readability and the
   scheduler polls. */
static void emo_net_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* Wait until fd is readable: park the current fiber; the scheduler
   polls parked descriptors while the run queue is empty. */
void emo_net_wait_readable(int64_t fd) {
  emo_current->wait_fd = fd;
  emo_current->wait_write = 0;
  emo_current->blocked = 1;
  swapcontext(&emo_current->ctx, &emo_sched_ctx);
}

/* Wait until fd is writable: the TLS handshake's WANT_WRITE park; the
   scheduler polls writability the same way. */
void emo_net_wait_writable(int64_t fd) {
  emo_current->wait_fd = fd;
  emo_current->wait_write = 1;
  emo_current->blocked = 1;
  swapcontext(&emo_current->ctx, &emo_sched_ctx);
}

/* The data-driven net failures are values, like the os ones above: the
   call answers (R.ok, fd) or (R.error, reason) — the reason the same
   text the fatal print carried. */

/* The TCP listen shared by the plain and TLS listeners: socket,
   resolve, bind, listen, nonblocking. Returns the fd or -1 with the
   refusal in [why] — the text the plain listen has always printed. */
static int emo_net_listen_fd(emo_str host, int64_t port, char *why,
                             size_t whyn) {
  char *h = emo_cstr_owned(host);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    snprintf(why, whyn, "listen failed");
    free(h);
    return -1;
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, h, &addr.sin_addr) != 1) {
    close(fd);
    snprintf(why, whyn, "cannot resolve host `%s`", h);
    free(h);
    return -1;
  }
  if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 ||
      listen(fd, 16) < 0) {
    snprintf(why, whyn, "cannot listen on %s:%d: %s", h, (int)port,
             strerror(errno));
    close(fd);
    free(h);
    return -1;
  }
  free(h);
  emo_net_nonblock(fd);
  return fd;
}

emo_value emo_net_listen(emo_str host, int64_t port) {
  char why[512];
  int fd = emo_net_listen_fd(host, port, why, sizeof why);
  if (fd < 0) return emo_os_pair("error", emo_box_str(emo_str_from_cstr(why)));
  return emo_os_pair("ok", emo_box_i64(fd));
}

int64_t emo_net_port(int64_t listener) {
  struct sockaddr_in addr;
  socklen_t len = sizeof addr;
  if (getsockname((int)listener, (struct sockaddr *)&addr, &len) < 0)
    emo_net_fatal("port failed", strerror(errno));
  return ntohs(addr.sin_port);
}

/* The raw accept shared by both planes: parks on readability until a
   connection arrives. Returns the fd or -1 with the refusal in [why]. */
static int emo_net_accept_fd(int64_t listener, char *why, size_t whyn) {
  for (;;) {
    int fd = accept((int)listener, NULL, NULL);
    if (fd >= 0) {
      emo_net_nonblock(fd);
      return fd;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      emo_net_wait_readable(listener);
      continue;
    }
    snprintf(why, whyn, "cannot accept: %s", strerror(errno));
    return -1;
  }
}

/* The TLS listeners' hooks, defined with the fence below: the
   listener's registered context, and the accepting handshake. */
#ifdef EMO_HAS_TLS
typedef struct ssl_ctx_st SSL_CTX;
static SSL_CTX *emo_tls_listener_ctx(int64_t listener);
static emo_value emo_net_accept_tls(int64_t listener, SSL_CTX *lctx);
#endif

emo_value emo_net_accept(int64_t listener) {
#ifdef EMO_HAS_TLS
  SSL_CTX *lctx = emo_tls_listener_ctx(listener);
  if (lctx != NULL) return emo_net_accept_tls(listener, lctx);
#endif
  char why[512];
  int fd = emo_net_accept_fd(listener, why, sizeof why);
  if (fd < 0) return emo_os_pair("error", emo_box_str(emo_str_from_cstr(why)));
  return emo_os_pair("ok", emo_box_i64(fd));
}

/* The TCP leg shared by the plain and TLS connects: the socket, the
   dotted-quad resolve, the blocking connect, the timeout, the
   nonblocking flag. Returns the fd, or -1 with the refusal in [why] —
   the same text the plain connect has always printed. */
static int emo_net_connect_fd(emo_str host, int64_t port, double timeout,
                              char *why, size_t whyn) {
  char *h = emo_cstr_owned(host);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    snprintf(why, whyn, "connect failed");
    free(h);
    return -1;
  }
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, h, &addr.sin_addr) != 1) {
    close(fd);
    snprintf(why, whyn, "cannot resolve host `%s`", h);
    free(h);
    return -1;
  }
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
    if (errno == ECONNREFUSED)
      snprintf(why, whyn, "connection refused to %s:%d", h, (int)port);
    else
      snprintf(why, whyn, "cannot connect to %s:%d: %s", h, (int)port,
               strerror(errno));
    close(fd);
    free(h);
    return -1;
  }
  free(h);
  emo_net_set_timeout(fd, timeout);
  emo_net_nonblock(fd);
  return fd;
}

emo_value emo_net_connect(emo_str host, int64_t port, double timeout) {
  char why[512];
  int fd = emo_net_connect_fd(host, port, timeout, why, sizeof why);
  if (fd < 0) return emo_os_pair("error", emo_box_str(emo_str_from_cstr(why)));
  return emo_os_pair("ok", emo_box_i64(fd));
}

int64_t emo_net_set_timeout(int64_t fd, double seconds) {
  struct timeval tv = {
      (time_t)seconds,
      (suseconds_t)((seconds - (double)(time_t)seconds) * 1000000.0)};
  setsockopt((int)fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  return fd;
}

/* ---- TLS (step 51) ----

   The three net TLS builtins ride the same cooperative scheduler as
   the TCP tier below. Everything OpenSSL-shaped lives behind this
   gate:

   - No OpenSSL header is included anywhere, so no platform needs
     TLS headers: the subset of the frozen 1.1-era client/server core
     the handshakes walk is hand-declared below. The libraries are the
     machine's own — Linux links the distro OpenSSL through the dev
     package's -lssl/-lcrypto symlinks, while macOS has shipped no
     system TLS library for years (no headers since Xcode 10, and the
     /usr/lib dylibs are gone from current releases), so its OpenSSL
     comes from Homebrew or similar and rides --cclib -L<dir>. The
     pre-flight probe (emo_cli) catches a machine without either and
     names the fix instead of surfacing raw linker output.

   - The constants are pinned with provenance: verified once against
     the OpenSSL 3.x headers (ssl.h, tls1.h, prov_ssl.h, x509_vfy.h)
     and held there by the TLS goldens on every CI platform.

   - The CLI defines EMO_HAS_TLS — with -lssl -lcrypto — only when the
     program's IR genuinely reaches one of the three builtins, so a
     program that never touches TLS neither links nor requires
     OpenSSL: the mirror image of the sqlite3 settle, which refused
     baking SQLite into the always-linked runtime; here the runtime is
     the native carrier, so the gate is a compile-time flag rather
     than a package.

   The supported floor is the API subset, not a pinned release:
   OpenSSL >= 1.1.1, LibreSSL >= 3.5.0 (SSL_set1_host completed its
   port there — libressl/portable issue 381). The first context
   creation reads OpenSSL_version_num and refuses below the floor with
   the library's own OpenSSL_version(OPENSSL_VERSION) string. */

#ifdef EMO_HAS_TLS

typedef struct ssl_method_st SSL_METHOD;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_st SSL;
typedef struct x509_store_ctx_st X509_STORE_CTX;

/* The frozen 1.1-era client/server core, and the ERR_* drain. */
const SSL_METHOD *TLS_method(void);
SSL_CTX *SSL_CTX_new(const SSL_METHOD *meth);
void SSL_CTX_free(SSL_CTX *ctx);
long SSL_CTX_ctrl(SSL_CTX *ctx, int cmd, long larg, void *parg);
void SSL_CTX_set_verify(SSL_CTX *ctx, int mode,
                        int (*callback)(int, X509_STORE_CTX *));
int SSL_CTX_set_default_verify_paths(SSL_CTX *ctx);
int SSL_CTX_use_certificate_file(SSL_CTX *ctx, const char *file, int type);
int SSL_CTX_use_PrivateKey_file(SSL_CTX *ctx, const char *file, int type);
SSL *SSL_new(SSL_CTX *ctx);
void SSL_free(SSL *ssl);
int SSL_set_fd(SSL *ssl, int fd);
long SSL_ctrl(SSL *ssl, int cmd, long larg, void *parg);
int SSL_set1_host(SSL *ssl, const char *host);
int SSL_connect(SSL *ssl);
int SSL_accept(SSL *ssl);
int SSL_read(SSL *ssl, void *buf, int num);
int SSL_write(SSL *ssl, const void *buf, int num);
int SSL_shutdown(SSL *ssl);
int SSL_get_error(const SSL *ssl, int ret_code);
long SSL_get_verify_result(const SSL *ssl);
unsigned long OpenSSL_version_num(void);
const char *OpenSSL_version(int type);
unsigned long ERR_get_error(void);
void ERR_error_string_n(unsigned long e, char *buf, size_t len);
void ERR_clear_error(void);

/* Verified against the OpenSSL 3.x headers; see the section comment. */
#define SSL_VERIFY_NONE 0x00
#define SSL_VERIFY_PEER 0x01
#define SSL_VERIFY_FAIL_IF_NO_PEER_CERT 0x02
#define SSL_ERROR_NONE 0
#define SSL_ERROR_SSL 1
#define SSL_ERROR_WANT_READ 2
#define SSL_ERROR_WANT_WRITE 3
#define SSL_ERROR_SYSCALL 5
#define SSL_ERROR_ZERO_RETURN 6
#define X509_V_OK 0
#define SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define SSL_CTRL_SET_MAX_PROTO_VERSION 124
#define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define TLSEXT_NAMETYPE_host_name 0
#define TLS1_2_VERSION 0x0303
#define TLS1_3_VERSION 0x0304
#define SSL_FILETYPE_PEM 1
#define OPENSSL_VERSION 0

/* The side table: fd → SSL* (plus the context the handshake borrowed),
   standing where the ocaml conn's `ltls : Ssl.socket option` stands,
   so the data plane routes a TLS fd through SSL_read/SSL_write while
   every other fd stays raw. */
typedef struct emo_tls_slot {
  int fd;
  SSL *ssl;
  SSL_CTX *ctx;
  struct emo_tls_slot *next;
} emo_tls_slot;

static emo_tls_slot *emo_tls_slots = NULL;

static void emo_tls_attach(int fd, SSL *ssl, SSL_CTX *ctx) {
  emo_tls_slot *s = emo_alloc(sizeof *s);
  s->fd = fd;
  s->ssl = ssl;
  s->ctx = ctx; /* NULL for an accepted conn: the context belongs to
                   the listener and outlives it */
  s->next = emo_tls_slots;
  emo_tls_slots = s;
}

static SSL *emo_tls_lookup(int64_t fd) {
  for (emo_tls_slot *s = emo_tls_slots; s != NULL; s = s->next)
    if (s->fd == (int)fd) return s->ssl;
  return NULL;
}

/* Unlinks the slot, handing back the SSL and its context for the
   caller's shutdown-and-free (the slot cell itself stays in the
   arena, like everything else). */
static SSL *emo_tls_detach(int64_t fd, SSL_CTX **ctx_out) {
  for (emo_tls_slot **p = &emo_tls_slots; *p != NULL; p = &(*p)->next)
    if ((*p)->fd == (int)fd) {
      emo_tls_slot *dead = *p;
      *p = dead->next;
      *ctx_out = dead->ctx;
      return dead->ssl;
    }
  return NULL;
}

/* The version floor: OpenSSL >= 1.1.1 (0x1010100f), LibreSSL >= 3.5.0
   (0x3050000f, the release that completed SSL_set1_host —
   libressl/portable issue 381). Each library's encoding is monotone
   within its own scheme; the banner's first word names the scheme. */
static int emo_tls_floor_ok(void) {
  const char *banner = OpenSSL_version(OPENSSL_VERSION);
  if (strncmp(banner, "LibreSSL", 8) == 0)
    return OpenSSL_version_num() >= 0x3050000fUL;
  return OpenSSL_version_num() >= 0x1010100fUL;
}

/* The ERR_* drain: the first queue entry rendered, the rest dropped —
   an empty queue means the failure carried no library detail. */
static void emo_tls_drain(char *buf, size_t n) {
  unsigned long e = ERR_get_error();
  if (e == 0) {
    snprintf(buf, n, "the library reported no further detail");
    return;
  }
  ERR_error_string_n(e, buf, n);
  while (ERR_get_error() != 0) {}
}

/* The ocaml scheduler's client_tls_ctx: one negotiate-all profile (TLS
   1.2 up to 1.3), verification on with the system trust store — or off
   entirely for the insecure variant, its set_verify [] shape. */
static SSL_CTX *emo_tls_client_ctx(int insecure) {
  SSL_CTX *ctx = SSL_CTX_new(TLS_method());
  if (ctx == NULL) return NULL;
  SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, NULL);
  SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, TLS1_3_VERSION, NULL);
  if (insecure) SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
  else {
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
                       NULL);
    SSL_CTX_set_default_verify_paths(ctx);
  }
  return ctx;
}

/* The second table: listener fd → context, standing where the ocaml
   scheduler's tls_listener record stands. */
typedef struct emo_tls_listener_slot {
  int fd;
  SSL_CTX *ctx;
  struct emo_tls_listener_slot *next;
} emo_tls_listener_slot;

static emo_tls_listener_slot *emo_tls_listeners = NULL;

static void emo_tls_listener_attach(int fd, SSL_CTX *ctx) {
  emo_tls_listener_slot *s = emo_alloc(sizeof *s);
  s->fd = fd;
  s->ctx = ctx;
  s->next = emo_tls_listeners;
  emo_tls_listeners = s;
}

static SSL_CTX *emo_tls_listener_ctx(int64_t listener) {
  for (emo_tls_listener_slot *s = emo_tls_listeners; s != NULL;
       s = s->next)
    if (s->fd == (int)listener) return s->ctx;
  return NULL;
}

/* The server context: the same negotiate-all profile, plus the PEM
   pair. Returns NULL with [why] carrying the drained library detail —
   the caller wraps it in the ocaml-matching certificate reason. */
static SSL_CTX *emo_tls_server_ctx(emo_str cert_path, emo_str key_path,
                                   char *why, size_t whyn) {
  SSL_CTX *ctx = SSL_CTX_new(TLS_method());
  if (ctx == NULL) {
    emo_tls_drain(why, whyn);
    return NULL;
  }
  SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, NULL);
  SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, TLS1_3_VERSION, NULL);
  char *cert = (char *)emo_str_cstr(cert_path);
  char *key = (char *)emo_str_cstr(key_path);
  if (SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) != 1 ||
      SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1) {
    emo_tls_drain(why, whyn);
    SSL_CTX_free(ctx);
    return NULL;
  }
  return ctx;
}

/* The accepting handshake: SSL_accept with the same parking loop as
   the client's, so a loopback handshake on one scheduler progresses
   from both ends. The conn registers before the accept returns, so
   the ocaml scheduler's tls_listener shape is met. */
static emo_value emo_net_accept_tls(int64_t listener, SSL_CTX *lctx) {
  char why[512];
  int fd = emo_net_accept_fd(listener, why, sizeof why);
  if (fd < 0) return emo_os_pair("error", emo_box_str(emo_str_from_cstr(why)));
  SSL *ssl = SSL_new(lctx);
  if (ssl == NULL || SSL_set_fd(ssl, fd) != 1) {
    char drained[256], what[512];
    emo_tls_drain(drained, sizeof drained);
    snprintf(what, sizeof what, "cannot start the TLS handshake: %s", drained);
    if (ssl != NULL) SSL_free(ssl);
    close(fd);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
  }
  for (;;) {
    ERR_clear_error();
    int r = SSL_accept(ssl);
    if (r == 1) {
      emo_tls_attach(fd, ssl, NULL);
      return emo_os_pair("ok", emo_box_i64(fd));
    }
    int err = SSL_get_error(ssl, r);
    if (err == SSL_ERROR_WANT_READ) {
      emo_net_wait_readable(fd);
      continue;
    }
    if (err == SSL_ERROR_WANT_WRITE) {
      emo_net_wait_writable(fd);
      continue;
    }
    char local[64], drained[256], what[768];
    struct sockaddr_in addr;
    socklen_t len = sizeof addr;
    if (getsockname((int)listener, (struct sockaddr *)&addr, &len) == 0)
      snprintf(local, sizeof local, "%s:%d", inet_ntoa(addr.sin_addr),
               (int)ntohs(addr.sin_port));
    else
      snprintf(local, sizeof local, "the listener");
    emo_tls_drain(drained, sizeof drained);
    snprintf(what, sizeof what, "the TLS handshake with %s failed: %s", local,
             drained);
    SSL_free(ssl);
    close(fd);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
  }
}

/* net_listen_tls: the PEM pair loads into a server context first (a
   missing or rejected certificate answers before the socket exists,
   the ocaml tls_listener's order), then the plain listen, then the
   listener registers in the second table. */
emo_value emo_net_listen_tls(emo_str host, int64_t port, emo_str cert_path,
                             emo_str key_path) {
  char *h = (char *)emo_str_cstr(host);
  char why[512];
  SSL_CTX *ctx = emo_tls_server_ctx(cert_path, key_path, why, sizeof why);
  if (ctx == NULL) {
    char what[640];
    snprintf(what, sizeof what, "cannot load the TLS certificate for %s:%d: %s",
             h, (int)port, why);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
  }
  int fd = emo_net_listen_fd(host, port, why, sizeof why);
  if (fd < 0) {
    SSL_CTX_free(ctx);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(why)));
  }
  emo_tls_listener_attach(fd, ctx);
  return emo_os_pair("ok", emo_box_i64(fd));
}

/* net_tls_connect: the TCP leg of the plain connect, then the
   nonblocking handshake — WANT_READ/WANT_WRITE park the fiber through
   the scheduler, exactly where the interpreter parks on ocaml-ssl's
   want_read/want_write. Hostname verification rides the connect
   hostname (skipped, like every check, for the insecure variant); SNI
   skips IP literals. The failure reason keeps the ocaml scheduler's
   prefix — `the TLS handshake with <host>: ` — with the library's own
   wording after it, the one spot byte parity is not claimed. */
emo_value emo_net_tls_connect(emo_str host, int64_t port, double timeout,
                              int insecure) {
  char *h = (char *)emo_str_cstr(host);
  if (!emo_tls_floor_ok()) {
    char what[512];
    snprintf(what, sizeof what,
             "the system TLS library is below the supported floor (OpenSSL"
             " 1.1.1 / LibreSSL 3.5.0): %s",
             OpenSSL_version(OPENSSL_VERSION));
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
  }
  SSL_CTX *ctx = emo_tls_client_ctx(insecure);
  if (ctx == NULL) {
    char drained[256], what[512];
    emo_tls_drain(drained, sizeof drained);
    snprintf(what, sizeof what, "cannot create the TLS context: %s", drained);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
  }
  char why[512];
  int fd = emo_net_connect_fd(host, port, timeout, why, sizeof why);
  if (fd < 0) {
    SSL_CTX_free(ctx);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(why)));
  }
  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL || SSL_set_fd(ssl, fd) != 1) {
    char drained[256], what[512];
    emo_tls_drain(drained, sizeof drained);
    snprintf(what, sizeof what, "cannot start the TLS handshake: %s", drained);
    if (ssl != NULL) SSL_free(ssl);
    close(fd);
    SSL_CTX_free(ctx);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
  }
  if (!insecure) SSL_set1_host(ssl, h);
  struct sockaddr_in skip;
  if (inet_pton(AF_INET, h, &skip.sin_addr) != 1)
    SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name,
             (void *)h);
  for (;;) {
    ERR_clear_error();
    int r = SSL_connect(ssl);
    if (r == 1) {
      emo_tls_attach(fd, ssl, ctx);
      return emo_os_pair("ok", emo_box_i64(fd));
    }
    int err = SSL_get_error(ssl, r);
    if (err == SSL_ERROR_WANT_READ) {
      emo_net_wait_readable(fd);
      continue;
    }
    if (err == SSL_ERROR_WANT_WRITE) {
      emo_net_wait_writable(fd);
      continue;
    }
    char drained[256], what[640];
    emo_tls_drain(drained, sizeof drained);
    snprintf(what, sizeof what, "the TLS handshake with %s:%d failed: %s", h,
             (int)port, drained);
    SSL_free(ssl);
    close(fd);
    SSL_CTX_free(ctx);
    return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
  }
}

#endif /* EMO_HAS_TLS */

/* One read of the fd, TLS-aware when the fence carries the fd in its
   side table: the TLS branch parks on WANT_READ/WANT_WRITE, the raw
   branch on would-block — the same parking discipline both planes
   already share. Returns the byte count, 0 on a clean close, or -1
   with [detail] filled (the library's wording for TLS, errno's for
   raw). */
static int emo_net_read_once(int64_t fd, void *buf, size_t n, char *detail,
                             size_t detailn) {
#ifdef EMO_HAS_TLS
  SSL *ssl = emo_tls_lookup(fd);
  if (ssl != NULL) {
    for (;;) {
      ERR_clear_error();
      int r = SSL_read(ssl, buf, (int)n);
      if (r > 0) return r;
      if (r == 0) return 0;
      int err = SSL_get_error(ssl, r);
      if (err == SSL_ERROR_WANT_READ) {
        emo_net_wait_readable(fd);
        continue;
      }
      if (err == SSL_ERROR_WANT_WRITE) {
        emo_net_wait_writable(fd);
        continue;
      }
      emo_tls_drain(detail, detailn);
      return -1;
    }
  }
#endif
  for (;;) {
    ssize_t got = recv((int)fd, buf, n, 0);
    if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      emo_net_wait_readable(fd);
      continue;
    }
    if (got < 0) snprintf(detail, detailn, "%s", strerror(errno));
    return (int)got;
  }
}

/* One write of the fd, TLS-aware when the fence carries it. The TLS
   branch parks on WANT_READ/WANT_WRITE; the raw branch stays today's
   plain send — would-block surfaces as the caller's error, exactly as
   before. Returns bytes written, or -1 with [detail] filled. */
static int emo_net_write_once(int64_t fd, const void *buf, size_t n,
                              char *detail, size_t detailn) {
#ifdef EMO_HAS_TLS
  SSL *ssl = emo_tls_lookup(fd);
  if (ssl != NULL) {
    for (;;) {
      ERR_clear_error();
      int r = SSL_write(ssl, buf, (int)n);
      if (r > 0) return r;
      int err = SSL_get_error(ssl, r);
      if (err == SSL_ERROR_WANT_READ) {
        emo_net_wait_readable(fd);
        continue;
      }
      if (err == SSL_ERROR_WANT_WRITE) {
        emo_net_wait_writable(fd);
        continue;
      }
      emo_tls_drain(detail, detailn);
      return -1;
    }
  }
#endif
  ssize_t sent = send((int)fd, buf, n, 0);
  if (sent < 0) snprintf(detail, detailn, "%s", strerror(errno));
  return (int)sent;
}

/* One byte at a time is slow but exact; the arena absorbs the growth. */
/* One byte at a time is slow but exact; the line buffer is a malloc'd
   transient that the boxing copies out and frees. */
emo_value emo_net_read_line(int64_t fd) {
  size_t cap = 64;
  char *buf = malloc(cap);
  if (buf == NULL) abort();
  int64_t len = 0;
  for (;;) {
    char detail[256];
    detail[0] = '\0';
    char c;
    int got = emo_net_read_once(fd, &c, 1, detail, sizeof detail);
    if (got == 0) { /* EOF ends the line */
      emo_value out = emo_box_str((emo_str){len, buf});
      free(buf);
      return emo_os_pair("ok", out);
    }
    if (got < 0) {
      char what[512];
      snprintf(what, sizeof what, "cannot read: %s", detail);
      free(buf);
      return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
    }
    if (c == '\n') {
      emo_value out = emo_box_str((emo_str){len, buf});
      free(buf);
      return emo_os_pair("ok", out);
    }
    if (c == '\r') continue;
    if ((size_t)len + 1 > cap) {
      cap *= 2;
      char *bigger = realloc(buf, cap);
      if (bigger == NULL) abort();
      buf = bigger;
    }
    buf[len++] = c;
  }
}

emo_value emo_net_read_exactly(int64_t fd, int64_t n) {
  char *buf = malloc(n > 0 ? (size_t)n : 1);
  if (buf == NULL) abort();
  int64_t got_total = 0;
  while (got_total < n) {
    char detail[256];
    detail[0] = '\0';
    int got = emo_net_read_once(fd, buf + got_total,
                                (size_t)(n - got_total), detail, sizeof detail);
    if (got == 0) {
      free(buf);
      return emo_os_pair(
          "error",
          emo_box_str(emo_str_from_cstr("the connection closed early")));
    }
    if (got < 0) {
      char what[512];
      snprintf(what, sizeof what, "cannot read: %s", detail);
      free(buf);
      return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
    }
    got_total += got;
  }
  emo_value out = emo_box_str((emo_str){n, buf});
  free(buf);
  return emo_os_pair("ok", out);
}

emo_value emo_net_read_all(int64_t fd) {
  size_t cap = 4096;
  char *buf = malloc(cap);
  if (buf == NULL) abort();
  int64_t len = 0;
  for (;;) {
    char detail[256];
    detail[0] = '\0';
    char chunk[4096];
    int got = emo_net_read_once(fd, chunk, sizeof chunk, detail, sizeof detail);
    if (got == 0) {
      emo_value out = emo_box_str((emo_str){len, buf});
      free(buf);
      return emo_os_pair("ok", out);
    }
    if (got < 0) {
      char what[512];
      snprintf(what, sizeof what, "cannot read: %s", detail);
      free(buf);
      return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
    }
    if ((size_t)len + (size_t)got > cap) {
      while ((size_t)len + (size_t)got > cap) cap *= 2;
      char *bigger = realloc(buf, cap);
      if (bigger == NULL) abort();
      buf = bigger;
    }
    memcpy(buf + len, chunk, (size_t)got);
    len += got;
  }
}

emo_value emo_net_write(int64_t fd, emo_str data) {
  int64_t sent_total = 0;
  while (sent_total < data.len) {
    char detail[256];
    detail[0] = '\0';
    int sent =
        emo_net_write_once(fd, data.bytes + sent_total,
                           (size_t)(data.len - sent_total), detail,
                           sizeof detail);
    if (sent < 0) {
      char what[512];
      snprintf(what, sizeof what, "cannot write: %s", detail);
      return emo_os_pair("error", emo_box_str(emo_str_from_cstr(what)));
    }
    sent_total += sent;
  }
  return emo_os_pair("ok", emo_box_i64(fd));
}

emo_value emo_net_close(int64_t fd) {
#ifdef EMO_HAS_TLS
  SSL_CTX *ctx = NULL;
  SSL *ssl = emo_tls_detach(fd, &ctx);
  if (ssl != NULL) {
    SSL_shutdown(ssl); /* best effort: no parking on the way out */
    SSL_free(ssl);
    SSL_CTX_free(ctx);
  }
#endif
  close((int)fd);
  return emo_os_pair("ok", emo_box_i64(fd));
}

#ifndef EMO_HAS_TLS
/* Without the gate, both builtins are today's honest refusal,
   byte-identical to the catch-all they left; the fence above carries
   the real bodies. */
emo_value emo_net_tls_connect(emo_str host, int64_t port, double timeout,
                              int insecure) {
  (void)host;
  (void)port;
  (void)timeout;
  (void)insecure;
  return emo_unsupported("net_tls_connect");
}

emo_value emo_net_listen_tls(emo_str host, int64_t port, emo_str cert_path,
                             emo_str key_path) {
  (void)host;
  (void)port;
  (void)cert_path;
  (void)key_path;
  return emo_unsupported("net_listen_tls");
}
#endif /* !EMO_HAS_TLS */

/* ---- String methods ---- */

emo_str emo_str_substring(emo_str s, int64_t start, int64_t len) {
  if (start < 0 || len < 0 || start + len > s.len)
    emo_fatal("substring is out of bounds for the string");
  return emo_str_from_parts(s.bytes + start, len);
}

int64_t emo_str_index_of(emo_str s, emo_str needle) {
  if (needle.len == 0) return 0;
  for (int64_t i = 0; i + needle.len <= s.len; i++)
    if (memcmp(s.bytes + i, needle.bytes, (size_t)needle.len) == 0) return i;
  return -1;
}

bool emo_str_starts_with(emo_str s, emo_str prefix) {
  return s.len >= prefix.len &&
         memcmp(s.bytes, prefix.bytes, (size_t)prefix.len) == 0;
}

emo_str emo_str_lower(emo_str s) {
  char *p = emo_alloc(s.len);
  for (int64_t i = 0; i < s.len; i++) {
    char c = s.bytes[i];
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    p[i] = c;
  }
  emo_str out = {s.len, p};
  return out;
}

emo_str emo_str_trim(emo_str s) {
  int64_t lo = 0, hi = s.len;
  while (lo < hi && (unsigned char)s.bytes[lo] <= ' ') lo++;
  while (hi > lo && (unsigned char)s.bytes[hi - 1] <= ' ') hi--;
  return emo_str_from_parts(s.bytes + lo, hi - lo);
}

int64_t emo_str_length(emo_str s) { return s.len; }

int64_t emo_str_to_int64(emo_str s) {
  char *clean = (char *)emo_str_cstr(emo_str_trim(s));
  char *end = NULL;
  long long v = strtoll(clean, &end, 10);
  if (end == clean || *end != '\0') {
    fprintf(stderr, "uncaught exception: cannot parse `%.*s` as an Int64\n",
            (int)s.len, s.bytes);
    exit(70);
  }
  return (int64_t)v;
}

emo_value emo_str_split(emo_str s, emo_str sep) {
  if (sep.len == 0) emo_fatal("the separator must not be empty");
  int64_t parts = 1;
  for (int64_t i = 0; i + sep.len <= s.len;)
    if (memcmp(s.bytes + i, sep.bytes, (size_t)sep.len) == 0) {
      parts++;
      i += sep.len;
    } else
      i++;
  emo_value *elems = emo_alloc((size_t)parts * sizeof(emo_value));
  int64_t count = 0, start = 0;
  for (int64_t i = 0; i + sep.len <= s.len;) {
    if (memcmp(s.bytes + i, sep.bytes, (size_t)sep.len) == 0) {
      elems[count++] =
          (uintptr_t)emo_box_str(emo_str_from_parts(s.bytes + start, i - start));
      i += sep.len;
      start = i;
    } else
      i++;
  }
  elems[count++] =
      (uintptr_t)emo_box_str(emo_str_from_parts(s.bytes + start, s.len - start));
  return emo_array_new(count, elems);
}

EMO_NORETURN int64_t emo_unsupported(const char *what) {
  fprintf(stderr,
          "uncaught exception: %s is not supported on this target yet\n",
          what);
  exit(70);
}

emo_value emo_make_exception(emo_value message) {
  /* the Exception value IS the message cell; the claim passes through */
  return message;
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
  /* [header][len][bytes...] — the cell arrives zeroed; the explicit
     clear keeps the contract local to the constructor. */
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

emo_value emo_bytes_of_str(emo_value s) {
  emo_str str = emo_str_of(s); /* a borrow: the cell outlives the call */
  emo_value v = emo_cell_new(EMO_BYTES, 1 + (str.len + 7) / 8);
  uintptr_t *p = emo_payload(v);
  p[0] = (uintptr_t)str.len;
  memcpy(p + 1, str.bytes, (size_t)str.len);
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

double emo_f64_sqrt(double x) { return sqrt(x); }
double emo_f64_floor(double x) { return floor(x); }
double emo_f64_ceil(double x) { return ceil(x); }
double emo_f64_trunc(double x) { return trunc(x); }

/* ---- the os module: synchronous POSIX syscalls ---- */

int64_t emo_os_getpid(void) { return (int64_t)getpid(); }

int64_t emo_os_getppid(void) { return (int64_t)getppid(); }

emo_value emo_os_fork(void) { return emo_os_ok(emo_box_i64((int64_t)fork())); }

int64_t emo_os_waitpid(int64_t pid) {
  int st = 0;
  if (waitpid((pid_t)pid, &st, 0) < 0) {
    char buf[512];
    snprintf(buf, sizeof buf, "os: waitpid: %s", strerror(errno));
    emo_raise(emo_make_exception(emo_cell_from_cstr(buf)));
  }
  emo_value elems[2];
  elems[0] = emo_box_i64(pid);
  elems[1] = emo_box_i64((int64_t)st);
  return emo_tuple_new(2, elems);
}

emo_value emo_os_pipe(void) {
  int fds[2];
  if (pipe(fds) != 0)
    return emo_os_fail("pipe", "");
  emo_value elems[2];
  elems[0] = emo_box_i64(fds[0]);
  elems[1] = emo_box_i64(fds[1]);
  return emo_os_ok(emo_tuple_new(2, elems));
}

int64_t emo_os_execv(emo_str path, emo_value argv) {
  char *p = emo_cstr_owned(path);
  int64_t count = emo_length(argv);
  char **argv_c = malloc(sizeof(char *) * (size_t)(count + 1));
  if (argv_c == NULL) abort();
  for (int64_t i = 0; i < count; i++) {
    argv_c[i] = emo_cstr_owned(emo_str_of(emo_index(argv, i)));
  }
  argv_c[count] = NULL;
  execv(p, argv_c);
  /* Failure is a data-driven value: the call returns (the value is
     discarded) — the fork child's cue to `_exit` (a raise here would
     run the parent's cleanup a second time). */
  for (int64_t i = 0; i < count; i++) free(argv_c[i]);
  free(argv_c);
  free(p);
  return 0;
}

void emo_os__exit(int64_t status) { _exit((int)status); }

emo_value emo_os_open_read(emo_str path) {
  char *p = emo_cstr_owned(path);
  int fd = open(p, O_RDONLY);
  if (fd < 0) {
    emo_value out = emo_os_fail("open", p);
    free(p);
    return out;
  }
  free(p);
  return emo_os_ok(emo_box_i64(fd));
}

emo_value emo_os_open_write(emo_str path) {
  char *p = emo_cstr_owned(path);
  int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    emo_value out = emo_os_fail("open", p);
    free(p);
    return out;
  }
  free(p);
  return emo_os_ok(emo_box_i64(fd));
}

emo_value emo_os_open_append(emo_str path) {
  char *p = emo_cstr_owned(path);
  int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) {
    emo_value out = emo_os_fail("open", p);
    free(p);
    return out;
  }
  free(p);
  return emo_os_ok(emo_box_i64(fd));
}

emo_value emo_os_read(int64_t fd, int64_t n) {
  if (n <= 0)
    return emo_os_ok(emo_box_str((emo_str){0, ""}));
  char *buf = malloc((size_t)n);
  if (buf == NULL) abort();
  ssize_t got = read((int)fd, buf, (size_t)n);
  if (got < 0) {
    free(buf);
    return emo_os_fail("read", "");
  }
  emo_value out = emo_box_str((emo_str){(int64_t)got, buf});
  free(buf);
  return emo_os_ok(out);
}

emo_value emo_os_write(int64_t fd, emo_str data) {
  ssize_t put = write((int)fd, data.bytes, (size_t)data.len);
  if (put < 0)
    return emo_os_fail("write", "");
  return emo_os_ok(emo_box_i64((int64_t)put));
}

emo_value emo_os_close(int64_t fd) {
  if (close((int)fd) != 0)
    return emo_os_fail("close", "");
  return emo_os_ok(emo_box_i64(0));
}

static int emo_os_cmp_cstr(const void *a, const void *b) {
  return strcmp(*(const char **)a, *(const char **)b);
}

emo_value emo_os_list_dir(emo_str path) {
  char *p = emo_cstr_owned(path);
  DIR *d = opendir(p);
  if (d == NULL) {
    emo_value out = emo_os_fail("opendir", p);
    free(p);
    return out;
  }
  free(p);
  size_t count = 0;
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
      continue;
    count++;
  }
  size_t slot = count > 0 ? count : 1;
  char **names = malloc(sizeof(char *) * slot);
  if (names == NULL) abort();
  rewinddir(d);
  size_t i = 0;
  while ((ent = readdir(d)) != NULL) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
      continue;
    names[i] = strdup(ent->d_name);
    if (names[i] == NULL) abort();
    i++;
  }
  closedir(d);
  qsort(names, count, sizeof(char *), emo_os_cmp_cstr);
  emo_value *elems = malloc(sizeof(emo_value) * slot);
  if (elems == NULL) abort();
  for (size_t k = 0; k < count; k++) {
    elems[k] = emo_cell_from_cstr(names[k]);
    free(names[k]);
  }
  free(names);
  emo_value out = emo_array_new((int64_t)count, elems);
  free(elems);
  return emo_os_ok(out);
}

emo_value emo_os_mkdir(emo_str path) {
  char *p = emo_cstr_owned(path);
  int rc = mkdir(p, 0755);
  if (rc != 0) {
    emo_value out = emo_os_fail("mkdir", p);
    free(p);
    return out;
  }
  free(p);
  return emo_os_ok(emo_box_i64(0));
}

emo_value emo_os_rmdir(emo_str path) {
  char *p = emo_cstr_owned(path);
  int rc = rmdir(p);
  if (rc != 0) {
    emo_value out = emo_os_fail("rmdir", p);
    free(p);
    return out;
  }
  free(p);
  return emo_os_ok(emo_box_i64(0));
}

emo_value emo_os_unlink(emo_str path) {
  char *p = emo_cstr_owned(path);
  int rc = unlink(p);
  if (rc != 0) {
    emo_value out = emo_os_fail("unlink", p);
    free(p);
    return out;
  }
  free(p);
  return emo_os_ok(emo_box_i64(0));
}

emo_value emo_os_rename(emo_str old_path, emo_str new_path) {
  char *o = emo_cstr_owned(old_path);
  char *n = emo_cstr_owned(new_path);
  int rc = rename(o, n);
  if (rc != 0) {
    emo_value out = emo_os_fail("rename", o);
    free(o);
    free(n);
    return out;
  }
  free(o);
  free(n);
  return emo_os_ok(emo_box_i64(0));
}

emo_value emo_os_getcwd(void) {
  char buf[4096];
  if (getcwd(buf, sizeof buf) == NULL) emo_fatal("getcwd failed");
  return emo_box_str((emo_str){(int64_t)strlen(buf), buf});
}

emo_value emo_os_chdir(emo_str path) {
  char *p = emo_cstr_owned(path);
  int rc = chdir(p);
  if (rc != 0) {
    emo_value out = emo_os_fail("chdir", p);
    free(p);
    return out;
  }
  free(p);
  return emo_os_ok(emo_box_i64(0));
}

/* ---- The dynamic builtin send ----

   A method call whose receiver the checker could not type (the value
   crossed a module boundary) may name an instance method, a String
   method, a socket method, or a List method. An instance answers
   through its vtable — these names may be that very method — and only
   a non-instance falls to the builtin that owns the name. The receiver
   is evaluated once, here. */

typedef struct {
  const char *name;
  int64_t arity;
  emo_value (*fn)(emo_value recv, const emo_value *args);
} emo_builtin_method;

static emo_value emo_bm_substring(emo_value recv, const emo_value *args) {
  return emo_box_str(emo_str_substring(emo_str_of(recv),
                                       emo_unbox_i64(args[0]),
                                       emo_unbox_i64(args[1])));
}

static emo_value emo_bm_index_of(emo_value recv, const emo_value *args) {
  return emo_box_i64(emo_str_index_of(emo_str_of(recv), emo_str_of(args[0])));
}

static emo_value emo_bm_starts_with(emo_value recv, const emo_value *args) {
  return emo_vbool(
      emo_str_starts_with(emo_str_of(recv), emo_str_of(args[0])));
}

static emo_value emo_bm_lower(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_str(emo_str_lower(emo_str_of(recv)));
}

static emo_value emo_bm_trim(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_str(emo_str_trim(emo_str_of(recv)));
}

static emo_value emo_bm_to_int64(emo_value recv, const emo_value *args) {
  (void)args;
  switch (emo_cell_kind(recv)) {
    case EMO_FLOAT64:
      return emo_box_i64((int64_t)emo_unbox_f64(recv));
    case EMO_INT64:
      return emo_retain(recv); /* the pass-through is a claim, like every
                                  builtin answer */
    default:
      return emo_box_i64(emo_str_to_int64(emo_str_of(recv)));
  }
}

static emo_value emo_bm_split(emo_value recv, const emo_value *args) {
  return emo_str_split(emo_str_of(recv), emo_str_of(args[0]));
}

static emo_value emo_bm_read_line(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_net_read_line(emo_unbox_i64(recv));
}

static emo_value emo_bm_read_exactly(emo_value recv, const emo_value *args) {
  return emo_net_read_exactly(emo_unbox_i64(recv), emo_unbox_i64(args[0]));
}

static emo_value emo_bm_read_all(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_net_read_all(emo_unbox_i64(recv));
}

static emo_value emo_bm_write(emo_value recv, const emo_value *args) {
  return emo_net_write(emo_unbox_i64(recv), emo_str_of(args[0]));
}

static emo_value emo_bm_close(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_net_close(emo_unbox_i64(recv));
}

static emo_value emo_bm_set_timeout(emo_value recv, const emo_value *args) {
  return emo_box_i64(
      emo_net_set_timeout(emo_unbox_i64(recv), emo_unbox_f64(args[0])));
}

static emo_value emo_bm_accept(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_net_accept(emo_unbox_i64(recv));
}

static emo_value emo_bm_port(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_i64(emo_net_port(emo_unbox_i64(recv)));
}

static emo_value emo_bm_push_front(emo_value recv, const emo_value *args) {
  return emo_list_push_front(recv, args[0]);
}

static emo_value emo_bm_push_back(emo_value recv, const emo_value *args) {
  return emo_list_push_back(recv, args[0]);
}

static emo_value emo_bm_pop_front(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_list_pop_front(recv);
}

static emo_value emo_bm_pop_back(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_list_pop_back(recv);
}

static emo_value emo_bm_length(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_i64(emo_length(recv));
}

static emo_value emo_bm_to_string(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_to_string_cell(recv); /* the answer is a cell */
}

/* The gradual call sites dispatch through the name/arity table when the
   checker could not pin the receiver; the payload's own kind picks the
   family — a Map and Bytes share the `get`/`set` spellings but not the
   mechanics. */
static emo_value emo_bm_get(emo_value recv, const emo_value *args) {
  if (emo_cell_kind(recv) == EMO_MAP) return emo_map_get(recv, args[0]);
  if (emo_cell_kind(recv) == EMO_BUILDER)
    return emo_builder_get(recv, emo_unbox_i64(args[0]));
  return emo_box_i64(emo_bytes_get(recv, emo_unbox_i64(args[0])));
}

static emo_value emo_bm_push(emo_value recv, const emo_value *args) {
  return emo_builder_push(recv, args[0]);
}

static emo_value emo_bm_to_array(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_builder_to_array(recv);
}

static emo_value emo_bm_set(emo_value recv, const emo_value *args) {
  if (emo_cell_kind(recv) == EMO_MAP)
    return emo_map_set(recv, args[0], args[1]);
  return emo_box_i64(
      emo_bytes_set(recv, emo_unbox_i64(args[0]), emo_unbox_i64(args[1])));
}

static emo_value emo_bm_get_u16_le(emo_value recv, const emo_value *args) {
  return emo_box_i64(emo_bytes_get_u16_le(recv, emo_unbox_i64(args[0])));
}

static emo_value emo_bm_get_u32_le(emo_value recv, const emo_value *args) {
  return emo_box_i64(emo_bytes_get_u32_le(recv, emo_unbox_i64(args[0])));
}

static emo_value emo_bm_get_u64_le(emo_value recv, const emo_value *args) {
  return emo_box_i64(emo_bytes_get_u64_le(recv, emo_unbox_i64(args[0])));
}

static emo_value emo_bm_set_u16_le(emo_value recv, const emo_value *args) {
  return emo_box_i64(emo_bytes_set_u16_le(
      recv, emo_unbox_i64(args[0]), emo_unbox_i64(args[1])));
}

static emo_value emo_bm_set_u32_le(emo_value recv, const emo_value *args) {
  return emo_box_i64(emo_bytes_set_u32_le(
      recv, emo_unbox_i64(args[0]), emo_unbox_i64(args[1])));
}

static emo_value emo_bm_set_u64_le(emo_value recv, const emo_value *args) {
  return emo_box_i64(emo_bytes_set_u64_le(
      recv, emo_unbox_i64(args[0]), emo_unbox_i64(args[1])));
}

static emo_value emo_bm_has(emo_value recv, const emo_value *args) {
  return emo_vbool(emo_map_has(recv, args[0]));
}

static emo_value emo_bm_remove(emo_value recv, const emo_value *args) {
  return emo_map_remove(recv, args[0]);
}

static emo_value emo_bm_keys(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_map_keys(recv);
}

static emo_value emo_bm_values(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_map_values(recv);
}

static emo_value emo_bm_read(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_read(recv);
}

static emo_value emo_bm_replace(emo_value recv, const emo_value *args) {
  return emo_box_replace(recv, args[0]);
}

static emo_value emo_bm_append(emo_value recv, const emo_value *args) {
  return emo_array_append(recv, args[0]);
}

static emo_value emo_bm_to_bytes(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_bytes_of_str(recv);
}

static emo_value emo_bm_to_bits(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_i64(emo_f64_bits(emo_unbox_f64(recv)));
}

static emo_value emo_bm_to_float64(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_f64((double)emo_unbox_i64(recv));
}

static emo_value emo_bm_sqrt(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_f64(emo_f64_sqrt(emo_unbox_f64(recv)));
}

static emo_value emo_bm_floor(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_f64(emo_f64_floor(emo_unbox_f64(recv)));
}

static emo_value emo_bm_ceil(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_f64(emo_f64_ceil(emo_unbox_f64(recv)));
}

static emo_value emo_bm_trunc(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_f64(emo_f64_trunc(emo_unbox_f64(recv)));
}

static emo_value emo_bm_to_byte(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_i64(emo_unbox_i64(recv) & 255);
}

static const emo_builtin_method emo_builtin_methods[] = {
    {"substring", 2, emo_bm_substring},
    {"index_of", 1, emo_bm_index_of},
    {"starts_with", 1, emo_bm_starts_with},
    {"lower", 0, emo_bm_lower},
    {"trim", 0, emo_bm_trim},
    {"to_int64", 0, emo_bm_to_int64},
    {"split", 1, emo_bm_split},
    {"read_line", 0, emo_bm_read_line},
    {"read_exactly", 1, emo_bm_read_exactly},
    {"read_all", 0, emo_bm_read_all},
    {"write", 1, emo_bm_write},
    {"close", 0, emo_bm_close},
    {"set_timeout", 1, emo_bm_set_timeout},
    {"accept", 0, emo_bm_accept},
    {"port", 0, emo_bm_port},
    {"push_front", 1, emo_bm_push_front},
    {"push_back", 1, emo_bm_push_back},
    {"pop_front", 0, emo_bm_pop_front},
    {"pop_back", 0, emo_bm_pop_back},
    {"push", 1, emo_bm_push},
    {"to_array", 0, emo_bm_to_array},
    {"length", 0, emo_bm_length},
    {"to_string", 0, emo_bm_to_string},
    {"get", 1, emo_bm_get},
    {"set", 2, emo_bm_set},
    {"get_u16_le", 1, emo_bm_get_u16_le},
    {"get_u32_le", 1, emo_bm_get_u32_le},
    {"get_u64_le", 1, emo_bm_get_u64_le},
    {"set_u16_le", 2, emo_bm_set_u16_le},
    {"set_u32_le", 2, emo_bm_set_u32_le},
    {"set_u64_le", 2, emo_bm_set_u64_le},
    {"has", 1, emo_bm_has},
    {"remove", 1, emo_bm_remove},
    {"keys", 0, emo_bm_keys},
    {"values", 0, emo_bm_values},
    {"read", 0, emo_bm_read},
    {"replace", 1, emo_bm_replace},
    {"append", 1, emo_bm_append},
    {"to_bytes", 0, emo_bm_to_bytes},
    {"to_bits", 0, emo_bm_to_bits},
    {"to_byte", 0, emo_bm_to_byte},
    {"to_float64", 0, emo_bm_to_float64},
    {"sqrt", 0, emo_bm_sqrt},
    {"floor", 0, emo_bm_floor},
    {"ceil", 0, emo_bm_ceil},
    {"trunc", 0, emo_bm_trunc},
};

emo_value emo_dynamic_builtin(emo_value recv, const char *name, int64_t arity,
                              const emo_value *args) {
  if (emo_is_instance(recv))
    return emo_send(recv, name, arity, args);
  for (size_t i = 0; i < sizeof emo_builtin_methods / sizeof *emo_builtin_methods;
       i++) {
    const emo_builtin_method *m = &emo_builtin_methods[i];
    if ((int64_t)m->arity == arity && strcmp(m->name, name) == 0)
      return m->fn(recv, args); /* every builtin hands the caller a claim */
  }
  fprintf(stderr, "runtime error: message not understood: %s/%lld\n", name,
          (long long)arity);
  exit(70);
}
