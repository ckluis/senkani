import Foundation

/// A complete dashboard frame ready to paint. Composed of ordered
/// `Region`s. `toANSI()` emits a deterministic, full-clear-and-paint
/// ANSI string — same input twice yields byte-identical output.
public struct RenderFrame: Sendable, Equatable {
    public let regions: [Region]

    public init(regions: [Region]) {
        self.regions = regions
    }

    /// Emit the full-clear-and-paint ANSI string for this frame.
    ///
    /// Sequence:
    ///   1. `ESC[2J` — erase display.
    ///   2. `ESC[H` — cursor home.
    ///   3. For each region, in declaration order, each line + `\n`.
    ///   4. `ESC[H` — cursor home (so the next render starts at the
    ///      same origin).
    ///
    /// V.15b's cheap-update path will replace this with a delta
    /// encoder; the `diff(against:)` seam lands in V.15a-2.
    public func toANSI() -> String {
        var out = ""
        out.append(ANSI.clear())
        out.append(ANSI.home())
        for region in regions {
            for line in region.lines {
                out.append(line)
                out.append("\n")
            }
        }
        out.append(ANSI.home())
        return out
    }
}

/// V.15b's delta-encoder result. V.15a-2 ships only the seam — the
/// `payload` is empty and `RenderFrame.diff(against:)` returns a
/// no-op delta. V.15b will fill `payload` with the minimal ANSI
/// cursor-positioning + content-overwrite sequence that turns
/// `previous` into `self`, enabling the <50 ms p95 SSH update path.
public struct ANSIDelta: Sendable, Equatable {
    public let payload: String

    public init(payload: String = "") {
        self.payload = payload
    }

    public static let noop = ANSIDelta(payload: "")
}

extension RenderFrame {
    /// V.15b-fill-in seam. V.15a-2 returns `.noop` so call sites
    /// compile against the final shape today; V.15b implements the
    /// actual delta encoder without restructuring the runner. Per
    /// operator's 2026-05-07 Q6 verdict ("pre-shape now").
    public func diff(against previous: RenderFrame) -> ANSIDelta {
        // V.15b fills this in. Until then, callers fall back to
        // `toANSI()` for full-clear-and-paint.
        _ = previous
        return .noop
    }
}
