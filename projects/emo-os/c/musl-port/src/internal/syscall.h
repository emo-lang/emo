// The port's `__syscall` seam (EmoOS plan B, T2.2): musl's mallocng
// spells its break as `__syscall(SYS_brk, p)`, and this header routes
// that one shape to the gate's arena instead of the vendored arch
// stubs. `SYS_brk` is the port's own number; the kernel still sees
// only the T2.1 verbs. The other argument-count entries exist so a
// compiled musl source that reaches for the seam fails loudly at link
// time rather than silently taking a Linux number.

#ifndef EMO_PORT_SYSCALL_H
#define EMO_PORT_SYSCALL_H

#include <sys/syscall.h>

#undef SYS_brk
#define SYS_brk 1

long __emo_port_syscall0(long);
long __emo_port_syscall1(long, long);
long __emo_port_syscall2(long, long);
long __emo_port_syscall3(long, long, long);
long __emo_port_syscall4(long, long, long, long);
long __emo_port_syscall5(long, long, long, long, long);
long __emo_port_syscall6(long, long, long, long, long, long);

#define __SYSCALL_NARGS_X(a, b, c, d, e, f, g, h, n, ...) n
#define __SYSCALL_NARGS(...) \
  __SYSCALL_NARGS_X(__VA_ARGS__, 7, 6, 5, 4, 3, 2, 1, 0, )
#define __SYSCALL_CONCAT_X(a, b) a##b
#define __SYSCALL_CONCAT(a, b) __SYSCALL_CONCAT_X(a, b)
#define __SYSCALL_DISP(b, ...) \
  __SYSCALL_CONCAT(b, __SYSCALL_NARGS(__VA_ARGS__))(__VA_ARGS__)

#define __syscall(...) __SYSCALL_DISP(__emo_port_syscall, __VA_ARGS__)

#endif
