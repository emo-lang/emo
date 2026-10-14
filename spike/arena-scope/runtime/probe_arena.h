/* The spike's probes, appended to the compiler's own
   emo_c_runtime.h at build time (see build.sh). Everything above this
   block is the shipped runtime, verbatim; this block only ADDS
   declarations. No existing struct, signature, or macro is touched —
   which is what makes the probes' numbers the runtime's numbers. */

/* What the bump arena is holding: the sum of every chunk's used
   prefix. `cap` would count the malloc slack the allocator rounds up
   to, which is not what a program asked for. */
int64_t emo_arena_bytes(void);

/* How many chunks the arena holds. */
int64_t emo_arena_chunks(void);

/* Identity cells that still carry a refcount — the shipped
   emo_identity_live_count, restated here so a probe that needs only
   this can say so. */
int64_t emo_identity_live_count(void);

/* A region handle: an opaque offset mark, malloc'd OUTSIDE the arena so
   that taking one allocates nothing inside the region it opens. */
int64_t emo_arena_mark(void);

/* Release everything the arena took since the mark: free every chunk
   newer than the marked one, rewind the marked chunk to its recorded
   offset. Strictly LIFO — marks are reset in reverse order, and
   nothing allocated before a mark may be read after its reset.
   Returns the bytes reclaimed.

   The detector: reclaimed bytes are poisoned with 0xAA before they are
   handed back, so a read through a stale pointer fails the same way
   every run instead of reading whatever the allocator left behind.
   0xAA is not a valid cell kind, so the first dereference a stale value
   reaches reports a corrupted cell rather than a plausible-looking
   one. */
int64_t emo_arena_reset(int64_t mark);
