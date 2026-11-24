// The gate's POSIX bridge for the musl body (EmoOS plan B, T3.1): the
// T1 C door's fd/path/process/pipe/signal functions ride under musl's
// headers and printf, with the pieces the shell needs that the T1
// library did not carry (opendir's musl `DIR`, execvp, termios,
// calloc/exit/abort, clock_gettime, fcntl, and the compiler runtime's
// unused network/ucontext surface stubbed).

#include <errno.h>
#undef errno
extern int errno;

#include "emo_t1.h"
#include "../emo_syscall.h"

#include <dirent.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <math.h>
#include <termios.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

extern char **environ;

int *__errno_location(void) {
  return &errno;
}

int *___errno_location(void) {
  return &errno;
}

#define errno (*__errno_location())

DIR *opendir(const char *path) {
  return (DIR *)emo_t1_opendir(path);
}

struct dirent *readdir(DIR *d) {
  struct emo_dirent *e = emo_t1_readdir((EMO_DIR *)d);
  static struct dirent out;
  if (e == 0) {
    return 0;
  }
  memset(&out, 0, sizeof out);
  strncpy(out.d_name, e->name, sizeof out.d_name - 1);
  return &out;
}

void rewinddir(DIR *d) {
  ((EMO_DIR *)d)->index = 0;
}

int closedir(DIR *d) {
  return emo_t1_closedir((EMO_DIR *)d);
}

int execvp(const char *file, char *const argv[]) {
  if (file == 0 || *file == 0) {
    errno = ENOENT;
    return -1;
  }
  // The volume is one flat namespace; the root is its only directory,
  // so a `./` path names the root's entry itself, never a PATH search.
  if (file[0] == '.' && file[1] == '/') {
    const char *bare = file;
    while (bare[0] == '.' && bare[1] == '/') {
      bare += 2;
    }
    execve(bare, argv, environ);
    return -1;
  }
  if (strchr(file, '/') != 0) {
    execve(file, argv, environ);
    return -1;
  }
  const char *path = getenv("PATH");
  if (path == 0 || *path == 0) {
    path = "/bin:/usr/bin";
  }
  const size_t flen = strlen(file);
  int last = ENOENT;
  const char *p = path;
  for (;;) {
    const char *colon = strchr(p, ':');
    size_t dlen = colon != 0 ? (size_t)(colon - p) : strlen(p);
    char buf[256];
    if (dlen + 1 + flen + 1 > sizeof buf) {
      last = ENAMETOOLONG;
    } else {
      memcpy(buf, p, dlen);
      buf[dlen] = '/';
      memcpy(buf + dlen + 1, file, flen);
      buf[dlen + 1 + flen] = 0;
      execve(buf, argv, environ);
      if (errno != ENOENT) {
        last = errno;
      }
    }
    if (colon == 0) {
      break;
    }
    p = colon + 1;
  }
  errno = last;
  return -1;
}

void *calloc(size_t n, size_t size) {
  if (n != 0 && size > (size_t)-1 / n) {
    errno = ENOMEM;
    return 0;
  }
  size_t total = n * size;
  void *p = malloc(total);
  if (p != 0) {
    memset(p, 0, total);
  }
  return p;
}

void abort(void) {
  raise(SIGABRT);
  _exit(134);
}

void exit(int code) {
  fflush(0);
  _exit(code);
}

int clock_gettime(clockid_t id, struct timespec *ts) {
  (void)id;
  long seconds = emo_syscall(29, 0, 0, 0, 0, 0, 0);
  if (seconds < 0) {
    errno = EIO;
    return -1;
  }
  ts->tv_sec = seconds;
  ts->tv_nsec = 0;
  return 0;
}

double sqrt(double x) {
  return __builtin_sqrt(x);
}

int fcntl(int fd, int cmd, ...) {
  va_list ap;
  int arg = 0;
  va_start(ap, cmd);
  arg = va_arg(ap, int);
  va_end(ap);
#ifdef F_DUPFD_CLOEXEC
  if (cmd == F_DUPFD || cmd == F_DUPFD_CLOEXEC) {
#else
  if (cmd == F_DUPFD) {
#endif
    if (fd < 0 || fd >= 16) {
      errno = EBADF;
      return -1;
    }
    int k = emo_t1_fd_free_above(arg < 0 ? 0 : arg);
    if (k < 0) {
      errno = EMFILE;
      return -1;
    }
    if (dup2(fd, k) < 0) {
      return -1;
    }
    return k;
  }
  if (cmd == F_GETFD || cmd == F_SETFD || cmd == F_GETFL || cmd == F_SETFL ||
      cmd == F_GETOWN || cmd == F_SETOWN) {
    return 0;
  }
  errno = EINVAL;
  return -1;
}

int isatty(int fd) {
  return fd >= 0 && fd <= 2;
}

int tcgetattr(int fd, struct termios *t) {
  if (!isatty(fd)) {
    errno = ENOTTY;
    return -1;
  }
  memset(t, 0, sizeof *t);
  return 0;
}

int tcsetattr(int fd, int action, const struct termios *t) {
  (void)action;
  (void)t;
  if (!isatty(fd)) {
    errno = ENOTTY;
    return -1;
  }
  return 0;
}

void cfmakeraw(struct termios *t) {
  t->c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR |
                  ICRNL | IXON);
  t->c_oflag &= ~OPOST;
  t->c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
  t->c_cflag &= ~(CSIZE | PARENB);
  t->c_cflag |= CS8;
}

int accept(int s, struct sockaddr *addr, socklen_t *len) {
  (void)s;
  (void)addr;
  (void)len;
  errno = ENOSYS;
  return -1;
}

int getsockname(int s, struct sockaddr *addr, socklen_t *len) {
  (void)s;
  (void)addr;
  (void)len;
  errno = ENOSYS;
  return -1;
}

int getnameinfo(const struct sockaddr *sa, socklen_t salen, char *host,
                socklen_t hostlen, char *serv, socklen_t servlen,
                int flags) {
  (void)sa;
  (void)salen;
  (void)host;
  (void)hostlen;
  (void)serv;
  (void)servlen;
  (void)flags;
  return EAI_FAIL;
}

uint16_t ntohs(uint16_t x) {
  return (uint16_t)((x << 8) | (x >> 8));
}

int poll(struct pollfd *fds, nfds_t n, int timeout) {
  (void)fds;
  (void)n;
  (void)timeout;
  errno = ENOSYS;
  return -1;
}

ssize_t recv(int fd, void *buf, size_t n, int flags) {
  (void)fd;
  (void)buf;
  (void)n;
  (void)flags;
  errno = ENOSYS;
  return -1;
}

ssize_t send(int fd, const void *buf, size_t n, int flags) {
  (void)fd;
  (void)buf;
  (void)n;
  (void)flags;
  errno = ENOSYS;
  return -1;
}

int getcontext(ucontext_t *u) {
  (void)u;
  errno = ENOSYS;
  return -1;
}

int setcontext(const ucontext_t *u) {
  (void)u;
  errno = ENOSYS;
  return -1;
}

int swapcontext(ucontext_t *old, const ucontext_t *u) {
  (void)old;
  (void)u;
  errno = ENOSYS;
  return -1;
}

void makecontext(ucontext_t *u, void (*fn)(void), int argc, ...) {
  (void)u;
  (void)fn;
  (void)argc;
}

// ---- The ported programs' POSIX surface (T4.1) ---------------------
//
// dash asks for the calls the T3.1 shell did not: the stat shape, the
// sigaction pair, the tty's foreground group, the process's parent and
// group, the umask, the login database, the resource limits and
// sysconf. The T1 door's three-word stat translates into musl's
// `struct stat`; the rest answer the conservative value a flat volume
// and a serial console can honestly give.

#include <pwd.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/times.h>
#include <sys/wait.h>

static void t1_stat_out(const struct emo_t1_stat *in, struct stat *out) {
  memset(out, 0, sizeof *out);
  out->st_mode = (in->is_dir ? S_IFDIR | 0755 : S_IFREG | 0644);
  out->st_size = in->size;
  out->st_nlink = 1;
}

int stat(const char *path, struct stat *out) {
  struct emo_t1_stat in;
  if (emo_t1_stat(path, &in) != 0) {
    return -1;
  }
  t1_stat_out(&in, out);
  return 0;
}

int lstat(const char *path, struct stat *out) {
  return stat(path, out);
}

int fstat(int fd, struct stat *out) {
  struct emo_t1_stat in;
  if (emo_t1_fstat(fd, &in) != 0) {
    return -1;
  }
  t1_stat_out(&in, out);
  return 0;
}

int sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
  if (sig <= 0 || sig >= 32) {
    errno = EINVAL;
    return -1;
  }
  long prev = 0;
  if (act != 0) {
    long disp = 0;
    if (act->sa_handler == SIG_IGN) {
      disp = 1;
    } else if (act->sa_handler != SIG_DFL) {
      disp = (long)act->sa_handler;
    }
    prev = emo_sig_action(sig, disp);
    if (prev < 0) {
      errno = EINVAL;
      return -1;
    }
  }
  if (old != 0) {
    memset(old, 0, sizeof *old);
    if (prev == 0) {
      old->sa_handler = SIG_DFL;
    } else if (prev == 1) {
      old->sa_handler = SIG_IGN;
    } else {
      old->sa_handler = (void (*)(int))prev;
    }
  }
  return 0;
}

pid_t tcgetpgrp(int fd) {
  (void)fd;
  return 0;
}

int tcsetpgrp(int fd, pid_t pgrp) {
  (void)fd;
  (void)pgrp;
  return 0;
}

pid_t getppid(void) {
  return 1;
}

pid_t getpgrp(void) {
  return (pid_t)getpgid(0);
}

int killpg(pid_t pgrp, int sig) {
  return kill(-pgrp, sig);
}

mode_t umask(mode_t mask) {
  (void)mask;
  return 0;
}

struct passwd *getpwnam(const char *name) {
  (void)name;
  return 0;
}

int getrlimit(int resource, struct rlimit *r) {
  (void)resource;
  if (r != 0) {
    r->rlim_cur = RLIM_INFINITY;
    r->rlim_max = RLIM_INFINITY;
  }
  return 0;
}

int setrlimit(int resource, const struct rlimit *r) {
  (void)resource;
  (void)r;
  return 0;
}

long sysconf(int name) {
  if (name == _SC_CLK_TCK) {
    return 100;
  }
  if (name == _SC_OPEN_MAX) {
    return 16;
  }
  if (name == _SC_ARG_MAX) {
    return 4096;
  }
  if (name == _SC_PAGESIZE) {
    return 4096;
  }
  if (name == _SC_NPROCESSORS_CONF) {
    return 1;
  }
  return -1;
}

// dash's arithmetic reads its numbers through strtod (T4.1); the
// decimal form is the shell's own surface, so the port parses it
// directly instead of pulling the floatscan body (the T2.2 quad cut).
uid_t getuid(void) { return 0; }

gid_t getgid(void) { return 0; }

uid_t geteuid(void) { return 0; }

gid_t getegid(void) { return 0; }

int getgroups(int count, gid_t *list) {
  (void)count;
  (void)list;
  return 0;
}

clock_t times(struct tms *t) {
  (void)t;
  return (clock_t)-1;
}

pid_t vfork(void) {
  return fork();
}

pid_t wait3(int *status, int options, struct rusage *rusage) {
  (void)rusage;
  return waitpid(-1, status, options);
}

int sigsuspend(const sigset_t *mask) {
  (void)mask;
  errno = EINTR;
  return -1;
}

double strtod(const char *s, char **end) {
  const char *p = s;
  while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
    p = p + 1;
  }
  int sign = 1;
  if (*p == '+' || *p == '-') {
    if (*p == '-') {
      sign = -1;
    }
    p = p + 1;
  }
  double v = 0.0;
  int any = 0;
  while (*p >= '0' && *p <= '9') {
    v = v * 10.0 + (double)(*p - '0');
    p = p + 1;
    any = 1;
  }
  if (*p == '.') {
    p = p + 1;
    double scale = 0.1;
    while (*p >= '0' && *p <= '9') {
      v = v + (double)(*p - '0') * scale;
      scale = scale * 0.1;
      p = p + 1;
      any = 1;
    }
  }
  if (!any) {
    if (end != 0) {
      *end = (char *)s;
    }
    return 0.0;
  }
  if (*p == 'e' || *p == 'E') {
    const char *e = p + 1;
    int esign = 1;
    if (*e == '+' || *e == '-') {
      if (*e == '-') {
        esign = -1;
      }
      e = e + 1;
    }
    int ev = 0;
    int eany = 0;
    while (*e >= '0' && *e <= '9') {
      ev = ev * 10 + (*e - '0');
      e = e + 1;
      eany = 1;
    }
    if (eany) {
      int k = 0;
      while (k < ev) {
        v = esign > 0 ? v * 10.0 : v / 10.0;
        k = k + 1;
      }
      p = e;
    }
  }
  if (end != 0) {
    *end = (char *)p;
  }
  return sign * v;
}
