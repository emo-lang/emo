// The gate's typed syscall wrappers (EmoOS plan B, T2.1): one
// function per documented verb the C library speaks, over the
// musl-derived ecall stubs. The header carries the API's comments;
// this file is the crossing itself.

#include "emo_syscall.h"

#include "arch/riscv64/syscall_arch.h"

long emo_syscall(long n, long a, long b, long c, long d, long e, long f) {
  return __syscall6(n, a, b, c, d, e, f);
}

void emo_exit(long code) {
  __syscall1(EMO_SYS_EXIT, code);
  __builtin_unreachable();
}

long emo_write(const void *buf, unsigned long len) {
  return __syscall2(EMO_SYS_WRITE, (long)buf, (long)len);
}

long emo_console_read(void) {
  return __syscall0(EMO_SYS_READ);
}

long emo_spawn(void) {
  return __syscall0(EMO_SYS_SPAWN);
}

long emo_wait(long pid) {
  return __syscall1(EMO_SYS_WAIT, pid);
}

long emo_file_write(const void *name, unsigned long nlen, const void *buf,
                    unsigned long len) {
  return __syscall4(EMO_SYS_FILE_WRITE, (long)name, (long)nlen, (long)buf,
                    (long)len);
}

long emo_file_read(const void *name, unsigned long nlen, void *buf,
                   unsigned long cap) {
  return __syscall4(EMO_SYS_FILE_READ, (long)name, (long)nlen, (long)buf,
                    (long)cap);
}

long emo_file_list(void *buf, unsigned long cap) {
  return __syscall2(EMO_SYS_FILE_LIST, (long)buf, (long)cap);
}

long emo_file_remove(const void *name, unsigned long nlen) {
  return __syscall2(EMO_SYS_FILE_REMOVE, (long)name, (long)nlen);
}

long emo_fd_open(long fd, const void *name, unsigned long nlen, long flags) {
  return __syscall4(EMO_SYS_FD_OPEN, fd, (long)name, (long)nlen, flags);
}

long emo_fd_close(long fd) {
  return __syscall1(EMO_SYS_FD_CLOSE, fd);
}

long emo_fd_read(long fd, void *buf, unsigned long n) {
  return __syscall3(EMO_SYS_FD_READ, fd, (long)buf, (long)n);
}

long emo_fd_write(long fd, const void *buf, unsigned long n) {
  return __syscall3(EMO_SYS_FD_WRITE, fd, (long)buf, (long)n);
}

long emo_fd_seek(long fd, long off, long whence) {
  return __syscall3(EMO_SYS_FD_LSEEK, fd, off, whence);
}

long emo_fd_stat(long fd) {
  return __syscall1(EMO_SYS_FD_FSTAT, fd);
}

long emo_path_type(const void *name, unsigned long nlen) {
  return __syscall2(EMO_SYS_PATH_TYPE, (long)name, (long)nlen);
}

long emo_mkdir(const void *name, unsigned long nlen) {
  return __syscall2(EMO_SYS_MKDIR, (long)name, (long)nlen);
}

long emo_rmdir(const void *name, unsigned long nlen) {
  return __syscall2(EMO_SYS_RMDIR, (long)name, (long)nlen);
}

long emo_list_dir(const void *name, unsigned long nlen, void *buf,
                  unsigned long cap) {
  return __syscall4(EMO_SYS_LIST_DIR, (long)name, (long)nlen, (long)buf,
                    (long)cap);
}

long emo_arena_info(void) {
  return __syscall0(EMO_SYS_ARENA_INFO);
}

long emo_arena_grow(long bytes) {
  return __syscall1(EMO_SYS_ARENA_GROW, bytes);
}

long emo_exec_args(const void *name, unsigned long nlen, const void *args,
                   unsigned long alen) {
  return __syscall4(EMO_SYS_EXEC_ARGS, (long)name, (long)nlen, (long)args,
                    (long)alen);
}

long emo_getpid(void) {
  return __syscall0(EMO_SYS_GETPID);
}

long emo_setpgid(long pid, long pgid) {
  return __syscall2(EMO_SYS_SETPGID, pid, pgid);
}

long emo_getpgid(long pid) {
  return __syscall1(EMO_SYS_GETPGID, pid);
}

long emo_fork(long ctx, long entry) {
  return __syscall2(EMO_SYS_FORK, ctx, entry);
}

long emo_execve(const void *name, unsigned long nlen, const void *args,
                unsigned long alen, const void *env, unsigned long elen) {
  return __syscall6(EMO_SYS_EXECVE, (long)name, (long)nlen, (long)args,
                    (long)alen, (long)env, (long)elen);
}

long emo_pipe_bind(long rfd, long wfd) {
  return __syscall2(EMO_SYS_PIPE_BIND, rfd, wfd);
}

long emo_pipe_read(long fd, void *buf, unsigned long n) {
  return __syscall3(EMO_SYS_PIPE_READ, fd, (long)buf, (long)n);
}

long emo_pipe_probe(long fd) {
  return __syscall1(EMO_SYS_PIPE_PROBE, fd);
}

long emo_pipe_write(long fd, const void *buf, unsigned long n) {
  return __syscall3(EMO_SYS_PIPE_WRITE, fd, (long)buf, (long)n);
}

long emo_pipe_dup(long oldfd, long newfd) {
  return __syscall2(EMO_SYS_PIPE_DUP, oldfd, newfd);
}

long emo_pipe_close(long fd) {
  return __syscall1(EMO_SYS_PIPE_CLOSE, fd);
}

long emo_kill(long pid, long sig) {
  return __syscall2(EMO_SYS_KILL, pid, sig);
}

long emo_sig_action(long sig, long disp) {
  return __syscall2(EMO_SYS_SIG_ACTION, sig, disp);
}

long emo_sig_mask(long how, long set) {
  return __syscall2(EMO_SYS_SIG_MASK, how, set);
}

long emo_sig_return(void) {
  return __syscall0(EMO_SYS_SIG_RETURN);
}

long emo_sig_pending(void) {
  return __syscall0(EMO_SYS_SIG_PENDING);
}
