import Foundation

/// T.3a-4 — classification for a `wasm_kill` chained audit row in
/// `token_events`. Stored as `text` in `wasm_reason` + duplicated into
/// `feature` so existing analytics queries that group by `feature`
/// still surface the kill rate alongside the new column.
///
/// Classification (set by `WasmtimeSubprocessRuntime` on every kill):
/// - `.fuel`: wasmtime stderr contains `"fuel"` (e.g. `"all fuel consumed
///   by WebAssembly"`). The soft fuel cap inside wasmtime
///   (`-W fuel=N`) self-terminated the guest.
/// - `.epoch`: wasmtime stderr contains `"interrupt"`/`"timeout"`/
///   `"epoch"`, OR the host-side `DispatchSourceTimer` watchdog from
///   T.3a-3 fired SIGTERM/SIGKILL because the guest exceeded the
///   wall-clock budget (`-W timeout=Nms`).
/// - `.escape`: wasmtime stderr indicates a denied WASI capability
///   (e.g. `"wasi: permission denied"`, `"unknown import"` against a
///   guarded function). The guest attempted a host syscall outside
///   the manifest's capability surface.
/// - `.crash`: abnormal exit without a recognised fuel/epoch/escape
///   signal. Catches wasmtime panics, OS-level signals from outside
///   the watchdog, and any future error class the heuristic hasn't
///   learned yet.
///
/// The raw value strings are stored in the database — never rename a
/// case without a migration that backfills historic rows.
public enum WasmKillReason: String, Sendable, Codable, Equatable {
    case fuel
    case epoch
    case escape
    case crash
}
