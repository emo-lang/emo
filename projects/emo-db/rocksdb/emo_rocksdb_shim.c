/* The C glue of the rocksdb package: one exact-ABI wrapper per
   operation over RocksDB's official C API. Handles cross as
   pointer-sized int64_t — an open database, a column family, a write
   batch, an iterator, and a snapshot bundle. Every RocksDB status
   string is copied into the shim's own last-error buffer and freed
   with rocksdb_free before the call returns, so no C numeral or
   RocksDB-owned pointer leaks into Emo.

   Keys and values cross as emo_bytes_view (the C ABI's borrowed view,
   emo-db D10): `data` is the Bytes cell's inline storage and `len`
   its length. An input view is valid for the duration of the call and
   is never retained; an out-parameter view is written through by the
   callee up to `len` bytes.

   The build compiles this file with -I .emo-build, and emo_defs.h is
   the compiler's own declaration of every `foreign def` in the
   package: a signature that drifts from internal/ffi.emo breaks here
   at cc time, in both directions. RocksDB itself arrives through the
   manifest's `pkg_config` field — its cflags carry the include path,
   its libs carry -lrocksdb.

   The scheduler's cooperative model means every call here serializes:
   no lock lives in this shim. The lock manager that arbitrates
   write-write conflicts is the database's own (M32), not this file's. */

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <rocksdb/c.h>

#include "emo_defs.h"

/* ---- the last error ----

   A RocksDB call reports through a char** errptr whose string belongs
   to the caller (rocksdb_free). The shim copies the message into this
   one buffer; the facade reads it immediately after a failure and
   turns it into "rocksdb: <op>: <message>". Calls are serialized by
   the cooperative scheduler, so one buffer is honest — and the
   package keeps a single database per process anyway. */
static char *emo_rdb_last_error = NULL;

static void emo_rdb_set_error(const char *message) {
  free(emo_rdb_last_error);
  emo_rdb_last_error = NULL;
  if (message == NULL) {
    return;
  }
  size_t n = strlen(message);
  char *copy = malloc(n + 1);
  if (copy == NULL) {
    return;
  }
  memcpy(copy, message, n + 1);
  emo_rdb_last_error = copy;
}

const char *emo_rocksdb_last_error(void) {
  return emo_rdb_last_error != NULL ? emo_rdb_last_error : "";
}

/* Takes ownership of a RocksDB status string: records it, frees it,
   and answers the caller's failure code. */
static int64_t emo_rdb_error(char *err, int64_t code) {
  emo_rdb_set_error(err != NULL ? err : "unknown RocksDB error");
  if (err != NULL) {
    rocksdb_free(err);
  }
  return code;
}

/* The success-or-error answer of the void-shaped RocksDB calls: a NULL
   status is success (0), anything else is recorded and 1. */
static int64_t emo_rdb_check(char *err) {
  if (err == NULL) {
    return 0;
  }
  emo_rdb_set_error(err);
  rocksdb_free(err);
  return 1;
}

static bool emo_rdb_view_ok(emo_bytes_view view) {
  if (view.len < 0) {
    emo_rdb_set_error("negative byte length");
    return false;
  }
  if (view.len > 0 && view.data == NULL) {
    emo_rdb_set_error("null byte buffer");
    return false;
  }
  return true;
}

/* ---- column family handles ---- */

typedef struct emo_rdb_cf {
  char *name;
  rocksdb_column_family_handle_t *handle;
} emo_rdb_cf;

typedef struct emo_rdb {
  rocksdb_t *db;
  rocksdb_options_t *options; /* the open options, reused by cf_create */
  rocksdb_readoptions_t *read_options;  /* the no-snapshot read path */
  rocksdb_writeoptions_t *write_options; /* the plain write path */
  emo_rdb_cf *cfs;
  int n_cfs;
} emo_rdb;

/* A snapshot bundle: the snapshot and the read options that name it.
   The facade keeps the bundle alive for as long as any iterator made
   from it lives; the read options are reused by every such iterator
   and by every read at the snapshot. */
typedef struct emo_rdb_snapshot {
  const rocksdb_snapshot_t *snapshot;
  rocksdb_readoptions_t *read_options;
} emo_rdb_snapshot;

/* The staging a caller fills before open: the FFI crosses scalars, so
   the column family names arrive one cfs_add at a time. */
typedef struct emo_rdb_cfs_stage {
  char **names;
  int n;
  int cap;
} emo_rdb_cfs_stage;

int64_t emo_rocksdb_cfs_new(void) {
  emo_rdb_cfs_stage *stg = calloc(1, sizeof *stg);
  if (stg == NULL) {
    emo_rdb_set_error("out of memory");
    return 0;
  }
  return (int64_t)(intptr_t)stg;
}

int64_t emo_rocksdb_cfs_add(int64_t stage, const char *name) {
  emo_rdb_cfs_stage *stg = (emo_rdb_cfs_stage *)(intptr_t)stage;
  if (stg == NULL || name == NULL) {
    emo_rdb_set_error("invalid column family staging");
    return 1;
  }
  if (stg->n == stg->cap) {
    int cap = stg->cap == 0 ? 4 : stg->cap * 2;
    char **names = realloc(stg->names, (size_t)cap * sizeof *names);
    if (names == NULL) {
      emo_rdb_set_error("out of memory");
      return 1;
    }
    stg->names = names;
    stg->cap = cap;
  }
  size_t n = strlen(name);
  char *copy = malloc(n + 1);
  if (copy == NULL) {
    emo_rdb_set_error("out of memory");
    return 1;
  }
  memcpy(copy, name, n + 1);
  stg->names[stg->n++] = copy;
  return 0;
}

void emo_rocksdb_cfs_free(int64_t stage) {
  emo_rdb_cfs_stage *stg = (emo_rdb_cfs_stage *)(intptr_t)stage;
  if (stg == NULL) {
    return;
  }
  for (int i = 0; i < stg->n; i++) {
    free(stg->names[i]);
  }
  free(stg->names);
  free(stg);
}

static void emo_rdb_free(emo_rdb *db) {
  if (db == NULL) {
    return;
  }
  if (db->cfs != NULL) {
    for (int i = 0; i < db->n_cfs; i++) {
      if (db->cfs[i].handle != NULL) {
        rocksdb_column_family_handle_destroy(db->cfs[i].handle);
      }
      free(db->cfs[i].name);
    }
    free(db->cfs);
  }
  if (db->write_options != NULL) {
    rocksdb_writeoptions_destroy(db->write_options);
  }
  if (db->read_options != NULL) {
    rocksdb_readoptions_destroy(db->read_options);
  }
  if (db->db != NULL) {
    rocksdb_close(db->db);
  }
  if (db->options != NULL) {
    rocksdb_options_destroy(db->options);
  }
  free(db);
}

/* The open path. The names must include "default": RocksDB requires
   every existing column family to be named at open, and the default
   one always exists. */
int64_t emo_rocksdb_open(int64_t stage, const char *path, bool create) {
  emo_rdb_cfs_stage *stg = (emo_rdb_cfs_stage *)(intptr_t)stage;
  if (stg == NULL || path == NULL) {
    emo_rdb_set_error("invalid open arguments");
    return 0;
  }
  bool has_default = false;
  for (int i = 0; i < stg->n; i++) {
    if (strcmp(stg->names[i], "default") == 0) {
      has_default = true;
    }
  }
  if (!has_default) {
    emo_rdb_set_error("open: the column family list must include \"default\"");
    return 0;
  }
  emo_rdb *db = calloc(1, sizeof *db);
  if (db == NULL) {
    emo_rdb_set_error("out of memory");
    return 0;
  }
  db->options = rocksdb_options_create();
  db->read_options = rocksdb_readoptions_create();
  db->write_options = rocksdb_writeoptions_create();
  if (db->options == NULL || db->read_options == NULL ||
      db->write_options == NULL) {
    emo_rdb_set_error("out of memory");
    emo_rdb_free(db);
    return 0;
  }
  rocksdb_options_set_create_if_missing(db->options, create);
  rocksdb_options_set_create_missing_column_families(db->options, create);

  int n = stg->n;
  const char **names = calloc((size_t)n, sizeof *names);
  const rocksdb_options_t **cf_options =
      calloc((size_t)n, sizeof *cf_options);
  rocksdb_column_family_handle_t **handles =
      calloc((size_t)n, sizeof *handles);
  db->cfs = calloc((size_t)n, sizeof *db->cfs);
  if (names == NULL || cf_options == NULL || handles == NULL ||
      db->cfs == NULL) {
    emo_rdb_set_error("out of memory");
    free(names);
    free(cf_options);
    free(handles);
    emo_rdb_free(db);
    return 0;
  }
  for (int i = 0; i < n; i++) {
    names[i] = stg->names[i];
    cf_options[i] = db->options;
  }
  char *err = NULL;
  db->db = rocksdb_open_column_families(
      db->options, path, n, names,
      (const rocksdb_options_t *const *)cf_options, handles, &err);
  free(names);
  free(cf_options);
  if (db->db == NULL) {
    free(handles);
    emo_rdb_error(err, 0);
    emo_rdb_free(db);
    return 0;
  }
  db->n_cfs = n;
  for (int i = 0; i < n; i++) {
    db->cfs[i].handle = handles[i];
    size_t len = strlen(stg->names[i]);
    char *copy = malloc(len + 1);
    if (copy == NULL) {
      free(handles);
      emo_rdb_set_error("out of memory");
      emo_rdb_free(db);
      return 0;
    }
    memcpy(copy, stg->names[i], len + 1);
    db->cfs[i].name = copy;
  }
  free(handles);
  return (int64_t)(intptr_t)db;
}

void emo_rocksdb_close(int64_t handle) {
  emo_rdb_free((emo_rdb *)(intptr_t)handle);
}

static emo_rdb *emo_rdb_of(int64_t handle) {
  emo_rdb *db = (emo_rdb *)(intptr_t)handle;
  if (db == NULL) {
    emo_rdb_set_error("invalid database handle");
  }
  return db;
}

int64_t emo_rocksdb_cf(int64_t handle, const char *name) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || name == NULL) {
    return 0;
  }
  for (int i = 0; i < db->n_cfs; i++) {
    if (strcmp(db->cfs[i].name, name) == 0) {
      return (int64_t)(intptr_t)db->cfs[i].handle;
    }
  }
  emo_rdb_set_error("no such column family");
  return 0;
}

int64_t emo_rocksdb_cf_create(int64_t handle, const char *name) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || name == NULL) {
    return 0;
  }
  char *err = NULL;
  rocksdb_column_family_handle_t *cf =
      rocksdb_create_column_family(db->db, db->options, name, &err);
  if (cf == NULL) {
    return emo_rdb_error(err, 0);
  }
  emo_rdb_cf *grown = realloc(db->cfs, (size_t)(db->n_cfs + 1) * sizeof *grown);
  if (grown == NULL) {
    rocksdb_column_family_handle_destroy(cf);
    emo_rdb_set_error("out of memory");
    return 0;
  }
  db->cfs = grown;
  size_t len = strlen(name);
  char *copy = malloc(len + 1);
  if (copy == NULL) {
    rocksdb_column_family_handle_destroy(cf);
    emo_rdb_set_error("out of memory");
    return 0;
  }
  memcpy(copy, name, len + 1);
  db->cfs[db->n_cfs].name = copy;
  db->cfs[db->n_cfs].handle = cf;
  db->n_cfs++;
  return (int64_t)(intptr_t)cf;
}

int64_t emo_rocksdb_cf_list_count(int64_t handle) {
  emo_rdb *db = emo_rdb_of(handle);
  return db == NULL ? 0 : (int64_t)db->n_cfs;
}

const char *emo_rocksdb_cf_list_name(int64_t handle, int64_t i) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || i < 0 || i >= db->n_cfs) {
    emo_rdb_set_error("column family index out of range");
    return "";
  }
  return db->cfs[i].name;
}

int64_t emo_rocksdb_destroy_db(const char *path) {
  if (path == NULL) {
    emo_rdb_set_error("invalid path");
    return 1;
  }
  struct stat st;
  if (stat(path, &st) != 0 && errno == ENOENT) {
    return 0;
  }
  rocksdb_options_t *options = rocksdb_options_create();
  if (options == NULL) {
    emo_rdb_set_error("out of memory");
    return 1;
  }
  char *err = NULL;
  rocksdb_destroy_db(options, path, &err);
  rocksdb_options_destroy(options);
  if (err != NULL) {
    emo_rdb_error(err, 1);
    return 1;
  }
  return 0;
}

/* ---- the column family list ----

   Opening a database with `rocksdb_open_column_families` requires every
   existing family named. The list handle answers them before any open:
   a path that does not exist is the empty list (the caller is about to
   create it), and a real database answers its names, "default" first in
   RocksDB's own order. */

typedef struct emo_rdb_name_list {
  char **names;
  int n;
} emo_rdb_name_list;

int64_t emo_rocksdb_list_new(const char *path) {
  if (path == NULL) {
    emo_rdb_set_error("invalid path");
    return 0;
  }
  emo_rdb_name_list *list = calloc(1, sizeof *list);
  if (list == NULL) {
    emo_rdb_set_error("out of memory");
    return 0;
  }
  struct stat st;
  if (stat(path, &st) != 0 && errno == ENOENT) {
    return (int64_t)(intptr_t)list;
  }
  rocksdb_options_t *options = rocksdb_options_create();
  if (options == NULL) {
    free(list);
    emo_rdb_set_error("out of memory");
    return 0;
  }
  size_t n = 0;
  char *err = NULL;
  char **names = rocksdb_list_column_families(options, path, &n, &err);
  rocksdb_options_destroy(options);
  if (err != NULL || names == NULL) {
    free(list);
    emo_rdb_error(err, 0);
    return 0;
  }
  list->names = calloc(n == 0 ? 1 : n, sizeof *list->names);
  if (list->names == NULL) {
    rocksdb_list_column_families_destroy(names, n);
    free(list);
    emo_rdb_set_error("out of memory");
    return 0;
  }
  for (size_t i = 0; i < n; i++) {
    size_t len = strlen(names[i]);
    char *copy = malloc(len + 1);
    if (copy == NULL) {
      for (size_t j = 0; j < i; j++) {
        free(list->names[j]);
      }
      free(list->names);
      free(list);
      rocksdb_list_column_families_destroy(names, n);
      emo_rdb_set_error("out of memory");
      return 0;
    }
    memcpy(copy, names[i], len + 1);
    list->names[i] = copy;
  }
  list->n = (int)n;
  rocksdb_list_column_families_destroy(names, n);
  return (int64_t)(intptr_t)list;
}

int64_t emo_rocksdb_list_count(int64_t handle) {
  emo_rdb_name_list *list = (emo_rdb_name_list *)(intptr_t)handle;
  return list == NULL ? 0 : (int64_t)list->n;
}

const char *emo_rocksdb_list_name(int64_t handle, int64_t i) {
  emo_rdb_name_list *list = (emo_rdb_name_list *)(intptr_t)handle;
  if (list == NULL || i < 0 || i >= list->n) {
    emo_rdb_set_error("column family list index out of range");
    return "";
  }
  return list->names[i];
}

void emo_rocksdb_list_free(int64_t handle) {
  emo_rdb_name_list *list = (emo_rdb_name_list *)(intptr_t)handle;
  if (list == NULL) {
    return;
  }
  for (int i = 0; i < list->n; i++) {
    free(list->names[i]);
  }
  free(list->names);
  free(list);
}

/* ---- reads and writes ---- */

/* The read options naming the snapshot (0 = the latest state). */
static rocksdb_readoptions_t *emo_rdb_read_options(emo_rdb *db, int64_t snap) {
  if (snap != 0) {
    return ((emo_rdb_snapshot *)(intptr_t)snap)->read_options;
  }
  return db->read_options;
}

int64_t emo_rocksdb_put(int64_t handle, int64_t cf, emo_bytes_view key,
                        emo_bytes_view value) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || cf == 0) {
    return 1;
  }
  if (!emo_rdb_view_ok(key) || !emo_rdb_view_ok(value)) {
    return 1;
  }
  char *err = NULL;
  rocksdb_put_cf(db->db, db->write_options,
                 (rocksdb_column_family_handle_t *)(intptr_t)cf,
                 (const char *)key.data, (size_t)key.len,
                 (const char *)value.data, (size_t)value.len, &err);
  return emo_rdb_check(err);
}

/* The length half of a read: one real get, freed here, answering the
   value's length, -1 for a missing key, and -2 for a failure. The
   facade then allocates that exact Bytes and calls get_into — the two
   calls repeat the lookup, which the block cache makes cheap and
   which keeps the shim free of a pinned result slot. */
int64_t emo_rocksdb_get_len(int64_t handle, int64_t cf, emo_bytes_view key,
                            int64_t snap) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || cf == 0) {
    return -2;
  }
  if (!emo_rdb_view_ok(key)) {
    return -2;
  }
  char *err = NULL;
  size_t vlen = 0;
  char *value = rocksdb_get_cf(
      db->db, emo_rdb_read_options(db, snap),
      (rocksdb_column_family_handle_t *)(intptr_t)cf, (const char *)key.data,
      (size_t)key.len, &vlen, &err);
  if (err != NULL) {
    return emo_rdb_error(err, -2);
  }
  if (value == NULL) {
    return -1;
  }
  rocksdb_free(value);
  return (int64_t)vlen;
}

int64_t emo_rocksdb_get_into(int64_t handle, int64_t cf, emo_bytes_view key,
                             emo_bytes_view out, int64_t snap) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || cf == 0) {
    return -2;
  }
  if (!emo_rdb_view_ok(key) || !emo_rdb_view_ok(out)) {
    return -2;
  }
  char *err = NULL;
  size_t vlen = 0;
  char *value = rocksdb_get_cf(
      db->db, emo_rdb_read_options(db, snap),
      (rocksdb_column_family_handle_t *)(intptr_t)cf, (const char *)key.data,
      (size_t)key.len, &vlen, &err);
  if (err != NULL) {
    return emo_rdb_error(err, -2);
  }
  if (value == NULL) {
    return -1;
  }
  if ((int64_t)vlen > out.len) {
    rocksdb_free(value);
    char message[64];
    snprintf(message, sizeof message, "buffer too small (need %lld)",
             (long long)vlen);
    emo_rdb_set_error(message);
    return -3;
  }
  if (vlen > 0) {
    memcpy(out.data, value, vlen);
  }
  rocksdb_free(value);
  return (int64_t)vlen;
}

int64_t emo_rocksdb_delete(int64_t handle, int64_t cf, emo_bytes_view key) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || cf == 0) {
    return 1;
  }
  if (!emo_rdb_view_ok(key)) {
    return 1;
  }
  char *err = NULL;
  rocksdb_delete_cf(db->db, db->write_options,
                    (rocksdb_column_family_handle_t *)(intptr_t)cf,
                    (const char *)key.data, (size_t)key.len, &err);
  return emo_rdb_check(err);
}

/* ---- write batches ---- */

int64_t emo_rocksdb_batch_new(void) {
  rocksdb_writebatch_t *batch = rocksdb_writebatch_create();
  if (batch == NULL) {
    emo_rdb_set_error("out of memory");
  }
  return (int64_t)(intptr_t)batch;
}

int64_t emo_rocksdb_batch_put(int64_t batch, int64_t cf, emo_bytes_view key,
                              emo_bytes_view value) {
  if (batch == 0 || cf == 0) {
    emo_rdb_set_error("invalid batch handle");
    return 1;
  }
  if (!emo_rdb_view_ok(key) || !emo_rdb_view_ok(value)) {
    return 1;
  }
  rocksdb_writebatch_put_cf(
      (rocksdb_writebatch_t *)(intptr_t)batch,
      (rocksdb_column_family_handle_t *)(intptr_t)cf, (const char *)key.data,
      (size_t)key.len, (const char *)value.data, (size_t)value.len);
  return 0;
}

int64_t emo_rocksdb_batch_delete(int64_t batch, int64_t cf,
                                 emo_bytes_view key) {
  if (batch == 0 || cf == 0) {
    emo_rdb_set_error("invalid batch handle");
    return 1;
  }
  if (!emo_rdb_view_ok(key)) {
    return 1;
  }
  rocksdb_writebatch_delete_cf(
      (rocksdb_writebatch_t *)(intptr_t)batch,
      (rocksdb_column_family_handle_t *)(intptr_t)cf, (const char *)key.data,
      (size_t)key.len);
  return 0;
}

int64_t emo_rocksdb_batch_write(int64_t handle, int64_t batch, bool sync) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || batch == 0) {
    return 1;
  }
  /* COMMIT's durability: the transaction's batch write asks the WAL to
     fsync before it answers; plain writes leave the flag off. Calls are
     serialized by the cooperative scheduler, so one options object is
     enough. */
  rocksdb_writeoptions_set_sync(db->write_options, sync);
  char *err = NULL;
  rocksdb_write(db->db, db->write_options,
                (rocksdb_writebatch_t *)(intptr_t)batch, &err);
  return emo_rdb_check(err);
}

void emo_rocksdb_batch_close(int64_t batch) {
  if (batch != 0) {
    rocksdb_writebatch_destroy((rocksdb_writebatch_t *)(intptr_t)batch);
  }
}

/* ---- iterators ---- */

int64_t emo_rocksdb_snapshot_new(int64_t handle) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL) {
    return 0;
  }
  emo_rdb_snapshot *snap = calloc(1, sizeof *snap);
  if (snap == NULL) {
    emo_rdb_set_error("out of memory");
    return 0;
  }
  snap->snapshot = rocksdb_create_snapshot(db->db);
  snap->read_options = rocksdb_readoptions_create();
  if (snap->snapshot == NULL || snap->read_options == NULL) {
    if (snap->read_options != NULL) {
      rocksdb_readoptions_destroy(snap->read_options);
    }
    free(snap);
    emo_rdb_set_error("out of memory");
    return 0;
  }
  rocksdb_readoptions_set_snapshot(snap->read_options, snap->snapshot);
  return (int64_t)(intptr_t)snap;
}

void emo_rocksdb_snapshot_close(int64_t handle, int64_t snap) {
  emo_rdb *db = emo_rdb_of(handle);
  emo_rdb_snapshot *bundle = (emo_rdb_snapshot *)(intptr_t)snap;
  if (db == NULL || bundle == NULL) {
    return;
  }
  rocksdb_release_snapshot(db->db, bundle->snapshot);
  rocksdb_readoptions_destroy(bundle->read_options);
  free(bundle);
}

/* An iterator's read options come from emo_rdb_read_options: the
   snapshot bundle's when one is named, the database's plain options
   otherwise. */

int64_t emo_rocksdb_iter_new(int64_t handle, int64_t cf, int64_t snap) {
  emo_rdb *db = emo_rdb_of(handle);
  if (db == NULL || cf == 0) {
    return 0;
  }
  rocksdb_iterator_t *it = rocksdb_create_iterator_cf(
      db->db, emo_rdb_read_options(db, snap),
      (rocksdb_column_family_handle_t *)(intptr_t)cf);
  if (it == NULL) {
    emo_rdb_set_error("out of memory");
    return 0;
  }
  return (int64_t)(intptr_t)it;
}

int64_t emo_rocksdb_iter_seek(int64_t iter, emo_bytes_view key) {
  if (iter == 0) {
    emo_rdb_set_error("invalid iterator handle");
    return 1;
  }
  if (!emo_rdb_view_ok(key)) {
    return 1;
  }
  rocksdb_iter_seek((rocksdb_iterator_t *)(intptr_t)iter,
                    (const char *)key.data, (size_t)key.len);
  return 0;
}

void emo_rocksdb_iter_seek_to_first(int64_t iter) {
  if (iter != 0) {
    rocksdb_iter_seek_to_first((rocksdb_iterator_t *)(intptr_t)iter);
  }
}

bool emo_rocksdb_iter_valid(int64_t iter) {
  return iter != 0 && rocksdb_iter_valid((const rocksdb_iterator_t *)(intptr_t)
                                             iter) != 0;
}

void emo_rocksdb_iter_next(int64_t iter) {
  if (iter != 0) {
    rocksdb_iter_next((rocksdb_iterator_t *)(intptr_t)iter);
  }
}

/* Borrowed pointers from RocksDB stay valid until the iterator moves;
   the facade reads the length then copies in the same position. */
static const char *emo_rdb_iter_part(int64_t iter, int64_t *len,
                                     bool want_value) {
  if (iter == 0) {
    emo_rdb_set_error("invalid iterator handle");
    return NULL;
  }
  if (!rocksdb_iter_valid((const rocksdb_iterator_t *)(intptr_t)iter)) {
    emo_rdb_set_error("iterator is not valid");
    return NULL;
  }
  size_t n = 0;
  const char *p =
      want_value
          ? rocksdb_iter_value((const rocksdb_iterator_t *)(intptr_t)iter, &n)
          : rocksdb_iter_key((const rocksdb_iterator_t *)(intptr_t)iter, &n);
  if (p == NULL) {
    emo_rdb_set_error("iterator position has no bytes");
    return NULL;
  }
  *len = (int64_t)n;
  return p;
}

int64_t emo_rocksdb_iter_key_len(int64_t iter) {
  int64_t n = 0;
  if (emo_rdb_iter_part(iter, &n, false) == NULL) {
    return -1;
  }
  return n;
}

int64_t emo_rocksdb_iter_key_into(int64_t iter, emo_bytes_view out) {
  int64_t n = 0;
  const char *p = emo_rdb_iter_part(iter, &n, false);
  if (p == NULL) {
    return -1;
  }
  if (!emo_rdb_view_ok(out)) {
    return -1;
  }
  if (n > out.len) {
    emo_rdb_set_error("buffer too small for the iterator key");
    return -3;
  }
  if (n > 0) {
    memcpy(out.data, p, (size_t)n);
  }
  return n;
}

int64_t emo_rocksdb_iter_value_len(int64_t iter) {
  int64_t n = 0;
  if (emo_rdb_iter_part(iter, &n, true) == NULL) {
    return -1;
  }
  return n;
}

int64_t emo_rocksdb_iter_value_into(int64_t iter, emo_bytes_view out) {
  int64_t n = 0;
  const char *p = emo_rdb_iter_part(iter, &n, true);
  if (p == NULL) {
    return -1;
  }
  if (!emo_rdb_view_ok(out)) {
    return -1;
  }
  if (n > out.len) {
    emo_rdb_set_error("buffer too small for the iterator value");
    return -3;
  }
  if (n > 0) {
    memcpy(out.data, p, (size_t)n);
  }
  return n;
}

void emo_rocksdb_iter_close(int64_t iter) {
  if (iter != 0) {
    rocksdb_iter_destroy((rocksdb_iterator_t *)(intptr_t)iter);
  }
}
