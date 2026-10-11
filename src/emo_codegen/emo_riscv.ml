(* The riscv64 target: emit RV64 assembly text for the GNU cross
   binutils to assemble and link into one freestanding ELF
   (plan/step-22-riscv64.md). Boot profile A: under
   `qemu-system-riscv64 -machine virt`, OpenSBI enters the payload at
   0x80200000 in S-mode with a0 = hart id and a1 = the DTB pointer, and
   the legacy ecalls (a7 = 1 console putchar, a7 = 8 shutdown) are the
   runtime's whole IO.

   The value model (T22.2/T22.3): a dynamic value is one tagged machine
   word. Heap pointers carry their kind in the low three bits — 0
   Int64 cell, 1 Float64 cell, 2 String, 3 Tuple, 4 Array, 5 Box,
   6 Closure, 7 Instance — and every block is [header word][payload],
   the header naming the payload size for a future precise GC:

     Int64/Float64  [header][bits]
     String         [header][length][bytes padded to 8]
     Tuple/Array    [header][length][elements...]
     Box            [header][value]
     Closure        [header][code][captures...]
     Instance       [header][class id][fields...]

   Bool, Char, and enum members are immediates (bit 0 set; kind in
   bits 3:1: 0 Bool, 1 Char, 2 Enum — enum members carry a program-wide
   member id above bit 3), so an immediate is never a valid pointer.
   Int64/Float64 are boxed: the decided wrap-around semantics need all
   2⁶⁴ bit patterns. Equality is content equality (emo_eq_deep).
   Method dispatch: a class-typed receiver calls its mangled method
   directly; an interface-typed receiver goes through a static
   per-interface table indexed by class id; `is` compares class ids or
   probes the table. The heap is a bump allocator over a fixed .bss
   region; exhaustion is a loud runtime failure.

   Correctness first: every local lives in a stack slot (the wasm
   target's implicit stack machine), the psABI is the internal calling
   convention (params a0–a7, result a0; a closure's record rides in
   t0), and a call in return position lowers to `tail`/`jalr x0` after
   restoring sp — the guaranteed tail call. Expression temporaries are
   depth-indexed slots; field access always untags first (andi -8).
   Stage B specialization (raw Int64/Float64 registers) is a later
   task; every body emits dynamic for now. *)

type frame = {
  fbuf : Buffer.t;
  mutable slots : (string * int) list; (* name -> slot index *)
  mutable named : int; (* the named slot count, fixed by the pre-pass *)
  mutable temps : int; (* the temp slot count (the expression-depth bound) *)
  ret : string; (* the epilogue label *)
  mutable size : int; (* the frame size in bytes *)
}

type class_info = {
  cls_display : string;
  cls_id : int;
  cls_fields : string list; (* in init-assignment order *)
  cls_methods : (string * string) list; (* display name -> mangled fname *)
}

type env = {
  buf : Buffer.t;
  mutable fresh : int; (* the string-literal counter *)
  mutable strs : (string * string) list; (* label, bytes — newest first *)
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
let bool_false = 1 (* immediate: kind 0 in bits 3:1, payload bit 4 = 0 *)
let bool_true = 17 (* kind 0 in bits 3:1, payload bit 4 *)
let char_imm (c : char) : int = (Char.code c lsl 4) lor 0b0011

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

let fresh_label env base =
  env.labels <- env.labels + 1;
  Printf.sprintf ".L%s_%d" base env.labels

let func_label (fname : string) : string = "emo_" ^ fname

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
    | Builtin { args; _ } -> List.iter ex args
    | Box_new x | Bytes_new x | List_new x -> ex x
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
    | Receive _ | Send _ | Raise _ -> ()
    | Return_stmt e -> ex e
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
  | Builtin { args; _ } ->
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
  | Box_new x -> 1 + expr_depth x
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

let rec emit_expr env d (e : Emo_ir.expr) : unit =
  match e.Emo_ir.desc with
  | Const (Emo_ast.L_int i) ->
      put env "    li a0, %Ld\n" i;
      put env "    call emo_box_i64\n"
  | Const (Emo_ast.L_bool b) ->
      put env "    li a0, %d\n" (if b then bool_true else bool_false)
  | Const (Emo_ast.L_char c) -> put env "    li a0, %d\n" (char_imm c)
  | Const (Emo_ast.L_float f) ->
      put env "    li t0, %Ld\n" (Int64.bits_of_float f);
      put env "    fmv.d.x fa0, t0\n";
      put env "    call emo_box_f64\n"
  | Const (Emo_ast.L_string s) ->
      let label = string_label env s in
      put env "    la a0, %s\n" label;
      put env "    li a1, %d\n" (String.length s);
      call_runtime env "emo_string_lit"
  | Const _ -> refuse "this literal kind"
  | Var name -> put env "    ld a0, %d(sp)\n" (slot_offset env name)
  | Binary (op, l, r) -> emit_binary env d e.Emo_ir.ety op l r
  | Unary (op, x) -> emit_unary env d e.Emo_ir.ety op x
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
  | Call { func; args } ->
      emit_args env d args;
      put env "    call %s\n" (func_label func)
  | Call_value { f; args } ->
      let fslot = temp_offset env d in
      emit_expr env (d + 1) f;
      put env "    sd a0, %d(sp)\n" fslot;
      emit_args_from env (d + 1) ~from:0 args;
      put env "    ld t0, %d(sp)\n" fslot;
      put env "    andi t0, t0, -16\n";
      put env "    ld t2, 8(t0)\n";
      put env "    jalr t2\n"
  | Closure { cparams; cbody } -> emit_closure_creation env d cparams cbody
  | Interpolate parts -> emit_interpolate env d parts
  | Tuple es -> emit_seq env d es tag_tuple
  | Array_lit es -> emit_seq env d es tag_array
  | Index (b, i) -> emit_index env d b i
  | Field_read { obj; name } -> (
      match obj.Emo_ir.ety with
      | Emo_check.ClassType _ ->
          emit_expr env d obj;
          put env "    andi a0, a0, -16\n";
          let idx = field_index env obj.Emo_ir.ety name in
          put env "    ld a0, %d(a0)\n" (16 + (8 * idx))
      | _ ->
          (* a dynamic receiver: the field resolves by name through the
             class's field table (the c target's emo_field_by_name) *)
          let spill = temp_offset env d in
          emit_expr env (d + 1) obj;
          put env "    andi a0, a0, -16\n";
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
      emit_method env d e.Emo_ir.ety self_ name args
  | Make_enum { enum_name; member } ->
      put env "    li a0, %d\n" (enum_imm env enum_name member)
  | Box_new arg ->
      emit_expr env (d + 1) arg;
      call_runtime env "emo_box_new"
  | Builtin { name = "println"; args = [ arg ] } ->
      emit_expr env d arg;
      call_runtime env "emo_println"
  | Builtin { name = "halt"; args = [] } -> put env "    li a7, 8\n    ecall\n"
  | Builtin { name; _ } -> refuse (Printf.sprintf "the `%s` builtin" name)
  | _ -> refuse (describe_expr e)

(* Evaluate the args, each spilled to its own slot first — later args
   may call over earlier results — then load them into a[from].. *)
and emit_args_from env d ~(from : int) (args : Emo_ir.expr list) : unit =
  if from + List.length args > 8 then
    refuse "a call with more than eight arguments";
  List.iteri
    (fun i arg ->
      let spill = temp_offset env (d + i) in
      emit_expr env (d + List.length args) arg;
      put env "    sd a0, %d(sp)\n" spill)
    args;
  List.iteri
    (fun i _ ->
      put env "    ld a%d, %d(sp)\n" (from + i) (temp_offset env (d + i)))
    args

and emit_args env d (args : Emo_ir.expr list) : unit =
  emit_args_from env d ~from:0 args

(* A Tuple or Array literal: the elements evaluate first (each spilled),
   then one block is allocated and filled. *)
and emit_seq env d (es : Emo_ir.expr list) (tag : int) : unit =
  let n = List.length es in
  List.iteri
    (fun i el ->
      emit_expr env (d + n) el;
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
  put env "    andi a0, a0, -16\n";
  put env "    sd a0, %d(sp)\n" spill;
  emit_expr env (d + 1) i;
  put env "    andi a0, a0, -16\n";
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

and emit_binary env d (ty : Emo_check.t) (op : Emo_ast.binop) (l : Emo_ir.expr)
    (r : Emo_ir.expr) : unit =
  let bool_of_t0 () =
    put env "    slli t0, t0, 4\n    addi t0, t0, 1\n    mv a0, t0\n"
  in
  (* Comparisons key on the operand type (their own result is Bool). *)
  let ty = if ty = Emo_check.Bool then l.Emo_ir.ety else ty in
  (* A dynamic operand: the runtime dispatches on the values (the c
     target's emo_*_dyn family). *)
  if l.Emo_ir.ety = Emo_check.Unknown || r.Emo_ir.ety = Emo_check.Unknown then
    match op with
    | Emo_ast.Eq | Emo_ast.Ne ->
        emit_expr env (d + 1) l;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) r;
        put env "    ld a1, %d(sp)\n" spill;
        call_runtime env "emo_eq_deep";
        if op = Emo_ast.Ne then put env "    xori a0, a0, 16\n"
    | Emo_ast.Add | Emo_ast.Sub | Emo_ast.Mul ->
        emit_expr env (d + 1) l;
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) r;
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
        let spill = temp_offset env d in
        put env "    sd a0, %d(sp)\n" spill;
        emit_expr env (d + 1) b;
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
        put env "    call emo_box_i64\n"
    | (Emo_ast.Add | Emo_ast.Sub | Emo_ast.Mul), Emo_check.Float64 ->
        emit_float_pair env d l r;
        let mnemonic =
          match op with
          | Emo_ast.Add -> "fadd.d"
          | Emo_ast.Sub -> "fsub.d"
          | Emo_ast.Mul -> "fmul.d"
          | _ -> assert false
        in
        put env "    %s fa0, fa0, fa1\n" mnemonic;
        put env "    call emo_box_f64\n"
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
        (Emo_check.Bool | Emo_check.Char | Emo_check.EnumType _) ) ->
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
   payloads in t0 (left) and t1 (right). *)
and emit_int_pair env d (l : Emo_ir.expr) (r : Emo_ir.expr) : unit =
  let spill = temp_offset env d in
  emit_expr env (d + 1) l;
  put env "    andi a0, a0, -16\n";
  put env "    ld t0, 8(a0)\n";
  put env "    sd t0, %d(sp)\n" spill;
  emit_expr env (d + 1) r;
  put env "    andi a0, a0, -16\n";
  put env "    ld t1, 8(a0)\n";
  put env "    ld t0, %d(sp)\n" spill

(* The Float64 twin: payloads ride fa0/fa1. Field reads untag first —
   every heap access runs on the untagged pointer (Int64's tag is 0 and
   hides any slip, so the discipline is checked on the float paths). *)
and emit_float_pair env d (l : Emo_ir.expr) (r : Emo_ir.expr) : unit =
  let spill = temp_offset env d in
  emit_expr env (d + 1) l;
  put env "    andi a0, a0, -16\n";
  put env "    fld fa0, 8(a0)\n";
  put env "    fsd fa0, %d(sp)\n" spill;
  emit_expr env (d + 1) r;
  put env "    andi a0, a0, -16\n";
  put env "    fld fa1, 8(a0)\n";
  put env "    fld fa0, %d(sp)\n" spill

and emit_unary env d (ty : Emo_check.t) (op : Emo_ast.unop) (x : Emo_ir.expr) :
    unit =
  match (op, ty) with
  | Emo_ast.Neg, Emo_check.Int64 ->
      emit_expr env d x;
      put env "    andi a0, a0, -16\n";
      put env "    ld t0, 8(a0)\n";
      put env "    sub t0, x0, t0\n";
      put env "    mv a0, t0\n";
      put env "    call emo_box_i64\n"
  | Emo_ast.Neg, Emo_check.Float64 ->
      emit_expr env d x;
      put env "    andi a0, a0, -16\n";
      put env "    fld fa0, 8(a0)\n";
      put env "    fneg.d fa0, fa0\n";
      put env "    call emo_box_f64\n"
  | Emo_ast.Bit_not, Emo_check.Int64 ->
      emit_expr env d x;
      put env "    andi a0, a0, -16\n";
      put env "    ld t0, 8(a0)\n";
      put env "    not t0, t0\n";
      put env "    mv a0, t0\n";
      put env "    call emo_box_i64\n"
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
      call_runtime env "emo_to_string";
      put env "    sd a0, %d(sp)\n" (temp_offset env (d + i)))
    parts;
  put env "    li t2, 0\n";
  List.iteri
    (fun i _ ->
      put env "    ld t0, %d(sp)\n" (temp_offset env (d + i));
      put env "    andi t0, t0, -16\n";
      put env "    ld t1, 8(t0)\n";
      put env "    add t2, t2, t1\n")
    parts;
  put env "    mv a0, t2\n";
  call_runtime env "emo_alloc_string";
  let block_slot = temp_offset env (d + k) in
  let cursor_slot = temp_offset env (d + k + 1) in
  put env "    sd a0, %d(sp)\n" block_slot;
  put env "    andi a0, a0, -16\n";
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

and emit_method env d (ty : Emo_check.t) (self_ : Emo_ir.expr) (name : string)
    (args : Emo_ir.expr list) : unit =
  (* `is` takes a type reference, not a value. *)
  match (name, args) with
  | "is", [ { Emo_ir.desc = Type_ref target; _ } ] -> (
      emit_expr env d self_;
      put env "    andi a0, a0, -16\n";
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
  | _ -> (
      match self_.Emo_ir.ety with
      | Emo_check.Int64 when name = "to_string" && args = [] ->
          emit_expr env d self_;
          put env "    andi a0, a0, -16\n";
          put env "    ld a0, 8(a0)\n";
          call_runtime env "emo_i64_to_string"
      | Emo_check.BoxType _ -> (
          match (name, args) with
          | "read", [] ->
              emit_expr env d self_;
              put env "    andi a0, a0, -16\n";
              put env "    ld a0, 8(a0)\n"
          | "replace", [ v ] ->
              let self_slot = temp_offset env d in
              emit_expr env (d + 1) self_;
              put env "    sd a0, %d(sp)\n" self_slot;
              emit_expr env (d + 1) v;
              put env "    ld t0, %d(sp)\n" self_slot;
              put env "    andi t0, t0, -16\n";
              put env "    sd a0, 8(t0)\n";
              put env "    ld a0, %d(sp)\n" self_slot
          | _ -> refuse (Printf.sprintf "the Box method `%s`" name))
      | Emo_check.ArrayType _ -> (
          match (name, args) with
          | "length", [] ->
              emit_expr env d self_;
              put env "    andi a0, a0, -16\n";
              put env "    ld a0, 8(a0)\n";
              put env "    call emo_box_i64\n"
          | "append", [ x ] ->
              let self_slot = temp_offset env d in
              emit_expr env (d + 1) self_;
              put env "    sd a0, %d(sp)\n" self_slot;
              emit_expr env (d + 1) x;
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
              put env "    call %s\n" (func_label mangled)
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
              put env "    andi t0, t0, -16\n";
              put env "    ld t1, 8(t0)\n";
              put env "    la t2, emo_iface_%s\n"
                (Emo_ir.sanitize_ident display);
              put env "    slli t1, t1, 3\n";
              put env "    add t2, t2, t1\n";
              put env "    ld t2, 0(t2)\n";
              put env "    jalr t2\n"
          | Some _ ->
              refuse (Printf.sprintf "the method `%s` of `%s`" name display)
          | None -> refuse (Printf.sprintf "the interface `%s`" display))
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
   first — it rides through the whole tail chain. *)
and emit_tail env (e : Emo_ir.expr) : bool =
  match e.Emo_ir.desc with
  | Call { func; args } ->
      emit_args env 0 args;
      let f =
        match env.cur with Some f -> f | None -> invalid_arg "riscv: no frame"
      in
      put env "    ld ra, 0(sp)\n";
      put env "    addi sp, sp, %d\n" f.size;
      put env "    tail %s\n" (func_label func);
      true
  | Call_value { f; args } ->
      let ff =
        match env.cur with Some f -> f | None -> invalid_arg "riscv: no frame"
      in
      let fslot = temp_offset env 0 in
      emit_expr env 1 f;
      put env "    sd a0, %d(sp)\n" fslot;
      emit_args_from env 1 ~from:0 args;
      put env "    ld t0, %d(sp)\n" fslot;
      put env "    andi t0, t0, -16\n";
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
      put env "    andi t1, t0, 15\n";
      put env "    bnez t1, %s\n" l_next;
      put env "    andi t0, t0, -16\n";
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
      put env "    andi t1, t0, 15\n";
      put env "    li t2, %d\n" tag_tuple;
      put env "    bne t1, t2, %s\n" l_next;
      put env "    andi t0, t0, -16\n";
      put env "    ld t1, 8(t0)\n";
      put env "    li t2, %d\n" (List.length ps);
      put env "    bne t1, t2, %s\n" l_next;
      List.iteri
        (fun i sub ->
          let elem_slot = temp_offset env 1 in
          put env "    ld t0, %d(sp)\n" slot_off;
          put env "    andi t0, t0, -16\n";
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
      put env "    ld t0, %d(sp)\n" src_off;
      put env "    sd t0, %d(sp)\n" (slot_offset env n)
  | Emo_ast.Tuple_pattern ps ->
      List.iteri
        (fun i sub ->
          put env "    ld t0, %d(sp)\n" src_off;
          put env "    andi t0, t0, -16\n";
          put env "    ld t0, %d(t0)\n" (16 + (8 * i));
          put env "    sd t0, %d(sp)\n" (temp_offset env 1);
          rec_pattern_bind env (temp_offset env 1) sub)
        ps

and emit_stmt env (st : Emo_ir.stmt) : unit =
  match st with
  | Effect e -> emit_expr env 0 e
  | Let { name; init; _ } ->
      emit_expr env 0 init;
      put env "    sd a0, %d(sp)\n" (slot_offset env name)
  | Assign_var { name; value } ->
      emit_expr env 0 value;
      put env "    sd a0, %d(sp)\n" (slot_offset env name)
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
      put env "    sd a0, %d(sp)\n" (temp_offset env 1);
      put env "    ld t0, %d(sp)\n" self_slot;
      match self_.Emo_ir.ety with
      | Emo_check.ClassType _ ->
          let idx = field_index env self_.Emo_ir.ety name in
          put env "    ld a0, %d(sp)\n" (temp_offset env 1);
          put env "    sd a0, %d(t0)\n" (16 + (8 * idx))
      | _ ->
          put env "    andi a0, t0, -16\n";
          put env "    ld t1, 8(a0)\n";
          let nlabel = string_label env name in
          put env "    la a1, %s\n" nlabel;
          put env "    li a2, %d\n" (String.length name);
          call_runtime env "emo_field_index";
          put env "    ld t0, %d(sp)\n" self_slot;
          put env "    andi t0, t0, -16\n";
          put env "    slli t1, a0, 3\n";
          put env "    add t0, t0, t1\n";
          put env "    ld a0, %d(sp)\n" (temp_offset env 1);
          put env "    sd a0, 16(t0)\n")
  | Set_global_var _ -> refuse "module-level `var` assignment"
  | Send _ -> refuse "send"
  | Receive _ -> refuse "receive"
  | Raise _ -> refuse "raise"

and describe_expr (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Type_ref _ -> "type references in value position"
  | Global _ -> "program-wide def values"
  | Global_var _ -> "module-level `var`"
  | Map_lit _ -> "maps"
  | Bytes_new _ -> "Bytes"
  | List_new _ -> "List"
  | Make_exception _ -> "exceptions"
  | Do_spawn _ | Spawn_value _ -> "processes (`spawn`)"
  | _ -> "this expression"

(* ---- Function emission ---- *)

(* One function: label, prologue (ra + the param/capture spill), body,
   epilogue. A closure body takes its record in t0 and spills the
   captures into its own slots at entry. *)
let emit_function env ~(label : string) ~(params : (string * Emo_check.t) list)
    ~(captures : string list) ~(body : Emo_ir.stmt list) : unit =
  if List.length params > 8 then refuse "a def with more than eight parameters";
  let f =
    {
      fbuf = Buffer.create 512;
      slots = [];
      named = 0;
      temps = 0;
      ret = fresh_label env "ret";
      size = 0;
    }
  in
  let nparams = List.length params in
  f.slots <-
    List.mapi (fun i (n, _) -> (n, i)) params
    @ List.mapi (fun i n -> (n, nparams + i)) captures;
  f.named <- nparams + List.length captures;
  env.cur <- Some f;
  collect_stmts f body;
  f.temps <- stmts_depth body + 2;
  f.size <- (8 + (8 * (f.named + f.temps)) + 15) / 16 * 16;
  gput env "%s:\n" label;
  gput env "    addi sp, sp, -%d\n" f.size;
  gput env "    sd ra, 0(sp)\n";
  List.iteri (fun i _ -> gput env "    sd a%d, %d(sp)\n" i (8 + (8 * i))) params;
  List.iteri
    (fun i _ ->
      gput env "    ld t1, %d(t0)\n" (16 + (8 * i));
      gput env "    sd t1, %d(sp)\n" (8 + (8 * (nparams + i))))
    captures;
  List.iter (emit_stmt env) body;
  (* Fall-off: the statement walk already left a final expression
     statement's value in a0; a Void body just returns. *)
  put env "%s:\n" f.ret;
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
    }
  in
  let nparams = List.length real_params in
  f.slots <-
    List.mapi (fun i (n, _) -> (n, i)) real_params @ [ ("self", nparams) ];
  f.named <- nparams + 1;
  env.cur <- Some f;
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

let runtime_asm =
  {asm|    .attribute arch, "rv64gc"

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

# ---- The bump allocator ----
#
# emo_alloc: a0 = payload words, a0 = the block (raw pointer, header
# word first). Exhaustion is a loud failure; the tagged layout stays
# ready for a collector.

    .globl emo_runtime_init
emo_runtime_init:
    la t0, emo_heap_start
    la t1, emo_heap_cursor
    sd t0, 0(t1)
    ret

    .globl emo_alloc
emo_alloc:
    addi t0, a0, 1
    slli t0, t0, 3
    addi t0, t0, 15
    andi t0, t0, -16
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

# emo_print_bytes: a0 = start, a1 = end; every byte through the legacy
# console ecall (a7 = 1, which the ecall leaves alone).
    .globl emo_print_bytes
emo_print_bytes:
    mv t0, a0
    li a7, 1
.Lpb:
    bgeu t0, a1, .Lpb_done
    lbu a0, 0(t0)
    ecall
    addi t0, t0, 1
    j .Lpb
.Lpb_done:
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
    li a7, 1
    ecall
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
    andi a1, a1, -16
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
    andi s0, a0, -16
    andi s1, a1, -16
    ld t0, 8(s0)
    ld t1, 8(s1)
    add s2, t0, t1
    mv a0, s2
    call emo_alloc_string
    andi t0, a0, -16
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
    andi a0, a0, -16
    andi a1, a1, -16
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
    andi s0, a0, -16
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
    andi t2, a0, 15
    andi t3, a1, 15
    bne t2, t3, .Leq_no
    bnez t0, .Leq_no
    andi s0, a0, -16
    andi s1, a1, -16
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
    andi t2, a0, 15
    beqz t2, .Ldm_scalar
    li t3, 2
    beq t2, t3, .Ldm_scalar
    li t3, 4
    beq t2, t3, .Ldm_scalar
    li t3, 8
    beq t2, t3, .Ldm_scalar
    li t3, 10
    beq t2, t3, .Ldm_scalar
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
    andi a0, a0, -16
    ld a0, 8(a0)
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    ret
.Ldm_do_repl:
    andi t0, a0, -16
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
    andi a0, a0, -16
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
    andi s0, a0, -16
    andi s1, a1, -16
    andi t0, a0, 15
    andi t1, a1, 15
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
    andi s0, a0, -16
    andi s1, a1, -16
    andi t0, a0, 15
    andi t1, a1, 15
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
    andi s0, a0, -16
    andi s1, a1, -16
    andi t0, a0, 15
    andi t1, a1, 15
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
    andi s0, a0, -16
    andi s1, a1, -16
    andi t0, a0, 15
    andi t1, a1, 15
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
    andi s0, a0, -16
    andi s1, a1, -16
    andi t0, a0, 15
    andi t1, a1, 15
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
    andi t0, a0, -16
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
    andi t0, a0, 15
    beqz t0, .Lts_i64
    li t1, 4
    beq t0, t1, .Lts_done
    li t1, 2
    beq t0, t1, .Lts_f64
    la a0, msg_kind
    la a1, msg_kind_end
    call emo_fail
.Lts_i64:
    andi a0, a0, -16
    ld a0, 8(a0)
    call emo_i64_to_string
    j .Lts_done
.Lts_f64:
    la a0, msg_float
    la a1, msg_float_end
    call emo_fail
.Lts_imm:
    srli t1, a0, 1
    andi t1, t1, 7
    beqz t1, .Lts_bool
    li t2, 1
    beq t1, t2, .Lts_char
    la a0, msg_kind
    la a1, msg_kind_end
    call emo_fail
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
    andi t1, a0, -16
    sb t0, 16(t1)
    j .Lts_done
.Lts_done:
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_println: a0 = any dynamic value; the string form, a newline.
    .globl emo_println
emo_println:
    addi sp, sp, -16
    sd ra, 0(sp)
    call emo_to_string
    andi a0, a0, -16
    ld a1, 8(a0)
    addi a0, a0, 16
    add a1, a0, a1
    call emo_print_bytes
    li a0, 10
    li a7, 1
    ecall
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
msg_float:
    .ascii "cannot convert a Float64 to a string yet"
msg_float_end:
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
|asm}

(* One whole-program artifact at 0x80200000, the profile A entry
   address. Two read-only segments and one read-write, so the loader
   sees honest permissions; .bss is NOBITS — the entry stub clears it,
   which is also why the stack and the value heap live there (no image
   weight). *)
let linker_script =
  {ld|OUTPUT_ARCH(riscv)
ENTRY(emo_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = 0x80200000;

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
|ld}

(* The stack (1 MiB) and the value heap (64 MiB) live in .bss — NOBITS,
   so neither weighs on the image; the entry stub clears the region
   before first use, and the heap cursor sits past the heap's end. *)
let stack_asm =
  {asm|
# ---- The stack and the value heap: .bss, cleared by the entry stub ----

    .section .bss
    .align 16
    .globl emo_stack_top
emo_stack_bottom:
    .zero 1048576
emo_stack_top:
    .globl emo_heap_start
emo_heap_start:
    .zero 67108864
    .globl emo_heap_end
emo_heap_end:
    .globl emo_heap_cursor
emo_heap_cursor:
    .zero 8
|asm}

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
  | Builtin { args; _ } -> List.iter (walk_expr_enum env) args
  | Box_new x | Bytes_new x | List_new x -> walk_expr_enum env x
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
  (* Receive refuses at emission, so its branches never carry enum
     members the program needs; the walk skips them. *)
  | Receive _ -> ()
  | Send { target; message } ->
      walk_expr_enum env target;
      walk_expr_enum env message
  | Raise e -> walk_expr_enum env e

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

let emit (program : Emo_ir.program) : string =
  if program.pglobals <> [] then refuse "module-level `var`";
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
      labels = 0;
      cur = None;
      fclass = None;
      deferred = [];
      classes;
      ifaces = program.pinterfaces;
      enums = [];
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
  gput env "%s\n" runtime_asm;
  (* The runtime's message block ends in .rodata; the program's code is
     text. *)
  gput env "\n    .section .text\n";
  List.iter
    (fun (f : Emo_ir.func) ->
      if f.fforeign <> None then refuse "`foreign def`";
      emit_function env
        ~label:(func_label f.Emo_ir.fname)
        ~params:f.fparams ~captures:[] ~body:f.fbody)
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
            ~params:m.Emo_ir.fparams ~captures:[] ~body:m.Emo_ir.fbody;
          env.fclass <- None)
        c.Emo_ir.cmethods)
    program.pclasses;
  emit_function env ~label:"emo_program"
    ~params:([] : (string * Emo_check.t) list)
    ~captures:[] ~body:program.pinit;
  (* Closure bodies queued during emission may queue more. *)
  let rec drain () =
    match env.deferred with
    | [] -> ()
    | (label, cparams, caps, cbody) :: rest ->
        env.deferred <- rest;
        emit_function env ~label ~params:cparams ~captures:caps ~body:cbody;
        drain ()
  in
  drain ();
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
        ignore sigs;
        gput env "    .globl emo_iface_%s\n" (Emo_ir.sanitize_ident name);
        gput env "emo_iface_%s:\n" (Emo_ir.sanitize_ident name);
        List.iter
          (fun (c : Emo_ir.class_) ->
            let entry =
              List.find_map
                (fun (m, _) ->
                  let info = class_of env c.Emo_ir.cdisplay in
                  match
                    List.find_opt
                      (fun (d, _) -> String.equal d m)
                      info.cls_methods
                  with
                  | Some (_, mangled) -> Some (func_label mangled)
                  | None -> None)
                sigs
            in
            match entry with
            | Some label -> gput env "    .dword %s\n" label
            | None -> gput env "    .dword 0\n")
          program.pclasses)
      program.pinterfaces
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
  gput env "%s" stack_asm;
  Buffer.contents env.buf
