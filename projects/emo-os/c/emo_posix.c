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
  int fd = 3;
  while (fd < EMO_MAX_FD && used[fd]) {
    fd = fd + 1;
  }
  if (fd == EMO_MAX_FD) {
    errno = EMO_EMFILE;
    return -1;
  }
  long answer = emo_fd_open(fd, name_buf, nlen, flags);
  if (answer < 0) {
    errno = reason_errno(answer);
    return -1;
  }
  used[fd] = 1;
  return fd;
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
  if (pid <= 0 || options != 0) {
    errno = EMO_ENOSYS;
    return -1;
  }
  long a = emo_wait(pid);
  if (a < 0) {
    errno = reason_errno(a);
    return -1;
  }
  if (status != 0) {
    *status = (int)((a & 0xff) << 8);
  }
  return pid;
}

long waitpid(long pid, int *status, int options) {
  return wait4(pid, status, options, 0);
}

long wait(int *status) {
  return wait4(-1, status, 0, 0);
}
