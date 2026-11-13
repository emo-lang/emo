(* The WASI 0.3 command component: the wrapper that turns the WasmGC
   core module into an artifact a standard WASI runtime executes (step
   81). One fixed shape — the wasi:cli 0.3.0 imports the probe
   validated, the memory provider that breaks the canon-lower cycle,
   the stream builtins the guest calls, and the sync-lifted async run —
   expressed as an entry list and written twice: the binary the runtime
   loads and the component WAT the .wat sibling pins. The encodings
   follow the component model's Binary.md; the load-bearing facts (the
   use-split import shape, the packed-i64 stream handles, the
   ownership-transfer stdout protocol, the more-async-builtins gate)
   are the probe campaign's, recorded in plan/step-81-wasi03.md and
   devtools/wasi03-probe. *)

(* ---- Component-level types ---- *)

type prim = U8 | Str

type valtype =
  | Prim of prim
  | TypeRef of int (* an index into the enclosing type space *)

type ctype =
  | CEnum of string list
  | CResult of valtype option * valtype option (* ok?, error? *)
  | CStream of valtype option
  | CFuture of valtype option
  | CFunc of {
      async_ : bool; (* the async-typed signature; the lift stays sync *)
      params : (string * valtype) list;
      result : valtype option;
    }
  | CInstance of inst_decl list

(* A declaration inside an instance type; the inner type index space
   builds in declaration order — aliases, type defs, and type exports
   introduce indices, function exports do not. *)
and inst_decl =
  | InnerType of ctype
  | InnerAliasOuter of int * int (* scope count, outer type index *)
  | InnerExportType of string * int (* export "name" (type (eq idx)) *)
  | InnerExportFunc of string * int (* export "name" (func (type idx)) *)

(* ---- Entries ----

   The component as a flat list in definition order; the writer walks
   it once, grouping consecutive same-section entries into one compound
   section per run (compound sections repeat, and the index spaces
   build in file order, which is the order the entries carry). *)

type core_extern = CoreFuncE of int | CoreMemoryE of int

type entry =
  | EType of ctype (* → type idx *)
  | EImportInstance of string * int (* "name", type idx → instance idx *)
  | EAliasExportType of int * string (* instance idx, "name" → type idx *)
  | EAliasExportFunc of int * string (* instance idx, "name" → func idx *)
  | EAliasCoreExport of core_extern * int * string
    (* extern, core instance idx, "name" → the core index *)
  | ECoreModule of string (* the binary → core module idx *)
  | ECoreInstantiate of int * (string * int) list
    (* module idx, (name, core instance idx) args → core instance idx *)
  | ECoreInlineExports of (string * core_extern) list
    (* the synthetic instance the with-args hand the guest → core instance idx *)
  | ECanonLower of
      int * int option (* component func idx, memory? → core func idx *)
  | ECanonStreamNew of int (* stream type idx → core func idx *)
  | ECanonStreamWrite of int * int (* stream type idx, memory → core func idx *)
  | ECanonStreamDropWritable of int (* stream type idx → core func idx *)
  | ECanonFutureDropReadable of int (* future type idx → core func idx *)
  | ECanonLift of int * int (* core func idx, func type idx → func idx *)
  | EExportInstance of string * (string * int) list
(* export "name" (instance (export "inner" (func idx))); introduces
         the inline instance (section 5) and the export (section 11) *)

(* ---- The wasi:cli 0.3.0 shapes ----

   Version strings pinned at 0.3.0 (the probe validated them under
   wasmtime 49; the main-branch package is 0.3.2). *)

let error_code_cases = [ "io"; "illegal-byte-sequence"; "pipe" ]

(* The wasi:cli/types@0.3.0 instance: the enum lives here; the stdio
   interfaces alias it out (the use split — a self-contained enum
   inside the stdout instance fails wasmtime's world matching). *)
let types_instance : ctype =
  CInstance
    [
      InnerType (CEnum error_code_cases);
      (* inner 0 *)
      InnerExportType ("error-code", 0);
      (* inner 1 *)
    ]

(* A stdio interface instance (stdout and stderr share the shape): the
   error-code aliased from the outer scope and re-exported (eq), then
   the stream/result/future the signature rides and write-via-stream.
   write-via-stream is a SYNC function returning a future in 0.3.0
   final — the rc draft's async-func-to-result shape was superseded. *)
let stream_instance : ctype =
  CInstance
    [
      InnerAliasOuter (1, 1);
      (* the error-code type of the enclosing component *)
      InnerExportType ("error-code", 0);
      (* inner 1 *)
      InnerType (CStream (Some (Prim U8)));
      (* inner 2 *)
      InnerType (CResult (None, Some (TypeRef 1)));
      (* inner 3: result<_, error-code> *)
      InnerType (CFuture (Some (TypeRef 3)));
      (* inner 4 *)
      InnerType
        (CFunc
           {
             async_ = false;
             params = [ ("data", TypeRef 2) ];
             result = Some (TypeRef 4);
           });
      (* inner 5 *)
      InnerExportFunc ("write-via-stream", 5);
    ]

(* The wasi:cli/exit@0.3.0 instance, subset: exit-with-code only — an
   import's type declares what the guest needs, and the host instance
   may carry more. *)
let exit_instance : ctype =
  CInstance
    [
      InnerType (CResult (None, None));
      (* inner 0: the bare result *)
      InnerType
        (CFunc
           { async_ = false; params = [ ("status", TypeRef 0) ]; result = None });
      (* inner 1 *)
      InnerType
        (CFunc
           {
             async_ = false;
             params = [ ("status-code", Prim U8) ];
             result = None;
           });
      (* inner 2 *)
      InnerExportFunc ("exit-with-code", 2);
    ]

(* The memory provider: one memory, the pages the guest's module
   declares minimum, exported for the guest to import. Hand-encoded —
   preamble, memory section (id 5), export section (id 7). *)
let provider_module (pages : int) : string =
  let b = Buffer.create 32 in
  Buffer.add_string b "\x00\x61\x73\x6d\x01\x00\x00\x00";
  (* memory section *)
  Buffer.add_char b '\x05';
  Emo_wat.leb_u b 3;
  Buffer.add_char b '\x01';
  Buffer.add_char b '\x00';
  Emo_wat.leb_u b pages;
  (* export section *)
  Buffer.add_char b '\x07';
  Emo_wat.leb_u b 10;
  Buffer.add_char b '\x01';
  Emo_wat.leb_u b 6;
  Buffer.add_string b "memory";
  Buffer.add_char b '\x02';
  (* memory kind *)
  Emo_wat.leb_u b 0;
  Buffer.contents b

(* The entry list for the command component around [core_module_binary].
   The guest module imports its memory from "prov", the lowered WASI
   functions from their interface names, and the stream builtins from
   "stream" (see the --wasi import table in Emo_wasm). [pages] is the
   provider's initial page count. Two index spaces build: the component
   instances run imports 0-3, provider 4, synthetics 5-8, the guest 9,
   the exported run instance 10; the core instances run provider 0,
   synthetics 1-4, the guest 5 — the with-args' indices below are the
   core space. *)
let entries (pages : int) (core_module_binary : string) : entry list =
  [
    EType types_instance;
    (* type 0 *)
    EImportInstance ("wasi:cli/types@0.3.0", 0);
    (* instance 0 *)
    EAliasExportType (0, "error-code");
    (* type 1 *)
    EType stream_instance;
    (* type 2 *)
    EImportInstance ("wasi:cli/stdout@0.3.0", 2);
    (* instance 1 *)
    EType stream_instance;
    (* type 3 *)
    EImportInstance ("wasi:cli/stderr@0.3.0", 3);
    (* instance 2 *)
    EType exit_instance;
    (* type 4 *)
    EImportInstance ("wasi:cli/exit@0.3.0", 4);
    (* instance 3 *)
    (* type 5: the stream the builtins create; type 6: the result the
       stdio futures carry; type 7: that future — the same shape the
       stdio interfaces declare, or the drop-readable canon refuses the
       host's handle as "a future of a different type" *)
    EType (CStream (Some (Prim U8)));
    EType (CResult (None, Some (TypeRef 1)));
    EType (CFuture (Some (TypeRef 6)));
    EAliasExportFunc (1, "write-via-stream");
    (* func 0: stdout's *)
    EAliasExportFunc (2, "write-via-stream");
    (* func 1: stderr's *)
    EAliasExportFunc (3, "exit-with-code");
    (* func 2 *)
    (* the provider breaks the canon-lower cycle: the lowered functions
       write through the guest's linear memory, but that memory belongs
       to the guest module that is not instantiated yet — so the memory
       lives in a one-section provider module instantiated first, and
       the guest imports it (the route wit-component's shim/fixup
       avoids by indirection) *)
    ECoreModule (provider_module pages);
    (* core module 0 *)
    ECoreInstantiate (0, []);
    (* instance 4 / core instance 0 *)
    EAliasCoreExport (CoreMemoryE 0, 0, "memory");
    (* core memory 0 *)
    ECanonLower (0, Some 0);
    (* core func 0: stdout's, through the memory *)
    ECanonLower (1, Some 0);
    (* core func 1: stderr's *)
    ECanonLower (2, None);
    (* core func 2 — no linear-memory touch *)
    ECanonStreamNew 5;
    (* core func 3 *)
    ECanonStreamWrite (5, 0);
    (* core func 4 *)
    ECanonStreamDropWritable 5;
    (* core func 5 *)
    ECanonFutureDropReadable 7;
    (* core func 6 *)
    (* the synthetic instances the with-args map the guest's import
       module names onto *)
    ECoreInlineExports [ ("write-via-stream", CoreFuncE 0) ];
    (* instance 5 / core instance 1 *)
    ECoreInlineExports [ ("write-via-stream", CoreFuncE 1) ];
    (* instance 6 / core instance 2 *)
    ECoreInlineExports [ ("exit-with-code", CoreFuncE 2) ];
    (* instance 7 / core instance 3 *)
    ECoreInlineExports
      [
        ("new", CoreFuncE 3);
        ("write", CoreFuncE 4);
        ("drop-writable", CoreFuncE 5);
        ("future-drop-readable", CoreFuncE 6);
      ];
    (* instance 8 / core instance 4: the stream builtins *)
    ECoreModule core_module_binary;
    (* core module 1 *)
    ECoreInstantiate
      ( 1,
        [
          ("wasi:cli/stdout@0.3.0", 1);
          ("wasi:cli/stderr@0.3.0", 2);
          ("wasi:cli/exit@0.3.0", 3);
          ("stream", 4);
          ("prov", 0);
        ] );
    (* instance 9 / core instance 5 *)
    EAliasCoreExport (CoreFuncE 0, 5, "run");
    (* core func 7 *)
    EType (CResult (None, None));
    (* type 8: the bare result *)
    EType (CFunc { async_ = true; params = []; result = Some (TypeRef 8) });
    (* type 9 *)
    ECanonLift (7, 9);
    (* func 3: the sync lift of the async-typed run *)
    EExportInstance ("wasi:cli/run@0.3.0", [ ("run", 3) ]);
    (* instance 10 + export *)
  ]

(* ---- The binary writer ---- *)

let sort_core_func = 0x00
let sort_core_memory = 0x02

(* A component valtype: a type index (non-negative LEB) or a primitive. *)
let valtype_bytes (buf : Buffer.t) (v : valtype) =
  match v with
  | TypeRef i -> Emo_wat.leb_u buf i
  | Prim U8 -> Buffer.add_char buf '\x7d'
  | Prim Str -> Buffer.add_char buf '\x73'

(* The name-attributes wrapper: plain name, no annotations. *)
let plain_name (buf : Buffer.t) (name : string) =
  Buffer.add_char buf '\x00';
  Emo_wat.encode_name buf name

let rec ctype_bytes (buf : Buffer.t) (t : ctype) =
  match t with
  | CEnum cases ->
      Buffer.add_char buf '\x6d';
      Emo_wat.leb_u buf (List.length cases);
      List.iter (fun c -> Emo_wat.encode_name buf c) cases
  | CResult (ok, err) ->
      Buffer.add_char buf '\x6a';
      opt_valtype buf ok;
      opt_valtype buf err
  | CStream t ->
      Buffer.add_char buf '\x66';
      opt_valtype buf t
  | CFuture t ->
      Buffer.add_char buf '\x65';
      opt_valtype buf t
  | CFunc { async_; params; result } -> (
      Buffer.add_char buf (if async_ then '\x43' else '\x40');
      Emo_wat.leb_u buf (List.length params);
      List.iter
        (fun (label, v) ->
          Emo_wat.encode_name buf label;
          valtype_bytes buf v)
        params;
      match result with
      | Some v ->
          Buffer.add_char buf '\x00';
          valtype_bytes buf v
      | None ->
          Buffer.add_char buf '\x01';
          Buffer.add_char buf '\x00')
  | CInstance decls ->
      Buffer.add_char buf '\x42';
      Emo_wat.leb_u buf (List.length decls);
      List.iter (inst_decl_bytes buf) decls

and opt_valtype (buf : Buffer.t) (t : valtype option) =
  match t with
  | None -> Buffer.add_char buf '\x00'
  | Some v ->
      Buffer.add_char buf '\x01';
      valtype_bytes buf v

and inst_decl_bytes (buf : Buffer.t) (d : inst_decl) =
  match d with
  | InnerType t ->
      Buffer.add_char buf '\x01';
      ctype_bytes buf t
  | InnerAliasOuter (ct, idx) ->
      Buffer.add_char buf '\x02';
      Buffer.add_char buf '\x03';
      (* the type sort *)
      Buffer.add_char buf '\x02';
      (* outer *)
      Emo_wat.leb_u buf ct;
      Emo_wat.leb_u buf idx
  | InnerExportType (name, idx) ->
      Buffer.add_char buf '\x04';
      plain_name buf name;
      Buffer.add_char buf '\x03';
      (* the type sort's externtype *)
      Buffer.add_char buf '\x00';
      (* eq *)
      Emo_wat.leb_u buf idx
  | InnerExportFunc (name, idx) ->
      Buffer.add_char buf '\x04';
      plain_name buf name;
      Buffer.add_char buf '\x01';
      (* the func sort's externtype *)
      Emo_wat.leb_u buf idx

(* The core sortidx of a synthetic instance's inline export. *)

(* The core sort alone — the bytes an alias's sort carries. *)
let core_sort_bytes (buf : Buffer.t) (e : core_extern) =
  match e with
  | CoreFuncE _ ->
      Buffer.add_char buf '\x00';
      Buffer.add_char buf (Char.chr sort_core_func)
  | CoreMemoryE _ ->
      Buffer.add_char buf '\x00';
      Buffer.add_char buf (Char.chr sort_core_memory)

(* The core sortidx — sort plus index — an inline export carries. *)
let core_extern_bytes (buf : Buffer.t) (e : core_extern) =
  core_sort_bytes buf e;
  match e with
  | CoreFuncE i -> Emo_wat.leb_u buf i
  | CoreMemoryE i -> Emo_wat.leb_u buf i

(* One canon entry's bytes (the vec count rides with the section run). *)
let canon_bytes (buf : Buffer.t) (c : entry) =
  let opts mem =
    match mem with
    | Some m ->
        Buffer.add_char buf '\x01';
        (* one option *)
        Buffer.add_char buf '\x03';
        (* memory *)
        Emo_wat.leb_u buf m
    | None -> Buffer.add_char buf '\x00'
  in
  match c with
  | ECanonLower (f, mem) ->
      Buffer.add_string buf "\x01\x00";
      Emo_wat.leb_u buf f;
      opts mem
  | ECanonStreamNew t ->
      Buffer.add_char buf '\x0e';
      Emo_wat.leb_u buf t
  | ECanonStreamWrite (t, mem) ->
      Buffer.add_char buf '\x10';
      Emo_wat.leb_u buf t;
      opts (Some mem)
  | ECanonStreamDropWritable t ->
      Buffer.add_char buf '\x14';
      Emo_wat.leb_u buf t
  | ECanonFutureDropReadable t ->
      Buffer.add_char buf '\x1a';
      Emo_wat.leb_u buf t
  | ECanonLift (f, t) ->
      Buffer.add_string buf "\x00\x00";
      Emo_wat.leb_u buf f;
      Buffer.add_char buf '\x00';
      (* no options *)
      Emo_wat.leb_u buf t
  | _ -> failwith "component: not a canon entry"

let entry_section (e : entry) : int =
  match e with
  | EType _ -> 7
  | EImportInstance _ -> 10
  | EAliasExportType _ | EAliasExportFunc _ | EAliasCoreExport _ -> 6
  | ECoreModule _ -> 1
  | ECoreInstantiate _ | ECoreInlineExports _ -> 2
  | ECanonLower _ | ECanonStreamNew _ | ECanonStreamWrite _
  | ECanonStreamDropWritable _ | ECanonFutureDropReadable _ | ECanonLift _ ->
      8
  | EExportInstance _ -> 5 (* its export half rides section 11 *)

(* One framed section: id byte, payload length, payload. *)
let section_buf (id : int) (content : Buffer.t) : string =
  let out = Buffer.create (Buffer.length content + 8) in
  Buffer.add_char out (Char.chr id);
  Emo_wat.leb_u out (Buffer.length content);
  Buffer.add_buffer out content;
  Buffer.contents out

(* Writes one entry's bytes into its section payload. [inst_count] is
   the component instances introduced so far — the export-instance
   entry's export references the inline instance it itself introduces.
   Returns the section-11 payload for an export-instance entry (None
   otherwise). *)
let entry_bytes (buf : Buffer.t) (inst_count : int) (e : entry) :
    Buffer.t option =
  match e with
  | EType t ->
      ctype_bytes buf t;
      None
  | EImportInstance (name, ty) ->
      plain_name buf name;
      Buffer.add_char buf '\x05';
      (* instance externtype *)
      Emo_wat.leb_u buf ty;
      None
  | EAliasExportType (inst, name) ->
      Buffer.add_char buf '\x03';
      (* the type sort *)
      Buffer.add_char buf '\x00';
      (* export *)
      Emo_wat.leb_u buf inst;
      Emo_wat.encode_name buf name;
      None
  | EAliasExportFunc (inst, name) ->
      Buffer.add_char buf '\x01';
      (* the func sort *)
      Buffer.add_char buf '\x00';
      Emo_wat.leb_u buf inst;
      Emo_wat.encode_name buf name;
      None
  | EAliasCoreExport (ext, inst, name) ->
      core_sort_bytes buf ext;
      Buffer.add_char buf '\x01';
      (* core export *)
      Emo_wat.leb_u buf inst;
      Emo_wat.encode_name buf name;
      None
  | ECoreModule bin ->
      (* the section payload is the module binary itself — the framing
         (id + size) rides [section_buf] *)
      Buffer.add_string buf bin;
      None
  | ECoreInstantiate (m, args) ->
      Buffer.add_char buf '\x00';
      Emo_wat.leb_u buf m;
      Emo_wat.leb_u buf (List.length args);
      List.iter
        (fun (name, inst) ->
          Emo_wat.encode_name buf name;
          Buffer.add_char buf '\x12';
          (* the core instance sort *)
          Emo_wat.leb_u buf inst)
        args;
      None
  | ECoreInlineExports xs ->
      Buffer.add_char buf '\x01';
      Emo_wat.leb_u buf (List.length xs);
      List.iter
        (fun (name, ext) ->
          (* a core inline export is a core Export: plain name, then the
             core ExternalKind byte (no core-sort prefix), then the index *)
          Emo_wat.encode_name buf name;
          match ext with
          | CoreFuncE i ->
              Buffer.add_char buf '\x00';
              Emo_wat.leb_u buf i
          | CoreMemoryE i ->
              Buffer.add_char buf '\x02';
              Emo_wat.leb_u buf i)
        xs;
      None
  | ECanonLower _ | ECanonStreamNew _ | ECanonStreamWrite _
  | ECanonStreamDropWritable _ | ECanonFutureDropReadable _ | ECanonLift _ ->
      canon_bytes buf e;
      None
  | EExportInstance (name, funcs) ->
      (* section 5: the inline COMPONENT instance — its exports carry a
         plain-name wrapper and a component-level sortidx; section 11:
         the export *)
      Buffer.add_char buf '\x01';
      Emo_wat.leb_u buf (List.length funcs);
      List.iter
        (fun (inner, f) ->
          plain_name buf inner;
          Buffer.add_char buf '\x01';
          (* the component func sort *)
          Emo_wat.leb_u buf f)
        funcs;
      let exp = Buffer.create 64 in
      plain_name exp name;
      Buffer.add_char exp '\x05';
      (* the instance sort *)
      Emo_wat.leb_u exp inst_count;
      (* the inline instance this entry introduces *)
      Buffer.add_char exp '\x00';
      (* no ascribed type *)
      Some exp

(* The component instance space counts only component-level instances —
   the interface imports and the inline export instance; the provider,
   the synthetics, and the guest live in the CORE instance space (the
   with-args' indices), which the entry indices encode directly. *)
let introduces_instance (e : entry) : bool =
  match e with EImportInstance _ | EExportInstance _ -> true | _ -> false

let to_binary (es : entry list) : string =
  let out = Buffer.create 2048 in
  Buffer.add_string out "\x00\x61\x73\x6d\x0d\x00\x01\x00";
  let inst_count = ref 0 in
  (* Flushes one compound section: the entries' bytes ride a vector, so
     the run's count prefixes the payload — except section 1, which is
     a single embedded core module, no count. *)
  let flush id buf count =
    if count > 0 then begin
      let counted = Buffer.create (Buffer.length buf + 8) in
      if id <> 1 then Emo_wat.leb_u counted count;
      Buffer.add_buffer counted buf;
      Buffer.add_string out (section_buf id counted)
    end
  in
  let rec go last_id buf count es =
    match es with
    | [] -> flush last_id buf count
    | e :: rest ->
        let id = entry_section e in
        if id = 5 then begin
          (* the export-instance entry rides two sections: flush the
             current run, write the inline instance, then its export *)
          flush last_id buf count;
          let inst = Buffer.create 64 in
          let exp =
            match entry_bytes inst !inst_count e with
            | Some exp -> exp
            | None -> assert false
          in
          let counted_inst = Buffer.create (Buffer.length inst + 8) in
          Emo_wat.leb_u counted_inst 1;
          Buffer.add_buffer counted_inst inst;
          Buffer.add_string out (section_buf 5 counted_inst);
          let counted_exp = Buffer.create (Buffer.length exp + 8) in
          Emo_wat.leb_u counted_exp 1;
          Buffer.add_buffer counted_exp exp;
          Buffer.add_string out (section_buf 11 counted_exp);
          inst_count := !inst_count + 1;
          go (-1) (Buffer.create 128) 0 rest
        end
        else if id = last_id then begin
          ignore (entry_bytes buf !inst_count e);
          if introduces_instance e then inst_count := !inst_count + 1;
          go last_id buf (count + 1) rest
        end
        else begin
          flush last_id buf count;
          let buf = Buffer.create 128 in
          ignore (entry_bytes buf !inst_count e);
          if introduces_instance e then inst_count := !inst_count + 1;
          go id buf 1 rest
        end
  in
  go (-1) (Buffer.create 128) 0 es;
  Buffer.contents out

(* ---- The component WAT printer ----

   The same shape the probe's hand-written WAT carries, so the .wat
   sibling reads the way the campaign's evidence does. *)

let valtype_text (v : valtype) : string =
  match v with
  | TypeRef i -> Printf.sprintf "%d" i
  | Prim U8 -> "u8"
  | Prim Str -> "string"

let rec ctype_text (t : ctype) : string =
  match t with
  | CEnum cases ->
      Printf.sprintf "(enum %s)"
        (String.concat " " (List.map (fun c -> "\"" ^ c ^ "\"") cases))
  | CResult (ok, err) ->
      let ok_text =
        match ok with None -> "" | Some v -> " (ok " ^ valtype_text v ^ ")"
      in
      let err_text =
        match err with
        | None -> ""
        | Some v -> " (error " ^ valtype_text v ^ ")"
      in
      if ok_text = "" && err_text = "" then "(result)"
      else Printf.sprintf "(result%s%s)" ok_text err_text
  | CStream t -> (
      match t with
      | None -> "(stream)"
      | Some v -> "(stream " ^ valtype_text v ^ ")")
  | CFuture t -> (
      match t with
      | None -> "(future)"
      | Some v -> "(future " ^ valtype_text v ^ ")")
  | CFunc { async_; params; result } ->
      let a = if async_ then "async " else "" in
      let ps =
        match params with
        | [] -> ""
        | ps ->
            " (param "
            ^ String.concat " "
                (List.map
                   (fun (l, v) -> Printf.sprintf "%S %s" l (valtype_text v))
                   ps)
            ^ ")"
      in
      let rs =
        match result with
        | None -> ""
        | Some v -> " (result " ^ valtype_text v ^ ")"
      in
      Printf.sprintf "(func %s%s%s)" a ps rs
  | CInstance decls ->
      Printf.sprintf "(instance %s)"
        (String.concat " " (List.map inst_decl_text decls))

and inst_decl_text (d : inst_decl) : string =
  match d with
  | InnerType t -> Printf.sprintf "(type %s)" (ctype_text t)
  | InnerAliasOuter (ct, idx) ->
      Printf.sprintf "(alias outer %d %d (type))" ct idx
  | InnerExportType (name, idx) ->
      Printf.sprintf "(export %S (type (eq %d)))" name idx
  | InnerExportFunc (name, idx) ->
      Printf.sprintf "(export %S (func (type %d)))" name idx

let core_extern_text (e : core_extern) : string =
  match e with
  | CoreFuncE i -> Printf.sprintf "(core func $cf%d)" i
  | CoreMemoryE i -> Printf.sprintf "(core memory $cm%d)" i

let entry_text (indent : string) (e : entry) : string =
  match e with
  | EType t -> Printf.sprintf "%s(type %s)\n" indent (ctype_text t)
  | EImportInstance (name, ty) ->
      Printf.sprintf "%s(import %S (instance (type %d)))\n" indent name ty
  | EAliasExportType (inst, name) ->
      Printf.sprintf "%s(alias export %d %S (type))\n" indent inst name
  | EAliasExportFunc (inst, name) ->
      Printf.sprintf "%s(alias export %d %S (func))\n" indent inst name
  | EAliasCoreExport (ext, inst, name) ->
      Printf.sprintf "%s(alias %s %d %S)\n" indent
        (match ext with
        | CoreFuncE _ -> "core export"
        | CoreMemoryE _ -> "core export")
        inst name
  | ECoreModule _ -> Printf.sprintf "%s(core module $m)\n" indent
  | ECoreInstantiate (m, args) ->
      let withs =
        String.concat " "
          (List.map
             (fun (n, i) -> Printf.sprintf "(with %S (core instance %d))" n i)
             args)
      in
      Printf.sprintf "%s(core instance (instantiate %d %s))\n" indent m withs
  | ECoreInlineExports xs ->
      Printf.sprintf "%s(core instance %s)\n" indent
        (String.concat " "
           (List.map
              (fun (n, ext) ->
                Printf.sprintf "(export %S %s)" n
                  (match ext with
                  | CoreFuncE i -> Printf.sprintf "(func %d)" i
                  | CoreMemoryE i -> Printf.sprintf "(memory %d)" i))
              xs))
  | ECanonLower (f, mem) ->
      Printf.sprintf "%s(core func (canon lower (func %d)%s))\n" indent f
        (match mem with
        | Some m -> Printf.sprintf " (memory %d)" m
        | None -> "")
  | ECanonStreamNew t ->
      Printf.sprintf "%s(core func (canon stream.new (type %d)))\n" indent t
  | ECanonStreamWrite (t, m) ->
      Printf.sprintf
        "%s(core func (canon stream.write (type %d) (memory %d)))\n" indent t m
  | ECanonStreamDropWritable t ->
      Printf.sprintf "%s(core func (canon stream.drop-writable (type %d)))\n"
        indent t
  | ECanonFutureDropReadable t ->
      Printf.sprintf "%s(core func (canon future.drop-readable (type %d)))\n"
        indent t
  | ECanonLift (f, t) ->
      Printf.sprintf "%s(func (canon lift (core func %d) (type %d)))\n" indent f
        t
  | EExportInstance (name, funcs) ->
      let inners =
        String.concat " "
          (List.map
             (fun (n, f) -> Printf.sprintf "(export %S (func %d))" n f)
             funcs)
      in
      Printf.sprintf "%s(instance (export %s))\n%s(export %S (instance))\n"
        indent inners indent name

let to_text (es : entry list) : string =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf "(component\n";
  List.iter (fun e -> Buffer.add_string buf (entry_text "  " e)) es;
  Buffer.add_string buf ")\n";
  Buffer.contents buf

(* The command component around [core_module_binary]; [pages] is the
   provider's (and the guest's) minimum page count. *)
let command (pages : int) (core_module_binary : string) : string * string =
  let es = entries pages core_module_binary in
  (to_binary es, to_text es)
