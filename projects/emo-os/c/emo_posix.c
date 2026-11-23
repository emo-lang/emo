// The POSIX surface (EmoOS plan B, T1.1/T1.1k/T1.2): the fd table the
// filesystem service owns, and the path layer over the volume's flat
// names — a root, relative and absolute paths, `.` and `..`, the
// process's cwd, and the directory calls. A directory is the marker
// name `dir/` and the names under its prefix; the service still sees
// one flat name table (T1.2k takes the real directory entries into
// the service).

#include "emo_syscall.h"
#include "emo_posix.h"

#define EMO_NAME_MAX 24

int errno;

static char name_buf[EMO_NAME_MAX];
static char bounce[2048];
static char read_bounce[2048];
static char used[EMO_MAX_FD];
// The descriptor's kind (T1.5): 0 unknown, 1 console in, 2 file, 3 pipe
// read end, 4 pipe write end, 5 closed, 6 console out. A pipe is the
// kernel's binding map's — the library asks once (pipe_probe) and
// caches the answer, so an exec'd image's fresh table finds the low
// ends its predecessor redirected.
#define EMO_KIND_UNKNOWN 0
#define EMO_KIND_CIN 1
#define EMO_KIND_FILE 2
#define EMO_KIND_PREAD 3
#define EMO_KIND_PWRITE 4
#define EMO_KIND_CLOSED 5
#define EMO_KIND_COUT 6
static char fd_kind[EMO_MAX_FD];
// The descriptor's own copy (T1.4b3a): the name, flags and offset the
// child inherits with the image. The service's handle is per pid, so a
// forked child's first access reopens the name under its own pid and
// seeks to the copied offset — the description's offset diverges from
// the parent's, the documented approximation.
static char fd_name[EMO_MAX_FD][EMO_NAME_MAX + 1];
static unsigned long fd_nlen[EMO_MAX_FD];
static int fd_flags[EMO_MAX_FD];
static long fd_off[EMO_MAX_FD];
static char cwd[EMO_PATH_MAX + 1] = "/";
static char list_buf[EMO_DIR_LIST];
static struct emo_dirent dirent;
static EMO_DIR dirs[2];
static char *heap_base;
static char *heap_cur;
static char *heap_end;
static int heap_ready;

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

// The pipe verbs' answers (T1.5): the broken pipe is its own number.
static int pipe_errno(long answer) {
  if (answer == -32) {
    return EMO_EPIPE;
  }
  return fd_errno(answer);
}

// The descriptor's kind, asked of the kernel once (T1.5): fds 0..2 are
// the console until the binding map says a pipe, every higher fd a
// file until the map says otherwise. The answer stays cached; the
// library's own verbs maintain it from here.
static int fd_kind_of(int fd) {
  if (fd_kind[fd] != EMO_KIND_UNKNOWN) {
    return (int)fd_kind[fd];
  }
  long a = emo_pipe_probe(fd);
  if (a == 1) {
    fd_kind[fd] = EMO_KIND_PREAD;
    return EMO_KIND_PREAD;
  }
  if (a == 2) {
    fd_kind[fd] = EMO_KIND_PWRITE;
    return EMO_KIND_PWRITE;
  }
  if (fd == 0) {
    fd_kind[fd] = EMO_KIND_CIN;
    return EMO_KIND_CIN;
  }
  if (fd <= 2) {
    fd_kind[fd] = EMO_KIND_COUT;
    return EMO_KIND_COUT;
  }
  fd_kind[fd] = EMO_KIND_FILE;
  return EMO_KIND_FILE;
}

static int fd_is_open(int fd) {
  if (fd < 0 || fd >= EMO_MAX_FD) {
    return 0;
  }
  int k = fd_kind_of(fd);
  if (k == EMO_KIND_CLOSED) {
    return 0;
  }
  if (k == EMO_KIND_PREAD || k == EMO_KIND_PWRITE) {
    return 1;
  }
  if (k == EMO_KIND_CIN || k == EMO_KIND_COUT) {
    // a console stream, the low three's own or a dup's copy
    return 1;
  }
  return used[fd] != 0;
}

// Whatever the descriptor holds, dropped: a pipe end's binding (its
// count down, the peers woken), a file's service handle, or nothing.
// `errno` stays the caller's — this is dup2's inner step.
static void fd_drop(int fd) {
  if (fd < 0 || fd >= EMO_MAX_FD) {
    return;
  }
  int k = fd_kind_of(fd);
  if (k == EMO_KIND_PREAD || k == EMO_KIND_PWRITE) {
    emo_pipe_close(fd);
  } else if (used[fd]) {
    emo_fd_close(fd);
  }
  used[fd] = 0;
  fd_kind[fd] = EMO_KIND_UNKNOWN;
}

// The lowest free descriptor the library can hand out: 3 and up, never
// one a pipe end holds (the table's own number is the authority).
static int free_fd(void) {
  int fd = 3;
  while (fd < EMO_MAX_FD) {
    int k = fd_kind[fd];
    if (!used[fd] && k != EMO_KIND_PREAD && k != EMO_KIND_PWRITE) {
      return fd;
    }
    fd = fd + 1;
  }
  return -1;
}

static unsigned long slen(const char *s) {
  unsigned long n = 0;
  while (s[n] != 0) {
    n = n + 1;
  }
  return n;
}

static int seq(const char *a, const char *b) {
  unsigned long i = 0;
  while (a[i] != 0 && b[i] != 0) {
    if (a[i] != b[i]) {
      return 0;
    }
    i = i + 1;
  }
  return a[i] == b[i];
}

static void scopy(char *dst, const char *src, unsigned long cap) {
  unsigned long i = 0;
  while (src[i] != 0 && i + 1 < cap) {
    dst[i] = src[i];
    i = i + 1;
  }
  dst[i] = 0;
}

static int line_eq(const char *line, unsigned long len, const char *name,
                   unsigned long nlen) {
  if (len != nlen) {
    return 0;
  }
  unsigned long i = 0;
  while (i < len) {
    if (line[i] != name[i]) {
      return 0;
    }
    i = i + 1;
  }
  return 1;
}

// The canonical volume name: no leading slash, no trailing slash, the
// root the empty string. A relative path starts at the cwd's tail.
static int resolve(const char *path, char *out, unsigned long cap) {
  unsigned long n = 0;
  if (path[0] != '/') {
    const char *base = cwd + 1;
    unsigned long i = 0;
    while (base[i] != 0) {
      if (n + 1 >= cap) {
        errno = EMO_ENAMETOOLONG;
        return -1;
      }
      out[n] = base[i];
      n = n + 1;
      i = i + 1;
    }
  }
  unsigned long i = 0;
  while (path[i] != 0) {
    while (path[i] == '/') {
      i = i + 1;
    }
    if (path[i] == 0) {
      break;
    }
    unsigned long start = i;
    while (path[i] != 0 && path[i] != '/') {
      i = i + 1;
    }
    unsigned long len = i - start;
    if (len == 1 && path[start] == '.') {
      continue;
    }
    if (len == 2 && path[start] == '.' && path[start + 1] == '.') {
      unsigned long k = n;
      while (k > 0 && out[k - 1] != '/') {
        k = k - 1;
      }
      if (k > 0) {
        n = k - 1;
      } else {
        n = 0;
      }
      continue;
    }
    if (n > 0) {
      if (n + 1 >= cap) {
        errno = EMO_ENAMETOOLONG;
        return -1;
      }
      out[n] = '/';
      n = n + 1;
    }
    if (n + len >= cap) {
      errno = EMO_ENAMETOOLONG;
      return -1;
    }
    unsigned long j = 0;
    while (j < len) {
      out[n] = path[start + j];
      n = n + 1;
      j = j + 1;
    }
  }
  out[n] = 0;
  return 0;
}

static int put_name(const char *name, unsigned long nlen) {
  if (nlen < 1 || nlen > EMO_NAME_MAX) {
    errno = EMO_ENAMETOOLONG;
    return -1;
  }
  unsigned long i = 0;
  while (i < nlen) {
    name_buf[i] = name[i];
    i = i + 1;
  }
  return 0;
}

// The service's path kind (T1.2k): 1 a directory, 0 a file, -1 an
// error (ENOENT included). The root is the library's own.
static int path_kind(const char *full) {
  unsigned long nlen = slen(full);
  if (nlen == 0) {
    return 1;
  }
  if (put_name(full, nlen) != 0) {
    return -1;
  }
  long answer = emo_path_type(name_buf, nlen);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  return (int)answer;
}

// The line at line[0..len): does it name `dir/...`? The marker
// `dir/` itself matches; a plain file `dir` does not.
static int under(const char *line, unsigned long len, const char *dir,
                 unsigned long plen) {
  if (plen == 0) {
    return 1;
  }
  if (len <= plen) {
    return 0;
  }
  unsigned long i = 0;
  while (i < plen) {
    if (line[i] != dir[i]) {
      return 0;
    }
    i = i + 1;
  }
  return line[plen] == '/';
}

static int dir_exists(const char *dir) {
  return path_kind(dir) == 1;
}

static int file_exists(const char *name) {
  return path_kind(name) == 0;
}

static int path_exists_guard(const char *full) {
  return path_kind(full) >= 0;
}

static int parent_exists(const char *full) {
  unsigned long n = slen(full);
  unsigned long k = n;
  while (k > 0 && full[k - 1] != '/') {
    k = k - 1;
  }
  if (k == 0) {
    return 1;
  }
  char parent[EMO_PATH_MAX + 1];
  unsigned long plen = k - 1;
  unsigned long i = 0;
  while (i < plen) {
    parent[i] = full[i];
    i = i + 1;
  }
  parent[plen] = 0;
  return dir_exists(parent);
}

static int open_name(const char *full, int flags) {
  unsigned long nlen = slen(full);
  if (put_name(full, nlen) != 0) {
    return -1;
  }
  int fd = free_fd();
  if (fd < 0) {
    errno = EMO_EMFILE;
    return -1;
  }
  long answer = emo_fd_open(fd, name_buf, nlen, flags);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  unsigned long k = 0;
  while (k < nlen) {
    fd_name[fd][k] = full[k];
    k = k + 1;
  }
  fd_name[fd][nlen] = 0;
  fd_nlen[fd] = nlen;
  fd_flags[fd] = flags;
  fd_off[fd] = 0;
  used[fd] = 1;
  fd_kind[fd] = EMO_KIND_FILE;
  return fd;
}

// The child's inherited descriptor (T1.4b3a): the service has no
// handle for this pid yet, so the first access opens the stored name
// under it and seeks to the copied offset. O_APPEND keeps the
// service's own end; O_CREAT and O_TRUNC are dropped — the file is
// already this descriptor's, not a fresh creation.
static int fd_adopt(int fd) {
  if (fd < 3 || fd >= EMO_MAX_FD || !used[fd] || fd_nlen[fd] == 0) {
    errno = EMO_EBADF;
    return -1;
  }
  long answer = emo_fd_open(fd, fd_name[fd], fd_nlen[fd],
                            fd_flags[fd] & ~(EMO_O_CREAT | EMO_O_TRUNC));
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  if ((fd_flags[fd] & EMO_O_APPEND) == 0) {
    answer = emo_fd_seek(fd, fd_off[fd], EMO_SEEK_SET);
    if (answer < 0) {
      errno = fd_errno(answer);
      return -1;
    }
  }
  return 0;
}

static int remove_name(const char *full) {
  unsigned long nlen = slen(full);
  if (put_name(full, nlen) != 0) {
    return -1;
  }
  long answer = emo_file_remove(name_buf, nlen);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  return 0;
}

int open(const char *path, int flags) {
  char full[EMO_PATH_MAX + 1];
  if (resolve(path, full, sizeof(full)) != 0) {
    return -1;
  }
  if (full[0] == 0) {
    errno = EMO_EISDIR;
    return -1;
  }
  if (dir_exists(full) > 0) {
    errno = EMO_EISDIR;
    return -1;
  }
  if (!parent_exists(full)) {
    errno = EMO_ENOENT;
    return -1;
  }
  return open_name(full, flags);
}

int close(int fd) {
  if (fd < 0 || fd >= EMO_MAX_FD) {
    errno = EMO_EBADF;
    return -1;
  }
  int k = fd_kind_of(fd);
  if (k == EMO_KIND_CLOSED) {
    errno = EMO_EBADF;
    return -1;
  }
  if (k == EMO_KIND_PREAD || k == EMO_KIND_PWRITE) {
    // a pipe end's close (T1.5): the kernel's binding goes, and the
    // last writer's close is the readers' EOF
    long answer = emo_pipe_close(fd);
    fd_kind[fd] = EMO_KIND_UNKNOWN;
    used[fd] = 0;
    if (answer < 0) {
      errno = pipe_errno(answer);
      return -1;
    }
    return 0;
  }
  if (used[fd]) {
    long answer = emo_fd_close(fd);
    used[fd] = 0;
    fd_kind[fd] = EMO_KIND_UNKNOWN;
    if (answer < 0 && answer != -4) {
      errno = fd_errno(answer);
      return -1;
    }
    // -4 is a descriptor this pid never opened — a fork's inherited fd
    // the child closes before touching it; the child's copy closes.
    return 0;
  }
  if (k == EMO_KIND_CIN || k == EMO_KIND_COUT) {
    // a console stream's close: nothing of the kernel's to give back,
    // but the library's number is spent — a later read or write is the
    // EBADF POSIX says. The low three stay CLOSED; a dup's copy is
    // just freed for the next open.
    if (fd <= 2) {
      fd_kind[fd] = EMO_KIND_CLOSED;
    } else {
      fd_kind[fd] = EMO_KIND_UNKNOWN;
    }
    return 0;
  }
  errno = EMO_EBADF;
  return -1;
}

// The pipe's read: the caller's bytes bounce through .bss (the gate's
// checks cover the image's segments, not the stack), and the answer is
// the bytes or 0 at the last writer's close.
static long pipe_read_call(int fd, void *buf, unsigned long n) {
  unsigned long cap = n;
  if (cap > sizeof(read_bounce)) {
    cap = sizeof(read_bounce);
  }
  long answer = emo_pipe_read(fd, read_bounce, cap);
  if (answer < 0) {
    errno = pipe_errno(answer);
    return -1;
  }
  unsigned long i = 0;
  while (i < (unsigned long)answer) {
    ((char *)buf)[i] = read_bounce[i];
    i = i + 1;
  }
  return answer;
}

// The pipe's write: chunks of the bounce, each answered by what the
// ring's room took — a short answer loops, and no reader at all is
// EPIPE.
static long pipe_write_call(int fd, const void *buf, unsigned long n) {
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
    long answer = emo_pipe_write(fd, bounce, chunk);
    if (answer < 0) {
      errno = pipe_errno(answer);
      return done == 0 ? -1 : (long)done;
    }
    if (answer == 0) {
      break;
    }
    done = done + answer;
  }
  return (long)done;
}

long read(int fd, void *buf, unsigned long n) {
  if (fd < 0 || fd >= EMO_MAX_FD) {
    errno = EMO_EBADF;
    return -1;
  }
  int k = fd_kind_of(fd);
  if (k == EMO_KIND_PREAD) {
    if (n == 0) {
      return 0;
    }
    return pipe_read_call(fd, buf, n);
  }
  if (k == EMO_KIND_PWRITE || k == EMO_KIND_COUT) {
    errno = EMO_EBADF;
    return -1;
  }
  if (k == EMO_KIND_CIN) {
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
  if (k == EMO_KIND_CLOSED || !used[fd]) {
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
  if (answer == -4) {
    if (fd_adopt(fd) != 0) {
      return -1;
    }
    answer = emo_fd_read(fd, read_bounce, cap);
  }
  if (answer < 0) {
    errno = fd_errno(answer);
    return -1;
  }
  fd_off[fd] = fd_off[fd] + answer;
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
  if (fd < 0 || fd >= EMO_MAX_FD) {
    errno = EMO_EBADF;
    return -1;
  }
  int k = fd_kind_of(fd);
  if (k == EMO_KIND_PWRITE) {
    return pipe_write_call(fd, buf, n);
  }
  if (k == EMO_KIND_PREAD || k == EMO_KIND_CIN) {
    errno = EMO_EBADF;
    return -1;
  }
  if (k == EMO_KIND_COUT) {
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
  if (k == EMO_KIND_CLOSED || !used[fd]) {
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
    if (answer == -4) {
      if (fd_adopt(fd) != 0) {
        return done == 0 ? -1 : (long)done;
      }
      answer = emo_fd_write(fd, bounce, chunk);
    }
    if (answer < 0) {
      errno = fd_errno(answer);
      return done == 0 ? -1 : (long)done;
    }
    fd_off[fd] = fd_off[fd] + answer;
    done = done + chunk;
  }
  return (long)n;
}

long lseek(int fd, long off, int whence) {
  if (fd < 0 || fd >= EMO_MAX_FD) {
    errno = EMO_EBADF;
    return -1;
  }
  int kind = fd_kind_of(fd);
  if (kind == EMO_KIND_PREAD || kind == EMO_KIND_PWRITE) {
    errno = EMO_ESPIPE;
    return -1;
  }
  if (kind == EMO_KIND_CLOSED || !used[fd]) {
    errno = EMO_EBADF;
    return -1;
  }
  long answer = emo_fd_seek(fd, off, whence);
  if (answer == -4) {
    if (fd_adopt(fd) != 0) {
      return -1;
    }
    answer = emo_fd_seek(fd, off, whence);
  }
  if (answer < 0) {
    errno = fd_errno(answer);
    return -1;
  }
  fd_off[fd] = answer;
  return answer;
}

int fstat(int fd, struct emo_stat *st) {
  if (fd < 0 || fd >= EMO_MAX_FD) {
    errno = EMO_EBADF;
    return -1;
  }
  int kind = fd_kind_of(fd);
  if (kind == EMO_KIND_PREAD || kind == EMO_KIND_PWRITE) {
    st->size = 0;
    st->flags = 0;
    st->is_dir = 0;
    return 0;
  }
  if (kind == EMO_KIND_CLOSED || !used[fd]) {
    errno = EMO_EBADF;
    return -1;
  }
  long answer = emo_fd_stat(fd);
  if (answer == -4) {
    if (fd_adopt(fd) != 0) {
      return -1;
    }
    answer = emo_fd_stat(fd);
  }
  if (answer < 0) {
    errno = fd_errno(answer);
    return -1;
  }
  st->size = answer >> 32;
  st->flags = (int)(answer & 4294967295);
  st->is_dir = 0;
  return 0;
}

int unlink(const char *path) {
  char full[EMO_PATH_MAX + 1];
  if (resolve(path, full, sizeof(full)) != 0) {
    return -1;
  }
  if (full[0] == 0) {
    errno = EMO_EISDIR;
    return -1;
  }
  if (dir_exists(full) != 0) {
    errno = EMO_EISDIR;
    return -1;
  }
  if (file_exists(full) != 1) {
    errno = EMO_ENOENT;
    return -1;
  }
  return remove_name(full);
}

char *getcwd(char *buf, unsigned long size) {
  unsigned long n = slen(cwd);
  if (size < n + 1) {
    errno = EMO_ERANGE;
    return 0;
  }
  scopy(buf, cwd, size);
  return buf;
}

int chdir(const char *path) {
  char full[EMO_PATH_MAX + 1];
  if (resolve(path, full, sizeof(full)) != 0) {
    return -1;
  }
  if (full[0] == 0) {
    cwd[0] = '/';
    cwd[1] = 0;
    return 0;
  }
  if (dir_exists(full) != 1) {
    errno = EMO_ENOENT;
    return -1;
  }
  cwd[0] = '/';
  unsigned long i = 0;
  while (full[i] != 0) {
    cwd[i + 1] = full[i];
    i = i + 1;
  }
  cwd[i + 1] = 0;
  return 0;
}

int mkdir(const char *path, int mode) {
  (void)mode;
  char full[EMO_PATH_MAX + 1];
  if (resolve(path, full, sizeof(full)) != 0) {
    return -1;
  }
  if (full[0] == 0) {
    errno = EMO_EEXIST;
    return -1;
  }
  if (path_exists_guard(full)) {
    errno = EMO_EEXIST;
    return -1;
  }
  if (!parent_exists(full)) {
    errno = EMO_ENOENT;
    return -1;
  }
  unsigned long nlen = slen(full);
  if (put_name(full, nlen) != 0) {
    return -1;
  }
  long answer = emo_mkdir(name_buf, nlen);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  return 0;
}

int rmdir(const char *path) {
  char full[EMO_PATH_MAX + 1];
  if (resolve(path, full, sizeof(full)) != 0) {
    return -1;
  }
  if (full[0] == 0) {
    errno = EMO_EINVAL;
    return -1;
  }
  if (dir_exists(full) != 1) {
    errno = EMO_ENOENT;
    return -1;
  }
  unsigned long plen = slen(full);
  if (put_name(full, plen) != 0) {
    return -1;
  }
  long answer = emo_rmdir(name_buf, plen);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  return 0;
}

int rename(const char *old_path, const char *new_path) {
  char old_full[EMO_PATH_MAX + 1];
  char new_full[EMO_PATH_MAX + 1];
  if (resolve(old_path, old_full, sizeof(old_full)) != 0) {
    return -1;
  }
  if (resolve(new_path, new_full, sizeof(new_full)) != 0) {
    return -1;
  }
  if (old_full[0] == 0 || new_full[0] == 0) {
    errno = EMO_EINVAL;
    return -1;
  }
  if (seq(old_full, new_full)) {
    return 0;
  }
  if (dir_exists(old_full) != 0 || dir_exists(new_full) != 0) {
    errno = EMO_EINVAL;
    return -1;
  }
  if (file_exists(old_full) != 1) {
    errno = EMO_ENOENT;
    return -1;
  }
  if (!parent_exists(new_full)) {
    errno = EMO_ENOENT;
    return -1;
  }
  int src = open_name(old_full, EMO_O_RDONLY);
  if (src < 0) {
    return -1;
  }
  int dst = open_name(new_full, EMO_O_WRONLY | EMO_O_CREAT | EMO_O_TRUNC);
  if (dst < 0) {
    close(src);
    return -1;
  }
  char buf[512];
  long n = 0;
  int failed = 0;
  while ((n = read(src, buf, sizeof(buf))) > 0) {
    if (write(dst, buf, (unsigned long)n) != n) {
      failed = 1;
      break;
    }
  }
  if (n < 0) {
    failed = 1;
  }
  if (close(dst) != 0) {
    failed = 1;
  }
  if (close(src) != 0) {
    failed = 1;
  }
  if (failed) {
    return -1;
  }
  return remove_name(old_full);
}

int stat(const char *path, struct emo_stat *st) {
  char full[EMO_PATH_MAX + 1];
  if (resolve(path, full, sizeof(full)) != 0) {
    return -1;
  }
  if (full[0] == 0 || dir_exists(full) > 0) {
    st->size = 0;
    st->flags = 0;
    st->is_dir = 1;
    return 0;
  }
  if (file_exists(full) != 1) {
    errno = EMO_ENOENT;
    return -1;
  }
  unsigned long nlen = slen(full);
  if (put_name(full, nlen) != 0) {
    return -1;
  }
  long answer = emo_file_read(name_buf, nlen, list_buf, 0);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  st->size = answer;
  st->flags = 0;
  st->is_dir = 0;
  return 0;
}

EMO_DIR *opendir(const char *path) {
  char full[EMO_PATH_MAX + 1];
  if (resolve(path, full, sizeof(full)) != 0) {
    return 0;
  }
  if (full[0] != 0 && dir_exists(full) != 1) {
    errno = EMO_ENOENT;
    return 0;
  }
  int i = 0;
  while (i < 2 && dirs[i].used) {
    i = i + 1;
  }
  if (i == 2) {
    errno = EMO_EMFILE;
    return 0;
  }
  EMO_DIR *d = &dirs[i];
  d->used = 1;
  d->index = 0;
  scopy(d->path, full, sizeof(d->path));
  long answer = emo_file_list(d->names, sizeof(d->names));
  if (answer < 0) {
    d->used = 0;
    errno = reason_errno(answer);
    return 0;
  }
  d->total = answer;
  return d;
}

struct emo_dirent *readdir(EMO_DIR *d) {
  if (d == 0 || !d->used) {
    errno = EMO_EBADF;
    return 0;
  }
  unsigned long plen = slen(d->path);
  long pos = d->index;
  while (pos < d->total) {
    long start = pos;
    while (pos < d->total && d->names[pos] != '\n') {
      pos = pos + 1;
    }
    long len = pos - start;
    if (pos < d->total) {
      pos = pos + 1;
    }
    long child = 0;
    if (plen > 0) {
      if (!under(d->names + start, (unsigned long)len, d->path, plen)) {
        continue;
      }
      child = (long)plen + 1;
    }
    long clen = 0;
    while (child + clen < len && d->names[start + child + clen] != '/') {
      clen = clen + 1;
    }
    if (clen == 0) {
      continue;
    }
    int seen = 0;
    long q = 0;
    while (q < start) {
      long s2 = q;
      while (q < d->total && d->names[q] != '\n') {
        q = q + 1;
      }
      long l2 = q - s2;
      if (q < d->total) {
        q = q + 1;
      }
      long c2 = 0;
      if (plen > 0) {
        if (!under(d->names + s2, (unsigned long)l2, d->path, plen)) {
          continue;
        }
        c2 = (long)plen + 1;
      }
      long k2 = 0;
      while (c2 + k2 < l2 && d->names[s2 + c2 + k2] != '/') {
        k2 = k2 + 1;
      }
      if (k2 == clen &&
          line_eq(d->names + s2 + c2, (unsigned long)k2,
                  d->names + start + child, (unsigned long)clen)) {
        seen = 1;
        break;
      }
    }
    if (seen) {
      continue;
    }
    long k = 0;
    while (k < clen) {
      dirent.name[k] = d->names[start + child + k];
      k = k + 1;
    }
    dirent.name[clen] = 0;
    d->index = pos;
    return &dirent;
  }
  d->index = pos;
  return 0;
}

int closedir(EMO_DIR *d) {
  if (d == 0 || !d->used) {
    errno = EMO_EBADF;
    return -1;
  }
  d->used = 0;
  return 0;
}

// ---- the arena's memory (EmoOS plan B, T1.3/T1.3k) ----
//
// The arena is the user pass's run — sixteen 64 KiB blocks, 1 MiB —
// mapped by the kernel at its physical identity. The allocator is a
// bump for new bytes and first-fit free lists for the bytes handed
// back: malloc's freed blocks and mmap's unmapped pages are reused,
// the T1.3k cut. Growing the arena past its run is T1.3v (frames,
// page-table extension, the death reclaim).

struct emo_heap_block {
  unsigned long size;
  struct emo_heap_block *next;
};

static struct emo_heap_block *free_list;
static struct emo_heap_block *page_free;

static void mem_init(void) {
  if (heap_ready) {
    return;
  }
  heap_ready = 1;
  long info = emo_arena_info();
  if (info <= 0) {
    return;
  }
  // The gate packs the arena's base and end page numbers: base in the
  // high 20 bits, end in the low 20 — an address's bit 31 would make
  // the answer look like a route.
  heap_base = (char *)(long)((info >> 20) << 12);
  heap_end = (char *)(long)((info & 1048575) << 12);
  heap_cur = heap_base;
}

// The arena's growth (T1.3v): the kernel extends past the run in whole
// 64 KiB blocks and answers the new end's page number; the library's
// heap end follows.
static int arena_extend(unsigned long need_end) {
  if (heap_base == 0) {
    errno = EMO_ENOMEM;
    return 0;
  }
  unsigned long end = (unsigned long)heap_end;
  if (need_end <= end) {
    return 1;
  }
  long answer = emo_arena_grow((long)(need_end - end));
  if (answer <= 0) {
    errno = EMO_ENOMEM;
    return 0;
  }
  heap_end = (char *)(long)(answer << 12);
  if ((unsigned long)heap_end < need_end) {
    errno = EMO_ENOMEM;
    return 0;
  }
  return 1;
}

void *sbrk(long n) {
  mem_init();
  if (heap_base == 0) {
    errno = EMO_ENOMEM;
    return (void *)-1;
  }
  if (n == 0) {
    return heap_cur;
  }
  long next = (long)heap_cur + n;
  if (next < (long)heap_base) {
    errno = EMO_ENOMEM;
    return (void *)-1;
  }
  if (next > (long)heap_end) {
    if (!arena_extend((unsigned long)next)) {
      return (void *)-1;
    }
  }
  char *old = heap_cur;
  heap_cur = (char *)next;
  return old;
}

int brk(void *addr) {
  mem_init();
  if (heap_base == 0) {
    errno = EMO_ENOMEM;
    return -1;
  }
  long a = (long)addr;
  if (a < (long)heap_base) {
    errno = EMO_ENOMEM;
    return -1;
  }
  if (a > (long)heap_end) {
    if (!arena_extend((unsigned long)a)) {
      return -1;
    }
  }
  heap_cur = (char *)a;
  return 0;
}

void *malloc(unsigned long n) {
  mem_init();
  if (heap_base == 0) {
    errno = EMO_ENOMEM;
    return 0;
  }
  unsigned long need = (n + 15) & ~15UL;
  struct emo_heap_block *prev = 0;
  struct emo_heap_block *b = free_list;
  while (b != 0) {
    if (b->size >= need) {
      if (prev == 0) {
        free_list = b->next;
      } else {
        prev->next = b->next;
      }
      if (b->size >= need + 32) {
        struct emo_heap_block *r =
            (struct emo_heap_block *)((char *)b + 16 + need);
        r->size = b->size - need - 16;
        r->next = free_list;
        free_list = r;
        b->size = need;
      }
      b->next = 0;
      return (char *)b + 16;
    }
    prev = b;
    b = b->next;
  }
  if (heap_cur + 16 + need > heap_end) {
    if (!arena_extend((unsigned long)(heap_cur + 16 + need))) {
      return 0;
    }
  }
  b = (struct emo_heap_block *)heap_cur;
  heap_cur = heap_cur + 16 + need;
  b->size = need;
  b->next = 0;
  return (char *)b + 16;
}

void free(void *p) {
  if (p == 0) {
    return;
  }
  struct emo_heap_block *b = (struct emo_heap_block *)((char *)p - 16);
  if ((char *)b < heap_base || (char *)b >= heap_end) {
    return;
  }
  b->next = free_list;
  free_list = b;
}

void *realloc(void *p, unsigned long n) {
  if (p == 0) {
    return malloc(n);
  }
  if (n == 0) {
    free(p);
    return 0;
  }
  struct emo_heap_block *b = (struct emo_heap_block *)((char *)p - 16);
  unsigned long old = b->size;
  char *q = malloc(n);
  if (q == 0) {
    return 0;
  }
  unsigned long k = old;
  if (k > n) {
    k = n;
  }
  unsigned long i = 0;
  while (i < k) {
    q[i] = ((char *)p)[i];
    i = i + 1;
  }
  free(p);
  return q;
}

void *mmap(void *addr, unsigned long len, int prot, int flags, int fd,
           long off) {
  (void)addr;
  (void)prot;
  (void)flags;
  (void)fd;
  (void)off;
  mem_init();
  if (heap_base == 0 || len == 0) {
    errno = EMO_EINVAL;
    return (void *)-1;
  }
  unsigned long need = (len + 4095) & ~4095UL;
  struct emo_heap_block *prev = 0;
  struct emo_heap_block *b = page_free;
  while (b != 0) {
    if (b->size >= need) {
      if (prev == 0) {
        page_free = b->next;
      } else {
        prev->next = b->next;
      }
      if (b->size >= need + 4096) {
        struct emo_heap_block *r =
            (struct emo_heap_block *)((char *)b + need);
        r->size = b->size - need;
        r->next = page_free;
        page_free = r;
      }
      char *p = (char *)b;
      unsigned long i = 0;
      while (i < need) {
        p[i] = 0;
        i = i + 1;
      }
      return p;
    }
    prev = b;
    b = b->next;
  }
  unsigned long cur = ((unsigned long)heap_cur + 4095) & ~4095UL;
  if (cur + need > (unsigned long)heap_end) {
    if (!arena_extend(cur + need)) {
      return (void *)-1;
    }
  }
  char *p = (char *)cur;
  heap_cur = p + need;
  unsigned long i = 0;
  while (i < need) {
    p[i] = 0;
    i = i + 1;
  }
  return p;
}

int munmap(void *addr, unsigned long len) {
  if (addr == 0 || len == 0) {
    errno = EMO_EINVAL;
    return -1;
  }
  struct emo_heap_block *b = (struct emo_heap_block *)addr;
  b->size = (len + 4095) & ~4095UL;
  b->next = page_free;
  page_free = b;
  return 0;
}

int mprotect(void *addr, unsigned long len, int prot) {
  (void)addr;
  (void)len;
  (void)prot;
  return 0;
}

// ---- the process and environment (EmoOS plan B, T1.4b1) ----

char **environ;

#define EMO_ENV_MAX 16
#define EMO_ENV_LEN 128
static char env_store[EMO_ENV_MAX][EMO_ENV_LEN];
static char *env_ptrs[EMO_ENV_MAX + 1];
static int env_ready;

static int env_match(const char *entry, const char *name, unsigned long nlen) {
  unsigned long i = 0;
  while (i < nlen) {
    if (entry[i] != name[i]) {
      return 0;
    }
    i = i + 1;
  }
  return entry[nlen] == '=';
}

static void env_init(void) {
  if (env_ready) {
    return;
  }
  env_ready = 1;
  int n = 0;
  if (environ != 0) {
    while (environ[n] != 0 && n < EMO_ENV_MAX) {
      scopy(env_store[n], environ[n], EMO_ENV_LEN);
      env_ptrs[n] = env_store[n];
      n = n + 1;
    }
  }
  env_ptrs[n] = 0;
  environ = env_ptrs;
}

static void env_put(int i, const char *name, unsigned long nlen,
                    const char *value, unsigned long vlen) {
  unsigned long k = 0;
  while (k < nlen) {
    env_store[i][k] = name[k];
    k = k + 1;
  }
  env_store[i][nlen] = '=';
  k = 0;
  while (k < vlen) {
    env_store[i][nlen + 1 + k] = value[k];
    k = k + 1;
  }
  env_store[i][nlen + 1 + vlen] = 0;
  env_ptrs[i] = env_store[i];
}

char *getenv(const char *name) {
  env_init();
  unsigned long nlen = slen(name);
  if (nlen == 0) {
    return 0;
  }
  int i = 0;
  while (environ[i] != 0) {
    if (env_match(environ[i], name, nlen)) {
      return environ[i] + nlen + 1;
    }
    i = i + 1;
  }
  return 0;
}

int setenv(const char *name, const char *value, int overwrite) {
  env_init();
  unsigned long nlen = slen(name);
  unsigned long vlen = slen(value);
  if (nlen == 0 || nlen + vlen + 2 > EMO_ENV_LEN) {
    errno = EMO_EINVAL;
    return -1;
  }
  int i = 0;
  while (environ[i] != 0) {
    if (env_match(environ[i], name, nlen)) {
      if (!overwrite) {
        return 0;
      }
      env_put(i, name, nlen, value, vlen);
      return 0;
    }
    i = i + 1;
  }
  if (i >= EMO_ENV_MAX) {
    errno = EMO_ENOMEM;
    return -1;
  }
  env_put(i, name, nlen, value, vlen);
  env_ptrs[i + 1] = 0;
  return 0;
}

int unsetenv(const char *name) {
  env_init();
  unsigned long nlen = slen(name);
  if (nlen == 0) {
    errno = EMO_EINVAL;
    return -1;
  }
  int i = 0;
  int j = 0;
  while (environ[i] != 0) {
    if (env_match(environ[i], name, nlen)) {
      i = i + 1;
    } else {
      if (j != i) {
        scopy(env_store[j], env_store[i], EMO_ENV_LEN);
      }
      env_ptrs[j] = env_store[j];
      j = j + 1;
      i = i + 1;
    }
  }
  env_ptrs[j] = 0;
  return 0;
}

long getpid(void) {
  return emo_getpid();
}

int setpgid(long pid, long pgid) {
  long a = emo_setpgid(pid, pgid);
  if (a < 0) {
    errno = reason_errno(a);
    return -1;
  }
  return 0;
}

long getpgid(long pid) {
  long a = emo_getpgid(pid);
  if (a < 0) {
    errno = reason_errno(a);
    return -1;
  }
  return a;
}

long wait4(long pid, int *status, int options, void *rusage) {
  (void)rusage;
  if (options != 0) {
    errno = EMO_ENOSYS;
    return -1;
  }
  // The answer is packed: the child's pid above its status word
  // (T1.4b2, T1.6) — the any-child wait cannot name the child
  // otherwise, and the status is POSIX's own: the exit code above the
  // low byte for an exit, the signal's number for a signal death.
  long a = emo_wait(pid);
  if (a < 0) {
    errno = reason_errno(a);
    return -1;
  }
  long child = a >> 32;
  if (status != 0) {
    *status = (int)(a & 0xffffffff);
  }
  return child;
}

long waitpid(long pid, int *status, int options) {
  return wait4(pid, status, options, 0);
}

long wait(int *status) {
  return wait4(-1, status, 0, 0);
}

// fork's C half (T1.4b2): the ecall, and the reason's errno. The child
// never returns here — it resumes at the assembly trampoline with the
// copied stack.
long emo_fork_call(long ctx, long entry) {
  long a = emo_fork(ctx, entry);
  if (a < 0) {
    errno = (a == -5) ? EMO_EAGAIN : reason_errno(a);
    return -1;
  }
  return a;
}

void exit(int code) {
  emo_exit(code);
}

void _exit(int code) {
  emo_exit(code);
}

// ---- execve (T1.4b3b) ----
//
// The wire's texts are space-separated, so a word carrying a space is
// refused rather than mangled; argv[0] is the name the kernel starts.
// The name, the argv[1..] and every envp word are copied into the
// library's own writable staging before the gate sees them.
static char exec_name_buf[EMO_NAME_MAX];
static char exec_args_buf[512];
static char exec_env_buf[256];

static int exec_word(char *dst, unsigned long cap, unsigned long *n,
                     const char *s, int first) {
  unsigned long l = slen(s);
  if (l == 0) {
    errno = EMO_EINVAL;
    return -1;
  }
  unsigned long i = 0;
  while (i < l) {
    if (s[i] == ' ') {
      errno = EMO_EINVAL;
      return -1;
    }
    i = i + 1;
  }
  unsigned long need = l + (first ? 0 : 1);
  if (*n + need > cap) {
    errno = EMO_E2BIG;
    return -1;
  }
  if (!first) {
    dst[*n] = ' ';
    *n = *n + 1;
  }
  i = 0;
  while (i < l) {
    dst[*n] = s[i];
    *n = *n + 1;
    i = i + 1;
  }
  return 0;
}

int execve(const char *path, char *const argv[], char *const envp[]) {
  unsigned long nlen = slen(path);
  if (nlen < 1 || nlen > EMO_NAME_MAX) {
    errno = EMO_ENAMETOOLONG;
    return -1;
  }
  unsigned long i = 0;
  while (i < nlen) {
    exec_name_buf[i] = path[i];
    i = i + 1;
  }
  unsigned long alen = 0;
  int first = 1;
  if (argv != 0) {
    int k = 1;
    while (argv[k] != 0) {
      if (exec_word(exec_args_buf, sizeof(exec_args_buf), &alen, argv[k],
                    first) != 0) {
        return -1;
      }
      first = 0;
      k = k + 1;
    }
  }
  unsigned long elen = 0;
  first = 1;
  if (envp != 0) {
    int k = 0;
    while (envp[k] != 0) {
      if (exec_word(exec_env_buf, sizeof(exec_env_buf), &elen, envp[k],
                    first) != 0) {
        return -1;
      }
      first = 0;
      k = k + 1;
    }
  }
  long answer = emo_execve(exec_name_buf, nlen, exec_args_buf, alen,
                           exec_env_buf, elen);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  _exit(127);
}

int execv(const char *path, char *const argv[]) {
  return execve(path, argv, environ);
}

// ---- the pipes (T1.5) ----
//
// `pipe` takes two free descriptor numbers and binds them to one new
// pipe; the kernel owns the ends, the counts and the ring, and the
// library's kind byte mirrors the binding so a read, write or close
// finds the kernel verb without a probe. `dup2` copies a descriptor:
// a pipe end's binding moves to the new number through the kernel, a
// file's name/flags/offset through the library's own table, a console
// stream's number bestows the console.

int pipe(int fds[2]) {
  int r = free_fd();
  int w = -1;
  if (r >= 0) {
    fd_kind[r] = EMO_KIND_PREAD;
    w = free_fd();
    fd_kind[r] = EMO_KIND_UNKNOWN;
  }
  if (r < 0 || w < 0) {
    errno = EMO_EMFILE;
    return -1;
  }
  long answer = emo_pipe_bind(r, w);
  if (answer < 0) {
    errno = pipe_errno(answer);
    return -1;
  }
  used[r] = 0;
  used[w] = 0;
  fd_kind[r] = EMO_KIND_PREAD;
  fd_kind[w] = EMO_KIND_PWRITE;
  fds[0] = r;
  fds[1] = w;
  return 0;
}

int dup(int fd) {
  if (!fd_is_open(fd)) {
    errno = EMO_EBADF;
    return -1;
  }
  int nfd = free_fd();
  if (nfd < 0) {
    errno = EMO_EMFILE;
    return -1;
  }
  return dup2(fd, nfd);
}

int dup2(int oldfd, int newfd) {
  if (oldfd < 0 || oldfd >= EMO_MAX_FD || newfd < 0 || newfd >= EMO_MAX_FD) {
    errno = EMO_EBADF;
    return -1;
  }
  if (oldfd == newfd) {
    if (!fd_is_open(oldfd)) {
      errno = EMO_EBADF;
      return -1;
    }
    return newfd;
  }
  int ok = fd_kind_of(oldfd);
  if (!fd_is_open(oldfd)) {
    errno = EMO_EBADF;
    return -1;
  }
  fd_drop(newfd);
  if (ok == EMO_KIND_PREAD || ok == EMO_KIND_PWRITE) {
    long answer = emo_pipe_dup(oldfd, newfd);
    if (answer < 0) {
      errno = pipe_errno(answer);
      return -1;
    }
    used[newfd] = 0;
    fd_kind[newfd] = (char)ok;
  } else if (ok == EMO_KIND_CIN || ok == EMO_KIND_COUT) {
    used[newfd] = 0;
    fd_kind[newfd] = (char)ok;
  } else {
    unsigned long k = 0;
    while (k < fd_nlen[oldfd]) {
      fd_name[newfd][k] = fd_name[oldfd][k];
      k = k + 1;
    }
    fd_name[newfd][fd_nlen[oldfd]] = 0;
    fd_nlen[newfd] = fd_nlen[oldfd];
    fd_flags[newfd] = fd_flags[oldfd];
    fd_off[newfd] = fd_off[oldfd];
    used[newfd] = 1;
    fd_kind[newfd] = EMO_KIND_FILE;
  }
  return newfd;
}

// ---- the signals (T1.6) ----
//
// The kernel's vocabulary is the eight signals; the disposition's
// word is 0 the default, 1 ignored, an address a handler. The mask
// the kernel keeps uses the signal's number as the bit; this file
// translates the POSIX `sigset_t`'s bit (signo - 1) at its boundary,
// so a program's `1 << (sig - 1)` is what it expects.

static int sig_known(int sig) {
  if (sig == EMO_SIGINT || sig == EMO_SIGQUIT || sig == EMO_SIGUSR1 ||
      sig == EMO_SIGSEGV || sig == EMO_SIGPIPE || sig == EMO_SIGTERM ||
      sig == EMO_SIGCHLD) {
    return 1;
  }
  return 0;
}

// The POSIX bit (signo - 1) word into the kernel's (bit signo).
static unsigned long sig_to_kernel(const unsigned long *set) {
  unsigned long k = 0;
  int sig = 1;
  while (sig <= 31) {
    if ((*set & (1UL << (sig - 1))) != 0) {
      k = k | (1UL << sig);
    }
    sig = sig + 1;
  }
  return k;
}

static void sig_from_kernel(unsigned long k, unsigned long *set) {
  unsigned long p = 0;
  int sig = 1;
  while (sig <= 31) {
    if ((k & (1UL << sig)) != 0) {
      p = p | (1UL << (sig - 1));
    }
    sig = sig + 1;
  }
  *set = p;
}

emo_sighandler_t signal(int sig, emo_sighandler_t handler) {
  if (sig <= 0 || sig >= 32) {
    errno = EMO_EINVAL;
    return EMO_SIG_ERR;
  }
  long disp = 0;
  if (handler == EMO_SIG_IGN) {
    disp = 1;
  } else if (handler != EMO_SIG_DFL) {
    disp = (long)handler;
  }
  long old = emo_sig_action(sig, disp);
  if (old < 0) {
    errno = reason_errno(old);
    return EMO_SIG_ERR;
  }
  if (old == 0) {
    return EMO_SIG_DFL;
  }
  if (old == 1) {
    return EMO_SIG_IGN;
  }
  return (emo_sighandler_t)old;
}

int kill(long pid, int sig) {
  if (sig < 0 || sig >= 32) {
    errno = EMO_EINVAL;
    return -1;
  }
  if (sig != 0 && !sig_known(sig) && sig != EMO_SIGKILL) {
    errno = EMO_EINVAL;
    return -1;
  }
  long a = emo_kill(pid, sig);
  if (a < 0) {
    errno = reason_errno(a);
    return -1;
  }
  return 0;
}

int raise(int sig) {
  return kill(getpid(), sig);
}

int sigprocmask(int how, const unsigned long *set, unsigned long *old) {
  if (how != EMO_SIG_BLOCK && how != EMO_SIG_UNBLOCK &&
      how != EMO_SIG_SETMASK) {
    errno = EMO_EINVAL;
    return -1;
  }
  long kset = set == 0 ? 0 : (long)sig_to_kernel(set);
  long a = emo_sig_mask(how, kset);
  if (a < 0) {
    errno = reason_errno(a);
    return -1;
  }
  if (old != 0) {
    sig_from_kernel((unsigned long)a, old);
  }
  return 0;
}

unsigned long sigpending(void) {
  unsigned long set = 0;
  long a = emo_sig_pending();
  if (a > 0) {
    sig_from_kernel((unsigned long)a, &set);
  }
  return set;
}
