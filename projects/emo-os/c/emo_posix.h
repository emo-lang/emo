// The C library's fd surface (EmoOS plan B, T1.1): POSIX-shaped
// descriptors over the gate's whole-file verbs. fd 0 is the serial
// console's byte stream, fd 1 and 2 the console's write, and every
// fd from 3 up names a file the library has opened. The kernel's
// file interface stays whole-file; the offset and the buffer are the
// library's, per process, exactly where a libc's fd table lives.

#ifndef EMO_POSIX_H
#define EMO_POSIX_H

#define EMO_MAX_FD 16

#define EMO_O_RDONLY 0
#define EMO_O_WRONLY 1
#define EMO_O_RDWR 2
#define EMO_O_CREAT 0100
#define EMO_O_TRUNC 01000
#define EMO_O_APPEND 02000

#define EMO_SEEK_SET 0
#define EMO_SEEK_CUR 1
#define EMO_SEEK_END 2

// Linux's numbers: the C programs a port brings already speak them.
#define EMO_EBADF 9
#define EMO_EFAULT 14
#define EMO_EINVAL 22
#define EMO_EMFILE 24
#define EMO_ENOENT 2
#define EMO_EACCES 13
#define EMO_ENOSPC 28
#define EMO_EIO 5
#define EMO_EEXIST 17
#define EMO_ENOTDIR 20
#define EMO_EISDIR 21
#define EMO_ERANGE 34
#define EMO_ENAMETOOLONG 36
#define EMO_ENOTEMPTY 39
#define EMO_ENOMEM 12

#define EMO_PATH_MAX 24
#define EMO_DIR_LIST 2048

struct emo_stat {
  long size;
  int flags;
  int is_dir;
};

struct emo_dirent {
  char name[EMO_PATH_MAX + 1];
};

typedef struct emo_DIR {
  int used;
  long index;
  long total;
  char path[EMO_PATH_MAX + 1];
  char names[EMO_DIR_LIST];
} EMO_DIR;

extern int errno;

int open(const char *path, int flags);
int close(int fd);
long read(int fd, void *buf, unsigned long n);
long write(int fd, const void *buf, unsigned long n);
long lseek(int fd, long off, int whence);
int fstat(int fd, struct emo_stat *st);
int unlink(const char *path);

// The path layer (EmoOS plan B, T1.2): a root, relative and absolute
// names, `.` and `..`, the process's cwd, and the directory calls over
// the volume's flat names — a directory is the marker name `dir/` and
// the names under its prefix.
char *getcwd(char *buf, unsigned long size);
int chdir(const char *path);
int mkdir(const char *path, int mode);
int rmdir(const char *path);
int rename(const char *old_path, const char *new_path);
int stat(const char *path, struct emo_stat *st);
EMO_DIR *opendir(const char *path);
struct emo_dirent *readdir(EMO_DIR *d);
int closedir(EMO_DIR *d);

// The arena's memory surface (EmoOS plan B, T1.3): brk/sbrk and the
// anonymous private mmap live inside the process's 64 KiB arena, which
// the kernel exposes with arena_info; munmap is the bump allocator's
// no-op and mprotect answers 0. A write past the arena's end is the
// page fault it always was.
void *malloc(unsigned long n);
void free(void *p);
void *realloc(void *p, unsigned long n);
void *sbrk(long n);
int brk(void *addr);
void *mmap(void *addr, unsigned long len, int prot, int flags, int fd,
           long off);
int munmap(void *addr, unsigned long len);
int mprotect(void *addr, unsigned long len, int prot);

#endif
