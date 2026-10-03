(* The Wasm backend: lowers the IR to a WasmGC module (Emo_wat's AST),
   serialized as binary .wasm and readable .wat.

   Value model: every dynamic value is an anyref into a boxed struct —
   $vint (i64), $vfloat (f64), $vbool, $vchar, $vstring (UTF-8 byte
   array), $vtuple, $vbox (its mutable field is the mutability),
   $venum, and one struct per class with the fields in declaration
   order. The runtime type is the tag: tests compile to
   ref.test/ref.cast.

   Host boundary: print renders into linear memory and calls an
   imported (ptr, len) print; raise calls an imported abort that
   throws in the host. $heap is the bump cursor for that exchange,
   starting at 1024. *)

module Ast = Emo_ast
module W = Emo_wat

(* ---- Fixed type table ---- *)

let t_print = 0
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
let t_int_str = 17
let t_bool_str = 18
let t_char_str = 19
let t_bytes_from_mem = 20
let t_write_bytes = 21
let t_print_v = 22

let runtime_types : W.typ list =
  [
    W.FuncT ([ W.I32; W.I32 ], []); (* print *)
    W.FuncT ([ W.I32; W.I32 ], []); (* abort *)
    W.FuncT ([ W.F64 ], [ W.I32; W.I32 ]); (* float_str *)
    W.FuncT ([], []); (* main *)
    W.FuncT ([ W.Anyref ], [ W.Anyref ]); (* sig1: one arg *)
    W.FuncT ([ W.Anyref; W.Anyref ], [ W.I32 ]); (* sig2: two args, bool *)
    W.ArrayT (W.I8, true); (* $bytes *)
    W.StructT [ (W.RefNull t_bytes, false) ]; (* $vstring *)
    W.StructT [ (W.I64, false) ]; (* $vint *)
    W.StructT [ (W.F64, false) ]; (* $vfloat *)
    W.StructT [ (W.I32, false) ]; (* $vbool *)
    W.StructT [ (W.I32, false) ]; (* $vchar *)
    W.ArrayT (W.Anyref, true); (* $anyarray *)
    W.StructT [ (W.RefNull t_anyarray, false) ]; (* $vtuple *)
    W.StructT [ (W.Anyref, true) ]; (* $vbox *)
    W.StructT [ (W.RefNull t_vstring, false); (W.RefNull t_vstring, false) ];
    (* $venum *)
    W.StructT [ (W.RefNull t_sig1, false) ]; (* $vfun *)
    W.FuncT ([ W.I64 ], [ W.RefNull t_bytes ]); (* int_str *)
    W.FuncT ([ W.I32 ], [ W.RefNull t_bytes ]); (* bool_str *)
    W.FuncT ([ W.I32 ], [ W.RefNull t_bytes ]); (* char_str *)
    W.FuncT ([ W.I32; W.I32 ], [ W.RefNull t_bytes ]); (* bytes_from_mem *)
    W.FuncT ([ W.RefNull t_bytes ], [ W.I32 ]); (* write_bytes *)
    W.FuncT ([ W.Anyref ], []); (* print_v *)
    W.FuncT ([ W.RefNull t_bytes; W.RefNull t_bytes ], [ W.I32 ]); (* str_eq *)
    W.FuncT ([ W.RefNull t_bytes; W.RefNull t_bytes ], [ W.RefNull t_bytes ]); (* strcat *)
    W.FuncT ([ W.Anyref; W.Anyref ], [ W.Anyref ]); (* numeric/comparison *)
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
  | "print" -> 16
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
  | "init" -> 28
  | _ -> failwith "wasm: bad runtime function"

(* imports 3 + runtime funcs 3..28 + main; program funcs follow. *)
let runtime_count = 30 (* imports 3 + rt 25 + init + main; program funcs follow *)

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

(* The i32 truthiness of a bool-struct value. *)
let truthy (v : W.instr list) : W.instr list = v @ [ W.Struct_get (t_vbool, 0) ]

(* ---- Expression lowering ---- *)

let rec expr env (x : Emo_ir.expr) : unit =
  match x.Emo_ir.desc with
  | Const (L_int n) ->
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
            ("wasm: unbound local " ^ name ^ " in " ^ env.fname
            ^ " map=" ^ String.concat "," (List.map fst env.local_map))))
  | Global name -> (
      match List.assoc_opt name env.funcs with
      | Some fidx ->
          e env (W.Ref_func fidx);
          e env (W.Struct_new t_vfun)
      | None -> failwith ("wasm: unbound global " ^ name))
  | Tuple es ->
      List.iter (expr env) es;
      e env (W.I32_const (List.length es));
      e env (W.Array_new_fixed (t_anyarray, List.length es));
      e env (W.Struct_new t_vtuple)
  | Array_lit es ->
      List.iter (expr env) es;
      e env (W.I32_const (List.length es));
      e env (W.Array_new_fixed (t_anyarray, List.length es));
      e env (W.Struct_new t_anyarray)
  | Make_enum { enum_name; member } ->
      string_const env enum_name;
      string_const env member;
      e env (W.Struct_new t_venum)
  | Interpolate items ->
      let rendered =
        List.concat_map
          (fun item ->
            expr_block env item
            @ [
                W.Call (rt "to_str");
                W.Ref_cast t_vstring;
                W.Struct_get (t_vstring, 0);
              ])
          items
      in
      (* interleave: bytes0 strcat bytes1 strcat ... *)
      let rec chain = function
        | [] -> []
        | [ x ] -> [ x ]
        | x :: y :: rest -> x :: W.Call (rt "strcat") :: chain (y :: rest)
      in
      es env (chain rendered)
  | Unary (Ast.Neg, operand) -> expr env operand; e env (W.Call (rt "neg"))
  | Unary (Ast.Not, operand) ->
      expr env operand;
      e env (W.Struct_get (t_vbool, 0));
      e env (W.I32_eqz);
      e env (W.Struct_new t_vbool)
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
        | Ast.And | Ast.Or -> "add"
      in
      e env (W.Call (rt fn))
  | Index (b, i) ->
      expr env b;
      e env (W.Ref_cast t_vtuple);
      e env (W.Struct_get (t_vtuple, 0));
      e env (W.Ref_cast t_anyarray);
      expr env i;
      e env (W.Struct_get (t_vint, 0));
      e env (W.I32_wrap_i64);
      e env (W.Array_get t_anyarray)
  | Field_read { obj; name } -> (
      let class_name =
        match obj.Emo_ir.ety with
        | Emo_check.ClassType c -> c
        | _ -> failwith "wasm: field read without a known class"
      in
      match (List.assoc_opt class_name env.class_field,
             List.assoc_opt class_name env.class_type) with
      | Some fields, Some tidx -> (
          match List.assoc_opt name fields with
          | Some fidx ->
              expr env obj;
              e env (W.Ref_cast tidx);
              e env (W.Struct_get (tidx, fidx))
          | None -> failwith ("wasm: unknown field " ^ class_name ^ "." ^ name))
      | _ -> failwith ("wasm: unknown class " ^ class_name))
  | Call { func; args } ->
      List.iter (expr env) args;
      (match List.assoc_opt func env.funcs with
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
      | "print", [ v ] -> expr env v; e env (W.Call (rt "print"))
      | _ ->
          raise
            (Emo_ir.Lower_error
               ("builtin `" ^ name ^ "` is not available on the wasm target")))
  | Box_new v -> expr env v; e env (W.Call (rt "box"))
  | Make_exception { message } ->
      expr env message;
      e env (W.Call (rt "throw"));
      e env (W.Unreachable)
  | Do_spawn _ | Spawn_value _ ->
      raise
        (Emo_ir.Lower_error
           "processes are not supported on the wasm target yet")
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
  | "to_string", [] -> expr env self_; e env (W.Call (rt "to_str"))
  | "is", [ target ] -> (
      let tname =
        match target.Emo_ir.desc with
        | Emo_ir.Type_ref n -> n
        | _ -> failwith "wasm: `is` expects a type name"
      in
      let classes =
        match List.assoc_opt tname env.iface_classes with
        | Some cs -> cs
        | None -> [ tname ]
      in
      let tests =
        List.filter_map
          (fun cname ->
            List.assoc_opt cname env.class_type
            |> Option.map (fun tidx -> W.Ref_test tidx))
          classes
      in
      match tests with
      | [] -> raise (Emo_ir.Lower_error ("wasm: unknown type in `is`: " ^ tname))
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
      let found =
        match recv_class with
        | Some c -> List.assoc_opt (c ^ "__" ^ mangled) env.funcs
        | None -> None
      in
      match found with
      | Some fidx ->
          expr env self_;
          List.iter (expr env) args;
          e env (W.Call fidx)
      | None ->
          raise
            (Emo_ir.Lower_error
               (Printf.sprintf "wasm: method `%s` has no static dispatch (in %s, self type: %s)" name
                  env.fname (Emo_check.to_string self_.Emo_ir.ety))))

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
  let body = stmts env cbody ~tail:true in
  env.hidden <-
    (fidx, { W.ftype_idx = t_sig1; fparams = [ "x" ]; flocals = []; fbody = body })
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
  | [] -> if tail then [ W.Unreachable ] else []
  | [ s ] -> stmt env s ~tail
  | s :: rest ->
      (* Left-to-right: each statement's instructions (and any local
         declarations it performs) must precede the rest. *)
      let code = stmt env s ~tail:false in
      code @ stmts env rest ~tail

and expr_block env (x : Emo_ir.expr) : W.instr list =
  let before = env.rev in
  expr env x;
  let code = List.rev (List.drop (List.length before) env.rev) in
  env.rev <- before;
  code

and stmt env (s : Emo_ir.stmt) ~(tail : bool) : W.instr list =
  match s with
  | Emo_ir.Effect x -> (
      let code = expr_block env x in
      match x.Emo_ir.desc with
      | Emo_ir.Builtin { name = "print"; _ } -> code
      | _ -> code @ [ W.Drop ])
  | Emo_ir.Let { mutable_ = _; name; init } ->
      let idx = fresh_local env name W.Anyref in
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
      match (List.assoc_opt class_name env.class_field,
             List.assoc_opt class_name env.class_type) with
      | Some fields, Some tidx -> (
          match List.assoc_opt name fields with
          | Some fidx ->
              expr_block env self_
              @ expr_block env value
              @ [ W.Ref_cast tidx; W.Struct_set (tidx, fidx) ]
          | None -> failwith ("wasm: unknown field " ^ class_name ^ "." ^ name))
      | _ -> failwith ("wasm: unknown class " ^ class_name))
  | Emo_ir.If { cond; then_; else_ } ->
      truthy (expr_block env cond)
      @ [
          W.If (W.Void, stmts env then_ ~tail:false, stmts env else_ ~tail:false);
        ]
  | Emo_ir.Case { scrutinee; branches } -> case env scrutinee branches ~tail
  | Emo_ir.Receive _ | Emo_ir.Send _ ->
      raise
        (Emo_ir.Lower_error
           "processes are not supported on the wasm target yet")
  | Emo_ir.Raise x -> expr_block env x @ [ W.Call (rt "throw"); W.Unreachable ]
  | Emo_ir.Return_stmt x -> (
      match x.Emo_ir.desc with
      | Emo_ir.Call { func = g; args } when g = env.fname ->
          List.iter (expr env) args;
          (match List.assoc_opt g env.funcs with
          | Some fidx -> [ W.Return_call fidx ]
          | None -> failwith ("wasm: unbound call " ^ g))
      | _ -> expr_block env x @ (if tail then [] else [ W.Return ]))

and case env scrutinee (branches : Emo_ir.branch list) ~(tail : bool) :
    W.instr list =
  let sname = Printf.sprintf "__s%d" env.fresh in
  env.fresh <- env.fresh + 1;
  let sidx = fresh_local env sname W.Anyref in
  let blocktype = if tail then W.Result W.Anyref else W.Void in
  let saved_recv = List.assoc_opt "__is_recv" env.local_map in
  let recv_local = fresh_local env (sname ^ "_r") W.Anyref in
  env.local_map <- ("__is_recv", recv_local) :: env.local_map;
  let rec build bs =
    match bs with
    | [] ->
        string_const env "no case branch matched this value";
        [ W.Call (rt "throw"); W.Unreachable ]
    | b :: rest ->
        let saved = env.binders in
        env.binders <-
          pattern_bindings [ W.Local_get sidx ] b.Emo_ir.pattern @ saved;
        let test = pattern_test env [ W.Local_get sidx ] b.Emo_ir.pattern in
        let guard =
          match b.Emo_ir.guard with
          | Some g -> truthy (expr_block env g)
          | None -> []
        in
        let cond =
          match guard with [] -> test | _ -> test @ [ W.I32_and ] @ guard
        in
        let body = stmts env b.Emo_ir.body ~tail in
        env.binders <- saved;
        let no_match = build rest in
        [ W.If_else (blocktype, cond, body, no_match) ]
  in
  let arms = build branches in
  (match saved_recv with
  | Some l -> env.local_map <- ("__is_recv", l) :: env.local_map
  | None -> env.local_map <- List.remove_assoc "__is_recv" env.local_map);
  expr env scrutinee;
  [ W.Local_set sidx; W.Block (blocktype, arms) ]

and pattern_test env (s : W.instr list) (p : Emo_ast.pattern) : W.instr list =
  match p.Ast.pattern_desc with
  | Ast.Wildcard | Ast.Pattern_binding _ -> [ W.I32_const 1 ]
  | Ast.Pattern_literal (L_int n) ->
      s
      @ [
          W.If_else
            ( W.Result W.I32,
              [ W.Ref_test t_vint ],
              [ W.Ref_cast t_vint;
                W.Struct_get (t_vint, 0);
                W.I64_const (Int64.of_int n);
                W.I64_eq ],
              [ W.I32_const 0 ] );
        ]
  | Ast.Pattern_literal (L_string str) ->
      s
      @ [
          W.If_else
            ( W.Result W.I32,
              [ W.Ref_test t_vstring ],
              [ W.Ref_cast t_vstring;
                W.Struct_get (t_vstring, 0) ]
              @ string_const_bytes env str
              @ [ W.Call (rt "str_eq") ],
              [ W.I32_const 0 ] );
        ]
  | Ast.Pattern_literal (L_bool b) ->
      s
      @ [
          W.If_else
            ( W.Result W.I32,
              [ W.Ref_test t_vbool ],
              [ W.Ref_cast t_vbool;
                W.Struct_get (t_vbool, 0);
                W.I32_const (if b then 1 else 0);
                W.I32_eq ],
              [ W.I32_const 0 ] );
        ]
  | Ast.Pattern_literal (L_float f) ->
      s
      @ [
          W.If_else
            ( W.Result W.I32,
              [ W.Ref_test t_vfloat ],
              [ W.Ref_cast t_vfloat;
                W.Struct_get (t_vfloat, 0);
                W.F64_const f;
                W.F64_eq ],
              [ W.I32_const 0 ] );
        ]
  | Ast.Pattern_literal (L_char c) ->
      s
      @ [
          W.If_else
            ( W.Result W.I32,
              [ W.Ref_test t_vchar ],
              [ W.Ref_cast t_vchar;
                W.Struct_get (t_vchar, 0);
                W.I32_const (Char.code c);
                W.I32_eq ],
              [ W.I32_const 0 ] );
        ]
  | Ast.Enum_member (t, m) ->
      let bytes_of = string_const_bytes env in
      let field_cmp (f : int) =
        [ W.Ref_cast t_venum;
          W.Struct_get (t_venum, f) ]
        @ bytes_of (if f = 0 then t else m)
        @ [ W.Call (rt "str_eq") ]
      in
      s
      @ [
          W.If_else
            ( W.Result W.I32,
              [ W.Ref_test t_venum ],
              [ W.If_else
                  ( W.Result W.I32,
                    field_cmp 0,
                    field_cmp 1,
                    [ W.I32_const 0 ] ) ],
              [ W.I32_const 0 ] );
        ]
  | Ast.Tuple_pattern _ ->
      raise
        (Emo_ir.Lower_error
           "wasm: tuple patterns arrive with the next task (T16.2)")

and string_const_bytes env (s : string) : W.instr list =
  let before = env.rev in
  string_const env s;
  let code = List.rev (List.drop (List.length before) env.rev) in
  env.rev <- before;
  code

and pattern_bindings (s : W.instr list) (p : Emo_ast.pattern) :
    (string * W.instr list) list =
  match p.Ast.pattern_desc with
  | Ast.Pattern_binding name -> [ (name, s) ]
  | _ -> []

(* ---- Function emission ---- *)

let emit_func env (f : Emo_ir.func) : W.func_type =
  env.rev <- [];
  env.local_decls <- List.map (fun _ -> W.Anyref) f.Emo_ir.fparams;
  env.local_map <- List.mapi (fun i (n, _) -> (n, i)) f.Emo_ir.fparams;
  env.binders <- [];
  env.fname <- f.Emo_ir.fname;
  env.fparams <- List.map fst f.Emo_ir.fparams;
  let body = stmts env f.Emo_ir.fbody ~tail:true in
  let param_types = List.map (fun _ -> W.Anyref) f.Emo_ir.fparams in
  {
    W.ftype_idx = type_idx env (W.FuncT (param_types, [ W.Anyref ]));
    fparams = List.map fst f.Emo_ir.fparams;
    flocals = [];
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
      ([ W.Local_get 0;
         W.Ref_cast t_vfloat;
         W.Struct_get (t_vfloat, 0);
         W.Call i_float_str;
         W.Call (rt "bytes_from_mem");
         W.Struct_new t_vstring ])
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
  { W.ftype_idx = t_sig1; fparams = [ "v" ]; flocals = []; fbody = [ string_branch ] }


(* int_str(n i64) -> (ref null $bytes): digits LSB-first into the
   scratch area at 60000, then reversed. Locals: 1 array, 2 len, 3
   neg, 4 digit/i. *)
let rt_int_str : W.func_type =
  let scratch = 60000 in
  { W.ftype_idx = t_int_str; fparams = [ "v" ];
    flocals = [ (1, W.RefNull t_bytes); (1, W.I32); (1, W.I32); (1, W.I32) ];
    fbody =
      [ W.Local_get 0;
        W.I64_const 0L;
        W.I64_lt_s;
        W.Local_set 3;
        W.Local_get 3;
        W.If
            ( W.Void,
              [ W.I64_const 0L;
                W.Local_get 0;
                W.I64_sub;
                W.Local_set 0 ],
                [] );
        W.I32_const 0;
        W.Local_set 2;
        W.Block
          ( W.Void,
            [ W.Loop
                ( W.Void,
                  [ W.Local_get 0;
                    W.I64_const 10L;
                    W.I64_rem_s;
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
                    W.I64_div_s;
                    W.Local_set 0;
                    W.Local_get 2;
                    W.I32_const 1;
                    W.I32_add;
                    W.Local_set 2;
                    W.Local_get 0;
                    W.I64_eqz;
                    W.Br_if 1;
                    W.Br 0 ] ) ] );
        W.Local_get 2;
        W.Local_get 3;
        W.I32_add;
        W.Array_new_default t_bytes;
        W.Local_set 1;
        W.Local_get 3;
        W.If
          (W.Void, [ W.Local_get 1; W.I32_const 0; W.I32_const 45; W.Array_set t_bytes ], []);
        W.I32_const 0;
        W.Local_set 4;
        W.Block
          ( W.Void,
            [ W.Loop
                ( W.Void,
                  [ W.Local_get 4;
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
                    W.Br 0 ] ) ] );
        W.Local_get 1 ] }

(* bool_str(b i32) -> (ref null $bytes). *)
let rt_bool_str : W.func_type =
  { W.ftype_idx = t_bool_str; fparams = [ "v" ]; flocals = [];
    fbody =
      [ W.If_else
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
            ] ) ] }

(* char_str(c i32) -> (ref null $bytes): one byte. *)
let rt_char_str : W.func_type =
  { W.ftype_idx = t_char_str; fparams = [ "v" ]; flocals = [];
    fbody = [ W.Local_get 0; W.Array_new_fixed (t_bytes, 1) ] }

(* instance_str(v) -> aborts: instances reach their __str through
   method_call; an unhandled shape here is a host-visible trap. *)
let rt_instance_str : W.func_type =
  { W.ftype_idx = t_sig1; fparams = [ "v" ]; flocals = [];
    fbody =
      [ W.Local_get 0;
        W.Drop;
        W.I32_const 0;
        W.I32_const 0;
        W.Call i_abort;
        W.Unreachable ] }

(* bytes_from_mem(ptr, len) -> (ref null $bytes). Locals: 2 array, 3
   i. *)
let rt_bytes_from_mem : W.func_type =
  { W.ftype_idx = t_bytes_from_mem;
    fparams = [ "ptr"; "len" ];
    flocals = [ (1, W.RefNull t_bytes); (2, W.I32) ];
    fbody =
      [ W.Block
          ( W.Void,
            [ W.Local_get 1;
              W.Array_new_default t_bytes;
              W.Local_set 2;
              W.I32_const 0;
              W.Local_set 3;
              W.Loop
                ( W.Void,
                  [ (* the byte lands in local 4 first: array.set reads
                       its three operands from the stack, so the value
                       cannot be computed between index and array *)
                    W.Local_get 0;
                    W.Local_get 3;
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
                    W.Br 0 ] ) ] );
        W.Local_get 2 ] }

(* write_bytes(b) -> i32 ptr: bump-allocate and copy. Locals: 1 ptr,
   2 len, 3 i. *)
let rt_write_bytes : W.func_type =
  { W.ftype_idx = t_write_bytes;
    fparams = [ "b" ];
    flocals = [ (3, W.I32) ]; (* 1 = ptr, 2 = len, 3 = i *)

    fbody =
      [ W.Block
          ( W.Void,
            [ W.Global_get 0;
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
                  [ W.Global_get 0;
                    W.Local_get 2;
                    W.I32_add;
                    W.I32_const 15;
                    W.I32_add;
                    W.I32_const 16;
                    W.I32_div_s;
                    W.Memory_grow;
                    W.Drop ],
                  [] );
              W.I32_const 0;
              W.Local_set 3;
              W.Loop
                ( W.Void,
                  [ W.Local_get 3;
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
                    W.Br 0 ] );
              W.Global_get 0;
              W.Local_get 2;
              W.I32_add;
              W.Global_set 0 ] );
        W.Local_get 1 ] }

(* print(v): render, bump-write, call the host. Local: 1 bytes. *)
let rt_print : W.func_type =
  { W.ftype_idx = t_print_v;
    fparams = [ "v" ];
    flocals = [ (1, W.RefNull t_bytes) ];
    fbody =
      [ W.Local_get 0;
        W.Call (rt "to_str");
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Local_set 1;
        W.Local_get 1;
        W.Call (rt "write_bytes");
        W.Local_get 1;
        W.Array_len t_bytes;
        W.Call i_print ] }

(* str_eq(a, b) -> i32 (through sig2): byte-wise compare. Locals: 2
   i, 3 la, 4 lb. *)
let rt_str_eq : W.func_type =
  { W.ftype_idx = t_str_eq;
    fparams = [ "a"; "b" ];
    flocals = [ (3, W.I32) ];
    fbody =
      [ W.Block
          ( W.Result W.I32,
            [ W.Block
                ( W.Void,
                  [ (* length mismatch: leave with 0 *)
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
                        [ W.Local_get 2;
                          W.Local_get 3;
                          W.I32_ge;
                          W.Br_if 1;
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
                          W.Br 0 ] );
                    W.I32_const 1;
                    W.Return ]);
                W.I32_const 0 ] ) ] }

(* init: build every interned string into its global. *)
let rt_init (pool : string list) : W.func_type =
  { W.ftype_idx = t_main; fparams = []; flocals = [];
    fbody =
      List.concat_map
        (fun s -> string_bytes_instrs s @ [ W.Struct_new t_vstring ])
        pool
      @ List.mapi
          (fun i _ -> W.Global_set (1 + (List.length pool - 1 - i)))
          pool }

(* ---- Numeric and comparison runtime (sig1: anyref -> anyref where a
   value is produced, sig2 where a bool) ---- *)

(* Unwrap a numeric (int or float) to f64. *)
(* both operands are $vint? *)
let both_int (a : int) (b : int) : W.instr list =
  [ W.Local_get a; W.Ref_test t_vint; W.Local_get b; W.Ref_test t_vint;
    W.I32_and ]

let i64_of (l : int) : W.instr list =
  [ W.Local_get l; W.Ref_cast t_vint; W.Struct_get (t_vint, 0) ]

let num_to_f64 (local : int) : W.instr list =
  [ W.If_else
      ( W.Result W.F64,
        [ W.Local_get local; W.Ref_test t_vfloat ],
        [ W.Local_get local;
          W.Ref_cast t_vfloat;
          W.Struct_get (t_vfloat, 0) ],
        [ W.Local_get local;
          W.Ref_cast t_vint;
          W.Struct_get (t_vint, 0);
          W.F64_convert_i64_s ] ) ]

(* arithmetic: int path via i64 op, float path via f64 op *)
let rt_arith (int_body : W.instr list) (float_body : W.instr list) :
    W.func_type =
  { W.ftype_idx = t_numop;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [ W.If_else
          ( W.Result W.Anyref,
            both_int 0 1,
            i64_of 0 @ i64_of 1 @ int_body,
            num_to_f64 0 @ num_to_f64 1 @ float_body ) ] }

let rt_add = rt_arith [ W.I64_add; W.Struct_new t_vint ] [ W.F64_add; W.Struct_new t_vfloat ]
let rt_sub = rt_arith [ W.I64_sub; W.Struct_new t_vint ] [ W.F64_sub; W.Struct_new t_vfloat ]
let rt_mul = rt_arith [ W.I64_mul; W.Struct_new t_vint ] [ W.F64_mul; W.Struct_new t_vfloat ]

(* div/mod: int division truncates *)
let rt_div = rt_arith [ W.I64_div_s; W.Struct_new t_vint ] [ W.F64_div; W.Struct_new t_vfloat ]
let rt_mod = rt_arith [ W.I64_rem_s; W.Struct_new t_vint ] [ W.F64_rem_s; W.Struct_new t_vfloat ]

(* neg *)
let rt_neg : W.func_type =
  { W.ftype_idx = t_sig1;
    fparams = [ "a" ];
    flocals = [];
    fbody =
      [ W.If_else
          ( W.Result W.Anyref,
            [ W.Local_get 0; W.Ref_test t_vint ],
            [ W.I64_const 0L ] @ i64_of 0 @ [ W.I64_sub; W.Struct_new t_vint ],
            num_to_f64 0 @ [ W.F64_neg; W.Struct_new t_vfloat ] ) ] }

(* comparisons *)
let rt_cmp (int_body : W.instr list) (float_body : W.instr list) : W.func_type =
  { W.ftype_idx = t_numop;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [ W.If_else
          ( W.Result W.Anyref,
            both_int 0 1,
            i64_of 0 @ i64_of 1 @ int_body,
            num_to_f64 0 @ num_to_f64 1 @ float_body ) ] }

let rt_lt = rt_cmp [ W.I64_lt_s; W.Struct_new t_vbool ] [ W.F64_lt; W.Struct_new t_vbool ]
let rt_le = rt_cmp [ W.I64_le_s; W.Struct_new t_vbool ] [ W.F64_le; W.Struct_new t_vbool ]
let rt_gt = rt_cmp [ W.I64_gt_s; W.Struct_new t_vbool ] [ W.F64_gt; W.Struct_new t_vbool ]
let rt_ge = rt_cmp [ W.I64_ge_s; W.Struct_new t_vbool ] [ W.F64_ge; W.Struct_new t_vbool ]

(* eq: primitives by content via deep_eq, boxed $vbool *)
let rt_eq : W.func_type =
  { W.ftype_idx = t_numop;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [ W.Local_get 0;
        W.Call (rt "to_str");
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Local_get 1;
        W.Call (rt "to_str");
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Call (rt "str_eq");
        W.Struct_new t_vbool ] }

let rt_ne : W.func_type =
  { W.ftype_idx = t_numop;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [ W.Local_get 0;
        W.Call (rt "to_str");
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Local_get 1;
        W.Call (rt "to_str");
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Call (rt "str_eq");
        W.I32_eqz;
        W.Struct_new t_vbool ] }

(* deep_eq(a, b) -> i32: equality for the primitive shapes (instances
   arrive with classes; tuples/arrays with T16.2). Shape:
   bothref T ? (typed compare) : 0 — chained, first match exits. *)
let rt_deep_eq : W.func_type =
  (* Canonical-rendering equality: to_str is injective over the
     primitive shapes (each type renders distinctly: 2 vs 2.0 vs true),
     so comparing renderings equals comparing values — for the golden
     subset. Instance/array equality arrives with T16.2. *)
  { W.ftype_idx = t_sig2;
    fparams = [ "a"; "b" ];
    flocals = [];
    fbody =
      [ W.Local_get 0;
        W.Call (rt "to_str");
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Local_get 1;
        W.Call (rt "to_str");
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Call (rt "str_eq") ] }

(* strcat(a, b (ref null $bytes)) -> (ref null $bytes). Locals: 2 arr,
   3 i, 4 alen. *)
let rt_strcat : W.func_type =
  { W.ftype_idx = t_strcat;
    fparams = [ "a"; "b" ];
    flocals = [ (1, W.RefNull t_bytes); (2, W.I32); (3, W.I32) ];
    fbody =
      [ W.Local_get 0;
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
            [ W.Loop
                ( W.Void,
                  [ W.Local_get 3;
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
                    W.Br 0 ] ) ] );
        W.Block
          ( W.Void,
            [ W.I32_const 0;
              W.Local_set 3;
              W.Loop
                ( W.Void,
                  [ W.Local_get 3;
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
                    W.Br 0 ] ) ] );
        W.Local_get 2 ] }

(* box(v) -> (ref null $vbox). *)
let rt_box : W.func_type =
  { W.ftype_idx = t_sig1;
    fparams = [ "v" ];
    flocals = [];
    fbody =
      [ W.Local_get 0;
        W.Struct_new t_vbox ] }

(* throw(msg): render the message into memory and abort through the
   host, which throws. *)
let rt_throw : W.func_type =
  { W.ftype_idx = t_sig1;
    fparams = [ "v" ];
    flocals = [ (1, W.RefNull t_bytes) ];
    fbody =
      [ W.Local_get 0;
        W.Ref_cast t_vstring;
        W.Struct_get (t_vstring, 0);
        W.Local_set 1;
        W.Local_get 1;
        W.Call (rt "write_bytes");
        W.Local_get 1;
        W.Array_len t_bytes;
        W.Call i_abort;
        W.Unreachable ] }

(* ---- Module assembly ---- *)(* ---- Module assembly ---- *)

(* The exported main runs the entry statements; exported memory backs
   the print/abort exchange. *)
let assemble (program : Emo_ir.program) : W.module_ =
  let env =
    { rev = [];
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
      hidden = [] }
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
  let lowered =
    List.map
      (fun (f : Emo_ir.func) ->
        let idx = List.assoc f.Emo_ir.fname env.funcs in
        (idx, emit_func env f))
      program.Emo_ir.pfuncs
  in
  (* Types: the fixed runtime head first, then the program's appended
     types (env.types accumulates in reverse). *)
  let all_types = runtime_types @ List.rev env.types in
  let rt_funcs =
    [ rt_add;
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
      rt_print;
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
      rt_deep_eq ]
  in
  (* The entry's locals start fresh: the local state still holds the
     last lowered function's bindings. *)
  env.local_map <- [];
  env.local_decls <- [];
  env.binders <- [];
  let main_body = stmts env program.Emo_ir.pinit ~tail:false in
  let main_func : W.func_type =
    { W.ftype_idx = t_main;
      fparams = [];
      flocals = List.map (fun t -> (1, t)) env.local_decls;
      fbody = main_body }
  in
  (* The pool fills while the entry lowers; init and globals read it
     after. *)
  let string_pool = List.rev env.string_pool in
  let init_func = rt_init string_pool in
  let hidden = List.rev env.hidden in
  let funcs = rt_funcs @ [ init_func; main_func ] @ List.map snd hidden @ List.map snd lowered in
  let main_idx = runtime_count - 1 in
  { W.types = all_types;
    imports =
      [ { W.imodule = "emo"; W.iname = "print"; W.itype_idx = t_print };
        { W.imodule = "emo"; W.iname = "abort"; W.itype_idx = t_abort };
        { W.imodule = "emo"; W.iname = "float_str"; W.itype_idx = t_float_str };
      ];
    funcs;
    memory = 1;
    export_mem = true;
    declared_funcs = List.map fst hidden;

    globals = (W.I32, true) :: List.map (fun _ -> (W.RefNull t_vstring, true)) string_pool;
    start = rt "init";
    exports = [ ("main", main_idx) ] }

(* Serializers re-exported for the CLI. *)
let to_binary (m : W.module_) : string = W.to_binary m
let to_text (m : W.module_) : string = W.to_text m