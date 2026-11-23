// The gate's C side (EmoOS plan B, M0): the ecall crossing exactly as
// the Emo syscall stub spells it — the verb in a7, up to six words in
// a0..a5, the answer back in a0. The C library will grow one wrapper
// per documented verb; this header carries the first two, the ones
// the skeleton's hello needs.

#ifndef EMO_SYSCALL_H
#define EMO_SYSCALL_H

static inline long emo_ecall(long n, long a, long b, long c, long d,
                             long e, long f) {
  register long a0 __asm__("a0") = a;
  register long a1 __asm__("a1") = b;
  register long a2 __asm__("a2") = c;
  register long a3 __asm__("a3") = d;
  register long a4 __asm__("a4") = e;
  register long a5 __asm__("a5") = f;
  register long a7 __asm__("a7") = n;
  __asm__ volatile("ecall"
                   : "+r"(a0)
                   : "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a5), "r"(a7)
                   : "memory");
  return a0;
}

// Verb 1: the len bytes at buf ride the console. The gate requires
// the source segment writable, so a C caller hands it a writable
// buffer — the skeleton's message lives in .data for exactly this
// reason (docs/EmoOS.TASKS.md, the contract).
static inline long emo_write(const void *buf, unsigned long len) {
  return emo_ecall(1, (long)buf, (long)len, 0, 0, 0, 0);
}

// Verb 0: the calling process ends; the root's exit ends the machine.
static inline void emo_exit(long code) __attribute__((noreturn));
static inline void emo_exit(long code) {
  emo_ecall(0, code, 0, 0, 0, 0, 0);
  __builtin_unreachable();
}

// Verb 6: the name becomes the len bytes at buf. The gate's checks
// are the whole-file interface's: the name and the bytes are
// writable segments' (the library stages both), and len is at most
// the gate's 2048-byte staging bound.
static inline long emo_file_write(const void *name, unsigned long nlen,
                                  const void *buf, unsigned long len) {
  return emo_ecall(6, (long)name, (long)nlen, (long)buf, (long)len, 0, 0);
}

// Verb 7: the file's bytes land at buf, at most cap; the answer is
// the file's size (a short cap still reports the whole size).
static inline long emo_file_read(const void *name, unsigned long nlen,
                                 void *buf, unsigned long cap) {
  return emo_ecall(7, (long)name, (long)nlen, (long)buf, (long)cap, 0, 0);
}

// Verb 8: the names, each followed by a newline, land at buf; the
// answer is the bytes written.
static inline long emo_file_list(void *buf, unsigned long cap) {
  return emo_ecall(8, (long)buf, (long)cap, 0, 0, 0, 0);
}

// Verb 9: the file is gone.
static inline long emo_file_remove(const void *name, unsigned long nlen) {
  return emo_ecall(9, (long)name, (long)nlen, 0, 0, 0, 0);
}

// Verbs 36..41: the open-file table (T1.1k). The fd numbers are the
// caller's; the filesystem service owns each handle's offset and
// size. The write's source and the open's name must be writable
// segments' (the gate stages both), and one write carries at most the
// gate's 2048 bytes.
static inline long emo_fd_open(long fd, const void *name, unsigned long nlen,
                               long flags) {
  return emo_ecall(36, fd, (long)name, (long)nlen, flags, 0, 0);
}

static inline long emo_fd_close(long fd) {
  return emo_ecall(37, fd, 0, 0, 0, 0, 0);
}

static inline long emo_fd_read(long fd, void *buf, unsigned long n) {
  return emo_ecall(38, fd, (long)buf, (long)n, 0, 0, 0);
}

static inline long emo_fd_write(long fd, const void *buf, unsigned long n) {
  return emo_ecall(39, fd, (long)buf, (long)n, 0, 0, 0);
}

static inline long emo_fd_seek(long fd, long off, long whence) {
  return emo_ecall(40, fd, off, whence, 0, 0, 0);
}

static inline long emo_fd_stat(long fd) {
  return emo_ecall(41, fd, 0, 0, 0, 0, 0);
}

// Verbs 42..44: the service's real directories (T1.2k) — the path's
// kind (1 directory, 0 file, -6 missing), the explicit mkdir and the
// empty rmdir. The name is the caller's, staged like the fd verbs'.
static inline long emo_path_type(const void *name, unsigned long nlen) {
  return emo_ecall(42, (long)name, (long)nlen, 0, 0, 0, 0);
}

static inline long emo_mkdir(const void *name, unsigned long nlen) {
  return emo_ecall(43, (long)name, (long)nlen, 0, 0, 0, 0);
}

static inline long emo_rmdir(const void *name, unsigned long nlen) {
  return emo_ecall(44, (long)name, (long)nlen, 0, 0, 0, 0);
}

// Verb 46: the caller's arena, base in the high 32 bits and end in
// the low; 0 for a process with none. The library's brk/mmap live
// inside it (T1.3).
static inline long emo_arena_info(void) {
  return emo_ecall(46, 0, 0, 0, 0, 0, 0);
}

// Verb 47: the arena grows by the given bytes; the answer is the new
// end's page number, a negative the refusal (T1.3v).
static inline long emo_arena_grow(long bytes) {
  return emo_ecall(47, bytes, 0, 0, 0, 0, 0);
}

// Verbs 49..51: the caller's pid, the process group's set and query
// (T1.4b1). Verb 4 is the wait: the child's exit code, blocking.
static inline long emo_getpid(void) {
  return emo_ecall(49, 0, 0, 0, 0, 0, 0);
}

static inline long emo_setpgid(long pid, long pgid) {
  return emo_ecall(50, pid, pgid, 0, 0, 0, 0);
}

static inline long emo_getpgid(long pid) {
  return emo_ecall(51, pid, 0, 0, 0, 0, 0);
}

static inline long emo_wait(long pid) {
  return emo_ecall(4, pid, 0, 0, 0, 0, 0);
}

// Verb 52: fork — the caller's saved context address and the child's
// resume entry. The child's address space is the caller's, copied; the
// answer is the child's pid, or a reason (EmoOS plan B, T1.4b2).
static inline long emo_fork(long ctx, long entry) {
  return emo_ecall(52, ctx, entry, 0, 0, 0, 0);
}

// Verb 54: execve — the name and the argv/envp texts; the caller's
// image is replaced in place and the call never returns on success
// (EmoOS plan B, T1.4b3b).
static inline long emo_execve(const void *name, unsigned long nlen,
                              const void *args, unsigned long alen,
                              const void *env, unsigned long elen) {
  return emo_ecall(54, (long)name, (long)nlen, (long)args, (long)alen,
                   (long)env, (long)elen);
}

// Verbs 55..60: the pipes (EmoOS plan B, T1.5). The ends are bound to
// the library's own fd numbers; the read blocks on an empty ring a
// writer may still fill and answers 0 at the last writer's close, the
// write answers what the ring's room took (or the broken pipe). The
// probe names a descriptor's end — the fresh image after an exec asks
// it about 0..2 before its first read or write.
static inline long emo_pipe_bind(long rfd, long wfd) {
  return emo_ecall(55, rfd, wfd, 0, 0, 0, 0);
}

static inline long emo_pipe_read(long fd, void *buf, unsigned long n) {
  return emo_ecall(56, fd, (long)buf, (long)n, 0, 0, 0);
}

static inline long emo_pipe_probe(long fd) {
  return emo_ecall(57, fd, 0, 0, 0, 0, 0);
}

static inline long emo_pipe_write(long fd, const void *buf, unsigned long n) {
  return emo_ecall(58, fd, (long)buf, (long)n, 0, 0, 0);
}

static inline long emo_pipe_dup(long oldfd, long newfd) {
  return emo_ecall(59, oldfd, newfd, 0, 0, 0, 0);
}

static inline long emo_pipe_close(long fd) {
  return emo_ecall(60, fd, 0, 0, 0, 0, 0);
}

// Verbs 61..65: the signals (EmoOS plan B, T1.6). The disposition's
// word is 0 the default, 1 ignored, an address a handler. The mask's
// bits are the signal numbers themselves (bit 2 is SIGINT) — the
// library translates the POSIX (signo - 1) set at its own boundary.
static inline long emo_kill(long pid, long sig) {
  return emo_ecall(61, pid, sig, 0, 0, 0, 0);
}

static inline long emo_sig_action(long sig, long disp) {
  return emo_ecall(62, sig, disp, 0, 0, 0, 0);
}

static inline long emo_sig_mask(long how, long set) {
  return emo_ecall(63, how, set, 0, 0, 0, 0);
}

static inline long emo_sig_return(void) {
  return emo_ecall(64, 0, 0, 0, 0, 0, 0);
}

static inline long emo_sig_pending(void) {
  return emo_ecall(65, 0, 0, 0, 0, 0, 0);
}

#endif
