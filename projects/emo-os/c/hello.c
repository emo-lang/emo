// The C door's program (EmoOS plan B, M0 and T1.1): the smallest
// proof that a Linux-shaped C toolchain builds for EmoOS, that the
// machine's own exec loader runs the result, and that the library's
// fd table reaches the volume through the gate — open, write, close,
// open, fstat, lseek, read, close, unlink.

#include "emo_posix.h"

static char first[] = "fd table on EmoOS\n";
static char second[] = "read back: ";
static char cleaned[] = "fd table cleaned\n";
static char stat_ok[] = "stat ok\n";
static char stat_bad[] = "stat wrong\n";
static char path_ok[] = "path ok\n";
static char dir_ok[] = "dir listing ok\n";
static char dir_bad[] = "dir listing bad\n";
static char rename_ok[] = "rename ok\n";
static char vfs_clean[] = "vfs cleaned\n";
static char heap_ok[] = "heap ok\n";
static char mmap_ok[] = "mmap ok\n";
static char reuse_ok[] = "reuse ok\n";
static char mmap_reuse_ok[] = "mmap reuse ok\n";
static char grow_ok[] = "grow ok\n";
static char args_ok[] = "args ok\n";
static char args_none[] = "args none\n";
static char proc_ok[] = "proc ok\n";
static char env_ok[] = "env ok\n";
static char fork_ok[] = "fork ok\n";
static char wait_ok[] = "wait ok\n";
static char fdfork_ok[] = "fd fork ok\n";
static char fdfork_msg[] = "fork fd\n";
static char execve_ok[] = "execve ok\n";
static char execve_child_ok[] = "execve child ok\n";
static char execve_child_bad[] = "execve child bad\n";
static char pipe_ok[] = "pipe ok\n";
static char pipe_bad[] = "pipe bad\n";
static char pipe_dup_ok[] = "pipe dup ok\n";
static char pipe_dup_bad[] = "pipe dup bad\n";
static char pipe_exec_ok[] = "pipe exec ok\n";
static char pipe_exec_bad[] = "pipe exec bad\n";
static char pipe_big_ok[] = "pipe big ok\n";
static char pipe_big_bad[] = "pipe big bad\n";
static char pipe_epipe_ok[] = "pipe epipe ok\n";
static char pipe_epipe_bad[] = "pipe epipe bad\n";
static char sig_ok[] = "signal ok\n";
static char sig_bad[] = "signal bad\n";
static char sig_mask_ok[] = "signal mask ok\n";
static char sig_mask_bad[] = "signal mask bad\n";
static char sig_kill_ok[] = "signal kill ok\n";
static char sig_kill_bad[] = "signal kill bad\n";

static int sig_seen;
static int sig_chld_seen;

static void on_usr1(int s) {
  sig_seen = s;
}

static void on_chld(int s) {
  sig_chld_seen = s;
}
static char pipe_child_line[] = "pipe child line\n";
static char pipe_greet[] = "pipe greeting\n";
static char pipe_dup_line[] = "dup2 line\n";

static long parse_dec(const char *s) {
  long n = 0;
  int i = 0;
  while (s[i] >= '0' && s[i] <= '9') {
    n = n * 10 + (s[i] - '0');
    i = i + 1;
  }
  return n;
}

static void fmt_dec(char *dst, long n) {
  char tmp[24];
  int i = 0;
  if (n == 0) {
    dst[0] = '0';
    dst[1] = 0;
    return;
  }
  while (n > 0) {
    tmp[i] = (char)('0' + (n % 10));
    i = i + 1;
    n = n / 10;
  }
  int j = 0;
  while (i > 0) {
    i = i - 1;
    dst[j] = tmp[i];
    j = j + 1;
  }
  dst[j] = 0;
}

static int streq(const char *a, const char *b) {
  int i = 0;
  while (a[i] != 0 && b[i] != 0) {
    if (a[i] != b[i]) {
      return 0;
    }
    i = i + 1;
  }
  return a[i] == b[i];
}

int main(int argc, char **argv, char **envp) {
  if (argc >= 2 && streq(argv[1], "pipechild")) {
    write(1, pipe_greet, sizeof(pipe_greet) - 1);
    return 0;
  }
  if (argc >= 2 && streq(argv[1], "execchild")) {
    const char *ev = getenv("EMO_EXEC");
    long want = argc >= 3 ? parse_dec(argv[2]) : -1;
    if (ev != 0 && streq(ev, "1") && want == getpid()) {
      write(1, execve_child_ok, sizeof(execve_child_ok) - 1);
      return 0;
    }
    write(2, execve_child_bad, sizeof(execve_child_bad) - 1);
    return 1;
  }
  (void)envp;
  char head[3];
  char buf[64];
  struct emo_stat st;
  const char *name = "fd.txt";

  int fd = open(name, EMO_O_WRONLY | EMO_O_CREAT | EMO_O_TRUNC);
  if (fd < 0) {
    write(2, "open write failed\n", 18);
    return 1;
  }
  write(fd, first, sizeof(first) - 1);
  close(fd);

  fd = open(name, EMO_O_RDWR);
  if (fd < 0) {
    write(2, "open read failed\n", 17);
    return 2;
  }
  if (fstat(fd, &st) != 0 || st.size != (long)(sizeof(first) - 1)) {
    write(2, stat_bad, sizeof(stat_bad) - 1);
    return 3;
  }
  write(1, stat_ok, sizeof(stat_ok) - 1);
  read(fd, head, sizeof(head));
  lseek(fd, 0, EMO_SEEK_SET);
  long n = read(fd, buf, sizeof(buf));
  if (n < 0 || n > (long)sizeof(buf)) {
    write(2, "read size bad\n", 14);
    return 4;
  }
  close(fd);

  write(1, second, sizeof(second) - 1);
  write(1, buf, (unsigned long)n);
  write(1, cleaned, sizeof(cleaned) - 1);
  unlink(name);

  // ---- the path layer (T1.2): a directory, a relative open, the
  // cwd, the listing, a rename, and the clean-up.
  char here[32];
  if (mkdir("dir", 0755) != 0) {
    write(2, "mkdir failed\n", 13);
    return 5;
  }
  fd = open("dir/one.txt", EMO_O_WRONLY | EMO_O_CREAT | EMO_O_TRUNC);
  if (fd < 0) {
    write(2, "dir write failed\n", 17);
    return 6;
  }
  write(fd, first, sizeof(first) - 1);
  close(fd);
  if (chdir("dir") != 0) {
    write(2, "chdir failed\n", 13);
    return 7;
  }
  if (getcwd(here, sizeof(here)) == 0 || !streq(here, "/dir")) {
    write(2, "cwd wrong\n", 10);
    return 8;
  }
  fd = open("one.txt", EMO_O_RDONLY);
  if (fd < 0) {
    write(2, "relative open failed\n", 21);
    return 9;
  }
  n = read(fd, buf, sizeof(buf));
  close(fd);
  write(1, path_ok, sizeof(path_ok) - 1);
  if (chdir("..") != 0) {
    write(2, "chdir back failed\n", 18);
    return 10;
  }
  EMO_DIR *d = opendir("dir");
  struct emo_dirent *e = d == 0 ? 0 : readdir(d);
  if (e == 0 || !streq(e->name, "one.txt")) {
    write(2, dir_bad, sizeof(dir_bad) - 1);
    return 11;
  }
  closedir(d);
  write(1, dir_ok, sizeof(dir_ok) - 1);
  if (rename("dir/one.txt", "dir/two.txt") != 0) {
    write(2, "rename failed\n", 14);
    return 12;
  }
  if (stat("dir/two.txt", &st) != 0 || st.is_dir ||
      st.size != (long)(sizeof(first) - 1)) {
    write(2, "rename stat failed\n", 19);
    return 13;
  }
  write(1, rename_ok, sizeof(rename_ok) - 1);
  if (unlink("dir/two.txt") != 0 || rmdir("dir") != 0) {
    write(2, "vfs clean failed\n", 17);
    return 14;
  }
  write(1, vfs_clean, sizeof(vfs_clean) - 1);

  // ---- the arena (T1.3): brk/sbrk and an anonymous mmap.
  if ((long)sbrk(0) <= 0) {
    write(2, "brk failed\n", 11);
    return 15;
  }
  void *hp = malloc(1000);
  if (hp == 0) {
    write(2, "malloc failed\n", 14);
    return 16;
  }
  ((char *)hp)[0] = 'M';
  ((char *)hp)[999] = 'S';
  void *mp = mmap(0, 4096, 0, 0, -1, 0);
  if ((long)mp < 0) {
    write(2, "mmap failed\n", 12);
    return 17;
  }
  ((char *)mp)[0] = 'Q';
  write(1, heap_ok, sizeof(heap_ok) - 1);
  write(1, mmap_ok, sizeof(mmap_ok) - 1);
  free(hp);
  munmap(mp, 4096);
  void *hp2 = malloc(1000);
  void *mp2 = mmap(0, 4096, 0, 0, -1, 0);
  if (hp2 != hp || mp2 != mp) {
    write(2, "reuse failed\n", 13);
    return 18;
  }
  write(1, reuse_ok, sizeof(reuse_ok) - 1);
  write(1, mmap_reuse_ok, sizeof(mmap_reuse_ok) - 1);
  free(hp2);
  munmap(mp2, 4096);

  // ---- the arena's growth (T1.3v): a block past the 1 MiB run.
  void *big = malloc(3 * 1024 * 1024);
  if (big == 0) {
    write(2, "grow failed\n", 12);
    return 19;
  }
  ((char *)big)[0] = 'G';
  ((char *)big)[3 * 1024 * 1024 - 1] = 'R';
  write(1, grow_ok, sizeof(grow_ok) - 1);
  free(big);

  // ---- argv (T1.4a): the line's words on the first stack.
  if (argc >= 3 && streq(argv[1], "hello") && streq(argv[2], "world")) {
    write(1, args_ok, sizeof(args_ok) - 1);
  } else {
    write(1, args_none, sizeof(args_none) - 1);
  }

  // ---- the process and environment (T1.4b1).
  long pid = getpid();
  if (pid <= 0) {
    write(2, "pid failed\n", 11);
    return 20;
  }
  if (setpgid(0, 0) != 0 || getpgid(0) != pid) {
    write(2, "pgid failed\n", 12);
    return 21;
  }
  if (setenv("EMO", "yes", 1) != 0 || getenv("EMO") == 0 ||
      !streq(getenv("EMO"), "yes")) {
    write(2, "setenv failed\n", 14);
    return 22;
  }
  unsetenv("EMO");
  if (getenv("EMO") != 0) {
    write(2, "unsetenv failed\n", 16);
    return 23;
  }
  write(1, proc_ok, sizeof(proc_ok) - 1);
  write(1, env_ok, sizeof(env_ok) - 1);

  // ---- fork and wait (T1.4b2): the child's copy of the world.
  long fp = fork();
  if (fp == 0) {
    _exit(42);
  }
  if (fp < 0) {
    write(2, "fork failed\n", 12);
    return 24;
  }
  int fst = 0;
  long fw = waitpid(fp, &fst, 0);
  if (fw != fp || !EMO_WIFEXITED(fst) || EMO_WEXITSTATUS(fst) != 42) {
    write(2, "fork wait failed\n", 17);
    return 25;
  }
  write(1, fork_ok, sizeof(fork_ok) - 1);

  long fp2 = fork();
  if (fp2 == 0) {
    _exit(7);
  }
  if (fp2 < 0) {
    write(2, "fork2 failed\n", 13);
    return 26;
  }
  int fst2 = 0;
  long fw2 = waitpid(-1, &fst2, 0);
  if (fw2 != fp2 || !EMO_WIFEXITED(fst2) || EMO_WEXITSTATUS(fst2) != 7) {
    write(2, "any wait failed\n", 16);
    return 27;
  }
  write(1, wait_ok, sizeof(wait_ok) - 1);

  // ---- fd inheritance (T1.4b3a): the child reopens the name.
  int ffd = open("forkfd.txt", EMO_O_RDWR | EMO_O_CREAT | EMO_O_TRUNC);
  if (ffd < 0) {
    write(2, "fd fork open failed\n", 20);
    return 28;
  }
  write(ffd, fdfork_msg, sizeof(fdfork_msg) - 1);
  lseek(ffd, 0, EMO_SEEK_SET);
  long fdp = fork();
  if (fdp == 0) {
    char b[5];
    long got = read(ffd, b, 5);
    int good = got == 5 && b[0] == 'f' && b[1] == 'o' && b[2] == 'r' &&
               b[3] == 'k' && b[4] == ' ';
    close(ffd);
    _exit(good ? 0 : 1);
  }
  if (fdp < 0) {
    write(2, "fd fork failed\n", 15);
    return 29;
  }
  int fst3 = 0;
  long fdw = waitpid(fdp, &fst3, 0);
  close(ffd);
  unlink("forkfd.txt");
  if (fdw != fdp || !EMO_WIFEXITED(fst3) || EMO_WEXITSTATUS(fst3) != 0) {
    write(2, "fd fork wait failed\n", 20);
    return 30;
  }
  write(1, fdfork_ok, sizeof(fdfork_ok) - 1);

  // ---- execve (T1.4b3b): the child's own image is replaced.
  long ep = fork();
  if (ep == 0) {
    char pidbuf[24];
    fmt_dec(pidbuf, getpid());
    char *av[4];
    av[0] = "chello.elf";
    av[1] = "execchild";
    av[2] = pidbuf;
    av[3] = 0;
    char *ev[2];
    ev[0] = "EMO_EXEC=1";
    ev[1] = 0;
    execve("chello.elf", av, ev);
    write(2, "execve failed\n", 14);
    _exit(127);
  }
  if (ep < 0) {
    write(2, "execve fork failed\n", 19);
    return 31;
  }
  int est = 0;
  long ew = waitpid(ep, &est, 0);
  if (ew != ep || !EMO_WIFEXITED(est) || EMO_WEXITSTATUS(est) != 0) {
    write(2, "execve wait failed\n", 19);
    return 32;
  }
  write(1, execve_ok, sizeof(execve_ok) - 1);

  // ---- the pipes (T1.5): a child's write, the parent's read, and the
  // last writer's close for EOF.
  int p[2];
  if (pipe(p) != 0) {
    write(2, "pipe failed\n", 12);
    return 33;
  }
  long pp = fork();
  if (pp == 0) {
    close(p[0]);
    write(p[1], pipe_child_line, sizeof(pipe_child_line) - 1);
    close(p[1]);
    _exit(0);
  }
  if (pp < 0) {
    write(2, "pipe fork failed\n", 17);
    return 34;
  }
  close(p[1]);
  long pn = read(p[0], buf, sizeof(buf));
  int pmatch = pn == (long)(sizeof(pipe_child_line) - 1);
  long pi = 0;
  while (pmatch && pi < pn) {
    if (buf[pi] != pipe_child_line[pi]) {
      pmatch = 0;
    }
    pi = pi + 1;
  }
  long peof = read(p[0], buf, sizeof(buf));
  close(p[0]);
  int pst = 0;
  long pw = waitpid(pp, &pst, 0);
  if (!pmatch || peof != 0 || pw != pp || !EMO_WIFEXITED(pst) ||
      EMO_WEXITSTATUS(pst) != 0) {
    write(2, pipe_bad, sizeof(pipe_bad) - 1);
    return 35;
  }
  write(1, pipe_ok, sizeof(pipe_ok) - 1);

  // ---- dup2: the console saved, the pipe's write end onto fd 1, the
  // line into the pipe, then the console back.
  int q[2];
  if (pipe(q) != 0) {
    write(2, pipe_dup_bad, sizeof(pipe_dup_bad) - 1);
    return 36;
  }
  int saved = dup(1);
  if (saved < 0) {
    write(2, pipe_dup_bad, sizeof(pipe_dup_bad) - 1);
    return 37;
  }
  if (dup2(q[1], 1) != 1) {
    write(2, pipe_dup_bad, sizeof(pipe_dup_bad) - 1);
    return 38;
  }
  write(1, pipe_dup_line, sizeof(pipe_dup_line) - 1);
  if (dup2(saved, 1) != 1) {
    write(2, pipe_dup_bad, sizeof(pipe_dup_bad) - 1);
    return 39;
  }
  close(saved);
  write(1, pipe_dup_ok, sizeof(pipe_dup_ok) - 1);
  close(q[1]);
  long qn = read(q[0], buf, sizeof(buf));
  int qmatch = qn == (long)(sizeof(pipe_dup_line) - 1);
  long qi = 0;
  while (qmatch && qi < qn) {
    if (buf[qi] != pipe_dup_line[qi]) {
      qmatch = 0;
    }
    qi = qi + 1;
  }
  close(q[0]);
  if (!qmatch) {
    write(2, pipe_dup_bad, sizeof(pipe_dup_bad) - 1);
    return 39;
  }

  // ---- the pipeline's route (T1.5): the child's fd 1 into a pipe,
  // then its image replaced — the low end survives the exec.
  int x[2];
  if (pipe(x) != 0) {
    write(2, pipe_exec_bad, sizeof(pipe_exec_bad) - 1);
    return 40;
  }
  long xp = fork();
  if (xp == 0) {
    close(x[0]);
    dup2(x[1], 1);
    close(x[1]);
    char *xav[3];
    xav[0] = "chello.elf";
    xav[1] = "pipechild";
    xav[2] = 0;
    execve("chello.elf", xav, 0);
    _exit(127);
  }
  if (xp < 0) {
    write(2, pipe_exec_bad, sizeof(pipe_exec_bad) - 1);
    return 41;
  }
  close(x[1]);
  long xtot = 0;
  long xr = 0;
  while ((xr = read(x[0], buf, sizeof(buf))) > 0) {
    xtot = xtot + xr;
    if (xtot > 4096) {
      break;
    }
  }
  close(x[0]);
  int xst = 0;
  long xw = waitpid(xp, &xst, 0);
  if (xtot != (long)(sizeof(pipe_greet) - 1) || xr < 0 || xw != xp ||
      !EMO_WIFEXITED(xst) || EMO_WEXITSTATUS(xst) != 0) {
    write(2, pipe_exec_bad, sizeof(pipe_exec_bad) - 1);
    return 42;
  }
  write(1, pipe_exec_ok, sizeof(pipe_exec_ok) - 1);

  // ---- a transfer past the ring: the writer blocks, the reader
  // drains, and both ends keep their order.
  int z[2];
  if (pipe(z) != 0) {
    write(2, pipe_big_bad, sizeof(pipe_big_bad) - 1);
    return 43;
  }
  long zp = fork();
  if (zp == 0) {
    close(z[0]);
    char blk[200];
    long sent = 0;
    while (sent < 2000) {
      long lim = 2000 - sent;
      if (lim > (long)sizeof(blk)) {
        lim = (long)sizeof(blk);
      }
      int bi = 0;
      while ((long)bi < lim) {
        blk[bi] = (char)('a' + ((sent + bi) % 26));
        bi = bi + 1;
      }
      long w = write(z[1], blk, (unsigned long)lim);
      if (w <= 0) {
        break;
      }
      sent = sent + w;
    }
    close(z[1]);
    _exit(sent == 2000 ? 0 : 1);
  }
  if (zp < 0) {
    write(2, pipe_big_bad, sizeof(pipe_big_bad) - 1);
    return 44;
  }
  close(z[1]);
  long ztot = 0;
  int zgood = 1;
  long zr = 0;
  while ((zr = read(z[0], buf, sizeof(buf))) > 0) {
    long zi = 0;
    while (zi < zr) {
      if (buf[zi] != (char)('a' + ((ztot + zi) % 26))) {
        zgood = 0;
      }
      zi = zi + 1;
    }
    ztot = ztot + zr;
  }
  close(z[0]);
  int zst = 0;
  long zw = waitpid(zp, &zst, 0);
  if (ztot != 2000 || !zgood || zr != 0 || zw != zp ||
      !EMO_WIFEXITED(zst) || EMO_WEXITSTATUS(zst) != 0) {
    write(2, pipe_big_bad, sizeof(pipe_big_bad) - 1);
    return 45;
  }
  write(1, pipe_big_ok, sizeof(pipe_big_ok) - 1);

  // ---- the broken pipe (T1.5): the last reader's close is the
  // writer's EPIPE.
  int w[2];
  if (pipe(w) != 0) {
    write(2, pipe_epipe_bad, sizeof(pipe_epipe_bad) - 1);
    return 46;
  }
  close(w[0]);
  unsigned long pset = 1UL << (EMO_SIGPIPE - 1);
  if (sigprocmask(EMO_SIG_BLOCK, &pset, 0) != 0) {
    write(2, pipe_epipe_bad, sizeof(pipe_epipe_bad) - 1);
    return 46;
  }
  errno = 0;
  long wp = write(w[1], pipe_dup_line, sizeof(pipe_dup_line) - 1);
  int we = errno;
  close(w[1]);
  int ppend = (sigpending() & pset) != 0;
  if (signal(EMO_SIGPIPE, EMO_SIG_IGN) == EMO_SIG_ERR ||
      sigprocmask(EMO_SIG_UNBLOCK, &pset, 0) != 0) {
    write(2, pipe_epipe_bad, sizeof(pipe_epipe_bad) - 1);
    return 47;
  }
  int pcleared = (sigpending() & pset) == 0;
  if (wp != -1 || we != EMO_EPIPE || !ppend || !pcleared) {
    write(2, pipe_epipe_bad, sizeof(pipe_epipe_bad) - 1);
    return 48;
  }
  write(1, pipe_epipe_ok, sizeof(pipe_epipe_ok) - 1);

  // ---- the signals (T1.6): a handler run at the raise's own resume,
  // a disposition ignored, SIGKILL refused, and the blocked mask.
  sig_seen = 0;
  if (signal(EMO_SIGUSR1, on_usr1) == EMO_SIG_ERR) {
    write(2, sig_bad, sizeof(sig_bad) - 1);
    return 49;
  }
  if (raise(EMO_SIGUSR1) != 0 || sig_seen != EMO_SIGUSR1) {
    write(2, sig_bad, sizeof(sig_bad) - 1);
    return 50;
  }
  if (signal(EMO_SIGTERM, EMO_SIG_IGN) == EMO_SIG_ERR) {
    write(2, sig_bad, sizeof(sig_bad) - 1);
    return 51;
  }
  if (raise(EMO_SIGTERM) != 0) {
    write(2, sig_bad, sizeof(sig_bad) - 1);
    return 52;
  }
  if (signal(EMO_SIGKILL, on_usr1) != EMO_SIG_ERR) {
    write(2, sig_bad, sizeof(sig_bad) - 1);
    return 53;
  }
  write(1, sig_ok, sizeof(sig_ok) - 1);

  unsigned long uset = 1UL << (EMO_SIGUSR1 - 1);
  unsigned long oldmask = 0;
  sig_seen = 0;
  if (signal(EMO_SIGUSR1, on_usr1) == EMO_SIG_ERR) {
    write(2, sig_mask_bad, sizeof(sig_mask_bad) - 1);
    return 54;
  }
  if (sigprocmask(EMO_SIG_BLOCK, &uset, &oldmask) != 0) {
    write(2, sig_mask_bad, sizeof(sig_mask_bad) - 1);
    return 55;
  }
  if (raise(EMO_SIGUSR1) != 0 || sig_seen != 0) {
    write(2, sig_mask_bad, sizeof(sig_mask_bad) - 1);
    return 56;
  }
  if ((sigpending() & uset) == 0) {
    write(2, sig_mask_bad, sizeof(sig_mask_bad) - 1);
    return 57;
  }
  if (sigprocmask(EMO_SIG_UNBLOCK, &uset, 0) != 0) {
    write(2, sig_mask_bad, sizeof(sig_mask_bad) - 1);
    return 58;
  }
  if (sig_seen != EMO_SIGUSR1) {
    write(2, sig_mask_bad, sizeof(sig_mask_bad) - 1);
    return 59;
  }
  write(1, sig_mask_ok, sizeof(sig_mask_ok) - 1);

  // ---- a signal's default death (T1.6): the child raises SIGTERM on
  // itself and the parent's wait reads the signal, not an exit code.
  sig_chld_seen = 0;
  if (signal(EMO_SIGCHLD, on_chld) == EMO_SIG_ERR) {
    write(2, sig_kill_bad, sizeof(sig_kill_bad) - 1);
    return 60;
  }
  long kp = fork();
  if (kp == 0) {
    signal(EMO_SIGTERM, EMO_SIG_DFL);
    raise(EMO_SIGTERM);
    _exit(0);
  }
  if (kp < 0) {
    write(2, sig_kill_bad, sizeof(sig_kill_bad) - 1);
    return 61;
  }
  int kst = 0;
  long kw = waitpid(kp, &kst, 0);
  if (kw != kp || !EMO_WIFSIGNALED(kst) || EMO_WTERMSIG(kst) != EMO_SIGTERM) {
    write(2, sig_kill_bad, sizeof(sig_kill_bad) - 1);
    return 62;
  }
  if (sig_chld_seen != EMO_SIGCHLD) {
    write(2, sig_kill_bad, sizeof(sig_kill_bad) - 1);
    return 63;
  }
  write(1, sig_kill_ok, sizeof(sig_kill_ok) - 1);
  return 0;
}
