(* The riscv64 target: emit RV64 assembly text for the GNU cross
   binutils to assemble and link into one freestanding ELF
   (plan/step-19-riscv64.md). Boot profile A: under
   `qemu-system-riscv64 -machine virt`, OpenSBI enters the payload at
   0x80200000 in S-mode with a0 = hart id and a1 = the DTB pointer, and
   the legacy ecalls (a7 = 1 console putchar, a7 = 8 shutdown) are the
   runtime's whole IO — the console one only until a kernel package's
   boot stub parks a driver entry in `emo_console_hook` (EmoOS T3.5);
   the shutdown ecall stays for every image.

   The value model (T19.2/T19.3): a dynamic value is one tagged machine
   word. Heap pointers carry their kind in bits 4:1 (bit 0 clear) — 0
   Int64 cell, 1 Float64 cell, 2 String, 3 Tuple, 4 Array, 5 Box,
   6 Closure, 7 Instance, 8 Atomic — so every block is 32-byte aligned
   and the five low bits are free; every block is [header word][payload],
   the header naming the payload size for a future precise GC:

     Int64/Float64  [header][bits]
     String         [header][length][bytes padded to 8]
     Tuple/Array    [header][length][elements...]
     Box/Atomic     [header][value]
     Closure        [header][code][captures...]
     Instance       [header][class id][fields...]

  Bool, Char, Byte, and enum members are immediates (bit 0 set; kind in
  bits 3:1: 0 Bool, 1 Char, 2 Enum — enum members carry a program-wide
  member id above bit 3 — 3 Byte, the eight bits in bits 11:4), so an
  immediate is never a valid pointer.
   Int64/Float64 are boxed: the decided wrap-around semantics need all
   2⁶⁴ bit patterns — a numeric literal is a static read-only cell in
   .rodata, so the heap holds computed values only. Equality is content
   equality (emo_eq_deep).
   Method dispatch: a class-typed receiver calls its mangled method
   directly; an interface-typed receiver goes through a static
   per-interface table indexed by class id; `is` compares class ids or
   probes the table. The heap is a bump allocator over a fixed .bss
   region; exhaustion is a loud runtime failure.

   Correctness first: every local lives in a stack slot (the wasm
   target's implicit stack machine), the psABI is the internal calling
   convention (a closure's record rides in t0), and a call in return
   position lowers to `tail`/`jalr x0` after restoring sp — the
   guaranteed tail call. Expression temporaries are depth-indexed
   slots; field access always untags first (andi -32).

   The typed calling convention (EmoOS T2.1, Stage B's first half): a
   top-level def whose signature is fully typed takes raw-register
   params and results — Int64 as the raw payload in the integer bank
   (a0–a7), Float64 as the raw bits in the float bank (fa0–fa7), every
   other type the tagged word both conventions share — while bodies
   still emit dynamic, so boxing adapters stand at every
   typed↔dynamic boundary: the callee's entry boxes its raw params
   into cells, its exit unboxes the tagged result, and a call site
   unboxes its Int64/Float64 args and boxes a raw result back.
   Methods, constructors, and closures keep the dynamic convention —
   the runtime's name dispatch passes tagged words and cannot know a
   signature. T2.2's typed bodies are what melt the adapters away
   until a value truly escapes. *)

(* ---- The typed calling convention (EmoOS T2.1) ----

   The register classes a signature maps onto, and the conventions'
   agreement rule: only Int64 and Float64 change representation across
   the boundary — every other statically known type is the tagged word
   the dynamic convention already passes. *)

type param_kind =
  | P_int64 (* the raw payload, integer bank a0.. *)
  | P_float64 (* the raw double bits, float bank fa0.. *)
  | P_word (* the tagged word both conventions share, integer bank *)

type result_kind =
  | R_int64 (* the raw payload in a0 *)
  | R_float64 (* the raw double bits in fa0 *)
  | R_word (* the tagged word in a0 — the dynamic convention's result *)
  | R_void (* nothing *)

type conv = { cparams : param_kind list; cresult : result_kind }

let dynamic_conv (n : int) : conv =
  { cparams = List.init n (fun _ -> P_word); cresult = R_word }

(* A def qualifies when the checker pinned every parameter type and the
   result; an Unknown anywhere keeps the dynamic convention. *)
let conv_of (f : Emo_ir.func) : conv option =
  if f.Emo_ir.fforeign <> None then None
  else if
    List.exists (fun (_, t) -> t = Emo_check.Unknown) f.Emo_ir.fparams
    || f.Emo_ir.fresult = Emo_check.Unknown
  then None
  else
    Some
      {
        cparams =
          List.map
            (fun (_, t) ->
              match t with
              | Emo_check.Int64 -> P_int64
              | Emo_check.Float64 -> P_float64
              | _ -> P_word)
            f.Emo_ir.fparams;
        cresult =
          (match f.Emo_ir.fresult with
          | Emo_check.Int64 -> R_int64
          | Emo_check.Float64 -> R_float64
          | Emo_check.Void -> R_void
          | _ -> R_word);
      }

(* Each parameter's bank register: the integer bank counts the
   non-float parameters, the float bank the Float64 ones, each from
   zero — the psABI's two independent banks. *)
let bank_assign (kinds : param_kind list) : (param_kind * int) list =
  let rec go kinds i f acc =
    match kinds with
    | [] -> List.rev acc
    | k :: rest ->
        let acc = (k, if k = P_float64 then f else i) :: acc in
        go rest
          (if k = P_float64 then i else i + 1)
          (if k = P_float64 then f + 1 else f)
          acc
  in
  go kinds 0 0 []

(* A tail call may replace this function's return only when the
   callee's result representation is the one this function's own
   caller expects; Void and the tagged word agree because nobody
   reads the register. *)
let result_compatible (a : result_kind) (b : result_kind) : bool =
  a = b || (a = R_word && b = R_void) || (a = R_void && b = R_word)

type frame = {
  fbuf : Buffer.t;
  mutable slots : (string * int) list; (* name -> slot index *)
  mutable named : int; (* the named slot count, fixed by the pre-pass *)
  mutable temps : int; (* the temp slot count (the expression-depth bound) *)
  ret : string; (* the epilogue label *)
  mutable size : int; (* the frame size in bytes *)
  fconv : conv; (* this function's calling convention (T2.1) *)
  mutable raw : (string * Emo_check.t) list;
      (* in a native body (T2.2): the locals whose slots hold raw
         Int64/Float64 payloads instead of tagged cells — typed params
         and numeric-typed bindings; a pattern binding holds the tagged
         scrutinee word and drops any name it rebinds *)
}

type class_info = {
  cls_display : string;
  cls_id : int;
  cls_fields : string list; (* in init-assignment order *)
  cls_methods : (string * string) list; (* display name -> mangled fname *)
}

(* What a spawned process runs (T3.3): a def — mangled name and its
   calling convention, so the thunk hands over the psABI registers —
   or a closure value, the spawn's first argument, called like any
   first-class block. *)
type spawn_callee =
  | Spawn_def of string * conv
  | Spawn_closure of int (* the argument count after the closure word *)

type env = {
  buf : Buffer.t;
  mutable fresh : int; (* the string-literal counter *)
  mutable strs : (string * string) list; (* label, bytes — newest first *)
  mutable cells : (int64 * int * string) list;
      (* the numeric literal cells: bits, tag, label — newest first; one
         static read-only cell per distinct literal *)
  mutable labels : int; (* the fresh-label counter *)
  mutable cur : frame option;
  mutable fclass : string option; (* the class whose method is emitting *)
  mutable deferred :
    (string * (string * Emo_check.t) list * string list * Emo_ir.stmt list) list;
  (* closure bodies queued for emission: label, params, capture names,
     body *)
  classes : (string * class_info) list; (* display name -> info *)
  ifaces : (string * (string * int) list) list; (* display -> method/arity *)
  mutable enums : ((string * string) * int) list; (* (enum, member) -> id *)
  mutable loops : (string * string) list;
      (* each enclosing loop's (exit label, continue label), innermost
         first: break jumps to the exit, continue to the head — or to
         the post label, on a `for`, so the post runs first *)
  fforeigns : string list;
      (* `foreign def` names: the binding is skipped, a call refuses *)
  fsigs : (string * conv) list;
      (* mangled def name -> its typed calling convention; a name absent
         here (a method, a constructor, a closure, a dynamic-signature
         def) uses the dynamic convention (T2.1) *)
  mutable native : bool;
      (* emitting a typed body right now (T2.2): expressions follow the
         representation rule — Int64 raw in a0, Float64 raw in fa0,
         everything else the tagged word — and boxing happens only at
         the escape points. Outside, the dynamic rule holds: everything
         tagged in a0. *)
  mutable spawns : (string * spawn_callee) list;
      (* the spawn entry thunks queued for emission (T3.3): label,
         callee — newest first *)
}

let gput env fmt = Printf.ksprintf (Buffer.add_string env.buf) fmt

let put env fmt =
  match env.cur with
  | Some f -> Printf.ksprintf (Buffer.add_string f.fbuf) fmt
  | None -> invalid_arg "riscv: no function frame"

(* Emission-time refusal, the wasm/beam style: the checker admitted the
   program, this target cannot honor it yet, and the message names the
   construct. *)
let refuse what =
  raise
    (Emo_ir.Lower_error ("the riscv64 target does not support " ^ what ^ " yet"))

(* ---- Tags and immediates ---- *)

let tag_float64 = 2
let tag_string = 4
let tag_tuple = 6
let tag_array = 8
let tag_box = 10
let tag_closure = 12
let tag_instance = 14
let tag_atomic = 16
let bool_false = 1 (* immediate: kind 0 in bits 3:1, payload bit 4 = 0 *)
let bool_true = 17 (* kind 0 in bits 3:1, payload bit 4 *)
let char_imm (c : char) : int = (Char.code c lsl 4) lor 0b0011

(* Bytes: kind 3 in bits 3:1, the eight bits in bits 11:4 — the lane
   `peek8` reads and `poke8` writes (docs/raw-memory.md). *)
let byte_imm (n : int) : int = (n lsl 4) lor 0b0111

(* Enum members: kind 2 in bits 3:1, the member id above bit 3. *)
let enum_imm env enum_name member =
  match List.assoc_opt (enum_name, member) env.enums with
  | Some id -> 0b0101 lor (id lsl 4)
  | None -> refuse (Printf.sprintf "the enum member `%s.%s`" enum_name member)

(* ---- Fresh names ---- *)

let string_label env (s : string) : string =
  let label = Printf.sprintf "emo_str_%d" env.fresh in
  env.fresh <- env.fresh + 1;
  env.strs <- (label, s) :: env.strs;
  label

(* An Int64 or Float64 literal is an immutable cell, so it lives once in
   .rodata — [header][bits], 32-byte aligned like every block — and an
   evaluation is its address, not an allocation. The heap is spent on
   computed values only. *)
let cell_label env (bits : int64) (tag : int) : string =
  match
    List.find_opt (fun (b, t, _) -> Int64.equal b bits && t = tag) env.cells
  with
  | Some (_, _, label) -> label
  | None ->
      let label = Printf.sprintf "emo_cell_%d" (List.length env.cells) in
      env.cells <- (bits, tag, label) :: env.cells;
      label

let fresh_label env base =
  env.labels <- env.labels + 1;
  Printf.sprintf ".L%s_%d" base env.labels

let func_label (fname : string) : string = "emo_" ^ fname

(* The current program's const thunks (mangled names); set by [emit].
   Each memoizes into a .data flag/value pair (see
   [emit_const_function]). *)
let const_thunks : string list ref = ref []

(* ---- Class metadata ---- *)

let class_of env display =
  match List.assoc_opt display env.classes with
  | Some c -> c
  | None -> refuse (Printf.sprintf "the class `%s`" display)

(* A class field's index: the init-assignment order. *)
let field_index env obj_ety name =
  let display =
    match obj_ety with
    | Emo_check.ClassType d -> d
    | _ -> (
        match env.fclass with
        | Some d -> d
        | None -> refuse "a field access outside a class body")
  in
  let c = class_of env display in
  match List.find_index (fun f -> String.equal f name) c.cls_fields with
  | Some i -> i
  | None -> refuse (Printf.sprintf "the field `%s` of `%s`" name c.cls_display)

(* ---- Slots ---- *)

let slot_offset env name =
  match env.cur with
  | Some f -> (
      match List.assoc_opt name f.slots with
      | Some i -> 8 + (8 * i)
      | None ->
          refuse
            (Printf.sprintf
               "a reference to `%s` here (module-level constants shared with \
                defs land later)"
               name))
  | None -> invalid_arg "riscv: no function frame"

let temp_offset env depth =
  match env.cur with
  | Some f -> 8 + (8 * (f.named + depth))
  | None -> invalid_arg "riscv: no function frame"

(* ---- The pre-pass ---- *)

(* The free names a closure body reads: everything referenced that the
   body does not bind itself. Capture is by value — mutable state is
   Box's job. First-reference order. *)
let rec closure_free ~(cparams : (string * Emo_check.t) list)
    (body : Emo_ir.stmt list) : string list =
  let referenced = ref [] in
  let add n =
    if not (List.mem n !referenced) then referenced := n :: !referenced
  in
  let bound = ref (List.map fst cparams) in
  let rec ex (e : Emo_ir.expr) =
    match e.Emo_ir.desc with
    | Var n -> add n
    | Unary (_, x) -> ex x
    | Binary (_, l, r) ->
        ex l;
        ex r
    | Cond { c; t; e } ->
        ex c;
        ex t;
        ex e
    | Interpolate es -> List.iter ex es
    | Tuple es | Array_lit es -> List.iter ex es
    | Map_lit pairs -> List.iter ex pairs
    | Index (b, i) ->
        ex b;
        ex i
    | Field_read { obj; _ } -> ex obj
    | Call { args; _ } -> List.iter ex args
    | Call_value { f; args } ->
        ex f;
        List.iter ex args
    | Method { self_; args; _ } ->
        ex self_;
        List.iter ex args
    | Builtin { args; _ } | Runtime_impl { args; _ } -> List.iter ex args
    | Box_new x | Atomic_new x | Bytes_new x | List_new x -> ex x
    | Builder_new -> ()
    | Make_exception { message; data } ->
        ex message;
        Option.iter ex data
    | Do_spawn { args; _ } -> List.iter ex args
    | Spawn_value { f; args } ->
        ex f;
        List.iter ex args
    | Closure { cbody; _ } -> List.iter st cbody
    | Make_enum _ -> ()
    | Const _ | Type_ref _ | Global _ | Global_var _ -> ()
  and st (s : Emo_ir.stmt) =
    match s with
    | Effect e -> ex e
    | Let { name; init; _ } ->
        ex init;
        bound := name :: !bound
    | Assign_var { name; value } ->
        ex value;
        bound := name :: !bound
    | Set_global_var { value; _ } -> ex value
    | Set_field { self_; value; _ } ->
        ex self_;
        ex value
    | If { cond; then_; else_ } ->
        ex cond;
        List.iter st then_;
        List.iter st else_
    | Case { scrutinee; branches } ->
        ex scrutinee;
        List.iter
          (fun (b : Emo_ir.branch) ->
            Option.iter ex b.Emo_ir.guard;
            List.iter st b.Emo_ir.body)
          branches
    | Receive { branches } ->
        List.iter
          (fun (b : Emo_ir.branch) ->
            Option.iter ex b.Emo_ir.guard;
            List.iter st b.Emo_ir.body)
          branches
    | Send { target; message } ->
        ex target;
        ex message
    | Raise _ -> ()
    | Return_stmt e -> ex e
    | While { cond; body; _ } ->
        ex cond;
        List.iter st body
    | For { init; post; body; _ } ->
        List.iter st [ init; post ];
        List.iter st body
    | Break | Continue -> ()
  in
  List.iter st body;
  List.filter
    (fun n -> List.mem n !referenced && not (List.mem n !bound))
    (List.rev !referenced)

(* How many temp slots an expression needs: each node spills into its
   own depth region and evaluates its children one region deeper.
   Sequential forms (Cond arms, statement bodies) reuse the region, so
   they take a max, not a sum. *)
let rec expr_depth (e : Emo_ir.expr) : int =
  match e.Emo_ir.desc with
  | Binary (_, l, r) -> 1 + max (expr_depth l) (expr_depth r)
  | Unary (_, x) -> expr_depth x
  | Cond { c; t; e } -> max (expr_depth c) (max (expr_depth t) (expr_depth e))
  | Call { args; _ } ->
      let child =
        match args with
        | [] -> 0
        | args -> List.fold_left (fun acc a -> max acc (expr_depth a)) 0 args
      in
      List.length args + child
  | Call_value { f; args } ->
      1 + List.length args
      + List.fold_left (fun acc a -> max acc (expr_depth a)) 0 (f :: args)
  | Interpolate es -> (
      2 + List.length es
      +
      match es with
      | [] -> 0
      | es -> List.fold_left (fun acc a -> max acc (expr_depth a)) 0 es)
  | Closure { cparams; cbody } ->
      let caps = closure_free ~cparams cbody in
      List.length caps + 1
  | Builtin { args; _ } | Runtime_impl { args; _ } ->
      let child =
        match args with
        | [] -> 0
        | args -> List.fold_left (fun acc a -> max acc (expr_depth a)) 0 args
      in
      List.length args + child
  | Tuple es | Array_lit es ->
      let child =
        match es with
        | [] -> 0
        | es -> List.fold_left (fun acc a -> max acc (expr_depth a)) 0 es
      in
      List.length es + child
  | Index (b, i) -> 1 + max (expr_depth b) (expr_depth i)
  | Field_read { obj; _ } -> 1 + expr_depth obj
  | Method { self_; args; _ } ->
      1 + List.length args
      + List.fold_left (fun acc a -> max acc (expr_depth a)) 0 (self_ :: args)
  | Box_new x | Atomic_new x -> 1 + expr_depth x
  | Do_spawn { args; _ } ->
      List.length args
      + List.fold_left (fun acc a -> max acc (expr_depth a)) 0 args
  | Spawn_value { f; args } ->
      1 + List.length args
      + List.fold_left (fun acc a -> max acc (expr_depth a)) 0 (f :: args)
  | _ -> 0

(* The names a pattern binds, in binding order. *)
let rec pattern_bindings (p : Emo_ast.pattern) : string list =
  match p.Emo_ast.pattern_desc with
  | Emo_ast.Pattern_binding n -> [ n ]
  | Emo_ast.Tuple_pattern ps -> List.concat_map pattern_bindings ps
  | _ -> []

let rec stmts_depth (stmts : Emo_ir.stmt list) : int =
  List.fold_left
    (fun acc (s : Emo_ir.stmt) ->
      max acc
        (match s with
        | Effect e -> expr_depth e
        | Let { init; _ } -> expr_depth init
        | Assign_var { value; _ } -> expr_depth value
        | Set_global_var { value; _ } -> expr_depth value
        | Set_field { self_; value; _ } ->
            1 + max (expr_depth self_) (expr_depth value)
        | If { cond; then_; else_ } ->
            max (expr_depth cond) (max (stmts_depth then_) (stmts_depth else_))
        | Return_stmt e -> expr_depth e
        | Case { scrutinee; branches } ->
            3
            + max (expr_depth scrutinee)
                (List.fold_left
                   (fun acc (b : Emo_ir.branch) ->
                     max acc
                       (match b.Emo_ir.guard with
                       | Some g ->
                           max (expr_depth g) (stmts_depth b.Emo_ir.body)
                       | None -> stmts_depth b.Emo_ir.body))
                   0 branches)
        | While { cond; body; _ } -> max (expr_depth cond) (stmts_depth body)
        | For { init; cond; post; body; _ } ->
            max (expr_depth cond) (stmts_depth (init :: post :: body))
        | Send { target; message } ->
            1 + max (expr_depth target) (expr_depth message)
        | Receive { branches } ->
            (* the scan keeps its index in s0; the pattern machinery
               owns slots 0-2 and guards evaluate at depth 3 *)
            3
            + List.fold_left
                (fun acc (b : Emo_ir.branch) ->
                  max acc
                    (match b.Emo_ir.guard with
                    | Some g -> max (expr_depth g) (stmts_depth b.Emo_ir.body)
                    | None -> stmts_depth b.Emo_ir.body))
                0 branches
        | Break | Continue -> 0
        | _ -> 0))
    0 stmts

(* Register every binding of the body, in bind order: Let bindings and
   the case patterns' bindings (branches are exclusive but each keeps
   its own slot). *)
let rec collect_stmt (f : frame) (s : Emo_ir.stmt) : unit =
  match s with
  | Let { name; _ } ->
      if not (List.mem_assoc name f.slots) then begin
        f.slots <- (name, List.length f.slots) :: f.slots;
        f.named <- f.named + 1
      end
  | If { then_; else_; _ } ->
      collect_stmts f then_;
      collect_stmts f else_
  | Case { branches; _ } ->
      List.iter
        (fun (b : Emo_ir.branch) ->
          List.iter
            (fun n ->
              if not (List.mem_assoc n f.slots) then begin
                f.slots <- (n, List.length f.slots) :: f.slots;
                f.named <- f.named + 1
              end)
            (pattern_bindings b.Emo_ir.pattern);
          collect_stmts f b.Emo_ir.body)
        branches
  | Receive { branches } ->
      List.iter
        (fun (b : Emo_ir.branch) ->
          List.iter
            (fun n ->
              if not (List.mem_assoc n f.slots) then begin
                f.slots <- (n, List.length f.slots) :: f.slots;
                f.named <- f.named + 1
              end)
            (pattern_bindings b.Emo_ir.pattern);
          collect_stmts f b.Emo_ir.body)
        branches
  | While { body; _ } -> collect_stmts f body
  | For { init; post; body; _ } -> collect_stmts f (init :: post :: body)
  | _ -> ()

and collect_stmts (f : frame) (stmts : Emo_ir.stmt list) : unit =
  match stmts with
  | [] -> ()
  | s :: rest ->
      collect_stmt f s;
      collect_stmts f rest

(* ---- Expression emission: the result arrives in a0 ---- *)

(* [d] is the expression's temp-slot depth: this node's own spill
   region starts at slot d, its children evaluate at deeper regions. *)

let call_runtime env name = put env "    call %s\n" name

(* ---- The escape-point adapters (T2.2) ---- *)

(* Typed → dynamic: a raw numeric value boxes into the tagged cell the
   dynamic consumer reads. A no-op outside native bodies (where values
   are tagged already) and on every other type (whose tagged word is
   the value). Clobbers t0/ra through the helper — insert before the
   spill, never over a live t0. *)
let box_if_numeric env (t : Emo_check.t) : unit =
  if env.native then
    match t with
    | Emo_check.Int64 -> call_runtime env "emo_box_i64"
    | Emo_check.Float64 -> call_runtime env "emo_box_f64"
    | _ -> ()

(* Dynamic → typed: a dynamic producer left the tagged word in a0; the
   raw numeric consumer reads the payload. *)
let unbox_if_numeric env (t : Emo_check.t) : unit =
  if env.native then
    match t with
    | Emo_check.Int64 ->
        put env "    andi a0, a0, -32\n";
        put env "    ld a0, 8(a0)\n"
    | Emo_check.Float64 ->
        put env "    andi t0, a0, -32\n";
        put env "    fld fa0, 8(t0)\n"
    | _ -> ()

let rec emit_expr env d (e : Emo_ir.expr) : unit =
  match e.Emo_ir.desc with
  | Const (Emo_ast.L_int i) ->
      (* native: the raw payload; dynamic: the static read-only cell *)
      if env.native then put env "    li a0, %Ld\n" i
      else put env "    la a0, %s\n" (cell_label env i 0)
  | Const (Emo_ast.L_bool b) ->
      put env "    li a0, %d\n" (if b then bool_true else bool_false)
  | Const (Emo_ast.L_char c) -> put env "    li a0, %d\n" (char_imm c)
  | Const (Emo_ast.L_byte n) -> put env "    li a0, %d\n" (byte_imm n)
  | Const (Emo_ast.L_float f) ->
      let cell = cell_label env (Int64.bits_of_float f) tag_float64 in
      if env.native then begin
        (* the raw bits into fa0, straight out of the read-only cell *)
        put env "    la t0, %s\n" cell;
        put env "    ld t0, 8(t0)\n";
        put env "    fmv.d.x fa0, t0\n"
      end
      else begin
        put env "    la a0, %s\n" cell;
        put env "    ori a0, a0, %d\n" tag_float64
      end
  | Const (Emo_ast.L_string s) ->
      let label = string_label env s in
      put env "    la a0, %s\n" label;
      put env "    li a1, %d\n" (String.length s);
      call_runtime env "emo_string_lit"
  | Var name -> (
      let slot = slot_offset env name in
      match env.cur with
      (* Native bodies honor the representation rule on every read: a
         raw local loads its payload; a tagged one — a pattern binding
         holds the boxed scrutinee — unboxes here, so a raw Int64/Float64
         reaches every consumer that trusts the rule. *)
      | Some f when env.native -> (
          if List.mem_assoc name f.raw then
            match List.assoc name f.raw with
            | Emo_check.Float64 -> put env "    fld fa0, %d(sp)\n" slot
            | _ -> put env "    ld a0, %d(sp)\n" slot
          else
            match e.Emo_ir.ety with
            | Emo_check.Int64 ->
                put env "    ld a0, %d(sp)\n" slot;
                put env "    andi a0, a0, -32\n";
                put env "    ld a0, 8(a0)\n"
            | Emo_check.Float64 ->
                put env "    ld a0, %d(sp)\n" slot;
                put env "    andi t0, a0, -32\n";
                put env "    fld fa0, 8(t0)\n"
            | _ -> put env "    ld a0, %d(sp)\n" slot)
      | _ -> put env "    ld a0, %d(sp)\n" slot)
  | Binary (op, l, r) ->
      emit_binary env d e.Emo_ir.ety ~boxed:(not env.native) op l r
  | Unary (op, x) -> emit_unary env d e.Emo_ir.ety ~boxed:(not env.native) op x
  | Cond { c; t; e } ->
      let l_else = fresh_label env "else" in
      let l_end = fresh_label env "endif" in
      emit_expr env d c;
      put env "    andi t0, a0, 16\n";
      put env "    beqz t0, %s\n" l_else;
      emit_expr env d t;
      put env "    j %s\n" l_end;
      put env "%s:\n" l_else;
      emit_expr env d e;
      put env "%s:\n" l_end
  | Call { func; args } -> (
      if List.mem func env.fforeigns then
        raise
          (Emo_ir.Lower_error
             (Printf.sprintf
                "the riscv64 target does not support a call to the foreign \
                 definition `%s` yet"
                func));
      match List.assoc_opt func env.fsigs with
      | Some conv -> emit_typed_call env d func conv args
      | None ->
          emit_args env d args;
          put env "    call %s\n" (func_label func);
          (* a dynamic callee answers the tagged word; a raw numeric
             consumer reads the payload *)
          unbox_if_numeric env e.Emo_ir.ety)
  | Call_value { f; args } ->
      let fslot = temp_offset env d in
      emit_expr env (d + 1) f;
      put env "    sd a0, %d(sp)\n" fslot;
      emit_args_from env (d + 1) ~from:0 args;
      put env "    ld t0, %d(sp)\n" fslot;
      put env "    andi t0, t0, -32\n";
      put env "    ld t2, 8(t0)\n";
      put env "    jalr t2\n";
      unbox_if_numeric env e.Emo_ir.ety
  | Spawn_value { f; args } ->
      (* `do f(...)` as a value: the closure word and the tagged
         arguments spill consecutively, and the thunk (queued below)
         calls the closure on the child's stack *)
      let fslot = temp_offset env d in
      emit_expr env (d + 1) f;
      put env "    sd a0, %d(sp)\n" fslot;
      List.iteri
        (fun i arg ->
          emit_expr env (d + 1 + List.length args) arg;
          box_if_numeric env arg.Emo_ir.ety;
          put env "    sd a0, %d(sp)\n" (temp_offset env (d + 1 + i)))
        args;
      let label = fresh_label env "spawn_thunk" in
      env.spawns <- (label, Spawn_closure (List.length args)) :: env.spawns;
      put env "    la a0, %s\n" label;
      put env "    li a1, %d\n" (List.length args + 1);
      put env "    addi a2, sp, %d\n" fslot;
      call_runtime env "emo_spawn"
  | Do_spawn { func; args } ->
      (* `do f(...)`: the arguments evaluate eagerly in the spawning
         process (the escape point boxes them), the thunk delivers them
         through the child's psABI registers or the dynamic words, and
         the answer is the child's Pid *)
      let n = List.length args in
      List.iteri
        (fun i arg ->
          emit_expr env (d + n) arg;
          box_if_numeric env arg.Emo_ir.ety;
          put env "    sd a0, %d(sp)\n" (temp_offset env (d + i)))
        args;
      let conv =
        match List.assoc_opt func env.fsigs with
        | Some conv -> conv
        | None -> dynamic_conv n
      in
      let label = fresh_label env "spawn_thunk" in
      env.spawns <- (label, Spawn_def (func, conv)) :: env.spawns;
      put env "    la a0, %s\n" label;
      put env "    li a1, %d\n" n;
      put env "    addi a2, sp, %d\n" (temp_offset env d);
      call_runtime env "emo_spawn"
  | Closure { cparams; cbody } -> emit_closure_creation env d cparams cbody
  | Interpolate parts -> emit_interpolate env d parts
  | Tuple es -> emit_seq env d es tag_tuple
  | Array_lit es -> emit_seq env d es tag_array
  | Index (b, i) -> emit_index env d b i
  | Field_read { obj; name } -> (
      match obj.Emo_ir.ety with
      | Emo_check.ClassType _ ->
          emit_expr env d obj;
          put env "    andi a0, a0, -32\n";
          let idx = field_index env obj.Emo_ir.ety name in
          put env "    ld a0, %d(a0)\n" (16 + (8 * idx))
      | _ ->
          (* a dynamic receiver: the field resolves by name through the
             class's field table (the c target's emo_field_by_name) *)
          let spill = temp_offset env d in
          emit_expr env (d + 1) obj;
          put env "    andi a0, a0, -32\n";
          put env "    sd a0, %d(sp)\n" spill;
          put env "    ld t0, 8(a0)\n";
          let nlabel = string_label env name in
          put env "    la a1, %s\n" nlabel;
          put env "    li a2, %d\n" (String.length name);
          call_runtime env "emo_field_index";
          put env "    ld t0, %d(sp)\n" spill;
          put env "    slli t1, a0, 3\n";
          put env "    add t0, t0, t1\n";
          put env "    ld a0, 16(t0)\n")
  | Method { self_; name; args } ->
      emit_method env d e.Emo_ir.ety ~boxed:(not env.native) self_ name args
  | Make_enum { enum_name; member } ->
      put env "    li a0, %d\n" (enum_imm env enum_name member)
  | Box_new arg ->
      emit_expr env (d + 1) arg;
      box_if_numeric env arg.Emo_ir.ety;
      call_runtime env "emo_box_new"
  | Atomic_new arg ->
      emit_expr env (d + 1) arg;
      box_if_numeric env arg.Emo_ir.ety;
      call_runtime env "emo_atomic_new"
  | Builtin { name = "println"; args = [ arg ] } ->
      emit_expr env d arg;
      box_if_numeric env arg.Emo_ir.ety;
      call_runtime env "emo_println"
  | Builtin { name = "halt"; args = [] } -> put env "    li a7, 8\n    ecall\n"
  | Builtin { name = "device_wait"; args = [] } ->
      (* T3.7: the kernel sleeps until the device world wakes it — the
         park is state 4 (device-wait), the resume is this call's own
         return, and the ISR's wake (emo_sched_wake_console) is what
         brings the process back. A send to a device-waiter does not
         wake it: requests queue in its mailbox for the next pump. *)
      call_runtime env "emo_park_console"
  | Builtin { name = "self_pid"; args = [] } -> call_runtime env "emo_self_pid"
  | Builtin { name = "fence"; args = [] } ->
      (* the full sequential-consistency barrier, ordinary and volatile
         accesses alike; `fence` answers nothing, like `halt` *)
      put env "    fence rw, rw\n"
  | Builtin { name = "peek8"; args = [ addr ] } ->
      emit_expr env (d + 1) addr;
      if env.native then begin
        (* the volatile byte load, inline: the raw address is already in
           a0, the answer is the Byte immediate — one instruction, in
           program order, nothing allocated (T2.3) *)
        put env "    lbu t0, 0(a0)\n";
        put env "    slli a0, t0, 4\n";
        put env "    ori a0, a0, 7\n"
      end
      else begin
        box_if_numeric env addr.Emo_ir.ety;
        call_runtime env "emo_peek8"
      end
  | Builtin { name = "peek64"; args = [ addr ] } ->
      emit_expr env (d + 1) addr;
      if env.native then
        (* the volatile word load, inline: raw address in, raw payload
           out — an MMIO read allocates nothing *)
        put env "    ld a0, 0(a0)\n"
      else begin
        box_if_numeric env addr.Emo_ir.ety;
        call_runtime env "emo_peek64";
        unbox_if_numeric env e.Emo_ir.ety
      end
  | Builtin { name = "poke8"; args = [ addr; value ] } ->
      let addr_slot = temp_offset env d in
      emit_expr env (d + 1) addr;
      if env.native then begin
        (* the volatile byte store, inline: raw address, the value's
           Byte immediate decodes with the shift *)
        put env "    sd a0, %d(sp)\n" addr_slot;
        emit_expr env (d + 1) value;
        put env "    srli t1, a0, 4\n";
        put env "    ld t0, %d(sp)\n" addr_slot;
        put env "    sb t1, 0(t0)\n"
      end
      else begin
        box_if_numeric env addr.Emo_ir.ety;
        put env "    sd a0, %d(sp)\n" addr_slot;
        emit_expr env (d + 1) value;
        box_if_numeric env value.Emo_ir.ety;
        put env "    mv a1, a0\n";
        put env "    ld a0, %d(sp)\n" addr_slot;
        call_runtime env "emo_poke8"
      end
  | Builtin { name = "poke64"; args = [ addr; value ] } ->
      let addr_slot = temp_offset env d in
      emit_expr env (d + 1) addr;
      if env.native then begin
        (* the volatile word store, inline: raw address, raw payload *)
        put env "    sd a0, %d(sp)\n" addr_slot;
        emit_expr env (d + 1) value;
        put env "    ld t0, %d(sp)\n" addr_slot;
        put env "    sd a0, 0(t0)\n"
      end
      else begin
        box_if_numeric env addr.Emo_ir.ety;
        put env "    sd a0, %d(sp)\n" addr_slot;
        emit_expr env (d + 1) value;
        box_if_numeric env value.Emo_ir.ety;
        put env "    mv a1, a0\n";
        put env "    ld a0, %d(sp)\n" addr_slot;
        call_runtime env "emo_poke64"
      end
  | Builtin { name; _ } -> refuse (Printf.sprintf "the `%s` builtin" name)
  | Runtime_impl { name; _ } ->
      refuse (Printf.sprintf "the `%s` runtime implementation" name)
  | _ -> refuse (describe_expr e)

(* Evaluate the args, each spilled to its own slot first — later args
   may call over earlier results — then load them into a[from].. A raw
   numeric arg boxes first: these registers feed dynamic callees, whose
   tagged-word contract is the escape point. *)
and emit_args_from env d ~(from : int) (args : Emo_ir.expr list) : unit =
  if from + List.length args > 8 then
    refuse "a call with more than eight arguments";
  List.iteri
    (fun i arg ->
      let spill = temp_offset env (d + i) in
      emit_expr env (d + List.length args) arg;
      box_if_numeric env arg.Emo_ir.ety;
      put env "    sd a0, %d(sp)\n" spill)
    args;
  List.iteri
    (fun i _ ->
      put env "    ld a%d, %d(sp)\n" (from + i) (temp_offset env (d + i)))
    args

and emit_args env d (args : Emo_ir.expr list) : unit =
  emit_args_from env d ~from:0 args

(* ---- The typed-convention adapters (T2.1) ----

   The caller side. Dynamic context: args evaluate left to right as
   tagged words, each spilled to its own temp slot (later args may call
   over earlier results), then the registers fill from the slots — an
   Int64 or Float64 arg unboxes into its bank register, every other arg
   loads its tagged word — and a raw result boxes back into a0.
   Native context (T2.2): the args already hold their rule-1
   representations (raw Int64 in a0, raw Float64 in fa0, tagged
   otherwise), so spill and fill are plain moves — the boundary
   disappears. *)

and emit_typed_regs env d (kinds : param_kind list) : unit =
  List.iteri
    (fun i (k, reg) ->
      let spill = temp_offset env (d + i) in
      match k with
      | P_int64 ->
          put env "    ld a%d, %d(sp)\n" reg spill;
          put env "    andi a%d, a%d, -32\n" reg reg;
          put env "    ld a%d, 8(a%d)\n" reg reg
      | P_word -> put env "    ld a%d, %d(sp)\n" reg spill
      | P_float64 ->
          put env "    ld t0, %d(sp)\n" spill;
          put env "    andi t0, t0, -32\n";
          put env "    fld fa%d, 8(t0)\n" reg)
    (bank_assign kinds)

and emit_typed_regs_native env d (kinds : param_kind list) : unit =
  List.iteri
    (fun i (k, reg) ->
      let spill = temp_offset env (d + i) in
      match k with
      | P_float64 -> put env "    fld fa%d, %d(sp)\n" reg spill
      | _ -> put env "    ld a%d, %d(sp)\n" reg spill)
    (bank_assign kinds)

and emit_box_result env (r : result_kind) : unit =
  match r with
  | R_int64 -> call_runtime env "emo_box_i64"
  | R_float64 -> call_runtime env "emo_box_f64"
  | R_word | R_void -> ()

(* The callee side, at the return label: the dynamic body leaves the
   tagged result in a0; a typed result unboxes to its raw register.
   Only dynamic bodies run this — a native body already holds the rule-1
   representation. *)
and emit_unbox_result env (r : result_kind) : unit =
  match r with
  | R_int64 ->
      put env "    andi a0, a0, -32\n";
      put env "    ld a0, 8(a0)\n"
  | R_float64 ->
      put env "    andi t0, a0, -32\n";
      put env "    fld fa0, 8(t0)\n"
  | R_word | R_void -> ()

and emit_typed_call env d (func : string) (conv : conv)
    (args : Emo_ir.expr list) : unit =
  if List.length args > 8 then refuse "a call with more than eight arguments";
  let n = List.length args in
  if env.native then begin
    List.iteri
      (fun i arg ->
        let spill = temp_offset env (d + i) in
        emit_expr env (d + n) arg;
        match arg.Emo_ir.ety with
        | Emo_check.Float64 -> put env "    fsd fa0, %d(sp)\n" spill
        | _ -> put env "    sd a0, %d(sp)\n" spill)
      args;
    emit_typed_regs_native env d conv.cparams;
    put env "    call %s\n" (func_label func)
  end
  else begin
    List.iteri
      (fun i arg ->
        let spill = temp_offset env (d + i) in
        emit_expr env (d + n) arg;
        put env "    sd a0, %d(sp)\n" spill)
      args;
    emit_typed_regs env d conv.cparams;
    put env "    call %s\n" (func_label func);
    emit_box_result env conv.cresult
  end

(* A Tuple or Array literal: the elements evaluate first (each spilled —
   boxed at the container boundary first), then one block is allocated
   and filled. *)
and emit_seq env d (es : Emo_ir.expr list) (tag : int) : unit =
  let n = List.length es in
  List.iteri
    (fun i el ->
      emit_expr env (d + n) el;
      box_if_numeric env el.Emo_ir.ety;
      put env "    sd a0, %d(sp)\n" (temp_offset env (d + i)))
    es;
  put env "    li a0, %d\n" (n + 1);
  call_runtime env "emo_alloc";
  put env "    li t0, %d\n" n;
  put env "    sd t0, 8(a0)\n";
  List.iteri
    (fun i _ ->
      put env "    ld t0, %d(sp)\n" (temp_offset env (d + i));
      put env "    sd t0, %d(a0)\n" (16 + (8 * i)))
    es;
  put env "    ori a0, a0, %d\n" tag

and emit_index env d (b : Emo_ir.expr) (i : Emo_ir.expr) : unit =
  let spill = temp_offset env d in
  emit_expr env (d + 1) b;
  put env "    andi a0, a0, -32\n";
  put env "    sd a0, %d(sp)\n" spill;
  emit_expr env (d + 1) i;
  box_if_numeric env i.Emo_ir.ety;
  put env "    andi a0, a0, -32\n";
  put env "    ld t2, 8(a0)\n";
  put env "    ld t0, %d(sp)\n" spill;
  put env "    ld t1, 8(t0)\n";
  let l_oob = fresh_label env "idxoob" in
  put env "    bgeu t2, t1, %s\n" l_oob;
  put env "    slli t2, t2, 3\n";
  put env "    add t0, t0, t2\n";
  put env "    ld a0, 16(t0)\n";
  let l_ok = fresh_label env "idx" in
  put env "    j %s\n" l_ok;
  put env "%s:\n" l_oob;
  let label = string_label env "index out of bounds" in
  put env "    la a0, %s\n" label;
  put env "    la a1, %s_end\n" label;
  call_runtime env "emo_fail";
  put env "%s:\n" l_ok

and emit_binary env d (ty : Emo_check.t) ~(boxed : bool) (op : Emo_ast.binop)
    (l : Emo_ir.expr) (r : Emo_ir.expr) : unit =
  let bool_of_t0 () =
    put env "    slli t0, t0, 4\n    addi t0, t0, 1\n    mv a0, t0\n"
  in
  (* Comparisons key on the operand type (their own result is Bool). *)
  let ty = if ty = Emo_check.Bool then l.Emo_ir.ety else ty in
  (* A dynamic operand: the runtime dispatches on the values (the c
     target's emo_*_dyn family). A raw numeric operand boxes at the
     dynamic boundary — the helper reads tagged words. *)
  if l.Emo_ir.ety = Emo_check.Unknown || r.Emo_ir.ety = Emo_check.Unknown then
    match op with
    | Emo_ast.Eq | Emo_ast.Ne ->
        emit_expr env (d + 1) l;
        box_if_numeric env l.Emo_ir.ety;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) r;
        box_if_numeric env r.Emo_ir.ety;
        put env "    ld a1, %d(sp)\n" spill;
        call_runtime env "emo_eq_deep";
        if op = Emo_ast.Ne then put env "    xori a0, a0, 16\n"
    | Emo_ast.Add | Emo_ast.Sub | Emo_ast.Mul ->
        emit_expr env (d + 1) l;
        box_if_numeric env l.Emo_ir.ety;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) r;
        box_if_numeric env r.Emo_ir.ety;
        put env "    mv a1, a0\n";
        put env "    ld a0, %d(sp)\n" spill;
        let helper =
          match op with
          | Emo_ast.Add -> "emo_add_dyn"
          | Emo_ast.Sub -> "emo_sub_dyn"
          | _ -> "emo_mul_dyn"
        in
        call_runtime env helper
    | Emo_ast.Lt | Emo_ast.Le | Emo_ast.Gt | Emo_ast.Ge ->
        (* Gt/Ge swap the operands onto Lt/Le, the c target's trick *)
        let a, b =
          if op = Emo_ast.Gt || op = Emo_ast.Ge then (r, l) else (l, r)
        in
        emit_expr env (d + 1) a;
        box_if_numeric env a.Emo_ir.ety;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) b;
        box_if_numeric env b.Emo_ir.ety;
        put env "    mv a1, a0\n";
        put env "    ld a0, %d(sp)\n" spill;
        call_runtime env
          (if op = Emo_ast.Lt || op = Emo_ast.Gt then "emo_lt_dyn"
           else "emo_le_dyn")
    | _ -> refuse "this operator on a dynamic value"
  else
    match (op, ty) with
    | ( ( Emo_ast.Add | Emo_ast.Sub | Emo_ast.Mul | Emo_ast.Bit_and
        | Emo_ast.Bit_or | Emo_ast.Bit_xor | Emo_ast.Shl | Emo_ast.Shr ),
        Emo_check.Int64 ) ->
        emit_int_pair env d l r;
        let mnemonic =
          match op with
          | Emo_ast.Add -> "add"
          | Emo_ast.Sub -> "sub"
          | Emo_ast.Mul -> "mul"
          | Emo_ast.Bit_and -> "and"
          | Emo_ast.Bit_or -> "or"
          | Emo_ast.Bit_xor -> "xor"
          | Emo_ast.Shl -> "sll"
          | Emo_ast.Shr -> "sra"
          | _ -> assert false
        in
        put env "    %s t0, t0, t1\n" mnemonic;
        put env "    mv a0, t0\n";
        if boxed then put env "    call emo_box_i64\n"
    | ( ( Emo_ast.Add | Emo_ast.Sub | Emo_ast.Mul | Emo_ast.Bit_and
        | Emo_ast.Bit_or | Emo_ast.Bit_xor ),
        Emo_check.Byte ) ->
        (* the byte lane: in-type, wrapping modulo 256 — Byte is
           unsigned, the family rule the hosted targets already run.
           Operands are immediates: decode, op, re-encode *)
        emit_byte_pair env d l r;
        let mnemonic =
          match op with
          | Emo_ast.Add -> "add"
          | Emo_ast.Sub -> "sub"
          | Emo_ast.Mul -> "mul"
          | Emo_ast.Bit_and -> "and"
          | Emo_ast.Bit_or -> "or"
          | Emo_ast.Bit_xor -> "xor"
          | _ -> assert false
        in
        put env "    %s t0, t0, t1\n" mnemonic;
        put env "    andi t0, t0, 255\n";
        put env "    slli a0, t0, 4\n";
        put env "    ori a0, a0, 7\n"
    | (Emo_ast.Shl | Emo_ast.Shr), Emo_check.Byte ->
        (* a count of eight or more saturates at the width: the Byte
           answers 0, the same rule every hosted target runs *)
        emit_byte_pair env d l r;
        let saturated = fresh_label env "bshift" in
        put env "    li t2, 8\n";
        put env "    bgeu t1, t2, %s\n" saturated;
        put env "    %s t0, t0, t1\n"
          (if op = Emo_ast.Shl then "sll" else "srl");
        put env "    j 1f\n";
        put env "%s:\n" saturated;
        put env "    li t0, 0\n";
        put env "1:\n";
        put env "    andi t0, t0, 255\n";
        put env "    slli a0, t0, 4\n";
        put env "    ori a0, a0, 7\n"
    | (Emo_ast.Div | Emo_ast.Mod), Emo_check.Int64 ->
        (* the divisor is checked first: RISC-V's div/rem define x/0
           instead of trapping, and the language raises. INT64_MIN / -1
           needs no check — the hardware's wrap matches the c runtime's
           saturation. *)
        emit_int_pair env d l r;
        put env "    bnez t1, 1f\n";
        put env "    la a0, msg_divzero\n";
        put env "    la a1, msg_divzero_end\n";
        put env "    call emo_fail\n";
        put env "1:\n";
        put env "    %s t0, t0, t1\n"
          (if op = Emo_ast.Div then "div" else "rem");
        put env "    mv a0, t0\n";
        if boxed then put env "    call emo_box_i64\n"
    | (Emo_ast.Div | Emo_ast.Mod), Emo_check.Byte ->
        (* unsigned, and the divisor is checked first — the Int64 arm's
           discipline *)
        emit_byte_pair env d l r;
        put env "    bnez t1, 1f\n";
        put env "    la a0, msg_divzero\n";
        put env "    la a1, msg_divzero_end\n";
        put env "    call emo_fail\n";
        put env "1:\n";
        put env "    %s t0, t0, t1\n"
          (if op = Emo_ast.Div then "divu" else "remu");
        put env "    slli a0, t0, 4\n";
        put env "    ori a0, a0, 7\n"
    | (Emo_ast.Add | Emo_ast.Sub | Emo_ast.Mul | Emo_ast.Div), Emo_check.Float64
      ->
        emit_float_pair env d l r;
        let mnemonic =
          match op with
          | Emo_ast.Add -> "fadd.d"
          | Emo_ast.Sub -> "fsub.d"
          | Emo_ast.Mul -> "fmul.d"
          | Emo_ast.Div -> "fdiv.d"
          | _ -> assert false
        in
        put env "    %s fa0, fa0, fa1\n" mnemonic;
        if boxed then put env "    call emo_box_f64\n"
    | Emo_ast.Add, Emo_check.String ->
        emit_expr env (d + 1) l;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) r;
        put env "    mv a1, a0\n";
        put env "    ld a0, %d(sp)\n" spill;
        call_runtime env "emo_string_concat"
    | (Emo_ast.Eq | Emo_ast.Ne), Emo_check.Int64 ->
        emit_int_pair env d l r;
        put env "    sub t0, t0, t1\n";
        if op = Emo_ast.Eq then put env "    seqz t0, t0\n"
        else put env "    snez t0, t0\n";
        bool_of_t0 ()
    | (Emo_ast.Eq | Emo_ast.Ne), Emo_check.String ->
        emit_expr env (d + 1) l;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) r;
        put env "    mv a1, a0\n";
        put env "    ld a0, %d(sp)\n" spill;
        call_runtime env "emo_string_eq"
    | ( (Emo_ast.Eq | Emo_ast.Ne),
        (Emo_check.Bool | Emo_check.Char | Emo_check.Byte | Emo_check.EnumType _)
      ) ->
        (* immediates: equal iff the words are identical *)
        emit_expr env (d + 1) l;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) r;
        put env "    ld t0, %d(sp)\n" spill;
        put env "    xor t0, t0, a0\n";
        if op = Emo_ast.Eq then put env "    seqz t0, t0\n"
        else put env "    snez t0, t0\n";
        bool_of_t0 ()
    | (Emo_ast.Eq | Emo_ast.Ne), _ ->
        (* content equality: instances, tuples, arrays, boxes *)
        emit_expr env (d + 1) l;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) r;
        put env "    mv a1, a0\n";
        put env "    ld a0, %d(sp)\n" spill;
        call_runtime env "emo_eq_deep";
        if op = Emo_ast.Ne then put env "    xori a0, a0, 16\n"
    | (Emo_ast.Lt | Emo_ast.Le | Emo_ast.Gt | Emo_ast.Ge), Emo_check.Int64 ->
        emit_int_pair env d l r;
        (match op with
        | Emo_ast.Lt -> put env "    slt t0, t0, t1\n"
        | Emo_ast.Gt -> put env "    slt t0, t1, t0\n"
        | Emo_ast.Le ->
            put env "    slt t0, t1, t0\n";
            put env "    xori t0, t0, 1\n"
        | Emo_ast.Ge ->
            put env "    slt t0, t0, t1\n";
            put env "    xori t0, t0, 1\n"
        | _ -> assert false);
        bool_of_t0 ()
    | (Emo_ast.Lt | Emo_ast.Le | Emo_ast.Gt | Emo_ast.Ge), Emo_check.Byte ->
        (* unsigned bytes, so the decoded pair compares as plain ints *)
        emit_byte_pair env d l r;
        (match op with
        | Emo_ast.Lt -> put env "    slt t0, t0, t1\n"
        | Emo_ast.Gt -> put env "    slt t0, t1, t0\n"
        | Emo_ast.Le ->
            put env "    slt t0, t1, t0\n";
            put env "    xori t0, t0, 1\n"
        | Emo_ast.Ge ->
            put env "    slt t0, t0, t1\n";
            put env "    xori t0, t0, 1\n"
        | _ -> assert false);
        bool_of_t0 ()
    | (Emo_ast.Lt | Emo_ast.Le | Emo_ast.Gt | Emo_ast.Ge), Emo_check.Float64 ->
        emit_float_pair env d l r;
        (match op with
        | Emo_ast.Lt -> put env "    flt.d t0, fa0, fa1\n"
        | Emo_ast.Le -> put env "    fle.d t0, fa0, fa1\n"
        | Emo_ast.Gt -> put env "    flt.d t0, fa1, fa0\n"
        | Emo_ast.Ge ->
            put env "    flt.d t0, fa1, fa0\n";
            put env "    xori t0, t0, 1\n"
        | _ -> assert false);
        bool_of_t0 ()
    | (Emo_ast.And | Emo_ast.Or), _ ->
        let l_end = fresh_label env "sc" in
        emit_expr env d l;
        put env "    andi t0, a0, 16\n";
        if op = Emo_ast.And then put env "    beqz t0, %s\n" l_end
        else put env "    bnez t0, %s\n" l_end;
        emit_expr env d r;
        put env "%s:\n" l_end
    | Emo_ast.Div, _ | Emo_ast.Mod, _ ->
        refuse "`/` and `%` (they arrive with runtime exceptions)"
    | _ -> refuse "this operator on this type"

(* Unbox both operands of an Int64 binary: the left payload spills to
   this depth's slot while the right evaluates one deeper. Leaves the
   payloads in t0 (left) and t1 (right). A native body's operands are
   raw already — the pair is plain moves. *)
and emit_int_pair env d (l : Emo_ir.expr) (r : Emo_ir.expr) : unit =
  let spill = temp_offset env d in
  emit_expr env (d + 1) l;
  if env.native then put env "    sd a0, %d(sp)\n" spill
  else begin
    put env "    andi a0, a0, -32\n";
    put env "    ld t0, 8(a0)\n";
    put env "    sd t0, %d(sp)\n" spill
  end;
  emit_expr env (d + 1) r;
  if env.native then begin
    put env "    mv t1, a0\n";
    put env "    ld t0, %d(sp)\n" spill
  end
  else begin
    put env "    andi a0, a0, -32\n";
    put env "    ld t1, 8(a0)\n";
    put env "    ld t0, %d(sp)\n" spill
  end

(* The Byte twin: immediates both, so decoding is a shift. Leaves the
   payloads in t0 (left) and t1 (right). *)
and emit_byte_pair env d (l : Emo_ir.expr) (r : Emo_ir.expr) : unit =
  let spill = temp_offset env d in
  emit_expr env (d + 1) l;
  put env "    srli t0, a0, 4\n";
  put env "    sd t0, %d(sp)\n" spill;
  emit_expr env (d + 1) r;
  put env "    srli t1, a0, 4\n";
  put env "    ld t0, %d(sp)\n" spill

(* The Float64 twin: payloads ride fa0/fa1. Field reads untag first —
   every heap access runs on the untagged pointer (Int64's tag is 0 and
   hides any slip, so the discipline is checked on the float paths).
   Native: the operands are raw in fa0 already, so the left spill is an
   fsd and the right lands in fa0 via a register move. *)
and emit_float_pair env d (l : Emo_ir.expr) (r : Emo_ir.expr) : unit =
  let spill = temp_offset env d in
  emit_expr env (d + 1) l;
  if env.native then put env "    fsd fa0, %d(sp)\n" spill
  else begin
    put env "    andi a0, a0, -32\n";
    put env "    fld fa0, 8(a0)\n";
    put env "    fsd fa0, %d(sp)\n" spill
  end;
  emit_expr env (d + 1) r;
  if env.native then begin
    put env "    fmv.d fa1, fa0\n";
    put env "    fld fa0, %d(sp)\n" spill
  end
  else begin
    put env "    andi a0, a0, -32\n";
    put env "    fld fa1, 8(a0)\n";
    put env "    fld fa0, %d(sp)\n" spill
  end

and emit_unary env d (ty : Emo_check.t) ~(boxed : bool) (op : Emo_ast.unop)
    (x : Emo_ir.expr) : unit =
  match (op, ty) with
  | Emo_ast.Neg, Emo_check.Int64 ->
      emit_expr env d x;
      if not boxed then put env "    sub a0, x0, a0\n"
      else begin
        put env "    andi a0, a0, -32\n";
        put env "    ld t0, 8(a0)\n";
        put env "    sub t0, x0, t0\n";
        put env "    mv a0, t0\n";
        put env "    call emo_box_i64\n"
      end
  | Emo_ast.Neg, Emo_check.Float64 ->
      emit_expr env d x;
      if not boxed then put env "    fneg.d fa0, fa0\n"
      else begin
        put env "    andi a0, a0, -32\n";
        put env "    fld fa0, 8(a0)\n";
        put env "    fneg.d fa0, fa0\n";
        put env "    call emo_box_f64\n"
      end
  | Emo_ast.Bit_not, Emo_check.Int64 ->
      emit_expr env d x;
      if not boxed then put env "    not a0, a0\n"
      else begin
        put env "    andi a0, a0, -32\n";
        put env "    ld t0, 8(a0)\n";
        put env "    not t0, t0\n";
        put env "    mv a0, t0\n";
        put env "    call emo_box_i64\n"
      end
  | Emo_ast.Bit_not, Emo_check.Byte ->
      emit_expr env d x;
      put env "    srli t0, a0, 4\n";
      put env "    not t0, t0\n";
      put env "    andi t0, t0, 255\n";
      put env "    slli a0, t0, 4\n";
      put env "    ori a0, a0, 7\n"
  | Emo_ast.Not, _ ->
      emit_expr env d x;
      put env "    xori a0, a0, 16\n"
  | _ -> refuse "this unary operator"

and emit_interpolate env d (parts : Emo_ir.expr list) : unit =
  (* Every part becomes a String block through the runtime's to-string
     dispatch; then one block is allocated and the parts blit in. *)
  let k = List.length parts in
  List.iteri
    (fun i part ->
      emit_expr env (d + k) part;
      box_if_numeric env part.Emo_ir.ety;
      call_runtime env "emo_to_string";
      put env "    sd a0, %d(sp)\n" (temp_offset env (d + i)))
    parts;
  put env "    li t2, 0\n";
  List.iteri
    (fun i _ ->
      put env "    ld t0, %d(sp)\n" (temp_offset env (d + i));
      put env "    andi t0, t0, -32\n";
      put env "    ld t1, 8(t0)\n";
      put env "    add t2, t2, t1\n")
    parts;
  put env "    mv a0, t2\n";
  call_runtime env "emo_alloc_string";
  let block_slot = temp_offset env (d + k) in
  let cursor_slot = temp_offset env (d + k + 1) in
  put env "    sd a0, %d(sp)\n" block_slot;
  put env "    andi a0, a0, -32\n";
  put env "    addi a0, a0, 16\n";
  List.iteri
    (fun i _ ->
      put env "    ld a1, %d(sp)\n" (temp_offset env (d + i));
      call_runtime env "emo_blit";
      put env "    sd a0, %d(sp)\n" cursor_slot;
      put env "    ld a0, %d(sp)\n" cursor_slot)
    parts;
  put env "    ld a0, %d(sp)\n" block_slot

and emit_closure_creation env d (cparams : (string * Emo_check.t) list)
    (cbody : Emo_ir.stmt list) : unit =
  env.labels <- env.labels + 1;
  let label = Printf.sprintf "emo_closure_%d" env.labels in
  let caps = closure_free ~cparams cbody in
  let k = List.length caps in
  List.iteri
    (fun i name ->
      put env "    ld a0, %d(sp)\n" (slot_offset env name);
      (* the record holds tagged words: a captured raw local boxes at
         the capture — the closure boundary is an escape point *)
      (match env.cur with
      | Some f when env.native -> (
          match List.assoc_opt name f.raw with
          | Some t -> box_if_numeric env t
          | None -> ())
      | _ -> ());
      put env "    sd a0, %d(sp)\n" (temp_offset env (d + i)))
    caps;
  put env "    li a0, %d\n" (1 + k);
  call_runtime env "emo_alloc";
  put env "    sd a0, %d(sp)\n" (temp_offset env (d + k));
  put env "    la t0, %s\n" label;
  put env "    ld t1, %d(sp)\n" (temp_offset env (d + k));
  put env "    sd t0, 8(t1)\n";
  List.iteri
    (fun i _ ->
      put env "    ld t0, %d(sp)\n" (temp_offset env (d + i));
      put env "    ld t1, %d(sp)\n" (temp_offset env (d + k));
      put env "    sd t0, %d(t1)\n" (16 + (8 * i)))
    caps;
  put env "    ld t1, %d(sp)\n" (temp_offset env (d + k));
  put env "    ori a0, t1, %d\n" tag_closure;
  env.deferred <- (label, cparams, caps, cbody) :: env.deferred

(* ---- Method dispatch ---- *)

and emit_method env d (ty : Emo_check.t) ~(boxed : bool) (self_ : Emo_ir.expr)
    (name : string) (args : Emo_ir.expr list) : unit =
  (* `is` takes a type reference, not a value. *)
  match (name, args) with
  | "is", [ { Emo_ir.desc = Type_ref target; _ } ] -> (
      emit_expr env d self_;
      put env "    andi a0, a0, -32\n";
      put env "    ld t0, 8(a0)\n";
      match List.assoc_opt target env.classes with
      | Some c ->
          put env "    li t1, %d\n" c.cls_id;
          put env "    sub t0, t0, t1\n";
          put env "    seqz t0, t0\n";
          put env "    slli t0, t0, 4\n    addi t0, t0, 1\n    mv a0, t0\n"
      | None -> (
          match List.assoc_opt target env.ifaces with
          | Some _ ->
              put env "    la t1, emo_iface_%s\n" (Emo_ir.sanitize_ident target);
              put env "    slli t0, t0, 3\n";
              put env "    add t1, t1, t0\n";
              put env "    ld t2, 0(t1)\n";
              put env "    seqz t0, t2\n";
              put env "    xori t0, t0, 1\n";
              put env "    slli t0, t0, 4\n    addi t0, t0, 1\n    mv a0, t0\n"
          | None -> refuse (Printf.sprintf "`is(%s)`" target)))
  | "from_int64", [ x ]
    when match self_.Emo_ir.desc with
         | Emo_ir.Type_ref "Byte" -> true
         | _ -> false ->
      (* the conversion the checker admits statically, the interpreter
         runs loudly: 0–255 or the named failure — the mask the c
         target applies silently is not the rule here *)
      emit_expr env (d + 1) x;
      box_if_numeric env x.Emo_ir.ety;
      put env "    andi a0, a0, -32\n";
      put env "    ld t0, 8(a0)\n";
      put env "    li t1, -256\n";
      put env "    and t1, t0, t1\n";
      put env "    beqz t1, 1f\n";
      put env "    la a0, msg_byte_range\n";
      put env "    la a1, msg_byte_range_end\n";
      put env "    call emo_fail\n";
      put env "1:\n";
      put env "    slli a0, t0, 4\n";
      put env "    ori a0, a0, 7\n"
  | _ -> (
      match self_.Emo_ir.ety with
      | Emo_check.Byte -> (
          match (name, args) with
          | "to_int64", [] ->
              emit_expr env d self_;
              put env "    srli a0, a0, 4\n";
              put env "    andi a0, a0, 255\n";
              if boxed then put env "    call emo_box_i64\n"
          | "to_string", [] ->
              emit_expr env d self_;
              call_runtime env "emo_to_string"
          | _ -> refuse (Printf.sprintf "the Byte method `%s`" name))
      | Emo_check.Int64 when name = "to_string" && args = [] ->
          emit_expr env d self_;
          if not boxed then ()
          else begin
            put env "    andi a0, a0, -32\n";
            put env "    ld a0, 8(a0)\n"
          end;
          call_runtime env "emo_i64_to_string"
      | Emo_check.Int64 when name = "to_byte" && args = [] ->
          (* the low eight bits, the family's rule *)
          emit_expr env d self_;
          if boxed then begin
            put env "    andi a0, a0, -32\n";
            put env "    ld t0, 8(a0)\n";
            put env "    andi t0, t0, 255\n"
          end
          else put env "    andi t0, a0, 255\n";
          put env "    slli a0, t0, 4\n";
          put env "    ori a0, a0, 7\n"
      | Emo_check.BoxType _ -> (
          match (name, args) with
          | "read", [] ->
              emit_expr env d self_;
              put env "    andi a0, a0, -32\n";
              put env "    ld a0, 8(a0)\n";
              (* the cell holds the tagged word; a raw numeric consumer
                 reads the payload *)
              if not boxed then unbox_if_numeric env ty
          | "replace", [ v ] ->
              let self_slot = temp_offset env d in
              emit_expr env (d + 1) self_;
              put env "    sd a0, %d(sp)\n" self_slot;
              emit_expr env (d + 1) v;
              box_if_numeric env v.Emo_ir.ety;
              put env "    ld t0, %d(sp)\n" self_slot;
              put env "    andi t0, t0, -32\n";
              put env "    sd a0, 8(t0)\n";
              put env "    ld a0, %d(sp)\n" self_slot
          | _ -> refuse (Printf.sprintf "the Box method `%s`" name))
      | Emo_check.AtomicType _ -> (
          (* Box's synchronized sibling: every access is a runtime
             helper over the cell's word (the psABI: a0 = cell, a1.. =
             the args), so the static and the dynamic paths share one
             implementation *)
          let helper =
            match (name, args) with
            | "load", [] -> Some "emo_atomic_load"
            | "store", [ _ ] -> Some "emo_atomic_store"
            | "exchange", [ _ ] -> Some "emo_atomic_exchange"
            | "compare_exchange", [ _; _ ] -> Some "emo_atomic_compare_exchange"
            | ( ( "fetch_add" | "fetch_sub" | "fetch_and" | "fetch_or"
                | "fetch_xor" ),
                [ _ ] ) ->
                Some ("emo_atomic_" ^ name)
            | "to_string", [] -> Some "emo_to_string"
            | _ -> None
          in
          match helper with
          | Some helper ->
              let self_slot = temp_offset env d in
              emit_expr env (d + 1) self_;
              put env "    sd a0, %d(sp)\n" self_slot;
              emit_args_from env (d + 1) ~from:1 args;
              put env "    ld a0, %d(sp)\n" self_slot;
              call_runtime env helper;
              if not boxed then unbox_if_numeric env ty
          | None -> refuse (Printf.sprintf "the Atomic method `%s`" name))
      | Emo_check.ArrayType _ -> (
          match (name, args) with
          | "length", [] ->
              emit_expr env d self_;
              put env "    andi a0, a0, -32\n";
              put env "    ld a0, 8(a0)\n";
              if boxed then put env "    call emo_box_i64\n"
          | "append", [ x ] ->
              let self_slot = temp_offset env d in
              emit_expr env (d + 1) self_;
              put env "    sd a0, %d(sp)\n" self_slot;
              emit_expr env (d + 1) x;
              box_if_numeric env x.Emo_ir.ety;
              put env "    sd a0, %d(sp)\n" (temp_offset env (d + 1));
              put env "    ld a1, %d(sp)\n" (temp_offset env (d + 1));
              put env "    ld a0, %d(sp)\n" self_slot;
              call_runtime env "emo_array_append"
          | _ -> refuse (Printf.sprintf "the Array method `%s`" name))
      | Emo_check.ClassType display -> (
          let c = class_of env display in
          match List.assoc_opt (Emo_ir.sanitize_ident name) c.cls_methods with
          | Some mangled ->
              let self_slot = temp_offset env d in
              emit_expr env (d + 1) self_;
              put env "    sd a0, %d(sp)\n" self_slot;
              emit_args_from env (d + 1) ~from:1 args;
              put env "    ld a0, %d(sp)\n" self_slot;
              put env "    call %s\n" (func_label mangled);
              (* the callee is a dynamic-convention body: its tagged
                 result crosses back through the boundary *)
              if not boxed then unbox_if_numeric env ty
          | None ->
              refuse (Printf.sprintf "the method `%s` of `%s`" name display))
      | Emo_check.InterfaceType display -> (
          match List.assoc_opt display env.ifaces with
          | Some sigs
            when List.exists
                   (fun (m, _) -> String.equal m (Emo_ir.sanitize_ident name))
                   sigs ->
              let self_slot = temp_offset env d in
              emit_expr env (d + 1) self_;
              put env "    sd a0, %d(sp)\n" self_slot;
              emit_args_from env (d + 1) ~from:1 args;
              put env "    ld a0, %d(sp)\n" self_slot;
              put env "    ld t0, %d(sp)\n" self_slot;
              put env "    andi t0, t0, -32\n";
              put env "    ld t1, 8(t0)\n";
              put env "    la t2, emo_iface_%s\n"
                (Emo_ir.sanitize_ident display);
              (* the table is one row of per-class slots, a slot per
                 interface method in the interface's own order — the row
                 for the receiver's class, the slot for this method *)
              put env "    li t3, %d\n" (List.length sigs);
              put env "    mul t1, t1, t3\n";
              put env "    slli t1, t1, 3\n";
              put env "    add t2, t2, t1\n";
              let idx =
                let rec go i = function
                  | [] -> 0
                  | (m, _) :: rest ->
                      if String.equal m (Emo_ir.sanitize_ident name) then i
                      else go (i + 1) rest
                in
                go 0 sigs
              in
              put env "    ld t2, %d(t2)\n" (idx * 8);
              put env "    jalr t2\n";
              if not boxed then unbox_if_numeric env ty
          | Some _ ->
              refuse (Printf.sprintf "the method `%s` of `%s`" name display)
          | None -> refuse (Printf.sprintf "the interface `%s`" display))
      | Emo_check.BuilderType _ ->
          (* `ArrayBuilder.new` refuses at the construction site, so a
             builder value cannot be built here; one still arrives as a
             parameter's annotation, which is why the methods refuse by
             name rather than falling through to the dynamic dispatch. *)
          refuse (Printf.sprintf "the ArrayBuilder method `%s`" name)
      | _ ->
          (* a dynamic receiver: the runtime dispatches by name — the
             instance's method table first, then the scalar builtins
             (the c target's emo_dynamic_builtin). a0.. carry self and
             the args as the impl wants them; t0/t1 name the method. *)
          let nlabel = string_label env name in
          let self_slot = temp_offset env d in
          emit_expr env (d + 1) self_;
          put env "    sd a0, %d(sp)\n" self_slot;
          List.iteri
            (fun i arg ->
              emit_expr env (d + 1 + List.length args) arg;
              box_if_numeric env arg.Emo_ir.ety;
              put env "    sd a0, %d(sp)\n" (temp_offset env (d + 1 + i)))
            args;
          put env "    ld a0, %d(sp)\n" self_slot;
          List.iteri
            (fun i _ ->
              put env "    ld a%d, %d(sp)\n" (i + 1)
                (temp_offset env (d + 1 + i)))
            args;
          put env "    la t0, %s\n" nlabel;
          put env "    li t1, %d\n" (String.length name);
          call_runtime env "emo_dyn_method")

(* ---- Statement emission ---- *)

(* A call in return position lowers to a guaranteed tail call: the
   frame is released first (nothing live rides in it — the args are
   already in registers), so the stack stays constant. `tail`/`jr`
   leave ra alone, so the original return address is loaded into ra
   first — it rides through the whole tail chain. A typed callee's
   result must match this function's own representation — the tail
   path bypasses the return label, so no adapter can convert a raw
   result into the tagged word the dynamic convention promises (or the
   reverse); a mismatching pair takes the plain call instead. *)
and emit_tail env (e : Emo_ir.expr) : bool =
  let frame () =
    match env.cur with Some f -> f | None -> invalid_arg "riscv: no frame"
  in
  let mine () = (frame ()).fconv.cresult in
  match e.Emo_ir.desc with
  | Call { func; args } -> (
      match List.assoc_opt func env.fsigs with
      | Some conv when result_compatible conv.cresult (mine ()) ->
          if List.length args > 8 then
            refuse "a call with more than eight arguments";
          let n = List.length args in
          List.iteri
            (fun i arg ->
              let spill = temp_offset env i in
              emit_expr env n arg;
              if env.native then
                match arg.Emo_ir.ety with
                | Emo_check.Float64 -> put env "    fsd fa0, %d(sp)\n" spill
                | _ -> put env "    sd a0, %d(sp)\n" spill
              else put env "    sd a0, %d(sp)\n" spill)
            args;
          if env.native then emit_typed_regs_native env 0 conv.cparams
          else emit_typed_regs env 0 conv.cparams;
          let f = frame () in
          put env "    ld ra, 0(sp)\n";
          put env "    addi sp, sp, %d\n" f.size;
          put env "    tail %s\n" (func_label func);
          true
      | Some _ -> false
      | None when result_compatible R_word (mine ()) ->
          emit_args env 0 args;
          let f = frame () in
          put env "    ld ra, 0(sp)\n";
          put env "    addi sp, sp, %d\n" f.size;
          put env "    tail %s\n" (func_label func);
          true
      | None -> false)
  | Call_value { f; args } when result_compatible R_word (mine ()) ->
      let ff = frame () in
      let fslot = temp_offset env 0 in
      emit_expr env 1 f;
      put env "    sd a0, %d(sp)\n" fslot;
      emit_args_from env 1 ~from:0 args;
      put env "    ld t0, %d(sp)\n" fslot;
      put env "    andi t0, t0, -32\n";
      put env "    ld t2, 8(t0)\n";
      put env "    ld ra, 0(sp)\n";
      put env "    addi sp, sp, %d\n" ff.size;
      put env "    jr t2\n";
      true
  | _ -> false

(* One branch's pattern as a fall-through test over the scrutinee word
   in [slot_off]; control reaches [l_next] when it does not match.
   Tuple subtests hold their element in temp slot 0 while recursing. *)
and emit_pattern_test env (slot_off : int) (p : Emo_ast.pattern)
    (l_next : string) : unit =
  match p.Emo_ast.pattern_desc with
  | Emo_ast.Wildcard | Emo_ast.Pattern_binding _ -> ()
  | Emo_ast.Enum_member (t, m) ->
      put env "    ld t0, %d(sp)\n" slot_off;
      put env "    li t1, %d\n" (enum_imm env t m);
      put env "    bne t0, t1, %s\n" l_next
  | Emo_ast.Pattern_literal (Emo_ast.L_int n) ->
      put env "    ld t0, %d(sp)\n" slot_off;
      put env "    andi t1, t0, 31\n";
      put env "    bnez t1, %s\n" l_next;
      put env "    andi t0, t0, -32\n";
      put env "    ld t0, 8(t0)\n";
      put env "    li t1, %Ld\n" n;
      put env "    bne t0, t1, %s\n" l_next
  | Emo_ast.Pattern_literal (Emo_ast.L_bool b) ->
      put env "    ld t0, %d(sp)\n" slot_off;
      put env "    li t1, %d\n" (if b then bool_true else bool_false);
      put env "    bne t0, t1, %s\n" l_next
  | Emo_ast.Pattern_literal (Emo_ast.L_char c) ->
      put env "    ld t0, %d(sp)\n" slot_off;
      put env "    li t1, %d\n" (char_imm c);
      put env "    bne t0, t1, %s\n" l_next
  | Emo_ast.Pattern_literal (Emo_ast.L_string s) ->
      let label = string_label env s in
      put env "    la a0, %s\n" label;
      put env "    li a1, %d\n" (String.length s);
      call_runtime env "emo_string_lit";
      put env "    sd a0, %d(sp)\n" (temp_offset env 1);
      put env "    ld a0, %d(sp)\n" slot_off;
      put env "    ld a1, %d(sp)\n" (temp_offset env 1);
      call_runtime env "emo_string_eq";
      put env "    andi t0, a0, 16\n";
      put env "    beqz t0, %s\n" l_next
  | Emo_ast.Pattern_literal (Emo_ast.L_float _) ->
      refuse "a float literal pattern"
  | Emo_ast.Pattern_literal (Emo_ast.L_byte _) -> refuse "a Byte pattern"
  | Emo_ast.Tuple_pattern ps ->
      put env "    ld t0, %d(sp)\n" slot_off;
      put env "    andi t1, t0, 31\n";
      put env "    li t2, %d\n" tag_tuple;
      put env "    bne t1, t2, %s\n" l_next;
      put env "    andi t0, t0, -32\n";
      put env "    ld t1, 8(t0)\n";
      put env "    li t2, %d\n" (List.length ps);
      put env "    bne t1, t2, %s\n" l_next;
      List.iteri
        (fun i sub ->
          let elem_slot = temp_offset env 1 in
          put env "    ld t0, %d(sp)\n" slot_off;
          put env "    andi t0, t0, -32\n";
          put env "    ld t0, %d(t0)\n" (16 + (8 * i));
          put env "    sd t0, %d(sp)\n" elem_slot;
          emit_pattern_test env elem_slot sub l_next)
        ps

(* Load a pattern's bound names out of the scrutinee slot into their
   own slots. Tuple subpatterns stage each element in temp slot 1 —
   slot 0 holds the scrutinee itself. *)
and rec_pattern_bind env (src_off : int) (p : Emo_ast.pattern) : unit =
  match p.Emo_ast.pattern_desc with
  | Emo_ast.Wildcard | Emo_ast.Pattern_literal _ | Emo_ast.Enum_member _ -> ()
  | Emo_ast.Pattern_binding n ->
      (* the bound word is tagged (the scrutinee boxed at the case); a
         native body must not read the name as a raw numeric local *)
      (match env.cur with
      | Some f when env.native -> f.raw <- List.remove_assoc n f.raw
      | _ -> ());
      put env "    ld t0, %d(sp)\n" src_off;
      put env "    sd t0, %d(sp)\n" (slot_offset env n)
  | Emo_ast.Tuple_pattern ps ->
      List.iteri
        (fun i sub ->
          put env "    ld t0, %d(sp)\n" src_off;
          put env "    andi t0, t0, -32\n";
          put env "    ld t0, %d(t0)\n" (16 + (8 * i));
          put env "    sd t0, %d(sp)\n" (temp_offset env 1);
          rec_pattern_bind env (temp_offset env 1) sub)
        ps

and emit_stmt env (st : Emo_ir.stmt) : unit =
  match st with
  | Effect e -> emit_expr env 0 e
  | Let { name; init; _ } -> (
      emit_expr env 0 init;
      match env.cur with
      | Some f when env.native -> (
          match init.Emo_ir.ety with
          | Emo_check.Float64 ->
              f.raw <- (name, Emo_check.Float64) :: List.remove_assoc name f.raw;
              put env "    fsd fa0, %d(sp)\n" (slot_offset env name)
          | Emo_check.Int64 ->
              f.raw <- (name, Emo_check.Int64) :: List.remove_assoc name f.raw;
              put env "    sd a0, %d(sp)\n" (slot_offset env name)
          | _ ->
              f.raw <- List.remove_assoc name f.raw;
              put env "    sd a0, %d(sp)\n" (slot_offset env name))
      | _ -> put env "    sd a0, %d(sp)\n" (slot_offset env name))
  | Assign_var { name; value } -> (
      emit_expr env 0 value;
      match env.cur with
      | Some f when env.native -> (
          match value.Emo_ir.ety with
          | Emo_check.Float64 ->
              f.raw <- (name, Emo_check.Float64) :: List.remove_assoc name f.raw;
              put env "    fsd fa0, %d(sp)\n" (slot_offset env name)
          | Emo_check.Int64 ->
              f.raw <- (name, Emo_check.Int64) :: List.remove_assoc name f.raw;
              put env "    sd a0, %d(sp)\n" (slot_offset env name)
          | _ ->
              f.raw <- List.remove_assoc name f.raw;
              put env "    sd a0, %d(sp)\n" (slot_offset env name))
      | _ -> put env "    sd a0, %d(sp)\n" (slot_offset env name))
  | If { cond; then_; else_ } ->
      let l_else = fresh_label env "else" in
      let l_end = fresh_label env "endif" in
      emit_expr env 0 cond;
      put env "    andi t0, a0, 16\n";
      put env "    beqz t0, %s\n" l_else;
      List.iter (emit_stmt env) then_;
      put env "    j %s\n" l_end;
      put env "%s:\n" l_else;
      List.iter (emit_stmt env) else_;
      put env "%s:\n" l_end
  | Case { scrutinee; branches } ->
      let scrut_slot = temp_offset env 0 in
      emit_expr env 3 scrutinee;
      (* the pattern tests read the tagged word: a raw numeric
         scrutinee boxes at the case boundary, and any binding the
         patterns make holds tagged words *)
      box_if_numeric env scrutinee.Emo_ir.ety;
      put env "    sd a0, %d(sp)\n" scrut_slot;
      let l_end = fresh_label env "case_end" in
      List.iter
        (fun (b : Emo_ir.branch) ->
          (* the test jumps to l_next on failure; a match falls through
             into the bind, the guard, and the body *)
          let l_next = fresh_label env "skip" in
          emit_pattern_test env scrut_slot b.Emo_ir.pattern l_next;
          rec_pattern_bind env scrut_slot b.Emo_ir.pattern;
          (match b.Emo_ir.guard with
          | Some g ->
              emit_expr env 2 g;
              put env "    andi t0, a0, 16\n";
              put env "    beqz t0, %s\n" l_next
          | None -> ());
          List.iter (emit_stmt env) b.Emo_ir.body;
          put env "    j %s\n" l_end;
          put env "%s:\n" l_next)
        branches;
      put env "%s:\n" l_end
  | Return_stmt e ->
      let ret =
        match env.cur with
        | Some f -> f.ret
        | None -> invalid_arg "riscv: no frame"
      in
      if emit_tail env e then ()
      else begin
        emit_expr env 0 e;
        put env "    j %s\n" ret
      end
  | Set_field { self_; name; value } -> (
      let self_slot = temp_offset env 0 in
      emit_expr env 1 self_;
      put env "    sd a0, %d(sp)\n" self_slot;
      emit_expr env 1 value;
      box_if_numeric env value.Emo_ir.ety;
      put env "    sd a0, %d(sp)\n" (temp_offset env 1);
      put env "    ld t0, %d(sp)\n" self_slot;
      match self_.Emo_ir.ety with
      | Emo_check.ClassType _ ->
          let idx = field_index env self_.Emo_ir.ety name in
          put env "    ld a0, %d(sp)\n" (temp_offset env 1);
          put env "    sd a0, %d(t0)\n" (16 + (8 * idx))
      | _ ->
          put env "    andi a0, t0, -32\n";
          put env "    ld t1, 8(a0)\n";
          let nlabel = string_label env name in
          put env "    la a1, %s\n" nlabel;
          put env "    li a2, %d\n" (String.length name);
          call_runtime env "emo_field_index";
          put env "    ld t0, %d(sp)\n" self_slot;
          put env "    andi t0, t0, -32\n";
          put env "    slli t1, a0, 3\n";
          put env "    add t0, t0, t1\n";
          put env "    ld a0, %d(sp)\n" (temp_offset env 1);
          put env "    sd a0, 16(t0)\n")
  | Set_global_var _ -> refuse "module-level `var` assignment"
  | Send { target; message } ->
      (* the send boundary: the message snapshots in emo_send and the
         sender yields — the call returns when this process is next
         scheduled *)
      emit_expr env 0 target;
      put env "    sd a0, %d(sp)\n" (temp_offset env 0);
      emit_expr env 1 message;
      box_if_numeric env message.Emo_ir.ety;
      put env "    mv a1, a0\n";
      put env "    ld a0, %d(sp)\n" (temp_offset env 0);
      call_runtime env "emo_send"
  | Receive { branches } ->
      (* the mailbox scan (T3.3): the index rides s0 — every helper is
         ABI-clean and the switch saves the callee-saved set — the
         candidate message stages in temp slot 0, the pattern machinery
         uses slots 1 and 2, and guards evaluate at depth 3. The first
         message a pattern and its guard accept dequeues; nothing
         accepting anywhere parks the process and the scan restarts
         from the oldest message on waking. *)
      let msg_slot = temp_offset env 0 in
      let l_test = fresh_label env "recv_scan" in
      let l_park = fresh_label env "recv_park" in
      let l_end = fresh_label env "recv_end" in
      put env "    li s0, 0\n";
      put env "%s:\n" l_test;
      call_runtime env "emo_mb_count";
      put env "    bgeu s0, a0, %s\n" l_park;
      put env "    mv a0, s0\n";
      call_runtime env "emo_mb_at";
      put env "    sd a0, %d(sp)\n" msg_slot;
      List.iter
        (fun (b : Emo_ir.branch) ->
          let l_next = fresh_label env "skip" in
          emit_pattern_test env msg_slot b.Emo_ir.pattern l_next;
          rec_pattern_bind env msg_slot b.Emo_ir.pattern;
          (match b.Emo_ir.guard with
          | Some g ->
              emit_expr env 3 g;
              put env "    andi t0, a0, 16\n";
              put env "    beqz t0, %s\n" l_next
          | None -> ());
          (* accepted: the message leaves the mailbox, the body runs *)
          put env "    mv a0, s0\n";
          call_runtime env "emo_mb_remove";
          List.iter (emit_stmt env) b.Emo_ir.body;
          put env "    j %s\n" l_end;
          put env "%s:\n" l_next)
        branches;
      put env "    addi s0, s0, 1\n";
      put env "    j %s\n" l_test;
      put env "%s:\n" l_park;
      call_runtime env "emo_park_receive";
      put env "    li s0, 0\n";
      put env "    j %s\n" l_test;
      put env "%s:\n" l_end
  | Raise _ -> refuse "raise"
  | While { cond; body; _ } ->
      let head = fresh_label env "loop" in
      let exit_l = fresh_label env "endloop" in
      put env "%s:\n" head;
      emit_expr env 0 cond;
      put env "    andi t0, a0, 16\n";
      put env "    beqz t0, %s\n" exit_l;
      env.loops <- (exit_l, head) :: env.loops;
      List.iter (emit_stmt env) body;
      env.loops <- List.tl env.loops;
      put env "    j %s\n" head;
      put env "%s:\n" exit_l
  | For { init; cond; post; body; _ } ->
      (* the head tests, the body runs, the post label sits between the
         body and the jump back — a `continue` lands on the post, a
         `break` leaves past it *)
      emit_stmt env init;
      let head = fresh_label env "loop" in
      let post_l = fresh_label env "post" in
      let exit_l = fresh_label env "endloop" in
      put env "%s:\n" head;
      emit_expr env 0 cond;
      put env "    andi t0, a0, 16\n";
      put env "    beqz t0, %s\n" exit_l;
      env.loops <- (exit_l, post_l) :: env.loops;
      List.iter (emit_stmt env) body;
      env.loops <- List.tl env.loops;
      put env "%s:\n" post_l;
      emit_stmt env post;
      put env "    j %s\n" head;
      put env "%s:\n" exit_l
  | Break -> (
      match env.loops with
      | (exit_l, _) :: _ -> put env "    j %s\n" exit_l
      | [] -> refuse "`break` outside a loop")
  | Continue -> (
      match env.loops with
      | (_, continue_l) :: _ -> put env "    j %s\n" continue_l
      | [] -> refuse "`continue` outside a loop")

and describe_expr (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Type_ref _ -> "type references in value position"
  | Global _ -> "program-wide def values"
  | Global_var _ -> "module-level `var`"
  | Map_lit _ -> "maps"
  | Bytes_new _ -> "Bytes"
  | List_new _ -> "List"
  | Builder_new -> "ArrayBuilder"
  | Make_exception _ -> "exceptions"
  | _ -> "this expression"

(* ---- Function emission ---- *)

(* A const thunk: a flag/value word pair in .data memoizes the
   initializer's result. The first call stores a0 into the value slot
   and flips the flag; every later call returns the stored word — an
   allocating initializer keeps its identity, as in the interpreter.
   The body is one `return <expr>`; its jump lands on the store block,
   which the fall-off path shares. *)
let emit_const_function env (f : Emo_ir.func) : unit =
  let n = Emo_ir.sanitize_ident f.Emo_ir.fname in
  let done_label = Printf.sprintf "emo_const_done_%s" n in
  let val_label = Printf.sprintf "emo_const_val_%s" n in
  let store = fresh_label env "const_store" in
  let hit = fresh_label env "const_hit" in
  (* a const thunk adopts its signature's convention (T2.1): the memo
     slot holds the raw result, and every reader — a call site keyed on
     the thunk's signature — boxes it back. A fully typed thunk's body
     is native (T2.2): the initializer computes the raw result
     directly. *)
  let conv = match conv_of f with Some c -> c | None -> dynamic_conv 0 in
  let native = match conv_of f with Some _ -> true | None -> false in
  let frm =
    {
      fbuf = Buffer.create 512;
      slots = [];
      named = 0;
      temps = 0;
      ret = store;
      size = 0;
      fconv = conv;
      raw = [];
    }
  in
  env.cur <- Some frm;
  env.native <- native;
  collect_stmts frm f.Emo_ir.fbody;
  frm.temps <- stmts_depth f.Emo_ir.fbody + 2;
  frm.size <- (8 + (8 * (frm.named + frm.temps)) + 15) / 16 * 16;
  gput env "%s:\n" (func_label f.Emo_ir.fname);
  gput env "    addi sp, sp, -%d\n" frm.size;
  gput env "    sd ra, 0(sp)\n";
  gput env "    la t0, %s\n" done_label;
  gput env "    ld t1, 0(t0)\n";
  gput env "    bnez t1, %s\n" hit;
  (* The body writes into [frm.fbuf] through [put]; its `return` jumps
     to the store label, so the value is in a0 when the store block
     runs. Everything after the prologue shares the frame buffer, and
     the whole function is appended to the module in one place — the
     order [emit_function] keeps. *)
  List.iter (emit_stmt env) f.Emo_ir.fbody;
  put env "%s:\n" store;
  put env "    la t2, %s\n" val_label;
  (match conv.cresult with
  | R_int64 ->
      if native then put env "    sd a0, 0(t2)\n"
      else begin
        put env "    andi a0, a0, -32\n";
        put env "    ld a0, 8(a0)\n";
        put env "    sd a0, 0(t2)\n"
      end
  | R_float64 ->
      if native then put env "    fsd fa0, 0(t2)\n"
      else begin
        put env "    andi t0, a0, -32\n";
        put env "    fld fa0, 8(t0)\n";
        put env "    fsd fa0, 0(t2)\n"
      end
  | R_word | R_void -> put env "    sd a0, 0(t2)\n");
  put env "    li t1, 1\n";
  put env "    la t0, %s\n" done_label;
  put env "    sd t1, 0(t0)\n";
  put env "%s:\n" hit;
  put env "    la t0, %s\n" val_label;
  put env "    ld a0, 0(t0)\n";
  (match conv.cresult with
  | R_float64 -> put env "    fmv.d.x fa0, a0\n"
  | R_int64 | R_word | R_void -> ());
  put env "    ld ra, 0(sp)\n";
  put env "    addi sp, sp, %d\n" frm.size;
  put env "    ret\n";
  Buffer.add_buffer env.buf frm.fbuf;
  env.cur <- None

(* One function: label, prologue (ra + the param/capture spill), body,
   epilogue. A closure body takes its record in t0 and spills the
   captures into its own slots at entry. The convention (T2.1) drives
   the prologue and epilogue: a dynamic conv is all P_word/R_word, so
   it emits exactly the old shape; a typed conv spills each raw param
   to its slot. A native body (T2.2 — a fully typed def) stops there:
   the params stay raw, the locals and arithmetic stay raw, and the
   result answers in its rule-1 representation — no adapters at all. A
   dynamic body boxes its raw numeric params in place (after the
   captures, whose record rides in t0 — the boxing calls clobber the
   argument registers) and unboxes the tagged result at the return
   label. *)
let emit_function env ~(label : string) ~(params : (string * Emo_check.t) list)
    ~(captures : string list) ~(conv : conv) ~(native : bool)
    ~(body : Emo_ir.stmt list) : unit =
  if List.length params > 8 then refuse "a def with more than eight parameters";
  let f =
    {
      fbuf = Buffer.create 512;
      slots = [];
      named = 0;
      temps = 0;
      ret = fresh_label env "ret";
      size = 0;
      fconv = conv;
      raw = [];
    }
  in
  let nparams = List.length params in
  f.slots <-
    List.mapi (fun i (n, _) -> (n, i)) params
    @ List.mapi (fun i n -> (n, nparams + i)) captures;
  f.named <- nparams + List.length captures;
  (* a native body's typed numeric params hold raw payloads *)
  if native then
    f.raw <-
      List.filter_map
        (fun (n, t) ->
          match t with
          | Emo_check.Int64 | Emo_check.Float64 -> Some (n, t)
          | _ -> None)
        params;
  env.cur <- Some f;
  env.native <- native;
  collect_stmts f body;
  f.temps <- stmts_depth body + 2;
  f.size <- (8 + (8 * (f.named + f.temps)) + 15) / 16 * 16;
  gput env "%s:\n" label;
  gput env "    addi sp, sp, -%d\n" f.size;
  gput env "    sd ra, 0(sp)\n";
  (* every raw param to its own slot first — the boxing calls clobber
     the argument registers, so nothing may still ride in one *)
  List.iteri
    (fun i (k, reg) ->
      let off = 8 + (8 * i) in
      match k with
      | P_float64 -> gput env "    fsd fa%d, %d(sp)\n" reg off
      | _ -> gput env "    sd a%d, %d(sp)\n" reg off)
    (bank_assign conv.cparams);
  List.iteri
    (fun i _ ->
      gput env "    ld t1, %d(t0)\n" (16 + (8 * i));
      gput env "    sd t1, %d(sp)\n" (8 + (8 * (nparams + i))))
    captures;
  (* the dynamic body's entry adapter: box each raw numeric param into
     the cell the body reads *)
  if not native then
    List.iteri
      (fun i k ->
        let off = 8 + (8 * i) in
        match k with
        | P_int64 ->
            gput env "    ld a0, %d(sp)\n" off;
            gput env "    call emo_box_i64\n";
            gput env "    sd a0, %d(sp)\n" off
        | P_float64 ->
            gput env "    fld fa0, %d(sp)\n" off;
            gput env "    call emo_box_f64\n";
            gput env "    sd a0, %d(sp)\n" off
        | P_word -> ())
      conv.cparams;
  List.iter (emit_stmt env) body;
  (* Fall-off: the statement walk already left a final expression
     statement's value in a0 (fa0 for a Float64-typed fall-off in a
     native body); a Void body just returns. *)
  put env "%s:\n" f.ret;
  if not native then emit_unbox_result env conv.cresult;
  put env "    ld ra, 0(sp)\n";
  put env "    addi sp, sp, %d\n" f.size;
  put env "    ret\n";
  Buffer.add_buffer env.buf f.fbuf;
  env.cur <- None

(* A constructor: the params arrive in a0.., the fresh instance (with
   its class id and zeroed fields) binds self, the init body runs, and
   self returns. *)
let emit_ctor env (c : Emo_ir.class_) (info : class_info) : unit =
  let ctor = c.Emo_ir.cname ^ "__new" in
  let real_params =
    match c.Emo_ir.cinit with
    | Some init -> List.tl init.Emo_ir.fparams
    | None -> []
  in
  let body =
    match c.Emo_ir.cinit with Some init -> init.Emo_ir.fbody | None -> []
  in
  if List.length real_params > 7 then
    refuse (Printf.sprintf "the constructor `%s.new`" c.Emo_ir.cdisplay);
  let f =
    {
      fbuf = Buffer.create 512;
      slots = [];
      named = 0;
      temps = 0;
      ret = fresh_label env "ret";
      size = 0;
      fconv = dynamic_conv (List.length real_params + 1);
      raw = [];
    }
  in
  let nparams = List.length real_params in
  f.slots <-
    List.mapi (fun i (n, _) -> (n, i)) real_params @ [ ("self", nparams) ];
  f.named <- nparams + 1;
  env.cur <- Some f;
  env.native <- false;
  env.fclass <- Some c.Emo_ir.cdisplay;
  collect_stmts f body;
  f.temps <- stmts_depth body + 2;
  f.size <- (8 + (8 * (f.named + f.temps)) + 15) / 16 * 16;
  gput env "%s:\n" (func_label ctor);
  gput env "    addi sp, sp, -%d\n" f.size;
  gput env "    sd ra, 0(sp)\n";
  List.iteri
    (fun i _ -> gput env "    sd a%d, %d(sp)\n" i (8 + (8 * i)))
    real_params;
  gput env "    li a0, %d\n" info.cls_id;
  gput env "    li a1, %d\n" (List.length info.cls_fields);
  gput env "    call emo_instance_new\n";
  gput env "    sd a0, %d(sp)\n" (8 + (8 * nparams));
  List.iter (emit_stmt env) body;
  put env "    ld a0, %d(sp)\n" (8 + (8 * nparams));
  put env "%s:\n" f.ret;
  put env "    ld ra, 0(sp)\n";
  put env "    addi sp, sp, %d\n" f.size;
  put env "    ret\n";
  Buffer.add_buffer env.buf f.fbuf;
  env.fclass <- None;
  env.cur <- None

(* ---- The runtime ---- *)

(* The assembly opens with the architecture attribute in every shape: it
   precedes whatever code follows, the compiler's boot stub or a
   package-provided one. *)
let arch_directive = "    .attribute arch, \"rv64gc\"\n"

(* The boot stub: the image's entry discipline. This is the one piece of
   the runtime a package may replace (EmoOS T3.1) — a package's
   `runtime.S` takes the image's entry over while the runtime body below
   stays: `emo_runtime_init`, `emo_program`, the allocator, and every
   other symbol the generated code calls remain the compiler's. The stub
   owns the entry symbol the linker script names (the default script's
   `ENTRY(emo_start)`) and the boot discipline — a kernel package writes
   its own and never touches this one. *)
let boot_stub_asm =
  {asm|
# ---- The freestanding runtime ----
#
# Boot profile A: OpenSBI enters emo_start in S-mode with a0 = hart id
# and a1 = the DTB pointer. Non-boot harts park forever; the boot hart
# clears .bss, sets the stack, initializes the heap cursor, runs the
# program, and asks SBI to power off (legacy a7 = 8 — under QEMU the
# machine exits 0).

    .section .text
    .globl emo_start
emo_start:
    bnez a0, emo_park
    la sp, emo_stack_top
    la t0, __emo_bss_start
    la t1, __emo_bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    call emo_runtime_init
    call emo_program
    li a7, 8
    ecall
emo_park:
    wfi
    j emo_park
|asm}

(* The user profile's boot stub (EmoOS T4.1): the kernel loads this image
   and enters it in U-mode through sret — a0 is whatever the kernel left,
   not a hart id, and the SBI is unreachable from U-mode. The stub owns
   no CSR: it clears .bss, sets its own stack (the image carries it in
   .bss), runs the program, and exits with the shutdown ecall — which
   lands in the kernel, the exit verb the gate answers (T4.1) and the
   syscall dispatch generalizes (T4.2). *)
let user_boot_stub_asm =
  {asm|
# ---- The user profile's boot stub (EmoOS T4.1) ----
#
# The kernel loads the image and enters it in U-mode through sret: a0 is
# the kernel's, not a hart id, and the SBI is unreachable from U-mode.
# No runtime CSRs — the stub clears .bss, sets the stack the image
# carries, runs the program, and exits with the shutdown ecall, which
# lands in the kernel: the exit verb the gate answers.

    .section .text
    .globl emo_start
emo_start:
    la sp, emo_stack_top
    la t0, __emo_bss_start
    la t1, __emo_bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    call emo_runtime_init
    call emo_program
    li a7, 8
    ecall
3:
    wfi
    j 3b
|asm}

(* The runtime body: everything the generated code calls — the heap
   cursor's init, the bump allocator, failure, boxing, the atomic
   helpers, the dynamic dispatch and formatting support. The compiler
   always provides it; a package's boot stub calls into it like the
   program does. *)
let runtime_asm =
  {asm|# ---- The bump allocator ----
#
# emo_alloc: a0 = payload words, a0 = the block (raw pointer, header
# word first). Exhaustion is a loud failure; the tagged layout stays
# ready for a collector.

    .globl emo_runtime_init
emo_runtime_init:
    la t0, emo_heap_start
    la t1, emo_heap_cursor
    sd t0, 0(t1)
    # the process world (EmoOS T3.3): pid 1 is the root, running now on
    # the boot stack; every other slot is free, the run queue empty
    la t0, emo_pid_counter
    li t1, 1
    sd t1, 0(t0)
    la t0, emo_cur_slot
    la t1, emo_procs
    sd t1, 0(t0)
    li t2, 1
    sd t2, 8(t1)            # the root's pid
    sd t2, 16(t1)           # alive
    ret

    .globl emo_alloc
emo_alloc:
    addi t0, a0, 1
    slli t0, t0, 3
    addi t0, t0, 31
    andi t0, t0, -32
    la t1, emo_heap_cursor
    ld t2, 0(t1)
    add t3, t2, t0
    la t4, emo_heap_end
    bgeu t3, t4, emo_heap_gone
    sd t3, 0(t1)
    sd a0, 0(t2)
    mv a0, t2
    ret
emo_heap_gone:
    la a0, msg_heap
    la a1, msg_heap_end
    call emo_fail

# ---- Failure ----

# emo_console_emit: a0 = the byte. Through the console hook when one is
# parked — a tail call, the hook answers the runtime's own caller — else
# the legacy console ecall (a7 = 1, which the ecall leaves alone).
emo_console_emit:
    la t0, emo_console_hook
    ld t0, 0(t0)
    beqz t0, 1f
    jr t0
1:
    li a7, 1
    ecall
    ret

# emo_print_bytes: a0 = start, a1 = end; every byte through the console
# hook or the legacy ecall. The walk rides the saved registers — the
# hook is a call like any other.
    .globl emo_print_bytes
emo_print_bytes:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    mv s0, a0
    mv s1, a1
.Lpb:
    bgeu s0, s1, .Lpb_done
    lbu a0, 0(s0)
    call emo_console_emit
    addi s0, s0, 1
    j .Lpb
.Lpb_done:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    addi sp, sp, 32
    ret

# emo_fail: a0 = message start, a1 = end; announce and power off.
    .globl emo_fail
emo_fail:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd a0, 8(sp)
    sd a1, 16(sp)
    la a0, msg_prefix
    la a1, msg_prefix_end
    call emo_print_bytes
    ld a0, 8(sp)
    ld a1, 16(sp)
    call emo_print_bytes
    li a0, 10
    call emo_console_emit
    li a7, 8
    ecall
.Lfail_park:
    wfi
    j .Lfail_park

# ---- Boxing ----

# emo_box_i64: a0 = the integer, a0 = the tagged Int64 cell (tag 0, so
# the tagged word is the pointer itself).
    .globl emo_box_i64
emo_box_i64:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd a0, 8(sp)
    li a0, 1
    call emo_alloc
    ld t0, 8(sp)
    sd t0, 8(a0)
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_box_f64: fa0 = the double, a0 = the tagged cell.
    .globl emo_box_f64
emo_box_f64:
    addi sp, sp, -16
    sd ra, 0(sp)
    fsd fa0, 8(sp)
    li a0, 1
    call emo_alloc
    fld fa0, 8(sp)
    fsd fa0, 8(a0)
    ori a0, a0, 2
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_box_new: a0 = any value, a0 = a fresh Box holding it.
    .globl emo_box_new
emo_box_new:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd a0, 8(sp)
    li a0, 1
    call emo_alloc
    ld t0, 8(sp)
    sd t0, 8(a0)
    ori a0, a0, 10
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# ---- Atomics ----
#
# The Atomic cell: Box's synchronized sibling (docs/atomics.md) —
# [header][word], tag 16, the word a tagged dynamic value (a boxed
# Int64 or a Bool immediate), the shape the c runtime keeps. Sequential
# consistency by the ISA's recommended mapping: a load is
# fence rw,rw; ld; fence r,rw — a store or an exchange is
# amoswap.d.aqrl — and compare_exchange and the fetch_* family are
# LR/SC loops over the word. The payload is a boxed pointer, so the
# arithmetic decodes, computes under the Int64 wrap rule, boxes, and
# swaps the word in against the exact word it read; a cell that moved
# meanwhile is read again. The AMO arithmetic (amoadd and its family)
# lands when Stage B gives the cell a raw word. Every helper takes the
# psABI (a0 = cell, a1 = v, a2 = fresh) so the dynamic dispatch jumps
# to it directly.

# emo_atomic_new: a0 = any value; a0 = a fresh Atomic holding it. The
# initial word is published with the sequential-consistency store.
    .globl emo_atomic_new
emo_atomic_new:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd a0, 8(sp)
    li a0, 1
    call emo_alloc
    ld t0, 8(sp)
    fence rw, w
    sd t0, 8(a0)
    fence rw, rw
    ori a0, a0, 16
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_atomic_load: a0 = cell; a0 = the value the cell holds.
    .globl emo_atomic_load
emo_atomic_load:
    andi t0, a0, -32
    fence rw, rw
    ld a0, 8(t0)
    fence r, rw
    ret

# emo_atomic_store: a0 = cell, a1 = v; the cell holds v. `store`
# answers nothing; a0 keeps the cell for the statement to discard.
    .globl emo_atomic_store
emo_atomic_store:
    andi t0, a0, -32
    addi t0, t0, 8
    amoswap.d.aqrl zero, a1, (t0)
    ret

# emo_atomic_exchange: a0 = cell, a1 = v; a0 = the previous value.
    .globl emo_atomic_exchange
emo_atomic_exchange:
    andi t0, a0, -32
    addi t0, t0, 8
    amoswap.d.aqrl a0, a1, (t0)
    ret

# emo_atomic_compare_exchange: a0 = cell, a1 = expected, a2 = fresh;
# a0 = the tuple (swapped, the value the cell held before). The
# comparison is content equality on the word read (emo_eq_deep: two
# boxed Int64 holding the same bits are equal), then the swap is an
# LR/SC against that exact word — the reservation covers only the
# instructions between lr and sc, so the deep compare runs outside it
# and a word that moved meanwhile sends the read around again. A
# mismatch answers (false, actual); nothing raises.
    .globl emo_atomic_compare_exchange
emo_atomic_compare_exchange:
    addi sp, sp, -48
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    andi s0, a0, -32
    addi s0, s0, 8
    mv s1, a1
    mv s2, a2
.Lcas_read:
    fence rw, rw
    ld s3, 0(s0)
    fence r, rw
    mv a0, s3
    mv a1, s1
    call emo_eq_deep
    andi t0, a0, 16
    beqz t0, .Lcas_miss
.Lcas_try:
    lr.d.aqrl t1, (s0)
    bne t1, s3, .Lcas_read
    sc.d.rl t2, s2, (s0)
    bnez t2, .Lcas_try
    li t0, 1
    j .Lcas_pack
.Lcas_miss:
    li t0, 0
.Lcas_pack:
    sd t0, 40(sp)
    li a0, 3
    call emo_alloc
    li t0, 2
    sd t0, 8(a0)
    ld t0, 40(sp)
    slli t0, t0, 4
    addi t0, t0, 1
    sd t0, 16(a0)
    sd s3, 24(a0)
    ori a0, a0, 6
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    addi sp, sp, 48
    ret

# The fetch_* family: a0 = cell, a1 = v; a0 = the value the cell held
# before. t6 selects the operation (0 add, 1 sub, 2 and, 3 or, 4 xor)
# on the way into the shared body. An Int64 word decodes both cells,
# computes in the wrap rule, and boxes the result; a Bool word takes
# the logical family on the immediates and allocates nothing. Any other
# word, or an operand of the wrong shape, is a loud failure — the
# checker refuses these statically; a dynamic receiver reaches here.
    .globl emo_atomic_fetch_add
emo_atomic_fetch_add:
    li t6, 0
    j emo_atomic_rmw
    .globl emo_atomic_fetch_sub
emo_atomic_fetch_sub:
    li t6, 1
    j emo_atomic_rmw
    .globl emo_atomic_fetch_and
emo_atomic_fetch_and:
    li t6, 2
    j emo_atomic_rmw
    .globl emo_atomic_fetch_or
emo_atomic_fetch_or:
    li t6, 3
    j emo_atomic_rmw
    .globl emo_atomic_fetch_xor
emo_atomic_fetch_xor:
    li t6, 4
    j emo_atomic_rmw

emo_atomic_rmw:
    addi sp, sp, -64
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    andi s0, a0, -32
    addi s0, s0, 8
    mv s1, a1
    mv s4, t6
.Lrmw_read:
    fence rw, rw
    ld s2, 0(s0)
    fence r, rw
    andi t0, s2, 1
    bnez t0, .Lrmw_bool
    andi t0, s2, 31
    bnez t0, .Lrmw_kind
    andi t0, s1, 31
    bnez t0, .Lrmw_kind
    ld t0, 8(s2)
    ld t1, 8(s1)
    beqz s4, .Lrmw_add
    li t2, 1
    beq s4, t2, .Lrmw_sub
    li t2, 2
    beq s4, t2, .Lrmw_and
    li t2, 3
    beq s4, t2, .Lrmw_or
    xor a0, t0, t1
    j .Lrmw_box
.Lrmw_add:
    add a0, t0, t1
    j .Lrmw_box
.Lrmw_sub:
    sub a0, t0, t1
    j .Lrmw_box
.Lrmw_and:
    and a0, t0, t1
    j .Lrmw_box
.Lrmw_or:
    or a0, t0, t1
.Lrmw_box:
    call emo_box_i64
    mv s3, a0
    j .Lrmw_try
.Lrmw_bool:
    andi t0, s2, 15
    li t1, 1
    bne t0, t1, .Lrmw_kind
    andi t0, s1, 15
    bne t0, t1, .Lrmw_kind
    srli t0, s2, 4
    andi t0, t0, 1
    srli t1, s1, 4
    andi t1, t1, 1
    li t2, 2
    beq s4, t2, .Lrmw_band
    li t2, 3
    beq s4, t2, .Lrmw_bor
    li t2, 4
    beq s4, t2, .Lrmw_bxor
    j .Lrmw_kind
.Lrmw_band:
    and t0, t0, t1
    j .Lrmw_bpack
.Lrmw_bor:
    or t0, t0, t1
    j .Lrmw_bpack
.Lrmw_bxor:
    xor t0, t0, t1
.Lrmw_bpack:
    slli t0, t0, 4
    addi s3, t0, 1
.Lrmw_try:
    lr.d.aqrl t1, (s0)
    bne t1, s2, .Lrmw_read
    sc.d.rl t2, s3, (s0)
    bnez t2, .Lrmw_try
    mv a0, s2
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    addi sp, sp, 64
    ret
.Lrmw_kind:
    la a0, msg_atomic_kind
    la a1, msg_atomic_kind_end
    call emo_fail

# emo_instance_new: a0 = class id, a1 = field count; a0 = the tagged
# instance with zeroed fields.
    .globl emo_instance_new
emo_instance_new:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd a0, 8(sp)
    sd a1, 16(sp)
    addi a0, a1, 1
    call emo_alloc
    ld t0, 8(sp)
    sd t0, 8(a0)
    ld t1, 16(sp)
    beqz t1, .Lin_done
    addi t2, a0, 16
.Lin_zero:
    sd zero, 0(t2)
    addi t2, t2, 8
    addi t1, t1, -1
    bnez t1, .Lin_zero
.Lin_done:
    ori a0, a0, 14
    ld ra, 0(sp)
    addi sp, sp, 32
    ret

# ---- Raw memory ----
#
# The volatile lanes (docs/raw-memory.md): peek8/poke8 over Byte,
# peek64/poke64 over Int64. Each is one load or store where the program
# put it — never elided, never reordered against its siblings. The
# address is exactly what the program named; a bad one traps.

# emo_peek8: a0 = the address (an Int64 cell); a0 = the byte, a Byte
# immediate, read unsigned.
    .globl emo_peek8
emo_peek8:
    andi a0, a0, -32
    ld t0, 8(a0)
    lbu t0, 0(t0)
    slli a0, t0, 4
    ori a0, a0, 7
    ret

# emo_poke8: a0 = the address, a1 = the Byte immediate.
    .globl emo_poke8
emo_poke8:
    andi a0, a0, -32
    ld t0, 8(a0)
    srli t1, a1, 4
    sb t1, 0(t0)
    ret

# emo_peek64: a0 = the address; a0 = the word, a boxed Int64.
    .globl emo_peek64
emo_peek64:
    addi sp, sp, -16
    sd ra, 0(sp)
    andi a0, a0, -32
    ld t0, 8(a0)
    ld a0, 0(t0)
    call emo_box_i64
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_poke64: a0 = the address, a1 = a boxed Int64.
    .globl emo_poke64
emo_poke64:
    andi a0, a0, -32
    ld t0, 8(a0)
    andi a1, a1, -32
    ld t1, 8(a1)
    sd t1, 0(t0)
    ret

# ---- Strings ----
#
# Block layout: [header][length][bytes padded to 8]. Field access runs
# on the untagged pointer.

# emo_string_lit: a0 = rodata bytes, a1 = length; a0 = a fresh String.
    .globl emo_string_lit
emo_string_lit:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd a0, 8(sp)
    sd a1, 16(sp)
    addi t0, a1, 7
    srli t0, t0, 3
    addi t0, t0, 1
    mv a0, t0
    call emo_alloc
    ld t1, 16(sp)
    sd t1, 8(a0)
    ld t3, 8(sp)
    ld t4, 16(sp)
    addi t2, a0, 16
    beqz t4, .Lsl_done
.Lsl_copy:
    lbu t5, 0(t3)
    sb t5, 0(t2)
    addi t3, t3, 1
    addi t2, t2, 1
    addi t4, t4, -1
    bnez t4, .Lsl_copy
.Lsl_done:
    ori a0, a0, 4
    ld ra, 0(sp)
    addi sp, sp, 32
    ret

# emo_alloc_string: a0 = length; a0 = an uninitialized String.
    .globl emo_alloc_string
emo_alloc_string:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd a0, 8(sp)
    addi t0, a0, 7
    srli t0, t0, 3
    addi t0, t0, 1
    mv a0, t0
    call emo_alloc
    ld t1, 8(sp)
    sd t1, 8(a0)
    ori a0, a0, 4
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_blit: a0 = raw destination cursor, a1 = String; a0 = past the copy.
    .globl emo_blit
emo_blit:
    andi a1, a1, -32
    ld t0, 8(a1)
    beqz t0, .Lbl_done
    addi t1, a1, 16
.Lbl_copy:
    lbu t2, 0(t1)
    sb t2, 0(a0)
    addi t1, t1, 1
    addi a0, a0, 1
    addi t0, t0, -1
    bnez t0, .Lbl_copy
.Lbl_done:
    ret

# emo_string_concat: a0 = a1 = Strings; a0 = a fresh String.
    .globl emo_string_concat
emo_string_concat:
    addi sp, sp, -48
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    andi s0, a0, -32
    andi s1, a1, -32
    ld t0, 8(s0)
    ld t1, 8(s1)
    add s2, t0, t1
    mv a0, s2
    call emo_alloc_string
    andi t0, a0, -32
    addi t2, t0, 16
    ld t3, 8(s0)
    addi t4, s0, 16
    beqz t3, .Lsc_second
.Lsc_first:
    lbu t5, 0(t4)
    sb t5, 0(t2)
    addi t4, t4, 1
    addi t2, t2, 1
    addi t3, t3, -1
    bnez t3, .Lsc_first
.Lsc_second:
    ld t3, 8(s1)
    addi t4, s1, 16
    beqz t3, .Lsc_done
.Lsc_copy2:
    lbu t5, 0(t4)
    sb t5, 0(t2)
    addi t4, t4, 1
    addi t2, t2, 1
    addi t3, t3, -1
    bnez t3, .Lsc_copy2
.Lsc_done:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 48
    ret

# emo_str_content: a0 = a1 = untagged String blocks; a0 = a Bool
# immediate (content equality). emo_string_eq and emo_eq_deep ride it.
    .globl emo_str_content
emo_str_content:
    ld t0, 8(a0)
    ld t1, 8(a1)
    bne t0, t1, .Lstc_ne
    beqz t0, .Lstc_eq
    addi t2, a0, 16
    addi t3, a1, 16
.Lstc_loop:
    lbu t4, 0(t2)
    lbu t5, 0(t3)
    bne t4, t5, .Lstc_ne
    addi t2, t2, 1
    addi t3, t3, 1
    addi t0, t0, -1
    bnez t0, .Lstc_loop
.Lstc_eq:
    li a0, 17
    ret
.Lstc_ne:
    li a0, 1
    ret

# emo_string_eq: a0 = a1 = Strings; a0 = a Bool immediate (content).
    .globl emo_string_eq
emo_string_eq:
    andi a0, a0, -32
    andi a1, a1, -32
    tail emo_str_content

# ---- Arrays ----

# emo_array_append: a0 = an Array, a1 = a value; a0 = a fresh Array
# with the value on the end (the original is untouched).
    .globl emo_array_append
emo_array_append:
    addi sp, sp, -48
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    andi s0, a0, -32
    mv s1, a1
    ld s2, 8(s0)
    addi a0, s2, 2
    call emo_alloc
    addi t1, s2, 1
    sd t1, 8(a0)
    addi t2, a0, 16
    addi t3, s0, 16
    mv t5, s2
    beqz t5, .Lap_last
.Lap_copy:
    ld t4, 0(t3)
    sd t4, 0(t2)
    addi t3, t3, 8
    addi t2, t2, 8
    addi t5, t5, -1
    bnez t5, .Lap_copy
.Lap_last:
    sd s1, 0(t2)
    ori a0, a0, 8
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 48
    ret

# ---- Content equality ----

# emo_eq_deep: a0 = a1 = dynamic values; a0 = a Bool immediate. Word
# equality settles immediates and shared pointers; same-tag heap blocks
# compare fieldwise (strings by content, boxes deref, instances by
# class id and fields, closures by identity).
    .globl emo_eq_deep
emo_eq_deep:
    addi sp, sp, -64
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    beq a0, a1, .Leq_yes
    andi t0, a0, 1
    andi t1, a1, 1
    xor t2, t0, t1
    bnez t2, .Leq_no
    andi t2, a0, 31
    andi t3, a1, 31
    bne t2, t3, .Leq_no
    bnez t0, .Leq_no
    andi s0, a0, -32
    andi s1, a1, -32
    beqz t2, .Leq_cell
    li t0, 2
    beq t2, t0, .Leq_cell
    li t0, 4
    beq t2, t0, .Leq_str
    li t0, 6
    beq t2, t0, .Leq_seq
    li t0, 8
    beq t2, t0, .Leq_seq
    li t0, 10
    beq t2, t0, .Leq_box
    li t0, 12
    beq t2, t0, .Leq_no
    li t0, 16
    beq t2, t0, .Leq_atomic
    li t0, 18
    beq t2, t0, .Leq_no
    j .Leq_inst
.Leq_cell:
    ld t0, 8(s0)
    ld t1, 8(s1)
    sub t0, t0, t1
    seqz t0, t0
    j .Leq_pack
.Leq_str:
    mv a0, s0
    mv a1, s1
    call emo_str_content
    j .Leq_raw
.Leq_seq:
    ld t0, 8(s0)
    ld t1, 8(s1)
    bne t0, t1, .Leq_no
    addi s2, s0, 16
    addi s3, s1, 16
    mv s4, t0
    beqz s4, .Leq_yes
.Leq_seq_loop:
    ld a0, 0(s2)
    ld a1, 0(s3)
    call emo_eq_deep
    andi t0, a0, 16
    beqz t0, .Leq_no
    addi s2, s2, 8
    addi s3, s3, 8
    addi s4, s4, -1
    bnez s4, .Leq_seq_loop
    j .Leq_yes
.Leq_box:
    ld a0, 8(s0)
    ld a1, 8(s1)
    call emo_eq_deep
    j .Leq_raw
.Leq_atomic:
    # the values the cells hold now, each an atomic load
    fence rw, rw
    ld a0, 8(s0)
    ld a1, 8(s1)
    fence r, rw
    call emo_eq_deep
    j .Leq_raw
.Leq_inst:
    ld t0, 8(s0)
    ld t1, 8(s1)
    bne t0, t1, .Leq_no
    ld s4, 0(s0)
    addi s4, s4, -1
    addi s2, s0, 16
    addi s3, s1, 16
    beqz s4, .Leq_yes
.Leq_inst_loop:
    ld a0, 0(s2)
    ld a1, 0(s3)
    call emo_eq_deep
    andi t0, a0, 16
    beqz t0, .Leq_no
    addi s2, s2, 8
    addi s3, s3, 8
    addi s4, s4, -1
    bnez s4, .Leq_inst_loop
    j .Leq_yes
.Leq_yes:
    li t0, 1
    j .Leq_pack
.Leq_no:
    li t0, 0
.Leq_pack:
    slli t0, t0, 4
    addi t0, t0, 1
    mv a0, t0
.Leq_raw:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    addi sp, sp, 64
    ret

# ---- Dynamic dispatch ----
#
# The checker loses the static type on self.x and cross-module values,
# so fields and methods resolve by name at run time (the c target's
# emo_field_by_name / emo_dynamic_builtin). Each class 0..n-1 carries a
# field-name table and a method table; emo_field_tables and emo_mtbls
# hold one pointer per class id.

# emo_field_index: a0 = untagged instance, a1 = name bytes, a2 = length;
# a0 = the field's index (or a loud failure).
    .globl emo_field_index
emo_field_index:
    ld t0, 8(a0)
    la t1, emo_field_tables
    slli t0, t0, 3
    add t1, t1, t0
    ld t1, 0(t1)
    beqz t1, .Lfi_fail
    ld t2, 0(t1)
    addi t1, t1, 16
    li t3, 0
.Lfi_loop:
    beqz t2, .Lfi_fail
    ld t4, 0(t1)
    ld t5, 8(t1)
    bne t5, a2, .Lfi_next
    mv t6, a2
.Lfi_cmp:
    beqz t6, .Lfi_hit
    addi t6, t6, -1
    add t5, t4, t6
    add t0, a1, t6
    lbu t5, 0(t5)
    lbu t0, 0(t0)
    bne t5, t0, .Lfi_next
    j .Lfi_cmp
.Lfi_hit:
    mv a0, t3
    ret
.Lfi_next:
    addi t3, t3, 1
    addi t1, t1, 16
    addi t2, t2, -1
    j .Lfi_loop
.Lfi_fail:
    la a0, msg_field
    la a1, msg_field_end
    call emo_fail

# emo_dyn_method: a0.. carry self + the args exactly as the impl wants
# them; t0 = name bytes, t1 = name length. Resolution touches only the
# t/s registers of its own frame, then jumps: the impl returns straight
# to emo_dyn_method's caller with the result in a0.
    .globl emo_dyn_method
emo_dyn_method:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    mv s0, t0
    mv s1, t1
    andi t2, a0, 1
    bnez t2, .Ldm_imm
    andi t2, a0, 31
    beqz t2, .Ldm_scalar
    li t3, 2
    beq t2, t3, .Ldm_scalar
    li t3, 4
    beq t2, t3, .Ldm_scalar
    li t3, 8
    beq t2, t3, .Ldm_scalar
    li t3, 10
    beq t2, t3, .Ldm_scalar
    li t3, 16
    beq t2, t3, .Ldm_atomic
    li t3, 14
    bne t2, t3, .Ldm_fail
    # an instance: the class's method table first
    ld t3, 8(a0)
    la t4, emo_mtbls
    slli t3, t3, 3
    add t4, t4, t3
    ld t4, 0(t4)
    beqz t4, .Ldm_builtin
    mv s2, t4
    ld t5, 0(s2)
    addi s2, s2, 16
.Ldm_mloop:
    beqz t5, .Ldm_builtin
    ld t6, 0(s2)
    ld t2, 8(s2)
    bne t2, s1, .Ldm_mnext
    mv t2, s1
.Ldm_mcmp:
    beqz t2, .Ldm_mhit
    addi t2, t2, -1
    add t3, t6, t2
    add t4, s0, t2
    lbu t3, 0(t3)
    lbu t4, 0(t4)
    bne t3, t4, .Ldm_mnext
    j .Ldm_mcmp
.Ldm_mhit:
    ld t2, 16(s2)
    j .Ldm_go
.Ldm_mnext:
    addi s2, s2, 24
    addi t5, t5, -1
    j .Ldm_mloop
.Ldm_imm:
    # Bool/Char/enum immediates: only to_string
    li t2, 9
    bne t1, t2, .Ldm_fail
    la t3, name_to_string
    la t6, .Ldm_to_string
    j .Ldm_namecmp
.Ldm_scalar:
    # Int64/Float64/String/Array cells
    li t4, 9
    beq t1, t4, .Ldm_sc_ts
    li t4, 6
    beq t1, t4, .Ldm_sc_len
    # an Array cell also answers append; a Box answers read/replace
    li t4, 8
    beq t2, t4, .Ldm_arr
    li t4, 10
    beq t2, t4, .Ldm_box
    j .Ldm_fail
.Ldm_arr:
    li t4, 6
    bne t1, t4, .Ldm_fail
    la t3, name_append
    la t6, .Ldm_append
    j .Ldm_namecmp
.Ldm_box:
    li t4, 4
    beq t1, t4, .Ldm_box_r
    li t4, 7
    beq t1, t4, .Ldm_box_w
    j .Ldm_fail
.Ldm_box_r:
    la t3, name_read
    la t6, .Ldm_do_read
    j .Ldm_namecmp
.Ldm_box_w:
    la t3, name_replace
    la t6, .Ldm_do_repl
    j .Ldm_namecmp
.Ldm_do_read:
    andi a0, a0, -32
    ld a0, 8(a0)
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    ret
.Ldm_do_repl:
    andi t0, a0, -32
    sd a1, 8(t0)
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    ret
.Ldm_append:
    la t2, emo_array_append
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    jr t2
.Ldm_sc_ts:
    la t3, name_to_string
    la t6, .Ldm_to_string
    j .Ldm_namecmp
.Ldm_sc_len:
    la t3, name_length
    la t6, .Ldm_length
    j .Ldm_namecmp
.Ldm_builtin:
    # no such method on the instance: the scalar builtins still answer
    li t2, 9
    beq t1, t2, .Ldm_sc_ts
    li t2, 6
    beq t1, t2, .Ldm_sc_len
    j .Ldm_fail
.Ldm_atomic:
    # an Atomic cell: the op set and to_string, by name through
    # emo_atomic_mtbl ([name][length][impl], zero-terminated); the impl
    # takes a0.. as they stand
    la s2, emo_atomic_mtbl
.Ldm_at_loop:
    ld t3, 0(s2)
    beqz t3, .Ldm_fail
    ld t4, 8(s2)
    bne t4, s1, .Ldm_at_next
    mv t2, s1
.Ldm_at_cmp:
    beqz t2, .Ldm_at_hit
    addi t2, t2, -1
    add t5, t3, t2
    add t6, s0, t2
    lbu t5, 0(t5)
    lbu t6, 0(t6)
    bne t5, t6, .Ldm_at_next
    j .Ldm_at_cmp
.Ldm_at_hit:
    ld t2, 16(s2)
    j .Ldm_go
.Ldm_at_next:
    addi s2, s2, 24
    j .Ldm_at_loop
.Ldm_namecmp:
    mv t2, s1
.Ldm_nloop:
    beqz t2, .Ldm_nhit
    addi t2, t2, -1
    add t4, t3, t2
    add t5, s0, t2
    lbu t4, 0(t4)
    lbu t5, 0(t5)
    bne t4, t5, .Ldm_fail
    j .Ldm_nloop
.Ldm_nhit:
    jr t6
.Ldm_to_string:
    la t2, emo_to_string
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    jr t2
.Ldm_length:
    andi a0, a0, -32
    ld a0, 8(a0)
    call emo_box_i64
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    ret
.Ldm_go:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    jr t2
.Ldm_fail:
    la a0, msg_method
    la a1, msg_method_end
    call emo_fail

# ---- Dynamic arithmetic ----
#
# emo_add_dyn / emo_sub_dyn / emo_mul_dyn / emo_lt_dyn / emo_le_dyn:
# a0 = a1 = dynamic values; the result boxed or a Bool immediate
# (Gt/Ge swap their operands at the call site).

    .globl emo_add_dyn
emo_add_dyn:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    andi s0, a0, -32
    andi s1, a1, -32
    andi t0, a0, 31
    andi t1, a1, 31
    bne t0, t1, .Ldyn_bad
    beqz t0, .Lad_int
    li t2, 2
    beq t0, t2, .Lad_float
    li t2, 4
    beq t0, t2, .Lad_str
    j .Ldyn_bad
.Lad_int:
    ld a0, 8(s0)
    ld a1, 8(s1)
    add a0, a0, a1
    call emo_box_i64
    j .Ldyn_done
.Lad_float:
    fld fa0, 8(s0)
    fld fa1, 8(s1)
    fadd.d fa0, fa0, fa1
    call emo_box_f64
    j .Ldyn_done
.Lad_str:
    mv a0, s0
    ori a0, a0, 4
    mv a1, s1
    ori a1, a1, 4
    call emo_string_concat
    j .Ldyn_done
.Ldyn_done:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    addi sp, sp, 32
    ret

    .globl emo_sub_dyn
emo_sub_dyn:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    andi s0, a0, -32
    andi s1, a1, -32
    andi t0, a0, 31
    andi t1, a1, 31
    bne t0, t1, .Ldyn_bad
    beqz t0, .Lsb_int
    li t2, 2
    beq t0, t2, .Lsb_float
    j .Ldyn_bad
.Lsb_int:
    ld a0, 8(s0)
    ld a1, 8(s1)
    sub a0, a0, a1
    call emo_box_i64
    j .Ldyn_done
.Lsb_float:
    fld fa0, 8(s0)
    fld fa1, 8(s1)
    fsub.d fa0, fa0, fa1
    call emo_box_f64
    j .Ldyn_done

    .globl emo_mul_dyn
emo_mul_dyn:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    andi s0, a0, -32
    andi s1, a1, -32
    andi t0, a0, 31
    andi t1, a1, 31
    bne t0, t1, .Ldyn_bad
    beqz t0, .Lmu_int
    li t2, 2
    beq t0, t2, .Lmu_float
    j .Ldyn_bad
.Lmu_int:
    ld a0, 8(s0)
    ld a1, 8(s1)
    mul a0, a0, a1
    call emo_box_i64
    j .Ldyn_done
.Lmu_float:
    fld fa0, 8(s0)
    fld fa1, 8(s1)
    fmul.d fa0, fa0, fa1
    call emo_box_f64
    j .Ldyn_done

    .globl emo_lt_dyn
emo_lt_dyn:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    andi s0, a0, -32
    andi s1, a1, -32
    andi t0, a0, 31
    andi t1, a1, 31
    bne t0, t1, .Ldyn_bad
    beqz t0, .Llt_int
    li t2, 2
    beq t0, t2, .Llt_float
    j .Ldyn_bad
.Llt_int:
    ld a0, 8(s0)
    ld a1, 8(s1)
    slt t0, a0, a1
    j .Lcmp_pack
.Llt_float:
    fld fa0, 8(s0)
    fld fa1, 8(s1)
    flt.d t0, fa0, fa1
    j .Lcmp_pack

    .globl emo_le_dyn
emo_le_dyn:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    andi s0, a0, -32
    andi s1, a1, -32
    andi t0, a0, 31
    andi t1, a1, 31
    bne t0, t1, .Ldyn_bad
    beqz t0, .Lle_int
    li t2, 2
    beq t0, t2, .Lle_float
    j .Ldyn_bad
.Lle_int:
    ld a0, 8(s0)
    ld a1, 8(s1)
    slt t0, a1, a0
    xori t0, t0, 1
    j .Lcmp_pack
.Lle_float:
    fld fa0, 8(s0)
    fld fa1, 8(s1)
    fle.d t0, fa0, fa1
.Lcmp_pack:
    slli t0, t0, 4
    addi t0, t0, 1
    mv a0, t0
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    addi sp, sp, 32
    ret
.Ldyn_bad:
    la a0, msg_arith
    la a1, msg_arith_end
    call emo_fail

# ---- to-string ----

# emo_i64_to_string: a0 = the integer; a0 = a String. The magnitude is
# computed unsigned — INT64_MIN negates to 2^63, which the unsigned
# divide handles — and the digits land backward in a stack buffer,
# then reverse into a fresh block.
    .globl emo_i64_to_string
emo_i64_to_string:
    addi sp, sp, -80
    sd ra, 0(sp)
    li t3, 10
    bgez a0, .Lig_pos
    sub t0, x0, a0
    li t1, 1
    j .Lig_mag
.Lig_pos:
    mv t0, a0
    li t1, 0
.Lig_mag:
    addi t2, sp, 48
.Lig_digit:
    remu t4, t0, t3
    addi t4, t4, 48
    addi t2, t2, -1
    sb t4, 0(t2)
    divu t0, t0, t3
    bnez t0, .Lig_digit
    beqz t1, .Lig_count
    li t4, 45
    addi t2, t2, -1
    sb t4, 0(t2)
.Lig_count:
    addi t3, sp, 48
    sub t3, t3, t2
    sd t2, 56(sp)
    sd t3, 64(sp)
    mv a0, t3
    call emo_alloc_string
    andi t0, a0, -32
    addi t0, t0, 16
    ld t1, 56(sp)
    ld t2, 64(sp)
.Lig_copy:
    beqz t2, .Lig_done
    lbu t3, 0(t1)
    sb t3, 0(t0)
    addi t1, t1, 1
    addi t0, t0, 1
    addi t2, t2, -1
    j .Lig_copy
.Lig_done:
    ld ra, 0(sp)
    addi sp, sp, 80
    ret

# emo_to_string: a0 = any dynamic value; a0 = a String. The dispatch a
# String part or a println argument rides.
    .globl emo_to_string
emo_to_string:
    addi sp, sp, -16
    sd ra, 0(sp)
    andi t0, a0, 1
    bnez t0, .Lts_imm
    andi t0, a0, 31
    beqz t0, .Lts_i64
    li t1, 4
    beq t0, t1, .Lts_done
    li t1, 2
    beq t0, t1, .Lts_f64
    li t1, 16
    beq t0, t1, .Lts_atomic
    li t1, 18
    beq t0, t1, .Lts_pid
    la a0, msg_kind
    la a1, msg_kind_end
    call emo_fail
.Lts_i64:
    andi a0, a0, -32
    ld a0, 8(a0)
    call emo_i64_to_string
    j .Lts_done
.Lts_f64:
    andi t0, a0, -32
    fld fa0, 8(t0)
    call emo_f64_to_string
    j .Lts_done
.Lts_atomic:
    la a0, msg_atomic
    li a1, 8
    call emo_string_lit
    j .Lts_done
.Lts_pid:
    # "<pid N>" — the hosted rendering
    addi sp, sp, -16
    sd ra, 0(sp)
    andi t0, a0, -32
    ld a0, 8(t0)
    call emo_i64_to_string
    andi t1, a0, -32
    ld t2, 8(t1)            # the digits' length
    addi sp, sp, -16
    sd a0, 0(sp)
    addi a0, t2, 6
    call emo_alloc_string
    ld t1, 0(sp)
    addi sp, sp, 16
    andi t0, a0, -32
    andi t1, t1, -32
    ld t2, 8(t1)
    addi t3, t1, 16
    addi t4, t0, 16
    li t5, 60
    sb t5, 0(t4)
    li t5, 112
    sb t5, 1(t4)
    li t5, 105
    sb t5, 2(t4)
    li t5, 100
    sb t5, 3(t4)
    li t5, 32
    sb t5, 4(t4)
    addi t4, t4, 5
.Lts_pid_copy:
    beqz t2, .Lts_pid_tail
    lbu t5, 0(t3)
    sb t5, 0(t4)
    addi t3, t3, 1
    addi t4, t4, 1
    addi t2, t2, -1
    j .Lts_pid_copy
.Lts_pid_tail:
    li t5, 62
    sb t5, 0(t4)
    ld ra, 0(sp)            # this arm's own frame — .Lts_done pops only
    addi sp, sp, 16         # the entry frame, so restore ours first
    j .Lts_done
.Lts_imm:
    srli t1, a0, 1
    andi t1, t1, 7
    beqz t1, .Lts_bool
    li t2, 1
    beq t1, t2, .Lts_char
    li t2, 3
    beq t1, t2, .Lts_byte
    la a0, msg_kind
    la a1, msg_kind_end
    call emo_fail
.Lts_byte:
    srli a0, a0, 4
    andi a0, a0, 255
    call emo_i64_to_string
    j .Lts_done
.Lts_bool:
    andi t0, a0, 16
    beqz t0, .Lts_false
    la a0, msg_true
    li a1, 4
    call emo_string_lit
    j .Lts_done
.Lts_false:
    la a0, msg_false
    li a1, 5
    call emo_string_lit
    j .Lts_done
.Lts_char:
    srli t0, a0, 4
    andi t0, t0, 255
    sd t0, 8(sp)
    li a0, 1
    call emo_alloc_string
    ld t0, 8(sp)
    andi t1, a0, -32
    sb t0, 16(t1)
    j .Lts_done
.Lts_done:
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_f64_to_string: fa0 = the double; a0 = a String. The rule every
# target shares: an integral value below 1e16 in magnitude is written
# with one decimal place ("2.0", "-0.0"); everything else takes %g —
# six significant digits, trailing fractional zeros trimmed, the
# exponent form below 1e-4 or at 1e6 and above.
#
# The exponent comes from the binary exponent (log10(2) in 12-bit
# fixed point), then a down loop and an up loop against the pow10 table
# settle it. The six digits are y * 10^(5-e) rounded to an integer; the
# product rides as a double-double pair (the table holds each power as
# hi + lo and FMSUB recovers the high product's exact residual), so
# a value close to a half-integer still rounds as %g rounds it, and a
# true tie (a half with nothing after it) rounds to even. Values
# below 1e-300 are first multiplied by 1e300 (the result is still
# normal) and the exponent is offset back.
    .globl emo_f64_to_string
emo_f64_to_string:
    addi sp, sp, -128
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    fmv.x.d t0, fa0
    li t1, 0x7ff0000000000000
    and t2, t0, t1
    beq t2, t1, .Lfs_special
    li t2, 0x7fffffffffffffff
    and t2, t0, t2
    beqz t2, .Lfs_zero
    srli t2, t0, 63
    sd t2, 48(sp)
    # integral and |f| < 1e16?
    fabs.d fa1, fa0
    la t2, emo_f64_1e16
    fld fa2, 0(t2)
    flt.d t2, fa1, fa2
    beqz t2, .Lfs_g6
    fcvt.l.d a0, fa0, rtz
    fcvt.d.l fa2, a0, rtz
    feq.d t2, fa2, fa0
    beqz t2, .Lfs_g6
    # the integer, then ".0" appended to a fresh block
    call emo_i64_to_string
    andi t0, a0, -32
    ld t1, 8(t0)
    sd t0, 56(sp)
    sd t1, 64(sp)
    addi a0, t1, 2
    call emo_alloc_string
    andi t2, a0, -32
    addi t2, t2, 16
    ld t0, 56(sp)
    ld t1, 64(sp)
    addi t3, t0, 16
.Lfs_int_copy:
    beqz t1, .Lfs_int_dot
    lbu t4, 0(t3)
    sb t4, 0(t2)
    addi t3, t3, 1
    addi t2, t2, 1
    addi t1, t1, -1
    j .Lfs_int_copy
.Lfs_int_dot:
    li t4, 46
    sb t4, 0(t2)
    li t4, 48
    sb t4, 1(t2)
    j .Lfs_done
.Lfs_special:
    li t2, 0x000fffffffffffff
    and t2, t0, t2
    bnez t2, .Lfs_nan
    bltz t0, .Lfs_neg_inf
    la a0, msg_inf
    li a1, 3
    call emo_string_lit
    j .Lfs_done
.Lfs_neg_inf:
    la a0, msg_neg_inf
    li a1, 4
    call emo_string_lit
    j .Lfs_done
.Lfs_nan:
    la a0, msg_nan
    li a1, 3
    call emo_string_lit
    j .Lfs_done
.Lfs_zero:
    bltz t0, .Lfs_neg_zero
    la a0, msg_zero
    li a1, 3
    call emo_string_lit
    j .Lfs_done
.Lfs_neg_zero:
    la a0, msg_neg_zero
    li a1, 4
    call emo_string_lit
    j .Lfs_done
.Lfs_g6:
    fabs.d fa0, fa0
    li t0, 0
    sd t0, 72(sp)
    la t0, emo_f64_1e_300
    fld fa1, 0(t0)
    flt.d t0, fa0, fa1
    beqz t0, .Lfs_norm
    la t0, emo_f64_1e300
    fld fa1, 0(t0)
    fmul.d fa0, fa0, fa1
    li t0, -300
    sd t0, 72(sp)
.Lfs_norm:
    fmv.x.d t0, fa0
    srli t0, t0, 52
    andi t0, t0, 0x7ff
    addi t0, t0, -1023
    li t1, 1233
    mul t0, t0, t1
    srai t0, t0, 12
    sd t0, 80(sp)
    # settle the decimal exponent against the table's powers of ten
.Lfs_e_down:
    ld t0, 80(sp)
    li t1, -303
    ble t0, t1, .Lfs_e_up
    addi t2, t0, 303
    slli t2, t2, 3
    la t1, emo_pow10
    add t1, t1, t2
    fld fa1, 0(t1)
    flt.d t2, fa0, fa1
    beqz t2, .Lfs_e_up
    addi t0, t0, -1
    sd t0, 80(sp)
    j .Lfs_e_down
.Lfs_e_up:
    ld t0, 80(sp)
    li t1, 308
    bge t0, t1, .Lfs_scale
    addi t2, t0, 1
    addi t2, t2, 303
    slli t2, t2, 3
    la t1, emo_pow10
    add t1, t1, t2
    fld fa1, 0(t1)
    flt.d t2, fa0, fa1
    bnez t2, .Lfs_scale
    addi t0, t0, 1
    sd t0, 80(sp)
    j .Lfs_e_up
.Lfs_scale:
    ld t0, 80(sp)
    li t1, 5
    sub t2, t1, t0
    addi t2, t2, 303
    slli t2, t2, 3
    la t1, emo_pow10
    add t3, t1, t2
    fld fa1, 0(t3)
    la t1, emo_pow10_lo
    add t3, t1, t2
    fld fa2, 0(t3)
    fmul.d fa3, fa0, fa1
    fmsub.d fa4, fa0, fa1, fa3
    fmul.d fa5, fa0, fa2
    fadd.d fa4, fa4, fa5
    fcvt.l.d s0, fa3, rdn
    fcvt.d.l fa5, s0
    fsub.d fa5, fa3, fa5
    la t1, emo_f64_half
    fld fa6, 0(t1)
    la t1, emo_f64_eps
    fld fa2, 0(t1)
    fsub.d fa7, fa5, fa6
    fabs.d fa7, fa7
    flt.d t0, fa7, fa2
    beqz t0, .Lfs_round_plain
    # A value within a rounding error of a half may still be an exact
    # decimal tie (x = odd * 5^m * 2^(m-1) up to the significand's
    # trailing zeros, with m = e - 5): compare the double's significand
    # against the scaled odd integer and round a true tie to even.
    ld t0, 72(sp)
    bnez t0, .Lfs_tie_sign
    ld t0, 80(sp)
    addi t0, t0, -5
    blez t0, .Lfs_tie_sign
    li t1, 16
    blt t1, t0, .Lfs_tie_sign
    fmv.x.d t1, fa0
    srli t2, t1, 52
    andi t2, t2, 0x7ff
    addi t2, t2, -1075
    li t3, 0x000fffffffffffff
    and t1, t1, t3
    li t3, 0x0010000000000000
    or t1, t1, t3
    addi t2, t2, 1
    sub t2, t0, t2
    bltz t2, .Lfs_tie_sign
    li t3, 52
    blt t3, t2, .Lfs_tie_sign
    srl t3, t1, t2
    li t4, 1
    sll t4, t4, t2
    addi t4, t4, -1
    and t4, t1, t4
    bnez t4, .Lfs_tie_sign
    slli t4, s0, 1
    addi t4, t4, 1
    la t5, emo_pow5
    addi t6, t0, -1
    slli t6, t6, 3
    add t5, t5, t6
    ld t5, 0(t5)
    mul t4, t4, t5
    bne t3, t4, .Lfs_tie_sign
    andi t0, s0, 1
    beqz t0, .Lfs_round_keep
    j .Lfs_round_up
.Lfs_tie_sign:
    flt.d t0, fa6, fa5
    bnez t0, .Lfs_round_up
    flt.d t0, fa5, fa6
    bnez t0, .Lfs_round_keep
    fmv.d.x fa6, x0
    flt.d t0, fa6, fa4
    bnez t0, .Lfs_round_up
    flt.d t0, fa4, fa6
    bnez t0, .Lfs_round_keep
    andi t0, s0, 1
    beqz t0, .Lfs_round_keep
    j .Lfs_round_up
.Lfs_round_plain:
    flt.d t0, fa6, fa5
    beqz t0, .Lfs_round_keep
.Lfs_round_up:
    addi s0, s0, 1
.Lfs_round_keep:
    li t0, 1000000
    bne s0, t0, .Lfs_digits
    li s0, 100000
    ld t0, 80(sp)
    addi t0, t0, 1
    sd t0, 80(sp)
.Lfs_digits:
    addi t1, sp, 101
    li t2, 10
    mv t3, s0
    li t4, 6
.Lfs_digit_loop:
    remu t5, t3, t2
    addi t5, t5, 48
    sb t5, 0(t1)
    divu t3, t3, t2
    addi t1, t1, -1
    addi t4, t4, -1
    bnez t4, .Lfs_digit_loop
    addi s1, sp, 96
    li s2, 6
.Lfs_trim:
    li t0, 1
    ble s2, t0, .Lfs_form
    add t0, s1, s2
    lbu t0, -1(t0)
    li t1, 48
    bne t0, t1, .Lfs_form
    addi s2, s2, -1
    j .Lfs_trim
.Lfs_form:
    ld t0, 80(sp)
    ld t1, 72(sp)
    add t0, t0, t1
    sd t0, 80(sp)
    li t1, -4
    blt t0, t1, .Lfs_sci
    li t1, 6
    bge t0, t1, .Lfs_sci
    j .Lfs_plain
.Lfs_plain:
    addi s3, sp, 104
    ld t0, 48(sp)
    beqz t0, .Lfs_plain_dot
    li t1, 45
    sb t1, 0(s3)
    addi s3, s3, 1
.Lfs_plain_dot:
    ld t0, 80(sp)
    bgez t0, .Lfs_plain_int
    li t1, 48
    sb t1, 0(s3)
    li t1, 46
    sb t1, 1(s3)
    addi s3, s3, 2
    sub t2, x0, t0
    addi t2, t2, -1
.Lfs_plain_zero:
    beqz t2, .Lfs_plain_frac
    li t1, 48
    sb t1, 0(s3)
    addi s3, s3, 1
    addi t2, t2, -1
    j .Lfs_plain_zero
.Lfs_plain_frac:
    mv t2, s2
    mv t3, s1
.Lfs_plain_fcopy:
    beqz t2, .Lfs_emit
    lbu t1, 0(t3)
    sb t1, 0(s3)
    addi t3, t3, 1
    addi s3, s3, 1
    addi t2, t2, -1
    j .Lfs_plain_fcopy
.Lfs_plain_int:
    addi t2, t0, 1
    mv t3, s1
.Lfs_plain_icopy:
    beqz t2, .Lfs_plain_idone
    lbu t1, 0(t3)
    sb t1, 0(s3)
    addi t3, t3, 1
    addi s3, s3, 1
    addi t2, t2, -1
    j .Lfs_plain_icopy
.Lfs_plain_idone:
    addi t2, t0, 1
    sub t2, s2, t2
    blez t2, .Lfs_emit
    li t1, 46
    sb t1, 0(s3)
    addi s3, s3, 1
    add t3, s1, t0
    addi t3, t3, 1
.Lfs_plain_dcopy:
    beqz t2, .Lfs_emit
    lbu t1, 0(t3)
    sb t1, 0(s3)
    addi t3, t3, 1
    addi s3, s3, 1
    addi t2, t2, -1
    j .Lfs_plain_dcopy
.Lfs_sci:
    addi s3, sp, 104
    ld t0, 48(sp)
    beqz t0, .Lfs_sci_head
    li t1, 45
    sb t1, 0(s3)
    addi s3, s3, 1
.Lfs_sci_head:
    lbu t1, 0(s1)
    sb t1, 0(s3)
    addi s3, s3, 1
    li t2, 1
    ble s2, t2, .Lfs_sci_exp
    li t1, 46
    sb t1, 0(s3)
    addi s3, s3, 1
    addi t3, s1, 1
    addi t2, s2, -1
.Lfs_sci_fcopy:
    beqz t2, .Lfs_sci_exp
    lbu t1, 0(t3)
    sb t1, 0(s3)
    addi t3, t3, 1
    addi s3, s3, 1
    addi t2, t2, -1
    j .Lfs_sci_fcopy
.Lfs_sci_exp:
    li t1, 101
    sb t1, 0(s3)
    addi s3, s3, 1
    ld t0, 80(sp)
    bgez t0, .Lfs_sci_plus
    li t1, 45
    sb t1, 0(s3)
    sub t0, x0, t0
    j .Lfs_sci_sign
.Lfs_sci_plus:
    li t1, 43
    sb t1, 0(s3)
.Lfs_sci_sign:
    addi s3, s3, 1
    addi t1, sp, 127
    li t2, 10
    mv t3, t0
    li t4, 0
.Lfs_sci_digit:
    remu t5, t3, t2
    addi t5, t5, 48
    addi t1, t1, -1
    sb t5, 0(t1)
    divu t3, t3, t2
    addi t4, t4, 1
    bnez t3, .Lfs_sci_digit
    li t5, 2
    bge t4, t5, .Lfs_sci_ecopy
    li t5, 48
    addi t1, t1, -1
    sb t5, 0(t1)
    addi t4, t4, 1
.Lfs_sci_ecopy:
    beqz t4, .Lfs_emit
    lbu t5, 0(t1)
    sb t5, 0(s3)
    addi t1, t1, 1
    addi s3, s3, 1
    addi t4, t4, -1
    j .Lfs_sci_ecopy
.Lfs_emit:
    addi t0, sp, 104
    sub t1, s3, t0
    sd t0, 56(sp)
    sd t1, 64(sp)
    mv a0, t1
    call emo_alloc_string
    andi t2, a0, -32
    addi t2, t2, 16
    ld t0, 56(sp)
    ld t1, 64(sp)
.Lfs_emit_copy:
    beqz t1, .Lfs_done
    lbu t3, 0(t0)
    sb t3, 0(t2)
    addi t0, t0, 1
    addi t2, t2, 1
    addi t1, t1, -1
    j .Lfs_emit_copy
.Lfs_done:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    addi sp, sp, 128
    ret

# emo_println: a0 = any dynamic value; the string form, a newline.
    .globl emo_println
emo_println:
    addi sp, sp, -16
    sd ra, 0(sp)
    call emo_to_string
    andi a0, a0, -32
    ld a1, 8(a0)
    addi a0, a0, 16
    add a1, a0, a1
    call emo_print_bytes
    li a0, 10
    call emo_console_emit
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# ---- The messages ----

    .section .rodata
msg_prefix:
    .ascii "emo runtime: "
msg_prefix_end:
msg_true:
    .ascii "true"
msg_true_end:
msg_false:
    .ascii "false"
msg_false_end:
msg_heap:
    .ascii "the value heap is exhausted"
msg_heap_end:
msg_blocked:
    .ascii "all processes are blocked; no message will ever arrive"
msg_blocked_end:
msg_procs:
    .ascii "the process table is exhausted"
msg_procs_end:
msg_noproc:
    .ascii "a message was sent to a process that does not exist"
msg_noproc_end:
msg_mbox:
    .ascii "a process mailbox is full"
msg_mbox_end:
msg_nan:
    .ascii "nan"
msg_inf:
    .ascii "inf"
msg_neg_inf:
    .ascii "-inf"
msg_zero:
    .ascii "0.0"
msg_neg_zero:
    .ascii "-0.0"
msg_kind:
    .ascii "cannot convert this value to a string yet"
msg_kind_end:
msg_field:
    .ascii "no such field on this value"
msg_field_end:
msg_method:
    .ascii "no such method on this value"
msg_method_end:
msg_arith:
    .ascii "arithmetic on values of these kinds"
msg_arith_end:
msg_divzero:
    .ascii "division by zero"
msg_divzero_end:
msg_atomic:
    .ascii "<atomic>"
msg_atomic_kind:
    .ascii "an atomic operation on a value of this kind"
msg_atomic_kind_end:
msg_byte_range:
    .ascii "`Byte.from_int64` needs a value in 0-255"
msg_byte_range_end:
name_to_string:
    .ascii "to_string"
name_length:
    .ascii "length"
name_append:
    .ascii "append"
name_read:
    .ascii "read"
name_replace:
    .ascii "replace"
name_load:
    .ascii "load"
name_store:
    .ascii "store"
name_exchange:
    .ascii "exchange"
name_compare_exchange:
    .ascii "compare_exchange"
name_fetch_add:
    .ascii "fetch_add"
name_fetch_sub:
    .ascii "fetch_sub"
name_fetch_and:
    .ascii "fetch_and"
name_fetch_or:
    .ascii "fetch_or"
name_fetch_xor:
    .ascii "fetch_xor"

# The Atomic cell's dynamic method table: [name][length][impl], the
# impl taking the psABI registers as emo_dyn_method received them.
    .align 3
emo_atomic_mtbl:
    .quad name_load, 4, emo_atomic_load
    .quad name_store, 5, emo_atomic_store
    .quad name_exchange, 8, emo_atomic_exchange
    .quad name_compare_exchange, 16, emo_atomic_compare_exchange
    .quad name_fetch_add, 9, emo_atomic_fetch_add
    .quad name_fetch_sub, 9, emo_atomic_fetch_sub
    .quad name_fetch_and, 9, emo_atomic_fetch_and
    .quad name_fetch_or, 8, emo_atomic_fetch_or
    .quad name_fetch_xor, 9, emo_atomic_fetch_xor
    .quad name_to_string, 9, emo_to_string
    .quad 0, 0, 0

# ---- Processes: green threads on the boot hart (EmoOS T3.3) ----
#
# The root process runs emo_program on the boot stack; every spawned
# process owns one slot in emo_procs — its saved context, its pid, its
# state word, the scheduler's policy fields, and its bounded mailbox —
# and one stack in emo_pstacks. The discipline is the hosted
# scheduler's: spawn does not yield; send snapshots the message (the
# copy-on-send boundary), wakes a receiver parked on it, and yields the
# sender; receive scans the mailbox oldest-first, dequeues the first
# message its patterns accept, and parks on no match; the root exiting
# ends the program; a switch with nobody runnable is the loud deadlock.
#
# Slot layout (stride 72 words = 576 bytes): 0 the saved sp, 8 the pid,
# 16 the state (0 free, 1 alive, 2 receiving, 3 done, 4 device-wait),
# 24 the mailbox head, 32 the mailbox length, 40 the process's own
# priority, 48 its effective priority, 56 its CPU quota, 64.. the
# 32-word message ring, 320.. the 32-word ring of the priorities the
# messages carry (entry i of each ring belongs to the same message). A
# slot never returns to free — a pid is unique for the whole run, so a
# send to a dead pid is dropped, never redirected to a new occupant.
#
# The scheduler's policy (EmoOS T3.4): dispatch is round-robin — the
# run queue is a FIFO ring and emo_schedule pops its head. The priority
# and quota words are present and maintained, read by nothing yet: no
# surface sets a priority, so every one is 0 and the policy below is
# dormant until one does. A child inherits its spawner's own priority
# and quota. A message carries its sender's effective priority, and a
# process's effective priority is the maximum of its own and the
# priorities its queued messages carry — the asynchronous form of
# "the priorities of the processes waiting on it": raised at enqueue
# (the send-time donation), re-formed from the remaining messages at
# dequeue, so it is always a function of the wait graph the slots hold
# and never a stale residue. The quota is the CPU slice budget in
# ticks; the tick (T3.6) consumes it, and 0 is the unassigned value
# until then.
#
# Interrupt safety (T3.6): every function that mutates scheduler state
# — the run queue, the slot words, the cur-slot swap — opens with
# `csrci sstatus, 2` (SIE off) and, on every exit the resumed process
# flows through, closes with `csrsi sstatus, 2`. A timer interrupt
# therefore never lands inside a scheduler region: the trap entry
# hardware-masks interrupts, the ISR's own helpers assume the mask, and
# the one switch made under a mask records the mask in the context
# frame's spare word, which the switch-in restores — a process
# preempted or parked mid-region resumes still masked, and unmasks when
# its own region ends. Helpers called only from masked contexts (the
# run-queue push, the mailbox reads) toggle nothing.

    .section .text

# emo_runq_push: a0 = the slot; appends it to the run-queue ring.
    .globl emo_runq_push
emo_runq_push:
    addi sp, sp, -16
    sd ra, 0(sp)
    la t0, emo_runq_len
    ld t1, 0(t0)
    la t2, emo_runq_head
    ld t3, 0(t2)
    add t4, t3, t1
    andi t4, t4, 63
    slli t4, t4, 3
    la t5, emo_runq
    add t4, t4, t5
    sd a0, 0(t4)
    addi t1, t1, 1
    sd t1, 0(t0)
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_schedule: the caller's slot state and the run queue are already
# set (park = receiving and unqueued; yield = alive and enqueued). This
# saves the current context into the current slot, picks the next
# runnable, and switches. An empty queue is the loud deadlock — a wake
# happens only in a send, whose sender stays runnable, so nobody can
# ever arrive. The region is masked (T3.6); the spare word at 200(sp)
# records the mask for the switch-in, and the pick loads the incoming
# slot's quota into the tick's slice countdown. The pick half is its
# own entry — emo_sched_pick — for the tick's preemption path, which
# arrives with the victim's context already built.
    .globl emo_schedule
emo_schedule:
    csrci sstatus, 2
    addi sp, sp, -208
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    sd s5, 48(sp)
    sd s6, 56(sp)
    sd s7, 64(sp)
    sd s8, 72(sp)
    sd s9, 80(sp)
    sd s10, 88(sp)
    sd s11, 96(sp)
    fsd fs0, 104(sp)
    fsd fs1, 112(sp)
    fsd fs2, 120(sp)
    fsd fs3, 128(sp)
    fsd fs4, 136(sp)
    fsd fs5, 144(sp)
    fsd fs6, 152(sp)
    fsd fs7, 160(sp)
    fsd fs8, 168(sp)
    fsd fs9, 176(sp)
    fsd fs10, 184(sp)
    fsd fs11, 192(sp)
    csrr t6, sstatus
    andi t6, t6, 2
    sd t6, 200(sp)
    la t0, emo_cur_slot
    ld t1, 0(t0)
    sd sp, 0(t1)
    .globl emo_sched_pick
emo_sched_pick:
    la t0, emo_cur_slot
    la t2, emo_runq_len
    ld t3, 0(t2)
    beqz t3, emo_deadlock
    la t4, emo_runq_head
    ld t5, 0(t4)
    slli t6, t5, 3
    la a0, emo_runq
    add t6, t6, a0
    ld a1, 0(t6)
    addi t5, t5, 1
    andi t5, t5, 63
    sd t5, 0(t4)
    addi t3, t3, -1
    sd t3, 0(t2)
    sd a1, 0(t0)
    ld t2, 56(a1)
    la t3, emo_slice_left
    sd t2, 0(t3)
    ld sp, 0(a1)
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    ld s5, 48(sp)
    ld s6, 56(sp)
    ld s7, 64(sp)
    ld s8, 72(sp)
    ld s9, 80(sp)
    ld s10, 88(sp)
    ld s11, 96(sp)
    fld fs0, 104(sp)
    fld fs1, 112(sp)
    fld fs2, 120(sp)
    fld fs3, 128(sp)
    fld fs4, 136(sp)
    fld fs5, 144(sp)
    fld fs6, 152(sp)
    fld fs7, 160(sp)
    fld fs8, 168(sp)
    fld fs9, 176(sp)
    fld fs10, 184(sp)
    fld fs11, 192(sp)
    ld t0, 200(sp)
    beqz t0, .Lsched_sie_off
    csrsi sstatus, 2
    j .Lsched_sie_done
.Lsched_sie_off:
    csrci sstatus, 2
.Lsched_sie_done:
    addi sp, sp, 208
    ret
emo_deadlock:
    # nobody runnable: the machine may only wait when the device world
    # can wake someone — a state-4 device-waiter (T3.7). Otherwise the
    # classic loud deadlock: a wake happens only in a send, and no
    # sender exists.
    la t0, emo_procs
    li t1, 0
.Ldl_scan:
    li t2, 64
    bgeu t1, t2, emo_fail_blocked
    li t3, 576
    mul t4, t1, t3
    add t4, t0, t4
    ld t5, 16(t4)
    li t6, 4
    beq t5, t6, .Ldl_idle
    addi t1, t1, 1
    j .Ldl_scan
.Ldl_idle:
    la t0, emo_slice_left
    sd zero, 0(t0)           # the tick's quota step sleeps with the hart
    csrsi sstatus, 2         # the timer and the devices can land
    wfi
    csrci sstatus, 2         # back under the region's mask
    j emo_sched_pick         # the ISR may have queued someone
emo_fail_blocked:
    la a0, msg_blocked
    la a1, msg_blocked_end
    call emo_fail

# emo_sched_tick: the kernel timer ISR's quota step (T3.6). Consumes
# one tick of the running slice and answers a0 = 1 when the slice is
# spent — the ISR then calls emo_sched_preempt with the trap frame —
# and a0 = 0 when the quota is unassigned (0, the dormant case) or
# still counting. Interrupts are already masked at a trap entry; the
# helper allocates nothing and touches nothing the ISR does not own.
    .globl emo_sched_tick
emo_sched_tick:
    la t1, emo_slice_left
    ld t0, 0(t1)
    beqz t0, .Ltick_dormant
    addi t0, t0, -1
    sd t0, 0(t1)
    bnez t0, .Ltick_dormant
    li a0, 1
    ret
.Ltick_dormant:
    li a0, 0
    ret

# emo_sched_preempt: a0 = the trap frame's switch-section base on the
# victim's own stack — the frame the kernel's trap shim laid down, its
# top 208 bytes shaped exactly like the scheduler's context frame. The
# victim's slot takes that base as its saved sp and the resume hook as
# its ra (the frame keeps the interrupted ra below, for the resume
# stub), the victim re-joins the run queue, and the scheduler picks the
# next process — this call never returns to the ISR. Interrupts are
# already masked at a trap entry; nothing here allocates.
    .globl emo_sched_preempt
emo_sched_preempt:
    la t0, emo_cur_slot
    ld t0, 0(t0)
    sd a0, 0(t0)
    ld t1, emo_trap_resume_hook
    sd t1, 0(a0)
    mv a0, t0
    call emo_runq_push
    j emo_sched_pick

# emo_yield: the current process re-joins the run queue and gives the
# hart away; it resumes here when the scheduler picks it again. The
# region is masked; the resume unmask is this function's own exit.
    .globl emo_yield
emo_yield:
    csrci sstatus, 2
    addi sp, sp, -16
    sd ra, 0(sp)
    la t0, emo_cur_slot
    ld a0, 0(t0)
    call emo_runq_push
    call emo_schedule
    csrsi sstatus, 2
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_park_receive: the current process waits for its mailbox; it
# leaves the run queue, so only a send can put it back. Masked (T3.6);
# the switch away records the mask, and the wake resumes through this
# call's own exit — the unmask before the ret, so the scan the receive
# site runs next is unmasked, as the ISR expects.
    .globl emo_park_receive
emo_park_receive:
    csrci sstatus, 2
    addi sp, sp, -16
    sd ra, 0(sp)
    la t0, emo_cur_slot
    ld t1, 0(t0)
    li t2, 2
    sd t2, 16(t1)
    call emo_schedule
    csrsi sstatus, 2
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_park_console: the device-wait park (T3.7) — `device_wait` in the
# kernel's surface. The state is 4, a state only the device world
# wakes: the ISR's emo_sched_wake_console finds a 4, flips it to 1, and
# pushes the slot. A send does not wake a 4 — a request arriving while
# the driver sleeps just queues in its mailbox for the next pump — so
# the resume is exactly this call's return, no rescan, the mask
# discipline identical to the receive park's.
    .globl emo_park_console
emo_park_console:
    csrci sstatus, 2
    addi sp, sp, -16
    sd ra, 0(sp)
    la t0, emo_cur_slot
    ld t1, 0(t0)
    li t2, 4
    sd t2, 16(t1)
    call emo_schedule
    csrsi sstatus, 2
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_sched_wake_console: the ISR's wake for the device-wait park —
# the first state-4 slot becomes alive and re-joins the run queue.
# Called from a trap (interrupts hardware-masked); scans at most the
# 64 slots; a park that already ended (state not 4) is simply not
# found, and the byte the ISR enqueued waits in the ring.
    .globl emo_sched_wake_console
emo_sched_wake_console:
    addi sp, sp, -16
    sd ra, 0(sp)
    la t0, emo_procs
    li t1, 0
.Lwake_scan:
    li t2, 64
    bgeu t1, t2, .Lwake_none
    li t3, 576
    mul t4, t1, t3
    add t4, t0, t4
    ld t5, 16(t4)
    li t6, 4
    bne t5, t6, .Lwake_next
    li t5, 1
    sd t5, 16(t4)            # alive
    mv a0, t4
    call emo_runq_push
    ld ra, 0(sp)
    addi sp, sp, 16
    ret
.Lwake_next:
    addi t1, t1, 1
    j .Lwake_scan
.Lwake_none:
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_process_done: the entry thunk's return address — a spawned
# process that falls off its body lands here and never comes back. The
# root never does: its return goes to the boot stub, and the program
# ends with it, the hosted semantics.
    .globl emo_process_done
emo_process_done:
    csrci sstatus, 2
    la t0, emo_cur_slot
    ld t1, 0(t0)
    li t2, 3
    sd t2, 16(t1)
    j emo_schedule

# emo_spawn: a0 = the entry thunk, a1 = the argument count, a2 = the
# arguments (tagged words, copied into the child's fresh stack). The
# child's first schedule "returns" into the thunk; the thunk jumps to
# the body with ra = emo_process_done, so a returning body ends the
# process. Answers the child's Pid.
    .globl emo_spawn
emo_spawn:
    csrci sstatus, 2
    addi sp, sp, -40
    sd ra, 0(sp)
    sd a0, 8(sp)            # the entry thunk
    sd a1, 16(sp)           # the argument count
    sd a2, 24(sp)           # the arguments
    # a free slot: state 0, never reused once used
    la t0, emo_procs
    li t1, 0
    li t2, 64
.Lspawn_scan:
    bgeu t1, t2, .Lspawn_exhausted
    li t3, 576
    mul t4, t1, t3
    add t4, t0, t4
    ld t5, 16(t4)
    beqz t5, .Lspawn_found
    addi t1, t1, 1
    j .Lspawn_scan
.Lspawn_exhausted:
    la a0, msg_procs
    la a1, msg_procs_end
    call emo_fail
.Lspawn_found:
    mv t3, t4               # the slot; t3 keeps it through the bookkeeping
    la t5, emo_pid_counter
    ld t6, 0(t5)
    addi t6, t6, 1
    sd t6, 0(t5)
    sd t6, 8(t3)            # the slot's pid
    sd t6, 32(sp)           # it must survive the helper calls below
    li t5, 1
    sd t5, 16(t3)           # alive
    # the policy fields: the child inherits the spawner's own priority
    # and quota, and its effective priority starts at its own — its
    # mailbox is empty
    la t4, emo_cur_slot
    ld t4, 0(t4)
    ld t0, 40(t4)
    sd t0, 40(t3)
    sd t0, 48(t3)
    ld t0, 56(t4)
    sd t0, 56(t3)
    # the child's stack: one switch-shaped frame whose ra is the entry
    # thunk, the arguments just above it. The spare word records the
    # mask state the switch-in restores: the child is born outside any
    # scheduler region — its body's own send/receive/spawn calls open
    # and close their own — so it starts with interrupts enabled.
    addi t5, t1, 1
    slli t5, t5, 16
    la t6, emo_pstacks
    add t5, t5, t6
    addi t4, t5, -208
    ld t0, 8(sp)
    sd t0, 0(t4)            # ra = the entry thunk
    li t0, 1
    sd t0, 200(t4)          # the spare word: SIE on at the first dispatch
    sd t4, 0(t3)            # the slot's saved sp
    # copy the arguments
    ld t0, 16(sp)           # argc
    ld t1, 24(sp)           # src
    mv t2, t5               # dst
    beqz t0, .Lspawn_copied
.Lspawn_copy:
    ld t6, 0(t1)
    sd t6, 0(t2)
    addi t0, t0, -1
    addi t1, t1, 8
    addi t2, t2, 8
    bnez t0, .Lspawn_copy
.Lspawn_copied:
    mv a0, t3
    call emo_runq_push
    # the answer: [header][pid], the pointer tagged kind 9
    li a0, 1
    call emo_alloc
    ld t1, 32(sp)
    sd t1, 8(a0)
    ori a0, a0, 18
    csrsi sstatus, 2
    ld ra, 0(sp)
    addi sp, sp, 40
    ret

# emo_send: a0 = the target's Pid word, a1 = the message. The message
# snapshots at the boundary (the copy-on-send rule; an Atomic shares
# its cell), a full mailbox or an unknown pid is loud, the message
# carries the sender's effective priority and donates it to the target,
# a receiver gets woken, and the sender yields — a send never runs on
# into the next statement, the hosted discipline.
    .globl emo_send
emo_send:
    csrci sstatus, 2
    addi sp, sp, -48
    sd ra, 0(sp)
    sd a0, 8(sp)            # the target word
    sd a1, 16(sp)           # the message word
    andi t0, a0, -32
    ld t0, 8(t0)            # the pid number
    la t1, emo_procs
    li t2, 0
    li t3, 64
.Lsend_scan:
    bgeu t2, t3, .Lsend_noproc
    li t4, 576
    mul t5, t2, t4
    add t5, t1, t5
    ld t6, 8(t5)
    beq t6, t0, .Lsend_found
    addi t2, t2, 1
    j .Lsend_scan
.Lsend_noproc:
    la a0, msg_noproc
    la a1, msg_noproc_end
    call emo_fail
.Lsend_found:
    sd t5, 24(sp)           # the target slot
    ld t5, 16(t5)
    li t6, 3
    beq t5, t6, .Lsend_drop
    # snapshot the message at the boundary
    ld a0, 16(sp)
    call emo_copy_deep
    sd a0, 32(sp)           # the copy
    ld t4, 24(sp)           # the target slot
    # into the target's mailbox: 32 entries, oldest first — the message
    # word in one ring, the priority it carries in the other
    ld t0, 24(t4)           # head
    ld t1, 32(t4)           # length
    li t2, 32
    bge t1, t2, .Lsend_full
    add t3, t0, t1
    andi t3, t3, 31         # the entry
    slli t3, t3, 3
    addi t6, t3, 64
    add t6, t4, t6
    ld t5, 32(sp)
    sd t5, 0(t6)            # the message
    la t5, emo_cur_slot
    ld t5, 0(t5)
    ld t5, 48(t5)           # the sender's effective priority
    addi t6, t3, 320
    add t6, t4, t6
    sd t5, 0(t6)            # rides with the message
    addi t1, t1, 1
    sd t1, 32(t4)
    # the donation: the target's effective priority rises to the
    # sender's when the sender outranks it
    ld t6, 48(t4)
    bge t6, t5, .Lsend_wake
    sd t5, 48(t4)
.Lsend_wake:
    # wake a receiver; a live-but-running target needs nothing
    ld t5, 16(t4)
    li t6, 2
    bne t5, t6, .Lsend_drop
    li t5, 1
    sd t5, 16(t4)
    mv a0, t4
    call emo_runq_push
.Lsend_drop:
    # the yield: this process re-joins the run queue and the scheduler
    # switches away — the call returns when the process is next
    # scheduled, with its own frame still beneath the restored one
    la t0, emo_cur_slot
    ld a0, 0(t0)
    call emo_runq_push
    call emo_schedule
    csrsi sstatus, 2
    ld ra, 0(sp)
    addi sp, sp, 48
    ret
.Lsend_full:
    la a0, msg_mbox
    la a1, msg_mbox_end
    call emo_fail

# The mailbox reads, on the current slot's rings. [0] is the oldest.
    .globl emo_mb_count
emo_mb_count:
    la t0, emo_cur_slot
    ld t0, 0(t0)
    ld a0, 32(t0)
    ret

    .globl emo_mb_at
emo_mb_at:                      # a0 = the scan index; a0 = the word
    la t0, emo_cur_slot
    ld t0, 0(t0)
    ld t1, 24(t0)
    add t1, t1, a0
    andi t1, t1, 31
    slli t1, t1, 3
    addi t1, t1, 64
    add t0, t0, t1
    ld a0, 0(t0)
    ret

# emo_mb_remove: a0 = the scan index; the message leaves both rings —
# the entries after it shift down together — and the effective
# priority re-forms from what remains: the process's own, or the
# highest priority a queued message still carries.
    .globl emo_mb_remove
emo_mb_remove:
    la t0, emo_cur_slot
    ld t0, 0(t0)
    ld t1, 24(t0)
    add t1, t1, a0
    andi t1, t1, 31             # the position being removed
    ld t3, 32(t0)
    mv t2, a0
.Lmb_rm_loop:
    addi t4, t3, -1
    bgeu t2, t4, .Lmb_rm_done
    addi t5, t1, 1
    andi t5, t5, 31             # the position after it
    slli a1, t5, 3
    add a1, t0, a1
    ld a2, 64(a1)               # the next message
    ld a3, 320(a1)              # and the priority it carries
    slli a1, t1, 3
    add a1, t0, a1
    sd a2, 64(a1)               # both move down one
    sd a3, 320(a1)
    mv t1, t5
    addi t2, t2, 1
    j .Lmb_rm_loop
.Lmb_rm_done:
    ld t3, 32(t0)
    addi t3, t3, -1
    sd t3, 32(t0)
    ld t4, 40(t0)               # the floor: the process's own priority
    beqz t3, .Lmb_rm_eff
    ld t1, 24(t0)               # head
    mv t2, t3                   # the remaining messages, newest down
.Lmb_rm_scan:
    addi t2, t2, -1
    add a1, t1, t2
    andi a1, a1, 31
    slli a1, a1, 3
    add a1, t0, a1
    ld a2, 320(a1)
    bge t4, a2, .Lmb_rm_next
    mv t4, a2
.Lmb_rm_next:
    bnez t2, .Lmb_rm_scan
.Lmb_rm_eff:
    sd t4, 48(t0)
    ret

# emo_self_pid: a0 = the current process's Pid word.
    .globl emo_self_pid
emo_self_pid:
    addi sp, sp, -16
    sd ra, 0(sp)
    la t0, emo_cur_slot
    ld t0, 0(t0)
    ld a1, 8(t0)                # a1 rides emo_alloc untouched
    li a0, 1
    call emo_alloc
    sd a1, 8(a0)
    ori a0, a0, 18
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_copy_deep: a0 = a dynamic value; a0 = the deep copy. The
# copy-on-send boundary: a Box, a Tuple, an Array, or an instance
# arrives as a fresh block with every nested value copied; an Atomic
# shares its cell (the declared exception); an Int64 or Float64 cell,
# a String, a closure, and a Pid pass as-is — immutable data or
# identity, exactly the hosted snapshot's rule.
    .globl emo_copy_deep
emo_copy_deep:
    addi sp, sp, -64
    sd ra, 0(sp)                # 0 ra
    sd a0, 8(sp)                # 8 the word
    andi t0, a0, 1
    bnez t0, .Lcd_asis
    andi t0, a0, 31
    sd t0, 48(sp)               # 48 the tag, back onto the fresh block
    beqz t0, .Lcd_asis          # the Int64 cell
    li t1, 2
    beq t0, t1, .Lcd_asis       # the Float64 cell
    li t1, 4
    beq t0, t1, .Lcd_asis       # a String
    li t1, 12
    beq t0, t1, .Lcd_asis       # a closure
    li t1, 16
    beq t0, t1, .Lcd_asis       # an Atomic (the shared cell)
    li t1, 18
    beq t0, t1, .Lcd_asis       # a Pid (identity)
    li t1, 10
    beq t0, t1, .Lcd_box
    # 6 Tuple, 8 Array, 14 instance: a fresh block, verbatim header and
    # length/class word, every element or field copied
    andi t2, a0, -32
    sd t2, 24(sp)               # 24 the source block
    ld t3, 0(t2)
    sd t3, 32(sp)               # 32 the payload word count
    addi t3, t3, 1              # the elements end at block word hdr, so the
    sd t3, 32(sp)               #   bound is one past it (hdr counts payload
    mv a0, t3                   #   words 1..hdr; the elements are 2..hdr)
    call emo_alloc
    sd a0, 16(sp)               # 16 the new word
    ld t2, 24(sp)
    andi t4, a0, -32
    ld t5, 0(t2)
    sd t5, 0(t4)                # the header, verbatim
    ld t5, 8(t2)
    sd t5, 8(t4)                # the length or class id, verbatim
    li t6, 2
    sd t6, 40(sp)               # 40 the word index
.Lcd_loop:
    ld t2, 24(sp)
    ld t3, 32(sp)
    ld t6, 40(sp)
    bgeu t6, t3, .Lcd_wrap
    slli t5, t6, 3
    add t5, t2, t5
    ld a0, 0(t5)
    call emo_copy_deep
    ld t4, 16(sp)
    andi t4, t4, -32
    ld t6, 40(sp)
    slli t5, t6, 3
    add t5, t4, t5
    sd a0, 0(t5)
    addi t6, t6, 1
    sd t6, 40(sp)
    j .Lcd_loop
.Lcd_wrap:
    ld a0, 16(sp)
    ld t2, 48(sp)
    or a0, a0, t2               # the fresh block wears the original's tag
    j .Lcd_out
.Lcd_box:
    andi t0, a0, -32
    ld a0, 8(t0)
    call emo_copy_deep
    call emo_box_new
.Lcd_asis:
.Lcd_out:
    ld ra, 0(sp)
    addi sp, sp, 64
    ret
|asm}

(* The default linker script per profile. The kernel profile links at
   0x80200000, where OpenSBI's boot enters the payload (T0.1). The user
   profile links at 0x87100000 — the pre-SV39 user window's base, the
   one load address the kernel's ELF loader copies segments to (EmoOS
   T4.1): a page above the kernel's fixed rings, under the top of the
   board's 128 MiB. SV39 replaces the fixed window with per-process
   address spaces (M5). Two read-only segments and one read-write, so
   the loader sees honest permissions; .bss is NOBITS — the entry stub
   clears it, which is also why the stack and the value heap live there
   (no image weight). *)
let linker_script ~(profile : string) : string =
  let base =
    match profile with
    | "kernel" -> "0x80200000"
    | "user" -> "0x87100000"
    | other -> invalid_arg ("riscv: unknown image profile `" ^ other ^ "`")
  in
  Printf.sprintf
    {|OUTPUT_ARCH(riscv)
ENTRY(emo_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = %s;

  .text : { *(.text .text.*) } :text
  .rodata : { *(.rodata .rodata.*) } :text
  .data : { *(.data .data.*) } :data

  .bss : {
    . = ALIGN(16);
    __emo_bss_start = .;
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(16);
    __emo_bss_end = .;
  } :data

  /DISCARD/ : { *(.eh_frame .eh_frame_hdr .note .comment) }
}
|}
    base

(* The stack and the value heap live in .bss — NOBITS, so neither weighs
   on the image; the entry stub clears the region before first use, and
   the heap cursor sits past the heap's end. The sizes are the one thing
   the image profiles (EmoOS T4.1) change in the emitted runtime. The
   kernel profile keeps the 1 MiB stack and the 96 MiB heap: T2.1's
   boundary adapters forced the growth from 64 (a typed call in a
   dynamic body allocated on both sides), and T2.2's native bodies
   closed that window — `examples/fib`'s `count_down(1000000)` now runs
   its recursion allocation-free — but the headroom stays: dynamic
   bodies still box per operation, and the bump's exhaustion is loud by
   design. The user profile is the kernel's guest: one 64 KiB stack —
   the per-process stack size — over an 8 MiB heap, the budget that
   fits the pre-SV39 user window under the board's 128 MiB with the
   process world beside it; per-process quotas arrive with the arenas
   (EmoOS T5). QEMU virt's default 128 MiB holds both. *)
let stack_asm ~(profile : string) : string =
  let stack_bytes, heap_bytes =
    match profile with
    | "kernel" -> (1048576, 100663296)
    | "user" -> (65536, 8388608)
    | other -> invalid_arg ("riscv: unknown image profile `" ^ other ^ "`")
  in
  Printf.sprintf
    {|# ---- The stack and the value heap: .bss, cleared by the entry stub ----

    .section .bss
    .align 16
    .globl emo_stack_top
emo_stack_bottom:
    .zero %d
emo_stack_top:
    .globl emo_heap_start
emo_heap_start:
    .zero %d
    .globl emo_heap_end
emo_heap_end:
    .globl emo_heap_cursor
emo_heap_cursor:
    .zero 8

# ---- The process world (EmoOS T3.3): the slot table, the per-process
# ---- stacks, and the run queue ----
#
# 64 slots at 576 bytes (context word, pid, state, mailbox head and
# length, the own and effective priorities and the quota, a 32-word
# message ring and the 32-word ring of the priorities the messages
# carry), one 64 KiB stack per slot, and the run-queue ring. A slot
# never returns to free — pids stay unique for the whole run — so 64 is
# the bound on spawns ever taken, loud at the ceiling. Everything here
# is NOBITS: the image carries none of it.

    .align 8
emo_procs:
    .zero 36864
emo_pstacks:
    .zero 4194304
emo_runq:
    .zero 512
emo_runq_head:
    .zero 8
emo_runq_len:
    .zero 8
emo_pid_counter:
    .zero 8
emo_cur_slot:
    .zero 8

# ---- The console hook (EmoOS T3.5) ----
#
# Zero — what the entry stub's .bss clear leaves, and what the default
# stub never touches — means the legacy SBI console ecall. A kernel
# package's boot stub parks the raw entry of a fully typed Emo def here
# (the psABI discipline: the byte in a0, the callee's own frame
# discipline), and every console byte the runtime emits rides through
# it. SBI keeps the shutdown.

    .globl emo_console_hook
emo_console_hook:
    .zero 8

# ---- The tick's scheduler side (EmoOS T3.6) ----
#
# emo_slice_left is the running process's slice countdown in ticks: the
# dispatch loads it from the incoming slot's quota (0 = unassigned, the
# dormant case), and the kernel's timer ISR consumes it through
# `emo_sched_tick`, which answers 1 when the slice is spent — the ISR
# then hands the interrupted context to `emo_sched_preempt`, which
# re-queues the victim and dispatches the next process. Both answer to
# the ISR only: the trap entry hardware-masks interrupts, so neither
# can race the scheduler's own regions. emo_trap_resume_hook holds the
# address a preempted process resumes at — the trap frame's other half
# lives on the victim's own stack, and the hook (parked by the kernel's
# boot stub) restores it and srets home.

    .globl emo_slice_left
emo_slice_left:
    .zero 8
    .globl emo_trap_resume_hook
emo_trap_resume_hook:
    .zero 8
|}
    stack_bytes heap_bytes

(* The float formatter's tables: 10^k for every exponent the rule can
   produce (indexed by k + 303), as a double-double pair so the digit
   product carries about twice a double's precision, plus the constants
   the integral check and the deep-subnormal rescale read. The pairs
   come from double-double exponentiation by squaring; every power the
   tie rule can meet (|k| small) is exact, so its low half is zero. *)
let float_tables_asm =
  let split a =
    if a = 0.0 then (0.0, 0.0)
    else
      let s, inv =
        if Float.abs a > 1e292 then (3.725290298461914e-9, 268435456.0)
        else if Float.abs a < 1e-292 then (268435456.0, 3.725290298461914e-9)
        else (1.0, 1.0)
      in
      let a' = a *. s in
      let c = 134217729.0 *. a' in
      let hi = c -. (c -. a') in
      let lo = a' -. hi in
      (hi *. inv, lo *. inv)
  in
  let dd_mul (a, ae) (b, be) =
    let p = a *. b in
    let ah, al = split a in
    let bh, bl = split b in
    let err = (ah *. bh) -. p +. (ah *. bl) +. (al *. bh) +. (al *. bl) in
    let e = err +. (a *. be) +. (ae *. b) +. (ae *. be) in
    let s = p +. e in
    (s, p -. s +. e)
  in
  let dd_div (a, ae) (b, be) =
    let q = a /. b in
    let p, pe = dd_mul (q, 0.0) (b, be) in
    let r = a -. p +. (ae -. pe) in
    let q2 = r /. b in
    let s = q +. q2 in
    (s, q -. s +. q2)
  in
  let rec pow10 k =
    if k >= 0 then
      let rec go acc base n =
        if n = 0 then acc
        else
          let acc = if n land 1 = 1 then dd_mul acc base else acc in
          let base = if n > 1 then dd_mul base base else base in
          go acc base (n lsr 1)
      in
      go (1.0, 0.0) (10.0, 0.0) k
    else dd_div (1.0, 0.0) (pow10 (-k))
  in
  let lo = -303 and hi = 308 in
  let b = Buffer.create 32768 in
  Buffer.add_string b
    ("\n# ---- Float64 formatting tables ----\n\n"
   ^ "    .section .rodata\n    .align 3\nemo_pow10:\n");
  for k = lo to hi do
    let h, _ = pow10 k in
    Buffer.add_string b
      (Printf.sprintf "    .quad 0x%016Lx\n" (Int64.bits_of_float h))
  done;
  Buffer.add_string b "emo_pow10_lo:\n";
  for k = lo to hi do
    let _, l = pow10 k in
    Buffer.add_string b
      (Printf.sprintf "    .quad 0x%016Lx\n" (Int64.bits_of_float l))
  done;
  Buffer.add_string b "emo_pow5:\n";
  let p5 = ref 1L in
  for _ = 1 to 16 do
    p5 := Int64.mul !p5 5L;
    Buffer.add_string b (Printf.sprintf "    .dword %Ld\n" !p5)
  done;
  List.iter
    (fun (label, v) ->
      Buffer.add_string b
        (Printf.sprintf "%s:\n    .quad 0x%016Lx\n" label
           (Int64.bits_of_float v)))
    [
      ("emo_f64_1e16", 1e16);
      ("emo_f64_1e300", 1e300);
      ("emo_f64_1e_300", 1e-300);
      ("emo_f64_half", 0.5);
      ("emo_f64_eps", 1e-6);
    ];
  Buffer.contents b

(* Walk every body, collecting the enum members the program names
   (Make_enum expressions and Enum_member patterns share one id space). *)
let rec walk_expr_enum env (e : Emo_ir.expr) : unit =
  match e.Emo_ir.desc with
  | Make_enum { enum_name; member } ->
      if not (List.mem_assoc (enum_name, member) env.enums) then begin
        let id = List.length env.enums in
        env.enums <- ((enum_name, member), id) :: env.enums
      end
  | Unary (_, x) -> walk_expr_enum env x
  | Binary (_, l, r) ->
      walk_expr_enum env l;
      walk_expr_enum env r
  | Cond { c; t; e } ->
      walk_expr_enum env c;
      walk_expr_enum env t;
      walk_expr_enum env e
  | Interpolate es -> List.iter (walk_expr_enum env) es
  | Tuple es | Array_lit es -> List.iter (walk_expr_enum env) es
  | Map_lit pairs -> List.iter (walk_expr_enum env) pairs
  | Index (b, i) ->
      walk_expr_enum env b;
      walk_expr_enum env i
  | Field_read { obj; _ } -> walk_expr_enum env obj
  | Call { args; _ } -> List.iter (walk_expr_enum env) args
  | Call_value { f; args } ->
      walk_expr_enum env f;
      List.iter (walk_expr_enum env) args
  | Method { self_; args; _ } ->
      walk_expr_enum env self_;
      List.iter (walk_expr_enum env) args
  | Builtin { args; _ } | Runtime_impl { args; _ } ->
      List.iter (walk_expr_enum env) args
  | Box_new x | Atomic_new x | Bytes_new x | List_new x -> walk_expr_enum env x
  | Builder_new -> ()
  | Make_exception { message; data } ->
      walk_expr_enum env message;
      Option.iter (walk_expr_enum env) data
  | Do_spawn { args; _ } -> List.iter (walk_expr_enum env) args
  | Spawn_value { f; args } ->
      walk_expr_enum env f;
      List.iter (walk_expr_enum env) args
  | Closure { cbody; _ } -> walk_stmts_enum env cbody
  | Var _ | Const _ | Type_ref _ | Global _ | Global_var _ -> ()

and walk_stmt_enum env (s : Emo_ir.stmt) : unit =
  match s with
  | Effect e -> walk_expr_enum env e
  | Let { init; _ } -> walk_expr_enum env init
  | Assign_var { value; _ } -> walk_expr_enum env value
  | Set_global_var { value; _ } -> walk_expr_enum env value
  | Set_field { self_; value; _ } ->
      walk_expr_enum env self_;
      walk_expr_enum env value
  | If { cond; then_; else_ } ->
      walk_expr_enum env cond;
      walk_stmts_enum env then_;
      walk_stmts_enum env else_
  | Return_stmt e -> walk_expr_enum env e
  | Case { scrutinee; branches } ->
      walk_expr_enum env scrutinee;
      List.iter
        (fun (b : Emo_ir.branch) ->
          (match b.Emo_ir.guard with
          | Some g -> walk_expr_enum env g
          | None -> ());
          walk_pattern_enum env b.Emo_ir.pattern;
          walk_stmts_enum env b.Emo_ir.body)
        branches
  | Receive { branches } ->
      List.iter
        (fun (b : Emo_ir.branch) ->
          (match b.Emo_ir.guard with
          | Some g -> walk_expr_enum env g
          | None -> ());
          walk_pattern_enum env b.Emo_ir.pattern;
          walk_stmts_enum env b.Emo_ir.body)
        branches
  | Send { target; message } ->
      walk_expr_enum env target;
      walk_expr_enum env message
  | Raise e -> walk_expr_enum env e
  | While { cond; body; _ } ->
      walk_expr_enum env cond;
      walk_stmts_enum env body
  | For { init; cond; post; body; _ } ->
      walk_stmt_enum env init;
      walk_expr_enum env cond;
      walk_stmt_enum env post;
      walk_stmts_enum env body
  | Break | Continue -> ()

and walk_stmts_enum env (stmts : Emo_ir.stmt list) : unit =
  List.iter (walk_stmt_enum env) stmts

and walk_branches_enum env (branches : Emo_ir.branch list) : unit =
  match branches with
  | [] -> ()
  | b :: rest ->
      walk_stmts_enum env b.Emo_ir.body;
      walk_branches_enum env rest

and walk_pattern_enum env (p : Emo_ast.pattern) : unit =
  match p.Emo_ast.pattern_desc with
  | Emo_ast.Enum_member (t, m) ->
      if not (List.mem_assoc (t, m) env.enums) then begin
        let id = List.length env.enums in
        env.enums <- ((t, m), id) :: env.enums
      end
  | Emo_ast.Tuple_pattern ps -> List.iter (walk_pattern_enum env) ps
  | _ -> ()

(* [boot_stub] is the compiler's own entry discipline (the default). A
   package-provided `runtime.S` (EmoOS T3.1) replaces it: the image's
   entry is the package's, the runtime body and the program are the
   compiler's. [profile] is the image shape (EmoOS T4.1): "kernel", the
   boot-profile-A image OpenSBI enters in S-mode, or "user", the U-mode
   ELF the kernel loads — its own stub, its own sizing, its own load
   address. A package's stub and linker script ride in above either. *)
let emit ?(boot_stub : bool = true) ~(profile : string)
    (program : Emo_ir.program) : string =
  let profile_stub =
    match profile with
    | "kernel" -> boot_stub_asm
    | "user" -> user_boot_stub_asm
    | other -> invalid_arg ("riscv: unknown image profile `" ^ other ^ "`")
  in
  if program.pglobals <> [] then refuse "module-level `var`";
  const_thunks := program.Emo_ir.pconsts;
  (* Class metadata: ids, fields (init-assignment order), methods. *)
  let classes =
    List.mapi
      (fun i (c : Emo_ir.class_) ->
        let fields =
          match c.Emo_ir.cinit with
          | None -> []
          | Some init ->
              List.filter_map
                (fun (st : Emo_ir.stmt) ->
                  match st with
                  | Emo_ir.Set_field { name; _ } -> Some name
                  | _ -> None)
                init.Emo_ir.fbody
        in
        let methods =
          List.map
            (fun (m : Emo_ir.func) ->
              let n = String.length c.Emo_ir.cname + 2 in
              let display =
                if
                  String.starts_with ~prefix:(c.Emo_ir.cname ^ "__")
                    m.Emo_ir.fname
                then
                  String.sub m.Emo_ir.fname n (String.length m.Emo_ir.fname - n)
                else m.Emo_ir.fname
              in
              (display, m.Emo_ir.fname))
            c.Emo_ir.cmethods
        in
        ( c.Emo_ir.cdisplay,
          {
            cls_display = c.Emo_ir.cdisplay;
            cls_id = i;
            cls_fields = fields;
            cls_methods = methods;
          } ))
      program.pclasses
  in
  let env =
    {
      buf = Buffer.create 32768;
      fresh = 0;
      strs = [];
      cells = [];
      labels = 0;
      cur = None;
      fclass = None;
      deferred = [];
      classes;
      ifaces = program.pinterfaces;
      enums = [];
      loops = [];
      fforeigns =
        List.filter_map
          (fun (f : Emo_ir.func) ->
            if f.fforeign <> None then Some f.fname else None)
          program.pfuncs;
      fsigs =
        List.filter_map
          (fun (f : Emo_ir.func) ->
            match conv_of f with
            | Some conv -> Some (f.Emo_ir.fname, conv)
            | None -> None)
          program.pfuncs;
      native = false;
      spawns = [];
    }
  in
  (* Enum member ids over the whole program, first-seen order. *)
  List.iter
    (fun (f : Emo_ir.func) -> walk_stmts_enum env f.fbody)
    program.pfuncs;
  List.iter
    (fun (c : Emo_ir.class_) ->
      Option.iter (fun i -> walk_stmts_enum env i.Emo_ir.fbody) c.Emo_ir.cinit;
      List.iter (fun m -> walk_stmts_enum env m.Emo_ir.fbody) c.Emo_ir.cmethods)
    program.pclasses;
  walk_stmts_enum env program.pinit;
  gput env "%s" arch_directive;
  if boot_stub then gput env "%s\n" profile_stub;
  gput env "%s\n" runtime_asm;
  gput env "%s\n" float_tables_asm;
  (* The runtime's message block ends in .rodata; the program's code is
     text. *)
  gput env "\n    .section .text\n";
  List.iter
    (fun (f : Emo_ir.func) ->
      if f.fforeign = None then
        begin if f.fparams = [] && List.mem f.fname !const_thunks then
          emit_const_function env f
        else
          let native = match conv_of f with Some _ -> true | None -> false in
          (* Top-level defs are global: a package's boot stub reaches
             one by name (the console hook of T3.5, the trap entry of
             T3.6) — the module-prefixed labels collide with nothing. *)
          gput env "    .globl %s\n" (func_label f.Emo_ir.fname);
          emit_function env
            ~label:(func_label f.Emo_ir.fname)
            ~params:f.fparams ~captures:[]
            ~conv:
              (match conv_of f with
              | Some conv -> conv
              | None -> dynamic_conv (List.length f.fparams))
            ~native ~body:f.fbody
        end)
    program.pfuncs;
  (* Constructors and methods, per class. *)
  List.iter
    (fun (c : Emo_ir.class_) ->
      let info = class_of env c.Emo_ir.cdisplay in
      emit_ctor env c info;
      List.iter
        (fun (m : Emo_ir.func) ->
          env.fclass <- Some c.Emo_ir.cdisplay;
          emit_function env
            ~label:(func_label m.Emo_ir.fname)
            ~params:m.Emo_ir.fparams ~captures:[]
            ~conv:(dynamic_conv (List.length m.Emo_ir.fparams))
            ~native:false ~body:m.Emo_ir.fbody;
          env.fclass <- None)
        c.Emo_ir.cmethods)
    program.pclasses;
  (* The entry the boot stub calls — the compiler's or a package's
     (EmoOS T3.1) — global so a stub in its own object reaches it. *)
  gput env "\n    .section .text\n    .globl emo_program\n";
  emit_function env ~label:"emo_program"
    ~params:([] : (string * Emo_check.t) list)
    ~captures:[] ~conv:(dynamic_conv 0) ~native:false ~body:program.pinit;
  (* Closure bodies queued during emission may queue more. *)
  let rec drain () =
    match env.deferred with
    | [] -> ()
    | (label, cparams, caps, cbody) :: rest ->
        env.deferred <- rest;
        emit_function env ~label ~params:cparams ~captures:caps
          ~conv:(dynamic_conv (List.length cparams))
          ~native:false ~body:cbody;
        drain ()
  in
  drain ();
  (* The spawn entry thunks (T3.3): the child's first schedule returns
     into one; it hands the tagged words from the child's stack to the
     callee — the psABI registers for a typed def, the dynamic words
     with the closure record in t0 for a first-class block — and sets
     ra so a returning body ends the process. *)
  let emit_spawn_thunk (label, callee) =
    gput env "%s:\n" label;
    match callee with
    | Spawn_def (fname, conv) ->
        List.iteri
          (fun i (k, reg) ->
            let off = 8 * i in
            match k with
            | P_int64 ->
                gput env "    ld a%d, %d(sp)\n" reg off;
                gput env "    andi a%d, a%d, -32\n" reg reg;
                gput env "    ld a%d, 8(a%d)\n" reg reg
            | P_float64 ->
                gput env "    ld t0, %d(sp)\n" off;
                gput env "    andi t0, t0, -32\n";
                gput env "    fld fa%d, 8(t0)\n" reg
            | P_word -> gput env "    ld a%d, %d(sp)\n" reg off)
          (bank_assign conv.cparams);
        gput env "    la ra, emo_process_done\n";
        gput env "    j %s\n" (func_label fname)
    | Spawn_closure argc ->
        gput env "    ld t0, 0(sp)\n";
        gput env "    andi t0, t0, -32\n";
        let rec go i =
          if i <= argc then begin
            gput env "    ld a%d, %d(sp)\n" (i - 1) (8 * i);
            go (i + 1)
          end
        in
        go 1;
        gput env "    ld t2, 8(t0)\n";
        gput env "    la ra, emo_process_done\n";
        gput env "    jalr t2\n"
  in
  List.iter emit_spawn_thunk (List.rev env.spawns);
  (* Dispatch tables in .data: per-interface vtables (one slot per
     class), per-class field-name and method-name tables for the
     dynamic paths, and the per-class pointer tables the runtime
     indexes by class id. *)
  if program.pinterfaces <> [] then begin
    gput env
      "\n\
       # ---- Interface dispatch tables ----\n\n\
      \    .section .data\n\
      \    .align 3\n";
    List.iter
      (fun (name, sigs) ->
        gput env "    .globl emo_iface_%s\n" (Emo_ir.sanitize_ident name);
        gput env "emo_iface_%s:\n" (Emo_ir.sanitize_ident name);
        (* one row per class, one slot per interface method in the
           interface's own order — the dispatch multiplies the class id
           by the row's width and reads the method's slot *)
        List.iter
          (fun (c : Emo_ir.class_) ->
            let info = class_of env c.Emo_ir.cdisplay in
            List.iter
              (fun (m, _) ->
                match
                  List.find_opt
                    (fun (d, _) -> String.equal d m)
                    info.cls_methods
                with
                | Some (_, mangled) ->
                    gput env "    .dword %s\n" (func_label mangled)
                | None -> gput env "    .dword 0\n")
              sigs)
          program.pclasses)
      program.pinterfaces
  end;
  (* The const thunks' memo slots: one flag/value word pair each, in
     .data, read by [emit_const_function]. *)
  if !const_thunks <> [] then begin
    gput env "\n# ---- Const memo slots ----\n\n";
    gput env "    .section .data\n    .align 3\n";
    List.iter
      (fun name ->
        let n = Emo_ir.sanitize_ident name in
        gput env "emo_const_done_%s:\n" n;
        gput env "    .dword 0\n";
        gput env "emo_const_val_%s:\n" n;
        gput env "    .dword 0\n")
      !const_thunks
  end;
  (* The per-class tables and the two id-indexed pointer tables. The
     pointer tables always exist: the runtime's dynamic helpers
     reference them, and a program without classes just leaves them
     empty. *)
  gput env "\n# ---- Dynamic field and method tables ----\n\n";
  gput env "    .section .data\n    .align 3\n";
  if program.pclasses = [] then
    gput env
      "    .globl emo_field_tables\n\
       emo_field_tables:\n\
      \    .globl emo_mtbls\n\
       emo_mtbls:\n"
  else begin
    (* the name bytes, then each class's tables, then the id-indexed
       pointer tables *)
    let field_rows =
      List.map
        (fun (c : Emo_ir.class_) ->
          let info = class_of env c.Emo_ir.cdisplay in
          let names =
            List.map
              (fun f -> (string_label env f, String.length f))
              info.cls_fields
          in
          (info, names))
        program.pclasses
    in
    let method_rows =
      List.map
        (fun (c : Emo_ir.class_) ->
          let info = class_of env c.Emo_ir.cdisplay in
          let rows =
            List.map
              (fun (m, mangled) ->
                (string_label env m, String.length m, func_label mangled))
              info.cls_methods
          in
          (info, rows))
        program.pclasses
    in
    List.iteri
      (fun i (info, names) ->
        let tbl = Printf.sprintf "emo_flds_%d" i in
        gput env "    .globl %s\n%s:\n" tbl tbl;
        gput env "    .dword %d\n    .dword 0\n" (List.length names);
        List.iter
          (fun (label, len) ->
            gput env "    .dword %s\n    .dword %d\n" label len)
          names)
      field_rows;
    gput env "    .globl emo_field_tables\nemo_field_tables:\n";
    List.iteri
      (fun i (info, _) ->
        if info.cls_fields = [] then gput env "    .dword 0\n"
        else gput env "    .dword emo_flds_%d\n" i)
      field_rows;
    List.iteri
      (fun i (info, rows) ->
        let tbl = Printf.sprintf "emo_mts_%d" i in
        gput env "    .globl %s\n%s:\n" tbl tbl;
        gput env "    .dword %d\n    .dword 0\n" (List.length rows);
        List.iter
          (fun (label, len, addr) ->
            gput env "    .dword %s\n    .dword %d\n    .dword %s\n" label len
              addr)
          rows)
      method_rows;
    gput env "    .globl emo_mtbls\nemo_mtbls:\n";
    List.iteri
      (fun i (info, _) ->
        if info.cls_methods = [] then gput env "    .dword 0\n"
        else gput env "    .dword emo_mts_%d\n" i)
      method_rows
  end;
  if env.fresh > 0 then begin
    gput env "\n# ---- String literals ----\n\n    .section .rodata\n";
    List.iter
      (fun (label, s) ->
        gput env "%s:\n" label;
        let n = String.length s in
        let rec chunk i =
          if i < n then begin
            let stop = min (i + 16) n in
            let bytes =
              List.init (stop - i) (fun k ->
                  string_of_int (Char.code s.[i + k]))
            in
            gput env "    .byte %s\n" (String.concat ", " bytes);
            chunk stop
          end
        in
        chunk 0;
        gput env "%s_end:\n" label;
        gput env "    .size %s, . - %s\n" label label)
      (List.rev env.strs)
  end;
  if env.cells <> [] then begin
    gput env "\n# ---- Numeric literal cells ----\n\n    .section .rodata\n";
    List.iter
      (fun (bits, _, label) ->
        gput env "    .balign 32\n%s:\n    .quad 1\n    .quad %Ld\n" label bits)
      (List.rev env.cells)
  end;
  gput env "%s" (stack_asm ~profile);
  Buffer.contents env.buf
