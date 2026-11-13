/* emo_ocaml_stub.c — the runtime's POSIX stubs, compiled and linked
   beside emo_ocaml_runtime.ml on every ocaml-target build.

   The POSIX calls OCaml's Unix module does not wrap — and the one it
   wraps against its own numbering: waitpid's WSIGNALED carries the
   signal in the runtime's internal numbering (negative on this
   platform), not the kernel's raw 16-bit wait status word, so the
   Emo-level wait_* decoders would read the wrong number. The stub
   answers the kernel's own status word, the same encoding the c
   runtime's waitpid returns, so the decoders and the runner's verdicts
   are byte-identical across the interpreter and both targets. */

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

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
