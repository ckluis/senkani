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
