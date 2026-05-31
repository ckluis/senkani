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
    /// V.15b-fill-in seam (kept for source compatibility with the
    /// V.15a-2 call sites). Delegates to the real encoder.
    public func diff(against previous: RenderFrame) -> ANSIDelta {
        return RenderFrame.diff(prior: previous, next: self)
    }

    /// Flatten the frame into a list of `(regionId, absoluteRow, text)`
    /// where `absoluteRow` is 1-indexed and matches exactly the row
    /// each line lands on after `toANSI()` paints from cursor-home.
    ///
    /// `toANSI()` emits, from home (row 1, col 1), each region's lines
    /// top-to-bottom each followed by `\n`. So the first line of the
    /// frame is row 1, the next row 2, and so on across region
    /// boundaries — regions do NOT introduce blank separators.
    fileprivate func flattenedLines() -> [(regionId: String, row: Int, text: String)] {
        var out: [(regionId: String, row: Int, text: String)] = []
        var row = 1
        for region in regions {
            for line in region.lines {
                out.append((regionId: region.id, row: row, text: line))
                row += 1
            }
        }
        return out
    }

    /// REAL delta encoder. Produces the minimal-ish ANSI sequence that,
    /// applied to a terminal currently showing a full paint of `prior`,
    /// yields exactly what a full paint of `next` would show.
    ///
    /// Granularity (operator-locked design):
    ///   • panes-table region (`panes_table`): ROW-LEVEL diff — emit a
    ///     cursor-position + erase-to-EOL + overwrite for each row whose
    ///     text changed, when the table's geometry (start row + row
    ///     count) is stable. If the table grew/shrank or shifted, the
    ///     table's rows are repainted wholesale (still no per-glyph
    ///     diff).
    ///   • header / live-tiles / footer regions: REGION-LEVEL diff —
    ///     wholesale-repaint the region's rows when any byte in it
    ///     changed, or when it shifted because a region above it changed
    ///     line count.
    ///   • trailing rows that existed in `prior` but not in `next` are
    ///     positioned-to + erased (so removed rows don't linger).
    ///
    /// No `ESC[2J`: the steady-state stream never full-clears. Every
    /// touched row is `ESC[row;1H` + `ESC[K` + text.
    public static func diff(prior: RenderFrame, next: RenderFrame) -> ANSIDelta {
        let priorLines = prior.flattenedLines()
        let nextLines = next.flattenedLines()

        // Group line indices by region for both frames, preserving the
        // absolute rows. Region order is the frame's declaration order.
        func regionRows(_ lines: [(regionId: String, row: Int, text: String)])
            -> [(id: String, rows: [(row: Int, text: String)])]
        {
            var result: [(id: String, rows: [(row: Int, text: String)])] = []
            for entry in lines {
                if let last = result.last, last.id == entry.regionId {
                    result[result.count - 1].rows.append((row: entry.row, text: entry.text))
                } else {
                    result.append((id: entry.regionId, rows: [(row: entry.row, text: entry.text)]))
                }
            }
            return result
        }

        let priorRegions = regionRows(priorLines)
        let nextRegions = regionRows(nextLines)

        // Map regionId -> prior rows (first occurrence) for stability
        // comparisons. Region ids are unique per frame in practice.
        var priorByID: [String: [(row: Int, text: String)]] = [:]
        for r in priorRegions where priorByID[r.id] == nil {
            priorByID[r.id] = r.rows
        }

        // Accumulate the rows we will repaint: row -> text (or nil = erase).
        // Use a dictionary keyed by absolute row so later region rules
        // win deterministically; we then emit in ascending row order.
        var paint: [Int: String?] = [:]

        let panesID = DashboardRender.panesTableRegionId

        for region in nextRegions {
            let priorRows = priorByID[region.id]
            let geometryStable: Bool = {
                guard let pr = priorRows else { return false }
                guard pr.count == region.rows.count else { return false }
                // Start row must match so row-level addressing is valid.
                guard let pFirst = pr.first?.row, let nFirst = region.rows.first?.row else {
                    return false
                }
                return pFirst == nFirst
            }()

            if region.id == panesID && geometryStable, let priorRows = priorRows {
                // ROW-LEVEL diff: only changed rows.
                for (idx, nextRow) in region.rows.enumerated() {
                    let priorText = priorRows[idx].text
                    if priorText != nextRow.text {
                        paint[nextRow.row] = nextRow.text
                    }
                }
            } else {
                // REGION-LEVEL diff. Repaint the whole region when it
                // changed in any byte, when it shifted, or when its row
                // count differs from prior.
                let changed: Bool = {
                    guard let pr = priorRows else { return true }
                    if pr.count != region.rows.count { return true }
                    for (idx, nextRow) in region.rows.enumerated() {
                        if pr[idx].text != nextRow.text { return true }
                        if pr[idx].row != nextRow.row { return true }
                    }
                    return false
                }()
                if changed {
                    for nextRow in region.rows {
                        paint[nextRow.row] = nextRow.text
                    }
                }
            }
        }

        // Erase trailing rows: any prior row whose absolute row index is
        // beyond the last next row must be blanked so removed content
        // does not linger on the terminal.
        let nextMaxRow = nextLines.last?.row ?? 0
        let priorMaxRow = priorLines.last?.row ?? 0
        if priorMaxRow > nextMaxRow {
            for row in (nextMaxRow + 1)...priorMaxRow {
                // nil text → position + erase only.
                if paint[row] == nil {
                    paint[row] = Optional<String>.none
                }
            }
        }

        if paint.isEmpty {
            return .noop
        }

        var out = ""
        for row in paint.keys.sorted() {
            out.append(ANSI.moveTo(row: row, col: 1))
            out.append(ANSI.clearLine())
            if let text = paint[row], let text = text {
                out.append(text)
            }
        }
        // Park the cursor at home, mirroring toANSI()'s trailing home so
        // both paths leave the cursor in the same place.
        out.append(ANSI.home())
        return ANSIDelta(payload: out)
    }
}
