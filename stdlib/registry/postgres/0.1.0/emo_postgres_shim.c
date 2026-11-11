/* The C glue of the postgres package: one exact-ABI wrapper per
   operation over libpq, PostgreSQL's own client library. Handles cross
   as pointer-sized int64_t — a PGconn *, a PGresult *, and the
   parameter staging that lives between exec_begin and exec_fire.
   Status enums never cross raw: CONNECTION_OK becomes 1, and a result
   becomes 2 (rows), 1 (a command), or 0 (a failure), so no C numeral
   leaks into Emo.

   The build compiles this file with -I .emo-build, and emo_defs.h is
   the compiler's own declaration of every `foreign def` in the
   package: a signature that drifts from internal/ffi.emo breaks here
   at cc time, in both directions. libpq itself arrives through the
   manifest's `pkg_config` field — its cflags carry the include path,
   its libs carry -lpq. */

#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libpq-fe.h>

#include "emo_defs.h"

/* ---- the connection ---- */

/* PQconnectdb answers NULL only when memory ran out; a refused
   connection still comes back as a connection whose status reads
   bad, and conn_error carries its report. */
int64_t emo_postgres_connect(const char *info) {
  PGconn *conn = PQconnectdb(info != NULL ? info : "");
  return conn != NULL ? (int64_t)(intptr_t)conn : 0;
}

int64_t emo_postgres_conn_status(int64_t conn) {
  return PQstatus((PGconn *)(intptr_t)conn) == CONNECTION_OK ? 1 : 0;
}

const char *emo_postgres_conn_error(int64_t conn) {
  const char *message = PQerrorMessage((PGconn *)(intptr_t)conn);
  return message != NULL ? message : "";
}

void emo_postgres_conn_close(int64_t conn) {
  PQfinish((PGconn *)(intptr_t)conn);
}

/* ---- the parameter staging ----

   libpq's PQexecParams takes the parameters as one array, and the FFI
   crosses scalars only — so the staging gathers the slots one bind at
   a time and exec_fire hands the finished array over. Every slot must
   be bound (bind_none counts) before the fire: an unbound slot is a
   package bug, and the shim refuses rather than silently sending a
   NULL. */

typedef struct emo_pg_stage {
  int n;
  char **values; /* slot i: the text to send, or NULL for SQL NULL */
  bool *bound;   /* slot i: whether the package named it at all */
} emo_pg_stage;

static void emo_pg_stage_free(emo_pg_stage *stg) {
  if (stg == NULL) {
    return;
  }
  if (stg->values != NULL) {
    for (int i = 0; i < stg->n; i++) {
      free(stg->values[i]);
    }
    free(stg->values);
  }
  free(stg->bound);
  free(stg);
}

int64_t emo_postgres_exec_begin(int64_t conn, const char *sql, int64_t n) {
  (void)conn;
  (void)sql;
  if (n < 0) {
    return 0;
  }
  emo_pg_stage *stg = malloc(sizeof *stg);
  if (stg == NULL) {
    return 0;
  }
  stg->n = (int)n;
  stg->values = NULL;
  stg->bound = NULL;
  if (n > 0) {
    stg->values = calloc((size_t)n, sizeof *stg->values);
    stg->bound = calloc((size_t)n, sizeof *stg->bound);
    if (stg->values == NULL || stg->bound == NULL) {
      emo_pg_stage_free(stg);
      return 0;
    }
  }
  return (int64_t)(intptr_t)stg;
}

/* The slot's 1-based index is in range, or there is nothing to bind
   into and the bind answers 1 for the caller to raise on. */
static bool emo_pg_slot_ok(emo_pg_stage *stg, int64_t i) {
  return stg != NULL && i >= 1 && i <= (int64_t)stg->n;
}

/* Re-binding a slot replaces its text — the staging is the package's
   own, and idempotence here costs one free. */
static int emo_pg_slot_set(emo_pg_stage *stg, int64_t i, char *text) {
  if (!emo_pg_slot_ok(stg, i) || text == NULL) {
    free(text);
    return 1;
  }
  free(stg->values[i - 1]);
  stg->values[i - 1] = text;
  stg->bound[i - 1] = true;
  return 0;
}

int64_t emo_postgres_bind_text(int64_t stg_handle, int64_t i, const char *v) {
  emo_pg_stage *stg = (emo_pg_stage *)(intptr_t)stg_handle;
  if (!emo_pg_slot_ok(stg, i) || v == NULL) {
    return 1;
  }
  char *copy = strdup(v);
  if (copy == NULL) {
    return 1;
  }
  return (int64_t)emo_pg_slot_set(stg, i, copy);
}

int64_t emo_postgres_bind_i64(int64_t stg_handle, int64_t i, int64_t v) {
  emo_pg_stage *stg = (emo_pg_stage *)(intptr_t)stg_handle;
  char buf[32];
  int written = snprintf(buf, sizeof buf, "%" PRId64, v);
  if (written < 0 || (size_t)written >= sizeof buf) {
    return 1;
  }
  char *text = strdup(buf);
  if (text == NULL) {
    return 1;
  }
  return (int64_t)emo_pg_slot_set(stg, i, text);
}

/* %.17g round-trips any binary64; the decimal point stays '.' because
   the process never leaves the C locale. */
int64_t emo_postgres_bind_f64(int64_t stg_handle, int64_t i, double v) {
  emo_pg_stage *stg = (emo_pg_stage *)(intptr_t)stg_handle;
  char buf[64];
  int written = snprintf(buf, sizeof buf, "%.17g", v);
  if (written < 0 || (size_t)written >= sizeof buf) {
    return 1;
  }
  char *text = strdup(buf);
  if (text == NULL) {
    return 1;
  }
  return (int64_t)emo_pg_slot_set(stg, i, text);
}

int64_t emo_postgres_bind_bool(int64_t stg_handle, int64_t i, bool v) {
  emo_pg_stage *stg = (emo_pg_stage *)(intptr_t)stg_handle;
  return (int64_t)emo_pg_slot_set(stg, i, strdup(v ? "true" : "false"));
}

int64_t emo_postgres_bind_none(int64_t stg_handle, int64_t i) {
  emo_pg_stage *stg = (emo_pg_stage *)(intptr_t)stg_handle;
  if (!emo_pg_slot_ok(stg, i)) {
    return 1;
  }
  free(stg->values[i - 1]);
  stg->values[i - 1] = NULL; /* SQL NULL, named as such */
  stg->bound[i - 1] = true;
  return 0;
}

/* Fires the staged statement. 0 means a slot was never bound — the
   caller raises, since the public API binds every slot it staged; -1
   means PQexecParams itself failed (a broken connection) and the
   caller reads conn_error; anything positive is a PGresult *. */
int64_t emo_postgres_exec_fire(int64_t conn_handle, const char *sql,
                               int64_t stg_handle) {
  PGconn *conn = (PGconn *)(intptr_t)conn_handle;
  emo_pg_stage *stg = (emo_pg_stage *)(intptr_t)stg_handle;
  if (stg == NULL || sql == NULL) {
    emo_pg_stage_free(stg);
    return -1;
  }
  for (int i = 0; i < stg->n; i++) {
    if (!stg->bound[i]) {
      emo_pg_stage_free(stg);
      return 0;
    }
  }
  PGresult *res =
      PQexecParams(conn, sql, stg->n, NULL,
                   stg->n > 0 ? (const char *const *)stg->values : NULL,
                   NULL, NULL, 0 /* every answer in text format */);
  emo_pg_stage_free(stg);
  return res != NULL ? (int64_t)(intptr_t)res : -1;
}

/* ---- the result ---- */

int64_t emo_postgres_result_status(int64_t res) {
  ExecStatusType st = PQresultStatus((PGresult *)(intptr_t)res);
  if (st == PGRES_TUPLES_OK) {
    return 2;
  }
  if (st == PGRES_COMMAND_OK) {
    return 1;
  }
  return 0;
}

/* The primary message: the one line the server itself printed, not
   the multi-line report with position and context — a reason string
   stays one line and stays stable. */
const char *emo_postgres_result_error(int64_t res) {
  const char *message =
      PQresultErrorField((PGresult *)(intptr_t)res, PG_DIAG_MESSAGE_PRIMARY);
  return message != NULL ? message : "";
}

const char *emo_postgres_result_sqlstate(int64_t res) {
  const char *message =
      PQresultErrorField((PGresult *)(intptr_t)res, PG_DIAG_SQLSTATE);
  return message != NULL ? message : "";
}

int64_t emo_postgres_result_n_rows(int64_t res) {
  return (int64_t)PQntuples((PGresult *)(intptr_t)res);
}

int64_t emo_postgres_result_n_cols(int64_t res) {
  return (int64_t)PQnfields((PGresult *)(intptr_t)res);
}

const char *emo_postgres_result_col_name(int64_t res, int64_t c) {
  const char *name = PQfname((PGresult *)(intptr_t)res, (int)c);
  return name != NULL ? name : "";
}

/* A NULL cell's text reads as the empty string — libpq's own rule in
   text format; result_is_null tells the two apart. */
const char *emo_postgres_result_value(int64_t res, int64_t r, int64_t c) {
  const char *value = PQgetvalue((PGresult *)(intptr_t)res, (int)r, (int)c);
  return value != NULL ? value : "";
}

bool emo_postgres_result_is_null(int64_t res, int64_t r, int64_t c) {
  return PQgetisnull((PGresult *)(intptr_t)res, (int)r, (int)c) == 1;
}

/* The typed reads ride in pairs: the _ok half validates the cell's
   whole text in C — endptr full-consume, range included — and the
   plain half answers the parse. The text between the two calls is the
   same bytes: the result is fixed once it exists. */

bool emo_postgres_result_i64_ok(int64_t res, int64_t r, int64_t c) {
  const char *value = PQgetvalue((PGresult *)(intptr_t)res, (int)r, (int)c);
  if (value == NULL || *value == '\0') {
    return false;
  }
  errno = 0;
  char *end = NULL;
  (void)strtoll(value, &end, 10);
  return end != value && *end == '\0' && errno != ERANGE;
}

int64_t emo_postgres_result_i64(int64_t res, int64_t r, int64_t c) {
  const char *value = PQgetvalue((PGresult *)(intptr_t)res, (int)r, (int)c);
  return value != NULL ? (int64_t)strtoll(value, NULL, 10) : 0;
}

bool emo_postgres_result_f64_ok(int64_t res, int64_t r, int64_t c) {
  const char *value = PQgetvalue((PGresult *)(intptr_t)res, (int)r, (int)c);
  if (value == NULL || *value == '\0') {
    return false;
  }
  errno = 0;
  char *end = NULL;
  double parsed = strtod(value, &end);
  /* Overflow refuses; underflow does not — a genuine subnormal is a
     value, and strtod lumps it in with ERANGE. */
  if (end == value || *end != '\0') {
    return false;
  }
  return !(errno == ERANGE && parsed == HUGE_VAL);
}

double emo_postgres_result_f64(int64_t res, int64_t r, int64_t c) {
  const char *value = PQgetvalue((PGresult *)(intptr_t)res, (int)r, (int)c);
  return value != NULL ? strtod(value, NULL) : 0.0;
}

/* PostgreSQL spells a boolean t/f on the wire; the literal spellings
   the server itself accepts pass too, so a hand-typed 'true' in a
   text column reads as honestly as a boolean column's t. */
static bool emo_pg_bool_text(const char *value, bool *out) {
  static const char *const truths[] = {"t", "true", "yes", "1"};
  static const char *const lies[] = {"f", "false", "no", "0"};
  for (size_t i = 0; i < sizeof truths / sizeof truths[0]; i++) {
    if (strcasecmp(value, truths[i]) == 0) {
      *out = true;
      return true;
    }
    if (strcasecmp(value, lies[i]) == 0) {
      *out = false;
      return true;
    }
  }
  return false;
}

bool emo_postgres_result_bool_ok(int64_t res, int64_t r, int64_t c) {
  const char *value = PQgetvalue((PGresult *)(intptr_t)res, (int)r, (int)c);
  if (value == NULL) {
    return false;
  }
  bool parsed = false;
  return emo_pg_bool_text(value, &parsed);
}

bool emo_postgres_result_bool(int64_t res, int64_t r, int64_t c) {
  const char *value = PQgetvalue((PGresult *)(intptr_t)res, (int)r, (int)c);
  bool parsed = false;
  if (value != NULL) {
    (void)emo_pg_bool_text(value, &parsed);
  }
  return parsed;
}

/* The count the server reports for INSERT/UPDATE/DELETE and friends —
   an empty report (CREATE TABLE and the rest) is 0. */
int64_t emo_postgres_result_cmd_tuples(int64_t res) {
  const char *count = PQcmdTuples((PGresult *)(intptr_t)res);
  if (count == NULL || *count == '\0') {
    return 0;
  }
  return (int64_t)strtoll(count, NULL, 10);
}

void emo_postgres_result_finish(int64_t res) {
  PQclear((PGresult *)(intptr_t)res);
}
