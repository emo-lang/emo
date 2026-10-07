(* Reference for benchmarks/loops_tail: the same tail-recursive counter
   in plain OCaml, which optimizes the tail call. *)
let rec spin n acc = if n = 0 then acc else spin (n - 1) (acc + 1)
let () = Printf.printf "%d\n" (spin 10000000 0)
