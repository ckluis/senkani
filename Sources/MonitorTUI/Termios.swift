import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Hand-rolled raw-mode wrapper for `senkani monitor --tui`. Saves
/// the current termios state, applies cbreak + no-echo via `tcsetattr`,
/// runs the supplied closure, and restores the original termios on
/// scope exit — including the SIGINT / SIGTERM paths (handlers
/// installed inside the `withRawMode` block restore termios before
/// re-raising the signal).
///
/// No new SwiftPM dep — Darwin's POSIX termios is sufficient. Per the
/// V.15a-1 / V.15a-2 split-round operator decision (Q3 hand-rolled),
/// MIT-licensing constraints stay trivially satisfied.
///
/// Test-friendly: the `TermiosProvider` protocol lets tests substitute
/// `tcgetattr` / `tcsetattr` with in-memory stubs so the test runner
/// never touches the host TTY.
public protocol TermiosProvider: Sendable {
    /// Capture the current termios state for `fd`. Returns nil if
    /// `fd` is not a TTY or capture failed.
    func getAttributes(fd: Int32) -> termios?
    /// Apply `attributes` to `fd`. Returns true on success.
    func setAttributes(fd: Int32, attributes: termios) -> Bool
    /// True when `fd` references a TTY. `withRawMode` no-ops when
    /// false (pipe-driven CI invocations stay safe).
    func isTTY(fd: Int32) -> Bool
}

public struct DefaultTermiosProvider: TermiosProvider {
    public init() {}
    public func getAttributes(fd: Int32) -> termios? {
        var attrs = termios()
        let rc = tcgetattr(fd, &attrs)
        return rc == 0 ? attrs : nil
    }
    public func setAttributes(fd: Int32, attributes: termios) -> Bool {
        var copy = attributes
        return tcsetattr(fd, TCSANOW, &copy) == 0
    }
    public func isTTY(fd: Int32) -> Bool {
        return isatty(fd) == 1
    }
}

/// Recording provider for tests — captures the call sequence so a
/// unit test can verify `withRawMode` invokes `tcgetattr` → raw apply
/// → user closure → restore.
public final class RecordingTermiosProvider: TermiosProvider, @unchecked Sendable {
    public enum Call: Equatable {
        case get(fd: Int32)
        case set(fd: Int32, isRaw: Bool)
        case isTTY(fd: Int32)
    }
    public private(set) var calls: [Call] = []
    public var pretendIsTTY: Bool = true
    public var savedAttributes: termios = termios()

    public init() {}

    public func getAttributes(fd: Int32) -> termios? {
        calls.append(.get(fd: fd))
        return savedAttributes
    }
    public func setAttributes(fd: Int32, attributes: termios) -> Bool {
        let isRaw = (attributes.c_lflag & UInt(ICANON | ECHO)) == 0
        calls.append(.set(fd: fd, isRaw: isRaw))
        return true
    }
    public func isTTY(fd: Int32) -> Bool {
        calls.append(.isTTY(fd: fd))
        return pretendIsTTY
    }
}

/// Global slot the C-ABI signal handler reads on SIGINT / SIGTERM.
/// `withRawMode` populates the slot on entry and clears it on exit.
/// Lock-protected so concurrent panes don't trample each other,
/// though in practice only one TUI loop runs per process.
nonisolated(unsafe) private var _savedAttributesSlot: termios? = nil
nonisolated(unsafe) private var _savedSlotFD: Int32 = STDIN_FILENO
private let _slotLock = NSLock()

private func setSavedAttributes(_ attrs: termios?, fd: Int32) {
    _slotLock.lock(); defer { _slotLock.unlock() }
    _savedAttributesSlot = attrs
    _savedSlotFD = fd
}

private func currentSavedAttributesPair() -> (termios, Int32)? {
    _slotLock.lock(); defer { _slotLock.unlock() }
    guard let attrs = _savedAttributesSlot else { return nil }
    return (attrs, _savedSlotFD)
}

/// C-ABI signal handler installed inside `withRawMode`. Restores
/// the saved termios from the global slot, then re-raises the signal
/// via the default disposition so the operator's Ctrl-C / kill
/// terminates the process the way they expect.
private let termiosRestoreHandler: @convention(c) (Int32) -> Void = { signo in
    if let pair = currentSavedAttributesPair() {
        var attrs = pair.0
        _ = tcsetattr(pair.1, TCSANOW, &attrs)
    }
    signal(signo, SIG_DFL)
    _ = raise(signo)
}

/// Termios raw-mode primitives + scoped runner.
public enum Termios {
    public static func currentSavedAttributes() -> termios? {
        return currentSavedAttributesPair()?.0
    }

    /// Apply raw mode (cbreak + no-echo) to `fd`, run `body`, and
    /// restore the original attributes. SIGINT / SIGTERM handlers
    /// restore + re-raise to preserve operator's Ctrl-C / kill
    /// behavior without leaving a corrupted terminal.
    ///
    /// When `provider.isTTY(fd:)` returns false (pipe-driven test
    /// invocations, CI), the body still runs but no termios changes
    /// are applied. This keeps the runner safe across CI without
    /// requiring callers to branch.
    @discardableResult
    public static func withRawMode<R>(
        fd: Int32 = STDIN_FILENO,
        provider: TermiosProvider = DefaultTermiosProvider(),
        installSignalHandlers: Bool = true,
        body: () throws -> R
    ) rethrows -> R {
        guard provider.isTTY(fd: fd) else {
            return try body()
        }
        guard let original = provider.getAttributes(fd: fd) else {
            return try body()
        }
        setSavedAttributes(original, fd: fd)

        var raw = original
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        _ = provider.setAttributes(fd: fd, attributes: raw)

        var prevSIGINT: sig_t?
        var prevSIGTERM: sig_t?
        if installSignalHandlers {
            prevSIGINT = signal(SIGINT, termiosRestoreHandler)
            prevSIGTERM = signal(SIGTERM, termiosRestoreHandler)
        }

        defer {
            _ = provider.setAttributes(fd: fd, attributes: original)
            if installSignalHandlers {
                if let prev = prevSIGINT { signal(SIGINT, prev) }
                if let prev = prevSIGTERM { signal(SIGTERM, prev) }
            }
            setSavedAttributes(nil, fd: fd)
        }

        return try body()
    }
}
