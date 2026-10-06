(* The Wasm backend: lowers the IR to a WasmGC module (Emo_wat's AST),
   serialized as binary .wasm and readable .wat.

   Value model: every dynamic value is an anyref into a boxed struct —
   $vint (i64), $vfloat (f64), $vbool, $vchar, $vstring (UTF-8 byte
   array), $vtuple, $vbox (its mutable field is the mutability),
   $venum, and one struct per class with the fields in declaration
   order. The runtime type is the tag: tests compile to
   ref.test/ref.cast.

   Host boundary: println renders into linear memory and calls an
   imported (ptr, len) println; raise calls an imported abort that
   throws in the host. $heap is the bump cursor for that exchange,
   starting at 1024. *)

module Ast = Emo_ast
module W = Emo_wat

(* ---- Fixed type table ---- *)

let t_println = 0
let t_abort = 1
let t_float_str = 2
let t_main = 3
let t_sig1 = 4
let t_sig2 = 5
let t_bytes = 6
let t_vstring = 7
let t_vint = 8
let t_vfloat = 9
let t_vbool = 10
let t_vchar = 11
let t_anyarray = 12
let t_vtuple = 13
let t_vbox = 14
let t_venum = 15
let t_vfun = 16
let t_str_eq = 23
let t_strcat = 24
let t_numop = 25
let t_vfun2 = 26
let t_proc = 27
let t_cons = 28
let t_vbytes = 29
let t_bytes_set = 30
let t_int_str = 17
let t_bool_str = 18
let t_char_str = 19
let t_bytes_from_mem = 20
let t_write_bytes = 21
let t_println_v = 22

let runtime_types : W.typ list =
  [
    W.FuncT ([ W.I32; W.I32 ], []);
    (* println *)
    W.FuncT ([ W.I32; W.I32 ], []);
    (* abort *)
    W.FuncT ([ W.F64 ], [ W.I32; W.I32 ]);
    (* float_str *)
    W.FuncT ([], []);
    (* main *)
    W.FuncT ([ W.Anyref ], [ W.Anyref ]);
    (* sig1: one arg *)
    W.FuncT ([ W.Anyref; W.Anyref ], [ W.I32 ]);
    (* sig2: two args, bool *)
    W.ArrayT (W.I8, true);
    (* $bytes *)
    W.StructT [ (W.RefNull t_bytes, false) ];
    (* $vstring *)
    W.StructT [ (W.I64, false) ];
    (* $vint *)
    W.StructT [ (W.F64, false) ];
    (* $vfloat *)
    W.StructT [ (W.I32, false) ];
    (* $vbool *)
    W.StructT [ (W.I32, false) ];
    (* $vchar *)
    W.ArrayT (W.Anyref, true);
    (* $anyarray *)
    W.StructT [ (W.RefNull t_anyarray, false) ];
    (* $vtuple *)
    W.StructT [ (W.Anyref, true) ];
    (* $vbox *)
    W.StructT [ (W.RefNull t_vstring, false); (W.RefNull t_vstring, false) ];
    (* $venum *)
    W.StructT [ (W.RefNull t_sig1, false) ];
    (* $vfun *)
    W.FuncT ([ W.I64 ], [ W.RefNull t_bytes ]);
    (* int_str *)
    W.FuncT ([ W.I32 ], [ W.RefNull t_bytes ]);
    (* bool_str *)
    W.FuncT ([ W.I32 ], [ W.RefNull t_bytes ]);
    (* char_str *)
    W.FuncT ([ W.I32; W.I32 ], [ W.RefNull t_bytes ]);
    (* bytes_from_mem *)
    W.FuncT ([ W.RefNull t_bytes ], [ W.I32 ]);
    (* write_bytes *)
    W.FuncT ([ W.Anyref ], []);
    (* print_v *)
    W.FuncT ([ W.RefNull t_bytes; W.RefNull t_bytes ], [ W.I32 ]);
    (* str_eq *)
    W.FuncT ([ W.RefNull t_bytes; W.RefNull t_bytes ], [ W.RefNull t_bytes ]);
    (* strcat *)
    W.FuncT ([ W.Anyref; W.Anyref ], [ W.Anyref ]);
    (* numeric/comparison *)
    W.StructT [ (W.RefNull t_numop, false) ];
    (* $vfun2: a receive handler — (msg, captured args) -> value *)
    W.StructT
      [
        (W.I32, false);
        (W.I32, true);
        (W.I32, true);
        (W.Anyref, true);
        (W.Anyref, true);
        (W.Anyref, true);
        (W.Anyref, true);
      ];
    (* $proc: id, alive, parked, mailbox head/tail, handler, args *)
    W.StructT [ (W.Anyref, true); (W.Anyref, true) ];
    (* $cons: a message-list cell, also the saved-current stack *)
    W.StructT [ (W.RefNull t_bytes, false) ];
    (* $vbytes — same payload shape as $vstring, mutable by convention *)
    W.FuncT ([ W.Anyref; W.Anyref; W.Anyref ], [ W.Anyref ]);
    (* bytes_set: recv, index, value -> value *)
  ]

let i_print = 0
let i_abort = 1
let i_float_str = 2

(* Runtime function indices: imports 0..2, then these. *)
let rt = function
  | "add" -> 3
  | "sub" -> 4
  | "mul" -> 5
  | "div" -> 6
  | "mod" -> 7
  | "neg" -> 8
  | "lt" -> 9
  | "le" -> 10
  | "gt" -> 11
  | "ge" -> 12
  | "eq" -> 13
  | "ne" -> 14
  | "to_str" -> 15
  | "println" -> 16
  | "strcat" -> 17
  | "box" -> 18
  | "throw" -> 19
  | "int_str" -> 20
  | "bool_str" -> 21
  | "char_str" -> 22
  | "instance_str" -> 23
  | "write_bytes" -> 24
  | "bytes_from_mem" -> 25
  | "str_eq" -> 26
  | "deep_eq" -> 27
  | "append" -> 28
  | "spawn_begin" -> 29
  | "spawn_end" -> 30
  | "send" -> 31
  | "recv_poll" -> 32
  | "recv_take" -> 33
  | "park" -> 34
  | "driver_next" -> 35
  | "driver_resume" -> 36
  | "driver_run" -> 37
  | "self_pid" -> 38
  | "halt" -> 39
  | "proc_end" -> 40
  | "bit_and" -> 41
  | "bit_or" -> 42
  | "bit_xor" -> 43
  | "shl" -> 44
  | "shr" -> 45
  | "bnot" -> 46
  | "bytes_new" -> 47
  | "bytes_get" -> 48
  | "bytes_set" -> 49
  | "bytes_u16_get" -> 50
  | "bytes_u32_get" -> 51
  | "bytes_u64_get" -> 52
  | "bytes_u16_set" -> 53
  | "bytes_u32_set" -> 54
  | "bytes_u64_set" -> 55
  | "bytes_from_str" -> 56
  | "bytes_to_str" -> 57
  | "bytes_label" -> 58
  | "init" -> 59
  | _ -> failwith "wasm: bad runtime function"

(* imports 3 + runtime funcs 3..46 + bytes ops 47..58 + init + main;
   program funcs follow. *)
let runtime_count =
  61 (* imports 3 + rt 38 + init + main + bit ops 6 + bytes ops 12 *)

(* ---- Lowering state ---- *)

type env = {
  mutable rev : W.instr list;
  mutable local_decls : W.valtype list;
  mutable local_map : (string * int) list;
  mutable binders : (string * W.instr list) list;
  mutable fname : string;
  mutable fparams : string list;
  mutable current_class : string option;
  mutable fresh : int;
  mutable types : W.typ list;
  mutable ntypes : int;
  mutable class_type : (string * int) list;
  mutable class_field : (string * (string * int) list) list;
  mutable funcs : (string * int) list;
  mutable nfuncs : int;
  mutable strings : (string * int) list;
  mutable string_pool : string list;
  mutable iface_classes : (string * string list) list;
  mutable classes : Emo_ir.class_ list;
  mutable hidden : (int * W.func_type) list;
}

let e env i = env.rev <- i :: env.rev
let es env xs = env.rev <- List.rev_append xs env.rev

let type_idx env (t : W.typ) : int =
  (* env.types accumulates program types in reverse AFTER the fixed
     runtime head; indices are absolute (runtime head first). *)
  let base = List.length runtime_types in
  let rec find i = function
    | [] -> None
    | t' :: rest -> if t = t' then Some (base + i) else find (i + 1) rest
  in
  match find 0 (List.rev env.types) with
  | Some i -> i
  | None ->
      let i = env.ntypes in
      env.types <- t :: env.types;
      env.ntypes <- i + 1;
      i

let fresh_local env name (t : W.valtype) : int =
  let idx = List.length env.local_decls in
  env.local_decls <- env.local_decls @ [ t ];
  env.local_map <- (name, idx) :: env.local_map;
  idx

let string_bytes_instrs (s : string) : W.instr list =
  let n = String.length s in
  List.mapi (fun i _ -> W.I32_const (Char.code s.[i])) (List.init n Fun.id)
  @ [ W.Array_new_fixed (t_bytes, n) ]

let string_const env (s : string) =
  match List.assoc_opt s env.strings with
  | Some g -> e env (W.Global_get g)
  | None ->
      let g = 1 + List.length env.string_pool in
      env.strings <- (s, g) :: env.strings;
      env.string_pool <- s :: env.string_pool;
      e env (W.Global_get g)

(* The i32 truthiness of a bool-struct value: the value arrives as
   anyref, so it is narrowed to $vbool before the field read. *)
let truthy (v : W.instr list) : W.instr list =
  v @ [ W.Ref_cast t_vbool; W.Struct_get (t_vbool, 0) ]

(* The class-member name behind a mangled method fname: the mangled
   form is `cname "__" member`. *)
let member_name (c : Emo_ir.class_) (m : Emo_ir.func) : string =
  let prefix = c.Emo_ir.cname ^ "__" in
  let n = m.Emo_ir.fname in
  if String.starts_with ~prefix n then
    String.sub n (String.length prefix) (String.length n - String.length prefix)
  else n

(* ---- Expression lowering ---- *)

(* Wrap the $vint on top of the stack back into a Byte's 0-255 range. *)
let mask_byte env =
  e env (W.Ref_cast t_vint);
  e env (W.Struct_get (t_vint, 0));
  e env (W.I64_const 255L);
  e env W.I64_and;
  e env (W.Struct_new t_vint)

let rec expr env (x : Emo_ir.expr) : unit =
  match x.Emo_ir.desc with
  | Const (L_int n) ->
      e env (W.I64_const (Int64.of_int n));
      e env (W.Struct_new t_vint)
  | Const (L_int64 n) ->
      e env (W.I64_const n);
      e env (W.Struct_new t_vint)
  | Const (L_byte n) ->
      e env (W.I64_const (Int64.of_int n));
      e env (W.Struct_new t_vint)
  | Const (L_float f) ->
      e env (W.F64_const f);
      e env (W.Struct_new t_vfloat)
  | Const (L_bool b) ->
      e env (W.I32_const (if b then 1 else 0));
      e env (W.Struct_new t_vbool)
  | Const (L_char c) ->
      e env (W.I32_const (Char.code c));
      e env (W.Struct_new t_vchar)
  | Const (L_string s) -> string_const env s
  | Type_ref name -> string_const env name
  | Var name -> (
      match List.assoc_opt name env.binders with
      | Some instrs -> es env instrs
      | None -> (
          match List.assoc_opt name env.local_map with
          | Some i -> e env (W.Local_get i)
          | None ->
              failwith
                ("wasm: unbound local " ^ name ^ " in " ^ env.fname ^ " map="
                ^ String.concat "," (List.map fst env.local_map))))
  | Global name -> (
      match List.assoc_opt name env.funcs with
      | Some fidx ->
          e env (W.Ref_func fidx);
          e env (W.Struct_new t_vfun)
      | None -> failwith ("wasm: unbound global " ^ name))
  | Tuple es ->
      List.iter (expr env) es;
      e env (W.Array_new_fixed (t_anyarray, List.length es));
      e env (W.Struct_new t_vtuple)
  | Array_lit es ->
      List.iter (expr env) es;
      e env (W.Array_new_fixed (t_anyarray, List.length es))
  | Make_enum { enum_name; member } ->
      string_const env enum_name;
      string_const env member;
      e env (W.Struct_new t_venum)
  | Interpolate items -> (
      (* each item renders to a bytes ref (its own instr group); the
         groups are then joined with strcat *)
      let groups =
        List.map
          (fun item ->
            expr_block env item
            @ [
                W.Call (rt "to_str");
                W.Ref_cast t_vstring;
                W.Struct_get (t_vstring, 0);
              ])
          items
      in
      (* stack order: push every group's bytes, strcat after each pair *)
      let rec chain acc = function
        | [] -> acc
        | g :: rest -> chain (acc @ g @ [ W.Call (rt "strcat") ]) rest
      in
      match groups with
      | [] -> string_const env ""
      | g0 :: rest -> es env (chain g0 rest @ [ W.Struct_new t_vstring ]))
  | Unary (Ast.Neg, operand) ->
      expr env operand;
      e env (W.Call (rt "neg"))
  | Unary (Ast.Not, operand) ->
      expr env operand;
      e env (W.Struct_get (t_vbool, 0));
      e env W.I32_eqz;
      e env (W.Struct_new t_vbool)
  | Unary (Ast.Bit_not, operand) ->
      expr env operand;
      e env (W.Call (rt "bnot"));
      if x.Emo_ir.ety = Emo_check.Byte then mask_byte env
  | Cond { c; t; e = else_ } ->
      es env
        (truthy (expr_block env c)
        @ [ W.If (W.Result W.Anyref, expr_block env t, expr_block env else_) ])
  | Binary (Ast.And, l, r) ->
      expr env l;
      e env (W.Struct_get (t_vbool, 0));
      let rcode = expr_block env r in
      e env (W.If (W.Result W.I32, truthy rcode, [ W.I32_const 0 ]));
      e env (W.Struct_new t_vbool)
  | Binary (Ast.Or, l, r) ->
      expr env l;
      e env (W.Struct_get (t_vbool, 0));
      let rcode = expr_block env r in
      e env (W.If (W.Result W.I32, [ W.I32_const 1 ], truthy rcode));
      e env (W.Struct_new t_vbool)
  | Binary (op, l, r) ->
      expr env l;
      expr env r;
      let fn =
        match op with
        | Ast.Add -> "add"
        | Ast.Sub -> "sub"
        | Ast.Mul -> "mul"
        | Ast.Div -> "div"
        | Ast.Mod -> "mod"
        | Ast.Lt -> "lt"
        | Ast.Le -> "le"
        | Ast.Gt -> "gt"
        | Ast.Ge -> "ge"
        | Ast.Eq -> "eq"
        | Ast.Ne -> "ne"
        | Ast.Bit_and -> "bit_and"
        | Ast.Bit_or -> "bit_or"
        | Ast.Bit_xor -> "bit_xor"
        | Ast.Shl -> "shl"
        | Ast.Shr -> "shr"
        | Ast.And | Ast.Or -> "add"
      in
      e env (W.Call (rt fn));
      (* A Byte stays inside 0-255, so only the operations that can
         leave the range wrap back into it. *)
      if x.Emo_ir.ety = Emo_check.Byte then (
        match op with
        | Ast.Add | Ast.Sub | Ast.Mul | Ast.Shl -> mask_byte env
        | _ -> ())
  | Index (b, i) ->
      (* a tuple wraps its element array; an array is bare. Both the
         collection and the index go through locals: the arms of the
         shape chain cannot read the caller's stack. *)
      let recv = fresh_local env "__idx_recv" W.Anyref in
      let idx = fresh_local env "__idx_i" W.I32 in
      expr env b;
      e env (W.Local_set recv);
      expr env i;
      e env (W.Ref_cast t_vint);
      e env (W.Struct_get (t_vint, 0));
      e env W.I32_wrap_i64;
      e env (W.Local_set idx);
      let rec chain = function
        | [] -> [ W.Unreachable ]
        | (t, unwrap) :: rest ->
            [
              W.If_else
                ( W.Result W.Anyref,
                  [ W.Local_get recv; W.Ref_test t ],
                  unwrap recv @ [ W.Local_get idx; W.Array_get t_anyarray ],
                  chain rest );
            ]
      in
      es env
        (chain
           [
             ( t_vtuple,
               fun l ->
                 [
                   W.Local_get l; W.Ref_cast t_vtuple; W.Struct_get (t_vtuple, 0);
                 ] );
             (t_anyarray, fun l -> [ W.Local_get l; W.Ref_cast t_anyarray ]);
           ])
  | Field_read { obj; name } -> (
      (* a module reference: the alias's runtime value is never used —
         qualified calls resolve statically — so the qualified path as
         a string stands in, matching the TypeScript target's inert
         module value *)
      match obj.Emo_ir.desc with
      | Emo_ir.Type_ref m -> string_const env (m ^ "__" ^ name)
      | _ -> (
          let class_name =
            match obj.Emo_ir.ety with
            | Emo_check.ClassType c -> c
            | _ -> (
                (* The span type table keys on span start, so `self.x`
                   and the chain it opens share a start and the
                   receiver's type is lost; inside a class member, self
                   is the class. *)
                match env.current_class with
                | Some c -> c
                | None -> failwith "wasm: field read without a known class")
          in
          match
            ( List.assoc_opt class_name env.class_field,
              List.assoc_opt class_name env.class_type )
          with
          | Some fields, Some tidx -> (
              match List.assoc_opt name fields with
              | Some fidx ->
                  expr env obj;
                  e env (W.Ref_cast tidx);
                  e env (W.Struct_get (tidx, fidx))
              | None ->
                  failwith ("wasm: unknown field " ^ class_name ^ "." ^ name))
          | _ -> failwith ("wasm: unknown class " ^ class_name)))
  | Call { func; args } -> (
      List.iter (expr env) args;
      match List.assoc_opt func env.funcs with
      | Some fidx -> e env (W.Call fidx)
      | None -> failwith ("wasm: unbound call " ^ func))
  | Call_value { f; args } -> (
      match args with
      | [ arg ] ->
          expr env arg;
          expr env f;
          e env (W.Ref_cast t_vfun);
          e env (W.Struct_get (t_vfun, 0));
          e env (W.Ref_cast t_sig1);
          e env (W.Call_ref t_sig1)
      | _ ->
          raise
            (Emo_ir.Lower_error
               "wasm: only one-parameter closures are supported yet"))
  | Method { self_; name; args } -> method_call env self_ name args
  | Builtin { name; args } -> (
      match (name, args) with
      | "println", [ v ] ->
          expr env v;
          e env (W.Call (rt "println"))
      | "self_pid", [] -> e env (W.Call (rt "self_pid"))
      | "halt", [] -> e env (W.Call (rt "halt"))
      | _ ->
          raise
            (Emo_ir.Lower_error
               ("builtin `" ^ name ^ "` is not available on the wasm target")))
  | Box_new v ->
      expr env v;
      e env (W.Call (rt "box"))
  | Bytes_new v ->
      expr env v;
      e env (W.Call (rt "bytes_new"))
  | Make_exception { message } ->
      expr env message;
      e env (W.Call (rt "throw"));
      e env W.Unreachable
  | Do_spawn { func; args } -> (
      (* the child's first turn runs here: it evaluates with the
         parent's bindings already on the stack, then parks or ends.
         The pid lands below the call — stashed so it survives as the
         spawn's value. *)
      match List.assoc_opt func env.funcs with
      | Some fidx ->
          (* the arguments evaluate in the parent's context — before
             spawn_begin switches the current process — so self_pid()
             inside them names the spawner *)
          let pid = fresh_local env "__spawn_pid" W.Anyref in
          let arg_locals =
            List.map (fun _ -> fresh_local env "__spawn_arg" W.Anyref) args
          in
          List.iter2
            (fun a l ->
              expr env a;
              e env (W.Local_set l))
            args arg_locals;
          e env (W.Call (rt "spawn_begin"));
          e env (W.Local_set pid);
          List.iter (fun l -> e env (W.Local_get l)) arg_locals;
          e env (W.Call fidx);
          e env W.Drop;
          e env (W.Call (rt "proc_end"));
          e env (W.Call (rt "spawn_end"));
          e env (W.Local_get pid)
      | None -> failwith ("wasm: unbound spawn " ^ func))
  | Spawn_value _ ->
      raise (Emo_ir.Lower_error "wasm: `do` lowers from a call only")
  | Closure { cparams; cbody } -> (
      match cparams with
      | [ (p, _) ] ->
          let fidx = emit_closure env p cbody in
          e env (W.Ref_func fidx);
          e env (W.Struct_new t_vfun)
      | _ ->
          raise
            (Emo_ir.Lower_error
               "wasm: only one-parameter closures are supported yet"))

and method_call env self_ name args =
  let mangled = Emo_ir.sanitize_ident name in
  match (name, args) with
  | "to_string", [] ->
      expr env self_;
      (* a Bytes receiver stringifies raw; the labeled spelling is the
         display form the generic to_str produces *)
      e env
        (W.Call
           (rt
              (match self_.Emo_ir.ety with
              | Emo_check.Bytes -> "bytes_to_str"
              | _ -> "to_str")))
  | "length", [] ->
      (* arrays, tuples, and strings carry a length; the arms rebuild
         from a scratch local — the if's arms cannot see the caller's
         stack *)
      let recv = fresh_local env "__len_recv" W.Anyref in
      expr env self_;
      e env (W.Local_set recv);
      let rec chain = function
        | [] -> [ W.Unreachable ]
        | (t, unwrap) :: rest ->
            [
              W.If_else
                ( W.Result W.I32,
                  [ W.Local_get recv; W.Ref_test t ],
                  unwrap recv,
                  chain rest );
            ]
      in
      es env
        (chain
           [
             ( t_anyarray,
               fun l ->
                 [
                   W.Local_get l; W.Ref_cast t_anyarray; W.Array_len t_anyarray;
                 ] );
             ( t_vtuple,
               fun l ->
                 [
                   W.Local_get l;
                   W.Ref_cast t_vtuple;
                   W.Struct_get (t_vtuple, 0);
                   W.Array_len t_anyarray;
                 ] );
             ( t_vstring,
               fun l ->
                 [
                   W.Local_get l;
                   W.Ref_cast t_vstring;
                   W.Struct_get (t_vstring, 0);
                   W.Array_len t_bytes;
                 ] );
             ( t_vbytes,
               fun l ->
                 [
                   W.Local_get l;
                   W.Ref_cast t_vbytes;
                   W.Struct_get (t_vbytes, 0);
                   W.Array_len t_bytes;
                 ] );
           ]);
      e env W.I64_extend_i32_s;
      e env (W.Struct_new t_vint)
  | "append", [ v ] ->
      expr env self_;
      expr env v;
      e env (W.Call (rt "append"))
  | "read", [] ->
      (* the receiver is a Box by construction; the cast is the check *)
      expr env self_;
      e env (W.Ref_cast t_vbox);
      e env (W.Struct_get (t_vbox, 0))
  | "replace", [ v ] ->
      (* the new value is both stored and returned; receiver and value
         go through scratch locals to keep the evaluation order *)
      let recv = fresh_local env "__box_recv" W.Anyref in
      let val_local = fresh_local env "__box_val" W.Anyref in
      expr env self_;
      e env (W.Local_set recv);
      expr env v;
      e env (W.Local_set val_local);
      e env (W.Local_get recv);
      e env (W.Ref_cast t_vbox);
      e env (W.Local_get val_local);
      e env (W.Struct_set (t_vbox, 0));
      e env (W.Local_get val_local)
  | "get", [ i ] ->
      expr env self_;
      expr env i;
      e env (W.Call (rt "bytes_get"))
  | "set", [ i; v ] ->
      expr env self_;
      expr env i;
      expr env v;
      e env (W.Call (rt "bytes_set"))
  | (("get_u16_le" | "get_u32_le" | "get_u64_le") as mname), [ i ] ->
      expr env self_;
      expr env i;
      e env
        (W.Call
           (rt
              (match mname with
              | "get_u16_le" -> "bytes_u16_get"
              | "get_u32_le" -> "bytes_u32_get"
              | _ -> "bytes_u64_get")))
  | (("set_u16_le" | "set_u32_le" | "set_u64_le") as mname), [ i; v ] ->
      expr env self_;
      expr env i;
      expr env v;
      e env
        (W.Call
           (rt
              (match mname with
              | "set_u16_le" -> "bytes_u16_set"
              | "set_u32_le" -> "bytes_u32_set"
              | _ -> "bytes_u64_set")))
  | "to_bytes", [] ->
      (* the receiver is a String; the copy keeps the two independent *)
      expr env self_;
      e env (W.Call (rt "bytes_from_str"))
  (* The fixed-width conversions. Int64 and Byte are both a $vint around
     an i64, the same shape Int has, so only the narrowing back to Byte
     masks anything. *)
  | "to_int", [] ->
      (* Int64 and Byte already have Int's shape, so this is the identity.
         A String receiver would parse, which this target does not do yet;
         the shape test keeps it from passing the string through. *)
      let recv = fresh_local env "__to_int_recv" W.Anyref in
      expr env self_;
      e env (W.Local_set recv);
      e env (W.Local_get recv);
      e env (W.Ref_test t_vint);
      e env (W.If (W.Void, [], [ W.Unreachable ]));
      e env (W.Local_get recv)
  | "to_byte", [] ->
      expr env self_;
      mask_byte env
  | "to_bits", [] ->
      expr env self_;
      e env (W.Ref_cast t_vfloat);
      e env (W.Struct_get (t_vfloat, 0));
      e env W.I64_reinterpret_f64;
      e env (W.Struct_new t_vint)
  | "from_int", [ v ] -> (
      match self_.Emo_ir.desc with
      | Emo_ir.Type_ref "Int64" -> expr env v
      | _ ->
          (* `Byte.from_int` is the one conversion the checker leaves to
             run time: nothing outside 0-255 has a Byte to narrow to. *)
          let n = fresh_local env "__byte_from_int" W.I64 in
          expr env v;
          e env (W.Ref_cast t_vint);
          e env (W.Struct_get (t_vint, 0));
          e env (W.Local_tee n);
          e env (W.I64_const 255L);
          e env W.I64_and;
          e env (W.Local_get n);
          e env W.I64_eq;
          e env W.I32_eqz;
          e env (W.If (W.Void, [ W.Unreachable ], []));
          e env (W.Local_get n);
          e env (W.Struct_new t_vint))
  | "from_bits", [ v ] ->
      expr env v;
      e env (W.Ref_cast t_vint);
      e env (W.Struct_get (t_vint, 0));
      e env W.F64_reinterpret_i64;
      e env (W.Struct_new t_vfloat)
  | "is", [ target ] -> (
      let tname =
        match target.Emo_ir.desc with
        | Emo_ir.Type_ref n -> n
        | _ -> failwith "wasm: `is` expects a type name"
      in
      let classes =
        match List.assoc_opt tname env.iface_classes with
        | Some cs -> cs
        | None -> (
            (* a class `is` test: the name is the display name, the
               struct type is keyed by the mangled cname *)
            match
              List.find_opt
                (fun c -> String.equal c.Emo_ir.cdisplay tname)
                env.classes
            with
            | Some c -> [ c.Emo_ir.cname ]
            | None -> [])
      in
      let tests =
        List.filter_map
          (fun cname ->
            List.assoc_opt cname env.class_type
            |> Option.map (fun tidx -> W.Ref_test tidx))
          classes
      in
      match tests with
      | [] ->
          raise (Emo_ir.Lower_error ("wasm: unknown type in `is`: " ^ tname))
      | first :: rest ->
          let scratch = fresh_local env "__is_recv" W.Anyref in
          expr env self_;
          e env (W.Local_set scratch);
          e env (W.Local_get scratch);
          e env first;
          List.iter
            (fun t ->
              e env (W.Local_get scratch);
              e env t;
              e env W.I32_or)
            rest;
          e env (W.Struct_new t_vbool))
  | _ -> (
      let recv_class =
        match self_.Emo_ir.ety with
        | Emo_check.ClassType c -> Some c
        | _ -> None
      in
      match recv_class with
      | Some c -> (
          match List.assoc_opt (c ^ "__" ^ mangled) env.funcs with
          | Some fidx ->
              expr env self_;
              List.iter (expr env) args;
              e env (W.Call fidx)
          | None ->
              raise
                (Emo_ir.Lower_error
                   (Printf.sprintf
                      "wasm: method `%s` has no static dispatch (in %s, self \
                       type: %s)"
                      name env.fname
                      (Emo_check.to_string self_.Emo_ir.ety))))
      | None -> (
          (* The receiver's static type is not a class (an interface,
             or an ety the span table lost): dispatch over every class
             that defines the method. The runtime value is one of
            them — the checker admitted the call — and extra arms
            simply never fire. *)
          let matching =
            List.filter_map
              (fun (c : Emo_ir.class_) ->
                if
                  List.exists
                    (fun (m : Emo_ir.func) ->
                      String.equal (member_name c m) mangled
                      && List.length m.Emo_ir.fparams - 1 = List.length args)
                    c.Emo_ir.cmethods
                then
                  match
                    ( List.assoc_opt c.Emo_ir.cname env.class_type,
                      List.assoc_opt (c.Emo_ir.cname ^ "__" ^ mangled) env.funcs
                    )
                  with
                  | Some tidx, Some fidx -> Some (tidx, fidx)
                  | _ -> None
                else None)
              env.classes
          in
          match matching with
          | [] ->
              raise
                (Emo_ir.Lower_error
                   (Printf.sprintf
                      "wasm: method `%s` has no static dispatch (in %s, self \
                       type: %s)"
                      name env.fname
                      (Emo_check.to_string self_.Emo_ir.ety)))
          | arms ->
              (* The if's arms cannot see the operand stack below the
                 frame, so self and every argument go through scratch
                 locals and each arm rebuilds the call's operands. *)
              let scratch = fresh_local env "__iface_recv" W.Anyref in
              let arg_locals =
                List.map (fun _ -> fresh_local env "__iface_arg" W.Anyref) args
              in
              expr env self_;
              e env (W.Local_set scratch);
              List.iter2
                (fun a l ->
                  expr env a;
                  e env (W.Local_set l))
                args arg_locals;
              let arm_args = List.map (fun l -> W.Local_get l) arg_locals in
              let rec chain arms =
                match arms with
                | [] -> [ W.Unreachable ]
                | (tidx, fidx) :: rest ->
                    [
                      W.If_else
                        ( W.Result W.Anyref,
                          [ W.Local_get scratch; W.Ref_test tidx ],
                          (W.Local_get scratch :: arm_args) @ [ W.Call fidx ],
                          chain rest );
                    ]
              in
              es env (chain arms)))

(* ---- Statement lowering ---- *)

and emit_closure env p cbody : int =
  let fidx = env.nfuncs in
  env.nfuncs <- env.nfuncs + 1;
  let saved_rev = env.rev in
  let saved_locals = env.local_decls in
  let saved_map = env.local_map in
  let saved_binders = env.binders in
  let saved_fname = env.fname in
  let saved_fparams = env.fparams in
  env.rev <- [];
  env.local_decls <- [ W.Anyref ];
  env.local_map <- [ (p, 0) ];
  env.binders <- [];
  env.fname <- "";
  env.fparams <- [];
  let body = stmts_value env cbody ~tail:true in
  env.hidden <-
    ( fidx,
      { W.ftype_idx = t_sig1; fparams = [ "x" ]; flocals = []; fbody = body } )
    :: env.hidden;
  env.rev <- saved_rev;
  env.local_decls <- saved_locals;
  env.local_map <- saved_map;
  env.binders <- saved_binders;
  env.fname <- saved_fname;
  env.fparams <- saved_fparams;
  fidx

and stmts env (xs : Emo_ir.stmt list) ~(tail : bool) : W.instr list =
  match xs with
  | [] ->
      (* A Void function or arrow block ends without `return` and yields
         the Void value (an empty tuple struct); the checker rejects a
         fall-off in any other body. *)
      if tail then [ W.Array_new_fixed (t_anyarray, 0); W.Struct_new t_vtuple ]
      else []
  | [ s ] -> stmt env s ~tail
  | s :: rest ->
      (* Left-to-right: each statement's instructions (and any local
         declarations it performs) must precede the rest. *)
      let code = stmt env s ~tail:false in
      code @ stmts env rest ~tail

(* Whether a statement in tail position yields the block's result value
   by itself. [if] never does — its arms are emitted valueless — and
   effects and bindings end in a drop or a local set. *)
and yields_value (s : Emo_ir.stmt) =
  match s with
  | Emo_ir.Return_stmt _ | Emo_ir.Case _ | Emo_ir.Receive _ -> true
  | _ -> false

(* A statement list whose enclosing block expects a value. The checker
   guarantees a value-returning body always ends in `return`, so the
   appended Void value only fires for Void bodies whose last statement
   cannot yield (a trailing `if`, say). *)
and stmts_value env (xs : Emo_ir.stmt list) ~(tail : bool) : W.instr list =
  let base = stmts env xs ~tail in
  match List.rev xs with
  | [] -> base
  | last :: _ when yields_value last -> base
  | _ -> base @ [ W.Array_new_fixed (t_anyarray, 0); W.Struct_new t_vtuple ]

and expr_block env (x : Emo_ir.expr) : W.instr list =
  let before = env.rev in
  expr env x;
  (* Emission prepends, so the new instructions are the FIRST k entries
     of the reversed accumulator — the old `drop (length before)` slice
     read the wrong end whenever anything was already pending. *)
  let k = List.length env.rev - List.length before in
  let code = List.rev (List.filteri (fun i _ -> i < k) env.rev) in
  env.rev <- before;
  code

and stmt env (s : Emo_ir.stmt) ~(tail : bool) : W.instr list =
  match s with
  | Emo_ir.Effect x -> (
      let code = expr_block env x in
      match x.Emo_ir.desc with
      | Emo_ir.Builtin { name = "println"; _ } -> code
      | _ -> code @ [ W.Drop ])
  | Emo_ir.Let { mutable_ = _; name; init } ->
      (* a closure value is a $vfun struct — funcref is not under any *)
      let t =
        match init.Emo_ir.desc with
        | Emo_ir.Closure _ -> W.RefNull t_vfun
        | _ -> W.Anyref
      in
      let idx = fresh_local env name t in
      expr_block env init @ [ W.Local_set idx ]
  | Emo_ir.Assign_var { name; value } -> (
      match List.assoc_opt name env.local_map with
      | Some idx -> expr_block env value @ [ W.Local_set idx ]
      | None -> failwith ("wasm: assignment to unbound " ^ name))
  | Emo_ir.Set_field { self_; name; value } -> (
      let class_name =
        match self_.Emo_ir.ety with
        | Emo_check.ClassType c -> c
        | _ -> (
            match env.current_class with
            | Some c -> c
            | None -> failwith "wasm: field set without a known class")
      in
      match
        ( List.assoc_opt class_name env.class_field,
          List.assoc_opt class_name env.class_type )
      with
      | Some fields, Some tidx -> (
          match List.assoc_opt name fields with
          | Some fidx ->
              expr_block env self_ @ [ W.Ref_cast tidx ] @ expr_block env value
              @ [ W.Struct_set (tidx, fidx) ]
          | None -> failwith ("wasm: unknown field " ^ class_name ^ "." ^ name))
      | _ -> failwith ("wasm: unknown class " ^ class_name))
  | Emo_ir.If { cond; then_; else_ } ->
      truthy (expr_block env cond)
      @ [
          W.If (W.Void, stmts env then_ ~tail:false, stmts env else_ ~tail:false);
        ]
  | Emo_ir.Case { scrutinee; branches } -> case env scrutinee branches ~tail
  | Emo_ir.Receive { branches } -> receive env branches ~tail
  | Emo_ir.Send { target; message } ->
      expr_block env target @ expr_block env message
      @ [ W.Call (rt "send"); W.Drop ]
  | Emo_ir.Raise x -> expr_block env x @ [ W.Call (rt "throw"); W.Unreachable ]
  | Emo_ir.Return_stmt x -> (
      match x.Emo_ir.desc with
      | Emo_ir.Call { func = g; args } when g = env.fname -> (
          (* self tail call: constant stack *)
          let arg_code = List.concat_map (expr_block env) args in
          match List.assoc_opt g env.funcs with
          | Some fidx -> arg_code @ [ W.Return_call fidx ]
          | None -> failwith ("wasm: unbound call " ^ g))
      | _ -> expr_block env x @ if tail then [] else [ W.Return ])

and dispatch_branches env (s : W.instr list) (branches : Emo_ir.branch list)
    ~(tail : bool) : W.instr list =
  let blocktype = if tail then W.Result W.Anyref else W.Void in
  let saved_recv = List.assoc_opt "__is_recv" env.local_map in
  let recv_local = fresh_local env "__is_dispatch_r" W.Anyref in
  env.local_map <- ("__is_recv", recv_local) :: env.local_map;
  let rec build bs =
    match bs with
    | [] ->
        string_const_boxed env "no case branch matched this value"
        @ [ W.Call (rt "throw"); W.Unreachable ]
    | b :: rest ->
        let saved = env.binders in
        env.binders <- pattern_bindings s b.Emo_ir.pattern @ saved;
        let test = pattern_test env s b.Emo_ir.pattern in
        let guard =
          match b.Emo_ir.guard with
          | Some g -> truthy (expr_block env g)
          | None -> []
        in
        let cond =
          match guard with [] -> test | _ -> test @ guard @ [ W.I32_and ]
        in
        let body =
          if tail then stmts_value env b.Emo_ir.body ~tail
          else stmts env b.Emo_ir.body ~tail
        in
        env.binders <- saved;
        let no_match = build rest in
        [ W.If_else (blocktype, cond, body, no_match) ]
  in
  let arms = build branches in
  match saved_recv with
  | Some l ->
      env.local_map <- ("__is_recv", l) :: env.local_map;
      arms
  | None ->
      env.local_map <- List.remove_assoc "__is_recv" env.local_map;
      arms

and case env scrutinee (branches : Emo_ir.branch list) ~(tail : bool) :
    W.instr list =
  let sname = Printf.sprintf "__s%d" env.fresh in
  env.fresh <- env.fresh + 1;
  let sidx = fresh_local env sname W.Anyref in
  (* the scrutinee's code is captured, not left in the rev buffer: it
     must sit directly before the case's local.set *)
  let scrutinee_code = expr_block env scrutinee in
  scrutinee_code @ [ W.Local_set sidx ]
  @ dispatch_branches env [ W.Local_get sidx ] branches ~tail

(* The enclosing bindings a receive hands its handler: the newest
   binding per name, in binding order — the park packs them into a
   tuple and the handler unpacks them back by name. *)
and captured_bindings (env : env) : (string * int) list =
  let rec pick seen = function
    | [] -> []
    | ((n, i) as x) :: rest ->
        if List.mem_assoc n seen then pick seen rest
        else x :: pick ((n, i) :: seen) rest
  in
  pick [] env.local_map

and receive env (branches : Emo_ir.branch list) ~(tail : bool) : W.instr list =
  (* Non-empty mailbox: the message dispatches inline. Empty: the
     process parks — the handler (a hidden func of (msg, captured
     bindings)) re-runs the same dispatch when the driver delivers. A
     suspending receive continues past the park, so the receive must
     be the body's last statement: what follows would otherwise run
     twice (once at park, once at resume). *)
  if not tail then
    raise
      (Emo_ir.Lower_error
         "wasm: a receive must be the last statement of its body");
  let caps = captured_bindings env in
  let handler_idx = emit_receive_handler env caps branches in
  let msg = fresh_local env "__recv_msg" W.Anyref in
  let park_code =
    [ W.Ref_func handler_idx; W.Struct_new t_vfun2 ]
    @ List.concat_map (fun (_, i) -> [ W.Local_get i ]) caps
    @ [
        W.Array_new_fixed (t_anyarray, List.length caps);
        W.Struct_new t_vtuple;
        W.Call (rt "park");
        W.Drop;
      ]
  in
  let dispatch =
    dispatch_branches env [ W.Local_get msg ] branches ~tail:false
  in
  [
    W.Call (rt "recv_poll");
    W.Local_set msg;
    W.Local_get msg;
    W.Ref_is_null;
    W.I32_eqz;
    W.If (W.Void, [ W.Call (rt "recv_take") ] @ dispatch, park_code);
    (* a trailing receive is the function's return value; a mid-body
       one leaves nothing behind *)
    W.Ref_null_any;
  ]
  @ if tail then [] else [ W.Drop ]

and emit_receive_handler env (caps : (string * int) list)
    (branches : Emo_ir.branch list) : int =
  let fidx = env.nfuncs in
  env.nfuncs <- env.nfuncs + 1;
  let saved_rev = env.rev in
  let saved_locals = env.local_decls in
  let saved_map = env.local_map in
  let saved_binders = env.binders in
  let saved_fname = env.fname in
  let saved_fparams = env.fparams in
  let saved_cc = env.current_class in
  env.rev <- [];
  env.local_decls <- [ W.Anyref; W.Anyref ];
  env.local_map <- [ ("__recv_msg", 0); ("__recv_args", 1) ];
  env.binders <- [];
  env.fname <- Printf.sprintf "__recv_%d" fidx;
  env.fparams <- [ "__recv_msg"; "__recv_args" ];
  env.current_class <- None;
  let unpacked =
    List.concat_map
      (fun (k, (n, _)) ->
        [
          W.Local_get 1;
          W.Ref_cast t_vtuple;
          W.Struct_get (t_vtuple, 0);
          W.I32_const k;
          W.Array_get t_anyarray;
          W.Local_set (fresh_local env n W.Anyref);
        ])
      (List.mapi (fun k x -> (k, x)) caps)
  in
  let dispatch = dispatch_branches env [ W.Local_get 0 ] branches ~tail:false in
  let body = unpacked @ dispatch @ [ W.Ref_null_any ] in
  env.hidden <-
    ( fidx,
      {
        W.ftype_idx = t_numop;
        fparams = [ "__recv_msg"; "__recv_args" ];
        flocals = List.map (fun t -> (1, t)) env.local_decls;
        fbody = body;
      } )
    :: env.hidden;
  env.rev <- saved_rev;
  env.local_decls <- saved_locals;
  env.local_map <- saved_map;
  env.binders <- saved_binders;
  env.fname <- saved_fname;
  env.fparams <- saved_fparams;
  env.current_class <- saved_cc;
  fidx

and pattern_test env (s : W.instr list) (p : Emo_ast.pattern) : W.instr list =
  (* [s] re-reads the scrutinee; it goes inside every cond and arm —
     the if's frames cannot see values pushed before them *)
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_binding _ -> [ W.I32_const 1 ]
  | Ast.Pattern_literal (L_int n) ->
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_vint ],
            s
            @ [
                W.Ref_cast t_vint;
                W.Struct_get (t_vint, 0);
                W.I64_const (Int64.of_int n);
                W.I64_eq;
              ],
            [ W.I32_const 0 ] );
      ]
  | Ast.Pattern_literal (L_int64 n) ->
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_vint ],
            s
            @ [
                W.Ref_cast t_vint;
                W.Struct_get (t_vint, 0);
                W.I64_const n;
                W.I64_eq;
              ],
            [ W.I32_const 0 ] );
      ]
  | Ast.Pattern_literal (L_byte n) ->
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_vint ],
            s
            @ [
                W.Ref_cast t_vint;
                W.Struct_get (t_vint, 0);
                W.I64_const (Int64.of_int n);
                W.I64_eq;
              ],
            [ W.I32_const 0 ] );
      ]
  | Ast.Pattern_literal (L_string str) ->
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_vstring ],
            s
            @ [ W.Ref_cast t_vstring; W.Struct_get (t_vstring, 0) ]
            @ string_const_bytes env str
            @ [ W.Call (rt "str_eq") ],
            [ W.I32_const 0 ] );
      ]
  | Ast.Pattern_literal (L_bool b) ->
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_vbool ],
            s
            @ [
                W.Ref_cast t_vbool;
                W.Struct_get (t_vbool, 0);
                W.I32_const (if b then 1 else 0);
                W.I32_eq;
              ],
            [ W.I32_const 0 ] );
      ]
  | Ast.Pattern_literal (L_float f) ->
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_vfloat ],
            s
            @ [
                W.Ref_cast t_vfloat;
                W.Struct_get (t_vfloat, 0);
                W.F64_const f;
                W.F64_eq;
              ],
            [ W.I32_const 0 ] );
      ]
  | Ast.Pattern_literal (L_char c) ->
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_vchar ],
            s
            @ [
                W.Ref_cast t_vchar;
                W.Struct_get (t_vchar, 0);
                W.I32_const (Char.code c);
                W.I32_eq;
              ],
            [ W.I32_const 0 ] );
      ]
  | Ast.Enum_member (t, m) ->
      let bytes_of = string_const_bytes env in
      let field_cmp (f : int) =
        s
        @ [
            W.Ref_cast t_venum;
            W.Struct_get (t_venum, f);
            W.Ref_cast t_vstring;
            W.Struct_get (t_vstring, 0);
          ]
        @ bytes_of (if f = 0 then t else m)
        @ [ W.Call (rt "str_eq") ]
      in
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_venum ],
            [
              W.If_else
                (W.Result W.I32, field_cmp 0, field_cmp 1, [ W.I32_const 0 ]);
            ],
            [ W.I32_const 0 ] );
      ]
  | Ast.Tuple_pattern ps ->
      (* every element must match: one sub-test per position, ANDed —
         each sub-test re-reads the element from the scrutinee, so the
         if's arms never touch the caller's stack *)
      let elem i =
        s
        @ [
            W.Ref_cast t_vtuple;
            W.Struct_get (t_vtuple, 0);
            W.I32_const i;
            W.Array_get t_anyarray;
          ]
      in
      let sub_tests =
        List.mapi (fun i sub -> pattern_test env (elem i) sub) ps
      in
      let rec fold_and = function
        | [] -> [ W.I32_const 1 ]
        | [ x ] -> x
        | x :: rest -> x @ fold_and rest @ [ W.I32_and ]
      in
      [
        W.If_else
          ( W.Result W.I32,
            s @ [ W.Ref_test t_vtuple ],
            fold_and sub_tests,
            [ W.I32_const 0 ] );
      ]

and string_const_boxed env (s : string) : W.instr list =
  (* the pooled $vstring itself, as returned instructions *)
  let before = env.rev in
  string_const env s;
  let code = List.rev (List.drop (List.length before) env.rev) in
  env.rev <- before;
  code

and string_const_bytes env (s : string) : W.instr list =
  (* the pool global holds a boxed $vstring; unwrap it to its bytes *)
  let before = env.rev in
  string_const env s;
  let code = List.rev (List.drop (List.length before) env.rev) in
  env.rev <- before;
  code @ [ W.Ref_cast t_vstring; W.Struct_get (t_vstring, 0) ]

and pattern_bindings (s : W.instr list) (p : Emo_ast.pattern) :
    (string * W.instr list) list =
  match p.Ast.pattern_desc with
  | Ast.Pattern_binding name -> [ (name, s) ]
  | Ast.Tuple_pattern ps ->
      List.concat_map
        (fun (i, sub) ->
          pattern_bindings
            (s
            @ [
                W.Ref_cast t_vtuple;
                W.Struct_get (t_vtuple, 0);
                W.I32_const i;
                W.Array_get t_anyarray;
              ])
            sub)
        (List.mapi (fun i sub -> (i, sub)) ps)
  | _ -> []

(* ---- Function emission ---- *)

let emit_func env (f : Emo_ir.func) : W.func_type =
  env.rev <- [];
  env.local_decls <- List.map (fun _ -> W.Anyref) f.Emo_ir.fparams;
  env.local_map <- List.mapi (fun i (n, _) -> (n, i)) f.Emo_ir.fparams;
  env.binders <- [];
  env.fname <- f.Emo_ir.fname;
  env.fparams <- List.map fst f.Emo_ir.fparams;
  (* A class member's mangled name opens with the class's cname; field
     reads inside fall back to it. *)
  let owner =
    match
      List.find_opt
        (fun c ->
          String.starts_with ~prefix:(c.Emo_ir.cname ^ "__") f.Emo_ir.fname)
        env.classes
    with
    | Some c -> Some c.Emo_ir.cname
    | None -> None
  in
  env.current_class <- owner;
  let body = stmts_value env f.Emo_ir.fbody ~tail:true in
  let param_types = List.map (fun _ -> W.Anyref) f.Emo_ir.fparams in
  (* local_decls opens with one entry per parameter; only the rest are
     declared locals *)
  let nparams = List.length f.Emo_ir.fparams in
  let scratches = List.filteri (fun i _ -> i >= nparams) env.local_decls in
  {
    W.ftype_idx = type_idx env (W.FuncT (param_types, [ W.Anyref ]));
    fparams = List.map fst f.Emo_ir.fparams;
    flocals = List.map (fun t -> (1, t)) scratches;
    fbody = body;
  }

(* ---- Classes ----

   One struct type per class: fields anyref and mutable, in
   init-assignment order (the IR's only field order). Methods are
   program functions whose first parameter is self; the constructor
   factory null-fills the struct and runs init with self bound. *)

let class_fields (c : Emo_ir.class_) : string list =
  match c.Emo_ir.cinit with
  | None -> []
  | Some init ->
      List.filter_map
        (fun (s : Emo_ir.stmt) ->
          match s with Emo_ir.Set_field { name; _ } -> Some name | _ -> None)
        init.Emo_ir.fbody

(* The dummy-field count that makes a class's struct shape unique:
   WasmGC canonicalizes identically-shaped struct types into one, so
   layout-equal classes would share an RTT and ref.test could not tell
   them apart. The ordinal is encoded in a base wide enough that
   (ordinal, real-field-count) pairs cannot collide; dummies sit after
   the real fields, so field indices are untouched. *)
let class_pad (max_fields : int) (ordinal : int) (c : Emo_ir.class_) : int =
  (ordinal * (max_fields + 1)) + List.length (class_fields c)

let emit_class_decls env (c : Emo_ir.class_) ~(pad : int) : unit =
  let fields = class_fields c in
  (* Distinct shape per class: the real fields, then [pad] dummies. *)
  let tidx = env.ntypes in
  env.types <-
    W.StructT
      (List.map (fun _ -> (W.Anyref, true)) fields
      @ List.map (fun _ -> (W.Anyref, true)) (List.init pad Fun.id))
    :: env.types;
  env.ntypes <- tidx + 1;
  env.class_type <- (c.Emo_ir.cname, tidx) :: env.class_type;
  env.class_field <-
    (c.Emo_ir.cname, List.mapi (fun i n -> (n, i)) fields) :: env.class_field

let emit_ctor_factory env (c : Emo_ir.class_) ~(pad : int) : W.func_type =
  let fields = class_fields c in
  let tidx = List.assoc c.Emo_ir.cname env.class_type in
  let params =
    match c.Emo_ir.cinit with
    | Some init -> (
        match init.Emo_ir.fparams with _ :: rest -> rest | [] -> [])
    | None -> []
  in
  env.rev <- [];
  env.local_decls <- List.map (fun _ -> W.Anyref) params;
  env.local_map <- List.mapi (fun i (n, _) -> (n, i)) params;
  env.binders <- [];
  env.fname <- c.Emo_ir.cname ^ "__new";
  env.fparams <- List.map fst params;
  env.current_class <- Some c.Emo_ir.cname;
  let self_local = fresh_local env "self" W.Anyref in
  let body =
    List.concat_map
      (fun _ -> [ W.Ref_null_any ])
      (List.init (pad + List.length fields) Fun.id)
    @ [ W.Struct_new tidx; W.Local_set self_local ]
    @ (match c.Emo_ir.cinit with
      | Some init -> stmts env init.Emo_ir.fbody ~tail:false
      | None -> [])
    @ [ W.Local_get self_local ]
  in
  {
    W.ftype_idx =
      type_idx env (W.FuncT (List.map (fun _ -> W.Anyref) params, [ W.Anyref ]));
    fparams = List.map fst params;
    flocals =
      List.map
        (fun t -> (1, t))
        (List.filteri (fun i _ -> i >= List.length params) env.local_decls);
    fbody = body;
  }

(* ---- Runtime function bodies ----

   to_str dispatches on the value's runtime type; each primitive shape
   renders into linear memory or fixed bytes, then boxes. Instances
   reach their __str through method_call before to_str runs, so the
   fallthrough aborts with a host-side message. *)

let rt_to_str : W.func_type =
  (* One If_else per shape: test -> produce a $vstring, else continue.
     The chain is built inside-out: the innermost else is the
     instance fallthrough. *)
  let branch test produce cont =
    W.If_else (W.Result W.Anyref, test, produce, cont)
  in
  let test_of t = [ W.Local_get 0; W.Ref_test t ] in
  let innermost = [ W.Local_get 0; W.Call (rt "instance_str") ] in
  let char_branch =
    branch (test_of t_vchar)
      [
        W.Local_get 0;
        W.Ref_cast t_vchar;
        W.Struct_get (t_vchar, 0);
        W.Call (rt "char_str");
        W.Struct_new t_vstring;
      ]
      innermost
  in
  let bool_branch =
    branch (test_of t_vbool)
      [
        W.Local_get 0;
        W.Ref_cast t_vbool;
        W.Struct_get (t_vbool, 0);
        W.Call (rt "bool_str");
        W.Struct_new t_vstring;
      ]
      [ char_branch ]
  in
  let float_branch =
    branch (test_of t_vfloat)
      [
        W.Local_get 0;
        W.Ref_cast t_vfloat;
        W.Struct_get (t_vfloat, 0);
        W.Call i_float_str;
        W.Call (rt "bytes_from_mem");
        W.Struct_new t_vstring;
      ]
      [ bool_branch ]
  in
  let int_branch =
    branch (test_of t_vint)
      [
        W.Local_get 0;
        W.Ref_cast t_vint;
        W.Struct_get (t_vint, 0);
        W.Call (rt "int_str");
        W.Struct_new t_vstring;
      ]
      [ float_branch ]
  in
  let string_branch =
    branch (test_of t_vstring)
      [
        W.Local_get 0;
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Struct_new t_vstring;
      ]
      [ int_branch ]
  in
  {
    W.ftype_idx = t_sig1;
    fparams = [ "v" ];
    flocals = [];
    fbody = [ string_branch ];
  }

(* int_str(n i64) -> (ref null $bytes): digits LSB-first into the
   scratch area at 60000, then reversed. Locals: 1 array, 2 len, 3
   neg, 4 digit/i.

   The digits come off with the unsigned operators: INT64_MIN negated
   is still INT64_MIN as a bit pattern, which as an unsigned value is
   exactly its magnitude 2^63, so the signed forms would divide by a
   negative and only yield one digit. *)
let rt_int_str : W.func_type =
  let scratch = 60000 in
  {
    W.ftype_idx = t_int_str;
    fparams = [ "v" ];
    flocals = [ (1, W.RefNull t_bytes); (1, W.I32); (1, W.I32); (1, W.I32) ];
    fbody =
      [
        W.Local_get 0;
        W.I64_const 0L;
        W.I64_lt_s;
        W.Local_set 3;
        W.Local_get 3;
        W.If
          ( W.Void,
            [ W.I64_const 0L; W.Local_get 0; W.I64_sub; W.Local_set 0 ],
            [] );
        W.I32_const 0;
        W.Local_set 2;
        W.Block
          ( W.Void,
            [
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 0;
                    W.I64_const 10L;
                    W.I64_rem_u;
                    W.I32_wrap_i64;
                    W.I32_const 48;
                    W.I32_add;
                    W.Local_set 4;
                    W.I32_const scratch;
                    W.Local_get 2;
                    W.I32_add;
                    W.Local_get 4;
                    W.I32_store8;
                    W.Local_get 0;
                    W.I64_const 10L;
                    W.I64_div_u;
                    W.Local_set 0;
                    W.Local_get 2;
                    W.I32_const 1;
                    W.I32_add;
                    W.Local_set 2;
                    W.Local_get 0;
                    W.I64_eqz;
                    W.Br_if 1;
                    W.Br 0;
                  ] );
            ] );
        W.Local_get 2;
        W.Local_get 3;
        W.I32_add;
        W.Array_new_default t_bytes;
        W.Local_set 1;
        W.Local_get 3;
        W.If
          ( W.Void,
            [
              W.Local_get 1; W.I32_const 0; W.I32_const 45; W.Array_set t_bytes;
            ],
            [] );
        W.I32_const 0;
        W.Local_set 4;
        W.Block
          ( W.Void,
            [
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 4;
                    W.Local_get 2;
                    W.I32_ge;
                    W.Br_if 1;
                    W.Local_get 1;
                    W.Local_get 4;
                    W.Local_get 3;
                    W.I32_add;
                    W.I32_const scratch;
                    W.Local_get 2;
                    W.I32_const 1;
                    W.I32_sub;
                    W.Local_get 4;
                    W.I32_sub;
                    W.I32_add;
                    W.I32_load8_u;
                    W.Array_set t_bytes;
                    W.Local_get 4;
                    W.I32_const 1;
                    W.I32_add;
                    W.Local_set 4;
                    W.Br 0;
                  ] );
            ] );
        W.Local_get 1;
      ];
  }

(* bool_str(b i32) -> (ref null $bytes). *)
let rt_bool_str : W.func_type =
  {
    W.ftype_idx = t_bool_str;
    fparams = [ "v" ];
    flocals = [];
    fbody =
      [
        W.If_else
          ( W.Result (W.RefNull t_bytes),
            [ W.Local_get 0 ],
            [
              W.I32_const 116;
              W.I32_const 114;
              W.I32_const 117;
              W.I32_const 101;
              W.Array_new_fixed (t_bytes, 4);
            ],
            [
              W.I32_const 102;
              W.I32_const 97;
              W.I32_const 108;
              W.I32_const 115;
              W.I32_const 101;
              W.Array_new_fixed (t_bytes, 5);
            ] );
      ];
  }

(* char_str(c i32) -> (ref null $bytes): one byte. *)
let rt_char_str : W.func_type =
  {
    W.ftype_idx = t_char_str;
    fparams = [ "v" ];
    flocals = [];
    fbody = [ W.Local_get 0; W.Array_new_fixed (t_bytes, 1) ];
  }

(* instance_str(v) -> aborts: instances reach their __str through
   method_call; an unhandled shape here is a host-visible trap. *)
let rt_instance_str : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "v" ];
    flocals = [];
    fbody =
      [
        (* scratch marker "inst" at 61000 *)
        W.I32_const 61000;
        W.I32_const 105;
        W.I32_store8;
        W.I32_const 61001;
        W.I32_const 110;
        W.I32_store8;
        W.I32_const 61002;
        W.I32_const 115;
        W.I32_store8;
        W.I32_const 61003;
        W.I32_const 116;
        W.I32_store8;
        W.I32_const 61000;
        W.I32_const 4;
        W.Call i_abort;
        W.Unreachable;
      ];
  }

(* bytes_from_mem(ptr, len) -> (ref null $bytes). Locals: 2 array, 3
   i. *)
let rt_bytes_from_mem : W.func_type =
  {
    W.ftype_idx = t_bytes_from_mem;
    fparams = [ "ptr"; "len" ];
    flocals = [ (1, W.RefNull t_bytes); (2, W.I32) ];
    fbody =
      [
        W.Block
          ( W.Void,
            [
              W.Local_get 1;
              W.Array_new_default t_bytes;
              W.Local_set 2;
              W.I32_const 0;
              W.Local_set 3;
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 3;
                    W.Local_get 1;
                    W.I32_ge;
                    W.Br_if 1;
                    (* the byte lands in local 4 first: array.set reads
                       its three operands from the stack, so the value
                       cannot be computed between index and array *)
                    W.Local_get 0;
                    W.Local_get 3;
                    W.I32_add;
                    W.I32_load8_u;
                    W.Local_set 4;
                    W.Local_get 2;
                    W.Local_get 3;
                    W.Local_get 4;
                    W.Array_set t_bytes;
                    W.Local_get 3;
                    W.I32_const 1;
                    W.I32_add;
                    W.Local_set 3;
                    W.Br 0;
                  ] );
            ] );
        W.Local_get 2;
      ];
  }

(* write_bytes(b) -> i32 ptr: bump-allocate and copy. Locals: 1 ptr,
   2 len, 3 i. *)
let rt_write_bytes : W.func_type =
  {
    W.ftype_idx = t_write_bytes;
    fparams = [ "b" ];
    flocals = [ (3, W.I32) ];
    (* 1 = ptr, 2 = len, 3 = i *)
    fbody =
      [
        W.Block
          ( W.Void,
            [
              W.Global_get 0;
              W.Local_set 1;
              W.Local_get 0;
              W.Array_len t_bytes;
              W.Local_set 2;
              W.Global_get 0;
              W.Local_get 2;
              W.I32_add;
              W.Memory_size;
              W.I32_const 16;
              W.I32_mul;
              W.I32_gt;
              W.If
                ( W.Void,
                  [
                    W.Global_get 0;
                    W.Local_get 2;
                    W.I32_add;
                    W.I32_const 15;
                    W.I32_add;
                    W.I32_const 16;
                    W.I32_div_s;
                    W.Memory_grow;
                    W.Drop;
                  ],
                  [] );
              W.I32_const 0;
              W.Local_set 3;
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 3;
                    W.Local_get 2;
                    W.I32_ge;
                    W.Br_if 1;
                    W.Local_get 1;
                    W.Local_get 3;
                    W.I32_add;
                    W.Local_get 0;
                    W.Local_get 3;
                    W.Array_get_u t_bytes;
                    W.I32_store8;
                    W.Local_get 3;
                    W.I32_const 1;
                    W.I32_add;
                    W.Local_set 3;
                    W.Br 0;
                  ] );
              W.Global_get 0;
              W.Local_get 2;
              W.I32_add;
              W.Global_set 0;
            ] );
        W.Local_get 1;
      ];
  }

(* println(v): render, bump-write, call the host. Local: 1 bytes. *)
let rt_println : W.func_type =
  {
    W.ftype_idx = t_println_v;
    fparams = [ "v" ];
    flocals = [ (1, W.RefNull t_bytes) ];
    fbody =
      [
        W.Local_get 0;
        W.Call (rt "to_str");
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Local_set 1;
        W.Local_get 1;
        W.Call (rt "write_bytes");
        W.Local_get 1;
        W.Array_len t_bytes;
        W.Call i_print;
      ];
  }

(* str_eq(a, b) -> i32 (through sig2): byte-wise compare. Locals: 2
   i, 3 la, 4 lb. *)
let rt_str_eq : W.func_type =
  {
    W.ftype_idx = t_str_eq;
    fparams = [ "a"; "b" ];
    flocals = [ (3, W.I32) ];
    fbody =
      [
        W.Block
          ( W.Result W.I32,
            [
              W.Block
                ( W.Void,
                  [
                    (* length mismatch: leave with 0 *)
                    W.Local_get 0;
                    W.Array_len t_bytes;
                    W.Local_set 3;
                    W.Local_get 1;
                    W.Array_len t_bytes;
                    W.Local_set 4;
                    W.Local_get 3;
                    W.Local_get 4;
                    W.I32_ne;
                    W.Br_if 0;
                    (* byte loop *)
                    W.I32_const 0;
                    W.Local_set 2;
                    W.Loop
                      ( W.Void,
                        [
                          (* exhausted: leave the outer block with 1 *)
                          W.I32_const 1;
                          W.Local_get 2;
                          W.Local_get 3;
                          W.I32_ge;
                          W.Br_if 2;
                          W.Local_get 0;
                          W.Local_get 2;
                          W.Array_get_u t_bytes;
                          W.Local_get 1;
                          W.Local_get 2;
                          W.Array_get_u t_bytes;
                          W.I32_ne;
                          W.Br_if 1;
                          W.Local_get 2;
                          W.I32_const 1;
                          W.I32_add;
                          W.Local_set 2;
                          W.Br 0;
                        ] );
                  ] );
              W.I32_const 0;
            ] );
      ];
  }

(* init: build every interned string into its global. *)
(* init: build every interned string into its global, then create the
   entry process (id 0) on an empty list. *)
(* The concurrency driver's globals — all indices depend on the string
   pool, so the rt builders take them. *)
type driver_globals = {
  g_cur : int;
  g_curp : int;
  g_next : int;
  g_head : int;
  g_tail : int;
  g_saved : int;
}

let rt_init (pool : string list) ~(g : driver_globals) : W.func_type =
  {
    W.ftype_idx = t_main;
    fparams = [];
    flocals = [ (1, W.RefNull t_proc); (1, W.RefNull t_cons); (1, W.I32) ];
    fbody =
      List.concat_map
        (fun s -> string_bytes_instrs s @ [ W.Struct_new t_vstring ])
        pool
      @ List.mapi
          (fun i _ -> W.Global_set (1 + (List.length pool - 1 - i)))
          pool
      @ [
          W.I32_const 0;
          W.I32_const 1;
          W.I32_const 0;
          W.Ref_null_any;
          W.Ref_null_any;
          W.Ref_null_any;
          W.Ref_null_any;
          W.Struct_new t_proc;
          W.Local_set 0;
          W.Local_get 0;
          W.Ref_null_any;
          W.Struct_new t_cons;
          W.Local_set 1;
          W.Local_get 1;
          W.Global_set g.g_head;
          W.Local_get 1;
          W.Global_set g.g_tail;
          W.Local_get 0;
          W.Global_set g.g_curp;
          W.I32_const 1;
          W.Global_set g.g_next;
        ];
  }

(* ---- Numeric and comparison runtime (sig1: anyref -> anyref where a
   value is produced, sig2 where a bool) ---- *)

(* Unwrap a numeric (int or float) to f64. *)
(* both operands are $vint? *)
let both_int (a : int) (b : int) : W.instr list =
  [
    W.Local_get a;
    W.Ref_test t_vint;
    W.Local_get b;
    W.Ref_test t_vint;
    W.I32_and;
  ]

let i64_of (l : int) : W.instr list =
  [ W.Local_get l; W.Ref_cast t_vint; W.Struct_get (t_vint, 0) ]

let both_string (a : int) (b : int) : W.instr list =
  [
    W.Local_get a;
    W.Ref_test t_vstring;
    W.Local_get b;
    W.Ref_test t_vstring;
    W.I32_and;
  ]

let bytes_of (l : int) : W.instr list =
  [ W.Local_get l; W.Ref_cast t_vstring; W.Struct_get (t_vstring, 0) ]

let num_to_f64 (local : int) : W.instr list =
  [
    W.If_else
      ( W.Result W.F64,
        [ W.Local_get local; W.Ref_test t_vfloat ],
        [ W.Local_get local; W.Ref_cast t_vfloat; W.Struct_get (t_vfloat, 0) ],
        [
          W.Local_get local;
          W.Ref_cast t_vint;
          W.Struct_get (t_vint, 0);
          W.F64_convert_i64_s;
        ] );
  ]

(* arithmetic: int path via i64 op, float path via f64 op *)
let rt_arith (int_body : W.instr list) (float_body : W.instr list) : W.func_type
    =
  {
    W.ftype_idx = t_numop;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [
        W.If_else
          ( W.Result W.Anyref,
            both_int 0 1,
            i64_of 0 @ i64_of 1 @ int_body,
            num_to_f64 0 @ num_to_f64 1 @ float_body );
      ];
  }

(* add: int + int, string + string (concat), otherwise numeric float *)
let rt_add =
  {
    W.ftype_idx = t_numop;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [
        W.If_else
          ( W.Result W.Anyref,
            both_int 0 1,
            i64_of 0 @ i64_of 1 @ [ W.I64_add; W.Struct_new t_vint ],
            [
              W.If_else
                ( W.Result W.Anyref,
                  both_string 0 1,
                  bytes_of 0 @ bytes_of 1
                  @ [ W.Call (rt "strcat"); W.Struct_new t_vstring ],
                  num_to_f64 0 @ num_to_f64 1
                  @ [ W.F64_add; W.Struct_new t_vfloat ] );
            ] );
      ];
  }

let rt_sub =
  rt_arith
    [ W.I64_sub; W.Struct_new t_vint ]
    [ W.F64_sub; W.Struct_new t_vfloat ]

let rt_mul =
  rt_arith
    [ W.I64_mul; W.Struct_new t_vint ]
    [ W.F64_mul; W.Struct_new t_vfloat ]

(* div/mod: int division truncates *)
let rt_div =
  rt_arith
    [ W.I64_div_s; W.Struct_new t_vint ]
    [ W.F64_div; W.Struct_new t_vfloat ]

let rt_mod =
  rt_arith
    [ W.I64_rem_s; W.Struct_new t_vint ]
    [ W.F64_rem_s; W.Struct_new t_vfloat ]

(* neg *)
let rt_neg : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "a" ];
    flocals = [];
    fbody =
      [
        W.If_else
          ( W.Result W.Anyref,
            [ W.Local_get 0; W.Ref_test t_vint ],
            [ W.I64_const 0L ] @ i64_of 0 @ [ W.I64_sub; W.Struct_new t_vint ],
            num_to_f64 0 @ [ W.F64_neg; W.Struct_new t_vfloat ] );
      ];
  }

(* Bitwise ops are integer-only: the checker guarantees Int, and any
   other shape traps rather than silently coercing. *)
let rt_bit (op : W.instr) : W.func_type =
  {
    W.ftype_idx = t_numop;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [
        W.If_else
          ( W.Result W.Anyref,
            both_int 0 1,
            i64_of 0 @ i64_of 1 @ [ op; W.Struct_new t_vint ],
            [ W.Unreachable ] );
      ];
  }

let rt_bit_and = rt_bit W.I64_and
let rt_bit_or = rt_bit W.I64_or
let rt_bit_xor = rt_bit W.I64_xor
let rt_shl = rt_bit W.I64_shl
let rt_shr = rt_bit W.I64_shr_s

let rt_bnot : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "a" ];
    flocals = [];
    fbody =
      [
        W.If_else
          ( W.Result W.Anyref,
            [ W.Local_get 0; W.Ref_test t_vint ],
            [ W.I64_const (-1L) ] @ i64_of 0
            @ [ W.I64_xor; W.Struct_new t_vint ],
            [ W.Unreachable ] );
      ];
  }

(* ---- Bytes: a fixed-length mutable byte buffer ($vbytes) ---- *)

let bytes_of_vbytes (l : int) : W.instr list =
  [ W.Local_get l; W.Ref_cast t_vbytes; W.Struct_get (t_vbytes, 0) ]

let rt_bytes_new : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "len" ];
    flocals = [ (1, W.I32) ];
    fbody =
      [
        W.Local_get 0;
        W.Ref_cast t_vint;
        W.Struct_get (t_vint, 0);
        W.I32_wrap_i64;
        W.Local_set 1;
        W.If_else
          ( W.Result W.Anyref,
            [ W.Local_get 1; W.I32_const 0; W.I32_ge ],
            [
              W.Local_get 1; W.Array_new_default t_bytes; W.Struct_new t_vbytes;
            ],
            [ W.Unreachable ] );
      ];
  }

let rt_bytes_get : W.func_type =
  {
    W.ftype_idx = t_numop;
    fparams = [ "b"; "i" ];
    flocals = [ (1, W.I32); (1, W.I32) ];
    fbody =
      [
        W.Block
          ( W.Void,
            bytes_of_vbytes 0
            @ [ W.Array_len t_bytes; W.Local_set 2 ]
            @ i64_of 1
            @ [
                W.I32_wrap_i64;
                W.Local_set 3;
                W.Local_get 3;
                W.I32_const 0;
                W.I32_lt_s;
                W.Local_get 3;
                W.Local_get 2;
                W.I32_ge;
                W.I32_or;
                W.Br_if 0;
              ]
            @ bytes_of_vbytes 0
            @ [
                W.Local_get 3;
                W.Array_get_u t_bytes;
                W.I64_extend_i32_u;
                W.Struct_new t_vint;
                W.Return;
              ] );
        W.Unreachable;
      ];
  }

let rt_bytes_set : W.func_type =
  {
    W.ftype_idx = t_bytes_set;
    fparams = [ "b"; "i"; "v" ];
    flocals = [ (1, W.I32); (1, W.I32) ];
    fbody =
      [
        W.Block
          ( W.Void,
            bytes_of_vbytes 0
            @ [ W.Array_len t_bytes; W.Local_set 3 ]
            @ i64_of 1
            @ [
                W.I32_wrap_i64;
                W.Local_set 4;
                W.Local_get 4;
                W.I32_const 0;
                W.I32_lt_s;
                W.Local_get 4;
                W.Local_get 3;
                W.I32_ge;
                W.I32_or;
                W.Br_if 0;
              ]
            @ i64_of 2
            @ [ W.I64_const 0L; W.I64_lt_s; W.Br_if 0 ]
            @ i64_of 2
            @ [ W.I64_const 255L; W.I64_gt_s; W.Br_if 0 ]
            @ bytes_of_vbytes 0 @ [ W.Local_get 4 ] @ i64_of 2
            @ [ W.I32_wrap_i64; W.Array_set t_bytes; W.Local_get 2; W.Return ]
          );
        W.Unreachable;
      ];
  }

(* the little-endian multi-byte accessors share one body shape *)
let rt_bytes_le_get (width : int) : W.func_type =
  {
    W.ftype_idx = t_numop;
    fparams = [ "b"; "i" ];
    flocals = [ (3, W.I32); (1, W.I64) ];
    fbody =
      [
        W.Block
          ( W.Void,
            bytes_of_vbytes 0
            @ [ W.Array_len t_bytes; W.Local_set 2 ]
            @ i64_of 1
            @ [
                W.I32_wrap_i64;
                W.Local_set 3;
                W.Local_get 3;
                W.I32_const 0;
                W.I32_lt_s;
                W.Local_get 3;
                W.I32_const width;
                W.I32_add;
                W.Local_get 2;
                W.I32_gt;
                W.I32_or;
                W.Br_if 0;
                W.I64_const 0L;
                W.Local_set 5;
                W.I32_const 0;
                W.Local_set 4;
              ]
            @ [
                W.Loop
                  ( W.Void,
                    [ W.Local_get 5 ] @ bytes_of_vbytes 0
                    @ [
                        W.Local_get 3;
                        W.Local_get 4;
                        W.I32_add;
                        W.Array_get_u t_bytes;
                        W.I64_extend_i32_u;
                        W.Local_get 4;
                        W.I32_const 8;
                        W.I32_mul;
                        W.I64_extend_i32_s;
                        W.I64_shl;
                        W.I64_or;
                        W.Local_set 5;
                        W.Local_get 4;
                        W.I32_const 1;
                        W.I32_add;
                        W.Local_tee 4;
                        W.I32_const width;
                        W.I32_lt_s;
                        W.Br_if 0;
                      ] );
              ]
            @ [ W.Local_get 5; W.Struct_new t_vint; W.Return ] );
        W.Unreachable;
      ];
  }

let rt_bytes_le_set (width : int) : W.func_type =
  {
    W.ftype_idx = t_bytes_set;
    fparams = [ "b"; "i"; "v" ];
    flocals = [ (3, W.I32) ];
    fbody =
      [
        W.Block
          ( W.Void,
            bytes_of_vbytes 0
            @ [ W.Array_len t_bytes; W.Local_set 3 ]
            @ i64_of 1
            @ [
                W.I32_wrap_i64;
                W.Local_set 4;
                W.Local_get 4;
                W.I32_const 0;
                W.I32_lt_s;
                W.Local_get 4;
                W.I32_const width;
                W.I32_add;
                W.Local_get 3;
                W.I32_gt;
                W.I32_or;
                W.Br_if 0;
                W.I32_const 0;
                W.Local_set 5;
              ]
            @ [
                W.Loop
                  ( W.Void,
                    bytes_of_vbytes 0
                    @ [ W.Local_get 4; W.Local_get 5; W.I32_add ]
                    @ i64_of 2
                    @ [
                        W.Local_get 5;
                        W.I32_const 8;
                        W.I32_mul;
                        W.I64_extend_i32_s;
                        W.I64_shr_u;
                        W.I64_const 255L;
                        W.I64_and;
                        W.I32_wrap_i64;
                        W.Array_set t_bytes;
                        W.Local_get 5;
                        W.I32_const 1;
                        W.I32_add;
                        W.Local_tee 5;
                        W.I32_const width;
                        W.I32_lt_s;
                        W.Br_if 0;
                      ] );
              ]
            @ i64_of 2
            @ [ W.Struct_new t_vint; W.Return ] );
        W.Unreachable;
      ];
  }

(* $vstring -> $vbytes: the copy keeps the two surfaces independent —
   mutating the bytes must never be observable through the string. *)
let rt_bytes_from_str : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "s" ];
    flocals = [ (1, W.RefNull t_bytes); (1, W.RefNull t_bytes); (1, W.I32) ];
    fbody =
      [
        W.Local_get 0;
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Array_len t_bytes;
        W.Local_tee 3;
        W.Array_new_default t_bytes;
        W.Local_set 1;
        W.Local_get 0;
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Local_set 2;
        W.I32_const 0;
        W.Local_set 3;
        W.Loop
          ( W.Void,
            [
              W.Local_get 1;
              W.Local_get 3;
              W.Local_get 2;
              W.Local_get 3;
              W.Array_get_u t_bytes;
              W.Array_set t_bytes;
              W.Local_get 3;
              W.I32_const 1;
              W.I32_add;
              W.Local_tee 3;
              W.Local_get 1;
              W.Array_len t_bytes;
              W.I32_lt_s;
              W.Br_if 0;
            ] );
        W.Local_get 1;
        W.Struct_new t_vbytes;
      ];
  }

(* $vbytes -> $vstring: same copy discipline, the other direction. *)
let rt_bytes_to_str : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "b" ];
    flocals = [ (1, W.RefNull t_bytes); (1, W.RefNull t_bytes); (1, W.I32) ];
    fbody =
      bytes_of_vbytes 0
      @ [
          W.Array_len t_bytes;
          W.Local_tee 3;
          W.Array_new_default t_bytes;
          W.Local_set 1;
        ]
      @ bytes_of_vbytes 0
      @ [ W.Local_set 2; W.I32_const 0; W.Local_set 3 ]
      @ [
          W.Loop
            ( W.Void,
              [
                W.Local_get 1;
                W.Local_get 3;
                W.Local_get 2;
                W.Local_get 3;
                W.Array_get_u t_bytes;
                W.Array_set t_bytes;
                W.Local_get 3;
                W.I32_const 1;
                W.I32_add;
                W.Local_tee 3;
                W.Local_get 1;
                W.Array_len t_bytes;
                W.I32_lt_s;
                W.Br_if 0;
              ] );
        ]
      @ [ W.Local_get 1; W.Struct_new t_vstring ];
  }

(* $vbytes -> $vstring spelling "Bytes[N]": "Bytes[" lives at scratch
   60000, the digits of N from 60006 on, the bracket after them. *)
let rt_bytes_label : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "b" ];
    flocals = [];
    fbody =
      (* "Bytes[" *)
      [
        W.I32_const 66;
        W.I32_const 121;
        W.I32_const 116;
        W.I32_const 101;
        W.I32_const 115;
        W.I32_const 91;
        W.Array_new_fixed (t_bytes, 6);
      ]
      (* the length, rendered by int_str *)
      @ bytes_of_vbytes 0
      @ [
          W.Array_len t_bytes;
          W.I64_extend_i32_s;
          W.Call (rt "int_str");
          W.Call (rt "strcat");
        ]
      (* "]" *)
      @ [ W.I32_const 93; W.Array_new_fixed (t_bytes, 1); W.Call (rt "strcat") ]
      @ [ W.Struct_new t_vstring ];
  }

let rt_cmp (int_body : W.instr list) (float_body : W.instr list) : W.func_type =
  {
    W.ftype_idx = t_numop;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [
        W.If_else
          ( W.Result W.Anyref,
            both_int 0 1,
            i64_of 0 @ i64_of 1 @ int_body,
            num_to_f64 0 @ num_to_f64 1 @ float_body );
      ];
  }

let rt_lt =
  rt_cmp [ W.I64_lt_s; W.Struct_new t_vbool ] [ W.F64_lt; W.Struct_new t_vbool ]

let rt_le =
  rt_cmp [ W.I64_le_s; W.Struct_new t_vbool ] [ W.F64_le; W.Struct_new t_vbool ]

let rt_gt =
  rt_cmp [ W.I64_gt_s; W.Struct_new t_vbool ] [ W.F64_gt; W.Struct_new t_vbool ]

let rt_ge =
  rt_cmp [ W.I64_ge_s; W.Struct_new t_vbool ] [ W.F64_ge; W.Struct_new t_vbool ]

(* eq: primitives by content via deep_eq, boxed $vbool *)
(* Equality over the program's shapes, built per module: primitives
   and strings by value, enums by both interned names, instances
   field-wise per class (each arm reads its operands from locals —
   the if's arms cannot see the caller's stack). eq and ne box the
   i32; deep_eq returns it raw and recurses through its fixed index. *)
let rt_equality_funcs (env : env) : W.func_type * W.func_type * W.func_type =
  let rec fold_and = function
    | [] -> [ W.I32_const 1 ]
    | [ x ] -> x
    | x :: rest -> x @ fold_and rest @ [ W.I32_and ]
  in
  let both t a b =
    [ W.Local_get a; W.Ref_test t; W.Local_get b; W.Ref_test t; W.I32_and ]
  in
  let prim t =
    [
      W.Local_get 0;
      W.Ref_cast t;
      W.Struct_get (t, 0);
      W.Local_get 1;
      W.Ref_cast t;
      W.Struct_get (t, 0);
    ]
  in
  (* an enum field is a $vstring: unwrap it to bytes *)
  let enum_bytes (local : int) (field : int) : W.instr list =
    [
      W.Local_get local;
      W.Ref_cast t_venum;
      W.Struct_get (t_venum, field);
      W.Ref_cast t_vstring;
      W.Struct_get (t_vstring, 0);
    ]
  in
  let class_arms =
    List.filter_map
      (fun (cname, tidx) ->
        match List.assoc_opt cname env.class_field with
        | Some fields ->
            let produce =
              fold_and
                (List.map
                   (fun (_, fidx) ->
                     [
                       W.Local_get 0;
                       W.Ref_cast tidx;
                       W.Struct_get (tidx, fidx);
                       W.Local_get 1;
                       W.Ref_cast tidx;
                       W.Struct_get (tidx, fidx);
                       W.Call (rt "deep_eq");
                     ])
                   fields)
            in
            Some (both tidx 0 1, produce)
        | None -> None)
      env.class_type
  in
  let array_arm =
    (* lengths equal, then element-wise deep_eq; the differ exit lands
       past the inner block, the equal exit carries 1 to the outer *)
    [
      W.Block
        ( W.Result W.I32,
          [
            W.Block
              ( W.Void,
                [
                  W.Local_get 0;
                  W.Ref_cast t_anyarray;
                  W.Array_len t_anyarray;
                  W.Local_set 2;
                  W.Local_get 1;
                  W.Ref_cast t_anyarray;
                  W.Array_len t_anyarray;
                  W.Local_get 2;
                  W.I32_ne;
                  W.Br_if 0;
                  W.I32_const 0;
                  W.Local_set 3;
                  W.Loop
                    ( W.Void,
                      [
                        W.I32_const 1;
                        W.Local_get 3;
                        W.Local_get 2;
                        W.I32_ge;
                        W.Br_if 2;
                        W.Local_get 0;
                        W.Ref_cast t_anyarray;
                        W.Local_get 3;
                        W.Array_get t_anyarray;
                        W.Local_get 1;
                        W.Ref_cast t_anyarray;
                        W.Local_get 3;
                        W.Array_get t_anyarray;
                        W.Call (rt "deep_eq");
                        W.I32_eqz;
                        W.Br_if 1;
                        W.Local_get 3;
                        W.I32_const 1;
                        W.I32_add;
                        W.Local_set 3;
                        W.Br 0;
                      ] );
                ] );
            W.I32_const 0;
          ] );
    ]
  in
  let bytes_arm =
    (* both receivers are $vbytes: lengths equal, then every i8 pair *)
    [
      W.Block
        ( W.Result W.I32,
          [
            W.Block
              ( W.Void,
                bytes_of_vbytes 0
                @ [ W.Array_len t_bytes; W.Local_set 2 ]
                @ bytes_of_vbytes 1
                @ [
                    W.Array_len t_bytes;
                    W.Local_get 2;
                    W.I32_ne;
                    W.Br_if 0;
                    W.I32_const 0;
                    W.Local_set 3;
                    W.Loop
                      ( W.Void,
                        [
                          W.I32_const 1;
                          W.Local_get 3;
                          W.Local_get 2;
                          W.I32_ge;
                          W.Br_if 2;
                        ]
                        @ bytes_of_vbytes 0
                        @ [ W.Local_get 3; W.Array_get_u t_bytes ]
                        @ bytes_of_vbytes 1
                        @ [
                            W.Local_get 3;
                            W.Array_get_u t_bytes;
                            W.I32_ne;
                            W.Br_if 1;
                            W.Local_get 3;
                            W.I32_const 1;
                            W.I32_add;
                            W.Local_set 3;
                            W.Br 0;
                          ] );
                  ] );
            W.I32_const 0;
          ] );
    ]
  in
  let arms =
    [
      (both t_vint 0 1, i64_of 0 @ i64_of 1 @ [ W.I64_eq ]);
      (both t_vfloat 0 1, prim t_vfloat @ [ W.F64_eq ]);
      (both t_vbool 0 1, prim t_vbool @ [ W.I32_eq ]);
      (both t_vchar 0 1, prim t_vchar @ [ W.I32_eq ]);
      (both t_vstring 0 1, bytes_of 0 @ bytes_of 1 @ [ W.Call (rt "str_eq") ]);
      ( both t_venum 0 1,
        enum_bytes 0 0 @ enum_bytes 1 0
        @ [ W.Call (rt "str_eq") ]
        @ enum_bytes 0 1 @ enum_bytes 1 1
        @ [ W.Call (rt "str_eq"); W.I32_and ] );
      (both t_anyarray 0 1, array_arm);
      (both t_vbytes 0 1, bytes_arm);
    ]
    @ class_arms
  in
  let rec chain = function
    | [] -> [ W.I32_const 0 ]
    | (test, produce) :: rest ->
        [ W.If_else (W.Result W.I32, test, produce, chain rest) ]
  in
  let body = chain arms in
  ( {
      W.ftype_idx = t_numop;
      fparams = [ "a"; "b" ];
      flocals = [ (2, W.I32) ];
      fbody = body @ [ W.Struct_new t_vbool ];
    },
    {
      W.ftype_idx = t_numop;
      fparams = [ "a"; "b" ];
      flocals = [ (2, W.I32) ];
      fbody = body @ [ W.I32_eqz; W.Struct_new t_vbool ];
    },
    {
      W.ftype_idx = t_sig2;
      fparams = [ "a"; "b" ];
      flocals = [ (2, W.I32) ];
      fbody = body;
    } )

(* append(xs, v) -> a new array: every element copied, v at the end.
   Arrays are never mutated. Locals: 2 src, 3 elem, 4 fresh, 5 i. *)
let rt_append : W.func_type =
  {
    W.ftype_idx = t_numop;
    fparams = [ "xs"; "v" ];
    flocals =
      [
        (1, W.RefNull t_anyarray);
        (1, W.Anyref);
        (1, W.RefNull t_anyarray);
        (1, W.I32);
      ];
    fbody =
      [
        W.Local_get 0;
        W.Ref_cast t_anyarray;
        W.Local_set 2;
        W.Local_get 1;
        W.Local_set 3;
        W.Local_get 2;
        W.Array_len t_anyarray;
        W.I32_const 1;
        W.I32_add;
        W.Array_new_default t_anyarray;
        W.Local_set 4;
        W.I32_const 0;
        W.Local_set 5;
        W.Block
          ( W.Void,
            [
              W.Loop
                ( W.Void,
                  [
                    (* exhausted: the copy is done *)
                    W.Local_get 5;
                    W.Local_get 2;
                    W.Array_len t_anyarray;
                    W.I32_ge;
                    W.Br_if 1;
                    W.Local_get 4;
                    W.Local_get 5;
                    W.Local_get 2;
                    W.Local_get 5;
                    W.Array_get t_anyarray;
                    W.Array_set t_anyarray;
                    W.Local_get 5;
                    W.I32_const 1;
                    W.I32_add;
                    W.Local_set 5;
                    W.Br 0;
                  ] );
            ] );
        W.Local_get 4;
        W.Local_get 2;
        W.Array_len t_anyarray;
        W.Local_get 3;
        W.Array_set t_anyarray;
        W.Local_get 4;
      ];
  }

let rt_strcat : W.func_type =
  {
    W.ftype_idx = t_strcat;
    fparams = [ "a"; "b" ];
    flocals = [ (1, W.RefNull t_bytes); (2, W.I32); (3, W.I32) ];
    fbody =
      [
        W.Local_get 0;
        W.Array_len t_bytes;
        W.Local_get 1;
        W.Array_len t_bytes;
        W.I32_add;
        W.Array_new_default t_bytes;
        W.Local_set 2;
        W.I32_const 0;
        W.Local_set 3;
        W.Block
          ( W.Void,
            [
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 3;
                    W.Local_get 0;
                    W.Array_len t_bytes;
                    W.I32_ge;
                    W.Br_if 1;
                    W.Local_get 2;
                    W.Local_get 3;
                    W.Local_get 0;
                    W.Local_get 3;
                    W.Array_get_u t_bytes;
                    W.Array_set t_bytes;
                    W.Local_get 3;
                    W.I32_const 1;
                    W.I32_add;
                    W.Local_set 3;
                    W.Br 0;
                  ] );
            ] );
        W.Block
          ( W.Void,
            [
              W.I32_const 0;
              W.Local_set 3;
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 3;
                    W.Local_get 1;
                    W.Array_len t_bytes;
                    W.I32_ge;
                    W.Br_if 1;
                    W.Local_get 2;
                    W.Local_get 0;
                    W.Array_len t_bytes;
                    W.Local_get 3;
                    W.I32_add;
                    W.Local_get 1;
                    W.Local_get 3;
                    W.Array_get_u t_bytes;
                    W.Array_set t_bytes;
                    W.Local_get 3;
                    W.I32_const 1;
                    W.I32_add;
                    W.Local_set 3;
                    W.Br 0;
                  ] );
            ] );
        W.Local_get 2;
      ];
  }

(* box(v) -> (ref null $vbox). *)
let rt_box : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "v" ];
    flocals = [];
    fbody = [ W.Local_get 0; W.Struct_new t_vbox ];
  }

(* throw(msg): render the message into memory and abort through the
   host, which throws. *)
let rt_throw : W.func_type =
  {
    W.ftype_idx = t_sig1;
    fparams = [ "v" ];
    flocals = [ (1, W.RefNull t_bytes) ];
    fbody =
      [
        W.Local_get 0;
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Local_set 1;
        W.Local_get 1;
        W.Call (rt "write_bytes");
        W.Local_get 1;
        W.Array_len t_bytes;
        W.Call i_abort;
        W.Unreachable;
      ];
  }

(* ---- The concurrency driver ----

   Processes are $proc structs on a creation-ordered $cons list;
   mailboxes are $cons chains (head + tail for FIFO append). A spawn
   runs the child's first turn inline — it either ends or parks at a
   receive; parking records the receive's handler and the enclosing
   bindings, and the driver resumes by popping the mailbox and calling
   the handler. *)

let rt_spawn_begin (g : driver_globals) ~(t_pid : int) : W.func_type =
  {
    W.ftype_idx = t_pid;
    fparams = [];
    flocals = [ (1, W.I32); (1, W.RefNull t_proc); (1, W.RefNull t_cons) ];
    fbody =
      [
        W.Global_get g.g_next;
        W.Local_set 0;
        W.Local_get 0;
        W.I32_const 1;
        W.I32_const 0;
        W.Ref_null_any;
        W.Ref_null_any;
        W.Ref_null_any;
        W.Ref_null_any;
        W.Struct_new t_proc;
        W.Local_set 1;
        W.Local_get 1;
        W.Ref_null_any;
        W.Struct_new t_cons;
        W.Local_set 2;
        W.Global_get g.g_head;
        W.Ref_is_null;
        W.If
          ( W.Void,
            [
              W.Local_get 2;
              W.Global_set g.g_head;
              W.Local_get 2;
              W.Global_set g.g_tail;
            ],
            [
              W.Global_get g.g_tail;
              W.Local_get 2;
              W.Struct_set (t_cons, 1);
              W.Local_get 2;
              W.Global_set g.g_tail;
            ] );
        W.Global_get g.g_curp;
        W.Global_get g.g_saved;
        W.Struct_new t_cons;
        W.Global_set g.g_saved;
        W.Local_get 0;
        W.Global_set g.g_cur;
        W.Local_get 1;
        W.Global_set g.g_curp;
        W.Global_get g.g_next;
        W.I32_const 1;
        W.I32_add;
        W.Global_set g.g_next;
        W.Global_get g.g_curp;
        W.Struct_get (t_proc, 0);
        W.I64_extend_i32_s;
        W.Struct_new t_vint;
      ];
  }

let rt_spawn_end (g : driver_globals) : W.func_type =
  {
    W.ftype_idx = t_main;
    fparams = [];
    flocals = [ (1, W.RefNull t_cons) ];
    fbody =
      [
        W.Global_get g.g_saved;
        W.Ref_is_null;
        W.If
          ( W.Void,
            [],
            [
              W.Global_get g.g_saved;
              W.Ref_cast t_cons;
              W.Local_tee 0;
              W.Struct_get (t_cons, 1);
              W.Global_set g.g_saved;
              W.Local_get 0;
              W.Struct_get (t_cons, 0);
              W.Ref_cast t_proc;
              W.Global_set g.g_curp;
              W.Global_get g.g_curp;
              W.Struct_get (t_proc, 0);
              W.Global_set g.g_cur;
            ] );
      ];
  }

let rt_send (g : driver_globals) : W.func_type =
  {
    W.ftype_idx = t_numop;
    fparams = [ "to"; "msg" ];
    flocals =
      [
        (1, W.I32); (1, W.Anyref); (1, W.RefNull t_proc); (1, W.RefNull t_cons);
      ];
    fbody =
      [
        W.Local_get 0;
        W.Ref_cast t_vint;
        W.Struct_get (t_vint, 0);
        W.I32_wrap_i64;
        W.Local_set 2;
        W.Global_get g.g_head;
        W.Local_set 3;
        W.Block
          ( W.Void,
            [
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 3;
                    W.Ref_is_null;
                    W.Br_if 1;
                    W.Local_get 3;
                    W.Ref_cast t_cons;
                    W.Struct_get (t_cons, 0);
                    W.Ref_cast t_proc;
                    W.Local_set 4;
                    W.Local_get 4;
                    W.Struct_get (t_proc, 0);
                    W.Local_get 2;
                    W.I32_eq;
                    W.If
                      ( W.Void,
                        [
                          W.Local_get 1;
                          W.Ref_null_any;
                          W.Struct_new t_cons;
                          W.Local_set 5;
                          W.Local_get 4;
                          W.Struct_get (t_proc, 4);
                          W.Ref_is_null;
                          W.If
                            ( W.Void,
                              [
                                W.Local_get 4;
                                W.Local_get 5;
                                W.Struct_set (t_proc, 3);
                                W.Local_get 4;
                                W.Local_get 5;
                                W.Struct_set (t_proc, 4);
                              ],
                              [
                                W.Local_get 4;
                                W.Struct_get (t_proc, 4);
                                W.Ref_cast t_cons;
                                W.Local_get 5;
                                W.Struct_set (t_cons, 1);
                                W.Local_get 4;
                                W.Local_get 5;
                                W.Struct_set (t_proc, 4);
                              ] );
                          W.Br 2;
                        ],
                        [] );
                    W.Local_get 3;
                    W.Ref_cast t_cons;
                    W.Struct_get (t_cons, 1);
                    W.Local_set 3;
                    W.Br 0;
                  ] );
            ] );
        W.Local_get 1;
      ];
  }

let rt_recv_poll (g : driver_globals) ~(t_void_anyref : int) : W.func_type =
  {
    W.ftype_idx = t_void_anyref;
    fparams = [];
    flocals = [];
    fbody =
      [
        W.If_else
          ( W.Result W.Anyref,
            [ W.Global_get g.g_curp; W.Struct_get (t_proc, 3); W.Ref_is_null ],
            [ W.Ref_null_any ],
            [
              W.Global_get g.g_curp;
              W.Struct_get (t_proc, 3);
              W.Ref_cast t_cons;
              W.Struct_get (t_cons, 0);
            ] );
      ];
  }

let rt_recv_take (g : driver_globals) : W.func_type =
  {
    W.ftype_idx = t_main;
    fparams = [];
    flocals = [ (1, W.RefNull t_cons) ];
    fbody =
      [
        W.Global_get g.g_curp;
        W.Struct_get (t_proc, 3);
        W.Ref_cast t_cons;
        W.Local_set 0;
        W.Local_get 0;
        W.Struct_get (t_cons, 1);
        W.Ref_is_null;
        W.If
          ( W.Void,
            [
              (* the mailbox drained: head and tail go null *)
              W.Global_get g.g_curp;
              W.Ref_null_any;
              W.Struct_set (t_proc, 3);
              W.Global_get g.g_curp;
              W.Ref_null_any;
              W.Struct_set (t_proc, 4);
            ],
            [
              W.Global_get g.g_curp;
              W.Local_get 0;
              W.Struct_get (t_cons, 1);
              W.Ref_cast t_cons;
              W.Struct_set (t_proc, 3);
            ] );
      ];
  }

let rt_park (g : driver_globals) : W.func_type =
  {
    W.ftype_idx = t_numop;
    fparams = [ "handler"; "args" ];
    flocals = [];
    fbody =
      [
        W.Global_get g.g_curp;
        W.Local_get 0;
        W.Struct_set (t_proc, 5);
        W.Global_get g.g_curp;
        W.Local_get 1;
        W.Struct_set (t_proc, 6);
        W.Global_get g.g_curp;
        W.I32_const 1;
        W.Struct_set (t_proc, 2);
        W.Ref_null_any;
      ];
  }

let rt_self_pid (g : driver_globals) ~(t_void_anyref : int) : W.func_type =
  {
    W.ftype_idx = t_void_anyref;
    fparams = [];
    flocals = [];
    fbody =
      [
        W.Global_get g.g_curp;
        W.Struct_get (t_proc, 0);
        W.I64_extend_i32_s;
        W.Struct_new t_vint;
      ];
  }

let rt_halt (g : driver_globals) ~(t_void_anyref : int) : W.func_type =
  {
    W.ftype_idx = t_void_anyref;
    fparams = [];
    flocals = [];
    fbody =
      [
        W.Global_get g.g_curp;
        W.I32_const 0;
        W.Struct_set (t_proc, 1);
        W.Ref_null_any;
      ];
  }

let rt_proc_end (g : driver_globals) : W.func_type =
  {
    W.ftype_idx = t_main;
    fparams = [];
    flocals = [];
    fbody =
      [
        W.Global_get g.g_curp;
        W.Struct_get (t_proc, 2);
        W.I32_eqz;
        W.If
          ( W.Void,
            [ W.Global_get g.g_curp; W.I32_const 0; W.Struct_set (t_proc, 1) ],
            [] );
      ];
  }

let rt_driver_next (g : driver_globals) ~(t_void_i32 : int) : W.func_type =
  {
    W.ftype_idx = t_void_i32;
    fparams = [];
    flocals = [ (1, W.Anyref); (1, W.RefNull t_proc) ];
    fbody =
      [
        W.Global_get g.g_head;
        W.Local_set 0;
        W.Block
          ( W.Void,
            [
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 0;
                    W.Ref_is_null;
                    W.If (W.Void, [ W.I32_const (-1); W.Return ], []);
                    W.Local_get 0;
                    W.Ref_cast t_cons;
                    W.Struct_get (t_cons, 0);
                    W.Ref_cast t_proc;
                    W.Local_set 1;
                    W.Local_get 1;
                    W.Struct_get (t_proc, 1);
                    W.Local_get 1;
                    W.Struct_get (t_proc, 2);
                    W.I32_and;
                    W.Local_get 1;
                    W.Struct_get (t_proc, 3);
                    W.Ref_is_null;
                    W.I32_eqz;
                    W.I32_and;
                    W.If
                      ( W.Void,
                        [ W.Local_get 1; W.Struct_get (t_proc, 0); W.Return ],
                        [] );
                    W.Local_get 0;
                    W.Ref_cast t_cons;
                    W.Struct_get (t_cons, 1);
                    W.Local_set 0;
                    W.Br 0;
                  ] );
            ] );
        (* the loop only exits by returning; validation still wants a
           value on the fall-through path *)
        W.I32_const (-1);
      ];
  }

let rt_driver_resume (g : driver_globals) ~(t_i32_void : int) : W.func_type =
  {
    W.ftype_idx = t_i32_void;
    fparams = [ "id" ];
    flocals =
      [
        (1, W.RefNull t_proc);
        (1, W.Anyref);
        (1, W.Anyref);
        (1, W.Anyref);
        (1, W.RefNull t_numop);
        (1, W.RefNull t_cons);
      ];
    fbody =
      [
        W.Global_get g.g_head;
        W.Local_set 2;
        W.Block
          ( W.Void,
            [
              W.Loop
                ( W.Void,
                  [
                    W.Local_get 2;
                    W.Ref_is_null;
                    W.Br_if 1;
                    W.Local_get 2;
                    W.Ref_cast t_cons;
                    W.Struct_get (t_cons, 0);
                    W.Ref_cast t_proc;
                    W.Local_set 1;
                    W.Local_get 1;
                    W.Struct_get (t_proc, 0);
                    W.Local_get 0;
                    W.I32_eq;
                    W.If
                      ( W.Void,
                        [
                          W.Local_get 1;
                          W.Struct_get (t_proc, 3);
                          W.Ref_cast t_cons;
                          W.Local_set 6;
                          W.Local_get 1;
                          W.Local_get 6;
                          W.Struct_get (t_cons, 1);
                          W.Struct_set (t_proc, 3);
                          W.Local_get 1;
                          W.Struct_get (t_proc, 3);
                          W.Ref_is_null;
                          W.If
                            ( W.Void,
                              [
                                W.Local_get 1;
                                W.Ref_null_any;
                                W.Struct_set (t_proc, 4);
                              ],
                              [] );
                          W.Local_get 6;
                          W.Struct_get (t_cons, 0);
                          W.Local_set 3;
                          W.Local_get 1;
                          W.Struct_get (t_proc, 6);
                          W.Local_set 4;
                          W.Local_get 1;
                          W.Struct_get (t_proc, 5);
                          W.Ref_cast t_vfun2;
                          W.Struct_get (t_vfun2, 0);
                          W.Local_set 5;
                          W.Local_get 1;
                          W.I32_const 0;
                          W.Struct_set (t_proc, 2);
                          W.Local_get 1;
                          W.Struct_get (t_proc, 0);
                          W.Global_set g.g_cur;
                          W.Local_get 1;
                          W.Global_set g.g_curp;
                          W.Local_get 3;
                          W.Local_get 4;
                          W.Local_get 5;
                          W.Call_ref t_numop;
                          W.Drop;
                          W.Local_get 1;
                          W.Struct_get (t_proc, 2);
                          W.I32_eqz;
                          W.If
                            ( W.Void,
                              [
                                W.Local_get 1;
                                W.I32_const 0;
                                W.Struct_set (t_proc, 1);
                              ],
                              [] );
                          W.Br 2;
                        ],
                        [] );
                    W.Local_get 2;
                    W.Ref_cast t_cons;
                    W.Struct_get (t_cons, 1);
                    W.Local_set 2;
                    W.Br 0;
                  ] );
            ] );
      ];
  }

let rt_driver_run ~(t_i32_void : int) : W.func_type =
  {
    W.ftype_idx = t_main;
    fparams = [];
    flocals = [ (1, W.I32) ];
    fbody =
      [
        W.Block
          ( W.Void,
            [
              W.Loop
                ( W.Void,
                  [
                    W.Call (rt "driver_next");
                    W.Local_set 0;
                    W.I32_const 0;
                    W.Local_get 0;
                    W.I32_gt;
                    W.Br_if 1;
                    W.Local_get 0;
                    W.Call (rt "driver_resume");
                    W.Br 0;
                  ] );
            ] );
      ];
  }

(* ---- Module assembly ---- *)

(* The exported main runs the entry statements, then the driver loop;
   exported memory backs the println/abort exchange. *)
let assemble (program : Emo_ir.program) : W.module_ =
  let env =
    {
      rev = [];
      local_decls = [];
      local_map = [];
      binders = [];
      fname = "";
      fparams = [];
      current_class = None;
      fresh = 0;
      types = [];
      ntypes = List.length runtime_types;
      class_type = [];
      class_field = [];
      funcs = [];
      nfuncs = runtime_count;
      strings = [];
      string_pool = [];
      iface_classes = [];
      classes = [];
      hidden = [];
    }
  in
  (* Register program functions first: every func gets an index
     regardless of whether its body lowers (bodies lower in order). *)
  let program_funcs =
    List.map
      (fun (f : Emo_ir.func) ->
        let idx = env.nfuncs in
        env.nfuncs <- env.nfuncs + 1;
        (f.Emo_ir.fname, idx))
      program.Emo_ir.pfuncs
  in
  env.funcs <- program_funcs;
  (* Interface → implementing classes, computed structurally: same
     (method name, arity-excluding-self) shape the runtime's is()
     uses. Set before any body lowers: `is` and dispatch need it. *)
  let iface_map =
    List.map
      (fun (iname, meths) ->
        ( iname,
          List.filter_map
            (fun (c : Emo_ir.class_) ->
              let conforms =
                List.for_all
                  (fun (mname, arity) ->
                    List.exists
                      (fun (m : Emo_ir.func) ->
                        String.equal (member_name c m)
                          (Emo_ir.sanitize_ident mname)
                        && List.length m.Emo_ir.fparams - 1 = arity)
                      c.Emo_ir.cmethods)
                  meths
              in
              if conforms then Some c.Emo_ir.cname else None)
            program.Emo_ir.pclasses ))
      program.Emo_ir.pinterfaces
  in
  env.iface_classes <- iface_map;
  env.classes <- program.Emo_ir.pclasses;
  (* Class methods and ctor factories take the next indices, before
     any closure can (bodies lower after this). *)
  List.iter
    (fun (c : Emo_ir.class_) ->
      let register name =
        env.funcs <- (name, env.nfuncs) :: env.funcs;
        env.nfuncs <- env.nfuncs + 1
      in
      List.iter
        (fun (m : Emo_ir.func) -> register m.Emo_ir.fname)
        c.Emo_ir.cmethods;
      register (c.Emo_ir.cname ^ "__new"))
    program.Emo_ir.pclasses;
  (* Struct types and field maps must exist before any body lowers. *)
  (* Distinct shapes per class: pad encodes the class ordinal in a
     base wide enough that (ordinal, real-field-count) pairs cannot
     collide. *)
  let max_fields =
    List.fold_left
      (fun acc c -> max acc (List.length (class_fields c)))
      0 program.Emo_ir.pclasses
  in
  List.iteri
    (fun i c -> emit_class_decls env c ~pad:(class_pad max_fields i c))
    program.Emo_ir.pclasses;
  let lowered =
    List.map
      (fun (f : Emo_ir.func) ->
        let idx = List.assoc f.Emo_ir.fname env.funcs in
        (idx, emit_func env f))
      program.Emo_ir.pfuncs
  in
  let class_funcs =
    List.concat_map
      (fun ((ordinal, c) : int * Emo_ir.class_) ->
        let meths =
          List.map
            (fun (m : Emo_ir.func) ->
              let idx = List.assoc m.Emo_ir.fname env.funcs in
              (idx, emit_func env m))
            c.Emo_ir.cmethods
        in
        let factory =
          let idx = List.assoc (c.Emo_ir.cname ^ "__new") env.funcs in
          (idx, emit_ctor_factory env c ~pad:(class_pad max_fields ordinal c))
        in
        meths @ [ factory ])
      (List.mapi (fun i c -> (i, c)) program.Emo_ir.pclasses)
  in
  (* Types: the fixed runtime head first, then the program's appended
     types (env.types accumulates in reverse). *)
  let rt_eq, rt_ne, rt_deep_eq = rt_equality_funcs env in
  let rt_funcs =
    [
      rt_add;
      rt_sub;
      rt_mul;
      rt_div;
      rt_mod;
      rt_neg;
      rt_lt;
      rt_le;
      rt_gt;
      rt_ge;
      rt_eq;
      rt_ne;
      rt_to_str;
      rt_println;
      rt_strcat;
      rt_box;
      rt_throw;
      rt_int_str;
      rt_bool_str;
      rt_char_str;
      rt_instance_str;
      rt_write_bytes;
      rt_bytes_from_mem;
      rt_str_eq;
      rt_deep_eq;
      rt_append;
    ]
  in
  (* The entry's locals start fresh: the local state still holds the
     last lowered function's bindings. *)
  env.local_map <- [];
  env.local_decls <- [];
  env.binders <- [];
  (* A trailing receive must lower in tail position (it parks the entry
     process); after it the driver loop takes over. *)
  let main_body =
    match List.rev program.Emo_ir.pinit with
    | (Emo_ir.Receive _ as last) :: rest_rev ->
        stmts env (List.rev rest_rev) ~tail:false
        @ stmt env last ~tail:true
        @ [ W.Drop; W.Call (rt "driver_run") ]
    | _ ->
        stmts env program.Emo_ir.pinit ~tail:false
        @ [ W.Call (rt "driver_run") ]
  in
  let main_func : W.func_type =
    {
      W.ftype_idx = t_main;
      fparams = [];
      flocals = List.map (fun t -> (1, t)) env.local_decls;
      fbody = main_body;
    }
  in
  (* The pool fills while the entry lowers; init and globals read it
     after. *)
  let string_pool = List.rev env.string_pool in
  (* the driver's globals sit after the string pool *)
  let g =
    let base = 1 + List.length string_pool in
    {
      g_cur = base;
      g_next = base + 1;
      g_curp = base + 2;
      g_head = base + 3;
      g_tail = base + 4;
      g_saved = base + 5;
    }
  in
  let t_void_anyref = type_idx env (W.FuncT ([], [ W.Anyref ])) in
  let t_void_i32 = type_idx env (W.FuncT ([], [ W.I32 ])) in
  let t_i32_void = type_idx env (W.FuncT ([ W.I32 ], [])) in
  let init_func = rt_init string_pool ~g in
  let hidden = List.rev env.hidden in
  let funcs =
    rt_funcs
    @ [
        rt_spawn_begin g ~t_pid:t_void_anyref;
        rt_spawn_end g;
        rt_send g;
        rt_recv_poll g ~t_void_anyref;
        rt_recv_take g;
        rt_park g;
        rt_driver_next g ~t_void_i32;
        rt_driver_resume g ~t_i32_void;
        rt_driver_run ~t_i32_void;
        rt_self_pid g ~t_void_anyref;
        rt_halt g ~t_void_anyref;
        rt_proc_end g;
        rt_bit_and;
        rt_bit_or;
        rt_bit_xor;
        rt_shl;
        rt_shr;
        rt_bnot;
        rt_bytes_new;
        rt_bytes_get;
        rt_bytes_set;
        rt_bytes_le_get 2;
        rt_bytes_le_get 4;
        rt_bytes_le_get 8;
        rt_bytes_le_set 2;
        rt_bytes_le_set 4;
        rt_bytes_le_set 8;
        rt_bytes_from_str;
        rt_bytes_to_str;
        rt_bytes_label;
        init_func;
        main_func;
      ]
    @ List.map snd lowered @ List.map snd class_funcs @ List.map snd hidden
  in
  let main_idx = runtime_count - 1 in
  (* types: the fixed runtime head, then everything the lowering
     appended (env.types accumulates in reverse) — snapped last so the
     driver's own func types are included *)
  let all_types = runtime_types @ List.rev env.types in
  {
    W.types = all_types;
    imports =
      [
        { W.imodule = "emo"; W.iname = "println"; W.itype_idx = t_println };
        { W.imodule = "emo"; W.iname = "abort"; W.itype_idx = t_abort };
        { W.imodule = "emo"; W.iname = "float_str"; W.itype_idx = t_float_str };
      ];
    funcs;
    memory = 1;
    export_mem = true;
    declared_funcs = List.map fst hidden;
    globals =
      (W.I32, true)
      :: List.map (fun _ -> (W.RefNull t_vstring, true)) string_pool
      @ [
          (W.I32, true);
          (W.I32, true);
          (W.RefNull t_proc, true);
          (W.RefNull t_cons, true);
          (W.RefNull t_cons, true);
          (W.Anyref, true);
        ];
    start = rt "init";
    exports = [ ("main", main_idx) ];
  }

(* Serializers re-exported for the CLI. *)
let to_binary (m : W.module_) : string = W.to_binary m
let to_text (m : W.module_) : string = W.to_text m
