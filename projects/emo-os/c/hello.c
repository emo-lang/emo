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

int main(void) {
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
  return 0;
}
