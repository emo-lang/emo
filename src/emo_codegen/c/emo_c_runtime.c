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

/* ---- The List deque ----

   A List is an identity, like a Box: [header][emo_list *], the struct
   owning a doubly-linked node chain — O(1) push and pop at both ends.
   Nodes ride the bump allocator like every cell, under the same
   provisional reclamation profile (CHECK.md frees nothing). */

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
  emo_list *l = emo_alloc(sizeof(emo_list));
  l->head = NULL;
  l->tail = NULL;
  l->size = 0;
  int64_t n = (int64_t)emo_payload(arr)[0];
  for (int64_t i = 0; i < n; i++) {
    emo_list_node *node = emo_alloc(sizeof(emo_list_node));
    node->v = (emo_value)emo_payload(arr)[i + 1];
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
  emo_list_node *node = emo_alloc(sizeof(emo_list_node));
  node->v = v;
  node->prev = NULL;
  node->next = list->head;
  if (list->head != NULL)
    list->head->prev = node;
  else
    list->tail = node;
  list->head = node;
  list->size++;
  return l;
}

emo_value emo_list_push_back(emo_value l, emo_value v) {
  emo_list *list = emo_list_of(l);
  emo_list_node *node = emo_alloc(sizeof(emo_list_node));
  node->v = v;
  node->prev = list->tail;
  node->next = NULL;
  if (list->tail != NULL)
    list->tail->next = node;
  else
    list->head = node;
  list->tail = node;
  list->size++;
  return l;
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
  return node->v;
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

/* ---- The Map ----

   A mutable, insertion-ordered hash table. The cell payload:
   [count][cap][entries][bucket_mask][buckets]. Entries live in an
   append-only array (indices never move, so array order is insertion
   order; a removed entry's key becomes 0), chained through `next`
   into an open bucket array rehashed at a 0.5 load factor. Keys are
   the primitive kinds only — the same rule the checker enforces when
   it can prove one — validated at every insertion. */

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
    emo_map_set(m, (emo_value)emo_payload(pair)[1],
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
  return ((emo_map_entry *)emo_payload(m)[2])[i].value;
}

emo_value emo_map_set(emo_value m, emo_value key, emo_value value) {
  emo_expect_kind(m, EMO_MAP);
  if (!emo_map_key_ok(key)) emo_fatal(emo_map_key_rule);
  int64_t i = emo_map_find(m, key);
  uintptr_t *p = emo_payload(m);
  if (i >= 0) {
    ((emo_map_entry *)p[2])[i].value = value;
    return m;
  }
  int64_t cap = (int64_t)p[1];
  int64_t count = (int64_t)p[0];
  if (cap == count) {
    int64_t ncap = cap < 8 ? 8 : cap * 2;
    emo_map_entry *entries =
        emo_alloc((size_t)ncap * sizeof(emo_map_entry));
    if (cap > 0)
      memcpy(entries, (void *)p[2], (size_t)cap * sizeof(emo_map_entry));
    memset(entries + cap, 0, (size_t)(ncap - cap) * sizeof(emo_map_entry));
    p[1] = (uintptr_t)ncap;
    p[2] = (uintptr_t)entries;
  }
  emo_map_entry *entries = (emo_map_entry *)p[2];
  entries[count].key = key;
  entries[count].value = value;
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
  return m;
}

/* Rehashes every live entry into a bucket array sized for the load. */
static void emo_map_rehash(emo_value m) {
  uintptr_t *p = emo_payload(m);
  int64_t cap = (int64_t)p[1];
  int64_t nbuckets = 8;
  while ((uint64_t)cap * 2 > (uint64_t)nbuckets) nbuckets <<= 1;
  int64_t *buckets = emo_alloc((size_t)nbuckets * sizeof(int64_t));
  for (int64_t i = 0; i < nbuckets; i++) buckets[i] = -1;
  emo_map_entry *entries = (emo_map_entry *)p[2];
  uintptr_t mask = (uintptr_t)(nbuckets - 1);
  for (int64_t i = 0; i < cap; i++) {
    if (entries[i].key == 0) continue;
    uint64_t h = emo_hash_key(entries[i].key);
    entries[i].next = buckets[h & mask];
    buckets[h & mask] = i;
  }
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
  if (!emo_map_key_ok(key)) return m; /* never storable, so never present */
  uintptr_t *p = emo_payload(m);
  if (p[4] == (uintptr_t)NULL) return m;
  emo_map_entry *entries = (emo_map_entry *)p[2];
  int64_t *buckets = (int64_t *)p[4];
  uintptr_t mask = p[3];
  int64_t *link = &buckets[emo_hash_key(key) & mask];
  while (*link >= 0) {
    emo_map_entry *e = &entries[*link];
    if (e->key != 0 && emo_eq_dyn(e->key, key)) {
      e->key = 0;
      *link = e->next;
      p[0] = (uintptr_t)((int64_t)p[0] - 1);
      return m;
    }
    link = &e->next;
  }
  return m;
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
  emo_payload(instance)[i + 1] = (uintptr_t)v;
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
  uintptr_t k = emo_cell_kind(v);
  if (k == EMO_LIST) return emo_list_length(v);
  if (k != EMO_TUPLE && k != EMO_ARRAY && k != EMO_BYTES && k != EMO_STRING)
    emo_fatal("only strings, Bytes, tuples, arrays, and Lists have a length");
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
  char *nb = emo_alloc(cap);
  if (b->bytes != NULL) memcpy(nb, b->bytes, b->len);
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
}

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

emo_str emo_to_string_method(emo_value v) {
  if (emo_cell_kind(v) == EMO_BYTES) return emo_str_of_bytes(v);
  return emo_to_string_dyn(v);
}

/* ---- Processes and the cooperative scheduler ---- */

typedef struct emo_msg {
  struct emo_msg *next;
  emo_value v;
} emo_msg;

typedef struct emo_process {
  int64_t pid;
  ucontext_t ctx;
  struct emo_process *next_run;   /* the run queue's linkage */
  struct emo_process *next_table; /* the live-process table's linkage */
  emo_msg *inbox_head, *inbox_tail;
  int blocked;     /* parked on receive or io */
  int finished;    /* body returned or halted */
  int64_t wait_fd; /* -1: parked on a mailbox; >= 0: parked on readability */
  emo_value *spawn_args;
  void (*entry)(void);
  void *stack; /* the fiber's malloc'd stack — ctx.uc_stack is clobbered
                  by swapcontext on save */
} emo_process;

static emo_process *emo_runq_head = NULL, *emo_runq_tail = NULL;
static emo_process *emo_process_table = NULL;
static emo_process **emo_process_table_tail = &emo_process_table;
static emo_process *emo_current = NULL;
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
  p->entry = entry;
  if (nargs > 0) {
    p->spawn_args = malloc((size_t)nargs * sizeof(emo_value));
    if (p->spawn_args == NULL) abort();
    memcpy(p->spawn_args, args, (size_t)nargs * sizeof(emo_value));
  }
  const size_t stack_size = 256 * 1024;
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
  emo_current->finished = 1;
  swapcontext(&emo_current->ctx, &emo_sched_ctx);
  abort(); /* unreachable */
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
  m->v = message;
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
          fds[n].events = POLLIN;
          fds[n].revents = 0;
          waiters[n] = q;
          n++;
        }
      if (n > 0) {
        poll(fds, (nfds_t)n, 100);
        int woke = 0;
        for (int i = 0; i < n; i++)
          if (fds[i].revents & (POLLIN | POLLERR | POLLHUP)) {
            waiters[i]->blocked = 0;
            waiters[i]->wait_fd = -1;
            emo_runq_push(waiters[i]);
            woke = 1;
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

static void emo_io_fatal(emo_str what, const char *detail) {
  fprintf(stderr, "uncaught exception: %.*s (%s)\n", (int)what.len,
          what.bytes, detail);
  exit(70);
}

static emo_str emo_str_from_parts(const char *p, int64_t n) {
  char *buf = emo_alloc(n);
  memcpy(buf, p, (size_t)n);
  emo_str s = {n, buf};
  return s;
}

emo_str emo_file_read(emo_str path) {
  char *clean = (char *)emo_str_cstr(path);
  FILE *f = fopen(clean, "rb");
  if (f == NULL)
    emo_io_fatal(emo_str_concat((emo_str){13, "read failed: "}, path),
                 strerror(errno));
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  emo_str out = emo_str_from_parts("", n);
  size_t got = fread((char *)out.bytes, 1, (size_t)n, f);
  fclose(f);
  if ((long)got != n)
    emo_io_fatal(emo_str_concat((emo_str){13, "read failed: "}, path),
                 "short read");
  return out;
}

int64_t emo_file_write(emo_str path, emo_str contents) {
  char *clean = (char *)emo_str_cstr(path);
  FILE *f = fopen(clean, "wb");
  if (f == NULL)
    emo_io_fatal(emo_str_concat((emo_str){13, "write failed: "}, path),
                 strerror(errno));
  size_t put = fwrite(contents.bytes, 1, (size_t)contents.len, f);
  fclose(f);
  if ((int64_t)put != contents.len)
    emo_io_fatal(emo_str_concat((emo_str){13, "write failed: "}, path),
                 "short write");
  return contents.len;
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
  emo_current->blocked = 1;
  swapcontext(&emo_current->ctx, &emo_sched_ctx);
}

int64_t emo_net_listen(emo_str host, int64_t port) {
  char *h = (char *)emo_str_cstr(host);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) emo_net_fatal("listen failed", strerror(errno));
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, h, &addr.sin_addr) != 1) {
    close(fd);
    emo_net_fatal("listen failed", "invalid host");
  }
  if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 ||
      listen(fd, 16) < 0) {
    close(fd);
    emo_net_fatal("listen failed", strerror(errno));
  }
  emo_net_nonblock(fd);
  return fd;
}

int64_t emo_net_port(int64_t listener) {
  struct sockaddr_in addr;
  socklen_t len = sizeof addr;
  if (getsockname((int)listener, (struct sockaddr *)&addr, &len) < 0)
    emo_net_fatal("port failed", strerror(errno));
  return ntohs(addr.sin_port);
}

int64_t emo_net_accept(int64_t listener) {
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
    emo_net_fatal("accept failed", strerror(errno));
  }
}

int64_t emo_net_connect(emo_str host, int64_t port, double timeout) {
  char *h = (char *)emo_str_cstr(host);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) emo_net_fatal("connect failed", strerror(errno));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, h, &addr.sin_addr) != 1) {
    close(fd);
    emo_net_fatal("connect failed", "invalid host");
  }
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0)
    emo_net_fatal("connect failed", strerror(errno));
  emo_net_set_timeout(fd, timeout);
  emo_net_nonblock(fd);
  return fd;
}

int64_t emo_net_set_timeout(int64_t fd, double seconds) {
  struct timeval tv = {
      (time_t)seconds,
      (suseconds_t)((seconds - (double)(time_t)seconds) * 1000000.0)};
  setsockopt((int)fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  return fd;
}

/* One byte at a time is slow but exact; the arena absorbs the growth. */
emo_str emo_net_read_line(int64_t fd) {
  emo_str out = emo_str_from_parts("", 0);
  for (;;) {
    char c;
    ssize_t got = recv((int)fd, &c, 1, 0);
    if (got == 0) return out; /* EOF ends the line */
    if (got < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        emo_net_wait_readable(fd);
        continue;
      }
      emo_net_fatal("read failed", strerror(errno));
    }
    if (c == '\n') return out;
    if (c == '\r') continue;
    char *bigger = emo_alloc(out.len + 1);
    memcpy(bigger, out.bytes, (size_t)out.len);
    bigger[out.len] = c;
    out.bytes = bigger;
    out.len += 1;
  }
}

emo_str emo_net_read_exactly(int64_t fd, int64_t n) {
  emo_str out = emo_str_from_parts("", n);
  int64_t got_total = 0;
  while (got_total < n) {
    ssize_t got = recv((int)fd, (char *)out.bytes + got_total,
                       (size_t)(n - got_total), 0);
    if (got == 0) emo_net_fatal("read failed", "the connection closed early");
    if (got < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        emo_net_wait_readable(fd);
        continue;
      }
      emo_net_fatal("read failed", strerror(errno));
    }
    got_total += got;
  }
  return out;
}

emo_str emo_net_read_all(int64_t fd) {
  emo_str out = emo_str_from_parts("", 0);
  for (;;) {
    char chunk[4096];
    ssize_t got = recv((int)fd, chunk, sizeof chunk, 0);
    if (got == 0) return out;
    if (got < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        emo_net_wait_readable(fd);
        continue;
      }
      emo_net_fatal("read failed", strerror(errno));
    }
    char *bigger = emo_alloc(out.len + got);
    memcpy(bigger, out.bytes, (size_t)out.len);
    memcpy(bigger + out.len, chunk, (size_t)got);
    out.bytes = bigger;
    out.len += got;
  }
}

int64_t emo_net_write(int64_t fd, emo_str data) {
  int64_t sent_total = 0;
  while (sent_total < data.len) {
    ssize_t sent =
        send((int)fd, data.bytes + sent_total, (size_t)(data.len - sent_total), 0);
    if (sent < 0) emo_net_fatal("write failed", strerror(errno));
    sent_total += sent;
  }
  return data.len;
}

int64_t emo_net_close(int64_t fd) {
  close((int)fd);
  return fd;
}

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

emo_value emo_make_exception(emo_str message) {
  return emo_box_str(message);
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

/* ---- the os module: synchronous POSIX syscalls ---- */

static int64_t emo_os_fail(const char *what, const char *arg) {
  char buf[512];
  if (arg[0] == 0)
    snprintf(buf, sizeof buf, "os: %s: %s", what, strerror(errno));
  else
    snprintf(buf, sizeof buf, "os: %s %s: %s", what, arg, strerror(errno));
  emo_raise(emo_make_exception(emo_str_from_cstr(buf)));
  return 0; /* unreachable: emo_raise exits */
}

int64_t emo_os_getpid(void) { return (int64_t)getpid(); }

int64_t emo_os_getppid(void) { return (int64_t)getppid(); }

int64_t emo_os_fork(void) { return (int64_t)fork(); }

int64_t emo_os_waitpid(int64_t pid) {
  int st = 0;
  if (waitpid((pid_t)pid, &st, 0) < 0)
    return (int64_t)emo_os_fail("waitpid", "");
  emo_value elems[2];
  elems[0] = emo_box_i64(pid);
  elems[1] = emo_box_i64((int64_t)st);
  return emo_tuple_new(2, elems);
}

int64_t emo_os_pipe(void) {
  int fds[2];
  if (pipe(fds) != 0)
    return (int64_t)emo_os_fail("pipe", "");
  emo_value elems[2];
  elems[0] = emo_box_i64(fds[0]);
  elems[1] = emo_box_i64(fds[1]);
  return emo_tuple_new(2, elems);
}

int64_t emo_os_execv(emo_str path, emo_value argv) {
  char *p = (char *)emo_str_cstr(path);
  int64_t count = emo_length(argv);
  char **argv_c = (char **)emo_alloc(sizeof(char *) * (size_t)(count + 1));
  for (int64_t i = 0; i < count; i++) {
    emo_str item = emo_str_of(emo_index(argv, i));
    char *copied = (char *)emo_alloc((size_t)item.len + 1);
    memcpy(copied, item.bytes, (size_t)item.len);
    copied[item.len] = 0;
    argv_c[i] = copied;
  }
  argv_c[count] = NULL;
  execv(p, argv_c);
  char buf[512];
  snprintf(buf, sizeof buf, "os: execv %s: %s", p, strerror(errno));
  emo_raise(emo_make_exception(emo_str_from_cstr(buf)));
  return (emo_value)0; /* unreachable */
}

void emo_os__exit(int64_t status) { _exit((int)status); }

int64_t emo_os_open_read(emo_str path) {
  char *p = (char *)emo_str_cstr(path);
  int fd = open(p, O_RDONLY);
  if (fd < 0)
    return (int64_t)emo_os_fail("open", p);
  return fd;
}

int64_t emo_os_open_write(emo_str path) {
  char *p = (char *)emo_str_cstr(path);
  int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0)
    return (int64_t)emo_os_fail("open", p);
  return fd;
}

int64_t emo_os_open_append(emo_str path) {
  char *p = (char *)emo_str_cstr(path);
  int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0)
    return (int64_t)emo_os_fail("open", p);
  return fd;
}

emo_str emo_os_read(int64_t fd, int64_t n) {
  if (n <= 0)
    return (emo_str){0, ""};
  char *buf = (char *)emo_alloc((size_t)n);
  ssize_t got = read((int)fd, buf, (size_t)n);
  if (got < 0)
    emo_os_fail("read", "");
  emo_str out = {(int64_t)got, buf};
  return out;
}

int64_t emo_os_write(int64_t fd, emo_str data) {
  ssize_t put = write((int)fd, data.bytes, (size_t)data.len);
  if (put < 0)
    return (int64_t)emo_os_fail("write", "");
  return (int64_t)put;
}

int64_t emo_os_close(int64_t fd) {
  if (close((int)fd) != 0)
    return (int64_t)emo_os_fail("close", "");
  return 0;
}

static int emo_os_cmp_cstr(const void *a, const void *b) {
  return strcmp(*(const char **)a, *(const char **)b);
}

emo_value emo_os_list_dir(emo_str path) {
  char *p = (char *)emo_str_cstr(path);
  DIR *d = opendir(p);
  if (d == NULL)
    return emo_os_fail("opendir", p);
  size_t count = 0;
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
      continue;
    count++;
  }
  size_t slot = count > 0 ? count : 1;
  char **names = (char **)emo_alloc(sizeof(char *) * slot);
  rewinddir(d);
  size_t i = 0;
  while ((ent = readdir(d)) != NULL) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
      continue;
    names[i] = (char *)emo_alloc(strlen(ent->d_name) + 1);
    strcpy(names[i], ent->d_name);
    i++;
  }
  closedir(d);
  qsort(names, count, sizeof(char *), emo_os_cmp_cstr);
  emo_value *elems = (emo_value *)emo_alloc(sizeof(emo_value) * slot);
  for (size_t k = 0; k < count; k++)
    elems[k] = emo_box_str(emo_str_from_cstr(names[k]));
  return emo_array_new((int64_t)count, elems);
}

int64_t emo_os_mkdir(emo_str path) {
  char *p = (char *)emo_str_cstr(path);
  if (mkdir(p, 0755) != 0)
    return (int64_t)emo_os_fail("mkdir", p);
  return 0;
}

int64_t emo_os_rmdir(emo_str path) {
  char *p = (char *)emo_str_cstr(path);
  if (rmdir(p) != 0)
    return (int64_t)emo_os_fail("rmdir", p);
  return 0;
}

int64_t emo_os_unlink(emo_str path) {
  char *p = (char *)emo_str_cstr(path);
  if (unlink(p) != 0)
    return (int64_t)emo_os_fail("unlink", p);
  return 0;
}

int64_t emo_os_rename(emo_str old_path, emo_str new_path) {
  char *o = (char *)emo_str_cstr(old_path);
  char *n = (char *)emo_str_cstr(new_path);
  if (rename(o, n) != 0)
    return (int64_t)emo_os_fail("rename", o);
  return 0;
}

emo_str emo_os_getcwd(void) {
  char buf[4096];
  if (getcwd(buf, sizeof buf) == NULL)
    emo_os_fail("getcwd", "");
  return emo_str_from_cstr(buf);
}

int64_t emo_os_chdir(emo_str path) {
  char *p = (char *)emo_str_cstr(path);
  if (chdir(p) != 0)
    return (int64_t)emo_os_fail("chdir", p);
  return 0;
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
  return emo_box_i64(emo_str_to_int64(emo_str_of(recv)));
}

static emo_value emo_bm_split(emo_value recv, const emo_value *args) {
  return emo_str_split(emo_str_of(recv), emo_str_of(args[0]));
}

static emo_value emo_bm_read_line(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_str(emo_net_read_line(emo_unbox_i64(recv)));
}

static emo_value emo_bm_read_exactly(emo_value recv, const emo_value *args) {
  return emo_box_str(
      emo_net_read_exactly(emo_unbox_i64(recv), emo_unbox_i64(args[0])));
}

static emo_value emo_bm_read_all(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_str(emo_net_read_all(emo_unbox_i64(recv)));
}

static emo_value emo_bm_write(emo_value recv, const emo_value *args) {
  return emo_box_i64(emo_net_write(emo_unbox_i64(recv), emo_str_of(args[0])));
}

static emo_value emo_bm_close(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_i64(emo_net_close(emo_unbox_i64(recv)));
}

static emo_value emo_bm_set_timeout(emo_value recv, const emo_value *args) {
  return emo_box_i64(
      emo_net_set_timeout(emo_unbox_i64(recv), emo_unbox_f64(args[0])));
}

static emo_value emo_bm_accept(emo_value recv, const emo_value *args) {
  (void)args;
  return emo_box_i64(emo_net_accept(emo_unbox_i64(recv)));
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
  return emo_box_str(emo_to_string_method(recv));
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
    {"length", 0, emo_bm_length},
    {"to_string", 0, emo_bm_to_string},
};

emo_value emo_dynamic_builtin(emo_value recv, const char *name, int64_t arity,
                              const emo_value *args) {
  if (emo_is_instance(recv))
    return emo_send(recv, name, arity, args);
  for (size_t i = 0; i < sizeof emo_builtin_methods / sizeof *emo_builtin_methods;
       i++) {
    const emo_builtin_method *m = &emo_builtin_methods[i];
    if ((int64_t)m->arity == arity && strcmp(m->name, name) == 0)
      return m->fn(recv, args);
  }
  fprintf(stderr, "runtime error: message not understood: %s/%lld\n", name,
          (long long)arity);
  exit(70);
}
