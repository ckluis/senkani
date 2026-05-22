;; T.3a-5 wall-clock-exhaustion fixture — WASI `_start` busy-spinning
;; on i64 arithmetic. Counterpart to wall-spin-1s.wat; the label
;; reflects intent only, the test caller sets the actual epoch budget.
;;
;; Compile offline:
;;   wasm-tools parse wall-spin-2s.wat -o wall-spin-2s.wasm

(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i64)
    (local.set $i (i64.const 7))
    (loop $burn
      (local.set $i (i64.mul (local.get $i) (i64.const 1000003)))
      (br $burn)
    )
  )
)
