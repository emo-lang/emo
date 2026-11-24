// The gate's POSIX side for the musl body (EmoOS plan B, T2.2): the
// console descriptors, the arena's `brk`/`mmap`, the single-threaded
// lock no-ops and the port's `__syscall` seam (mallocng's `brk`). The
// T2.1 wrappers are the only crossing; no Linux number reaches the
// kernel.

#include "../emo_syscall.h"

#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static char *heap_base;
static char *heap_cur;
static char *heap_end;
static int heap_ready;
static char bounce[2048];

static void mem_init(void) {
  if (heap_ready) {
    return;
  }
  heap_ready = 1;
  long info = emo_arena_info();
  if (info <= 0) {
    return;
  }
  heap_base = (char *)(long)((info >> 20) << 12);
  heap_end = (char *)(long)((info & 1048575) << 12);
  heap_cur = heap_base;
}

static int arena_extend(unsigned long need_end) {
  if (heap_base == 0) {
    return 0;
  }
  unsigned long end = (unsigned long)heap_end;
  if (need_end <= end) {
    return 1;
  }
  long answer = emo_arena_grow((long)(need_end - end));
  if (answer <= 0) {
    return 0;
  }
  heap_end = (char *)(long)(answer << 12);
  return (unsigned long)heap_end >= need_end;
}

static long gate_brk(long p) {
  mem_init();
  if (heap_base == 0) {
    return -ENOMEM;
  }
  if (p == 0) {
    return (long)heap_cur;
  }
  if (p < (long)heap_base) {
    return -ENOMEM;
  }
  if (p > (long)heap_end && !arena_extend((unsigned long)p)) {
    return -ENOMEM;
  }
  heap_cur = (char *)p;
  return p;
}

// The mallocng seam: musl's `glue.h` spells its break as
// `__syscall(SYS_brk, p)`; the overlay's `syscall.h` routes it here,
// and SYS_brk is the port's own number, not Linux's.
long __emo_port_syscall2(long n, long a) {
  if (n == 1) {
    return gate_brk(a);
  }
  return -ENOSYS;
}

long __emo_port_syscall0(long n) {
  return __emo_port_syscall2(n, 0);
}

long __emo_port_syscall1(long n, long a) {
  (void)a;
  return __emo_port_syscall2(n, 0);
}

long __emo_port_syscall3(long n, long a, long b) {
  (void)b;
  return __emo_port_syscall2(n, a);
}

long __emo_port_syscall4(long n, long a, long b, long c) {
  (void)b;
  (void)c;
  return __emo_port_syscall2(n, a);
}

long __emo_port_syscall5(long n, long a, long b, long c, long d) {
  (void)b;
  (void)c;
  (void)d;
  return __emo_port_syscall2(n, a);
}

long __emo_port_syscall6(long n, long a, long b, long c, long d, long e) {
  (void)b;
  (void)c;
  (void)d;
  (void)e;
  return __emo_port_syscall2(n, a);
}

void *__mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  (void)prot;
  (void)fd;
  (void)off;
  if (len == 0) {
    errno = EINVAL;
    return MAP_FAILED;
  }
  if ((flags & MAP_FIXED) && addr != 0) {
    return addr;
  }
  mem_init();
  if (heap_base == 0) {
    errno = ENOMEM;
    return MAP_FAILED;
  }
  unsigned long n = ((unsigned long)len + 4095) & ~4095UL;
  char *p = (char *)(((unsigned long)heap_cur + 4095) & ~4095UL);
  if ((unsigned long)(p + n) > (unsigned long)heap_end &&
      !arena_extend((unsigned long)(p + n))) {
    errno = ENOMEM;
    return MAP_FAILED;
  }
  heap_cur = p + n;
  memset(p, 0, n);
  return p;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  return __mmap(addr, len, prot, flags, fd, off);
}

int munmap(void *addr, size_t len) {
  (void)addr;
  (void)len;
  return 0;
}

int mprotect(void *addr, size_t len, int prot) {
  (void)addr;
  (void)len;
  (void)prot;
  return 0;
}

int __madvise(void *addr, size_t len, int advice) {
  (void)addr;
  (void)len;
  (void)advice;
  return 0;
}

void *__mremap(void *old, size_t old_len, size_t new_len, int flags, ...) {
  (void)flags;
  void *p = __mmap(0, new_len, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
  if (p == MAP_FAILED) {
    return MAP_FAILED;
  }
  size_t n = old_len < new_len ? old_len : new_len;
  memcpy(p, old, n);
  return p;
}

static int gate_errno(long answer) {
  if (answer == -2) {
    return EFAULT;
  }
  if (answer == -3) {
    return EACCES;
  }
  if (answer == -4) {
    return EINVAL;
  }
  if (answer == -5) {
    return ENOSPC;
  }
  if (answer == -6) {
    return ENOENT;
  }
  return EIO;
}

static long console_write(const char *buf, unsigned long n) {
  unsigned long done = 0;
  while (done < n) {
    unsigned long chunk = n - done;
    if (chunk > sizeof(bounce)) {
      chunk = sizeof(bounce);
    }
    long answer = emo_write(buf + done, chunk);
    if (answer == -2) {
      unsigned long i = 0;
      while (i < chunk) {
        bounce[i] = buf[done + i];
        i = i + 1;
      }
      answer = emo_write(bounce, chunk);
    }
    if (answer < 0) {
      return answer;
    }
    done = done + (unsigned long)answer;
  }
  return (long)n;
}

ssize_t write(int fd, const void *buf, size_t n) {
  if (fd != 1 && fd != 2) {
    if (fd > 2) {
      long answer = emo_fd_write(fd, buf, n);
      if (answer < 0) {
        errno = gate_errno(answer);
        return -1;
      }
      return answer;
    }
    errno = EBADF;
    return -1;
  }
  long answer = console_write(buf, n);
  if (answer < 0) {
    errno = gate_errno(answer);
    return -1;
  }
  return answer;
}

ssize_t read(int fd, void *buf, size_t n) {
  if (fd == 0) {
    long b = emo_console_read();
    if (b < 0) {
      errno = gate_errno(b);
      return -1;
    }
    if (n == 0) {
      return 0;
    }
    ((char *)buf)[0] = (char)b;
    return 1;
  }
  if (fd > 2) {
    long answer = emo_fd_read(fd, buf, n);
    if (answer < 0) {
      errno = gate_errno(answer);
      return -1;
    }
    return answer;
  }
  errno = EBADF;
  return -1;
}

int close(int fd) {
  if (fd >= 0 && fd <= 2) {
    return 0;
  }
  long answer = emo_fd_close(fd);
  if (answer < 0) {
    errno = gate_errno(answer);
    return -1;
  }
  return 0;
}

off_t lseek(int fd, off_t off, int whence) {
  if (fd >= 0 && fd <= 2) {
    errno = ESPIPE;
    return -1;
  }
  long answer = emo_fd_seek(fd, off, whence);
  if (answer < 0) {
    errno = gate_errno(answer);
    return -1;
  }
  return answer;
}

pid_t getpid(void) {
  return (pid_t)emo_getpid();
}

void _exit(int code) {
  emo_exit(code);
}

void __lock(volatile int *l) {
  (void)l;
}

void __unlock(volatile int *l) {
  (void)l;
}

// The printf float path's quad helpers (T2.2's cut): the user image
// lives past 2 GiB, where the host libgcc's medlow quad objects cannot
// be relocated, and T2.2's proof is the integer and string formats.
// These stubs keep the floatscan/vfprintf objects linkable; they are
// not arithmetic, and `%f`/`%Lf` wait for a medany soft-float or the
// real quad helpers (a later task).
long double __addtf3(long double a, long double b) { (void)b; return a; }
long double __subtf3(long double a, long double b) { (void)b; return a; }
long double __multf3(long double a, long double b) { (void)b; return a; }
long double __divtf3(long double a, long double b) { (void)b; return a; }
long double __extenddftf2(double a) { (void)a; return 0.0L; }
long double __extendsftf2(float a) { (void)a; return 0.0L; }
int __fixtfsi(long double a) { (void)a; return 0; }
unsigned int __fixunstfsi(long double a) { (void)a; return 0; }
long double __floatsitf(int a) { (void)a; return 0.0L; }
long double __floatunsitf(unsigned int a) { (void)a; return 0.0L; }
int __netf2(long double a, long double b) { (void)a; (void)b; return 0; }
int __eqtf2(long double a, long double b) { (void)a; (void)b; return 0; }
int __letf2(long double a, long double b) { (void)a; (void)b; return 0; }
int __lttf2(long double a, long double b) { (void)a; (void)b; return 0; }
int __getf2(long double a, long double b) { (void)a; (void)b; return 0; }
int __unordtf2(long double a, long double b) { (void)a; (void)b; return 0; }
double __trunctfdf2(long double a) { (void)a; return 0.0; }
