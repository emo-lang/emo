(* The native runtime: everything a compiled Emo program links against —
   dynamic-value helpers, the builtin bridge, process operations, and the
   scheduler hookup. Values are [Emo_eval.value] (the tagged dynamic
   representation); specialized functions use OCaml natives and
   box/unbox at the boundaries. *)

exception Return_signal of Emo_eval.value
(* a non-tail [return] unwinds its function through this *)

exception Arity_error of string

let arity_error name expected got =
  raise
    (Arity_error
       (Printf.sprintf "`%s` expects %d argument%s, got %d" name expected
          (if expected = 1 then "" else "s")
          got))

(* ---- Unboxing ---- *)

let type_error v expected =
  Printf.sprintf "expected %s, got %s" expected (Emo_eval.type_name v)

let unbox_bool v =
  match v with
  | Emo_eval.Bool b -> b
  | other -> failwith (type_error other "Bool")

let unbox_int64 v =
  match v with
  | Emo_eval.Int64 n -> n
  | other -> failwith (type_error other "Int64")

let unbox_float64 v =
  match v with
  | Emo_eval.Float f -> f
  | other -> failwith (type_error other "Float64")

let unbox_string v =
  match v with
  | Emo_eval.String s -> s
  | other -> failwith (type_error other "String")

let unbox_pid v =
  match v with
  | Emo_eval.Pid p -> p
  | other -> failwith (type_error other "Pid")

let unbox_conn v =
  match v with
  | Emo_eval.TcpConn c -> c
  | other -> failwith (type_error other "TcpConn")

let box_int64 n = Emo_eval.Int64 n
let box_float64 f = Emo_eval.Float f
let box_bool b = Emo_eval.Bool b
let box_string s = Emo_eval.String s
let box_char c = Emo_eval.Char c

let bytes_new (v : Emo_eval.value) : Emo_eval.value =
  match v with
  | Emo_eval.Int64 n when n >= 0L ->
      Emo_eval.Bytes (Bytes.make (Int64.to_int n) '\000')
  | Emo_eval.Int64 n ->
      failwith
        (Printf.sprintf "`Bytes.new` needs a non-negative length, got %Ld" n)
  | v -> failwith (type_error v "Int64")

(* ---- Operators (tag-checked, mirroring the evaluator) ---- *)

(* Fixed-width arithmetic wraps in two's complement; Byte, being
   unsigned, wraps modulo 256 — the evaluator's rule, mirrored here. *)
let add a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.add x y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte ((x + y) land 255)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (x +. y)
  | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Float (Int64.to_float x +. y)
  | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Float (x +. Int64.to_float y)
  | Emo_eval.String x, Emo_eval.String y -> Emo_eval.String (x ^ y)
  | _ -> failwith "operator `+` expects two numbers or two strings"

let sub a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.sub x y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte ((x - y) land 255)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (x -. y)
  | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Float (Int64.to_float x -. y)
  | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Float (x -. Int64.to_float y)
  | _ -> failwith "operator `-` expects two numbers"

let mul a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.mul x y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x * y land 255)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (x *. y)
  | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Float (Int64.to_float x *. y)
  | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Float (x *. Int64.to_float y)
  | _ -> failwith "operator `*` expects two numbers"

let div a b =
  match (a, b) with
  | Emo_eval.Int64 _, Emo_eval.Int64 0L -> failwith "division by zero"
  | Emo_eval.Byte _, Emo_eval.Byte 0 -> failwith "division by zero"
  | Emo_eval.Float _, Emo_eval.Float 0.0 -> failwith "division by zero"
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.div x y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x / y)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (x /. y)
  | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Float (Int64.to_float x /. y)
  | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Float (x /. Int64.to_float y)
  | _ -> failwith "operator `/` expects two numbers"

let modulo a b =
  match (a, b) with
  | Emo_eval.Int64 _, Emo_eval.Int64 0L -> failwith "division by zero"
  | Emo_eval.Byte _, Emo_eval.Byte 0 -> failwith "division by zero"
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.rem x y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x mod y)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Float (Float.rem x y)
  | _ -> failwith "operator `%` expects two numbers"

(* Bitwise work is integer work: no float coercion, and out-of-range
   shift counts are an error, never a silent platform wrap. *)
let shift_count = function
  | Emo_eval.Int64 y when y >= 0L -> Int64.to_int y
  | v -> failwith (type_error v "non-negative shift count")

let bit_and a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.logand x y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x land y)
  | _ -> failwith (type_error a "two Int64s or two Bytes")

let bit_or a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.logor x y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x lor y)
  | _ -> failwith (type_error a "two Int64s or two Bytes")

let bit_xor a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Int64 (Int64.logxor x y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Byte (x lxor y)
  | _ -> failwith (type_error a "two Int64s or two Bytes")

(* Fixed-width shift counts are their own width; the count saturates at
   the width, matching the evaluator. *)
let shl a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 c ->
      if c < 0L then failwith "shift count must be non-negative"
      else if c >= 64L then Emo_eval.Int64 0L
      else Emo_eval.Int64 (Int64.shift_left x (Int64.to_int c))
  | Emo_eval.Byte x, Emo_eval.Byte c ->
      if c >= 8 then Emo_eval.Byte 0 else Emo_eval.Byte ((x lsl c) land 255)
  | _ -> failwith (type_error a "two Int64s or two Bytes")

let shr a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 c ->
      if c < 0L then failwith "shift count must be non-negative"
      else if c >= 64L then Emo_eval.Int64 (if x < 0L then -1L else 0L)
      else Emo_eval.Int64 (Int64.shift_right x (Int64.to_int c))
  | Emo_eval.Byte x, Emo_eval.Byte c ->
      if c >= 8 then Emo_eval.Byte 0 else Emo_eval.Byte (x lsr c)
  | _ -> failwith (type_error a "two Int64s or two Bytes")

let bit_not = function
  | Emo_eval.Int64 x -> Emo_eval.Int64 (Int64.lognot x)
  | Emo_eval.Byte x -> Emo_eval.Byte (lnot x land 255)
  | v -> failwith (type_error v "Int64")

(* Native-int shifts for the specialized path: the operands are already
   unboxed, so the guard must live here rather than in emitted code. *)
let shl_int (x : int) (count : int) : int =
  if count < 0 then failwith "shift count must be non-negative"
  else if count >= 63 then 0
  else x lsl count

(* 64-bit shifts for the specialized path's boxed Int64.t. *)
let shl_i64 (x : int64) (count : int64) : int64 =
  let c = Int64.to_int count in
  if c < 0 then failwith "shift count must be non-negative"
  else if c >= 64 then 0L
  else Int64.shift_left x c

let shr_i64 (x : int64) (count : int64) : int64 =
  let c = Int64.to_int count in
  if c < 0 then failwith "shift count must be non-negative"
  else if c >= 64 then if x < 0L then -1L else 0L
  else Int64.shift_right x c

let shr_int (x : int) (count : int) : int =
  if count < 0 then failwith "shift count must be non-negative"
  else if count >= 63 then if x < 0 then -1 else 0
  else x asr count

let lt a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Bool (x < y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Bool (x < y)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Bool (x < y)
  | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Bool (Int64.to_float x < y)
  | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Bool (x < Int64.to_float y)
  | _ -> failwith "operator `<` expects two numbers"

let le a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Bool (x <= y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Bool (x <= y)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Bool (x <= y)
  | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Bool (Int64.to_float x <= y)
  | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Bool (x <= Int64.to_float y)
  | _ -> failwith "operator `<=` expects two numbers"

let gt a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Bool (x > y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Bool (x > y)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Bool (x > y)
  | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Bool (Int64.to_float x > y)
  | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Bool (x > Int64.to_float y)
  | _ -> failwith "operator `>` expects two numbers"

let ge a b =
  match (a, b) with
  | Emo_eval.Int64 x, Emo_eval.Int64 y -> Emo_eval.Bool (x >= y)
  | Emo_eval.Byte x, Emo_eval.Byte y -> Emo_eval.Bool (x >= y)
  | Emo_eval.Float x, Emo_eval.Float y -> Emo_eval.Bool (x >= y)
  | Emo_eval.Int64 x, Emo_eval.Float y -> Emo_eval.Bool (Int64.to_float x >= y)
  | Emo_eval.Float x, Emo_eval.Int64 y -> Emo_eval.Bool (x >= Int64.to_float y)
  | _ -> failwith "operator `>=` expects two numbers"

let eq a b = Emo_eval.Bool (Emo_eval.equal_value a b)
let ne a b = Emo_eval.Bool (not (Emo_eval.equal_value a b))
let and_ a b = Emo_eval.Bool (if unbox_bool a then unbox_bool b else false)
let or_ a b = Emo_eval.Bool (if unbox_bool a then true else unbox_bool b)
let not_ v = Emo_eval.Bool (not (unbox_bool v))
let no_return () = failwith "reached the end of a function without `return`"

let case_error v =
  failwith
    (Printf.sprintf "no `case` branch matched this %s value"
       (Emo_eval.type_name v))

let neg v = Emo_eval.Int64 (Int64.neg (unbox_int64 v))

let negf v =
  match v with
  | Emo_eval.Float f -> Emo_eval.Float (-.f)
  | Emo_eval.Int64 n -> Emo_eval.Int64 (Int64.neg n)
  | other -> failwith (type_error other "number")

(* ---- Objects and values ---- *)

let new_obj name methods =
  (* Returns the [obj_handle] so the constructor can wrap it once; call
     [Emo_eval.Obj] on the result. *)
  Emo_eval.new_obj name methods

let obj_set_field self name v =
  match self with
  | Emo_eval.Obj o -> Emo_eval.obj_set_field o name v
  | other -> failwith (type_error other "an object under construction")

let field obj name =
  match obj with
  | Emo_eval.Obj o -> (
      match List.assoc_opt name o.Emo_eval.ofields with
      | Some v -> v
      | None -> failwith (Printf.sprintf "`%s` has no field `%s`" o.ocname name)
      )
  | Emo_eval.Instance i -> (
      match List.assoc_opt name i.Emo_eval.ifields with
      | Some v -> v
      | None ->
          failwith
            (Printf.sprintf "`%s` has no field `%s`" i.Emo_eval.iclass.cname
               name))
  | other -> failwith (type_error other "an instance")

let exception_new (message : Emo_eval.value) : Emo_eval.value =
  let exception_class =
    {
      Emo_eval.cname = "Exception";
      cinit = None;
      cmethods = [];
      builtin_exception = true;
    }
  in
  Emo_eval.Instance
    { iclass = exception_class; ifields = [ ("message", message) ] }

let box_new v = Emo_eval.Box (ref v)

let index collection i =
  match (collection, i) with
  | Emo_eval.Array xs, Emo_eval.Int64 n ->
      if n >= 0L && n < Int64.of_int (Array.length xs) then xs.(Int64.to_int n)
      else failwith (Printf.sprintf "index %Ld is out of bounds" n)
  | Emo_eval.Tuple xs, Emo_eval.Int64 n ->
      if n >= 0L && n < Int64.of_int (List.length xs) then
        List.nth xs (Int64.to_int n)
      else failwith (Printf.sprintf "index %Ld is out of bounds" n)
  | _ -> failwith "indexing expects an Array or Tuple and an Int64"

let interpolate parts =
  Emo_eval.String
    (String.concat "" (List.map (fun p -> Emo_eval.to_string p) parts))

(* ---- Method dispatch: the shared native methods over values ---- *)

let method_call self name args =
  let argc = List.length args in
  let none_expected () =
    if argc <> 0 then
      failwith (Printf.sprintf "`%s` expects no arguments, got %d" name argc)
  in
  let one_expected () =
    if argc <> 1 then
      failwith (Printf.sprintf "`%s` expects 1 argument, got %d" name argc)
  in
  match (self, name) with
  | Emo_eval.Bytes b, "to_string" ->
      none_expected ();
      Emo_eval.String (Bytes.to_string b)
  | Emo_eval.Bytes b, "length" ->
      none_expected ();
      Emo_eval.Int64 (Int64.of_int (Bytes.length b))
  | Emo_eval.Bytes b, "get" -> (
      one_expected ();
      match args with
      | [ Emo_eval.Int64 i ] when i >= 0L && i < Int64.of_int (Bytes.length b)
        ->
          Emo_eval.Int64
            (Int64.of_int (Char.code (Bytes.get b (Int64.to_int i))))
      | [ Emo_eval.Int64 i ] ->
          failwith
            (Printf.sprintf "index %Ld is out of bounds for a length-%d Bytes" i
               (Bytes.length b))
      | [ v ] -> failwith (type_error v "Int64")
      | _ -> failwith "`get` expects 1 argument")
  | Emo_eval.Bytes b, "set" -> (
      if argc <> 2 then failwith "`set` expects 2 arguments";
      match args with
      | [ Emo_eval.Int64 i; Emo_eval.Int64 v ]
        when i >= 0L && i < Int64.of_int (Bytes.length b) ->
          if v < 0L || v > 255L then
            failwith
              (Printf.sprintf
                 "byte value %Ld is out of range for a byte (0-255)" v);
          Bytes.set b (Int64.to_int i) (Char.chr (Int64.to_int v));
          Emo_eval.Int64 v
      | [ Emo_eval.Int64 i; Emo_eval.Int64 _ ] ->
          failwith
            (Printf.sprintf "index %Ld is out of bounds for a length-%d Bytes" i
               (Bytes.length b))
      | _ -> failwith "`set` expects (i Int64, v Int64)")
  | Emo_eval.Bytes b, (("get_u16_le" | "get_u32_le") as mname) -> (
      one_expected ();
      let width = if mname = "get_u16_le" then 2 else 4 in
      match args with
      | [ Emo_eval.Int64 i ]
        when i >= 0L
             && Int64.add i (Int64.of_int width)
                <= Int64.of_int (Bytes.length b) ->
          let i = Int64.to_int i in
          let acc = ref 0 in
          for k = width - 1 downto 0 do
            acc := (!acc lsl 8) lor Char.code (Bytes.get b (i + k))
          done;
          Emo_eval.Int64 (Int64.of_int !acc)
      | [ Emo_eval.Int64 i ] ->
          failwith
            (Printf.sprintf
               "index %Ld is out of bounds for a %s read on a length-%d Bytes" i
               mname (Bytes.length b))
      | [ v ] -> failwith (type_error v "Int64")
      | _ -> failwith "`get_u16_le`/`get_u32_le` expects 1 argument")
  | Emo_eval.Bytes b, (("set_u16_le" | "set_u32_le") as mname) -> (
      if argc <> 2 then failwith "`set_u16_le`/`set_u32_le` expects 2 arguments";
      let width = if mname = "set_u16_le" then 2 else 4 in
      let max = if width = 2 then 0xFFFF else 0xFFFFFFFF in
      match args with
      | [ Emo_eval.Int64 i; Emo_eval.Int64 v ]
        when i >= 0L
             && Int64.add i (Int64.of_int width)
                <= Int64.of_int (Bytes.length b) ->
          let i = Int64.to_int i in
          let v = Int64.to_int v land max in
          for k = 0 to width - 1 do
            Bytes.set b (i + k) (Char.chr ((v lsr (8 * k)) land 0xFF))
          done;
          Emo_eval.Int64 (Int64.of_int v)
      | [ Emo_eval.Int64 i; Emo_eval.Int64 _ ] ->
          failwith
            (Printf.sprintf
               "index %Ld is out of bounds for a %s write on a length-%d Bytes"
               i mname (Bytes.length b))
      | _ -> failwith "`set_u16_le`/`set_u32_le` expects (i Int64, v Int64)")
  | Emo_eval.Bytes b, "get_u64_le" -> (
      one_expected ();
      match args with
      | [ Emo_eval.Int64 i ]
        when i >= 0L && Int64.add i 8L <= Int64.of_int (Bytes.length b) ->
          let i = Int64.to_int i in
          let acc = ref 0L in
          for k = 7 downto 0 do
            acc :=
              Int64.logor (Int64.shift_left !acc 8)
                (Int64.of_int (Char.code (Bytes.get b (i + k))))
          done;
          Emo_eval.Int64 !acc
      | [ Emo_eval.Int64 i ] ->
          failwith
            (Printf.sprintf
               "index %Ld is out of bounds for a get_u64_le read on a \
                length-%d Bytes"
               i (Bytes.length b))
      | [ v ] -> failwith (type_error v "Int64")
      | _ -> failwith "`get_u64_le` expects 1 argument")
  | Emo_eval.Bytes b, "set_u64_le" -> (
      if argc <> 2 then failwith "`set_u64_le` expects 2 arguments";
      match args with
      | [ Emo_eval.Int64 i; Emo_eval.Int64 v ]
        when i >= 0L && Int64.add i 8L <= Int64.of_int (Bytes.length b) ->
          let i = Int64.to_int i in
          for k = 0 to 7 do
            Bytes.set b (i + k)
              (Char.chr
                 (Int64.to_int
                    (Int64.logand (Int64.shift_right_logical v (8 * k)) 0xFFL)))
          done;
          Emo_eval.Int64 v
      | [ Emo_eval.Int64 i; Emo_eval.Int64 _ ] ->
          failwith
            (Printf.sprintf
               "index %Ld is out of bounds for a set_u64_le write on a \
                length-%d Bytes"
               i (Bytes.length b))
      | [ _; v ] -> failwith (type_error v "Int64")
      | _ -> failwith "`set_u64_le` expects (i Int64, v Int64)")
  | Emo_eval.String s, "to_bytes" ->
      none_expected ();
      Emo_eval.Bytes (Bytes.of_string s)
  | Emo_eval.TypeValue "Byte", "from_int64" -> (
      one_expected ();
      match List.hd args with
      | Emo_eval.Int64 n when n >= 0L && n <= 255L ->
          Emo_eval.Byte (Int64.to_int n)
      | Emo_eval.Int64 n ->
          failwith
            (Printf.sprintf "`Byte.from_int64` needs a value in 0-255, got %Ld"
               n)
      | v -> failwith (type_error v "Int64"))
  | Emo_eval.TypeValue "Float64", "from_bits" -> (
      one_expected ();
      match List.hd args with
      | Emo_eval.Int64 b -> Emo_eval.Float (Int64.float_of_bits b)
      | v -> failwith (type_error v "Int64"))
  | Emo_eval.Int64 x, "to_byte" ->
      none_expected ();
      Emo_eval.Byte (Int64.to_int (Int64.logand x 255L))
  | Emo_eval.Byte n, "to_int64" ->
      none_expected ();
      Emo_eval.Int64 (Int64.of_int n)
  | Emo_eval.Float f, "to_bits" ->
      none_expected ();
      Emo_eval.Int64 (Int64.bits_of_float f)
  | Emo_eval.Float f, "sqrt" ->
      none_expected ();
      Emo_eval.Float (Float.sqrt f)
  | Emo_eval.Float f, "floor" ->
      none_expected ();
      Emo_eval.Float (Float.floor f)
  | Emo_eval.Float f, "ceil" ->
      none_expected ();
      Emo_eval.Float (Float.ceil f)
  | Emo_eval.Float f, "trunc" ->
      none_expected ();
      Emo_eval.Float (Float.trunc f)
  | Emo_eval.Float f, "to_int64" ->
      none_expected ();
      Emo_eval.Int64 (Int64.of_float f)
  | Emo_eval.Int64 n, "to_float64" ->
      none_expected ();
      Emo_eval.Float (Int64.to_float n)
  | _, "to_string" ->
      none_expected ();
      Emo_eval.String (Emo_eval.to_string self)
  | _, "is" ->
      one_expected ();
      let target = List.hd args in
      Emo_eval.Bool
        (try Emo_eval.runtime_is Emo_support.Span.zero self target
         with Emo_eval.Error _ ->
           failwith "`is` checks instances and enum members, not this value")
  | Emo_eval.Array xs, "length" ->
      none_expected ();
      Emo_eval.Int64 (Int64.of_int (Array.length xs))
  | Emo_eval.Tuple xs, "length" ->
      none_expected ();
      Emo_eval.Int64 (Int64.of_int (List.length xs))
  | Emo_eval.String s, "length" ->
      none_expected ();
      Emo_eval.Int64 (Int64.of_int (String.length s))
  | Emo_eval.String s, "substring" -> (
      match args with
      | [ Emo_eval.Int64 start; Emo_eval.Int64 len ]
        when start >= 0L && len >= 0L
             && Int64.add start len <= Int64.of_int (String.length s) ->
          Emo_eval.String (String.sub s (Int64.to_int start) (Int64.to_int len))
      | _ ->
          failwith "`substring` expects (start Int64, length Int64) in bounds")
  | Emo_eval.String s, "split" -> (
      one_expected ();
      match List.hd args with
      | Emo_eval.String sep when sep <> "" ->
          let rec split_at from acc =
            match
              let rec find j =
                if j + String.length sep > String.length s then None
                else if String.sub s j (String.length sep) = sep then Some j
                else find (j + 1)
              in
              find from
            with
            | Some j ->
                split_at
                  (j + String.length sep)
                  (Emo_eval.String (String.sub s from (j - from)) :: acc)
            | None ->
                List.rev
                  (Emo_eval.String (String.sub s from (String.length s - from))
                  :: acc)
          in
          Emo_eval.Array (Array.of_list (split_at 0 []))
      | _ -> failwith "`split` expects a non-empty String separator")
  | Emo_eval.String s, "trim" ->
      none_expected ();
      Emo_eval.String (String.trim s)
  | Emo_eval.String s, "lower" ->
      none_expected ();
      Emo_eval.String (String.lowercase_ascii s)
  | Emo_eval.String s, "index_of" -> (
      one_expected ();
      match List.hd args with
      | Emo_eval.String needle ->
          let rec find i =
            if i + String.length needle > String.length s then None
            else if String.sub s i (String.length needle) = needle then Some i
            else find (i + 1)
          in
          Emo_eval.Int64
            (Int64.of_int (match find 0 with Some i -> i | None -> -1))
      | _ -> failwith "`index_of` expects a String")
  | Emo_eval.String s, "starts_with" -> (
      one_expected ();
      match List.hd args with
      | Emo_eval.String prefix -> Emo_eval.Bool (String.starts_with ~prefix s)
      | _ -> failwith "`starts_with` expects a String")
  | Emo_eval.String s, "to_int64" -> (
      none_expected ();
      let body =
        if String.length s > 0 && s.[0] = '-' then
          String.sub s 1 (String.length s - 1)
        else s
      in
      if body = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') body)
      then failwith (Printf.sprintf "cannot parse `%s` as an Int64" s)
      else
        match Int64.of_string_opt s with
        | Some n -> Emo_eval.Int64 n
        | None -> failwith (Printf.sprintf "cannot parse `%s` as an Int64" s))
  | Emo_eval.Array xs, "append" ->
      one_expected ();
      Emo_eval.Array (Array.append xs [| List.hd args |])
  | Emo_eval.Box r, "read" ->
      none_expected ();
      !r
  | Emo_eval.Box r, "replace" ->
      one_expected ();
      let v = List.hd args in
      r := v;
      v
  | Emo_eval.TcpConn c, "read_line" ->
      none_expected ();
      Emo_eval.String (Emo_eval.read_line_sync c)
  | Emo_eval.TcpConn c, "read_exactly" -> (
      one_expected ();
      match List.hd args with
      | Emo_eval.Int64 n ->
          Emo_eval.String (Emo_eval.read_exactly_sync c (Int64.to_int n))
      | _ -> failwith "`read_exactly` expects an Int64")
  | Emo_eval.TcpConn c, "read_all" ->
      none_expected ();
      Emo_eval.String (Emo_eval.read_all_sync c)
  | Emo_eval.TcpConn c, "write" -> (
      one_expected ();
      match List.hd args with
      | Emo_eval.String data ->
          Emo_eval.write_sync c data;
          self
      | _ -> failwith "`write` expects a String")
  | Emo_eval.TcpConn c, "close" ->
      none_expected ();
      Emo_eval.TcpConn (Emo_eval.close_sync c)
  | Emo_eval.TcpConn c, "set_timeout" -> (
      one_expected ();
      match List.hd args with
      | Emo_eval.Float f ->
          c.Emo_eval.ctimeout <- f;
          self
      | _ -> failwith "`set_timeout` expects a Float64")
  | Emo_eval.TcpListener l, "accept" ->
      none_expected ();
      Emo_eval.TcpConn (Emo_eval.accept_sync l)
  | Emo_eval.TcpListener l, "port" ->
      none_expected ();
      Emo_eval.Int64 (Int64.of_int l.Emo_eval.lport)
  | Emo_eval.TcpListener l, "close" ->
      none_expected ();
      Emo_eval.TcpListener (Emo_eval.close_listener_sync l)
  | Emo_eval.UdpSocket u, "send_to" -> (
      match args with
      | [ Emo_eval.String host; Emo_eval.Int64 port; Emo_eval.String data ] ->
          Emo_eval.udp_send_sync u host (Int64.to_int port) data;
          self
      | _ -> failwith "`send_to` expects (host, port, data)")
  | Emo_eval.UdpSocket u, "recv_from" ->
      none_expected ();
      Emo_eval.udp_recv_sync u
  | Emo_eval.UdpSocket u, "port" ->
      none_expected ();
      Emo_eval.Int64 (Int64.of_int u.Emo_eval.uport)
  | Emo_eval.UdpSocket u, "close" ->
      none_expected ();
      Emo_eval.UdpSocket (Emo_eval.udp_close_sync u)
  | _ -> (
      (* Compiled objects dispatch through their table; everything else
         is NoMethodError. *)
      match self with
      | Emo_eval.Obj o -> (
          match Hashtbl.find_opt o.Emo_eval.omethods name with
          (* Compiled class methods take [self] first; the table's arity
             counts the declared parameters only. *)
          | Some (_arity, f) -> f (self :: args)
          | None ->
              failwith
                (Printf.sprintf "NoMethodError: `%s` has no method `%s`"
                   o.ocname name))
      | _ ->
          failwith
            (Printf.sprintf "NoMethodError: `%s` has no method `%s`"
               (Emo_eval.type_name self) name))

(* First-class functions (compiled blocks and defs passed around). *)
let apply_value f args =
  match f with
  | Emo_eval.CompiledFn c -> c.Emo_eval.fapply args
  | _ -> failwith "calling a non-function"

(* ---- Process operations ---- *)

let self_pid () =
  Emo_eval.Int64 (Int64.of_int (Effect.perform Emo_eval.Self_pid))

(* Spawns a process whose arguments were evaluated eagerly in the
   spawning process — `do f(x)` reads x where the spawn appears, like
   the interpreter. *)
let spawn_args (vals : Emo_eval.value list) (f : Emo_eval.value list -> unit) :
    Emo_eval.value =
  let thunk () = ignore (f vals) in
  let nowhere = Emo_support.Span.zero in
  let pid = Effect.perform (Emo_eval.Spawn (thunk, nowhere)) in
  Emo_eval.Pid pid

let spawn (thunk : unit -> unit) : Emo_eval.value =
  let nowhere = Emo_support.Span.zero in
  let pid = Effect.perform (Emo_eval.Spawn (thunk, nowhere)) in
  Emo_eval.Pid pid

let send (pid_value : Emo_eval.value) (message : Emo_eval.value) : unit =
  let pid = unbox_pid pid_value in
  let nowhere = Emo_support.Span.zero in
  Effect.perform (Emo_eval.Send (pid, message, nowhere))

let receive
    (matchers : (Emo_eval.value -> (int * Emo_eval.value list) option) list) :
    int * Emo_eval.value list =
  (* Each branch matcher already tags its own index; the first branch
     that accepts the message decides. *)
  let matcher v =
    let rec try_branch = function
      | [] -> None
      | m :: rest -> (
          match m v with Some picked -> Some picked | None -> try_branch rest)
    in
    try_branch matchers
  in
  (Effect.perform (Emo_eval.Compiled_receive matcher)
    : int * Emo_eval.value list)

(* The items a receive branch's pattern binds against: tuple elements,
   array elements, or the value itself. *)
let payload_items (v : Emo_eval.value) : Emo_eval.value list =
  match v with
  | Emo_eval.Tuple xs -> xs
  | Emo_eval.Array xs -> Array.to_list xs
  | other -> [ other ]

(* Binds a receive payload's items: [f] receives the items as a list the
   emitter destructures with an exhaustive pattern (it knows the
   branch's own arity). *)
let bind_items (v : Emo_eval.value) (f : Emo_eval.value list -> 'a) : 'a =
  f (payload_items v)

let raise_ v =
  let nowhere = Emo_support.Span.zero in
  raise (Emo_eval.Emo_raise (v, nowhere, []))

let halt () = raise Emo_eval.Halt_signal

(* ---- The scheduler hookup ---- *)

(* Registers an interface for the runtime's structural is(). *)
let register_interface name methods =
  Hashtbl.replace Emo_eval.interface_registry name methods

(* Runs the program's root process on the own scheduler; output streams
   to stdout like `emo run`. *)
let run (body : unit -> unit) : int =
  Emo_eval.set_output (fun s ->
      print_string s;
      flush stdout);
  try
    ignore (Emo_sched_det.run ~log_events:false body);
    0
  with
  | Emo_eval.Error diagnostic ->
      Printf.eprintf "error[%s]: %s\n%!"
        (match diagnostic.Emo_support.Diagnostic.code with
        | Some c -> c
        | None -> "?")
        diagnostic.Emo_support.Diagnostic.message;
      70
  | Emo_eval.Emo_raise (v, _span, _trace) ->
      Printf.eprintf "uncaught exception: %s\n%!" (Emo_eval.to_string v);
      1
