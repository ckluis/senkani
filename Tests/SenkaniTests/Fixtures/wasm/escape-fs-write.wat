;; T.3a-5 escape-attempt fixture — WASI `_start` that imports a fake
;; host filesystem write function from an unknown module. wasmtime
;; default-deny posture refuses to provide this import; instantiation
;; fails with stderr containing "unknown import" which the runtime
;; classifier maps to `WasmKillReason.escape`.
;;
;; This pattern is endorsed by the parent item's `## Notes`: "the
;; fixtures simulate these by attempting WASI `proc_exec`-like
;; imports that wasmtime's default sandbox doesn't provide. The test
;; just asserts the imports fail at instantiation or first call."
;;
;; Compile offline:
;;   wasm-tools parse escape-fs-write.wat -o escape-fs-write.wasm

(module
  (import "host_fs" "write_anywhere"
    (func $forbidden (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (drop (call $forbidden (i32.const 0) (i32.const 16)))
  )
)
