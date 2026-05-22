;; T.3a-2 echo fixture — WASI `_start` command that reads bytes from
;; guest stdin (fd 0) and writes them back to guest stdout (fd 1).
;; Compiled offline by the operator via:
;;
;;   wasm-tools parse Tests/SenkaniTests/Fixtures/wasm/echo.wat \
;;     -o Tests/SenkaniTests/Fixtures/wasm/echo.wasm
;;
;; Memory layout used by this module:
;;
;;   [0..8)   iovec for fd_read  — buf=64, len=256
;;   [8..12)  *nread (bytes read by fd_read)
;;   [16..24) iovec for fd_write — buf=64, len=*nread
;;   [24..28) *nwritten (bytes written by fd_write)
;;   [64..)   data buffer (up to 256 bytes)

(module
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (func (export "_start")
    ;; iovec for fd_read: buf=64, len=256
    (i32.store (i32.const 0) (i32.const 64))
    (i32.store (i32.const 4) (i32.const 256))

    ;; fd_read(fd=0, iovs=0, iovs_len=1, nread=8)
    (drop (call $fd_read
      (i32.const 0)
      (i32.const 0)
      (i32.const 1)
      (i32.const 8)))

    ;; iovec for fd_write: buf=64, len=*nread
    (i32.store (i32.const 16) (i32.const 64))
    (i32.store (i32.const 20) (i32.load (i32.const 8)))

    ;; fd_write(fd=1, iovs=16, iovs_len=1, nwritten=24)
    (drop (call $fd_write
      (i32.const 1)
      (i32.const 16)
      (i32.const 1)
      (i32.const 24)))
  )
)
