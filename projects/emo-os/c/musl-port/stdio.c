// The stdio side (EmoOS plan B, T2.2): musl's buffered writers over the
// gate's console `write`, without the Linux `writev`/`ioctl` calls.
// The single-threaded body's `libc.need_locks` is zero, so the lock
// hooks are the no-op pair musl's `lock.h` would otherwise reach.

#include <unistd.h>

#include "stdio_impl.h"

#include <errno.h>

size_t __stdio_write(FILE *f, const unsigned char *buf, size_t len) {
  size_t total = len;
  if (f->wpos != f->wbase) {
    size_t n = (size_t)(f->wpos - f->wbase);
    if (write(f->fd, f->wbase, n) != (ssize_t)n) {
      f->flags |= F_ERR;
      f->wpos = f->wbase = f->wend = 0;
      return 0;
    }
  }
  if (len != 0 && write(f->fd, buf, len) != (ssize_t)len) {
    f->flags |= F_ERR;
    f->wpos = f->wbase = f->wend = 0;
    return 0;
  }
  f->wend = f->buf + f->buf_size;
  f->wpos = f->wbase = f->buf;
  return total;
}

size_t __stdio_read(FILE *f, unsigned char *buf, size_t len) {
  ssize_t n = read(f->fd, buf, len);
  if (n < 0) {
    f->flags |= F_ERR;
    return 0;
  }
  if (n == 0) {
    f->flags |= F_EOF;
    return 0;
  }
  return (size_t)n;
}

size_t __stdout_write(FILE *f, const unsigned char *buf, size_t len) {
  return __stdio_write(f, buf, len);
}

off_t __stdio_seek(FILE *f, off_t off, int whence) {
  return lseek(f->fd, off, whence);
}

int __stdio_close(FILE *f) {
  return close(f->fd);
}

int __lockfile(FILE *f) {
  (void)f;
  return 1;
}

void __unlockfile(FILE *f) {
  (void)f;
}
