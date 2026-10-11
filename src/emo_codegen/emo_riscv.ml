(* The riscv64 target: emit RV64 assembly text for the GNU cross
   binutils to assemble and link into one freestanding ELF
   (plan/step-22-riscv64.md). Boot profile A: under
   `qemu-system-riscv64 -machine virt`, OpenSBI enters the payload at
   0x80200000 in S-mode with a0 = hart id and a1 = the DTB pointer, and
   the legacy ecalls (a7 = 1 console putchar, a7 = 8 shutdown) are the
   runtime's whole IO.

   The value model (T22.2): a dynamic value is one tagged machine word.
   Heap pointers carry their kind in the low three bits — 0 Int64 cell,
   1 Float64 cell, 2 String, 3 Tuple, 4 Array, 5 Box, 6 Closure,
   7 Instance — and every block is [header word][payload...], the
   header naming the payload size for a future precise GC. Bool and
   Char are immediates (bit 0 set; bits 3:1 name the kind: 0 Bool,
   1 Char, 2 Enum), so an immediate is never a valid pointer.
   Int64/Float64 are boxed two-word cells: the decided wrap-around
   semantics need all 2⁶⁴ bit patterns, so the OCaml 63-bit shortcut
   is unavailable here. The heap is a bump allocator over a fixed .bss
   region; exhaustion is a loud runtime failure, and the tagged layout
   stays GC-ready.

   Correctness first: every local lives in a stack slot (the wasm
   target's implicit stack machine), the psABI is the internal calling
   convention (params a0–a7, result a0; a closure's record rides in
   t0), and a call in return position lowers to `tail`/`jalr x0` after
   restoring sp — the guaranteed tail call. Expression temporaries are
   depth-indexed slots: a node spills into its own region and evaluates
   its children one region deeper, so nested evaluation can never
   collide. Stage B specialization (raw Int64/Float64 registers) is a
   later task; every body emits dynamic for now. *)

type frame = {
  fbuf : Buffer.t;
  mutable slots : (string * int) list; (* name -> slot index *)
  mutable named : int; (* the named slot count, fixed by the pre-pass *)
  mutable temps : int; (* the temp slot count (the expression-depth bound) *)
  ret : string; (* the epilogue label *)
  mutable size : int; (* the frame size in bytes *)
}

type env = {
  buf : Buffer.t;
  mutable fresh : int; (* the string-literal counter *)
  mutable strs : (string * string) list; (* label, bytes — newest first *)
  mutable labels : int; (* the fresh-label counter *)
  mutable cur : frame option;
  mutable deferred :
    (string * (string * Emo_check.t) list * string list * Emo_ir.stmt list) list;
      (* closure bodies queued for emission: label, params, capture names,
     body *)
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

let tag_closure = 6
let bool_false = 1 (* immediate: kind 0 in bits 3:1, payload bit 4 = 0 *)
let bool_true = 17 (* kind 0 in bits 3:1, payload bit 4 *)
let char_imm (c : char) : int = (Char.code c lsl 4) lor 0b0011

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
  | Box_new x -> 1 + expr_depth x
  | _ -> 0

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
            max (expr_depth scrutinee)
              (List.fold_left
                 (fun acc (b : Emo_ir.branch) ->
                   max acc (stmts_depth b.Emo_ir.body))
                 0 branches)
        | _ -> 0))
    0 stmts

(* Register every Let binding of the body, in bind order. Case and
   receive bodies are skipped: emission refuses at the construct before
   any slot inside them is read. *)
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
      emit_args_from env (d + 1) args;
      put env "    ld t0, %d(sp)\n" fslot;
      put env "    andi t0, t0, -8\n";
      put env "    ld t2, 8(t0)\n";
      put env "    jalr t2\n"
  | Closure { cparams; cbody } -> emit_closure_creation env d cparams cbody
  | Interpolate parts -> emit_interpolate env d parts
  | Builtin { name = "println"; args = [ arg ] } ->
      emit_expr env d arg;
      call_runtime env "emo_println"
  | Builtin { name = "halt"; args = [] } -> put env "    li a7, 8\n    ecall\n"
  | Builtin { name; _ } -> refuse (Printf.sprintf "the `%s` builtin" name)
  | _ -> refuse (describe_expr e)

(* Evaluate the args, each spilled to its own slot first — later args
   may call over earlier results — then load them into a0.. *)
and emit_args_from env d (args : Emo_ir.expr list) : unit =
  if List.length args > 8 then refuse "a call with more than eight arguments";
  List.iteri
    (fun i arg ->
      let spill = temp_offset env (d + i) in
      emit_expr env (d + List.length args) arg;
      put env "    sd a0, %d(sp)\n" spill)
    args;
  List.iteri
    (fun i _ -> put env "    ld a%d, %d(sp)\n" i (temp_offset env (d + i)))
    args

and emit_args env d (args : Emo_ir.expr list) : unit = emit_args_from env d args

and emit_binary env d (ty : Emo_check.t) (op : Emo_ast.binop) (l : Emo_ir.expr)
    (r : Emo_ir.expr) : unit =
  let bool_of_t0 () =
    put env "    slli t0, t0, 4\n    addi t0, t0, 1\n    mv a0, t0\n"
  in
  (* Comparisons key on the operand type (their own result is Bool). *)
  let ty = if ty = Emo_check.Bool then l.Emo_ir.ety else ty in
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
      put env "    ld a1, %d(sp)\n" spill;
      call_runtime env "emo_string_eq"
  | (Emo_ast.Eq | Emo_ast.Ne), (Emo_check.Bool | Emo_check.Char) ->
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
  put env "    ld t0, 8(a0)\n";
  put env "    sd t0, %d(sp)\n" spill;
  emit_expr env (d + 1) r;
  put env "    ld t1, 8(a0)\n";
  put env "    ld t0, %d(sp)\n" spill

(* The Float64 twin: payloads ride fa0/fa1. Field reads untag first —
   every heap access runs on the untagged pointer (Int64's tag is 0 and
   hides any slip, so the discipline is checked on the float paths). *)
and emit_float_pair env d (l : Emo_ir.expr) (r : Emo_ir.expr) : unit =
  let spill = temp_offset env d in
  emit_expr env (d + 1) l;
  put env "    andi a0, a0, -8\n";
  put env "    fld fa0, 8(a0)\n";
  put env "    fsd fa0, %d(sp)\n" spill;
  emit_expr env (d + 1) r;
  put env "    andi a0, a0, -8\n";
  put env "    fld fa1, 8(a0)\n";
  put env "    fld fa0, %d(sp)\n" spill

and emit_unary env d (ty : Emo_check.t) (op : Emo_ast.unop) (x : Emo_ir.expr) :
    unit =
  match (op, ty) with
  | Emo_ast.Neg, Emo_check.Int64 ->
      emit_expr env d x;
      put env "    ld t0, 8(a0)\n";
      put env "    sub t0, x0, t0\n";
      put env "    mv a0, t0\n";
      put env "    call emo_box_i64\n"
  | Emo_ast.Neg, Emo_check.Float64 ->
      emit_expr env d x;
      put env "    andi a0, a0, -8\n";
      put env "    fld fa0, 8(a0)\n";
      put env "    fneg.d fa0, fa0\n";
      put env "    call emo_box_f64\n"
  | Emo_ast.Bit_not, Emo_check.Int64 ->
      emit_expr env d x;
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
      put env "    andi t0, t0, -8\n";
      put env "    ld t1, 8(t0)\n";
      put env "    add t2, t2, t1\n")
    parts;
  put env "    mv a0, t2\n";
  call_runtime env "emo_alloc_string";
  let block_slot = temp_offset env (d + k) in
  let cursor_slot = temp_offset env (d + k + 1) in
  put env "    sd a0, %d(sp)\n" block_slot;
  put env "    andi a0, a0, -8\n";
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

(* ---- Statement emission ---- *)

(* A call in return position lowers to a guaranteed tail call: the
   frame is released first (nothing live rides in it — the args are
   already in registers), so the stack stays constant. `tail`/`jr`
   leave ra alone, so the original return address is loaded into ra
   first — it rides through the whole tail chain and the deepest
   frame's saved ra stays honest. *)
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
      emit_args_from env 1 args;
      put env "    ld t0, %d(sp)\n" fslot;
      put env "    andi t0, t0, -8\n";
      put env "    ld t2, 8(t0)\n";
      put env "    ld ra, 0(sp)\n";
      put env "    addi sp, sp, %d\n" ff.size;
      put env "    jr t2\n";
      true
  | _ -> false

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
  | Set_global_var _ -> refuse "module-level `var` assignment"
  | Set_field _ -> refuse "field assignment"
  | Case _ -> refuse "match"
  | Receive _ -> refuse "receive"
  | Send _ -> refuse "send"
  | Raise _ -> refuse "raise"

and describe_expr (e : Emo_ir.expr) : string =
  match e.Emo_ir.desc with
  | Type_ref _ -> "type references in value position"
  | Global _ -> "program-wide def values"
  | Global_var _ -> "module-level `var`"
  | Tuple _ -> "tuples"
  | Array_lit _ -> "arrays"
  | Map_lit _ -> "maps"
  | Make_enum _ -> "enums"
  | Index _ -> "indexing"
  | Field_read _ -> "field reads"
  | Method _ -> "method calls"
  | Box_new _ -> "Box"
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
    ori a0, a0, 1
    ld ra, 0(sp)
    addi sp, sp, 16
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
    ori a0, a0, 2
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
    ori a0, a0, 2
    ld ra, 0(sp)
    addi sp, sp, 16
    ret

# emo_blit: a0 = raw destination cursor, a1 = String; a0 = past the copy.
    .globl emo_blit
emo_blit:
    andi a1, a1, -8
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

# emo_string_eq: a0 = a1 = Strings; a0 = a Bool immediate (content).
    .globl emo_string_eq
emo_string_eq:
    andi a0, a0, -8
    andi a1, a1, -8
    ld t0, 8(a0)
    ld t1, 8(a1)
    bne t0, t1, .Lse_ne
    beqz t0, .Lse_eq
    addi t2, a0, 16
    addi t3, a1, 16
.Lse_loop:
    lbu t4, 0(t2)
    lbu t5, 0(t3)
    bne t4, t5, .Lse_ne
    addi t2, t2, 1
    addi t3, t3, 1
    addi t0, t0, -1
    bnez t0, .Lse_loop
.Lse_eq:
    li a0, 17
    ret
.Lse_ne:
    li a0, 1
    ret

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
    andi t0, a0, -8
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
    andi t0, a0, 7
    beqz t0, .Lts_i64
    li t1, 2
    beq t0, t1, .Lts_done
    li t1, 1
    beq t0, t1, .Lts_f64
    la a0, msg_kind
    la a1, msg_kind_end
    call emo_fail
.Lts_i64:
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
    andi t1, a0, -8
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
    andi a0, a0, -8
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

let emit (program : Emo_ir.program) : string =
  if program.pclasses <> [] then refuse "classes";
  if program.pglobals <> [] then refuse "module-level `var`";
  let env =
    {
      buf = Buffer.create 16384;
      fresh = 0;
      strs = [];
      labels = 0;
      cur = None;
      deferred = [];
    }
  in
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
        gput env "    .size %s, . - %s\n" label label)
      (List.rev env.strs)
  end;
  gput env "%s" stack_asm;
  Buffer.contents env.buf
