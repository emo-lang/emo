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
  return 0;
}
