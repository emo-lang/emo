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

struct emo_stat {
  long size;
  int flags;
};

extern int errno;

int open(const char *path, int flags);
int close(int fd);
long read(int fd, void *buf, unsigned long n);
long write(int fd, const void *buf, unsigned long n);
long lseek(int fd, long off, int whence);
int fstat(int fd, struct emo_stat *st);
int unlink(const char *path);

#endif
