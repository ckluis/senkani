;; T.3a-5 fuel-exhaustion fixture — WASI `_start` that runs a tight
;; infinite loop of `i32.mul` instructions. With a small `-W fuel=N`
;; budget the wasmtime subprocess exhausts fuel within a few thousand
;; ops and exits with stderr containing "fuel".
;;
;; Compile offline:
;;   wasm-tools parse fuel-loop-mul.wat -o fuel-loop-mul.wasm

(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i32)
    (local.set $i (i32.const 1))
    (loop $burn
      (local.set $i (i32.mul (local.get $i) (i32.const 3)))
      (br $burn)
    )
  )
)
