;; T.3a-5 escape-attempt fixture — WASI `_start` that imports a fake
;; host fork/exec function. wasm has no native fork instruction so we
;; simulate via an unknown-module import; wasmtime refuses, stderr
;; contains "unknown import" → `WasmKillReason.escape`.
;;
;; Compile offline:
;;   wasm-tools parse escape-fork.wat -o escape-fork.wasm

(module
  (import "host_proc" "fork_exec"
    (func $forbidden (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (drop (call $forbidden (i32.const 0) (i32.const 0)))
  )
)
