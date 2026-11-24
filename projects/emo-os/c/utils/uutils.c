/* The first core-utilities corpus (EmoOS M4, T4.2): one static
 * binary, applets selected by argv[1], built through the musl sysroot.
 * The file, text and process families are represented:
 *
 *   cat ls wc grep cp mv rm echo pid sleep kill true false
 *
 * `uutils.elf selftest` is the metal acceptance: it drives the applets
 * over the volume and prints the pinned lines the golden checks.
 */

#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static char io_buf[1024];

static int copy_file(const char *src, const char *dst) {
  int in = open(src, O_RDONLY);
  if (in < 0) {
    return -1;
  }
  int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC);
  if (out < 0) {
    close(in);
    return -1;
  }
  long n;
  while ((n = read(in, io_buf, sizeof io_buf)) > 0) {
    long done = 0;
    while (done < n) {
      long w = write(out, io_buf + done, (unsigned long)(n - done));
      if (w <= 0) {
        close(in);
        close(out);
        return -1;
      }
      done = done + w;
    }
  }
  close(in);
  close(out);
  return n < 0 ? -1 : 0;
}

static int app_cat(int argc, char **argv) {
  if (argc < 2) {
    return 1;
  }
  int i;
  for (i = 1; i < argc; i++) {
    int fd = open(argv[i], O_RDONLY);
    if (fd < 0) {
      printf("cat: %s: miss\n", argv[i]);
      return 1;
    }
    long n;
    while ((n = read(fd, io_buf, sizeof io_buf)) > 0) {
      write(1, io_buf, (unsigned long)n);
    }
    close(fd);
  }
  return 0;
}

static int app_ls(int argc, char **argv) {
  const char *path = argc > 1 ? argv[1] : ".";
  DIR *d = opendir(path);
  if (d == 0) {
    printf("ls: %s: miss\n", path);
    return 1;
  }
  struct dirent *e;
  while ((e = readdir(d)) != 0) {
    printf("%s\n", e->d_name);
  }
  closedir(d);
  return 0;
}

static int app_wc(int argc, char **argv) {
  if (argc < 2) {
    return 1;
  }
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) {
    printf("wc: %s: miss\n", argv[1]);
    return 1;
  }
  long lines = 0;
  long words = 0;
  long bytes = 0;
  int in_word = 0;
  long n;
  while ((n = read(fd, io_buf, sizeof io_buf)) > 0) {
    long i;
    for (i = 0; i < n; i++) {
      unsigned char c = (unsigned char)io_buf[i];
      bytes = bytes + 1;
      if (c == '\n') {
        lines = lines + 1;
      }
      if (c == ' ' || c == '\t' || c == '\n') {
        in_word = 0;
      } else {
        if (!in_word) {
          words = words + 1;
          in_word = 1;
        }
      }
    }
  }
  close(fd);
  printf("%ld %ld %ld %s\n", lines, words, bytes, argv[1]);
  return 0;
}

static int app_grep(int argc, char **argv) {
  if (argc < 3) {
    return 1;
  }
  int fd = open(argv[2], O_RDONLY);
  if (fd < 0) {
    printf("grep: %s: miss\n", argv[2]);
    return 1;
  }
  long used = 0;
  long n;
  while ((n = read(fd, io_buf + used, (unsigned long)(sizeof io_buf - 1 - used))) >
         0) {
    used = used + n;
    long start = 0;
    long i;
    for (i = 0; i < used; i++) {
      if (io_buf[i] == '\n') {
        io_buf[i] = 0;
        if (strstr(io_buf + start, argv[1]) != 0) {
          printf("%s\n", io_buf + start);
        }
        start = i + 1;
      }
    }
    used = used - start;
    if (used > 0) {
      memmove(io_buf, io_buf + start, (unsigned long)used);
    }
  }
  close(fd);
  return 0;
}

static int app_cp(int argc, char **argv) {
  if (argc < 3) {
    return 1;
  }
  if (copy_file(argv[1], argv[2]) != 0) {
    printf("cp: %s: miss\n", argv[1]);
    return 1;
  }
  return 0;
}

static int app_mv(int argc, char **argv) {
  if (argc < 3) {
    return 1;
  }
  if (rename(argv[1], argv[2]) != 0) {
    printf("mv: %s: miss\n", argv[1]);
    return 1;
  }
  return 0;
}

static int app_rm(int argc, char **argv) {
  if (argc < 2) {
    return 1;
  }
  if (unlink(argv[1]) != 0) {
    printf("rm: %s: miss\n", argv[1]);
    return 1;
  }
  return 0;
}

static int app_echo(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; i++) {
    if (i > 1) {
      printf(" ");
    }
    printf("%s", argv[i]);
  }
  printf("\n");
  return 0;
}

static int app_pid(int argc, char **argv) {
  (void)argc;
  (void)argv;
  printf("%d\n", (int)getpid());
  return 0;
}

static int app_sleep(int argc, char **argv) {
  long want = argc > 1 ? (long)atoi(argv[1]) : 1;
  struct timespec start;
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
    return 1;
  }
  do {
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
      return 1;
    }
  } while (now.tv_sec - start.tv_sec < want);
  return 0;
}

static int app_kill(int argc, char **argv) {
  if (argc < 3) {
    return 1;
  }
  int r = kill((pid_t)atoi(argv[1]), atoi(argv[2]));
  printf("%s\n", r == 0 ? "ok" : "miss");
  return r == 0 ? 0 : 1;
}

static int app_true(int argc, char **argv) {
  (void)argc;
  (void)argv;
  return 0;
}

static int app_false(int argc, char **argv) {
  (void)argc;
  (void)argv;
  return 1;
}

static int selftest(void) {
  printf("utils selftest\n");

  int fd = open("u.txt", O_WRONLY | O_CREAT | O_TRUNC);
  if (fd < 0) {
    printf("utils fail open\n");
    return 1;
  }
  write(fd, "alpha\n", 6);
  close(fd);

  fd = open("u.txt", O_RDONLY);
  if (fd < 0) {
    printf("utils fail cat\n");
    return 1;
  }
  long n = read(fd, io_buf, sizeof io_buf - 1);
  close(fd);
  if (n < 0) {
    printf("utils fail cat\n");
    return 1;
  }
  io_buf[n] = 0;
  printf("cat: %s", io_buf);

  printf("wc: ");
  app_wc(2, (char *[]){"wc", "u.txt", 0});
  printf("grep: ");
  app_grep(3, (char *[]){"grep", "alpha", "u.txt", 0});

  if (copy_file("u.txt", "v.txt") != 0) {
    printf("utils fail cp\n");
    return 1;
  }
  printf("cp: ok\n");
  if (rename("v.txt", "w.txt") != 0) {
    printf("utils fail mv\n");
    return 1;
  }
  printf("mv: ok\n");
  if (unlink("w.txt") != 0) {
    printf("utils fail rm\n");
    return 1;
  }
  printf("rm: ok\n");

  int found = 0;
  DIR *d = opendir(".");
  if (d != 0) {
    struct dirent *e;
    while ((e = readdir(d)) != 0) {
      if (strcmp(e->d_name, "u.txt") == 0) {
        found = 1;
      }
    }
    closedir(d);
  }
  printf("ls: %s\n", found ? "ok" : "miss");

  printf("pid: %s\n", getpid() > 0 ? "ok" : "miss");

  app_sleep(2, (char *[]){"sleep", "1", 0});
  printf("sleep: ok\n");

  printf("kill: ");
  app_kill(3, (char *[]){"kill", "99999", "0", 0});

  unlink("u.txt");
  printf("utils ok\n");
  return 0;
}

int main(int argc, char **argv) {
  const char *name = argv[0];
  const char *slash = strrchr(name, '/');
  if (slash != 0) {
    name = slash + 1;
  }
  if (argc > 1) {
    name = argv[1];
    argc = argc - 1;
    argv = argv + 1;
  }
  if (strcmp(name, "cat") == 0) return app_cat(argc, argv);
  if (strcmp(name, "ls") == 0) return app_ls(argc, argv);
  if (strcmp(name, "wc") == 0) return app_wc(argc, argv);
  if (strcmp(name, "grep") == 0) return app_grep(argc, argv);
  if (strcmp(name, "cp") == 0) return app_cp(argc, argv);
  if (strcmp(name, "mv") == 0) return app_mv(argc, argv);
  if (strcmp(name, "rm") == 0) return app_rm(argc, argv);
  if (strcmp(name, "echo") == 0) return app_echo(argc, argv);
  if (strcmp(name, "pid") == 0) return app_pid(argc, argv);
  if (strcmp(name, "sleep") == 0) return app_sleep(argc, argv);
  if (strcmp(name, "kill") == 0) return app_kill(argc, argv);
  if (strcmp(name, "true") == 0) return app_true(argc, argv);
  if (strcmp(name, "false") == 0) return app_false(argc, argv);
  if (strcmp(name, "selftest") == 0) return selftest();
  printf("uutils: %s: unknown applet\n", name);
  return 1;
}
