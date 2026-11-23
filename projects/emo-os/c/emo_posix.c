// The fd table (EmoOS plan B, T1.1): the first POSIX surface over the
// gate. The gate's file verbs are whole-file and named; a descriptor
// is the library's record of a name, a flag word, a byte buffer and
// an offset. Reads are served from the buffer loaded at open; writes
// land in it and commit at close. The cut is stated: files fit the
// 2048-byte buffer (the gate's staging bound), and a descriptor
// opened for writing replaces the file (O_TRUNC's meaning); partial
// writes and larger files wait for the service-owned table, T1.1k.

#include "emo_syscall.h"
#include "emo_posix.h"

#define EMO_FILE_SLOTS 8
#define EMO_FILE_MAX 2048
#define EMO_NAME_MAX 24

struct emo_file {
  int used;
  int flags;
  int slot;
  long offset;
  long size;
  int name_len;
  char name[EMO_NAME_MAX];
};

int errno;

static struct emo_file files[EMO_MAX_FD];
static char slots[EMO_FILE_SLOTS][EMO_FILE_MAX];
static char slot_used[EMO_FILE_SLOTS];
static char name_buf[EMO_NAME_MAX];
static char bounce[EMO_FILE_MAX];

static int slot_take(void) {
  int i = 0;
  while (i < EMO_FILE_SLOTS) {
    if (!slot_used[i]) {
      slot_used[i] = 1;
      return i;
    }
    i = i + 1;
  }
  return -1;
}

static void slot_give(int s) {
  slot_used[s] = 0;
}

static int mode_of(int flags) {
  return flags & 3;
}

static int emo_readable(int flags) {
  int m = mode_of(flags);
  return m == EMO_O_RDONLY || m == EMO_O_RDWR;
}

static int emo_writable(int flags) {
  int m = mode_of(flags);
  return m == EMO_O_WRONLY || m == EMO_O_RDWR;
}

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
  while (fd < EMO_MAX_FD && files[fd].used) {
    fd = fd + 1;
  }
  if (fd == EMO_MAX_FD) {
    errno = EMO_EMFILE;
    return -1;
  }
  int s = slot_take();
  if (s < 0) {
    errno = EMO_EMFILE;
    return -1;
  }
  int i = 0;
  while (i < nlen) {
    name_buf[i] = path[i];
    files[fd].name[i] = path[i];
    i = i + 1;
  }
  long size = 0;
  if (emo_readable(flags)) {
    long answer = emo_file_read(name_buf, (unsigned long)nlen, slots[s],
                                EMO_FILE_MAX);
    if (answer < 0) {
      slot_give(s);
      errno = reason_errno(answer);
      return -1;
    }
    if (answer > EMO_FILE_MAX) {
      slot_give(s);
      errno = EMO_ENOSPC;
      return -1;
    }
    size = answer;
  }
  files[fd].used = 1;
  files[fd].flags = flags;
  files[fd].slot = s;
  files[fd].offset = 0;
  files[fd].size = size;
  files[fd].name_len = nlen;
  return fd;
}

int close(int fd) {
  if (fd == 0 || fd == 1 || fd == 2) {
    return 0;
  }
  if (fd < 3 || fd >= EMO_MAX_FD || !files[fd].used) {
    errno = EMO_EBADF;
    return -1;
  }
  struct emo_file *f = &files[fd];
  int failed = 0;
  if (emo_writable(f->flags)) {
    long answer = emo_file_write(f->name, (unsigned long)f->name_len,
                                 slots[f->slot], (unsigned long)f->size);
    if (answer < 0) {
      errno = reason_errno(answer);
      failed = 1;
    }
  }
  slot_give(f->slot);
  f->used = 0;
  return failed ? -1 : 0;
}

long read(int fd, void *buf, unsigned long n) {
  if (fd == 0) {
    long b = emo_ecall(2, 0, 0, 0, 0, 0, 0);
    if (b < 0) {
      errno = EMO_EIO;
      return -1;
    }
    ((char *)buf)[0] = (char)b;
    return 1;
  }
  if (fd < 3 || fd >= EMO_MAX_FD || !files[fd].used) {
    errno = EMO_EBADF;
    return -1;
  }
  struct emo_file *f = &files[fd];
  if (!emo_readable(f->flags)) {
    errno = EMO_EBADF;
    return -1;
  }
  long avail = f->size - f->offset;
  if (avail <= 0) {
    return 0;
  }
  unsigned long k = n;
  if ((long)k > avail) {
    k = (unsigned long)avail;
  }
  unsigned long i = 0;
  while (i < k) {
    ((char *)buf)[i] = slots[f->slot][f->offset + (long)i];
    i = i + 1;
  }
  f->offset = f->offset + (long)k;
  return (long)k;
}

long write(int fd, const void *buf, unsigned long n) {
  if (fd == 1 || fd == 2) {
    unsigned long done = 0;
    while (done < n) {
      unsigned long chunk = n - done;
      if (chunk > EMO_FILE_MAX) {
        chunk = EMO_FILE_MAX;
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
  if (fd < 3 || fd >= EMO_MAX_FD || !files[fd].used) {
    errno = EMO_EBADF;
    return -1;
  }
  struct emo_file *f = &files[fd];
  if (!emo_writable(f->flags)) {
    errno = EMO_EBADF;
    return -1;
  }
  if (f->size + (long)n > EMO_FILE_MAX) {
    errno = EMO_ENOSPC;
    return -1;
  }
  unsigned long i = 0;
  while (i < n) {
    slots[f->slot][f->size + (long)i] = ((const char *)buf)[i];
    i = i + 1;
  }
  f->size = f->size + (long)n;
  f->offset = f->size;
  return (long)n;
}

long lseek(int fd, long off, int whence) {
  if (fd < 3 || fd >= EMO_MAX_FD || !files[fd].used) {
    errno = EMO_EBADF;
    return -1;
  }
  struct emo_file *f = &files[fd];
  long base = 0;
  if (whence == EMO_SEEK_CUR) {
    base = f->offset;
  }
  if (whence == EMO_SEEK_END) {
    base = f->size;
  }
  if (whence != EMO_SEEK_SET && whence != EMO_SEEK_CUR &&
      whence != EMO_SEEK_END) {
    errno = EMO_EINVAL;
    return -1;
  }
  long next = base + off;
  if (next < 0) {
    errno = EMO_EINVAL;
    return -1;
  }
  f->offset = next;
  return next;
}

int fstat(int fd, struct emo_stat *st) {
  if (fd < 3 || fd >= EMO_MAX_FD || !files[fd].used) {
    errno = EMO_EBADF;
    return -1;
  }
  st->size = files[fd].size;
  st->flags = files[fd].flags;
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
