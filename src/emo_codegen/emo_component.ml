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
   are the probe campaign's, recorded in plan/step-85-wasi03.md and
   devtools/wasi03-probe. *)

(* ---- Component-level types ---- *)

type prim = U8 | U64 | Str
type valtype = Prim of prim | TypeRef of int
(* an index into the enclosing type space — the own/borrow handle
         types are declared as deftypes and referenced by index, the
         component binary's valtype has no inline handle form *)

type ctype =
  | CEnum of string list
  | CFlags of string list
  | CVariant of (string * valtype option) list
  | CRecord of (string * valtype) list
  | CList of valtype
  | CTuple of valtype list
  | COption of valtype
  | CResult of valtype option * valtype option (* ok?, error? *)
  | CStream of valtype option
  | CFuture of valtype option
  | COwn of int
    (* own <typeidx> — the deftype a handle-typed
      parameter or result references by index; the resource's own
      handle is one of these, named then referenced *)
  | CBorrow of int (* borrow <typeidx> *)
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
  | InnerExportResource of string
    (* export "name" (type (sub resource)) —
      the fresh abstract resource the handles refer to *)
  | InnerExportFunc of string * int (* export "name" (func (type idx)) *)

(* The canon lower's option set: the memory the flattened values cross
   through, the guest allocator for host-written contents, and the
   guest's string encoding. utf8 is the model's default; the option is
   emitted wherever strings ride the signature, the shape wit-component
   itself emits. *)
type canon_opts = { mem : int option; realloc : int option; str_utf8 : bool }

let no_opts = { mem = None; realloc = None; str_utf8 = false }

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
      int * canon_opts (* component func idx, opts → core func idx *)
  | ECanonStreamNew of int (* stream type idx → core func idx *)
  | ECanonStreamWrite of int * canon_opts (* stream type idx, opts *)
  | ECanonStreamRead of int * canon_opts (* stream type idx, opts *)
  | ECanonStreamDropWritable of int (* stream type idx → core func idx *)
  | ECanonStreamDropReadable of int (* stream type idx → core func idx *)
  | ECanonFutureRead of int * canon_opts (* future type idx, opts *)
  | ECanonFutureDropReadable of int (* future type idx → core func idx *)
  | ECanonResourceDrop of int (* resource type idx → core func idx *)
  | ECanonLift of int * int (* core func idx, func type idx → func idx *)
  | EExportInstance of string * (string * int) list
(* export "name" (instance (export "inner" (func idx))); introduces
         the inline instance (section 5) and the export (section 11) *)

(* ---- The WASI 0.3.0 shapes ----

   Version strings pinned at 0.3.0 (the probe validated them under
   wasmtime 49; the main-branch package is 0.3.2). *)

let error_code_cases = [ "io"; "illegal-byte-sequence"; "pipe" ]

(* The wasi:filesystem error-code variant, spelled as its degenerate
   enum — every case bare, and the honest subset being the whole list
   (the guest's declared variant is what the host must stay inside when
   it sends a failure). The order is the normative WIT's. *)
let fs_error_code_cases =
  [
    "access";
    "already";
    "bad-descriptor";
    "busy";
    "deadlock";
    "quota";
    "exist";
    "file-too-large";
    "illegal-byte-sequence";
    "in-progress";
    "interrupted";
    "invalid";
    "io";
    "is-directory";
    "loop";
    "too-many-links";
    "message-size";
    "name-too-long";
    "no-device";
    "no-entry";
    "no-lock";
    "insufficient-memory";
    "insufficient-space";
    "not-directory";
    "not-empty";
    "not-recoverable";
    "unsupported";
    "no-tty";
    "no-such-device";
    "overflow";
    "not-permitted";
    "pipe";
    "read-only";
    "invalid-seek";
    "text-file-busy";
    "cross-device";
  ]

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

(* The wasi:filesystem/types@0.3.0 instance, the door subset the fd and
   directory half lowers onto. The descriptor rides the (sub resource)
   export bound — resource definitions are rejected inside instance
   types, so the fresh abstract type the handles refer to is declared
   by its export, the shape wit-component itself emits. The offset
   params ride the inline u64 primval (the real interface names the
   alias `filesize`; structurally one type). Inner layout:
   0 descriptor | 1 fs error-code | 2 path-flags | 3 open-flags |
   4 descriptor-flags | 5 borrow descriptor | 6 stream<u8> |
   7 result<_,1> | 8 future 7 | 9 tuple 6,8 | 10 read-via-stream's type
   | 12 write-via-stream | 14 append-via-stream | 16 option string |
   17 descriptor-type | 18 directory-entry | 19 stream 18 |
   20 tuple 19,8 | 21 read-directory | 23 create-directory-at |
   25 own 0 | 26 result 25,1 | 27 open-at | 29 remove-directory-at |
   31 rename-at | 33 unlink-file-at — the three one-string
   result<_,err> methods share one type. *)
let fs_types_instance : ctype =
  CInstance
    [
      InnerExportResource "descriptor";
      (* inner 0 — the fresh abstract resource the handles refer to *)
      InnerType (COption (Prim Str));
      (* inner 1 — the payload of error-code's other case *)
      InnerType
        (CVariant
           (List.map (fun c -> (c, None)) fs_error_code_cases
           @ [ ("other", Some (TypeRef 1)) ]));
      (* inner 2 — the error-code variant; the real interface spells it
         a variant, and wasmtime 49's host carries the 37th `other`
         case, so the guest's list is the full one (a smaller variant
         fails the linker's case-by-case match) *)
      InnerExportType ("error-code", 2);
      (* inner 3 — the eq export the methods' results reference *)
      InnerType (CFlags [ "symlink-follow" ]);
      (* inner 4 *)
      InnerExportType ("path-flags", 4);
      (* inner 5 *)
      InnerType (CFlags [ "create"; "directory"; "exclusive"; "truncate" ]);
      (* inner 6 *)
      InnerExportType ("open-flags", 6);
      (* inner 7 *)
      InnerType
        (CFlags
           [
             "read";
             "write";
             "file-integrity-sync";
             "data-integrity-sync";
             "requested-write-sync";
             "mutate-directory";
           ]);
      (* inner 8 *)
      InnerExportType ("descriptor-flags", 8);
      (* inner 9 *)
      InnerType (CBorrow 0);
      (* inner 10: borrow<descriptor> — the self params reference it *)
      InnerType (CStream (Some (Prim U8)));
      (* inner 11 *)
      InnerType (CResult (None, Some (TypeRef 3)));
      (* inner 12 *)
      InnerType (CFuture (Some (TypeRef 12)));
      (* inner 13 *)
      InnerType (CTuple [ TypeRef 11; TypeRef 13 ]);
      (* inner 14 *)
      InnerType
        (CFunc
           {
             async_ = false;
             params = [ ("self", TypeRef 10); ("offset", Prim U64) ];
             result = Some (TypeRef 14);
           });
      (* inner 15 — the offset rides the inline u64 primval; the
         function exports carry no inner type index *)
      InnerExportFunc ("[method]descriptor.read-via-stream", 15);
      InnerType
        (CFunc
           {
             async_ = false;
             params =
               [
                 ("self", TypeRef 10); ("data", TypeRef 11); ("offset", Prim U64);
               ];
             result = Some (TypeRef 13);
           });
      (* inner 16 *)
      InnerExportFunc ("[method]descriptor.write-via-stream", 16);
      InnerType
        (CFunc
           {
             async_ = false;
             params = [ ("self", TypeRef 10); ("data", TypeRef 11) ];
             result = Some (TypeRef 13);
           });
      (* inner 17 *)
      InnerExportFunc ("[method]descriptor.append-via-stream", 17);
      InnerType
        (CVariant
           [
             ("block-device", None);
             ("character-device", None);
             ("directory", None);
             ("fifo", None);
             ("symbolic-link", None);
             ("regular-file", None);
             ("socket", None);
             ("other", Some (TypeRef 1));
           ]);
      (* inner 18: descriptor-type *)
      InnerExportType ("descriptor-type", 18);
      (* inner 19 *)
      InnerType (CRecord [ ("type", TypeRef 19); ("name", Prim Str) ]);
      (* inner 20: directory-entry *)
      InnerExportType ("directory-entry", 20);
      (* inner 21 *)
      InnerType (CStream (Some (TypeRef 21)));
      (* inner 22 *)
      InnerType (CTuple [ TypeRef 22; TypeRef 13 ]);
      (* inner 23 *)
      InnerType
        (CFunc
           {
             async_ = false;
             params = [ ("self", TypeRef 10) ];
             result = Some (TypeRef 23);
           });
      InnerExportFunc ("[method]descriptor.read-directory", 24);
      InnerType
        (CFunc
           {
             async_ = true;
             params = [ ("self", TypeRef 10); ("path", Prim Str) ];
             result = Some (TypeRef 12);
           });
      (* inner 25 — create/remove/unlink share it *)
      InnerExportFunc ("[method]descriptor.create-directory-at", 25);
      InnerExportFunc ("[method]descriptor.remove-directory-at", 25);
      InnerExportFunc ("[method]descriptor.unlink-file-at", 25);
      InnerType (COwn 0);
      (* inner 26 *)
      InnerType (CResult (Some (TypeRef 26), Some (TypeRef 3)));
      (* inner 27 *)
      InnerType
        (CFunc
           {
             async_ = true;
             params =
               [
                 ("self", TypeRef 10);
                 ("path-flags", TypeRef 5);
                 ("path", Prim Str);
                 ("open-flags", TypeRef 7);
                 ("flags", TypeRef 9);
               ];
             result = Some (TypeRef 27);
           });
      InnerExportFunc ("[method]descriptor.open-at", 28);
      InnerType
        (CFunc
           {
             async_ = true;
             params =
               [
                 ("self", TypeRef 10);
                 ("old-path", Prim Str);
                 ("new-descriptor", TypeRef 10);
                 ("new-path", Prim Str);
               ];
             result = Some (TypeRef 12);
           });
      (* inner 29 *)
      InnerExportFunc ("[method]descriptor.rename-at", 29);
    ]

(* The wasi:filesystem/preopens@0.3.0 instance: the use split — the
   descriptor type aliases the component-level one and re-exports it
   (eq), then the preopen list. [descriptor] is the aliased type's
   component index. *)
let fs_preopens_instance (descriptor : int) : ctype =
  CInstance
    [
      InnerAliasOuter (1, descriptor);
      (* inner 0 *)
      InnerExportType ("descriptor", 0);
      (* inner 1 *)
      InnerType (COwn 1);
      (* inner 2 *)
      InnerType (CTuple [ TypeRef 2; Prim Str ]);
      (* inner 3 *)
      InnerType (CList (TypeRef 3));
      (* inner 4 *)
      InnerType
        (CFunc { async_ = false; params = []; result = Some (TypeRef 4) });
      (* inner 5 *)
      InnerExportFunc ("get-directories", 5);
    ]

(* The wasi:random/random@0.3.0 instance, subset: get-random-bytes.
   Short returns are the caller's loop — the lowering accumulates. *)
let random_instance : ctype =
  CInstance
    [
      InnerType (CList (Prim U8));
      (* inner 0 *)
      InnerType
        (CFunc
           {
             async_ = false;
             params = [ ("max-len", Prim U64) ];
             result = Some (TypeRef 0);
           });
      (* inner 1 *)
      InnerExportFunc ("get-random-bytes", 1);
    ]

(* The wasi:cli/environment@0.3.0 instance: the three read-only doors —
   variables, arguments, and the initial-cwd hint the relative-path
   resolution anchors on (0.3 has no cwd concept). *)
let environment_instance : ctype =
  CInstance
    [
      InnerType (CTuple [ Prim Str; Prim Str ]);
      (* inner 0 *)
      InnerType (CList (TypeRef 0));
      (* inner 1 *)
      InnerType
        (CFunc { async_ = false; params = []; result = Some (TypeRef 1) });
      (* inner 2 *)
      InnerExportFunc ("get-environment", 2);
      InnerType (CList (Prim Str));
      (* inner 3 *)
      InnerType
        (CFunc { async_ = false; params = []; result = Some (TypeRef 3) });
      InnerExportFunc ("get-arguments", 4);
      InnerType (COption (Prim Str));
      (* inner 5 *)
      InnerType
        (CFunc { async_ = false; params = []; result = Some (TypeRef 5) });
      InnerExportFunc ("get-initial-cwd", 6);
    ]

(* The memory provider: the memory the guest imports, plus the realloc
   function the canon lowers with host-written results call — the one
   piece of the canonical ABI the guest cannot export (the lowers must
   exist before the guest is instantiated, so the realloc option cannot
   reference a guest export; wit-component unties the same knot with an
   indirect-call shim, this shape ties it with a shared bump cursor
   instead). The allocator state lives at fixed address 0x100 in the
   shared memory: the guest's wasi-mode bump allocator reads and
   advances the same cell, so the two allocators never overlap. The
   function honors the align argument (the host traps on misaligned
   list storage), grows the memory on demand, and copies on grow — the
   canonical ABI's realloc contract. Hand-encoded — preamble, type,
   function, memory, export, code sections. *)
let provider_module (pages : int) : string =
  let b = Buffer.create 256 in
  Buffer.add_string b "\x00\x61\x73\x6d\x01\x00\x00\x00";
  (* type section: one type, (i32 i32 i32 i32) -> i32 — the size
     covers the vector count and the eight functype bytes *)
  Buffer.add_char b '\x01';
  Emo_wat.leb_u b 9;
  Buffer.add_char b '\x01';
  Buffer.add_string b "\x60\x04\x7f\x7f\x7f\x7f\x01\x7f";
  (* function section *)
  Buffer.add_char b '\x03';
  Emo_wat.leb_u b 2;
  Buffer.add_char b '\x01';
  Buffer.add_char b '\x00';
  (* memory section *)
  Buffer.add_char b '\x05';
  Emo_wat.leb_u b 3;
  Buffer.add_char b '\x01';
  Buffer.add_char b '\x00';
  Emo_wat.leb_u b pages;
  (* export section: the vector count plus both entries *)
  Buffer.add_char b '\x07';
  Emo_wat.leb_u b 20;
  Buffer.add_char b '\x02';
  Emo_wat.leb_u b 6;
  Buffer.add_string b "memory";
  Buffer.add_char b '\x02';
  (* memory kind *)
  Emo_wat.leb_u b 0;
  Emo_wat.leb_u b 7;
  Buffer.add_string b "realloc";
  Buffer.add_char b '\x00';
  (* func kind *)
  Emo_wat.leb_u b 0;
  (* code section: one function; locals p and end ride slots 4 and 5 —
     params are old, old_size, align, new_size in 0..3. The body: the
     shrink-in-place early return, the aligned fresh bump off the shared
     cursor cell, the grow-when-short loop, the cursor store, the copy
     on grow. *)
  let body = Buffer.create 128 in
  (* locals: two i32 *)
  Emo_wat.leb_u body 1;
  Emo_wat.leb_u body 2;
  Buffer.add_char body '\x7f';
  (* the shrink-in-place block: old set and new_size <= old_size
     answers old directly *)
  Buffer.add_string body
    "\x02\x40\x20\x00\x45\x0d\x00\x20\x03\x20\x01\x4f\x0d\x00\x20\x00\x0f\x0b";
  (* p = load(0x100), aligned up to align *)
  Buffer.add_string body
    "\x41\x80\x02\x28\x02\x00\x21\x04\x20\x04\x20\x02\x6a\x41\x01\x6b\x41\x00\x20\x02\x6b\x71\x21\x04";
  (* end = p + new_size *)
  Buffer.add_string body "\x20\x04\x20\x03\x6a\x21\x05";
  (* grow while end exceeds the memory's current byte size *)
  Buffer.add_string body "\x02\x40\x20\x05\x3f\x00\x41\x10\x74\x4e\x0d\x00";
  Buffer.add_string body
    "\x20\x05\x3f\x00\x41\x10\x74\x6b\x41\xff\xff\x03\x6a\x41\x10\x76\x40\x00\x1a\x0b";
  (* the cursor cell takes the new end — the address pushes first, the
     value last: i32.store pops value then address *)
  Buffer.add_string body "\x41\x80\x02\x20\x05\x36\x02\x00";
  (* grow path copies the old contents *)
  Buffer.add_string body
    "\x02\x40\x20\x00\x45\x0d\x00\x20\x04\x20\x00\x20\x01\xfc\x0a\x00\x00\x0b";
  Buffer.add_string body "\x20\x04\x0b";
  (* code section: the vector count, then the one function entry —
     its size covers the locals vector and the instructions, both
     already in [body] *)
  Buffer.add_char b '\x0a';
  Emo_wat.leb_u b (Buffer.length body + 2);
  Emo_wat.leb_u b 1;
  Emo_wat.leb_u b (Buffer.length body);
  Buffer.add_buffer b body;
  Buffer.contents b

(* The entry list for the command component around [core_module_binary].
   The guest module imports its memory and realloc provider from "prov",
   the lowered WASI functions from their interface names, and the
   stream/future/resource builtins from "stream"/"future"/"resource"
   (see the --wasi import table in Emo_wasm). [pages] is the provider's
   initial page count. Two index spaces build: the component instances
   run imports 0-7, the exported run instance 8; the core instances run
   provider 0, synthetics 1-10, the guest 11 — the with-args' indices
   below are the core space. Types: 0-4 the cli shapes, 5 the fs types
   interface, 6 the aliased descriptor, 7-9 preopens/random/environment,
   10-12 the stdio stream/result/future, 13-15 the fs error/result/
   future, 16-19 the directory-entry record and its stream, 20-21 the
   run's bare result and async type. Core funcs: 0 the provider's
   realloc, 1-3 the stdio lowers, 4-8 the stream builtins, 9-11 the
   future builtins and descriptor drop, 12-21 the fs method lowers,
   22-26 the preopens/random/environment lowers. *)
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
    EAliasExportFunc (1, "write-via-stream");
    (* func 0: stdout's *)
    EAliasExportFunc (2, "write-via-stream");
    (* func 1: stderr's *)
    EAliasExportFunc (3, "exit-with-code");
    (* func 2 *)
    EType fs_types_instance;
    (* type 5 *)
    EImportInstance ("wasi:filesystem/types@0.3.0", 5);
    (* instance 4 *)
    EAliasExportType (4, "descriptor");
    (* type 6 *)
    EAliasExportFunc (4, "[method]descriptor.read-via-stream");
    (* func 3 *)
    EAliasExportFunc (4, "[method]descriptor.write-via-stream");
    (* func 4 *)
    EAliasExportFunc (4, "[method]descriptor.append-via-stream");
    (* func 5 *)
    EAliasExportFunc (4, "[method]descriptor.read-directory");
    (* func 6 *)
    EAliasExportFunc (4, "[method]descriptor.create-directory-at");
    (* func 7 *)
    EAliasExportFunc (4, "[method]descriptor.open-at");
    (* func 8 *)
    EAliasExportFunc (4, "[method]descriptor.remove-directory-at");
    (* func 9 *)
    EAliasExportFunc (4, "[method]descriptor.rename-at");
    (* func 10 *)
    EAliasExportFunc (4, "[method]descriptor.unlink-file-at");
    (* func 11 *)
    EType (fs_preopens_instance 6);
    (* type 7 *)
    EImportInstance ("wasi:filesystem/preopens@0.3.0", 7);
    (* instance 5 *)
    EAliasExportFunc (5, "get-directories");
    (* func 12 *)
    EType random_instance;
    (* type 8 *)
    EImportInstance ("wasi:random/random@0.3.0", 8);
    (* instance 6 *)
    EAliasExportFunc (6, "get-random-bytes");
    (* func 13 *)
    EType environment_instance;
    (* type 9 *)
    EImportInstance ("wasi:cli/environment@0.3.0", 9);
    (* instance 7 *)
    EAliasExportFunc (7, "get-environment");
    (* func 14 *)
    EAliasExportFunc (7, "get-arguments");
    (* func 15 *)
    EAliasExportFunc (7, "get-initial-cwd");
    (* func 16 *)
    (* types 10-12: the stream the builtins create, the result the stdio
       futures carry, that future — the same shape the stdio interfaces
       declare, or the drop-readable canon refuses the host's handle as
       "a future of a different type". Types 13-15: the fs error-code,
       its result, and the future the fs write/read streams carry.
       Types 16-19: the directory-entry record and the stream it rides. *)
    EType (CStream (Some (Prim U8)));
    EType (CResult (None, Some (TypeRef 1)));
    EType (CFuture (Some (TypeRef 11)));
    EType (COption (Prim Str));
    EType
      (CVariant
         (List.map (fun c -> (c, None)) fs_error_code_cases
         @ [ ("other", Some (TypeRef 13)) ]));
    EType (CResult (None, Some (TypeRef 14)));
    EType (CFuture (Some (TypeRef 15)));
    EType
      (CVariant
         [
           ("block-device", None);
           ("character-device", None);
           ("directory", None);
           ("fifo", None);
           ("symbolic-link", None);
           ("regular-file", None);
           ("socket", None);
           ("other", Some (TypeRef 13));
         ]);
    EType (CRecord [ ("type", TypeRef 17); ("name", Prim Str) ]);
    EType (CStream (Some (TypeRef 18)));
    (* the provider breaks the canon-lower cycle: the lowered functions
       write through the guest's linear memory, but that memory belongs
       to the guest module that is not instantiated yet — so the memory
       and the realloc the host-allocated results call live in a
       provider module instantiated first, and the guest imports both
       (the route wit-component's shim/fixup avoids by indirection; the
       shared bump cursor keeps the two allocators disjoint) *)
    ECoreModule (provider_module pages);
    (* core module 0 *)
    ECoreInstantiate (0, []);
    (* core instance 0 *)
    EAliasCoreExport (CoreMemoryE 0, 0, "memory");
    (* core memory 0 *)
    EAliasCoreExport (CoreFuncE 0, 0, "realloc");
    (* core func 0 *)
    ECanonLower (0, { mem = Some 0; realloc = None; str_utf8 = false });
    (* core func 1: stdout's *)
    ECanonLower (1, { mem = Some 0; realloc = None; str_utf8 = false });
    (* core func 2: stderr's *)
    ECanonLower (2, no_opts);
    (* core func 3 — no linear-memory touch *)
    ECanonStreamNew 10;
    (* core func 4 *)
    ECanonStreamWrite (10, { mem = Some 0; realloc = None; str_utf8 = false });
    (* core func 5 *)
    ECanonStreamRead (10, { mem = Some 0; realloc = None; str_utf8 = false });
    (* core func 6: the u8 file-read door *)
    ECanonStreamDropWritable 10;
    (* core func 7 *)
    ECanonStreamDropReadable 10;
    (* core func 8: the file stream's readable end *)
    ECanonStreamRead (19, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 9: the directory-entry stream — the names the host
       writes allocate through the provider's realloc *)
    ECanonStreamDropReadable 19;
    (* core func 10: the directory-entry stream's readable end *)
    ECanonFutureDropReadable 12;
    (* core func 11: the stdio future *)
    ECanonFutureRead (16, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 12 *)
    ECanonFutureDropReadable 16;
    (* core func 13: the fs future *)
    ECanonResourceDrop 6;
    (* core func 14: descriptor *)
    (* the fs lowers reference the aliased component funcs 3-11, the
       preopens/random/environment doors 12-16. Every fs door carries
       the error-code variant whose `other` payload is an option of
       string, so the host may write strings through any of them — the
       realloc and utf8 options ride all nine *)
    ECanonLower (3, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 15: fs read-via-stream *)
    ECanonLower (4, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 16: fs write-via-stream *)
    ECanonLower (5, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 17: fs append-via-stream *)
    ECanonLower (6, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 18: read-directory *)
    ECanonLower (7, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 19: create-directory-at *)
    ECanonLower (8, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 20: open-at *)
    ECanonLower (9, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 21: remove-directory-at *)
    ECanonLower (10, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 22: rename-at *)
    ECanonLower (11, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 23: unlink-file-at *)
    ECanonLower (12, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 24: get-directories — the host allocates the list *)
    ECanonLower (13, { mem = Some 0; realloc = Some 0; str_utf8 = false });
    (* core func 25: get-random-bytes *)
    ECanonLower (14, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 26: get-environment *)
    ECanonLower (15, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 27: get-arguments *)
    ECanonLower (16, { mem = Some 0; realloc = Some 0; str_utf8 = true });
    (* core func 28: get-initial-cwd *)
    (* the synthetic instances the with-args map the guest's import
       module names onto *)
    ECoreInlineExports [ ("write-via-stream", CoreFuncE 1) ];
    (* core instance 1 *)
    ECoreInlineExports [ ("write-via-stream", CoreFuncE 2) ];
    (* core instance 2 *)
    ECoreInlineExports [ ("exit-with-code", CoreFuncE 3) ];
    (* core instance 3 *)
    ECoreInlineExports
      [
        ("new", CoreFuncE 4);
        ("write", CoreFuncE 5);
        ("read", CoreFuncE 6);
        ("read-dir-entries", CoreFuncE 9);
        ("drop-writable", CoreFuncE 7);
        ("drop-readable", CoreFuncE 8);
        ("drop-readable-dir", CoreFuncE 10);
        ("future-drop-readable", CoreFuncE 11);
      ];
    (* core instance 4: the stream builtins *)
    ECoreInlineExports
      [ ("read", CoreFuncE 12); ("drop-readable", CoreFuncE 13) ];
    (* core instance 5: the fs future's *)
    ECoreInlineExports [ ("descriptor-drop", CoreFuncE 14) ];
    (* core instance 6 *)
    ECoreInlineExports
      [
        ("[method]descriptor.read-via-stream", CoreFuncE 15);
        ("[method]descriptor.write-via-stream", CoreFuncE 16);
        ("[method]descriptor.append-via-stream", CoreFuncE 17);
        ("[method]descriptor.read-directory", CoreFuncE 18);
        ("[method]descriptor.create-directory-at", CoreFuncE 19);
        ("[method]descriptor.open-at", CoreFuncE 20);
        ("[method]descriptor.remove-directory-at", CoreFuncE 21);
        ("[method]descriptor.rename-at", CoreFuncE 22);
        ("[method]descriptor.unlink-file-at", CoreFuncE 23);
      ];
    (* core instance 7: the fs types interface *)
    ECoreInlineExports [ ("get-directories", CoreFuncE 24) ];
    (* core instance 8 *)
    ECoreInlineExports [ ("get-random-bytes", CoreFuncE 25) ];
    (* core instance 9 *)
    ECoreInlineExports
      [
        ("get-environment", CoreFuncE 26);
        ("get-arguments", CoreFuncE 27);
        ("get-initial-cwd", CoreFuncE 28);
      ];
    (* core instance 10: the environment interface *)
    ECoreModule core_module_binary;
    (* core module 1 *)
    ECoreInstantiate
      ( 1,
        [
          ("wasi:cli/stdout@0.3.0", 1);
          ("wasi:cli/stderr@0.3.0", 2);
          ("wasi:cli/exit@0.3.0", 3);
          ("stream", 4);
          ("future", 5);
          ("resource", 6);
          ("wasi:filesystem/types@0.3.0", 7);
          ("wasi:filesystem/preopens@0.3.0", 8);
          ("wasi:random/random@0.3.0", 9);
          ("wasi:cli/environment@0.3.0", 10);
          ("prov", 0);
        ] );
    (* core instance 11 *)
    EAliasCoreExport (CoreFuncE 0, 11, "run");
    (* core func 27 *)
    EType (CResult (None, None));
    (* type 20: the bare result *)
    EType (CFunc { async_ = true; params = []; result = Some (TypeRef 20) });
    (* type 21 *)
    ECanonLift (29, 21);
    (* func 14: the sync lift of the async-typed run *)
    EExportInstance ("wasi:cli/run@0.3.0", [ ("run", 17) ]);
    (* instance 8 + export *)
  ]

(* ---- The binary writer ---- *)

let sort_core_func = 0x00
let sort_core_memory = 0x02

(* A component valtype: a type index (non-negative LEB), a primitive,
   or a resource handle type. *)
let valtype_bytes (buf : Buffer.t) (v : valtype) =
  match v with
  | TypeRef i -> Emo_wat.leb_u buf i
  | Prim U8 -> Buffer.add_char buf '\x7d'
  | Prim U64 -> Buffer.add_char buf '\x77'
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
  | CFlags labels ->
      Buffer.add_char buf '\x6e';
      Emo_wat.leb_u buf (List.length labels);
      List.iter (fun c -> Emo_wat.encode_name buf c) labels
  | CVariant cases ->
      Buffer.add_char buf '\x71';
      Emo_wat.leb_u buf (List.length cases);
      List.iter
        (fun (c, payload) ->
          Emo_wat.encode_name buf c;
          opt_valtype buf payload;
          (* the case's trailing zero byte — the spec reserves it, and
             the reference binary carries it on every case *)
          Buffer.add_char buf '\x00')
        cases
  | CRecord fields ->
      Buffer.add_char buf '\x72';
      Emo_wat.leb_u buf (List.length fields);
      List.iter
        (fun (n, v) ->
          Emo_wat.encode_name buf n;
          valtype_bytes buf v)
        fields
  | CList v ->
      Buffer.add_char buf '\x70';
      valtype_bytes buf v
  | CTuple vs ->
      Buffer.add_char buf '\x6f';
      Emo_wat.leb_u buf (List.length vs);
      List.iter (valtype_bytes buf) vs
  | COption v ->
      Buffer.add_char buf '\x6b';
      valtype_bytes buf v
  | COwn i ->
      Buffer.add_char buf '\x69';
      Emo_wat.leb_u buf i
  | CBorrow i ->
      Buffer.add_char buf '\x68';
      Emo_wat.leb_u buf i
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
  | InnerExportResource name ->
      Buffer.add_char buf '\x04';
      plain_name buf name;
      Buffer.add_char buf '\x03';
      Buffer.add_char buf '\x01'
      (* the sub-resource bound — the fresh abstract type the handles refer to *)
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
  (* The option vector: string-encoding (the utf8 default, emitted
     wherever wit-component emits it), the memory, the realloc — the
     order wit-component's own output carries. *)
  let opts (o : canon_opts) =
    let count =
      (if o.str_utf8 then 1 else 0)
      + (if o.mem <> None then 1 else 0)
      + if o.realloc <> None then 1 else 0
    in
    Emo_wat.leb_u buf count;
    if o.str_utf8 then Buffer.add_char buf '\x00';
    (match o.mem with
    | Some m ->
        Buffer.add_char buf '\x03';
        Emo_wat.leb_u buf m
    | None -> ());
    match o.realloc with
    | Some f ->
        Buffer.add_char buf '\x04';
        Emo_wat.leb_u buf f
    | None -> ()
  in
  match c with
  | ECanonLower (f, o) ->
      Buffer.add_string buf "\x01\x00";
      Emo_wat.leb_u buf f;
      opts o
  | ECanonStreamNew t ->
      Buffer.add_char buf '\x0e';
      Emo_wat.leb_u buf t
  | ECanonStreamWrite (t, o) ->
      Buffer.add_char buf '\x10';
      Emo_wat.leb_u buf t;
      opts o
  | ECanonStreamRead (t, o) ->
      Buffer.add_char buf '\x0f';
      Emo_wat.leb_u buf t;
      opts o
  | ECanonStreamDropWritable t ->
      Buffer.add_char buf '\x14';
      Emo_wat.leb_u buf t
  | ECanonStreamDropReadable t ->
      Buffer.add_char buf '\x13';
      Emo_wat.leb_u buf t
  | ECanonFutureRead (t, o) ->
      Buffer.add_char buf '\x16';
      Emo_wat.leb_u buf t;
      opts o
  | ECanonFutureDropReadable t ->
      Buffer.add_char buf '\x1a';
      Emo_wat.leb_u buf t
  | ECanonResourceDrop t ->
      Buffer.add_char buf '\x03';
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
  | ECanonLower _ | ECanonStreamNew _ | ECanonStreamWrite _ | ECanonStreamRead _
  | ECanonStreamDropWritable _ | ECanonStreamDropReadable _ | ECanonFutureRead _
  | ECanonFutureDropReadable _ | ECanonResourceDrop _ | ECanonLift _ ->
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
  | ECanonLower _ | ECanonStreamNew _ | ECanonStreamWrite _ | ECanonStreamRead _
  | ECanonStreamDropWritable _ | ECanonStreamDropReadable _ | ECanonFutureRead _
  | ECanonFutureDropReadable _ | ECanonResourceDrop _ | ECanonLift _ ->
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
  | Prim U64 -> "u64"
  | Prim Str -> "string"

let rec ctype_text (t : ctype) : string =
  match t with
  | CEnum cases ->
      Printf.sprintf "(enum %s)"
        (String.concat " " (List.map (fun c -> "\"" ^ c ^ "\"") cases))
  | CFlags labels ->
      Printf.sprintf "(flags %s)"
        (String.concat " " (List.map (fun c -> "\"" ^ c ^ "\"") labels))
  | CVariant cases ->
      Printf.sprintf "(variant %s)"
        (String.concat " "
           (List.map
              (fun (c, payload) ->
                match payload with
                | None -> Printf.sprintf "(case %S)" c
                | Some v -> Printf.sprintf "(case %S %s)" c (valtype_text v))
              cases))
  | CRecord fields ->
      Printf.sprintf "(record %s)"
        (String.concat " "
           (List.map
              (fun (n, v) -> Printf.sprintf "(field %S %s)" n (valtype_text v))
              fields))
  | CList v -> Printf.sprintf "(list %s)" (valtype_text v)
  | CTuple vs ->
      Printf.sprintf "(tuple %s)" (String.concat " " (List.map valtype_text vs))
  | COption v -> Printf.sprintf "(option %s)" (valtype_text v)
  | COwn i -> Printf.sprintf "(own %d)" i
  | CBorrow i -> Printf.sprintf "(borrow %d)" i
  | CResult (ok, err) ->
      let ok_text =
        match ok with None -> "" | Some v -> " " ^ valtype_text v
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
        (* one (param label type) group per parameter — the text
           format's parser reads each group separately *)
        String.concat ""
          (List.map
             (fun (l, v) -> Printf.sprintf " (param %S %s)" l (valtype_text v))
             params)
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
  | InnerExportResource name ->
      Printf.sprintf "(export %S (type (sub resource)))" name
  | InnerExportFunc (name, idx) ->
      Printf.sprintf "(export %S (func (type %d)))" name idx

let core_extern_text (e : core_extern) : string =
  match e with
  | CoreFuncE i -> Printf.sprintf "(core func $cf%d)" i
  | CoreMemoryE i -> Printf.sprintf "(core memory $cm%d)" i

let entry_text (indent : string) (e : entry) : string =
  let opts_text (o : canon_opts) =
    String.concat ""
      [
        (if o.str_utf8 then " string-encoding=utf8" else "");
        (match o.mem with
        | Some m -> Printf.sprintf " (memory %d)" m
        | None -> "");
        (match o.realloc with
        | Some f -> Printf.sprintf " (realloc %d)" f
        | None -> "");
      ]
  in
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
  | ECanonLower (f, o) ->
      Printf.sprintf "%s(core func (canon lower (func %d)%s))\n" indent f
        (opts_text o)
  | ECanonStreamNew t ->
      Printf.sprintf "%s(core func (canon stream.new (type %d)))\n" indent t
  | ECanonStreamWrite (t, o) ->
      Printf.sprintf "%s(core func (canon stream.write (type %d)%s))\n" indent t
        (opts_text o)
  | ECanonStreamRead (t, o) ->
      Printf.sprintf "%s(core func (canon stream.read (type %d)%s))\n" indent t
        (opts_text o)
  | ECanonStreamDropWritable t ->
      Printf.sprintf "%s(core func (canon stream.drop-writable (type %d)))\n"
        indent t
  | ECanonStreamDropReadable t ->
      Printf.sprintf "%s(core func (canon stream.drop-readable (type %d)))\n"
        indent t
  | ECanonFutureRead (t, o) ->
      Printf.sprintf "%s(core func (canon future.read (type %d)%s))\n" indent t
        (opts_text o)
  | ECanonFutureDropReadable t ->
      Printf.sprintf "%s(core func (canon future.drop-readable (type %d)))\n"
        indent t
  | ECanonResourceDrop t ->
      Printf.sprintf "%s(core func (canon resource.drop (type %d)))\n" indent t
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
