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
#define EMO_E2BIG 7
#define EMO_EAGAIN 11
#define EMO_EEXIST 17
#define EMO_ENOTDIR 20
#define EMO_EISDIR 21
#define EMO_ERANGE 34
#define EMO_ENAMETOOLONG 36
#define EMO_ENOTEMPTY 39
#define EMO_ENOMEM 12
#define EMO_ENOSYS 38
#define EMO_ESPIPE 29
#define EMO_EPIPE 32

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

// The process and environment surface (EmoOS plan B, T1.4b1): the
// pid, the process group, the environment's table, and the wait's
// status words. The envp a child starts with is empty (T1.4a); the
// library's environ/setenv build from there.
extern char **environ;
long getpid(void);
int setpgid(long pid, long pgid);
long getpgid(long pid);
char *getenv(const char *name);
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
long wait4(long pid, int *status, int options, void *rusage);
long waitpid(long pid, int *status, int options);
long wait(int *status);
long fork(void);
void exit(int code) __attribute__((noreturn));
void _exit(int code) __attribute__((noreturn));

// execve (EmoOS plan B, T1.4b3b): the volume name (no path layer), the
// argv[1..] and the envp's NAME=VALUE words. The spaces are the wire's
// separators, so a word containing one is EINVAL; argv[0] is the name
// the kernel starts. Success never returns.
int execve(const char *path, char *const argv[], char *const envp[]);
int execv(const char *path, char *const argv[]);

// The pipes (EmoOS plan B, T1.5): `pipe` binds two fresh descriptors to
// a new pipe — fds[0] the read end, fds[1] the write end. A read of an
// empty pipe whose writers are all gone answers 0 (the last writer's
// close is EOF); a write to a pipe whose readers are all gone is EPIPE.
// The ends copy across `fork` and the low three across `execve`.
int pipe(int fds[2]);
int dup(int fd);
int dup2(int oldfd, int newfd);

// The signals (EmoOS plan B, T1.6): the vocabulary the kernel carries —
// SIGINT, SIGQUIT, SIGKILL, SIGUSR1, SIGSEGV, SIGPIPE, SIGTERM and
// SIGCHLD. `signal` sets a disposition and answers the old one, SIG_ERR
// on a refusal (a signal outside the vocabulary, SIGKILL caught or
// ignored, a handler outside the image's executable segments). A
// handler runs on the interrupted stack with every signal masked; the
// interrupted mask returns when it does. `sigprocmask` takes the usual
// bit (signo - 1) word. A signal reaches a parked process only when its
// wait resolves — kill does not interrupt a blocked read yet.
typedef void (*emo_sighandler_t)(int);

#define EMO_SIG_DFL ((emo_sighandler_t)0)
#define EMO_SIG_IGN ((emo_sighandler_t)1)
#define EMO_SIG_ERR ((emo_sighandler_t)-1)

#define EMO_SIGINT 2
#define EMO_SIGQUIT 3
#define EMO_SIGKILL 9
#define EMO_SIGUSR1 10
#define EMO_SIGSEGV 11
#define EMO_SIGPIPE 13
#define EMO_SIGTERM 15
#define EMO_SIGCHLD 17

#define EMO_SIG_BLOCK 0
#define EMO_SIG_UNBLOCK 1
#define EMO_SIG_SETMASK 2

emo_sighandler_t signal(int sig, emo_sighandler_t handler);
int kill(long pid, int sig);
int raise(int sig);
int sigprocmask(int how, const unsigned long *set, unsigned long *old);
unsigned long sigpending(void);

#define EMO_WIFEXITED(s) (((s) & 0x7f) == 0)
#define EMO_WEXITSTATUS(s) (((s) >> 8) & 0xff)
#define EMO_WIFSIGNALED(s) (((s) & 0x7f) != 0 && ((s) & 0x7f) != 0x7f)
#define EMO_WTERMSIG(s) ((s) & 0x7f)

#endif
