/* The OCaml stubs over the vendored linenoise editor (`linenoise.c`):
   the blocking read answers the `line` variant `emo_linenoise.ml`
   declares — linenoise's errno verdicts (EAGAIN the interrupted edit,
   ENOENT the input's end) map onto constructors here, so the repl
   never reads raw integers — and the history calls carry their
   verdicts as values for the same reason.

   The constructor encodings follow OCaml's representation of a mixed
   variant: constant constructors are numbered among the constants
   (immediate `Val_int(k)`), and constructors with a payload are
   numbered among the payload-bearing ones (block `caml_alloc(1, k)`)
   — the two numberings are independent, which the first pty run
   caught the hard way. */

#include <errno.h>
#include <string.h>

#include "linenoise.h"

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

/* Line of string: block 0 | Interrupted: 0 | End_of_input: 1 |
   Lost of string: block 1 */
value emo_linenoise_read(value v_prompt) {
  CAMLparam1(v_prompt);
  errno = 0;
  char *line = linenoise(String_val(v_prompt));
  if (line != NULL) {
    CAMLlocal1(v);
    v = caml_alloc(1, 0);
    Store_field(v, 0, caml_copy_string(line));
    linenoiseFree(line);
    CAMLreturn(v);
  }
  if (errno == EAGAIN) CAMLreturn(Val_int(0));
  if (errno == ENOENT) CAMLreturn(Val_int(1));
  {
    CAMLlocal1(v);
    v = caml_alloc(1, 1);
    Store_field(v, 0, caml_copy_string(errno != 0 ? strerror(errno)
                                                  : "unknown read error"));
    CAMLreturn(v);
  }
}

/* Loaded: 0 | No_file: 1 | Failed of string: block 0 */
value emo_linenoise_history_load(value v_path) {
  CAMLparam1(v_path);
  errno = 0;
  int status = linenoiseHistoryLoad(String_val(v_path));
  if (status == 0) CAMLreturn(Val_int(0));
  if (errno == ENOENT) CAMLreturn(Val_int(1));
  {
    CAMLlocal1(v);
    v = caml_alloc(1, 0);
    Store_field(v, 0, caml_copy_string(errno != 0 ? strerror(errno)
                                                  : "unknown read error"));
    CAMLreturn(v);
  }
}

/* Ok: block 0 (the unit payload) | Error of string: block 1 */
value emo_linenoise_history_save(value v_path) {
  CAMLparam1(v_path);
  errno = 0;
  if (linenoiseHistorySave(String_val(v_path)) == 0) {
    /* Ok is a block: the constructor carries the unit payload, and an
       immediate here would be read as a block header — the crash the
       first pty run caught. */
    CAMLlocal1(v);
    v = caml_alloc(1, 0);
    Store_field(v, 0, Val_int(0));
    CAMLreturn(v);
  }
  {
    CAMLlocal1(v);
    v = caml_alloc(1, 1);
    Store_field(v, 0, caml_copy_string(errno != 0 ? strerror(errno)
                                                  : "unknown write error"));
    CAMLreturn(v);
  }
}

value emo_linenoise_history_add(value v_line) {
  CAMLparam1(v_line);
  int added = linenoiseHistoryAdd(String_val(v_line));
  CAMLreturn(Val_bool(added != 0));
}

value emo_linenoise_history_set_max(value v_len) {
  CAMLparam1(v_len);
  linenoiseHistorySetMaxLen(Int_val(v_len));
  CAMLreturn(Val_int(0));
}

value emo_linenoise_set_multiline(value v_ml) {
  CAMLparam1(v_ml);
  linenoiseSetMultiLine(Bool_val(v_ml) ? 1 : 0);
  CAMLreturn(Val_int(0));
}
