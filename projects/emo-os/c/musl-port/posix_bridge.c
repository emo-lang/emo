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
  (void)fd;
  (void)cmd;
  errno = ENOSYS;
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
