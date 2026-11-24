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

#endif
