// The gate's C side (EmoOS plan B, T2.1): one function per documented
// verb the C library speaks, and the generic `emo_syscall` entry the
// musl `syscall()` shape sits on. The ecall itself lives in
// `arch/riscv64/syscall_arch.h`, the musl-derived stub layer; every
// wrapper here is a call over it. The numbers are the gate's verbs
// (docs/syscalls.md), not Linux's.

#ifndef EMO_SYSCALL_H
#define EMO_SYSCALL_H

// The documented verb numbers this layer exposes. The desktop and
// notification families (10..35) stay the Emo side's: a C program's
// POSIX surface does not reach them, and the contract's "by need"
// rule keeps them out until one does.
#define EMO_SYS_EXIT 0
#define EMO_SYS_WRITE 1
#define EMO_SYS_READ 2
#define EMO_SYS_SPAWN 3
#define EMO_SYS_WAIT 4
#define EMO_SYS_FILE_WRITE 6
#define EMO_SYS_FILE_READ 7
#define EMO_SYS_FILE_LIST 8
#define EMO_SYS_FILE_REMOVE 9
#define EMO_SYS_FD_OPEN 36
#define EMO_SYS_FD_CLOSE 37
#define EMO_SYS_FD_READ 38
#define EMO_SYS_FD_WRITE 39
#define EMO_SYS_FD_LSEEK 40
#define EMO_SYS_FD_FSTAT 41
#define EMO_SYS_PATH_TYPE 42
#define EMO_SYS_MKDIR 43
#define EMO_SYS_RMDIR 44
#define EMO_SYS_LIST_DIR 45
#define EMO_SYS_ARENA_INFO 46
#define EMO_SYS_ARENA_GROW 47
#define EMO_SYS_EXEC_ARGS 48
#define EMO_SYS_GETPID 49
#define EMO_SYS_SETPGID 50
#define EMO_SYS_GETPGID 51
#define EMO_SYS_FORK 52
#define EMO_SYS_EXECVE 54
#define EMO_SYS_PIPE_BIND 55
#define EMO_SYS_PIPE_READ 56
#define EMO_SYS_PIPE_PROBE 57
#define EMO_SYS_PIPE_WRITE 58
#define EMO_SYS_PIPE_DUP 59
#define EMO_SYS_PIPE_CLOSE 60
#define EMO_SYS_KILL 61
#define EMO_SYS_SIG_ACTION 62
#define EMO_SYS_SIG_MASK 63
#define EMO_SYS_SIG_RETURN 64
#define EMO_SYS_SIG_PENDING 65

// The generic entry: the verb and its six words, the gate's answer
// verbatim. The typed wrappers below are the intended surface; this
// one is the raw crossing a porter's `syscall()` needs.
long emo_syscall(long n, long a, long b, long c, long d, long e, long f);

// Verb 0: the calling process ends; the root's exit ends the machine.
__attribute__((noreturn)) void emo_exit(long code);

// Verb 1: the len bytes at buf ride the console. The source segment
// needs R only (T1.0).
long emo_write(const void *buf, unsigned long len);

// Verb 2: the next console byte, blocking until one exists.
long emo_console_read(void);

// Verb 3: a child enters this image's top level on a fresh stack.
long emo_spawn(void);

// Verb 4: the child's pid in the high 32 bits, its status word in the
// low; 0 or a negative pid waits for any child. Blocks until one exits.
long emo_wait(long pid);

// Verb 6: the name becomes the len bytes at buf (at most 2048). The
// name and the bytes are the caller's staged sources (T1.0).
long emo_gate_file_write(const void *name, unsigned long nlen,
                    const void *buf, unsigned long len);

// Verb 7: the file's bytes land at buf, at most cap; answers the size.
long emo_gate_file_read(const void *name, unsigned long nlen, void *buf,
                   unsigned long cap);

// Verb 8: the names, each followed by a newline, land at buf.
long emo_file_list(void *buf, unsigned long cap);

// Verb 9: the file is gone.
long emo_file_remove(const void *name, unsigned long nlen);

// Verbs 36..41: the filesystem service's open-file table. The fd
// numbers are the caller's; the service owns each handle's offset and
// size. The write's source and the open's name are staged sources.
long emo_fd_open(long fd, const void *name, unsigned long nlen, long flags);
long emo_fd_close(long fd);
long emo_fd_read(long fd, void *buf, unsigned long n);
long emo_fd_write(long fd, const void *buf, unsigned long n);
long emo_fd_seek(long fd, long off, long whence);
long emo_fd_stat(long fd);

// Verbs 42..45: the real directory entries and the typed listing.
long emo_path_type(const void *name, unsigned long nlen);
long emo_mkdir(const void *name, unsigned long nlen);
long emo_rmdir(const void *name, unsigned long nlen);
long emo_list_dir(const void *name, unsigned long nlen, void *buf,
                  unsigned long cap);

// Verbs 46..47: the caller's arena, and its growth by whole blocks.
long emo_arena_info(void);
long emo_arena_grow(long bytes);

// Verb 48: the name and the arguments' text on the execargs page.
long emo_exec_args(const void *name, unsigned long nlen, const void *args,
                   unsigned long alen);

// Verbs 49..52: the pid, the process group, and fork's saved context
// and resume entry.
long emo_getpid(void);
long emo_setpgid(long pid, long pgid);
long emo_getpgid(long pid);
long emo_fork(long ctx, long entry);

// Verb 54: the image replaced in place; never returns on success.
long emo_execve(const void *name, unsigned long nlen, const void *args,
                unsigned long alen, const void *env, unsigned long elen);

// Verbs 55..60: the pipes. The read blocks on an empty ring a writer
// may still fill and answers 0 at the last writer's close; the write
// answers what the ring's room took.
long emo_pipe_bind(long rfd, long wfd);
long emo_pipe_read(long fd, void *buf, unsigned long n);
long emo_pipe_probe(long fd);
long emo_pipe_write(long fd, const void *buf, unsigned long n);
long emo_pipe_dup(long oldfd, long newfd);
long emo_pipe_close(long fd);

// Verbs 61..65: the signals. The disposition's word is 0 the default,
// 1 ignored, an address a handler; the mask's bits are the signal
// numbers themselves.
long emo_kill(long pid, long sig);
long emo_sig_action(long sig, long disp);
long emo_sig_mask(long how, long set);
long emo_sig_return(void);
long emo_sig_pending(void);

#endif
