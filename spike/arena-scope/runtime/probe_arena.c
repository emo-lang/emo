/* ---- The spike's probes (spike/arena-scope) ----
   build.sh concatenates this file onto the compiler's own
   emo_c_runtime.c, so everything above this line is the shipped
   runtime verbatim and only additions follow. The arena's internals
   (emo_heap, emo_chunk, emo_fatal) are file-scope statics, so the
   probes have to live in the same translation unit to see them —
   which is also why this is an append and not a patch. */

int64_t emo_arena_bytes(void) {
  int64_t total = 0;
  for (emo_chunk *c = emo_heap; c != NULL; c = c->next)
    total += (int64_t)c->used;
  return total;
}

int64_t emo_arena_chunks(void) {
  int64_t n = 0;
  for (emo_chunk *c = emo_heap; c != NULL; c = c->next) n++;
  return n;
}

typedef struct {
  emo_chunk *chunk;
  size_t used;
} emo_arena_mark_t;

int64_t emo_arena_mark(void) {
  emo_arena_mark_t *m = malloc(sizeof(emo_arena_mark_t));
  if (m == NULL) abort();
  m->chunk = emo_heap;
  m->used = emo_heap == NULL ? 0 : emo_heap->used;
  return (int64_t)(intptr_t)m;
}

static void emo_arena_poison(void *p, size_t n) { memset(p, 0xAA, n); }

int64_t emo_arena_reset(int64_t mark) {
  emo_arena_mark_t *m = (emo_arena_mark_t *)(intptr_t)mark;
  int64_t reclaimed = 0;
  while (emo_heap != m->chunk) {
    if (emo_heap == NULL) emo_fatal("arena reset past its mark");
    emo_chunk *dead = emo_heap;
    emo_heap = dead->next;
    emo_arena_poison(dead + 1, dead->used);
    reclaimed += (int64_t)dead->used;
    free(dead);
  }
  if (emo_heap != NULL && emo_heap->used > m->used) {
    emo_arena_poison((char *)(emo_heap + 1) + m->used, emo_heap->used - m->used);
    reclaimed += (int64_t)(emo_heap->used - m->used);
    emo_heap->used = m->used;
  }
  free(m);
  return reclaimed;
}
