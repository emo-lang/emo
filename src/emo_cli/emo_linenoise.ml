(* The OCaml face of the vendored linenoise editor (`linenoise.c` and
   `linenoise.h`, upstream `antirez/linenoise`): the blocking read, the
   history, and the multi-line mode. The C stubs (`emo_linenoise_stubs.c`)
   map the library's errno verdicts onto the variants below, so callers
   pattern-match, never decode integers. *)

type line =
  | Line of string (* a completed line: Enter pressed *)
  | Interrupted (* Ctrl-C: the edit abandoned, the terminal on a fresh line *)
  | End_of_input (* Ctrl-D on an empty line, or the input's end *)
  | Lost of string (* the input failed mid-read; the session cannot continue *)

type loaded =
  | Loaded
  | No_file (* no history yet: a first session's normal shape *)
  | Failed of string

external read : string -> line = "emo_linenoise_read"
external history_add : string -> bool = "emo_linenoise_history_add"
external history_load : string -> loaded = "emo_linenoise_history_load"

external history_save : string -> (unit, string) result
  = "emo_linenoise_history_save"

external history_set_max : int -> unit = "emo_linenoise_history_set_max"
external set_multiline : bool -> unit = "emo_linenoise_set_multiline"
