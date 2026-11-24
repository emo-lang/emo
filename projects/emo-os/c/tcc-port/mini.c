// The self-hosted link's two missing musl-crt hooks (T4.5): the T1 C
// door library has the fd layer and the gate, not the musl body's TLS
// entry or stdio flush. The crt calls both; these are the empty answers
// the minimal link needs.

void __emo_tls_init(void) {}

char **__environ;

int fflush(void *f) {
  (void)f;
  return 0;
}
