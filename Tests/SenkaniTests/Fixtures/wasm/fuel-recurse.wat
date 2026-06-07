;; T.3a-5 fuel-exhaustion fixture — WASI `_start` that drives an
;; unbounded self-call loop (tail-position recursion via `call` from
;; inside a `loop`). Each iteration consumes call-frame + arithmetic
;; fuel; a small `-W fuel=N` budget exhausts well before any wasm
;; stack overflow trap.
;;
;; Compile offline:
;;   wasm-tools parse fuel-recurse.wat -o fuel-recurse.wasm

(module
  (memory (export "memory") 1)
  (func $burn (param $n i32) (result i32)
    (local $acc i32)
    (local.set $acc (local.get $n))
    (loop $spin
      (local.set $acc (i32.add (local.get $acc) (i32.const 1)))
      (br $spin)
    )
    (local.get $acc)
  )
  (func (export "_start")
    (drop (call $burn (i32.const 0)))
  )
)
