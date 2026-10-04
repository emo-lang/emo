(* The Wasm intermediate: a small typed AST between the IR lowering and
   its two serializations — the readable `.wat` text and the binary
   `.wasm` the hosts execute. One AST, two writers; the golden tests
   catch the two disagreeing. *)

type valtype =
  | I32
  | I64
  | F64
  | I8 (* packed array storage only — never a local or param *)
  | Anyref
  | Externref
  | Funcref
  | RefNull of int (* (ref null $t) — a concrete type index *)
  | Ref of int

type fieldtype = valtype * bool (* type, mutable *)

type typ =
  | FuncT of valtype list * valtype list
  | StructT of fieldtype list
  | ArrayT of fieldtype

type blocktype = Void | Result of valtype

(* Labels: 0 is the innermost. *)
type instr =
  | I32_const of int
  | I64_const of int64
  | F64_const of float
  | Local_get of int
  | Local_set of int
  | Local_tee of int
  | Global_get of int
  | Global_set of int
  | Struct_new of int
  | Struct_new_default of int
  | Struct_get of int * int
  | Struct_set of int * int
  | Array_new_fixed of int * int (* type, length *)
  | Array_get of int (* unpacked element type *)
  | Array_get_u of int (* packed i8 elements *)
  | Array_set of int
  | Array_len of int
  | Ref_test of int (* (ref $t) — non-null test *)
  | Ref_cast of int
  | Drop
  | I32_eqz
  | I32_eq
  | I32_ne
  | I32_and
  | I32_or
  | I32_add
  | I32_sub
  | I32_mul
  | I32_div_s
  | I32_ge
  | I32_gt
  | I32_wrap_i64
  | I64_eq
  | I64_eqz
  | I64_extend_i32_s
  | I64_add
  | I64_sub
  | I64_mul
  | I64_div_s
  | I64_rem_s
  | I64_and
  | I64_or
  | I64_xor
  | I64_shl
  | I64_shr_s
  | F64_eq
  | F64_add
  | F64_sub
  | F64_mul
  | F64_div
  | F64_convert_i64_s
  | F64_rem_s
  | F64_neg
  | I64_lt_s
  | I64_le_s
  | I64_gt_s
  | I64_ge_s
  | F64_lt
  | F64_le
  | F64_gt
  | F64_ge
  | Memory_size
  | Memory_grow
  | I32_load8_u
  | I32_store8
  | Array_new_default of int
  | Call_ref of int
  | Ref_func of int
  | Ref_null_any
  | Ref_is_null
  | Call of int
  | Return_call of int
  | If of blocktype * instr list * instr list
  | If_else of blocktype * instr list * instr list * instr list
  | Block of blocktype * instr list
  | Loop of blocktype * instr list
  | Br of int
  | Br_if of int
  | Return
  | Unreachable

type func_type = {
  ftype_idx : int;
  fparams : string list;
  flocals : (int * valtype) list; (* count × type groups, beyond params *)
  fbody : instr list;
}

type import = {
  imodule : string;
  iname : string;
  itype_idx : int; (* index into the type section *)
}

type module_ = {
  types : typ list;
  imports : import list;
  funcs : func_type list; (* indices continue after the imports *)
  memory : int; (* minimum pages; 0 = none *)
  declared_funcs : int list; (* ref.func declarations for closures *)
  export_mem : bool; (* export the memory as "mem" *)
  globals : (valtype * bool) list; (* in order; zero/null init *)
  start : int; (* start function index; -1 = none *)
  exports : (string * int) list; (* name → func index *)
}

(* ---- The text printer (readable .wat) ---- *)

let valtype_name = function
  | I32 -> "i32"
  | I64 -> "i64"
  | F64 -> "f64"
  | I8 -> "i8"
  | Anyref -> "anyref"
  | Externref -> "externref"
  | Funcref -> "funcref"
  | RefNull t -> Printf.sprintf "(ref null $t%d)" t
  | Ref t -> Printf.sprintf "(ref $t%d)" t

let rec instr_text indent (i : instr) : string =
  let pad = String.make indent ' ' in
  let inner = indent + 2 in
  match i with
  | I32_const n -> Printf.sprintf "%si32.const %d\n" pad n
  | I64_const n -> Printf.sprintf "%si64.const %Ld\n" pad n
  | F64_const f -> Printf.sprintf "%sf64.const %h\n" pad f
  | Local_get n -> Printf.sprintf "%slocal.get %d\n" pad n
  | Local_set n -> Printf.sprintf "%slocal.set %d\n" pad n
  | Local_tee n -> Printf.sprintf "%slocal.tee %d\n" pad n
  | Global_get n -> Printf.sprintf "%sglobal.get %d\n" pad n
  | Global_set n -> Printf.sprintf "%sglobal.set %d\n" pad n
  | Struct_new t -> Printf.sprintf "%sstruct.new $t%d\n" pad t
  | Struct_new_default t -> Printf.sprintf "%sstruct.new_default $t%d\n" pad t
  | Struct_get (t, f) -> Printf.sprintf "%sstruct.get $t%d %d\n" pad t f
  | Struct_set (t, f) -> Printf.sprintf "%sstruct.set $t%d %d\n" pad t f
  | Array_new_fixed (t, n) ->
      Printf.sprintf "%sarray.new_fixed $t%d %d\n" pad t n
  | Array_get t -> Printf.sprintf "%sarray.get $t%d\n" pad t
  | Array_get_u t -> Printf.sprintf "%sarray.get_u $t%d\n" pad t
  | Array_set t -> Printf.sprintf "%sarray.set $t%d\n" pad t
  | Array_len _ -> Printf.sprintf "%sarray.len\n" pad
  | Ref_test t -> Printf.sprintf "%sref.test (ref $t%d)\n" pad t
  | Ref_cast t -> Printf.sprintf "%sref.cast (ref $t%d)\n" pad t
  | Drop -> Printf.sprintf "%sdrop\n" pad
  | I32_eqz -> Printf.sprintf "%si32.eqz\n" pad
  | I32_eq -> Printf.sprintf "%si32.eq\n" pad
  | I32_ne -> Printf.sprintf "%si32.ne\n" pad
  | I32_and -> Printf.sprintf "%si32.and\n" pad
  | I32_or -> Printf.sprintf "%si32.or\n" pad
  | I32_add -> Printf.sprintf "%si32.add\n" pad
  | I32_mul -> Printf.sprintf "%si32.mul\n" pad
  | I32_gt -> Printf.sprintf "%si32.gt\n" pad
  | I32_sub -> Printf.sprintf "%si32.sub\n" pad
  | I32_div_s -> Printf.sprintf "%si32.div_s\n" pad
  | I32_ge -> Printf.sprintf "%si32.ge\n" pad
  | I32_wrap_i64 -> Printf.sprintf "%si32.wrap_i64\n" pad
  | I64_eq -> Printf.sprintf "%si64.eq\n" pad
  | I64_eqz -> Printf.sprintf "%si64.eqz\n" pad
  | I64_extend_i32_s -> Printf.sprintf "%si64.extend_i32_s\n" pad
  | I64_add -> Printf.sprintf "%si64.add\n" pad
  | I64_sub -> Printf.sprintf "%si64.sub\n" pad
  | I64_mul -> Printf.sprintf "%si64.mul\n" pad
  | I64_div_s -> Printf.sprintf "%si64.div_s\n" pad
  | I64_rem_s -> Printf.sprintf "%si64.rem_s\n" pad
  | I64_and -> Printf.sprintf "%si64.and\n" pad
  | I64_or -> Printf.sprintf "%si64.or\n" pad
  | I64_xor -> Printf.sprintf "%si64.xor\n" pad
  | I64_shl -> Printf.sprintf "%si64.shl\n" pad
  | I64_shr_s -> Printf.sprintf "%si64.shr_s\n" pad
  | F64_eq -> Printf.sprintf "%sf64.eq\n" pad
  | F64_add -> Printf.sprintf "%sf64.add\n" pad
  | F64_sub -> Printf.sprintf "%sf64.sub\n" pad
  | F64_mul -> Printf.sprintf "%sf64.mul\n" pad
  | F64_div -> Printf.sprintf "%sf64.div\n" pad
  | F64_convert_i64_s -> Printf.sprintf "%sf64.convert_i64_s\n" pad
  | F64_rem_s -> Printf.sprintf "%sf64.rem_s\n" pad
  | F64_neg -> Printf.sprintf "%sf64.neg\n" pad
  | I64_lt_s -> Printf.sprintf "%si64.lt_s\n" pad
  | I64_le_s -> Printf.sprintf "%si64.le_s\n" pad
  | I64_gt_s -> Printf.sprintf "%si64.gt_s\n" pad
  | I64_ge_s -> Printf.sprintf "%si64.ge_s\n" pad
  | F64_lt -> Printf.sprintf "%sf64.lt\n" pad
  | F64_le -> Printf.sprintf "%sf64.le\n" pad
  | F64_gt -> Printf.sprintf "%sf64.gt\n" pad
  | F64_ge -> Printf.sprintf "%sf64.ge\n" pad
  | Memory_size -> Printf.sprintf "%smemory.size\n" pad
  | Memory_grow -> Printf.sprintf "%smemory.grow\n" pad
  | I32_load8_u -> Printf.sprintf "%si32.load8_u\n" pad
  | I32_store8 -> Printf.sprintf "%si32.store8\n" pad
  | Array_new_default t -> Printf.sprintf "%sarray.new_default $t%d\n" pad t
  | Call_ref t -> Printf.sprintf "%scall_ref $t%d\n" pad t
  | Ref_func f -> Printf.sprintf "%sref.func $f%d\n" pad f
  | Call f -> Printf.sprintf "%scall $f%d\n" pad f
  | Ref_null_any -> Printf.sprintf "%sref.null any\n" pad
  | Ref_is_null -> Printf.sprintf "%sref.is_null\n" pad
  | Return_call f -> Printf.sprintf "%sreturn_call $f%d\n" pad f
  | If (bt, then_, else_) ->
      let bt_text =
        match bt with
        | Void -> ""
        | Result v -> "(result " ^ valtype_name v ^ ")"
      in
      let else_text =
        match else_ with
        | [] -> ""
        | _ ->
            Printf.sprintf "%selse\n%s" pad
              (String.concat "" (List.map (instr_text inner) else_))
      in
      Printf.sprintf "%sif %s\n%s%s%send if\n" pad bt_text
        (String.concat "" (List.map (instr_text inner) then_))
        else_text pad
  | Block (bt, xs) ->
      let bt_text =
        match bt with
        | Void -> ""
        | Result v -> "(result " ^ valtype_name v ^ ")"
      in
      Printf.sprintf "%sblock %s\n%s%send block\n" pad bt_text
        (String.concat "" (List.map (instr_text inner) xs))
        pad
  | Loop (bt, xs) ->
      let bt_text =
        match bt with
        | Void -> ""
        | Result v -> "(result " ^ valtype_name v ^ ")"
      in
      Printf.sprintf "%sloop %s\n%s%send loop\n" pad bt_text
        (String.concat "" (List.map (instr_text inner) xs))
        pad
  | Br l -> Printf.sprintf "%sbr %d\n" pad l
  | Br_if l -> Printf.sprintf "%sbr_if %d\n" pad l
  | Return -> Printf.sprintf "%sreturn\n" pad
  | Unreachable -> Printf.sprintf "%sunreachable\n" pad
  | If_else (bt, cond, then_, else_) ->
      (* The condition's instructions run first (they leave the tested
         i32 on the stack); rendered as a nested block for honesty. *)
      let bt_text =
        match bt with
        | Void -> ""
        | Result v -> "(result " ^ valtype_name v ^ ")"
      in
      let cond_text = String.concat "" (List.map (instr_text inner) cond) in
      let then_text = String.concat "" (List.map (instr_text inner) then_) in
      let else_text = String.concat "" (List.map (instr_text inner) else_) in
      String.concat ""
        [
          pad;
          "block (result i32)\n";
          cond_text;
          "\nend block\n";
          "if (";
          bt_text;
          ")\n";
          then_text;
          "\nelse\n";
          else_text;
          "\nend if\n";
        ]

let leb_u (buf : Buffer.t) (n : int) =
  let rec go n =
    if n < 0x80 then Buffer.add_char buf (Char.chr n)
    else begin
      Buffer.add_char buf (Char.chr (n land 0x7f lor 0x80));
      go (n lsr 7)
    end
  in
  go n

let leb_s (buf : Buffer.t) (n : int) =
  let rec go n =
    let byte = n land 0x7f in
    let n = n asr 7 in
    if (n = 0 && byte land 0x40 = 0) || (n = -1 && byte land 0x40 <> 0) then
      Buffer.add_char buf (Char.chr byte)
    else begin
      Buffer.add_char buf (Char.chr (byte lor 0x80));
      go n
    end
  in
  go n

let leb_s64 (buf : Buffer.t) (n : int64) =
  let rec go n =
    let byte = Int64.to_int (Int64.logand n 0x7fL) in
    (* arithmetic shift: the sign bit must keep flowing into the
       terminator check, or negative values never end correctly *)
    let n = Int64.shift_right n 7 in
    let more =
      (Int64.compare n 0L = 0 && byte land 0x40 = 0)
      || (Int64.compare n (-1L) = 0 && byte land 0x40 <> 0)
    in
    if more then Buffer.add_char buf (Char.chr byte)
    else begin
      Buffer.add_char buf (Char.chr (byte lor 0x80));
      go n
    end
  in
  go n

let f64_bytes (buf : Buffer.t) (f : float) =
  let b = Int64.bits_of_float f in
  for i = 0 to 7 do
    Buffer.add_char buf
      (Char.chr
         (Int64.to_int
            (Int64.logand (Int64.shift_right_logical b (i * 8)) 0xffL)))
  done

let heaptype (buf : Buffer.t) (t : int) = leb_s buf t

let valtype_byte (buf : Buffer.t) (v : valtype) =
  match v with
  | I32 -> Buffer.add_char buf '\x7f'
  | I64 -> Buffer.add_char buf '\x7e'
  | F64 -> Buffer.add_char buf '\x7c'
  | I8 -> Buffer.add_char buf '\x78'
  | Anyref -> Buffer.add_string buf "\x63\x6e"
  | Externref -> Buffer.add_char buf '\x6f'
  | Funcref -> Buffer.add_char buf '\x70'
  | RefNull t ->
      Buffer.add_char buf '\x63';
      heaptype buf t
  | Ref t ->
      Buffer.add_char buf '\x64';
      heaptype buf t

let blocktype_byte (buf : Buffer.t) (bt : blocktype) =
  match bt with
  | Void -> Buffer.add_char buf '\x40'
  | Result Anyref -> Buffer.add_char buf '\x6e'
  | Result v -> valtype_byte buf v

let rec encode_instr buf (i : instr) =
  match i with
  | I32_const n ->
      Buffer.add_char buf '\x41';
      leb_s buf n
  | I64_const n ->
      Buffer.add_char buf '\x42';
      leb_s64 buf n
  | F64_const f ->
      Buffer.add_char buf '\x44';
      f64_bytes buf f
  | Local_get n ->
      Buffer.add_char buf '\x20';
      leb_u buf n
  | Local_set n ->
      Buffer.add_char buf '\x21';
      leb_u buf n
  | Local_tee n ->
      Buffer.add_char buf '\x22';
      leb_u buf n
  | Global_get n ->
      Buffer.add_char buf '\x23';
      leb_u buf n
  | Global_set n ->
      Buffer.add_char buf '\x24';
      leb_u buf n
  | Struct_new t ->
      Buffer.add_string buf "\xfb\x00";
      leb_u buf t
  | Struct_new_default t ->
      Buffer.add_string buf "\xfb\x01";
      leb_u buf t
  | Struct_get (t, f) ->
      Buffer.add_string buf "\xfb\x02";
      leb_u buf t;
      leb_u buf f
  | Struct_set (t, f) ->
      Buffer.add_string buf "\xfb\x05";
      leb_u buf t;
      leb_u buf f
  | Array_new_fixed (t, n) ->
      Buffer.add_string buf "\xfb\x08";
      leb_u buf t;
      leb_u buf n
  | Array_get t ->
      Buffer.add_string buf "\xfb\x0b";
      leb_u buf t
  | Array_get_u t ->
      Buffer.add_string buf "\xfb\x0d";
      leb_u buf t
  | Array_set t ->
      Buffer.add_string buf "\xfb\x0e";
      leb_u buf t
  | Array_len _ -> Buffer.add_string buf "\xfb\x0f"
  | Ref_test t ->
      Buffer.add_string buf "\xfb\x14";
      heaptype buf t
  | Ref_cast t ->
      Buffer.add_string buf "\xfb\x16";
      heaptype buf t
  | Drop -> Buffer.add_char buf '\x1a'
  | I32_eqz -> Buffer.add_char buf '\x45'
  | I32_eq -> Buffer.add_char buf '\x46'
  | I32_ne -> Buffer.add_char buf '\x47'
  | I32_and -> Buffer.add_char buf '\x71'
  | I32_or -> Buffer.add_char buf '\x72'
  | I32_add -> Buffer.add_char buf '\x6a'
  | I32_sub -> Buffer.add_char buf '\x6b'
  | I32_mul -> Buffer.add_char buf '\x6c'
  | I32_div_s -> Buffer.add_char buf '\x6d'
  | I32_ge -> Buffer.add_char buf '\x4e'
  | I32_gt -> Buffer.add_char buf '\x4a'
  | I32_wrap_i64 -> Buffer.add_char buf '\xa7'
  | I64_eq -> Buffer.add_char buf '\x51'
  | I64_eqz -> Buffer.add_char buf '\x50'
  | I64_extend_i32_s -> Buffer.add_char buf '\xac'
  | I64_add -> Buffer.add_char buf '\x7c'
  | I64_sub -> Buffer.add_char buf '\x7d'
  | I64_mul -> Buffer.add_char buf '\x7e'
  | I64_div_s -> Buffer.add_char buf '\x7f'
  | I64_rem_s -> Buffer.add_char buf '\x81'
  | I64_and -> Buffer.add_char buf '\x83'
  | I64_or -> Buffer.add_char buf '\x84'
  | I64_xor -> Buffer.add_char buf '\x85'
  | I64_shl -> Buffer.add_char buf '\x86'
  | I64_shr_s -> Buffer.add_char buf '\x87'
  | I64_lt_s -> Buffer.add_char buf '\x53'
  | I64_le_s -> Buffer.add_char buf '\x57'
  | I64_gt_s -> Buffer.add_char buf '\x55'
  | I64_ge_s -> Buffer.add_char buf '\x59'
  | F64_eq -> Buffer.add_char buf '\x61'
  | F64_add -> Buffer.add_char buf '\xa0'
  | F64_sub -> Buffer.add_char buf '\xa1'
  | F64_mul -> Buffer.add_char buf '\xa2'
  | F64_div -> Buffer.add_char buf '\xa3'
  | F64_rem_s -> Buffer.add_char buf '\xa5'
  | F64_neg -> Buffer.add_char buf '\x9a'
  | F64_convert_i64_s -> Buffer.add_char buf '\xb9'
  | F64_lt -> Buffer.add_char buf '\x63'
  | F64_le -> Buffer.add_char buf '\x65'
  | F64_gt -> Buffer.add_char buf '\x64'
  | F64_ge -> Buffer.add_char buf '\x66'
  | Memory_size -> Buffer.add_string buf "\x3f\x00"
  | Memory_grow -> Buffer.add_string buf "\x40\x00"
  | I32_load8_u -> Buffer.add_string buf "\x2d\x00\x00"
  | I32_store8 -> Buffer.add_string buf "\x3a\x00\x00"
  | Array_new_default t ->
      Buffer.add_string buf "\xfb\x07";
      leb_u buf t
  | Call_ref t ->
      Buffer.add_char buf '\x14';
      leb_u buf t
  | Ref_func f ->
      Buffer.add_char buf '\xd2';
      leb_u buf f
  | Call f ->
      Buffer.add_char buf '\x10';
      leb_u buf f
  | Ref_null_any -> Buffer.add_string buf "\xd0\x6e"
  | Ref_is_null -> Buffer.add_char buf '\xd1'
  | Return_call f ->
      Buffer.add_char buf '\x12';
      leb_u buf f
  | If_else (bt, cond, then_, else_) ->
      Buffer.add_char buf '\x02';
      Buffer.add_char buf '\x7f';
      List.iter (encode_instr buf) cond;
      Buffer.add_char buf '\x0b';
      Buffer.add_char buf '\x04';
      blocktype_byte buf bt;
      List.iter (encode_instr buf) then_;
      if else_ <> [] then begin
        Buffer.add_char buf '\x05';
        List.iter (encode_instr buf) else_
      end;
      Buffer.add_char buf '\x0b'
  | If (bt, then_, else_) ->
      Buffer.add_char buf '\x04';
      blocktype_byte buf bt;
      List.iter (encode_instr buf) then_;
      if else_ <> [] then begin
        Buffer.add_char buf '\x05';
        List.iter (encode_instr buf) else_
      end;
      Buffer.add_char buf '\x0b'
  | Block (bt, xs) ->
      Buffer.add_char buf '\x02';
      blocktype_byte buf bt;
      List.iter (encode_instr buf) xs;
      Buffer.add_char buf '\x0b'
  | Loop (bt, xs) ->
      Buffer.add_char buf '\x03';
      blocktype_byte buf bt;
      List.iter (encode_instr buf) xs;
      Buffer.add_char buf '\x0b'
  | Br l ->
      Buffer.add_char buf '\x0c';
      leb_u buf l
  | Br_if l ->
      Buffer.add_char buf '\x0d';
      leb_u buf l
  | Return -> Buffer.add_char buf '\x0f'
  | Unreachable -> Buffer.add_char buf '\x00'

let encode_name (buf : Buffer.t) (s : string) =
  leb_u buf (String.length s);
  Buffer.add_string buf s

let section (parts : Buffer.t) (id : int) (content : Buffer.t) =
  if Buffer.length content > 0 then begin
    Buffer.add_char parts (Char.chr id);
    leb_u parts (Buffer.length content);
    Buffer.add_buffer parts content
  end

let section (parts : Buffer.t) (id : int) (content : Buffer.t) =
  if Buffer.length content > 0 then begin
    Buffer.add_char parts (Char.chr id);
    leb_u parts (Buffer.length content);
    Buffer.add_buffer parts content
  end

let encode_name (buf : Buffer.t) (s : string) =
  leb_u buf (String.length s);
  Buffer.add_string buf s

let typ_text (idx : int) (t : typ) : string =
  let field_text (v, mutable_) : string =
    match mutable_ with
    | true -> Printf.sprintf "(field (mut %s))" (valtype_name v)
    | false -> Printf.sprintf "(field %s)" (valtype_name v)
  in
  match t with
  | FuncT (params, results) ->
      let ps = String.concat " " (List.map valtype_name params) in
      let rs =
        match results with
        | [] -> ""
        | xs -> " (result " ^ String.concat " " (List.map valtype_name xs) ^ ")"
      in
      Printf.sprintf "  (type $t%d (func (param %s)%s))\n" idx ps rs
  | StructT fields ->
      Printf.sprintf "  (type $t%d (struct %s))\n" idx
        (String.concat " " (List.map field_text fields))
  | ArrayT field ->
      Printf.sprintf "  (type $t%d (array %s))\n" idx (field_text field)

let to_text (m : module_) : string =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "(module\n";
  List.iteri (fun i t -> Buffer.add_string buf (typ_text i t)) m.types;
  List.iter
    (fun imp ->
      Buffer.add_string buf
        (Printf.sprintf "  (import %S %S (func $import%d))\n" imp.imodule
           imp.iname imp.itype_idx))
    m.imports;
  List.iteri
    (fun i (f : func_type) ->
      let ptypes =
        match List.nth m.types f.ftype_idx with FuncT (ps, _) -> ps | _ -> []
      in
      let params =
        String.concat " "
          (List.mapi
             (fun j p -> Printf.sprintf "$p%d %s" j (valtype_name p))
             ptypes)
      in
      (* the label carries the real function index: m.funcs sits after
         the imports, so the position plus the import count is what
         `call` instructions elsewhere refer to *)
      Buffer.add_string buf
        (Printf.sprintf "  (func $f%d %s\n%s  )\n" (i + List.length m.imports)
           (if params = "" then "" else "(param " ^ params ^ ")")
           (String.concat "" (List.map (instr_text 4) f.fbody))))
    m.funcs;
  if m.memory > 0 then
    Buffer.add_string buf (Printf.sprintf "  (memory %d)\n" m.memory);
  List.iter
    (fun (v, mutable_) ->
      let vt = valtype_name v in
      let mut = if mutable_ then "(mut " ^ vt ^ ")" else vt in
      Buffer.add_string buf (Printf.sprintf "  (global %s)\n" mut))
    m.globals;
  if m.start >= 0 then
    Buffer.add_string buf (Printf.sprintf "  (start $f%d)\n" m.start);
  List.iter
    (fun (name, fidx) ->
      Buffer.add_string buf
        (Printf.sprintf "  (export %S (func $f%d))\n" name fidx))
    m.exports;
  Buffer.add_string buf ")\n";
  Buffer.contents buf

let to_text (m : module_) : string =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "(module\n";
  List.iteri (fun i t -> Buffer.add_string buf (typ_text i t)) m.types;
  List.iter
    (fun imp ->
      Buffer.add_string buf
        (Printf.sprintf "  (import %S %S (func $import%d))\n" imp.imodule
           imp.iname imp.itype_idx))
    m.imports;
  List.iteri
    (fun i (f : func_type) ->
      let ptypes =
        match List.nth m.types f.ftype_idx with FuncT (ps, _) -> ps | _ -> []
      in
      let params =
        String.concat " "
          (List.mapi
             (fun j p -> Printf.sprintf "$p%d %s" j (valtype_name p))
             ptypes)
      in
      (* the label carries the real function index: m.funcs sits after
         the imports, so the position plus the import count is what
         `call` instructions elsewhere refer to *)
      Buffer.add_string buf
        (Printf.sprintf "  (func $f%d %s\n%s  )\n" (i + List.length m.imports)
           (if params = "" then "" else "(param " ^ params ^ ")")
           (String.concat "" (List.map (instr_text 4) f.fbody))))
    m.funcs;
  if m.memory > 0 then
    Buffer.add_string buf (Printf.sprintf "  (memory %d)\n" m.memory);
  if m.declared_funcs <> [] then begin
    Buffer.add_string buf "  (elem declare func\n";
    List.iter
      (fun fi -> Buffer.add_string buf (Printf.sprintf "    $f%d\n" fi))
      m.declared_funcs;
    Buffer.add_string buf "  )\n"
  end;
  List.iter
    (fun (v, mutable_) ->
      let vt = valtype_name v in
      let mut = if mutable_ then "(mut " ^ vt ^ ")" else vt in
      Buffer.add_string buf (Printf.sprintf "  (global %s)\n" mut))
    m.globals;
  if m.start >= 0 then
    Buffer.add_string buf (Printf.sprintf "  (start $f%d)\n" m.start);
  List.iter
    (fun (name, fidx) ->
      Buffer.add_string buf
        (Printf.sprintf "  (export %S (func $f%d))\n" name fidx))
    m.exports;
  Buffer.add_string buf ")\n";
  Buffer.contents buf

let to_binary (m : module_) : string =
  let types = Buffer.create 256 in
  leb_u types (List.length m.types);
  List.iter
    (fun t ->
      match t with
      | FuncT (params, results) ->
          Buffer.add_char types '\x60';
          leb_u types (List.length params);
          List.iter (valtype_byte types) params;
          leb_u types (List.length results);
          List.iter (valtype_byte types) results
      | StructT fields ->
          Buffer.add_char types '\x5f';
          leb_u types (List.length fields);
          List.iter
            (fun (v, mutable_) ->
              valtype_byte types v;
              Buffer.add_char types (if mutable_ then '\x01' else '\x00'))
            fields
      | ArrayT (v, mutable_) ->
          Buffer.add_char types '\x5e';
          valtype_byte types v;
          Buffer.add_char types (if mutable_ then '\x01' else '\x00'))
    m.types;
  let imports = Buffer.create 64 in
  leb_u imports (List.length m.imports);
  List.iter
    (fun imp ->
      encode_name imports imp.imodule;
      encode_name imports imp.iname;
      Buffer.add_char imports '\x00';
      leb_u imports imp.itype_idx)
    m.imports;
  let funcs = Buffer.create 64 in
  leb_u funcs (List.length m.funcs);
  List.iter (fun f -> leb_u funcs f.ftype_idx) m.funcs;
  let code = Buffer.create 1024 in
  leb_u code (List.length m.funcs);
  List.iter
    (fun (f : func_type) ->
      let body = Buffer.create 128 in
      leb_u body (List.length f.flocals);
      List.iter
        (fun (count, t) ->
          leb_u body count;
          valtype_byte body t)
        f.flocals;
      List.iter (encode_instr body) f.fbody;
      Buffer.add_char body '\x0b';
      leb_u code (Buffer.length body);
      Buffer.add_buffer code body)
    m.funcs;
  let memory = Buffer.create 16 in
  if m.memory > 0 then begin
    leb_u memory 1;
    Buffer.add_char memory '\x00';
    leb_u memory m.memory
  end;
  let globals = Buffer.create 64 in
  leb_u globals (List.length m.globals);
  List.iter
    (fun (v, mutable_) ->
      valtype_byte globals v;
      Buffer.add_char globals (if mutable_ then '\x01' else '\x00');
      (* const init: zero/null *)
      match v with
      | I32 ->
          Buffer.add_char globals '\x41';
          leb_s globals 0;
          Buffer.add_char globals '\x0b'
      | I64 ->
          Buffer.add_char globals '\x42';
          leb_s64 globals 0L;
          Buffer.add_char globals '\x0b'
      | F64 ->
          Buffer.add_char globals '\x44';
          f64_bytes globals 0.0;
          Buffer.add_char globals '\x0b'
      | RefNull t ->
          Buffer.add_char globals '\xd0';
          heaptype globals t;
          Buffer.add_char globals '\x0b'
      | _ ->
          Buffer.add_char globals '\xd0';
          Buffer.add_char globals '\x6e';
          Buffer.add_char globals '\x0b')
    m.globals;
  let elems = Buffer.create 64 in
  if m.declared_funcs <> [] then begin
    leb_u elems 1;
    (* one element segment *)
    Buffer.add_char elems '\x03';
    (* declarative *)
    Buffer.add_char elems '\x00';
    (* elemkind: funcref *)
    leb_u elems (List.length m.declared_funcs);
    List.iter (leb_u elems) m.declared_funcs
  end;
  let exports = Buffer.create 64 in
  let nexports = List.length m.exports + if m.export_mem then 1 else 0 in
  leb_u exports nexports;
  if m.export_mem then begin
    encode_name exports "mem";
    Buffer.add_char exports '\x02';
    (* memory kind *)
    leb_u exports 0
  end;
  List.iter
    (fun (name, fidx) ->
      encode_name exports name;
      Buffer.add_char exports '\x00';
      leb_u exports fidx)
    m.exports;
  let out = Buffer.create 2048 in
  Buffer.add_string out "\x00asm\x01\x00\x00\x00";
  section out 1 types;
  section out 2 imports;
  section out 3 funcs;
  section out 5 memory;
  section out 6 globals;
  section out 7 exports;
  if m.start >= 0 then begin
    let start = Buffer.create 8 in
    leb_u start m.start;
    section out 8 start
  end;
  section out 9 elems;
  section out 10 code;
  Buffer.contents out
