;; T.3a-5 escape-attempt fixture — WASI `_start` that imports a fake
;; host network-connect function from an unknown module. wasmtime
;; refuses to provide the import; instantiation fails with stderr
;; containing "unknown import" → `WasmKillReason.escape`.
;;
;; Compile offline:
;;   wasm-tools parse escape-net-connect.wat -o escape-net-connect.wasm

(module
  (import "host_net" "tcp_connect"
    (func $forbidden (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (drop (call $forbidden (i32.const 0) (i32.const 0) (i32.const 80)))
  )
)
