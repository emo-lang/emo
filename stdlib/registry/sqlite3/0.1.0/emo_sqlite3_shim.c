/* The C glue of the sqlite3 package: one exact-ABI wrapper per
   operation, so the FFI boundary never silently disagrees with sqlite's
   headers about `int` vs `int64_t` (sqlite returns `int` almost
   everywhere — the wrapper widens it explicitly). Handles cross as
   pointer-sized int64_t; strings as plain NUL-terminated const char *.

   The build compiles this file with -I .emo-build, and emo_defs.h is the
   compiler's own declaration of every `foreign def` in the package: a
   signature that drifts from internal/ffi.emo breaks here at cc time,
   in both directions. */

#include <stdbool.h>
#include <stdint.h>
#include <sqlite3.h>

#include "emo_defs.h"

/* sqlite3_open reports through the handle even on failure (when it
   could allocate one); errcode/errmsg below read that report. */
int64_t emo_sqlite3_open(const char *path) {
  sqlite3 *db = NULL;
  (void)sqlite3_open(path, &db);
  return (int64_t)(intptr_t)db;
}

int64_t emo_sqlite3_errcode(int64_t db) {
  return (int64_t)sqlite3_errcode((sqlite3 *)(intptr_t)db);
}

const char *emo_sqlite3_errmsg(int64_t db) {
  const char *message = sqlite3_errmsg((sqlite3 *)(intptr_t)db);
  return message != NULL ? message : "unknown error";
}

int64_t emo_sqlite3_exec(int64_t db, const char *sql) {
  return (int64_t)sqlite3_exec((sqlite3 *)(intptr_t)db, sql, NULL, NULL, NULL);
}

int64_t emo_sqlite3_prepare(int64_t db, const char *sql) {
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2((sqlite3 *)(intptr_t)db, sql, -1, &stmt, NULL);
  return rc == SQLITE_OK ? (int64_t)(intptr_t)stmt : (int64_t)0;
}

int64_t emo_sqlite3_step(int64_t stmt) {
  return (int64_t)sqlite3_step((sqlite3_stmt *)(intptr_t)stmt);
}

int64_t emo_sqlite3_bind_int64(int64_t stmt, int64_t i, int64_t v) {
  return (int64_t)sqlite3_bind_int64((sqlite3_stmt *)(intptr_t)stmt, (int)i,
                                     (sqlite3_int64)v);
}

int64_t emo_sqlite3_bind_double(int64_t stmt, int64_t i, double v) {
  return (int64_t)sqlite3_bind_double((sqlite3_stmt *)(intptr_t)stmt, (int)i,
                                      v);
}

int64_t emo_sqlite3_bind_text(int64_t stmt, int64_t i, const char *v) {
  return (int64_t)sqlite3_bind_text((sqlite3_stmt *)(intptr_t)stmt, (int)i, v,
                                    -1, SQLITE_TRANSIENT);
}

int64_t emo_sqlite3_bind_null(int64_t stmt, int64_t i) {
  return (int64_t)sqlite3_bind_null((sqlite3_stmt *)(intptr_t)stmt, (int)i);
}

int64_t emo_sqlite3_column_count(int64_t stmt) {
  return (int64_t)sqlite3_column_count((sqlite3_stmt *)(intptr_t)stmt);
}

const char *emo_sqlite3_column_name(int64_t stmt, int64_t i) {
  const char *name = sqlite3_column_name((sqlite3_stmt *)(intptr_t)stmt, (int)i);
  return name != NULL ? name : "";
}

int64_t emo_sqlite3_column_int64(int64_t stmt, int64_t i) {
  return (int64_t)sqlite3_column_int64((sqlite3_stmt *)(intptr_t)stmt, (int)i);
}

double emo_sqlite3_column_double(int64_t stmt, int64_t i) {
  return sqlite3_column_double((sqlite3_stmt *)(intptr_t)stmt, (int)i);
}

/* A NULL column reads as the empty string; column_is_null tells the two
   apart. */
const char *emo_sqlite3_column_text(int64_t stmt, int64_t i) {
  const unsigned char *text =
      sqlite3_column_text((sqlite3_stmt *)(intptr_t)stmt, (int)i);
  return text != NULL ? (const char *)text : "";
}

bool emo_sqlite3_column_is_null(int64_t stmt, int64_t i) {
  return sqlite3_column_type((sqlite3_stmt *)(intptr_t)stmt, (int)i) ==
         SQLITE_NULL;
}

int64_t emo_sqlite3_reset(int64_t stmt) {
  return (int64_t)sqlite3_reset((sqlite3_stmt *)(intptr_t)stmt);
}

int64_t emo_sqlite3_finalize(int64_t stmt) {
  return (int64_t)sqlite3_finalize((sqlite3_stmt *)(intptr_t)stmt);
}

int64_t emo_sqlite3_close(int64_t db) {
  return (int64_t)sqlite3_close((sqlite3 *)(intptr_t)db);
}

int64_t emo_sqlite3_last_insert_rowid(int64_t db) {
  return (int64_t)sqlite3_last_insert_rowid((sqlite3 *)(intptr_t)db);
}

int64_t emo_sqlite3_changes(int64_t db) {
  return (int64_t)sqlite3_changes((sqlite3 *)(intptr_t)db);
}
