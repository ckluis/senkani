;; T.3a-5 escape-attempt fixture — WASI `_start` that imports a fake
;; host dynamic-linker `dlopen` function. wasm has no native dlopen
;; instruction; we simulate via an unknown-module import. wasmtime
;; refuses, stderr contains "unknown import" → `WasmKillReason.escape`.
;;
;; Compile offline:
;;   wasm-tools parse escape-dlopen.wat -o escape-dlopen.wasm

(module
  (import "host_dyn" "dlopen"
    (func $forbidden (param i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (drop (call $forbidden (i32.const 0)))
  )
)
