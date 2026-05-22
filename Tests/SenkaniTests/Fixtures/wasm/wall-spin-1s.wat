;; T.3a-5 wall-clock-exhaustion fixture — WASI `_start` that busy-spins
;; via a bounded outer loop that counts to a large constant. The
;; constant is sized so that with a HIGH fuel budget but LOW
;; `-W timeout=Nms` budget, the wall-clock deadline fires first and
;; the runtime classifies the kill as `WasmKillReason.epoch` (either
;; via wasmtime's own interrupt → "interrupt"/"timeout" stderr OR the
;; host DispatchSource watchdog → SIGTERM at epoch+50ms).
;;
;; "1s" is a label only — the actual wall-clock budget is set by the
;; caller. Fixture sizing matches the other wall-spin variants so
;; tests share a single per-fixture iteration count.
;;
;; Compile offline:
;;   wasm-tools parse wall-spin-1s.wat -o wall-spin-1s.wasm

(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i64)
    (local.set $i (i64.const 0))
    (loop $burn
      (local.set $i (i64.add (local.get $i) (i64.const 1)))
      (br $burn)
    )
  )
)
