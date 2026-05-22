;; T.3a-5 fuel-exhaustion fixture — WASI `_start` that calls a chain
;; of helper funcs in a tight loop. Each iteration walks the chain so
;; fuel covers both `call` overhead and arithmetic. A small
;; `-W fuel=N` budget exhausts quickly.
;;
;; Compile offline:
;;   wasm-tools parse fuel-call-deep.wat -o fuel-call-deep.wasm

(module
  (memory (export "memory") 1)
  (func $a (param $x i32) (result i32)
    (i32.add (local.get $x) (i32.const 1))
  )
  (func $b (param $x i32) (result i32)
    (call $a (i32.add (local.get $x) (i32.const 1)))
  )
  (func $c (param $x i32) (result i32)
    (call $b (i32.add (local.get $x) (i32.const 1)))
  )
  (func $d (param $x i32) (result i32)
    (call $c (i32.add (local.get $x) (i32.const 1)))
  )
  (func (export "_start")
    (local $i i32)
    (local.set $i (i32.const 0))
    (loop $burn
      (local.set $i (call $d (local.get $i)))
      (br $burn)
    )
  )
)
