;; T.3a-5 wall-clock-exhaustion fixture — WASI `_start` with two
;; nested loops to vary the instruction mix from wall-spin-1s /
;; wall-spin-2s. Same `epoch`-kill behavior under a high-fuel /
;; low-epoch budget.
;;
;; Compile offline:
;;   wasm-tools parse wall-spin-loop.wat -o wall-spin-loop.wasm

(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i64)
    (local $j i64)
    (local.set $i (i64.const 0))
    (loop $outer
      (local.set $j (i64.const 0))
      (loop $inner
        (local.set $j (i64.add (local.get $j) (i64.const 1)))
        (br_if $inner (i64.ne (local.get $j) (i64.const 1024)))
      )
      (local.set $i (i64.add (local.get $i) (i64.const 1)))
      (br $outer)
    )
  )
)
