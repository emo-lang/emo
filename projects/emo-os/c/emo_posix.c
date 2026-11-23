// The fd surface (EmoOS plan B, T1.1/T1.1k): the kernel's open-file
// table does the work now — the filesystem service owns each handle's
// offset and size, so reads and writes are partial, appends land at
// the end, and the gate's 2048-byte staging bounds a single call, not
// the file. This library keeps only the fd numbers: which of 3..15
// are open, and the writable bounce the console's verb wants.

#include "emo_syscall.h"
#include "emo_posix.h"

#define EMO_NAME_MAX 24

int errno;

static char name_buf[EMO_NAME_MAX];
static char bounce[2048];
static char read_bounce[2048];
static char used[EMO_MAX_FD];

static int reason_errno(long answer) {
  if (answer == -6) {
    return EMO_ENOENT;
  }
  if (answer == -3) {
    return EMO_EACCES;
  }
  if (answer == -2) {
    return EMO_EFAULT;
  }
  if (answer == -5) {
    return EMO_ENOSPC;
  }
  if (answer == -4) {
    return EMO_EINVAL;
  }
  return EMO_EIO;
}

// A descriptor's answer: -4 from the service is a handle that is gone
// or not this process's, the POSIX EBADF.
static int fd_errno(long answer) {
  if (answer == -4) {
    return EMO_EBADF;
  }
  return reason_errno(answer);
}

static int name_of(const char *path, int *len) {
  int n = 0;
  while (n < EMO_NAME_MAX && path[n] != 0) {
    n = n + 1;
  }
  if (n == 0 || n >= EMO_NAME_MAX) {
    return 0;
  }
  *len = n;
  return 1;
}

int open(const char *path, int flags) {
  int nlen = 0;
  if (!name_of(path, &nlen)) {
    errno = EMO_EINVAL;
    return -1;
  }
  int fd = 3;
  while (fd < EMO_MAX_FD && used[fd]) {
    fd = fd + 1;
  }
  if (fd == EMO_MAX_FD) {
    errno = EMO_EMFILE;
    return -1;
  }
  int i = 0;
  while (i < nlen) {
    name_buf[i] = path[i];
    i = i + 1;
  }
  long answer = emo_fd_open(fd, name_buf, (unsigned long)nlen, flags);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  used[fd] = 1;
  return fd;
}

int close(int fd) {
  if (fd == 0 || fd == 1 || fd == 2) {
    return 0;
  }
  if (fd < 3 || fd >= EMO_MAX_FD || !used[fd]) {
    errno = EMO_EBADF;
    return -1;
  }
  long answer = emo_fd_close(fd);
  if (answer < 0) {
    errno = fd_errno(answer);
    used[fd] = 0;
    return -1;
  }
  used[fd] = 0;
  return 0;
}

long read(int fd, void *buf, unsigned long n) {
  if (fd == 0) {
    long b = emo_ecall(2, 0, 0, 0, 0, 0, 0);
    if (b < 0) {
      errno = EMO_EIO;
      return -1;
    }
    if (n == 0) {
      return 0;
    }
    ((char *)buf)[0] = (char)b;
    return 1;
  }
  if (fd < 3 || fd >= EMO_MAX_FD || !used[fd]) {
    errno = EMO_EBADF;
    return -1;
  }
  if (n == 0) {
    return 0;
  }
  // The gate's buffer checks cover the image's segments, not the
  // process stack; the service reads into this .bss bounce and the
  // caller's bytes are copied after, the console path's own reason.
  unsigned long cap = n;
  if (cap > sizeof(read_bounce)) {
    cap = sizeof(read_bounce);
  }
  long answer = emo_fd_read(fd, read_bounce, cap);
  if (answer < 0) {
    errno = fd_errno(answer);
    return -1;
  }
  unsigned long i = 0;
  while (i < (unsigned long)answer) {
    ((char *)buf)[i] = read_bounce[i];
    i = i + 1;
  }
  return answer;
}

long write(int fd, const void *buf, unsigned long n) {
  if (n == 0) {
    return 0;
  }
  if (fd == 1 || fd == 2) {
    unsigned long done = 0;
    while (done < n) {
      unsigned long chunk = n - done;
      if (chunk > sizeof(bounce)) {
        chunk = sizeof(bounce);
      }
      unsigned long i = 0;
      while (i < chunk) {
        bounce[i] = ((const char *)buf)[done + i];
        i = i + 1;
      }
      long answer = emo_write(bounce, chunk);
      if (answer < 0) {
        errno = reason_errno(answer);
        return done == 0 ? -1 : (long)done;
      }
      done = done + chunk;
    }
    return (long)n;
  }
  if (fd < 3 || fd >= EMO_MAX_FD || !used[fd]) {
    errno = EMO_EBADF;
    return -1;
  }
  unsigned long done = 0;
  while (done < n) {
    unsigned long chunk = n - done;
    if (chunk > sizeof(bounce)) {
      chunk = sizeof(bounce);
    }
    unsigned long i = 0;
    while (i < chunk) {
      bounce[i] = ((const char *)buf)[done + i];
      i = i + 1;
    }
    long answer = emo_fd_write(fd, bounce, chunk);
    if (answer < 0) {
      errno = fd_errno(answer);
      return done == 0 ? -1 : (long)done;
    }
    done = done + chunk;
  }
  return (long)n;
}

long lseek(int fd, long off, int whence) {
  if (fd < 3 || fd >= EMO_MAX_FD || !used[fd]) {
    errno = EMO_EBADF;
    return -1;
  }
  long answer = emo_fd_seek(fd, off, whence);
  if (answer < 0) {
    errno = fd_errno(answer);
    return -1;
  }
  return answer;
}

int fstat(int fd, struct emo_stat *st) {
  if (fd < 3 || fd >= EMO_MAX_FD || !used[fd]) {
    errno = EMO_EBADF;
    return -1;
  }
  long answer = emo_fd_stat(fd);
  if (answer < 0) {
    errno = fd_errno(answer);
    return -1;
  }
  st->size = answer >> 32;
  st->flags = (int)(answer & 4294967295);
  return 0;
}

int unlink(const char *path) {
  int nlen = 0;
  if (!name_of(path, &nlen)) {
    errno = EMO_EINVAL;
    return -1;
  }
  int i = 0;
  while (i < nlen) {
    name_buf[i] = path[i];
    i = i + 1;
  }
  long answer = emo_file_remove(name_buf, (unsigned long)nlen);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  return 0;
}
