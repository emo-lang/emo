(component
  ;; The gate probe (2026-11-15): the waitable-set machinery alone —
  ;; new, drop, and the synchronous wait — with none of the gated
  ;; sync stream/future read/write builtins. Compiles and validates
  ;; under stock `wasmtime compile` with NO feature flags (49.0.1),
  ;; which pins the two facts the gate decision rides on: the
  ;; waitable-set core builtins are ungated, and the synchronous
  ;; wait lowers to (param i32 i32) -> i32 under a (memory) option.
  ;; The guest never runs; the component is compile-only.
  (core module $m (memory (export "memory") 1))
  (core instance $i (instantiate $m))
  (alias core export $i "memory" (core memory $mem))
  (core func $ws-new (canon waitable-set.new))
  (core func $ws-drop (canon waitable-set.drop))
  (core func $ws-wait (canon waitable-set.wait (memory $mem)))
  (core instance $host
    (export "ws-new" (func $ws-new))
    (export "ws-drop" (func $ws-drop))
    (export "ws-wait" (func $ws-wait))
  )
  (core module $g
    (import "new-mod" "ws-new" (func $new (result i32)))
    (import "drop-mod" "ws-drop" (func $drop (param i32)))
    (import "wait-mod" "ws-wait" (func $wait (param i32 i32) (result i32)))
    (func (export "run")
      call $new
      call $drop
    )
  )
  (core instance $h-new (export "ws-new" (func $ws-new)))
  (core instance $h-drop
    (export "ws-drop" (func $ws-drop))
    (export "ws-wait" (func $ws-wait))
  )
  (core instance $g-i (instantiate $g
    (with "new-mod" (instance $h-new))
    (with "drop-mod" (instance $h-drop))
    (with "wait-mod" (instance $h-drop))))
  (alias core export $g-i "run" (core func $run))
  (type $rt (func))
  (func $run-lifted (type $rt) (canon lift (core func $run)))
  (instance $run-i (export "run" (func $run-lifted)))
  (export "run" (instance $run-i))
)
