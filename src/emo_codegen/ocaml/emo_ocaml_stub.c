/* emo_ocaml_stub.c — the runtime's POSIX stubs, compiled and linked
   beside emo_ocaml_runtime.ml on every ocaml-target build.

   The POSIX calls OCaml's Unix module does not wrap — and the one it
   wraps against its own numbering: waitpid's WSIGNALED carries the
   signal in the runtime's internal numbering (negative on this
   platform), not the kernel's raw 16-bit wait status word, so the
   Emo-level wait_* decoders would read the wrong number. The stub
   answers the kernel's own status word, the same encoding the c
   runtime's waitpid returns, so the decoders and the runner's verdicts
   are byte-identical across the interpreter and both targets. The same
   file carries the monotonic clock, which the Unix module does not wrap
   either: clock_gettime(CLOCK_MONOTONIC), nanoseconds, the same
   instrument the interpreter and the c runtime read. */

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/unixsupport.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <stdlib.h>
#include <string.h>

CAMLprim value emo_stub_setpgid(value v_pid, value v_pgid) {
  CAMLparam2(v_pid, v_pgid);
  if (setpgid((pid_t)Int_val(v_pid), (pid_t)Int_val(v_pgid)) < 0)
    unix_error(errno, "setpgid", Nothing);
  CAMLreturn(Val_int(0));
}

CAMLprim value emo_stub_waitpid(value v_pid) {
  CAMLparam1(v_pid);
  int st = 0;
  pid_t r;
  caml_enter_blocking_section();
  r = waitpid((pid_t)Int_val(v_pid), &st, 0);
  caml_leave_blocking_section();
  if (r < 0) unix_error(errno, "waitpid", Nothing);
  CAMLreturn(Val_int(st));
}

CAMLprim value emo_stub_waitpid_nohang(value v_pid) {
  CAMLparam1(v_pid);
  CAMLlocal1(v_result);
  int st = 0;
  pid_t r;
  caml_enter_blocking_section();
  r = waitpid((pid_t)Int_val(v_pid), &st, WNOHANG);
  caml_leave_blocking_section();
  if (r < 0) unix_error(errno, "waitpid_nohang", Nothing);
  /* the declared type is (int * int): the pid — 0 when children exist
     and none has exited yet — then the kernel's own status word */
  v_result = caml_alloc_2(0, Val_int((int)r), Val_int(st));
  CAMLreturn(v_result);
}

CAMLprim value emo_stub_monotonic_ns(value v_unit) {
  CAMLparam1(v_unit);
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
    unix_error(errno, "clock_gettime", Nothing);
  CAMLreturn(
      caml_copy_int64((int64_t)ts.tv_sec * 1000000000 + (int64_t)ts.tv_nsec));
}

/* The fd passage and the shm tier, the wayland wire's own calls — the
   same stubs the interpreter's runtime rides (emo_posix_stub.c). One
   sendmsg with one SCM_RIGHTS name: the bytes sent, -2 on would-block
   (the scheduler parks and re-runs the call), the Unix error raised
   otherwise. A partial send answers its own count, the c runtime's
   shape. */
CAMLprim value emo_stub_sendmsg_fd(value v_fd, value v_data, value v_pass) {
  CAMLparam3(v_fd, v_data, v_pass);
  struct msghdr msg;
  struct iovec iov;
  union {
    struct cmsghdr align;
    unsigned char buf[CMSG_SPACE(sizeof(int))];
  } control;
  memset(&msg, 0, sizeof msg);
  iov.iov_base = (void *)Bytes_val(v_data);
  iov.iov_len = (size_t)caml_string_length(v_data);
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = control.buf;
  msg.msg_controllen = sizeof control.buf;
  struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int));
  *(int *)CMSG_DATA(cmsg) = Int_val(v_pass);
  msg.msg_controllen = CMSG_SPACE(sizeof(int));
  int fd = Int_val(v_fd);
  ssize_t put;
  caml_enter_blocking_section();
  put = sendmsg(fd, &msg, 0);
  caml_leave_blocking_section();
  if (put >= 0) CAMLreturn(Val_int((int)put));
  if (errno == EAGAIN || errno == EWOULDBLOCK) CAMLreturn(Val_int(-2));
  unix_error(errno, "sendmsg", Nothing);
  CAMLreturn(Val_int(-2));
}

/* One recvmsg with the ancillary queue read back: the triple
   (got, data, passed fd) with the fd -1 when the read carried no name.
   -2 on would-block, the Unix error raised otherwise; MSG_CMSG_CLOEXEC
   where the platform defines it, the c runtime's guard. */
CAMLprim value emo_stub_recvmsg_fd(value v_fd, value v_cap) {
  CAMLparam2(v_fd, v_cap);
  CAMLlocal2(v_data, v_result);
  int cap = Int_val(v_cap);
  char *buf = malloc((size_t)cap);
  if (buf == NULL) unix_error(ENOMEM, "recvmsg", Nothing);
  struct msghdr msg;
  struct iovec iov;
  union {
    struct cmsghdr align;
    unsigned char buf2[CMSG_SPACE(sizeof(int))];
  } control;
  memset(&msg, 0, sizeof msg);
  iov.iov_base = buf;
  iov.iov_len = (size_t)cap;
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = control.buf2;
  msg.msg_controllen = sizeof control.buf2;
  int flags = 0;
#ifdef MSG_CMSG_CLOEXEC
  flags = MSG_CMSG_CLOEXEC;
#endif
  int fd = Int_val(v_fd);
  ssize_t got;
  caml_enter_blocking_section();
  got = recvmsg(fd, &msg, flags);
  caml_leave_blocking_section();
  if (got < 0) {
    int e = errno;
    free(buf);
    if (e == EAGAIN || e == EWOULDBLOCK)
      v_result = caml_alloc_3(0, Val_int(-2), Val_int(0), Val_int(-1));
    else
      unix_error(e, "recvmsg", Nothing);
    CAMLreturn(v_result);
  }
  int passed = -1;
  for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL;
       c = CMSG_NXTHDR(&msg, c)) {
    if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS &&
        c->cmsg_len >= CMSG_LEN(sizeof(int))) {
      memcpy(&passed, CMSG_DATA(c), sizeof(int));
      break;
    }
  }
  v_data = caml_alloc_string((mlsize_t)got);
  memcpy((void *)Bytes_val(v_data), buf, (size_t)got);
  free(buf);
  /* the declared type is (int * string * int): got, then the data, then
     the passed fd — the fields sit in that order */
  v_result = caml_alloc_3(0, Val_int((int)got), v_data, Val_int(passed));
  CAMLreturn(v_result);
}

CAMLprim value emo_stub_ftruncate(value v_fd, value v_size) {
  CAMLparam2(v_fd, v_size);
  if (ftruncate(Int_val(v_fd), (off_t)Int64_val(v_size)) != 0)
    unix_error(errno, "ftruncate", Nothing);
  CAMLreturn(Val_int(0));
}

/* One pwrite: the bytes written, the Unix error raised otherwise — the
   loop over the buffer belongs to the caller, the c runtime's shape. */
CAMLprim value emo_stub_pwrite(value v_fd, value v_data, value v_off) {
  CAMLparam3(v_fd, v_data, v_off);
  char *base = (void *)Bytes_val(v_data);
  size_t len = (size_t)caml_string_length(v_data);
  off_t off = (off_t)Int64_val(v_off);
  int fd = Int_val(v_fd);
  ssize_t put;
  caml_enter_blocking_section();
  put = pwrite(fd, base, len, off);
  caml_leave_blocking_section();
  if (put < 0) unix_error(errno, "pwrite", Nothing);
  CAMLreturn(Val_int((int)put));
}
