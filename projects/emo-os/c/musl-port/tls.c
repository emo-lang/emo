// The static TLS block (EmoOS plan B, T2.2): one `struct pthread` in
// `.bss`, `tp` above it as musl's `TLS_ABOVE_TP` layout expects, and
// the `libc` words the single-threaded body reads. The gate has no
// threads, so `threaded` and `need_locks` are zero; `errno`,
// `__lockfile`'s tid and the locale pointer still have a real block.

#include "pthread_impl.h"
#include "libc.h"

static size_t emo_auxv[2] = { 0, 0 };
static struct pthread emo_pthread;

void __emo_tls_init(void) {
  libc.page_size = 4096;
  libc.threaded = 0;
  libc.need_locks = 0;
  libc.auxv = emo_auxv;

  emo_pthread.self = &emo_pthread;
  emo_pthread.tid = 1;
  emo_pthread.detach_state = DT_DETACHED;
  emo_pthread.locale = &libc.global_locale;
  emo_pthread.next = &emo_pthread;
  emo_pthread.prev = &emo_pthread;
  emo_pthread.robust_list.head = &emo_pthread.robust_list.head;
  emo_pthread.robust_list.off = 0;
  emo_pthread.robust_list.pending = 0;

  __asm__ __volatile__("mv tp, %0"
                       :
                       : "r"((char *)&emo_pthread + sizeof(struct pthread)));
}
