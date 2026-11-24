// The T1 C door's types the bridge needs (T3.1): `EMO_DIR` and its
// `struct emo_dirent` layout, and the renamed directory functions. The
// T1 header's POSIX prototypes would collide with musl's; this slice
// carries only what the wrapper must cast to.

#ifndef EMO_T1_H
#define EMO_T1_H

#define EMO_T1_PATH_MAX 24
#define EMO_T1_DIR_LIST 2048

typedef struct emo_DIR {
  int used;
  long index;
  long total;
  char path[EMO_T1_PATH_MAX + 1];
  char names[EMO_T1_DIR_LIST];
} EMO_DIR;

struct emo_dirent {
  char name[EMO_T1_PATH_MAX + 1];
};

EMO_DIR *emo_t1_opendir(const char *path);
struct emo_dirent *emo_t1_readdir(EMO_DIR *d);
int emo_t1_closedir(EMO_DIR *d);

// The T1 stat's three words (emo_posix.h's `struct emo_stat`): the
// bridge translates them into musl's `struct stat` for the ported
// programs (T4.1).
struct emo_t1_stat {
  long size;
  int flags;
  int is_dir;
};

int emo_t1_stat(const char *path, struct emo_t1_stat *st);
int emo_t1_fstat(int fd, struct emo_t1_stat *st);

// The first free T1 descriptor at or above `floor`; the bridge's
// `F_DUPFD` asks it before `dup2` moves a descriptor (T4.1).
int emo_t1_fd_free_above(int floor);

#endif
