;; T.3a-5 wall-clock-exhaustion fixture — WASI `_start` running a
;; pure-arithmetic counter with mixed i32/i64 ops to vary the mix
;; from the other wall-spin variants. Same `epoch`-kill behavior.
;;
;; Compile offline:
;;   wasm-tools parse wall-spin-counter.wat -o wall-spin-counter.wasm

(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i32)
    (local $j i64)
    (local.set $i (i32.const 0))
    (local.set $j (i64.const 0))
    (loop $burn
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (local.set $j (i64.add (local.get $j) (i64.extend_i32_u (local.get $i))))
      (br $burn)
    )
  )
)
