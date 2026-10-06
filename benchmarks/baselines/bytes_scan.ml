(* Reference for benchmarks/bytes_scan: the same 20M reads in plain OCaml. *)
let buf = Bytes.make 256 '\000'

let rec scan n acc =
  if n = 0 then acc
  else scan (n - 1) (acc + Char.code (Bytes.get buf (n mod 256)))

let () = Printf.printf "%d\n" (scan 20000000 0)
